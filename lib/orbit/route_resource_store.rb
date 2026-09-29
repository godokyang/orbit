# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "resource_call_ledger"
require_relative "route_resource_facts"

module Orbit
  # Project-private, durable store for verified route resource facts, and the
  # per-call cost/quota report built from the real task call ledger
  # (主方案 §9, ADR-009 §6.4, 审计 F01/F03/F07).
  #
  # The store persists only documents that RouteResourceFacts fully validated.
  # It holds no credentials and no execution endpoints: a fact's source
  # reference is the documented place the reading came from, and a reference
  # that embeds a credential pair is refused. Facts are never rewritten, never
  # completed with a guess and never invented here.
  #
  # Selection is exact: scope plus the four-key execution identity plus account
  # scope and plan, then the newest reading whose effective window and
  # verification snapshot cover the moment being priced. Nothing is matched by
  # model name, neighbouring version, provider or price similarity.
  #
  # The report prices actual ledger calls, one by one, in the fact's own
  # currency or quota unit. A call with no verified fact, an unverified account
  # scope, incomplete reported usage or an unusable price window stays unknown —
  # never zero, never a catalogue price, and never a provider-reported SDK cost.
  # Cash is summed only per currency and account scope; quota stays in its own
  # plan/account/unit and is never converted into money. No budget or
  # confirmation gate is introduced here.
  class RouteResourceStore
    SCHEMA_VERSION = "orbit-route-resource-store-v1"
    FILE_NAME = "route-resources.json"
    LOCK_NAME = "route-resources.lock"
    DIRECTORY = ".orbit"
    MAX_BYTES = 2 * 1024 * 1024
    MAX_FACTS = 200
    # A source reference is documentation, never a credential or an endpoint
    # with embedded authentication.
    CREDENTIAL_REFERENCE = %r{://[^/\s@]+:[^/\s@]+@}

    class Error < StandardError; end

    def initialize(project_root:, path: nil, clock: nil)
      @project_root = File.realpath(project_root)
      @path = File.expand_path(path.nil? || path.to_s.empty? ? File.join(@project_root, DIRECTORY, FILE_NAME) : path.to_s)
      @clock = clock || -> { Time.now.utc }
    end

    attr_reader :path

    # Validates every document before writing anything, then appends the reading
    # as its own snapshot. Reading the same fact identity again at the same
    # verification time is idempotent; the same identity and time with different
    # content is refused, because a stored price is never silently amended. Every
    # accepted reading stays auditable, and selection picks the newest usable one.
    def import(documents)
      list = documents.is_a?(Array) ? documents : [documents]
      raise Error, "at least one route resource fact is required" if list.empty?

      validated = list.map do |document|
        fact = RouteResourceFacts.from(document, now: @clock.call)
        reference = fact.source["reference"].to_s
        raise Error, "a resource fact source reference must not embed credentials" if reference.match?(CREDENTIAL_REFERENCE)

        fact.document
      end

      stored = []
      kept = []
      count = 0
      with_lock do
        entries = read_entries
        validated.each do |fact|
          existing = entries.find do |entry|
            fact_key(entry) == fact_key(fact) && verified_at(entry) == verified_at(fact)
          end
          if existing
            raise Error, "conflicting resource fact for the same identity and verification time" unless existing == fact

            kept << existing
            next
          end
          raise Error, "route resource fact limit reached (#{MAX_FACTS})" if entries.length >= MAX_FACTS

          entries << fact
          stored << fact
        end
        write_entries(entries)
        count = entries.length
      end
      { "stored" => stored, "kept_existing" => kept, "count" => count }
    end

    # The raw stored document, for audit. A detached copy.
    def read
      JSON.parse(JSON.generate("schema_version" => SCHEMA_VERSION, "entries" => read_entries))
    end

    # Raw stored facts matching the given exact constraints. A nil constraint
    # means "not filtered"; a given one must match exactly.
    def list(scope: nil, route: nil, account_scope: nil, plan: nil, source_kind: nil)
      entries = read_entries.select do |fact|
        (scope.nil? || fact["scope"] == scope) &&
          (route.nil? || identity(fact["route"]) == identity(route)) &&
          (account_scope.nil? || fact.dig("applicability", "account_scope") == account_scope) &&
          (plan.nil? || fact.dig("applicability", "plan") == plan) &&
          (source_kind.nil? || fact.dig("source", "kind") == source_kind)
      end
      JSON.parse(JSON.generate(entries))
    end

    # The newest reading of one exact fact identity whose published effective
    # window and verification snapshot both cover `at`. Returns a
    # RouteResourceFacts, or nil when no stored reading is usable.
    #
    # This is the strict, pricing-side selection: the observed account scope is
    # required by the fact schema, so an unstated or explicitly unknown one
    # selects nothing. `plan` is optional in the schema, so a nil observation
    # matches a fact that declares no plan (a general API price) and never a
    # fact that declares one; an explicitly unknown plan selects nothing.
    # `list` keeps its lenient audit filters and is never used for pricing.
    def select(scope:, route:, account_scope:, plan: nil, source_kind: nil, at: nil)
      return nil if unstated?(account_scope) || explicit_unknown?(plan)

      moment = at || @clock.call
      candidates = read_entries.select do |fact|
        fact["scope"] == scope && identity(fact["route"]) == identity(route) &&
          fact.dig("applicability", "account_scope") == account_scope &&
          fact_plan(fact) == plan && (source_kind.nil? || fact.dig("source", "kind") == source_kind)
      end
      usable = candidates.filter_map do |document|
        fact = RouteResourceFacts.from(document, now: moment)
        next unless fact.snapshot_valid_at?(moment) && fact.effective_at?(moment)

        [verified_at(document), fact]
      end
      return nil if usable.empty?

      usable.max_by { |retrieved_at, _fact| retrieved_at }.last
    end

    # Cost and quota accounting for the actual calls of one task.
    #
    # account_scope and plan are the values actually observed for these calls.
    # Each may be a single value applied to every call, or a Hash keyed by
    # "provider/model" (or by the full four-key identity) for tasks that ran
    # different routes under different accounts or plans. They are never taken
    # from the fact being checked: a price is only applied inside the account and
    # plan the caller observed, and an unstated one stays unknown.
    def report(task_path:, task_id: nil, account_scope: nil, plan: nil, at: nil)
      ledger = ResourceCallLedger.new(task_path: task_path, task_id: task_id || File.basename(task_path), clock: @clock)
      calls = ledger.calls
      rows = calls.map { |call| price_call(call, account_scope: account_scope, plan: plan) }
      recorded = calls.length
      native = native_coverage(task_path, task_id || File.basename(task_path))
      native_unknown = native["pending_calls"].positive? || !native["gaps"].empty?
      {
        "store" => { "path" => @path, "facts" => read_entries.length },
        "coverage" => { "calls_recorded" => recorded, "scope" => "recorded_calls_only", "unknown" => recorded.zero? || native_unknown,
                        "native_observations" => native,
                        "calls_total" => recorded,
                        "calls_with_route_fact" => rows.count { |row| row["route_fact"] },
                        "calls_priced" => rows.count { |row| row["cost"] },
                        "calls_quota_rules" => rows.count { |row| row["quota"] },
                        "calls_unknown" => rows.count { |row| row["cost"].nil? && row["quota"].nil? },
                        "status_counts" => calls.map { |call| call["status"] }.tally,
                        "usage_status_counts" => calls.map { |call| call["usage_status"] }.tally,
                        "note" => recorded.zero? ? "no recorded calls; this task's resource consumption is unknown, " \
                                                   "and nothing is claimed as complete" :
                                  "totals cover attributed calls only; a failed, partially reported or " \
                                  "unverified call is reported as unknown instead of zero" },
        "calls" => rows,
        "cash" => cash_totals(rows),
        "quota" => quota_totals(rows),
        "gaps" => rows.filter_map { |row| { "call_id" => row["call_id"], "reason" => row["gap"] } if row["gap"] },
        "unknown" => { "cost_complete" => recorded.positive? && !native_unknown && rows.all? { |row| row["cost"] },
                       "quota_consumption_computed" => false,
                       "cash_scope" => "priced calls of one currency and one account scope only",
                       "quota_scope" => "plan rules only, in the plan's own unit; never converted to money" },
        "note" => "no provider-reported SDK cost is used as a price, and no budget or quota gate is applied"
      }
    end

    private

    def native_coverage(task_path, task_id)
      coverage = { "calls_observed" => nil, "pending_calls" => 0, "gaps" => [] }
      observations = File.join(task_path, "native-model-calls.json")
      if File.file?(observations)
        document = JSON.parse(File.read(observations))
        unless document.is_a?(Hash) && document["schema_version"] == "orbit-native-model-calls-v1" &&
               document["task_id"] == task_id && document["calls"].is_a?(Hash) && document["gaps"].is_a?(Array) &&
               document["calls"].values.all? { |call| call.is_a?(Hash) }
          raise Error, "native call observations are corrupt or foreign"
        end
        coverage["calls_observed"] = document["calls"].length
        coverage["pending_calls"] = document["calls"].values.count { |call| call["finalized"] != true }
        coverage["gaps"] = document["gaps"].map(&:to_s)
      end
      failures = File.join(task_path, "native-model-call-gaps.jsonl")
      if File.file?(failures)
        File.foreach(failures) do |line|
          entry = JSON.parse(line)
          raise Error, "native receipt persistence gap is malformed" unless entry.is_a?(Hash) && entry["reason"].is_a?(String)

          coverage["gaps"] << entry["reason"]
        end
      end
      coverage["gaps"].uniq!
      coverage
    rescue JSON::ParserError, SystemCallError, Error => error
      coverage["gaps"] << error.message
      coverage
    end

    def price_call(call, account_scope:, plan:)
      identity_fields = call["actual_identity"] || {}
      route = { "provider" => identity_fields["provider"], "model" => identity_fields["model"],
                "reasoning" => identity_fields["reasoning"], "billing_route" => identity_fields["billing_route"] }
      account_scope = observed_for(account_scope, route)
      plan = observed_for(plan, route)
      row = { "call_id" => call["call_id"], "role" => call["role"], "phase" => call["phase"],
              "status" => call["status"], "attempt_id" => call["attempt_id"],
              "requested_model" => call["requested_model"], "actual_identity" => identity_fields,
              "usage_status" => call["usage_status"], "usage_source" => call["usage_source"],
              "usage" => call["usage"], "recorded_at" => call["recorded_at"],
              "account_scope" => account_scope, "plan" => plan,
              "route_fact" => nil, "estimate" => nil, "cost" => nil, "quota" => nil, "gap" => nil }
      moment = call_time(call["started_at"])
      if moment.nil?
        return row.merge("gap" => "the call has no recorded start time; a recording time never stands in for it")
      end
      if unstated?(account_scope)
        return row.merge("gap" => "account_scope_unverified")
      end
      if explicit_unknown?(plan)
        return row.merge("gap" => "the plan is explicitly unknown, and no plan is inferred from a stored fact")
      end

      fact = select(scope: identity_fields["scope"], route: route, account_scope: account_scope, plan: plan, at: moment)
      if fact.nil?
        return row.merge("gap" => "no verified resource fact covers this exact route, account scope, plan and call time")
      end

      row = row.merge("route_fact" => fact_summary(fact.document))
      ended = call_time(call["completed_at"])
      if ended && !(fact.snapshot_valid_at?(ended) && fact.effective_at?(ended))
        return row.merge("gap" => "the call spans beyond this fact's verified window, so one price cannot cover it")
      end
      if fact.quota.is_a?(Hash) && fact_plan(fact.document).nil?
        return row.merge("gap" => "the quota fact does not state its plan, so its rules cannot be applied")
      end
      # A partially or wholly unreported composition can never yield a total.
      return row.merge("gap" => "reported usage is #{call['usage_status']}; a total is not claimed") unless
        call["usage_status"] == "reported"

      result = fact.estimate(route: route, usage: call["usage"], account_scope: account_scope,
                             usage_source: "recorded_calls", at: moment)
      case result["status"]
      when "priced"
        row.merge("estimate" => result, "cost" => { "currency" => result["currency"], "amount" => result["amount"] })
      when "quota_rules_only"
        row.merge("estimate" => result,
                  "quota" => { "unit" => result.dig("quota", "unit"), "plan" => result.dig("quota", "plan"),
                               "account_scope" => result["account_scope"], "rules" => result.dig("quota", "rules"),
                               "consumption" => nil })
      else
        row.merge("estimate" => result, "gap" => result["reason"].to_s)
      end
    end

    def cash_totals(rows)
      rows.select { |row| row["cost"] }.group_by { |row| [row["cost"]["currency"], row["account_scope"]] }
          .map do |(currency, scope), group|
        { "currency" => currency, "account_scope" => scope,
          "amount" => group.sum { |row| row["cost"]["amount"] }, "calls" => group.map { |row| row["call_id"] } }
      end.sort_by { |total| [total["currency"].to_s, total["account_scope"].to_s] }
    end

    def quota_totals(rows)
      rows.select { |row| row["quota"] }
          .group_by { |row| [row.dig("quota", "plan"), row["account_scope"], row.dig("quota", "unit"), row.dig("quota", "rules")] }
          .map do |(plan, scope, unit, _rules), group|
        { "plan" => plan, "account_scope" => scope, "unit" => unit, "consumption" => nil,
          "rules" => group.first.dig("quota", "rules"), "calls" => group.map { |row| row["call_id"] },
          "note" => "published plan rules only; quota consumption is not computed and unlike units are never added" }
      end.sort_by { |total| [total["plan"].to_s, total["unit"].to_s] }
    end

    def fact_summary(fact)
      { "scope" => fact["scope"], "route" => fact["route"], "account_scope" => fact.dig("applicability", "account_scope"),
        "plan" => fact.dig("applicability", "plan"), "currency" => fact["currency"],
        "quota_unit" => fact.dig("quota", "unit"), "source_kind" => fact.dig("source", "kind"),
        "verified_at" => fact.dig("verification", "retrieved_at"), "valid_until" => fact.dig("verification", "valid_until") }
    end

    # A real observed call time, or nil. The recording time is deliberately not
    # a fallback: a price is applied to when the call actually ran.
    # One observation for one route: a scalar applies to every call, a Hash is
    # looked up by the exact identity first and then by provider/model. A route
    # with no entry has no observed value and therefore stays unknown.
    def observed_for(value, route)
      return value unless value.is_a?(Hash)

      exact = route.values_at("provider", "model", "reasoning", "billing_route").map(&:to_s).join("/")
      value[exact] || value["#{route['provider']}/#{route['model']}"] || value["default"]
    end

    def call_time(value)
      return nil unless value.is_a?(String) && !value.strip.empty?

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def identity(route)
      route.is_a?(Hash) ? %w[provider model reasoning billing_route].map { |field| route[field].to_s } : nil
    end

    # A fact's own plan: the optional applicability plan, or the plan named by
    # its quota rules. Nil means the fact genuinely declares no plan.
    def fact_plan(fact)
      plan = fact.dig("applicability", "plan")
      plan = fact.dig("quota", "plan") unless stated?(plan)
      stated?(plan) ? plan.to_s.strip : nil
    end

    def stated?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def unstated?(value)
      !stated?(value) || value.to_s.strip.casecmp?("unknown")
    end

    def explicit_unknown?(value)
      !value.nil? && (!stated?(value) || value.to_s.strip.casecmp?("unknown"))
    end

    def fact_key(fact)
      [fact["scope"], identity(fact["route"]), fact.dig("applicability", "account_scope"), fact.dig("applicability", "plan")]
    end

    def verified_at(fact)
      Time.iso8601(fact.dig("verification", "retrieved_at").to_s)
    end

    def read_entries
      return [] unless File.exist?(@path)

      raise Error, "route resource store is unexpectedly large: #{@path}" if File.size(@path) > MAX_BYTES

      parsed =
        begin
          JSON.parse(File.read(@path))
        rescue JSON::ParserError
          raise Error, "route resource store is not valid JSON: #{@path}"
        end
      unless parsed.is_a?(Hash) && parsed["schema_version"] == SCHEMA_VERSION && parsed["entries"].is_a?(Array)
        raise Error, "route resource store does not match #{SCHEMA_VERSION}: #{@path}"
      end

      parsed["entries"].each do |entry|
        begin
          RouteResourceFacts.from(entry)
        rescue RouteResourceFacts::Error => error
          raise Error, "route resource store is corrupt at #{@path}: #{error.message}"
        end
      end
      parsed["entries"]
    rescue Errno::ENOENT
      raise Error, "route resource store disappeared while reading: #{@path}"
    end

    def write_entries(entries)
      bytes = JSON.pretty_generate("schema_version" => SCHEMA_VERSION, "entries" => entries) + "\n"
      raise Error, "route resource store would exceed #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES

      directory = File.dirname(@path)
      FileUtils.mkdir_p(directory)
      File.chmod(0o700, directory)
      temporary = File.join(directory, ".#{File.basename(@path)}.#{SecureRandom.hex(8)}.tmp")
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.chmod(0o600, temporary)
        File.rename(temporary, @path)
        File.open(directory, File::RDONLY) { |dir| dir.fsync }
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(File.join(File.dirname(@path), LOCK_NAME), File::WRONLY | File::CREAT, 0o600) do |lock|
        lock.chmod(0o600)
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
