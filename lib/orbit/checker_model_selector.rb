# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "checker_model_selection"
require_relative "jev_advisor"
require_relative "model_candidate_pool"
require_relative "model_capability_facts"
require_relative "model_evidence_cache"
require_relative "model_quality_policy"
require_relative "route_cost_inputs"
require_relative "observation_key"
require_relative "omp_check_runner"
require_relative "openrouter_model_overview"

module Orbit
  # Shared by start and every subsequent independent check. OMP supplies model
  # availability; the pool is preferred, not a permission boundary.
  #
  # Candidate facts come from ModelCapabilityFacts per exact execution identity
  # (provider/model/reasoning/billing_route): the precise evidence entry and the
  # catalog fact/prior are always presented together, each labeled, and a
  # potential same-index divergence holds that candidate's automatic positive
  # recommendation. The billing route is the host's resolved route for that
  # exact model; reasoning has no real declaration source, so it stays "unknown"
  # and never becomes "default" or a guess from the model name.
  #
  # Ordering comes from ModelQualityPolicy through CheckerModelSelection: a
  # reviewed calibration release can clear the task-fit bar for the derived task
  # profile, and comparable verified route estimates can then prefer lower
  # resource cost. Without a release, with another judgment model, with another
  # question-set version, or with a held candidate, the selection only
  # downgrades to pool order — a runnable checker is never blocked by that.
  #
  # Time, local-sample and coarse-tier signals are not read here at all
  # (审计 C01/C02/C04, 主方案 §1.1/§8); the release scope is derived from the
  # task record, never copied from the release.
  class CheckerModelSelector
    Error = Class.new(ArgumentError)
    MAX_SOURCES = 3
    MAX_USAGE_BYTES = 512
    # Per-candidate diagnostics list at most this many models; a larger pool
    # is summarized with "+N more" instead of burying the next-step text.
    MAX_DIAGNOSTIC_MODELS = 8
    MAX_DETAIL_LENGTH = 300
    MAX_RELATED_IDENTITIES = 3
    BILLING_ROUTES = %w[direct_api subscription_quota unknown].freeze
    # Bump when the canonical signature material changes, so a selection
    # recorded under older material is never reused as if nothing changed.
    SIGNATURE_VERSION = "orbit-checker-selection-signature-v8"
    # Distinguishes "no release injected" (production: read the reviewed file)
    # from an explicitly injected release, including an injected nil.
    UNSET = Object.new

    def initialize(connection:, project_root:, pool: ModelCandidatePool.new,
                   evidence_cache: ModelEvidenceCache.new, advisor: nil, probe: nil,
                   clock: nil, overview: nil, release: UNSET, facts: nil, route_cost_inputs: nil)
      @connection = connection
      @project_root = project_root
      @pool = pool
      @evidence_cache = evidence_cache
      @advisor = advisor
      @overview = overview || OpenRouterModelOverview.new
      @facts = facts || ModelCapabilityFacts.new(overview: @overview, evidence_cache: @evidence_cache)
      @release_injected = !release.equal?(UNSET)
      @release = @release_injected && release.is_a?(Hash) ? release : nil
      @release_note = if @release_injected && !release.nil? && !release.is_a?(Hash)
                        "an injected release must be a validated calibration hash"
                      end
      @probe = probe || ->(models, source_agent_dir:, source_project_dir:) {
        OmpCheckRunner.probe_models(models: models, source_agent_dir: source_agent_dir,
                                    source_project_dir: source_project_dir)
      }
      @clock = clock || -> { Time.now.utc }
      # Production default: the task-scoped RouteCostInputs builder. An
      # explicit route_costs argument (tests) always wins over it.
      @route_cost_inputs = route_cost_inputs
    end

    # `excluded` contains models whose real check failed on this input and
    # artifact version. An explicit Root choice is pinned only while the
    # selection inputs are unchanged: a changed task state, facts set or
    # calibration binding always re-runs the selection.
    #
    # `state` is the actual task record context (workspace/project/git,
    # work_unit with scope and acceptance, review_role for a checker) and is the
    # only source of the task profile and of model requirements
    # (work_unit.model_requirements or model_requirements). `route_costs` are
    # verified RouteResourceFacts estimates keyed by candidate id; nil means
    # unknown, which never removes a runnable candidate.
    def select(explicit:, instruction:, previous: nil, selected_for: "start", excluded: [], state: {},
               route_costs: nil)
      # The only network opportunity is before the selection/Jev path. A
      # failed optional refresh never prevents a runnable checker from starting.
      @overview_refresh = refresh_overview
      excluded = Array(excluded).map(&:to_s).uniq
      text = explicit.to_s.strip
      prepared = prepare(instruction, excluded: excluded, state: state, route_costs: route_costs)
      if !text.empty? && !excluded.include?(text)
        return [previous["model"], previous] if same_explicit?(previous, text, prepared)

        return explicit_selection(text, prepared, selected_for)
      end
      if pinned_explicit?(previous, prepared) && !excluded.include?(previous["model"])
        return [previous["model"], previous]
      end
      return [previous["model"], previous] if reusable?(previous, prepared)

      auto_select(prepared, selected_for)
    end

    # Read-only, side-effect-free per-candidate diagnostics for the candidate
    # UX (`orbit model-status`, the `/orbit-models` surface and undecided
    # errors): the resolved exact identity, pool membership in the current
    # session catalog, the projected capability facts and the cached evidence
    # status. It never probes the isolated checker profile and never calls JEV —
    # candidates are only probed and judged when a selection is actually
    # attempted — so unjudged fields are reported as "not_judged"/"not_probed"
    # instead of a guess. An unreadable cache is reported as such, never as
    # "absent".
    def candidate_statuses
      pool = @pool.read
      entries = stored_entries
      now = @clock.call
      catalog = model_catalog
      available = catalog.is_a?(Hash) ? catalog["available"] : nil
      candidates = pool.map do |model|
        identity = identity_for(catalog, model)
        status = precise_status(identity, entries, now)
        facts = capability_facts(identity, {}, execution_limits(catalog, model))
        entry = {
          "model" => model,
          "identity" => identity,
          "reasoning" => identity["reasoning"],
          "billing_route" => identity["billing_route"],
          "in_session" => available.nil? ? nil : Array(available).include?(model),
          "evidence_status" => status["status"],
          "quality" => "not_judged",
          "isolated_probe" => "not_probed",
          "facts" => facts
        }
        entry["evidence_detail"] = status["detail"] if status["detail"]
        entry["model_overview"] = facts.dig("catalog", "status")
        entry["model_overview_facts"] = facts.dig("catalog", "facts") if facts.dig("catalog", "facts")
        entry
      end
      report = {
        "pool_empty" => pool.empty?,
        "session_catalog" => @connection.nil? ? "not_provided" : (catalog.is_a?(Hash) ? "available" : "unavailable"),
        "evidence_cache" => entries.nil? ? "unavailable" : "available",
        "candidates" => candidates,
        "model_overview" => overview_diagnostics,
        "generated_at" => now.utc.iso8601
      }
      if pool.empty?
        report["default_model"] = begin
          @connection.configured_model.to_s.strip
        rescue StandardError
          ""
        end
      end
      report
    rescue ModelCandidatePool::Error
      raise Error, "the candidate pool could not be read"
    end

    private

    def same_explicit?(previous, text, prepared)
      previous.is_a?(Hash) && previous["source"] == "explicit" && previous["model"] == text &&
        previous["version"] == CheckerModelSelection::DECISION_VERSION &&
        previous["signature"] == prepared["signature"]
    end

    def pinned_explicit?(previous, prepared)
      previous.is_a?(Hash) && previous["source"] == "explicit" && !previous["model"].to_s.empty? &&
        previous["version"] == CheckerModelSelection::DECISION_VERSION &&
        previous["signature"] == prepared["signature"]
    end

    def explicit_selection(model, prepared, selected_for)
      raise Error, "OMP review model must be provider/id" unless model.match?(OmpCheckRunner::MODEL_ID)

      unless Array(prepared.dig("catalog", "available")).include?(model)
        raise Error, "Root-selected review model #{model} is not available in this OMP session"
      end

      prepared = prepared.merge("models" => [model], "choice_source" => "explicit")
      prepared["signature"] = signature(prepared)
      selected, selection = auto_select(prepared, selected_for)
      selection["in_pool"] = prepared["pool"].include?(model)
      [selected, selection]
    end

    def prepare(instruction, excluded: [], state: {}, route_costs: nil)
      route_costs = default_route_costs if route_costs.nil?
      pool = @pool.read
      catalog = model_catalog
      available = Array(catalog&.[]("available")).select { |model| model.is_a?(String) &&
        model.match?(OmpCheckRunner::MODEL_ID) }.uniq
      current = catalog&.[]("current")
      available = [current, *available.reject { |model| model == current }] if available.include?(current)
      preferred = pool.select { |model| available.include?(model) && !excluded.include?(model) }
      models = preferred.empty? ? available.reject { |model| excluded.include?(model) } : preferred
      entries = stored_entries
      checked_at = @clock.call
      identities = available.to_h { |model| [model, identity_for(catalog, model)] }
      facts, requirements_error = project_facts(identities, state, catalog)
      release, release_note = current_release
      evidence = {}
      priors = {}
      statuses = {}
      available.each do |model|
        fact = facts[model]
        precise = fact.is_a?(Hash) ? fact["precise_evidence"] : nil
        prior = fact.is_a?(Hash) ? fact.dig("catalog", "prior") : nil
        status = precise_status(identities[model], entries, checked_at)
        statuses[model] = status
        # Only a structurally valid exact-identity fact is handed to the
        # judgment; the projection of an invalid, expired or unavailable record
        # stays visible in the facts and diagnostics without becoming evidence.
        if status["status"] == "valid" && precise.is_a?(Hash) && precise["entry"].is_a?(Hash)
          evidence[model] = precise["entry"]
        end
        if prior.is_a?(Hash)
          priors[model] = prior
        end
      end
      {
        "pool" => pool, "catalog" => catalog, "models" => models, "preferred" => preferred,
        "available" => available, "excluded" => excluded, "identities" => identities, "facts" => facts,
        "evidence" => evidence, "overview_priors" => priors,
        "evidence_statuses" => statuses.transform_values { |status| status["status"] },
        "evidence_details" => statuses.transform_values { |status| status["detail"] },
        "release" => release, "release_note" => release_note, "requirements_error" => requirements_error,
        "state" => state, "route_costs" => route_costs, "agent_dir" => catalog&.[]("agent_dir"),
        "instruction" => instruction.to_s, "entries" => entries
      }.tap { |prepared| prepared["signature"] = signature(prepared) }
    rescue ModelCandidatePool::Error
      raise Error, "the candidate pool could not be read"
    end

    # The production route-cost source: the task-scoped inputs file bound to
    # the current review (task record digest and artifact_root). Any binding
    # or credibility failure yields {} - cost stays unknown and quality
    # judgment continues; an explicitly injected route_costs argument (tests)
    # bypasses this entirely.
    def default_route_costs
      @route_cost_inputs&.build(scope: "review")
    rescue RouteCostInputs::Error
      nil
    end

    # The canonical selection-input material. It carries every substantive
    # input: the policy binding, the current calibration release, the pool, the
    # resolved catalog, the per-candidate identities and projected facts, the
    # explicit task requirements, the task context the policy would project and
    # the instruction. ObservationKey.normalize sorts keys and bounds strings,
    # so insertion order and oversized text never change the key, while a real
    # change in any of those inputs always does — including a changed task state
    # for an already explicit Root choice. Changed resource facts must also
    # invalidate the chosen order; the previous cost comparison is stale.
    def signature(prepared)
      Digest::SHA256.hexdigest(JSON.generate(
        ObservationKey.normalize(
          "version" => SIGNATURE_VERSION,
          "policy" => ModelQualityPolicy.binding,
          "release" => release_binding(prepared["release"]),
          "pool" => prepared["pool"],
          "catalog" => catalog_view(prepared["catalog"]),
          "identities" => prepared["identities"],
          "facts" => prepared["facts"],
          "route_costs" => prepared["route_costs"],
          "state" => ModelQualityPolicy.project_selection_state(quality_body(prepared, [])),
          "instruction" => prepared["instruction"],
          "excluded" => prepared["excluded"]
        )
      ))
    end

    def catalog_view(catalog)
      return nil unless catalog.is_a?(Hash)

      { "current" => catalog["current"].to_s, "agent_dir" => catalog["agent_dir"].to_s,
        "available" => Array(catalog["available"]).map(&:to_s).sort,
        "routes" => (catalog["routes"].is_a?(Hash) ? catalog["routes"].sort_by { |key, _| key.to_s }.to_h : {}),
        "limits" => (catalog["limits"].is_a?(Hash) ? catalog["limits"].sort_by { |key, _| key.to_s }.to_h : {}),
        "families" => (catalog["families"].is_a?(Hash) ? catalog["families"].sort_by { |key, _| key.to_s }.to_h : {}) }
    end

    # The reviewed calibration, or the injected one. An absent or unreadable
    # file is a downgrade, never an error: a runnable checker still starts under
    # pool order and the reason is recorded for Root.
    def current_release
      return [@release, @release_note] if @release_injected

      loaded = ModelQualityPolicy.load
      case loaded
      when Hash then [loaded, nil]
      when nil then [nil, nil]
      else [nil, loaded.to_s.slice(0, MAX_DETAIL_LENGTH)]
      end
    rescue StandardError => error
      [nil, "the calibration file could not be read (#{error.class})"]
    end

    # The full validated release document IS the binding: every field that can
    # activate or shape a positive ranking (versions, digests, model, provider,
    # thresholds, scope and the review metadata) rides the signature and the
    # recorded decision, so a changed review or revalidation never reuses an
    # old choice.
    def release_binding(release)
      release.is_a?(Hash) ? JSON.parse(JSON.generate(release)) : nil
    end

    # The four explicit identity fields for one catalog model. The billing route
    # is whatever the host resolved for that exact model; anything else is
    # unknown. reasoning is only ever the real declaration — today there is none,
    # so it stays "unknown" and is never filled from the model name or a
    # provider default.
    def identity_for(catalog, model)
      provider, id = model.to_s.split("/", 2)
      route = catalog.is_a?(Hash) && catalog["routes"].is_a?(Hash) ? catalog["routes"][model] : nil
      route = "unknown" unless BILLING_ROUTES.include?(route)
      { "provider" => provider.to_s, "model" => id.to_s, "reasoning" => "unknown", "billing_route" => route }
    end

    # Model requirements are explicit input from the task record, never guessed
    # from a model name and never defaulted to "all indices".
    def task_requirements(state)
      context = state.is_a?(Hash) ? state : {}
      context = context["task_context"] if context["task_context"].is_a?(Hash)
      return {} unless context.is_a?(Hash)

      unit = context["work_unit"]
      requirements = unit.is_a?(Hash) ? unit["model_requirements"] : nil
      requirements = context["model_requirements"] unless requirements.is_a?(Hash)
      requirements.is_a?(Hash) ? requirements : {}
    end

    # Projected facts per candidate. An unusable requirements block is dropped
    # (facts only) with a recorded reason instead of blocking a runnable checker.
    # The host's resolved limits for that exact model are passed through, so the
    # projection can say whether the actual route meets an explicit requirement —
    # a catalog row never stands in for the actual limit.
    def project_facts(identities, state, catalog)
      facts = facts_for(identities, task_requirements(state), catalog)
      failure = facts.values.filter_map { |fact| fact["projection_error"] }.first
      return [facts, nil] if failure.nil?

      [facts_for(identities, {}, catalog),
       "recorded model requirements were dropped (#{failure}); candidates were projected with facts only"]
    end

    def facts_for(identities, requirements, catalog)
      identities.to_h do |model, identity|
        [model, capability_facts(identity, requirements, execution_limits(catalog, model))]
      end
    end

    # The exact model's resolved execution limits, as the host reported them.
    # Anything else is nil (unknown) and never filled in from the model name or
    # a catalog row.
    def execution_limits(catalog, model)
      limits = catalog.is_a?(Hash) && catalog["limits"].is_a?(Hash) ? catalog["limits"][model] : nil
      limits.is_a?(Hash) ? limits : nil
    end

    def capability_facts(identity, requirements, limits)
      @facts.candidate_facts(identity: identity, task: requirements, project_root: @project_root,
                             execution_limits: limits)
    rescue ModelCapabilityFacts::Error => error
      # A projection that cannot be built is unknown facts, not a blocked
      # candidate: the model stays runnable and unscored.
      {
        "identity" => identity, "task" => nil,
        "catalog" => { "status" => "error", "question" => nil, "facts" => nil, "prior" => nil,
                       "provenance" => nil, "detail" => bounded_detail(error.message) },
        "precise_evidence" => { "status" => "error", "question" => nil, "entry" => nil,
                                "detail" => bounded_detail(error.message) },
        "eligibility" => nil, "execution_eligibility" => nil, "conflicts" => [], "contrasts" => [],
        "recommendation_hold" => false, "hold_reason" => nil, "projection_error" => bounded_detail(error.message)
      }
    end

    # Read-only evidence status for one exact identity. Same status vocabulary
    # and structural checks as the selection module's diagnostics, but keyed by
    # the identity Orbit actually resolved for this candidate, so a model with a
    # real billing route is never reported as if its facts were absent.
    def precise_status(identity, entries, now)
      return { "status" => "unknown", "detail" => "the evidence cache could not be read" } unless entries.is_a?(Array)

      exact = entries.select { |entry| stored_identity?(entry, identity) }
      if exact.empty?
        related = related_identities(entries, identity)
        detail = "no cached entry for this exact identity " \
                 "(reasoning: #{identity['reasoning']}, billing_route: #{identity['billing_route']})"
        detail = "#{detail}; the cache holds #{related.join(', ')} under provider #{identity['provider']}" unless related.empty?
        return { "status" => "absent", "detail" => detail }
      end
      return { "status" => "valid", "detail" => nil } if exact.any? { |entry| CheckerModelSelection.valid_evidence_entry?(entry, now) }

      expired = exact.filter_map { |entry| CheckerModelSelection.parse_timestamp(entry["valid_until"]) }
                     .select { |time| time <= now }.max
      if expired
        return { "status" => "expired", "detail" => "evidence for this exact identity expired #{expired.utc.iso8601}" }
      end

      unavailable = exact.find { |entry| entry["status"] == ModelEvidenceCache::STATUS_UNAVAILABLE }
      if unavailable
        reason = unavailable["reason"].to_s.strip
        reason = "no reason recorded" if reason.empty?
        return { "status" => "unavailable", "detail" => "reported unavailable: #{reason.slice(0, MAX_DETAIL_LENGTH)}" }
      end

      { "status" => "invalid", "detail" => "cached entries for this exact identity failed structural validation" }
    end

    def stored_identity?(entry, identity)
      entry.is_a?(Hash) && entry["provider"] == identity["provider"] && entry["model"] == identity["model"] &&
        entry["reasoning"] == identity["reasoning"] &&
        entry.fetch("billing_route", "unknown") == identity["billing_route"]
    end

    # Related cached identities under the same provider, with the candidate's own
    # model first: another reasoning or billing route of the same model is the
    # most likely reason the exact identity has no usable entry.
    def related_identities(entries, identity)
      same_model = []
      other_models = []
      entries.each do |entry|
        next unless entry.is_a?(Hash) && entry["provider"] == identity["provider"]
        next if stored_identity?(entry, identity)

        text = "#{identity['provider']}/#{entry['model']} (reasoning: #{entry.fetch('reasoning', 'default')}, " \
               "billing_route: #{entry.fetch('billing_route', 'unknown')})"
        target = entry["model"] == identity["model"] ? same_model : other_models
        target << text if target.length < MAX_RELATED_IDENTITIES && !target.include?(text)
      end
      same_model + other_models
    end

    def refresh_overview
      @overview.refresh(project_root: @project_root)
    rescue StandardError
      { "status" => "error" }
    end

    def judgment_candidate(prepared, model)
      entry = { "model" => model, "identity" => prepared.dig("identities", model),
                "capability_facts" => prepared.dig("facts", model) }
      if prepared["evidence"].key?(model)
        entry["evidence"] = prepared["evidence"][model]
      end
      if prepared["overview_priors"].key?(model)
        entry["model_overview_prior"] = prepared["overview_priors"][model]
      end

      entry
    end

    def overview_diagnostics
      @overview.status(project_root: @project_root)
    rescue StandardError
      { "status" => "unavailable" }
    end

    def reusable?(previous, prepared)
      return false unless previous.is_a?(Hash)
      return false if previous["source"] == "explicit"
      return false unless previous["version"] == CheckerModelSelection::DECISION_VERSION
      return false unless previous["signature"].is_a?(String) && previous["signature"] == prepared["signature"]

      model = previous["model"].to_s
      return false if model.empty?

      prepared["models"].include?(model) && !prepared["excluded"].include?(model)
    end

    def auto_select(prepared, selected_for)
      catalog = prepared["catalog"]
      unless catalog.is_a?(Hash)
        raise failed_selection(prepared, "the OMP session model catalog is unavailable",
                               detail: ["no OMP model can be verified without its current catalog"])
      end
      if prepared["models"].empty?
        raise failed_selection(prepared, "no unused OMP model is available in this session",
                               detail: prepared["excluded"].empty? ? [] : ["already tried: #{listed(prepared['excluded'])}"])
      end

      availability = begin
        @probe.call(prepared["models"], source_agent_dir: prepared["agent_dir"], source_project_dir: @project_root)
      rescue StandardError => error
        raise failed_selection(prepared, "OMP models could not be checked in the isolated profile (#{error.class})",
                               detail: ["candidates #{listed(prepared['models'])}; no model was proven runnable"])
      end
      if Array(availability["resolvable"]).empty? && prepared["choice_source"] != "explicit" &&
         prepared["preferred"].any?
        # The pool is a preference, not a permission boundary. Probe the
        # remaining OMP models only when no preferred model is runnable.
        fallback = prepared["available"] - prepared["preferred"] - prepared["excluded"]
        unless fallback.empty?
          extra = begin
            @probe.call(fallback, source_agent_dir: prepared["agent_dir"], source_project_dir: @project_root)
          rescue StandardError => error
            raise failed_selection(prepared, "OMP fallback models could not be checked (#{error.class})",
                                   detail: probe_lines(availability, prepared["models"]), availability: availability)
          end
          availability = { "resolvable" => Array(extra["resolvable"]),
                           "unresolvable" => Array(availability["unresolvable"]) + Array(extra["unresolvable"]) }
          prepared["models"] = fallback
        end
      end
      source = prepared["choice_source"] || (prepared["models"].any? { |model| prepared["pool"].include?(model) } &&
        Array(availability["resolvable"]).any? { |model| prepared["pool"].include?(model) } ?
        "candidate_pool" : "omp_session")

      evidence = prepared["evidence"]
      judged = prepared["models"].select do |candidate|
        (evidence.key?(candidate) || prepared["overview_priors"].key?(candidate)) &&
          Array(availability["resolvable"]).include?(candidate)
      end
      judgment = nil
      judgment_state = nil
      projected_state = nil
      judgment_error = nil
      gate_note = nil
      if judged.any?
        advisor = resolved_advisor
        if advisor
          judgment_state = quality_body(prepared, judged)
          projected_state = ModelQualityPolicy.project_selection_state(judgment_state)
          gate_note = judgment_gate(prepared, projected_state)
          if gate_note.nil?
            begin
              judgment = advisor.assess_checker_quality(
                state: judgment_state,
                candidates: judged.map { |candidate| judgment_candidate(prepared, candidate) }
              )
            rescue StandardError => error
              judgment_error = "JEV task-fit judgment failed (#{error.class})"
              judgment = error.judgment.merge("scores" => {}) if error.is_a?(JevAdvisor::Error)
            end
          end
        else
          judgment_error = "JEV task-fit judgment unavailable"
        end
      end

      scores = judgment ? judgment.fetch("scores") : {}
      quality = prepared["models"].to_h do |candidate|
        [candidate, { "source" => "jev:checker_task_fit", "score" => scores.dig(candidate, "quality"),
                      "identity" => prepared.dig("identities", candidate),
                      "recommendation_hold" => prepared.dig("facts", candidate, "recommendation_hold") == true }]
      end
      decision = CheckerModelSelection.choose(
        pool: prepared["models"], catalog: catalog, quality: quality,
        resolvable: availability.fetch("resolvable"),
        fit_scores: scores.transform_values { |score| score["quality"] },
        release: prepared["release"], state: projected_state || choose_state(prepared),
        judgment: judgment_receipt(judgment), route_costs: prepared["route_costs"]
      )
      if decision["model"].nil?
        raise failed_selection(prepared, "no unused runnable OMP checker model (#{decision['reason']})",
                               detail: probe_lines(availability, prepared["models"]),
                               judgment: judgment, judgment_state: judgment_state, judgment_error: judgment_error,
                               availability: availability)
      end

      chosen = decision["model"]
      selected_facts = prepared.dig("facts", chosen) || {}
      selected_evidence = evidence[chosen]
      selected_prior = prepared.dig("overview_priors", chosen)
      runnable = Array(availability["resolvable"])
      evidence_needed = prepared["models"].filter_map do |candidate|
        next unless runnable.include?(candidate) && !evidence.key?(candidate)
        next if source != "candidate_pool" && candidate != chosen

        status = prepared.dig("evidence_statuses", candidate)
        { "model" => candidate, "reasoning" => prepared.dig("identities", candidate, "reasoning"),
          "billing_route" => prepared.dig("identities", candidate, "billing_route"),
          "status" => status } if %w[absent expired invalid].include?(status)
      end
      unscored = prepared["models"] - scores.keys
      selection = decision.merge(
        "source" => source, "model" => chosen, "model_identity" => prepared.dig("identities", chosen),
        "quality_score" => scores.dig(chosen, "quality"),
        "source_agent_dir" => prepared["agent_dir"],
        "quality_basis" => selected_evidence ? "exact_model_evidence" : (selected_prior ? "model_overview_prior" : "unknown"),
        "quality_sources" => Array(selected_evidence&.[]("sources") || selected_prior&.[]("sources")).first(MAX_SOURCES),
        "quality_evidence_valid_until" => selected_evidence&.[]("valid_until"),
        "recommendation_hold" => selected_facts["recommendation_hold"] == true,
        "hold_reason" => selected_facts["hold_reason"],
        "model_overview_status" => selected_facts.dig("catalog", "status"),
        "model_overview_prior" => selected_prior,
        "model_overview_refresh" => @overview_refresh,
        "eligibility" => selected_facts["eligibility"],
        "execution_eligibility" => selected_facts["execution_eligibility"],
        "judgment_provider" => judgment&.[]("provider"), "judgment_model" => judgment&.[]("model"),
        "judgment_call_id" => judgment&.[]("call_id"), "judgment_status" => judgment&.[]("status"),
        "judgment_requested_model" => judgment&.[]("requested_model"),
        "question_set_version" => judgment&.[]("question_set_version"),
        "judgment_error" => judgment_error,
        "release" => release_binding(prepared["release"]),
        "route_cost_inputs" => prepared["route_costs"],
        "calibration_note" => [prepared["release_note"], gate_note].compact.join("; ").then { |note| note.empty? ? nil : note },
        "requirements_error" => prepared["requirements_error"],
        "task_fit_scores" => scores, "unscored_candidates" => unscored,
        "evidence_needed" => evidence_needed,
        "judgment_state" => judgment_state,
        # A startup JEV call precedes TaskRecord; retain its usage separately.
        "usage" => bounded_usage(judgment&.[]("usage")),
        "selected_for" => selected_for, "selected_at" => now_iso,
        "signature" => prepared["signature"]
      )
      [chosen, selection]
    end

    # The paid checker judgment runs only when a reviewed release could
    # actually activate on this task: structurally valid for the current
    # policy, scope matched by the real task profile, and the recorded
    # requirements usable. Otherwise the projected facts and the runnable
    # order stand on their own; no judgment field is fabricated.
    def judgment_gate(prepared, projected_state)
      if prepared["requirements_error"]
        return "checker task-fit judgment not paid for: #{prepared['requirements_error']}"
      end

      case ModelQualityPolicy.activation_block(release: prepared["release"], judgment: nil, state: projected_state)
      when "no_reviewed_release"
        "checker task-fit judgment not paid for: no reviewed release binds the current questions and input"
      when "task_profile_mismatch"
        "checker task-fit judgment not paid for: this task is outside the released profile"
      end
    end

    def resolved_advisor
      return @advisor if @advisor

      begin
        JevAdvisor.for_project(@project_root)
      rescue StandardError
        nil
      end
    end

    # The body handed to the judgment and to the policy: the actual task record
    # context, the effective instruction and the judged candidates, flat, so the
    # policy's own projection can derive the task profile from the record and
    # label the priors and exact facts. The advisor projects it before sending;
    # choose receives that same projection.
    def quality_body(prepared, judged)
      context = prepared["state"].is_a?(Hash) ? prepared["state"] : {}
      context.merge(
        "instruction" => prepared["instruction"].to_s,
        "candidates" => judged.map { |candidate| judgment_candidate(prepared, candidate) }
      )
    end

    def choose_state(prepared)
      ModelQualityPolicy.project_selection_state(quality_body(prepared, []))
    end

    # The actual judgment receipt. The model is whatever the service reported;
    # a missing actual model, a failure status or another question set never
    # activates a release, and the requested name is kept separate.
    def judgment_receipt(judgment)
      return nil unless judgment.is_a?(Hash)

      {
        "input_version" => judgment["input_version"],
        "status" => judgment["status"], "provider" => judgment["provider"],
        "model" => judgment["model"], "question_set_version" => judgment["question_set_version"],
        "call_id" => judgment["call_id"], "requested_model" => judgment["requested_model"]
      }
    end

    def bounded_usage(usage)
      return nil unless usage.is_a?(Hash)

      kept = usage.select { |key, value| key.is_a?(String) && !key.empty? && value.is_a?(Numeric) }
      return nil if kept.empty? || JSON.generate(kept).bytesize > MAX_USAGE_BYTES

      kept
    end

    # A start that fails before TaskRecord exists still needs an inspectable
    # judgment/probe trace. The local project log contains the actual bounded
    # state sent to JEV and its structured response, never a guessed score.
    def failed_selection(prepared, reason, detail:, judgment: nil, judgment_state: nil,
                         judgment_error: nil, availability: nil)
      error = undecided(reason, detail: detail)
      path = File.join(@project_root, ".orbit", "checker-selection-failures.jsonl")
      trace = {
        "at" => now_iso, "reason" => reason, "instruction" => prepared["instruction"],
        "pool" => prepared["pool"], "session_candidates" => prepared["models"],
        "identities" => prepared["identities"], "release" => release_binding(prepared["release"]),
        "question_set_version" => ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch("checker_quality"),
        "judgment_state" => judgment_state, "judgment" => judgment,
        "judgment_error" => judgment_error, "isolated_probe" => availability
      }
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write("#{JSON.generate(trace)}\n")
        file.flush
        file.fsync
      end
      Error.new("#{error.message}; selection trace: #{path}")
    rescue SystemCallError, JSON::GeneratorError => failure
      Error.new("#{error.message}; local selection trace could not be saved (#{failure.class})")
    end

    def undecided(reason, detail: [], extra: nil)
      parts = [reason]
      parts << "(#{detail.join('; ')})" unless detail.empty?
      parts << extra if extra
      parts << "check OMP model availability and isolated checker credentials; Root may select any resolvable OMP model"
      Error.new(parts.join("; "))
    end

    # Candidate lists in diagnostics are bounded; "+N more" keeps a large pool
    # from burying the instruction.
    def listed(models, cap = MAX_DIAGNOSTIC_MODELS)
      items = Array(models).first(cap).map(&:to_s)
      overflow = Array(models).length - items.length
      overflow.positive? ? "#{items.join(', ')} (+#{overflow} more)" : items.join(", ")
    end

    def probe_lines(availability, models)
      reasons = Array(availability.is_a?(Hash) ? availability["unresolvable"] : nil)
                  .each_with_object({}) { |item, out| out[item["model"]] = item["reason"].to_s if item.is_a?(Hash) && !item["reason"].to_s.empty? }
      Array(models).first(MAX_DIAGNOSTIC_MODELS).map do |model|
        reason = reasons[model]
        reason ? "#{model}: not resolvable in the isolated checker profile (#{reason.slice(0, 200)})" : "#{model}: resolvable"
      end
    end

    def stored_entries
      @evidence_cache.stored_entries
    rescue StandardError
      nil
    end

    def model_catalog
      return nil if @connection.nil?

      @connection.model_catalog
    rescue StandardError
      nil
    end

    def bounded_detail(text)
      text.to_s.strip.slice(0, MAX_DETAIL_LENGTH)
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
