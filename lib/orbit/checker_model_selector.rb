# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "checker_model_selection"
require_relative "jev_advisor"
require_relative "model_candidate_pool"
require_relative "model_evidence_cache"
require_relative "openrouter_model_overview"
require_relative "omp_check_runner"

module Orbit
  # Shared by start and every subsequent independent check. OMP supplies
  # model availability; the pool is preferred, not a permission boundary.
  # JEV task-fit ranks candidates with verified facts. Low or unknown fit
  # never turns a runnable model into an authorization failure.
  class CheckerModelSelector
    Error = Class.new(ArgumentError)
    # A preference boundary only; a lower score never forbids a runnable pool
    # model from doing a real independent check.

    QUALITY_THRESHOLD = 0.55
    TIME_FAST_THRESHOLD = 0.66
    TIME_MEDIUM_THRESHOLD = 0.33
    MAX_SOURCES = 3
    MAX_USAGE_BYTES = 512
    # Per-candidate diagnostics list at most this many models; a larger pool
    # is summarized with "+N more" instead of burying the next-step text.
    MAX_DIAGNOSTIC_MODELS = 8

    def initialize(connection:, project_root:, pool: ModelCandidatePool.new,
                   evidence_cache: ModelEvidenceCache.new, advisor: nil, probe: nil,
                   clock: nil, overview: nil)
      @connection = connection
      @project_root = project_root
      @pool = pool
      @evidence_cache = evidence_cache
      @advisor = advisor
      @overview = overview || OpenRouterModelOverview.new
      @probe = probe || ->(models, source_agent_dir:, source_project_dir:) {
        OmpCheckRunner.probe_models(models: models, source_agent_dir: source_agent_dir,
                                    source_project_dir: source_project_dir)
      }
      @clock = clock || -> { Time.now.utc }
    end

    # `excluded` contains models whose real check failed on this input and
    # artifact version. An explicit Root choice is pinned until it fails.
    def select(explicit:, instruction:, previous: nil, selected_for: "start", excluded: [])
      # The only network opportunity is before the selection/Jev path. A
      # failed optional refresh never prevents a runnable checker from starting.
      @overview_refresh = refresh_overview
      excluded = Array(excluded).map(&:to_s).uniq
      text = explicit.to_s.strip
      if !text.empty? && !excluded.include?(text)
        return [previous["model"], previous] if same_explicit?(previous, text)

        return explicit_selection(text, instruction, selected_for)
      end
      if pinned_explicit?(previous) && !excluded.include?(previous["model"])
        return [previous["model"], previous]
      end

      prepared = prepare(instruction, excluded: excluded)
      return [previous["model"], previous] if reusable?(previous, prepared)

      auto_select(prepared, selected_for)
    end

    # Read-only, side-effect-free per-candidate diagnostics for the candidate
    # UX (`orbit model-status`, the /orbit-models surface and undecided
    # errors): pool membership in the current session catalog and the cached
    # evidence status per exact identity. It never probes the isolated
    # checker profile and never calls JEV — candidates are only probed and
    # judged when a selection is actually attempted — so unjudged fields are
    # reported as "not_judged"/"not_probed" instead of a guess. An unreadable
    # cache is reported as such, never as "absent".
    def candidate_statuses
      pool = @pool.read
      entries = begin
        @evidence_cache.stored_entries
      rescue StandardError
        nil
      end
      now = @clock.call
      catalog = if @connection.nil?
                  nil
                else
                  begin
                    @connection.model_catalog
                  rescue StandardError
                    nil
                  end
                end
      available = catalog.is_a?(Hash) ? catalog["available"] : nil
      candidates = pool.map do |model|
        evidence =
          if entries.nil?
            { "status" => "unknown", "detail" => "the evidence cache could not be read" }
          else
            CheckerModelSelection.evidence_status(model: model, entries: entries, now: now)
          end
        entry = {
          "model" => model,
          "reasoning" => "unknown",
          "billing_route" => "unknown",
          "in_session" => available.nil? ? nil : Array(available).include?(model),
          "evidence_status" => evidence["status"],
          "quality" => "not_judged",
          "isolated_probe" => "not_probed"
        }
        entry["evidence_detail"] = evidence["detail"] if evidence["detail"]
        overview = overview_state(model)
        entry["model_overview"] = overview["status"]
        entry["model_overview_facts"] = overview["facts"] if overview["facts"]
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

    def same_explicit?(previous, text)
      previous.is_a?(Hash) && previous["source"] == "explicit" && previous["model"] == text
    end

    def pinned_explicit?(previous)
      previous.is_a?(Hash) && previous["source"] == "explicit" && !previous["model"].to_s.empty?
    end

    def explicit_selection(model, instruction, selected_for)
      raise Error, "OMP review model must be provider/id" unless model.match?(OmpCheckRunner::MODEL_ID)

      prepared = prepare(instruction)
      unless Array(prepared.dig("catalog", "available")).include?(model)
        raise Error, "Root-selected review model #{model} is not available in this OMP session"
      end
      prepared["models"] = [model]
      prepared["choice_source"] = "explicit"
      prepared["signature"] = signature(prepared["pool"], prepared["catalog"], prepared["evidence"],
                                         instruction, prepared["evidence_statuses"], [model],
                                         prepared["overview_states"])
      selected, selection = auto_select(prepared, selected_for)
      selection["in_pool"] = prepared["pool"].include?(model)
      [selected, selection]
    end

    def prepare(instruction, excluded: [])
      pool = @pool.read
      catalog = begin
        @connection.model_catalog
      rescue StandardError
        nil
      end
      available = Array(catalog&.[]("available")).select { |model| model.is_a?(String) &&
        model.match?(OmpCheckRunner::MODEL_ID) }.uniq
      current = catalog&.[]("current")
      available = [current, *available.reject { |model| model == current }] if available.include?(current)
      preferred = pool.select { |model| available.include?(model) && !excluded.include?(model) }
      models = preferred.empty? ? available.reject { |model| excluded.include?(model) } : preferred
      entries = begin
        @evidence_cache.stored_entries
      rescue StandardError
        nil
      end
      checked_at = @clock.call
      evidence = CheckerModelSelection.cached_evidence(models: available, entries: entries, now: checked_at)
      evidence_statuses = available.to_h do |model|
        [model, entries.is_a?(Array) ?
          CheckerModelSelection.evidence_status(model: model, entries: entries, now: checked_at)["status"] : "unknown"]
      end
      overview_states = models.to_h { |model| [model, overview_state(model)] }
      overview_priors = overview_states.each_with_object({}) do |(model, state), out|
        out[model] = state["prior"] if !evidence.key?(model) && state["status"] == "fresh" &&
                                       state["prior"].is_a?(Hash)
      end
      {
        "pool" => pool, "catalog" => catalog, "models" => models, "preferred" => preferred,
        "available" => available, "excluded" => excluded, "evidence" => evidence,
        "overview_states" => overview_states, "overview_priors" => overview_priors,
        "agent_dir" => catalog&.[]("agent_dir"),
        "instruction" => instruction.to_s, "entries" => entries, "evidence_statuses" => evidence_statuses,
        "signature" => signature(pool, catalog, evidence, instruction, evidence_statuses, excluded, overview_states)
      }
    rescue ModelCandidatePool::Error
      raise Error, "the candidate pool could not be read"
    end

    def signature(pool, catalog, evidence, instruction, evidence_statuses = {}, excluded = [], overview_states = {})
      catalog_view =
        if catalog.is_a?(Hash)
          { "current" => catalog["current"].to_s,
            "agent_dir" => catalog["agent_dir"].to_s,
            "available" => Array(catalog["available"]).map(&:to_s).sort,
            "families" => catalog["families"].is_a?(Hash) ? catalog["families"].sort_by { |key, _| key.to_s }.to_h : {} }
        end
      Digest::SHA256.hexdigest(JSON.generate([
        "orbit-checker-selection-signature-v5",
        pool, catalog_view, evidence.sort_by { |key, _| key.to_s }.to_h,
        overview_states.sort_by { |key, _| key.to_s }.to_h,
        evidence_statuses, instruction.to_s.scrub, excluded.sort
      ]))
    end

    def refresh_overview
      @overview.refresh(project_root: @project_root)
    rescue StandardError
      { "status" => "error" }
    end

    def overview_state(model)
      @overview.lookup(model: model, reasoning: "unknown", billing_route: "unknown",
                       project_root: @project_root)
    rescue StandardError
      { "status" => "unavailable" }
    end

    def judgment_candidate(prepared, model)
      entry = { "model" => model }
      if prepared["evidence"].key?(model)
        entry["evidence"] = prepared["evidence"][model]
      else
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
          fallback.each do |model|
            state = overview_state(model)
            prepared["overview_states"][model] = state
            if !prepared["evidence"].key?(model) && state["status"] == "fresh" && state["prior"].is_a?(Hash)
              prepared["overview_priors"][model] = state["prior"]
            end
          end
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
      judgment_error = nil
      elapsed = nil
      if judged.any?
        advisor = resolved_advisor
        if advisor
          judgment_state = quality_state(prepared, judged)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            judgment = advisor.assess_checker_quality(
              state: judgment_state,
              candidates: judged.map { |candidate| judgment_candidate(prepared, candidate) }
            )
          rescue StandardError => error
            judgment_error = "JEV task-fit judgment failed (#{error.class})"
            judgment = error.judgment.merge("scores" => {}) if error.is_a?(JevAdvisor::Error)
          ensure
            elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
          end
        else
          judgment_error = "JEV task-fit judgment unavailable"
        end
      end

      scores = judgment ? judgment.fetch("scores") : {}
      quality = scores.each_with_object({}) do |(candidate, score), out|
        # A model-level benchmark may rank uncertain checkers, but cannot on
        # its own verify this OMP route's quality above the exact-fact line.
        next unless evidence.key?(candidate) && score["quality"].to_f >= QUALITY_THRESHOLD

        out[candidate] = { "verdict" => "qualified", "source" => "jev:checker_task_fit",
                           "score" => score["quality"] }
      end
      time_cost = judged.each_with_object({}) do |candidate, out|
        next unless scores.key?(candidate) && evidence.key?(candidate)

        tiers = {}
        tiers["time"] = time_tier(scores.dig(candidate, "time")) if scores.dig(candidate, "time")
        band = evidence.dig(candidate, "cost_tier", "band")
        tiers["cost"] = band if band
        out[candidate] = tiers unless tiers.empty?
      end
      decision = CheckerModelSelection.choose(
        pool: prepared["models"], catalog: catalog, quality: quality,
        resolvable: availability.fetch("resolvable"), time_cost: time_cost,
        fit_scores: scores.transform_values { |score| score["quality"] }
      )
      if decision["model"].nil?
        raise failed_selection(prepared, "no unused runnable OMP checker model (#{decision['reason']})",
                               detail: probe_lines(availability, prepared["models"]),
                               judgment: judgment, judgment_state: judgment_state, judgment_error: judgment_error,
                               availability: availability)
      end

      chosen = decision["model"]
      selected_evidence = evidence[chosen]
      selected_prior = prepared["overview_priors"][chosen]
      runnable = Array(availability["resolvable"])
      evidence_needed = prepared["models"].filter_map do |candidate|
        next unless runnable.include?(candidate) && !evidence.key?(candidate)
        next if source != "candidate_pool" && candidate != chosen

        status = prepared["evidence_statuses"][candidate]
        { "model" => candidate, "reasoning" => "unknown", "billing_route" => "unknown",
          "status" => status } if %w[absent expired invalid].include?(status)
      end
      unscored = prepared["models"] - scores.keys
      selection = decision.merge(
        "source" => source, "model" => chosen, "quality_score" => scores.dig(chosen, "quality"),
        "source_agent_dir" => prepared["agent_dir"],
        "time_score" => selected_evidence && scores.dig(chosen, "time"), "time_tier" => time_cost.dig(chosen, "time"),
        "cost_tier" => evidence.dig(chosen, "cost_tier"),
        "quality_basis" => selected_evidence ? "exact_model_evidence" : (selected_prior ? "model_overview_prior" : "unknown"),
        "quality_sources" => Array(selected_evidence&.[]("sources") || selected_prior&.[]("sources")).first(MAX_SOURCES),
        "quality_evidence_valid_until" => selected_evidence&.[]("valid_until"),
        "model_overview_status" => prepared.dig("overview_states", chosen, "status"),
        "model_overview_prior" => selected_prior,
        "model_overview_refresh" => @overview_refresh,
        "quality_elapsed_seconds" => elapsed,
        "judgment_provider" => judgment&.[]("provider"), "judgment_model" => judgment&.[]("model"),
        "question_set_version" => judgment_state && JevAdvisor::QUESTION_SET_VERSIONS.fetch("checker_quality"),
        "judgment_error" => judgment_error,
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

    def resolved_advisor
      return @advisor if @advisor

      begin
        JevAdvisor.for_project(@project_root)
      rescue StandardError
        nil
      end
    end

    # The original instruction plus the full candidate evidence is passed
    # complete; the contract forbids compressing the requirement, and a
    # silently truncated task text would make JEV judge the wrong task.
    def quality_state(prepared, judged)
      {
        "instruction" => prepared["instruction"].to_s,
        "candidates" => judged.map { |candidate| judgment_candidate(prepared, candidate) }
      }
    end

    def time_tier(score)
      value = score.to_f
      return "fast" if value >= TIME_FAST_THRESHOLD
      return "medium" if value >= TIME_MEDIUM_THRESHOLD

      "slow"
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
        "question_set_version" => judgment_state && JevAdvisor::QUESTION_SET_VERSIONS.fetch("checker_quality"),
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

    def evidence_lines(models, entries)
      now = @clock.call
      lines = Array(models).first(MAX_DIAGNOSTIC_MODELS).map do |model|
        status = CheckerModelSelection.evidence_status(model: model, entries: entries, now: now)
        detail = status["detail"].to_s.strip
        detail.empty? ? "#{model}: #{status['status']}" : "#{model}: #{status['status']} (#{detail})"
      end
      overflow = Array(models).length - lines.length
      lines << "+#{overflow} more" if overflow.positive?
      lines
    end

    def probe_lines(availability, models)
      reasons = Array(availability.is_a?(Hash) ? availability["unresolvable"] : nil)
                  .each_with_object({}) { |item, out| out[item["model"]] = item["reason"].to_s if item.is_a?(Hash) && !item["reason"].to_s.empty? }
      Array(models).first(MAX_DIAGNOSTIC_MODELS).map do |model|
        reason = reasons[model]
        reason ? "#{model}: not resolvable in the isolated checker profile (#{reason.slice(0, 200)})" : "#{model}: resolvable"
      end
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
