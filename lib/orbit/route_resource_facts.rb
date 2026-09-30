# frozen_string_literal: true

require "time"

module Orbit
  # One verified resource fact for one execution/billing route.
  #
  # A fact must state who verified it, where that can be re-checked, when the
  # reading was taken and until when it must be re-checked, for which account
  # scope/plan/conditions, which route identity, in which currency or quota
  # unit, per which provider category, and over which published effective dates.
  # Nothing here converts between currencies, turns subscription quota into
  # money, uses an OpenRouter catalog price for an OMP route, adds overlapping
  # token categories together, or prices a call whose route, account scope,
  # verification snapshot or effective window does not cover it.
  #
  # A missing price, a missing usage composition, an unverified billing route or
  # account scope, a lapsed verification snapshot and an unstated start of
  # effectiveness are all unknown: never zero, never "always valid", never
  # applied backwards to an older call, and never a cheaper candidate. A reading
  # whose publisher states no effective date may still be archived, but only with
  # an explicit `"effective": {"from": null, "until": null, "unknown": true}`
  # marker: such a fact covers no moment, never prices, never ranks and never has
  # a reading time substituted for the publisher's date. Structural validation
  # only checks that these fields exist and are well formed; it does not prove any
  # claimed source is genuine.
  class RouteResourceFacts
    SCHEMA_VERSION = "orbit-route-resource-facts-v1"
    # omp_route and judgment_service are the routes Orbit actually calls.
    # openrouter_catalog is only the catalog that supplied the model, so its
    # prices describe that catalog and not an OMP route.
    SCOPES = %w[omp_route judgment_service openrouter_catalog].freeze
    BILLING_ROUTES = %w[direct_api subscription_quota unknown].freeze
    # Where the fact came from. A fact without a named verifier and a checkable
    # reference is not accepted: a price claim nobody can re-check is not a
    # resource fact.
    SOURCE_KINDS = %w[first_party_pricing plan_document runtime_usage billing_observation].freeze
    CATEGORY_UNITS = %w[token request weighted_request].freeze
    MAX_CATEGORIES = 16
    MAX_TEXT = 512

    class Error < StandardError; end

    def self.from(document, now: nil)
      new(document, now: now)
    end

    # Each estimate must already be priced for its own verified account and
    # conditions. Cash amounts in the same currency can then be compared across
    # routes/accounts; requiring one shared account would prevent comparing
    # different providers. Quota rules, missing usage and different currencies
    # remain indeterminate. Amounts are arithmetic
    # over the stated usage, not bills and not budget claims.
    def self.compare(first, second)
      blockers = { "first" => first, "second" => second }.filter_map do |label, estimate|
        next if estimate.is_a?(Hash) && estimate["status"] == "priced"
        status = estimate.is_a?(Hash) ? estimate["status"].to_s : "malformed"
        reason = estimate.is_a?(Hash) ? estimate["reason"].to_s : "estimate is not a result hash"
        "#{label} is not priced (#{status}: #{reason})"
      end
      if blockers.empty? && first["currency"] != second["currency"]
        blockers << "different currencies are not comparable: #{first['currency']} vs #{second['currency']}"
      end
      if blockers.any?
        return { "verdict" => "indeterminate", "reasons" => blockers, "first" => first, "second" => second,
                 "note" => "unknown cost is not free and not a ranking" }
      end

      difference = (first["amount"] - second["amount"]).abs
      tolerance = 1e-9 * [first["amount"].abs, second["amount"].abs].max
      verdict = if difference <= tolerance
                  "equal"
                elsif first["amount"] < second["amount"]
                  "first_cheaper"
                else
                  "second_cheaper"
                end
      { "verdict" => verdict, "currency" => first["currency"],
        "account_scopes" => [first["account_scope"], second["account_scope"]],
        "first_amount" => first["amount"], "second_amount" => second["amount"],
        "usage_sources" => [first["usage_source"], second["usage_source"]],
        "note" => "amounts are arithmetic estimates over the stated usage, not bills or budget claims" }
    end

    def initialize(document, now: nil)
      @document = validate(document)
      @now = now
    end

    attr_reader :document

    def route = @document.fetch("route")
    def scope = @document.fetch("scope")
    def source = @document.fetch("source")
    def verification = @document.fetch("verification")
    def effective = @document.fetch("effective")
    def applicability = @document.fetch("applicability")
    def currency = @document["currency"]
    def plan = @document.dig("applicability", "plan")
    def account_scope = @document.dig("applicability", "account_scope")
    def quota = @document["quota"]
    def categories = @document.fetch("categories")
    def billing_route = route.fetch("billing_route")

    # Two different windows, never conflated: the provider's published rule
    # dates (`effective`) and this verification snapshot's re-check window
    # (`verification`). The snapshot window is the same TTL vocabulary the model
    # evidence cache already uses; it qualifies how long this reading may be
    # trusted before re-checking and cannot prove the price did not change
    # inside it.
    def effective_at?(at = nil)
      return false if effective_unknown?

      moment = at || @now || Time.now.utc
      from = Time.iso8601(effective.fetch("from"))
      until_time = effective["until"] && Time.iso8601(effective["until"])
      return false if moment < from

      until_time.nil? || moment < until_time
    end

    # A fact whose publisher effective date is unknown carries no date coverage
    # at all: it may be archived and listed, but no call date falls inside it.
    def effective_unknown? = effective["unknown"] == true

    def snapshot_valid_at?(at = nil)
      moment = at || @now || Time.now.utc
      retrieved = Time.iso8601(verification.fetch("retrieved_at"))
      valid_until = Time.iso8601(verification.fetch("valid_until"))
      retrieved <= moment && moment < valid_until
    end

    # Prices one observed route at one usage composition.
    #
    # route: the identity actually observed for this call, as
    #   { "provider" =>, "model" =>, "reasoning" =>, "billing_route" => }.
    #   Values must match this fact exactly; "unknown" never substitutes for a
    #   concrete value, and an unverified billing route never yields a price.
    # account_scope: the account scope actually observed for this call. It must
    #   match the fact's declared scope exactly; an unstated observed scope or an
    #   "unknown" scope yields unknown, because a price is only comparable
    #   inside the account, plan and conditions it was verified for.
    # at: the call time being priced. A fact is never applied backwards to an
    #   older call whose verification snapshot or effective window did not cover
    #   it; an unusable past still yields unknown instead of a back-calculation.
    # usage: provider-reported counts per category name. Every billed category
    #   must be present, and every reported field must belong to a declared
    #   category; a coarser `total` cannot stand in for its parts, and an extra
    #   overlapping field makes the result unknown instead of double counted.
    # usage_source: where the counts came from, e.g. "recorded_calls" for
    #   aggregated receipts of this route, or "assumed"/"prediction" for a
    #   bounded estimate. It is returned so callers cannot present an
    #   assumption as a settled amount.
    def estimate(route:, usage:, account_scope: nil, usage_source: "recorded_calls", at: nil)
      moment = at || @now || Time.now.utc
      # A catalog price describes the catalog that supplied the model, not the
      # route Orbit actually calls, so it never settles an OMP or judgment call
      # even when the model name matches.
      if scope == "openrouter_catalog"
        return unknown("catalog_pricing_does_not_price_omp_route",
                       "an OpenRouter catalog price is not an OMP route price")
      end

      observed = route_identity(route)
      return unknown("route_identity_mismatch", "observed #{observed} is not the priced route #{route_identity(self.route)}") if observed != route_identity(self.route)
      if billing_route == "unknown"
        return unknown("billing_route_unverified",
                       "the billing route of this price is unknown, so no comparable total cost exists")
      end
      observed_scope = account_scope.nil? ? nil : text(account_scope, "observed account scope")
      return unknown("account_scope_unverified", "the observed account scope or plan was not stated") if observed_scope.nil?
      if observed_scope == "unknown" || observed_scope != self.account_scope
        return unknown("account_scope_mismatch",
                       "observed account scope #{observed_scope} is not the scope this price was verified for (#{self.account_scope})")
      end
      if !snapshot_valid_at?(moment)
        if Time.iso8601(verification.fetch("retrieved_at")) > moment
          return unknown("verification_not_yet_made", "this price was verified after the call")
        end

        return unknown("verification_snapshot_expired",
                       "the verification snapshot lapsed before the call; it is a re-check window, not proof the price stayed unchanged")
      end
      if effective_unknown?
        return unknown("price_effective_unknown",
                       "the publisher's effective date is unknown, so this reading covers no call and never prices")
      end
      unless effective_at?(moment)
        return unknown("price_effective_window",
                       "the provider's published effective window does not cover #{moment.utc.iso8601}")
      end

      if quota
        # The plan's published rules are all this fact holds. Orbit does not
        # compute quota consumption from them, and two plans naming the same
        # unit or rule label are not thereby proven to share rules.
        return { "status" => "quota_rules_only", "amount" => nil, "currency" => nil, "consumption" => nil,
                 "reason" => "subscription_quota_rules_only", "quota" => quota, "usage_source" => usage_source,
                 "account_scope" => self.account_scope, "route" => self.route,
                 "note" => "published plan rules only: no quota consumption is computed, and a shared rule label is not verified evidence" }
      end

      priced = billed_categories
      return unknown("no_priced_category", "the fact declares no price for an observed category") if priced.empty?
      return unknown("currency_unknown", "a price without a verified currency cannot be compared") if currency.nil?

      counts, unusable = usage_counts(usage)
      return unknown("usage_composition_unknown", "no attributable usage composition was supplied") if counts.empty?
      unless unusable.empty?
        return unknown("usage_value_unusable",
                       "reported counts are not finite nonnegative numbers: #{unusable.sort.join(', ')}")
      end

      declared = categories.keys
      outside = counts.keys - declared
      unless outside.empty?
        return unknown("usage_fields_outside_price_definition",
                       "reported fields are not part of the price definition: #{outside.sort.join(', ')}")
      end

      missing = priced.keys - counts.keys
      unless missing.empty?
        return unknown("usage_composition_incomplete",
                       "billed categories without a reported count: #{missing.sort.join(', ')}")
      end

      detail = priced.to_h do |name, category|
        count = counts.fetch(name)
        amount = count / category.fetch("per").to_f * category.fetch("price")
        [name, { "unit" => category.fetch("unit"), "count" => count, "price" => category.fetch("price"),
                 "per" => category.fetch("per"), "amount" => amount }]
      end
      { "status" => "priced", "amount" => detail.values.sum { |item| item.fetch("amount") },
        "currency" => currency, "reason" => nil, "categories" => detail, "usage_source" => usage_source,
        "account_scope" => self.account_scope, "route" => self.route,
        "valid_at" => moment.utc.iso8601,
        "note" => "arithmetic over the stated usage, not a bill; overlapping categories are never added together" }
    end

    private

    def unknown(reason, note)
      { "status" => "unknown", "amount" => nil, "currency" => nil, "reason" => reason, "note" => note,
        "account_scope" => nil, "route" => route }
    end

    # A category is billed when it carries its own price. A category marked as
    # included in another (reasoning inside output, for example) is reported but
    # must not be charged twice.
    def billed_categories
      categories.select { |_name, category| category["price"] }.to_h
    end

    # Reported counts are kept only when they are finite nonnegative numbers.
    # Anything else is named so the caller sees an unusable report instead of a
    # silently smaller sum.
    def usage_counts(usage)
      return [{}, []] unless usage.is_a?(Hash)

      kept = {}
      unusable = []
      usage.each do |name, count|
        if count.is_a?(Numeric) && count.finite? && count >= 0
          kept[name] = count
        else
          unusable << name.to_s
        end
      end
      [kept, unusable]
    end

    def route_identity(route)
      raise Error, "route identity must be a hash" unless route.is_a?(Hash)

      %w[provider model reasoning billing_route].to_h do |field|
        value = route[field]
        [field, value.nil? ? nil : text(value, "route #{field}")]
      end
    end

    def validate(document)
      raise Error, "resource fact must be one JSON object" unless document.is_a?(Hash)
      raise Error, "unsupported resource fact schema" unless document["schema_version"] == SCHEMA_VERSION

      scope = enum(document["scope"], SCOPES, "scope")
      route = validate_route(document["route"])
      source = validate_source(document["source"])
      verification = validate_verification(document["verification"])
      effective = validate_effective(document["effective"])
      applicability = validate_applicability(document["applicability"])
      currency = document["currency"]
      unless currency.nil? || (currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/))
        raise Error, "invalid currency"
      end

      quota = validate_quota(document["quota"])
      if quota && route["billing_route"] != "subscription_quota"
        raise Error, "quota rules belong to a subscription budget route"
      end

      categories = validate_categories(document["categories"], quota)
      { "schema_version" => SCHEMA_VERSION, "scope" => scope, "route" => route, "source" => source,
        "verification" => verification, "effective" => effective, "applicability" => applicability,
        "currency" => currency, "categories" => categories, "quota" => quota,
        "notes" => optional_text(document["notes"], MAX_TEXT) }
    end

    def validate_route(route)
      raise Error, "route identity is required" unless route.is_a?(Hash)

      {
        "provider" => text(route["provider"], "provider"), "model" => text(route["model"], "model"),
        # An unproved reasoning effort stays "unknown" and never silently means
        # the provider default or another effort.
        "reasoning" => text(route["reasoning"], "reasoning"),
        "billing_route" => enum(route["billing_route"], BILLING_ROUTES, "billing route")
      }
    end

    def validate_source(source)
      raise Error, "resource source is required" unless source.is_a?(Hash)

      # Who verified it and where it can be re-checked. Both are required so a
      # price claim can be attributed and re-read; their presence is a minimal
      # field, not proof that the claim is genuine — real auditing is separate.
      { "kind" => enum(source["kind"], SOURCE_KINDS, "source kind"),
        "detail" => text(source["detail"], "source detail", MAX_TEXT),
        "verifier" => text(source["verifier"], "source verifier", MAX_TEXT),
        "reference" => text(source["reference"], "source reference", MAX_TEXT) }
    end

    # This reading's own re-check window, in the model evidence cache's
    # vocabulary. It must be bounded: an unbounded snapshot would silently read
    # as "still true", and the window itself never proves the price was stable.
    def validate_verification(verification)
      raise Error, "verification snapshot is required" unless verification.is_a?(Hash)

      retrieved_at = timestamp(verification["retrieved_at"], "verification retrieved_at")
      valid_until = timestamp(verification["valid_until"], "verification valid_until")
      raise Error, "verification valid_until must be after retrieved_at" unless valid_until > retrieved_at

      { "retrieved_at" => retrieved_at, "valid_until" => valid_until }
    end

    # The provider's published rule dates. `from` must be stated so a fact is
    # never read as valid since forever; `until` may be explicitly absent when
    # the provider published no end date.
    def validate_effective(effective)
      raise Error, "effective dates are required and must state when the rule took effect" unless effective.is_a?(Hash)

      unknown = effective["unknown"]
      unless unknown.nil? || unknown == true
        raise Error, "effective.unknown must be true when stated"
      end
      if unknown == true
        unless effective["from"].nil? && effective["until"].nil?
          raise Error, "an explicit unknown effective date must not carry a from or until date"
        end

        return { "from" => nil, "until" => nil, "unknown" => true }
      end
      raise Error, "effective.from must state when the rule took effect" if effective["from"].nil?

      from = timestamp(effective["from"], "effective from")
      until_text = effective["until"].nil? ? nil : timestamp(effective["until"], "effective until")
      raise Error, "effective.until must be after effective.from" if until_text && Time.iso8601(until_text) <= Time.iso8601(from)

      { "from" => from, "until" => until_text }
    end

    def timestamp(value, label)
      text = text(value, label)
      begin
        Time.iso8601(text)
      rescue ArgumentError
        raise Error("#{label} must be an ISO 8601 timestamp")
      end
      text
    end

    def validate_applicability(applicability)
      raise Error, "applicability is required" unless applicability.is_a?(Hash)

      { "account_scope" => text(applicability["account_scope"], "account scope", MAX_TEXT),
        "plan" => optional_text(applicability["plan"], MAX_TEXT),
        "conditions" => optional_text(applicability["conditions"], MAX_TEXT) }
    end

    def validate_quota(quota)
      return nil if quota.nil?
      raise Error, "quota must be a hash" unless quota.is_a?(Hash)

      { "unit" => text(quota["unit"], "quota unit"),
        "rules" => text(quota["rules"], "quota rules", MAX_TEXT),
        "plan" => optional_text(quota["plan"]),
        "reset" => optional_text(quota["reset"]) }
    end

    def validate_categories(categories, quota)
      raise Error, "categories must be a hash" unless categories.is_a?(Hash) && categories.length <= MAX_CATEGORIES

      validated = categories.to_h { |name, category| [text(name, "category name", 64), validate_category(name, category)] }
      return validated if validated.any? { |_name, category| category["price"] } || quota

      raise Error, "a price fact must carry at least one priced category or a quota rule"
    end

    def validate_category(name, category)
      raise Error, "category #{name} must be a hash" unless category.is_a?(Hash)

      price = category["price"]
      included_in = category["included_in"]
      if price.nil?
        raise Error, "category #{name} needs a price or an included_in category" if included_in.nil?
        raise Error, "category #{name} cannot include itself" if included_in == name

        return { "included_in" => text(included_in, "category included_in", 64) }
      end

      unless price.is_a?(Numeric) && price.finite? && price >= 0
        raise Error, "category #{name} price must be a finite nonnegative number"
      end
      per = category["per"]
      raise Error, "category #{name} needs an integer per" unless per.is_a?(Integer) && per.positive?

      { "unit" => enum(category["unit"], CATEGORY_UNITS, "category unit"), "price" => price, "per" => per }
    end

    def text(value, label, limit = 128)
      unless value.is_a?(String) && !value.strip.empty? && value.length <= limit && !value.match?(/[\x00-\x1f\x7f]/)
        raise Error, "invalid #{label}"
      end
      value
    end

    def optional_text(value, limit = 128)
      value.nil? ? nil : text(value, "optional text", limit)
    end

    def enum(value, values, label)
      raise Error, "invalid #{label}" unless values.include?(value)

      value
    end
  end
end
