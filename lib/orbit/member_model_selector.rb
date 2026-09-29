# frozen_string_literal: true

require "digest"
require "json"
require_relative "jev_advisor"
require_relative "model_capability_facts"
require_relative "model_evidence_cache"
require_relative "model_quality_policy"
require_relative "route_cost_inputs"
require_relative "observation_key"
require_relative "openrouter_model_overview"

module Orbit
  # Per-task assessment of whether an authorized execution member can take a
  # bounded work unit, and if so which one (主方案 §5.2/§6/§8, ADR-009 §6.2/§6.3).
  #
  # Candidates are pooled models the session catalog can both resolve and map to
  # a generated agent; an empty pool falls back to one real native @task
  # resolution. Each candidate is projected per exact execution identity through
  # ModelCapabilityFacts, so precise evidence and the catalog prior are labeled
  # side by side and the host's resolved limits decide an explicit requirement.
  # Ordering comes from ModelQualityPolicy and the release loaded from
  # production calibration: without one this class pays no judgment at all and
  # only reports facts, leaving the native choice to Root. Unknown cost never
  # rejects a candidate, and there is no budget, time, brand or local-success
  # gate here.
  class MemberModelSelector
    VERSION = "orbit-member-selection-v1"
    # Distinguishes "no release injected" (production: read the reviewed file)
    # from an injected release, including an injected nil.
    UNSET = Object.new
    NATIVE_AGENT = "task"
    MAX_CANDIDATES = 64
    MAX_TEXT = 300

    def initialize(connection:, project_root:, pool:, evidence_cache:, advisor:,
                   overview: nil, release: UNSET, route_cost_inputs: nil)
      @connection = connection
      @project_root = project_root
      @pool = pool
      @evidence_cache = evidence_cache
      @advisor = advisor
      @overview = overview || OpenRouterModelOverview.new
      @facts = ModelCapabilityFacts.new(overview: @overview, evidence_cache: @evidence_cache)
      @release_injected = !release.equal?(UNSET)
      @release = @release_injected && release.is_a?(Hash) ? release : nil
      @release_note = if @release_injected && !release.nil? && !release.is_a?(Hash)
                        "an injected release must be a validated calibration hash"
                      end
      # Production default: the task-scoped RouteCostInputs builder. An
      # explicit route_costs argument (tests) always wins over it.
      @route_cost_inputs = route_cost_inputs
    end

    # `state` is the actual task-record context (inputs, workspace, input_digest)
    # and `work_unit` the real work-unit object (scope with allowed paths,
    # string/array acceptance, model_requirements). Reusing an unchanged
    # previous assessment returns it with reused: true and spends nothing.
    def assess(state:, work_unit:, previous: nil, excluded: [], route_costs: nil)
      @native = nil
      prepared = prepare(state: state, work_unit: work_unit, excluded: excluded, route_costs: route_costs)
      reusable = reusable_assessment(previous, prepared)
      return reusable.merge("reused" => true) if reusable

      assessment(prepared)
    end

    private

    def reusable_assessment(previous, prepared)
      return nil unless previous.is_a?(Hash) && previous["version"] == VERSION
      return nil unless previous["signature"].is_a?(String) && previous["signature"] == prepared["signature"]

      previous
    end

    def prepare(state:, work_unit:, excluded:, route_costs:)
      catalog, catalog_error = model_catalog
      pool, pool_note = candidate_pool
      unit = unit_view(work_unit)
      route_costs = default_route_costs(unit) if route_costs.nil?

      state_digest = digest_field(state)
      stale = !unit["input_digest"].nil? && !state_digest.nil? && unit["input_digest"] != state_digest
      earlier = Array(excluded).map(&:to_s).uniq
      candidates, selection_note = candidate_list(pool: pool, pool_note: pool_note, catalog: catalog,
                                                   excluded: earlier, unit: unit)
      release, release_note = current_release
      {
        "catalog" => catalog, "catalog_error" => catalog_error, "pool" => pool, "pool_note" => pool_note,
        "excluded" => earlier,
        "unit" => unit, "state" => state.is_a?(Hash) ? state : {}, "input_digest" => state_digest,
        "stale" => stale, "candidates" => candidates, "selection_note" => selection_note,
        "release" => release, "release_note" => release_note, "route_costs" => route_costs
      }.tap { |prepared| prepared["signature"] = signature(prepared) }
    end

    # The production route-cost source: the task-scoped inputs file bound to
    # this exact work unit. Any binding or credibility failure yields {} -
    # cost stays unknown and quality judgment continues; an explicitly
    # injected route_costs argument (tests) bypasses this entirely.
    def default_route_costs(unit)
      builder = @route_cost_inputs
      return nil unless builder && unit["id"].is_a?(String)

      builder.build(scope: "member", work_unit_id: unit["id"],
                    artifact_root: unit["artifact_root"], input_digest: unit["input_digest"])
    rescue RouteCostInputs::Error
      nil
    end

    # Pool members are only usable when the session catalog can both resolve the
    # model and map it to a generated agent; the name is never re-derived here.
    # An empty pool uses the one real native @task resolution and no default.
    def candidate_list(pool:, pool_note:, catalog:, excluded:, unit:)
      return [[], pool_note] if pool.nil?

      if pool.empty?
        resolution, note = native_resolution
        candidates = resolution ? native_candidates(resolution, catalog, unit, excluded) : []
        return [candidates, candidates.empty? ? (note || "the native task model resolved to no usable identity") : nil]
      end

      agents = catalog.is_a?(Hash) && catalog["agents"].is_a?(Hash) ? catalog["agents"] : nil
      available = catalog.is_a?(Hash) ? Array(catalog["available"]) : nil
      if agents.nil? || available.nil?
        return [[], "the session model catalog is unavailable; Root selects a native agent"]
      end

      models = pool.select { |model| available.include?(model) && agents.key?(model) && !excluded.include?(model) }
      if models.empty?
        return [[], "no pooled model is both available and mapped to a session agent; Root selects a native agent"]
      end

      [models.first(MAX_CANDIDATES).map { |model| catalog_candidate(model, catalog, agents, unit) }, nil]
    end

    def native_candidates(resolution, catalog, unit, excluded)
      provider = resolution["provider"].to_s
      id = resolution["id"].to_s
      model = "#{provider}/#{id}"
      return [] if provider.empty? || id.empty? || excluded.include?(model)

      identity = identity_for(catalog, model, resolution)
      [candidate(agent: NATIVE_AGENT, model: model, identity: identity, unit: unit, catalog: catalog, native: true)]
    end

    # One real resolution of the native @task model, at most once per
    # assessment, and never used when the pool produced candidates.
    def native_resolution
      return @native if @native

      resolved = @connection.member_model_resolution
      @native = [resolved.is_a?(Hash) ? resolved : nil, nil]
    rescue StandardError => error
      @native = [nil, "the native task model could not be resolved (#{error.class})"]
    end

    def catalog_candidate(model, catalog, agents, unit)
      identity = identity_for(catalog, model, nil)
      candidate(agent: agents[model], model: model, identity: identity, unit: unit, catalog: catalog, native: false)
    end

    # One candidate's facts are always projected with the same four-key identity
    # the candidate carries, so an actual route or reasoning is never degraded to
    # unknown by a second lookup.
    def candidate(agent:, model:, identity:, unit:, catalog:, native:)
      facts = facts_for(catalog, model, identity, unit)
      evidence = evidence_entry(facts)
      prior = catalog_prior(facts)
      {
        "agent" => agent, "model" => model, "identity" => identity,
        "in_pool" => !native, "native" => native,
        "evidence" => evidence, "model_overview_prior" => prior,
        "quality_basis" => evidence ? "exact_model_evidence" : (prior ? "model_overview_prior" : "unknown"),
        "quality_sources" => Array(evidence&.[]("sources") || prior&.[]("sources")).first(3),
        "quality_evidence_valid_until" => evidence&.[]("valid_until"),
        "model_overview_status" => facts.dig("catalog", "status"),
        "recommendation_hold" => facts["recommendation_hold"] == true, "hold_reason" => facts["hold_reason"],
        "facts" => facts, "eligibility" => facts["eligibility"],
        "execution_eligibility" => facts["execution_eligibility"], "projection_error" => facts["projection_error"]
      }
    end

    def evidence_entry(facts)
      precise = facts["precise_evidence"]
      return nil unless precise.is_a?(Hash) && precise["status"] == ModelEvidenceCache::STATUS_EVIDENCE

      precise["entry"]
    end

    def catalog_prior(facts)
      prior = facts.dig("catalog", "prior")
      prior.is_a?(Hash) ? prior : nil
    end

    def facts_for(catalog, model, identity, unit)
      @facts.candidate_facts(identity: identity, task: unit["model_requirements"], project_root: @project_root,
                             execution_limits: catalog.is_a?(Hash) && catalog["limits"].is_a?(Hash) ? catalog["limits"][model] : nil)
    rescue ModelCapabilityFacts::Error => error
      { "catalog" => { "status" => "error", "detail" => bounded(error.message) },
        "precise_evidence" => { "status" => "error", "entry" => nil },
        "eligibility" => nil, "execution_eligibility" => nil, "conflicts" => [], "contrasts" => [],
        "recommendation_hold" => false, "hold_reason" => nil,
        "projection_error" => bounded(error.message) }
    end

    # The four explicit identity fields. The billing route is the host's resolved
    # route for that exact model; reasoning has no real declaration source, so it
    # stays "unknown" and is never guessed from a model name.
    def identity_for(catalog, model, resolution)
      provider, id = model.to_s.split("/", 2)
      route = resolution.is_a?(Hash) ? resolution["billing_route"] : nil
      route ||= catalog.is_a?(Hash) && catalog["routes"].is_a?(Hash) ? catalog["routes"][model] : nil
      route = "unknown" unless %w[direct_api subscription_quota unknown].include?(route)
      reasoning = resolution.is_a?(Hash) ? resolution["reasoning"].to_s.strip : ""
      reasoning = "unknown" if reasoning.empty?
      { "provider" => provider.to_s, "model" => id.to_s, "reasoning" => reasoning, "billing_route" => route }
    end

    # Only what the work unit declares: an allowed-path scope, its acceptance,
    # its explicit model requirements, its own input version and its declared
    # dependencies. Nothing is filled in or assumed satisfied.
    def unit_view(unit)
      scope = unit_field(unit, "scope")
      {
        # The real handoff fields travel unchanged into both the judgment input
        # and the cache signature. The id in particular keeps two identically
        # described units apart; nothing here is filled in from the state.
        "id" => unit_field(unit, "id"),
        "status" => unit_field(unit, "status"),
        "objective" => unit_field(unit, "objective"),
        "requirements" => unit_field(unit, "requirements"),
        "context" => unit_field(unit, "context"),
        "decisions" => unit_field(unit, "decisions"),
        "escalation" => unit_field(unit, "escalation"),
        "acceptance" => unit_field(unit, "acceptance"),
        "artifact_root" => unit_field(unit, "artifact_root"),
        "scope" => scope.is_a?(Hash) ? scope : {},
        "allowed_paths" => unit_field(scope, "allowed_paths"),
        "model_requirements" => unit_field(unit, "model_requirements") || {},
        "input_digest" => unit_field(unit, "input_digest"),
        "dependencies" => unit_field(unit, "dependencies"),
        "dispatches" => unit_field(unit, "dispatches"),
        "member_id" => unit_field(unit, "member_id"),
        "tool_call_id" => unit_field(unit, "tool_call_id"),
        "model" => unit_field(unit, "model"),
        "result" => unit_field(unit, "result"),
        "verification" => unit_field(unit, "verification")
      }
    end

    def unit_field(unit, key)
      return nil if unit.nil?

      return unit[key] if unit.respond_to?(:[]) && !unit.is_a?(String)
      return unit.public_send(key) if unit.respond_to?(key)

      nil
    rescue StandardError
      nil
    end

    def digest_field(state)
      return nil unless state.is_a?(Hash)

      value = state["input_digest"]
      value = state.dig("inputs", "input_digest") unless value.is_a?(String)
      value.is_a?(String) && !value.empty? ? value : nil
    end

    # A pool that cannot be read is unknown, not empty: only a real empty array
    # may fall back to the native @task resolution.
    def candidate_pool
      pool = @pool.read
      return [nil, "the candidate pool could not be read: expected an array"] unless pool.is_a?(Array)

      [pool.map(&:to_s).uniq, nil]
    rescue StandardError => error
      [nil, "the candidate pool could not be read (#{error.class})"]
    end

    def model_catalog
      [@connection.model_catalog, nil]
    rescue StandardError => error
      [nil, "the session model catalog is unavailable (#{error.class})"]
    end

    # Production calibration is the reviewed file; a test may inject one. An
    # absent or unreadable file is a downgrade, never an error.
    def current_release
      return [@release, @release_note] if @release_injected

      loaded = ModelQualityPolicy.load
      case loaded
      when Hash then [loaded, nil]
      when nil then [nil, nil]
      else [nil, loaded.to_s.slice(0, MAX_TEXT)]
      end
    rescue StandardError => error
      [nil, "the calibration file could not be read (#{error.class})"]
    end

    # The whole validated document, so every release binding — thresholds,
    # scope, model, question digest, proves_samples_real, allows_positive_ranking,
    # the nested release block and any other invalidation toggle — participates in
    # the cache signature. A change in any of them must re-assess.
    def release_binding(release)
      release.is_a?(Hash) ? ObservationKey.normalize(release) : nil
    end

    # Canonical material: the policy binding, the whole release binding, the task
    # input/unit, the per-candidate facts, the excluded set and the route costs.
    # A change in any of them must re-assess; an unchanged one spends nothing.
    def signature(prepared)
      Digest::SHA256.hexdigest(JSON.generate(
        ObservationKey.normalize(
          "version" => VERSION,
          "policy" => ModelQualityPolicy.binding,
          "release" => release_binding(prepared["release"]),
          "input_digest" => prepared["input_digest"], "unit" => prepared["unit"],
          "state" => ModelQualityPolicy.project_selection_state(judgment_body(prepared, [])),
          "candidates" => prepared["candidates"].map { |item| item.slice("agent", "model", "identity", "facts") },
          "excluded" => prepared["excluded"], "route_costs" => prepared["route_costs"]
        )
      ))
    end

    # The judgment body: the task context and work unit as given, plus each
    # candidate's labeled facts. The advisor projects it before sending.
    def judgment_body(prepared, candidates)
      context = prepared["state"].is_a?(Hash) ? prepared["state"] : {}
      context.merge(
        "work_unit" => prepared["unit"],
        "candidates" => candidates.map do |item|
          option = { "agent" => item["agent"], "provider" => item["identity"]["provider"],
                     "model" => item["identity"]["model"], "identity" => item["identity"],
                     "capability_facts" => item["facts"] }
          # Both evidence classes are handed over together whenever both exist.
          option["evidence"] = item["evidence"] if item["evidence"]
          option["model_overview_prior"] = item["model_overview_prior"] if item["model_overview_prior"]
          option
        end
      )
    end

    def assessment(prepared)
      result = base_result(prepared)
      return result.merge("decision" => "stale", "reason" => "the work unit belongs to another input version") if prepared["stale"]
      return result.merge("decision" => "facts_only", "reason" => prepared["selection_note"] || "no candidate") if prepared["candidates"].empty?

      release = prepared["release"]
      if release.nil?
        return result.merge("decision" => "facts_only", "reason" => release_reason(prepared))
      end
      unless prepared["candidates"].any? { |item| item["evidence"] || item["model_overview_prior"] }
        return result.merge("decision" => "facts_only",
                            "reason" => "no candidate carries usable sourced facts or a catalog prior; no judgment is paid")
      end

      active = ModelQualityPolicy.ranking_release(release)
      if active.nil?
        return result.merge("decision" => "facts_only",
                            "reason" => "the calibration document is not a valid ranking binding; no judgment is paid")
      end
      profile = ModelQualityPolicy.profile_for(projection_for(prepared))
      if profile.nil? || profile != active["scope"]
        return result.merge("decision" => "facts_only",
                            "reason" => "this task profile (#{profile || 'unrecognized'}) has no reviewed release " \
                                        "scope; no judgment is paid")
      end

      judge(prepared, result, release)
    end

    def projection_for(prepared)
      ModelQualityPolicy.project_selection_state(judgment_body(prepared, prepared["candidates"]))
    end

    def release_reason(prepared)
      note = prepared["release_note"] || prepared["catalog_error"]
      "no reviewed release for this task profile; facts only and Root chooses (native agents stay available)" +
        (note ? " (#{note})" : "")
    end

    def base_result(prepared)
      { "version" => VERSION, "signature" => prepared["signature"], "reused" => false,
        "candidates" => prepared["candidates"].map { |item| candidate_view(item, nil) },
        "requirements_error" => requirements_error(prepared),
        "recommendation" => { "first" => nil, "backups" => [] }, "judgments" => [],
        "judgment_state" => nil, "input_digest" => prepared["input_digest"], "stale" => prepared["stale"],
        "dependencies" => prepared["unit"]["dependencies"],
        "route_cost_inputs" => prepared["route_costs"],
        "release" => release_binding(prepared["release"]), "decision" => "facts_only", "reason" => nil }
    end

    def candidate_view(item, verdict)
      item.slice("agent", "model", "identity", "in_pool", "native", "quality_basis", "quality_sources",
                 "quality_evidence_valid_until", "model_overview_status", "recommendation_hold", "hold_reason",
                 "eligibility", "execution_eligibility", "projection_error").merge("verdict" => verdict)
    end

    # A candidate whose facts could not be projected is reported as an explicit
    # unknown instead of a silent no-requirements projection.
    def requirements_error(prepared)
      prepared["candidates"].filter_map { |item| item["projection_error"] }.first
    end

    # A release is required before any paid judgment: it supplies the reviewed
    # bar, and the receipt itself must match the task profile and the actual
    # service model. Two real calls: handoff/member fit first, then per-candidate
    # task fit only when that receipt clears both delegation gates.
    def judge(prepared, result, release)
      body = judgment_body(prepared, prepared["candidates"])
      projection = projection_for(prepared)
      delegation = judge_call(phase: "delegation") { @advisor.assess_delegation(state: body) }
      result["judgments"] << delegation["receipt"]
      result["judgment_state"] = body
      unless delegation["ok"] && delegation_released?(release, delegation["receipt"], projection)
        return result.merge("decision" => "not_recommended",
                            "reason" => delegation["receipt"]["error"] || "the delegation gates did not clear for this release")
      end

      candidates_call = judge_call(phase: "candidates") do
        @advisor.assess_candidates(state: body, candidates: body["candidates"])
      end
      result["judgments"] << candidates_call["receipt"]
      unless candidates_call["ok"]
        return result.merge("decision" => "not_recommended",
                            "reason" => candidates_call["receipt"]["error"] || "the per-candidate judgment failed")
      end

      costs = prepared["route_costs"]
      # The recorded producer keys by exact provider/model; ranking selects
      # native agent ids. Bind those two identities through this actual
      # candidate list, retaining the source inputs in the assessment.
      costs = prepared["candidates"].to_h do |item|
        [item["agent"], costs[item["model"]] || costs[item["agent"]]]
      end if costs.is_a?(Hash)
      order = ModelQualityPolicy.order(signals(prepared, candidates_call["receipt"]), release: release,
                                       route_costs: costs, state: projection,
                                       judgment: candidates_call["receipt"])
      ordered = Array(order["ordered_ids"])
      first = order["positive"] ? ordered.first : nil
      result["candidates"] = prepared["candidates"].map do |item|
        candidate_view(item, first == item["agent"] ? "recommended" : "not_recommended")
      end
      result.merge(
        "decision" => first ? "recommended" : "not_recommended",
        "reason" => first ? order["reason"] : "no candidate cleared the released task-fit bar for this profile",
        "recommendation" => { "first" => first, "backups" => first ? Array(order["positive_ids"]) - [first] : [] },
        "order" => order
      )
    end

    def delegation_released?(release, receipt, state)
      return false unless ModelQualityPolicy.activated_release(release: release, judgment: receipt, state: state)

      %w[handoff_fit member_task_fit].all? do |question|
        ModelQualityPolicy::GATING_QUESTION_SETS[question] == receipt["question_set_version"] &&
          ModelQualityPolicy.released_score?({ "quality" => receipt.dig("scores", question), "question" => question },
                                             release)
      end
    end

    def signals(prepared, receipt)
      prepared["candidates"].each_with_index.map do |item, index|
        { "id" => item["agent"], "index" => index, "question" => "candidate_task_fit",
          "quality" => receipt.dig("scores", index.to_s, "quality"), "identity" => item["identity"],
          "recommendation_hold" => item["recommendation_hold"] }
      end
    end

    # One real judgment attempt. The receipt keeps the service's own identity and
    # consumption; a failure keeps its real receipt and never becomes a success
    # or a fabricated zero.
    def judge_call(phase:)
      receipt = yield
      { "phase" => phase, "ok" => true, "receipt" => judgment_receipt(phase, receipt) }
    rescue JevAdvisor::Error => error
      { "phase" => phase, "ok" => false, "receipt" => judgment_receipt(phase, error.judgment, error: error.message) }
    rescue StandardError => error
      { "phase" => phase, "ok" => false,
        "receipt" => { "phase" => phase, "status" => "unavailable", "receipt_missing" => true,
                       "error" => "judgment call failed (#{error.class})" } }
    end

    # The recorded receipt is the real one, copied field by field: its input
    # version, model and question set are never substituted with a local
    # constant, so a receipt that does not match the release cannot look valid.
    def judgment_receipt(phase, receipt, error: nil)
      facts = receipt.is_a?(Hash) ? receipt : {}
      entry = facts.reject { |key, _| key == "usage" }.merge("phase" => phase, "usage" => bounded_usage(facts["usage"]))
      entry["error"] = error if error && !entry.key?("error")
      entry
    end

    def bounded_usage(usage)
      return nil unless usage.is_a?(Hash)

      kept = usage.select { |key, value| key.is_a?(String) && !key.empty? && value.is_a?(Numeric) }
      kept.empty? ? nil : kept
    end

    def bounded(text)
      text.to_s.strip.slice(0, MAX_TEXT)
    end
  end
end
