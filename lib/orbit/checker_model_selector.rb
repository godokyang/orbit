# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "checker_model_selection"
require_relative "jev_advisor"
require_relative "model_candidate_pool"
require_relative "model_evidence_cache"
require_relative "omp_check_runner"

module Orbit
  # ADR-009 checker-model selection, shared by `orbit start` (first check) and
  # TaskRuntime (before every later check).
  #
  # Selection rules are unchanged from the original CLI implementation:
  #
  #   * an explicit model (--review-model / ORBIT_REVIEW_MODEL) always wins,
  #     even outside the pool, and is recorded with an out-of-pool notice;
  #   * an empty pool keeps the existing session default;
  #   * a non-empty pool is intersected with the session catalog, each
  #     candidate's unexpired ModelEvidenceCache facts are judged for quality
  #     by JEV, then only qualified candidates are probed for isolated
  #     resolvability and ordered by time, coarse cost and family.
  #
  # Missing evidence, an unavailable service or nothing qualifying leave the
  # decision undecided (raise) instead of silently using a pool-outside
  # default; undecided errors carry per-candidate diagnostics that were
  # actually checked (ADR-009 2026-09-27 supplement). Credential/catalog
  # resolvability is never quality. `candidate_statuses` exposes the same
  # read-only per-candidate facts for the candidate UX without probing or
  # judging anything.
  class CheckerModelSelector
    # Startup argument errors keep the same class family the CLI already
    # handled, and every message ends with the explicit-model instruction.
    Error = Class.new(ArgumentError)

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
                   clock: nil)
      @connection = connection
      @project_root = project_root
      @pool = pool
      @evidence_cache = evidence_cache
      @advisor = advisor
      @probe = probe || ->(models) { OmpCheckRunner.probe_models(models: models) }
      @clock = clock || -> { Time.now.utc }
    end

    # Returns [model, selection]. `explicit` non-nil is frozen for the task;
    # `previous` is the last recorded review.selection (nil on the first call).
    def select(explicit:, instruction:, previous: nil, selected_for: "start")
      text = explicit.to_s.strip
      unless text.empty?
        return [previous["model"], previous] if same_explicit?(previous, text)

        return [text, explicit_selection(text, selected_for)]
      end
      if pinned_explicit?(previous)
        return [previous["model"], previous]
      end

      prepared = prepare(instruction)
      return [previous["model"], previous] if reusable?(previous, prepared)
      return empty_pool_selection(prepared, selected_for) if prepared["pool_empty"]

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
          "in_session" => available.nil? ? nil : Array(available).include?(model),
          "evidence_status" => evidence["status"],
          "quality" => "not_judged",
          "isolated_probe" => "not_probed"
        }
        entry["evidence_detail"] = evidence["detail"] if evidence["detail"]
        entry
      end
      report = {
        "pool_empty" => pool.empty?,
        "session_catalog" => @connection.nil? ? "not_provided" : (catalog.is_a?(Hash) ? "available" : "unavailable"),
        "evidence_cache" => entries.nil? ? "unavailable" : "available",
        "candidates" => candidates,
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

    def explicit_selection(model, selected_for)
      raise Error, "OMP review model must be provider/id from the session, --review-model, or ORBIT_REVIEW_MODEL" unless model.match?(OmpCheckRunner::MODEL_ID)
      if selected_for == "start"
        availability = begin
          @probe.call([model])
        rescue StandardError => error
          raise Error, "explicit review model could not be checked in the isolated profile (#{error.class}); choose another --review-model provider/id"
        end
        unless availability.is_a?(Hash) && Array(availability["resolvable"]).include?(model)
          failures = availability.is_a?(Hash) ? availability["unresolvable"] : nil
          reason = Array(failures).find { |item| item.is_a?(Hash) && item["model"] == model }
          detail = reason && reason["reason"].to_s.strip
          detail = "not resolvable in the isolated profile" if detail.nil? || detail.empty?
          raise Error, "explicit review model #{model} is unavailable (#{detail.slice(0, 200)}); choose another --review-model provider/id"
        end
      end

      pool = @pool.read
      in_pool = pool.empty? || pool.include?(model)
      selection = {
        "source" => "explicit", "model" => model, "in_pool" => in_pool,
        "version" => CheckerModelSelection::DECISION_VERSION,
        "selected_for" => selected_for, "selected_at" => now_iso
      }
      unless in_pool
        selection["notice"] = "explicit review model is outside the candidate pool"
        warn "orbit: explicit review model #{model} is outside the candidate pool; using it as given"
      end
      selection
    rescue ModelCandidatePool::Error
      raise Error, "the candidate pool could not be read"
    end

    def prepare(instruction)
      pool = @pool.read
      if pool.empty?
        default_model = begin
          @connection.configured_model.to_s.strip
        rescue StandardError
          ""
        end
        return {
          "pool" => pool, "pool_empty" => true, "catalog" => nil, "models" => [],
          "evidence" => {}, "default_model" => default_model, "instruction" => instruction.to_s,
          "signature" => signature(pool, nil, {}, instruction, default_model)
        }
      end

      catalog = begin
        @connection.model_catalog
      rescue StandardError
        nil
      end
      models = CheckerModelSelection.pool_candidates(pool: pool, catalog: catalog)
      entries = begin
        @evidence_cache.stored_entries
      rescue StandardError
        nil
      end
      # nil (unreadable) stays distinguishable from [] (empty): diagnostics
      # must report an unreadable cache as such, never as "absent" evidence.
      evidence = CheckerModelSelection.cached_evidence(models: models, entries: entries, now: @clock.call)
      {
        "pool" => pool, "pool_empty" => false, "catalog" => catalog, "models" => models,
        "evidence" => evidence, "default_model" => nil, "instruction" => instruction.to_s,
        # Raw entries feed the undecided diagnostics (absent/expired/unavailable
        # per exact identity); the judged `evidence` above keeps only valid
        # entries, which cannot distinguish why a candidate has none.
        "entries" => entries,
        "signature" => signature(pool, catalog, evidence, instruction, nil)
      }
    rescue ModelCandidatePool::Error
      raise Error, "the candidate pool could not be read"
    end

    def signature(pool, catalog, evidence, instruction, default_model)
      catalog_view =
        if catalog.is_a?(Hash)
          { "current" => catalog["current"].to_s,
            "available" => Array(catalog["available"]).map(&:to_s).sort,
            "families" => catalog["families"].is_a?(Hash) ? catalog["families"].sort_by { |key, _| key.to_s }.to_h : {} }
        end
      Digest::SHA256.hexdigest(JSON.generate([
        "orbit-checker-selection-signature-v1",
        pool, catalog_view, evidence.sort_by { |key, _| key.to_s }.to_h,
        default_model.to_s, instruction.to_s.scrub
      ]))
    end

    def reusable?(previous, prepared)
      return false unless previous.is_a?(Hash)
      return false if previous["source"] == "explicit"
      return false unless previous["signature"].is_a?(String) && previous["signature"] == prepared["signature"]

      model = previous["model"].to_s
      return false if model.empty?

      prepared["pool_empty"] || prepared["models"].include?(model)
    end

    def empty_pool_selection(prepared, selected_for)
      model = prepared["default_model"].to_s
      unless model.match?(OmpCheckRunner::MODEL_ID)
        raise Error, "OMP review model must be provider/id from the session, --review-model, or ORBIT_REVIEW_MODEL"
      end

      [model, { "source" => "session_default", "model" => model,
                "version" => CheckerModelSelection::DECISION_VERSION,
                "selected_for" => selected_for, "selected_at" => now_iso,
                "signature" => prepared["signature"] }]
    end

    def auto_select(prepared, selected_for)
      catalog = prepared["catalog"]
      unless catalog.is_a?(Hash)
        raise undecided("the OMP session model catalog is unavailable",
                        detail: ["pool candidates #{listed(prepared['pool'])} were not checked against the session catalog"])
      end
      if prepared["models"].empty?
        raise undecided("no candidate pool model is available in this session",
                        detail: ["not in this session catalog: #{listed(prepared['pool'])}"])
      end

      evidence = prepared["evidence"]
      judged = prepared["models"].select { |candidate| evidence.key?(candidate) }
      if judged.empty?
        if prepared["entries"].nil?
          raise undecided("the model evidence cache could not be read",
                          detail: ["candidates #{listed(prepared['models'])} were not evidence-checked"])
        end
        # Per-candidate precise reasons instead of one collapsed "no
        # evidence": absent for the exact identity (with the near-variant
        # identities the cache actually holds), expired, reported
        # unavailable, or structurally invalid.
        raise undecided("no candidate pool model has valid cached quality evidence",
                        detail: evidence_lines(prepared["models"], prepared["entries"]),
                        extra: "submit first-hand facts with `orbit model-evidence --file FILE|-` for the exact identities above")
      end

      advisor = resolved_advisor
      raise undecided("the JEV quality judgment is unavailable",
                      detail: ["evidence-backed candidates ready: #{listed(judged)}"]) if advisor.nil?


      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      judgment = begin
        advisor.assess_checker_quality(
          state: quality_state(prepared, evidence, judged),
          candidates: judged.map { |candidate| { "model" => candidate, "evidence" => evidence[candidate] } }
        )
      rescue StandardError => error
        raise undecided("the JEV quality judgment failed (#{error.class})")
      end
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)

      scores = judgment.fetch("scores")
      quality = scores.select { |_candidate, score| score["quality"].to_f >= QUALITY_THRESHOLD }
                      .to_h { |candidate, score| [candidate, { "verdict" => "qualified", "source" => "jev:checker_quality", "score" => score["quality"] }] }
      if quality.empty?
        raise undecided("no candidate pool model passed the JEV quality line",
                        detail: judged.map { |candidate| "#{candidate} scored #{scores.dig(candidate, 'quality')} (threshold #{QUALITY_THRESHOLD})" })
      end

      time_cost = judged.each_with_object({}) do |candidate, out|
        tiers = { "time" => time_tier(scores.dig(candidate, "time")) }
        band = evidence.dig(candidate, "cost_tier", "band")
        tiers["cost"] = band if band
        out[candidate] = tiers
      end

      availability = begin
        @probe.call(quality.keys)
      rescue StandardError => error
        raise undecided("qualified pool models could not be checked in the isolated profile (#{error.class})",
                        detail: ["quality-qualified: #{listed(quality.keys)}"])
      end
      resolvable = availability.fetch("resolvable")
      decision = CheckerModelSelection.choose(
        pool: prepared["pool"], catalog: catalog, quality: quality, resolvable: resolvable, time_cost: time_cost
      )
      if decision["model"].nil?
        raise undecided("no checker model could be selected from the candidate pool (#{decision['reason']})",
                        detail: probe_lines(availability, quality.keys))
      end

      chosen = decision["model"]
      selected_evidence = evidence.fetch(chosen)
      [chosen, decision.merge(
        "source" => "candidate_pool",
        "quality_score" => quality.fetch(chosen)["score"],
        "time_score" => scores.dig(chosen, "time"),
        "time_tier" => time_cost.dig(chosen, "time"),
        "cost_tier" => evidence.dig(chosen, "cost_tier"),
        "quality_sources" => Array(selected_evidence["sources"]).first(MAX_SOURCES),
        "quality_evidence_valid_until" => selected_evidence["valid_until"],
        "quality_elapsed_seconds" => elapsed,
        "judgment_provider" => judgment["provider"],
        "judgment_model" => judgment["model"],
        "question_set_version" => judgment["question_set_version"],
        # Recorded for audit only: this JEV call runs before TaskRecord exists
        # or outside the runtime's own usage buckets, so it is not part of the
        # task's jev_stage1/jev_stage2/check_tokens aggregates (see the debt
        # ledger); task-wide token totals do not include it.
        "usage" => bounded_usage(judgment["usage"]),
        "selected_for" => selected_for, "selected_at" => now_iso,
        "signature" => prepared["signature"]
      )]
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
    def quality_state(prepared, evidence, judged)
      {
        "instruction" => prepared["instruction"].to_s,
        "candidates" => judged.map { |candidate| { "model" => candidate, "evidence" => evidence[candidate] } }
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

    # `detail` lines and `extra` next steps keep the undecided error
    # actionable: per-candidate reasons that were actually checked, the
    # evidence submission path when evidence is the blocker, and the explicit
    # model instruction every undecided error ends with (ADR-009 2026-09-27
    # supplement). One line: the message reaches Root through the start error,
    # the blocked-state reason and checker notifications.
    def undecided(reason, detail: [], extra: nil)
      parts = [reason]
      parts << "(#{detail.join('; ')})" unless detail.empty?
      parts << extra if extra
      parts << "pass --review-model provider/id to choose explicitly"
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
