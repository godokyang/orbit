# frozen_string_literal: true

# Route resource facts decide what a call's reported usage costs on the route
# that actually ran. These fixtures pin the boundaries the mixed-delivery plan
# requires: named verifier and checkable reference, account scope, a bounded
# verification snapshot separate from the provider's published effective dates,
# no catalog price for an OMP route, no total cost from an unverified route or
# account, and no backward pricing of older calls. No provider or model is
# contacted.
require_relative "../lib/orbit/route_resource_facts"

module RouteResourceFactsTest
  module_function

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition
  end

  def route(billing_route: "direct_api")
    { "provider" => "zhipu", "model" => "glm-5.2", "reasoning" => "unknown", "billing_route" => billing_route }
  end

  def document(overrides = {})
    {
      "schema_version" => Orbit::RouteResourceFacts::SCHEMA_VERSION,
      "scope" => "omp_route", "route" => route(),
      "source" => { "kind" => "first_party_pricing", "detail" => "provider price list section 3",
                    "verifier" => "orbit maintainer", "reference" => "https://example.test/pricing" },
      "verification" => { "retrieved_at" => "2026-09-28T00:00:00Z", "valid_until" => "2026-10-05T00:00:00Z" },
      "effective" => { "from" => "2026-08-01T00:00:00Z", "until" => nil },
      "applicability" => { "account_scope" => "provider account acct-1", "plan" => "pay as you go",
                           "conditions" => "standard list price, no promotion" },
      "currency" => "USD",
      "categories" => {
        "input" => { "unit" => "token", "price" => 0.6, "per" => 1_000_000 },
        "cache_read" => { "unit" => "token", "price" => 0.06, "per" => 1_000_000 },
        "output" => { "unit" => "token", "price" => 2.2, "per" => 1_000_000 },
        "reasoning" => { "included_in" => "output" }
      }
    }.merge(overrides)
  end

  def fact(overrides = {})
    Orbit::RouteResourceFacts.from(document(overrides), now: Time.utc(2026, 9, 29, 12))
  end

  def at = Time.utc(2026, 9, 29, 12)
  def scope = "provider account acct-1"

  def check_complete_composition_prices_once
    result = fact.estimate(route: route(), account_scope: scope, at: at,
                           usage: { "input" => 1000, "cache_read" => 500, "output" => 200, "reasoning" => 150 })
    check(result["status"] == "priced", "a complete composition yields a priced estimate")
    check((result["amount"] - 0.00107).abs < 1e-12, "each priced category is charged once: #{result['amount']}")
    check(result["currency"] == "USD" && result["categories"].keys.sort == %w[cache_read input output],
          "reasoning is declared inside output and is not charged separately")
    check(result["account_scope"] == scope && result["usage_source"] == "recorded_calls",
          "the estimate states the account scope and where the usage composition came from")
    check(result["note"].include?("not a bill"), "an estimate never claims to be an actual bill")
  end

  def check_reported_zero_is_priced_zero
    result = fact.estimate(route: route(), account_scope: scope, at: at,
                           usage: { "input" => 0, "cache_read" => 0, "output" => 0 })
    check(result["status"] == "priced" && result["amount"].zero?,
          "a reported zero composition is a priced zero, not an unknown")
  end

  def check_missing_composition_is_unknown
    unknown = fact.estimate(route: route(), account_scope: scope, at: at, usage: nil)
    check(unknown["reason"] == "usage_composition_unknown", "no composition means unknown cost")
    partial = fact.estimate(route: route(), account_scope: scope, at: at, usage: { "input" => 1000 })
    check(partial["status"] == "unknown" && partial["reason"] == "usage_composition_incomplete",
          "a composition missing a billed category is never priced from the remainder")
    coarse = fact.estimate(route: route(), account_scope: scope, at: at, usage: { "total_tokens" => 12345 })
    check(coarse["reason"] == "usage_fields_outside_price_definition",
          "a coarse total cannot stand in for its parts and is not silently dropped")
    unusable = fact.estimate(route: route(), account_scope: scope, at: at,
                             usage: { "input" => "1000", "cache_read" => 0, "output" => 0 })
    check(unusable["reason"] == "usage_value_unusable", "a non-numeric count makes the estimate unknown")
  end

  def check_route_and_account_must_be_verified
    check(fact.estimate(route: route(billing_route: "subscription_quota"), account_scope: scope, at: at,
                        usage: { "input" => 1, "cache_read" => 0, "output" => 1 })["reason"] == "route_identity_mismatch",
          "an unverified billing route cannot inherit a direct_api price")
    check(fact.estimate(route: { "provider" => "zhipu", "model" => "glm-5", "reasoning" => "unknown",
                                 "billing_route" => "direct_api" },
                        account_scope: scope, at: at,
                        usage: { "input" => 1, "cache_read" => 0, "output" => 1 })["status"] == "unknown",
          "a neighbouring model never borrows the price")

    unverified_route = fact("route" => route(billing_route: "unknown"))
    check(unverified_route.estimate(route: route(billing_route: "unknown"), account_scope: scope, at: at,
                                    usage: { "input" => 1, "cache_read" => 0, "output" => 1 })["reason"] ==
          "billing_route_unverified",
          "a fact whose real billing route is unknown never yields a comparable total cost")
    check(fact.estimate(route: route(), at: at,
                        usage: { "input" => 1, "cache_read" => 0, "output" => 1 })["reason"] == "account_scope_unverified",
          "an unstated account scope is never assumed")
    check(fact.estimate(route: route(), account_scope: "another account", at: at,
                        usage: { "input" => 1, "cache_read" => 0, "output" => 1 })["reason"] == "account_scope_mismatch",
          "another account's price is not applied to this call")
  end

  def check_catalog_price_never_prices_an_omp_route
    catalog = fact("scope" => "openrouter_catalog")
    result = catalog.estimate(route: route(), account_scope: scope, at: at,
                              usage: { "input" => 1, "cache_read" => 0, "output" => 1 })
    check(result["status"] == "unknown" && result["reason"] == "catalog_pricing_does_not_price_omp_route",
          "an OpenRouter catalog price never settles an OMP route call")
  end

  def check_snapshot_and_effective_windows_are_separate
    lapsed = fact("verification" => { "retrieved_at" => "2026-09-01T00:00:00Z", "valid_until" => "2026-09-08T00:00:00Z" })
    result = lapsed.estimate(route: route(), account_scope: scope, at: at,
                             usage: { "input" => 1, "cache_read" => 0, "output" => 1 })
    check(result["reason"] == "verification_snapshot_expired" && result["note"].include?("not proof"),
          "a price reading past its re-check window is unknown, not a proven-stable price")

    back_calculated = fact.estimate(route: route(), account_scope: scope, at: Time.utc(2026, 9, 20, 12),
                                    usage: { "input" => 1, "cache_read" => 0, "output" => 1 })
    check(back_calculated["reason"] == "verification_not_yet_made",
          "an unknown historical price is never applied backwards to an older call")

    future_rules = fact("effective" => { "from" => "2026-10-01T00:00:00Z", "until" => nil })
    result = future_rules.estimate(route: route(), account_scope: scope, at: at,
                                   usage: { "input" => 1, "cache_read" => 0, "output" => 1 })
    check(result["reason"] == "price_effective_window",
          "published rules that do not cover the call date cannot settle it")

    ended = fact("effective" => { "from" => "2026-08-01T00:00:00Z", "until" => "2026-09-15T00:00:00Z" })
    result = ended.estimate(route: route(), account_scope: scope, at: at,
                            usage: { "input" => 1, "cache_read" => 0, "output" => 1 })
    check(result["reason"] == "price_effective_window", "an ended rule window cannot settle a later call")

    open_ended = fact.estimate(route: route(), account_scope: scope, at: at,
                               usage: { "input" => 1, "cache_read" => 0, "output" => 1 })
    check(open_ended["status"] == "priced",
          "a published rule with no end date stays usable while its own snapshot window is valid")
  end

  def check_uncurrencied_price_is_unknown
    result = fact("currency" => nil).estimate(route: route(), account_scope: scope, at: at,
                                              usage: { "input" => 1, "cache_read" => 0, "output" => 1 })
    check(result["reason"] == "currency_unknown", "a price without a verified currency is unknown")
  end

  def check_quota_rules_are_not_consumption
    quota_fact = fact("route" => route(billing_route: "subscription_quota"), "currency" => nil, "categories" => {},
                      "quota" => { "unit" => "weighted_request", "rules" => "plan rules as published",
                                   "plan" => "coding plan", "reset" => "monthly" })
    estimate = quota_fact.estimate(route: route(billing_route: "subscription_quota"), account_scope: scope, at: at, usage: nil)
    check(estimate["status"] == "quota_rules_only" && estimate["amount"].nil? && estimate["consumption"].nil?,
          "published quota rules are not quota consumption and are never converted into money")
    check(estimate["note"].include?("not verified evidence"),
          "a shared unit or rule label is not claimed to prove shared plan rules")
    check(estimate.dig("quota", "unit") == "weighted_request", "the plan's own unit is preserved")

    priced = fact.estimate(route: route(), account_scope: scope, at: at,
                           usage: { "input" => 1000, "cache_read" => 0, "output" => 1000 })
    comparison = Orbit::RouteResourceFacts.compare(estimate, priced)
    check(comparison["verdict"] == "indeterminate", "quota rules and a currency price are never ranked against each other")
  end

  def check_crossed_prices_without_composition_are_indeterminate
    first = fact()
    second = fact("categories" => {
      "input" => { "unit" => "token", "price" => 5.0, "per" => 1_000_000 },
      "cache_read" => { "unit" => "token", "price" => 0.5, "per" => 1_000_000 },
      "output" => { "unit" => "token", "price" => 0.5, "per" => 1_000_000 }
    })
    comparison = Orbit::RouteResourceFacts.compare(
      first.estimate(route: route(), account_scope: scope, at: at, usage: nil),
      second.estimate(route: route(), account_scope: scope, at: at, usage: nil)
    )
    check(comparison["verdict"] == "indeterminate",
          "crossed input/output prices without a trustworthy composition cannot decide total cost")
    check(comparison["reasons"].length == 2, "both unknown estimates are named as blockers")

    priced = Orbit::RouteResourceFacts.compare(
      first.estimate(route: route(), account_scope: scope, at: at,
                     usage: { "input" => 1000, "cache_read" => 0, "output" => 1000 }),
      second.estimate(route: route(), account_scope: scope, at: at,
                      usage: { "input" => 1000, "cache_read" => 0, "output" => 1000 })
    )
    check(priced["verdict"] == "first_cheaper" && priced["currency"] == "USD",
          "a comparable composition and currency yields an explicit cheaper verdict")

    other_currency = Orbit::RouteResourceFacts.compare(
      first.estimate(route: route(), account_scope: scope, at: at,
                     usage: { "input" => 1000, "cache_read" => 0, "output" => 1000 }),
      fact("currency" => "EUR").estimate(route: route(), account_scope: scope, at: at,
                                         usage: { "input" => 1000, "cache_read" => 0, "output" => 1000 })
    )
    check(other_currency["verdict"] == "indeterminate", "different currencies are never compared in money")

    second_account = fact("applicability" => { "account_scope" => "other-account", "plan" => nil })
      .estimate(route: route(), account_scope: "other-account", at: at,
                usage: { "input" => 1000, "cache_read" => 0, "output" => 1000 })
    cross_account = Orbit::RouteResourceFacts.compare(first.estimate(
      route: route(), account_scope: scope, at: at,
      usage: { "input" => 1000, "cache_read" => 0, "output" => 1000 }), second_account)
    check(cross_account["verdict"] != "indeterminate" && cross_account["account_scopes"] == [scope, "other-account"],
          "cash in one currency is comparable after each account's applicability has been verified")
  end

  def check_invalid_fact_is_refused
    [
      [document("source" => { "kind" => "model_reputation", "detail" => "brand impression",
                              "verifier" => "someone", "reference" => "https://example.test" }), "source kind"],
      [document("source" => { "kind" => "first_party_pricing", "detail" => "page" }), "verifier"],
      [document("verification" => { "retrieved_at" => "2026-09-28T00:00:00Z" }), "valid_until"],
      [document("effective" => { "until" => nil }), "effective.from"],
      [document("applicability" => { "plan" => "pay as you go" }), "account scope"],
      [document("categories" => {}), "priced category"]
    ].each do |doc, expected|
      raised = false
      begin
        Orbit::RouteResourceFacts.from(doc)
      rescue Orbit::RouteResourceFacts::Error => error
        raised = error.message.include?(expected)
      end
      check(raised, "an incomplete or unsourced fact is refused (#{expected})")
    end
  end

  def run
    check_complete_composition_prices_once
    check_reported_zero_is_priced_zero
    check_missing_composition_is_unknown
    check_route_and_account_must_be_verified
    check_catalog_price_never_prices_an_omp_route
    check_snapshot_and_effective_windows_are_separate
    check_uncurrencied_price_is_unknown
    check_quota_rules_are_not_consumption
    check_crossed_prices_without_composition_are_indeterminate
    check_invalid_fact_is_refused
    puts "PASS route resource facts"
  end
end

RouteResourceFactsTest.run
