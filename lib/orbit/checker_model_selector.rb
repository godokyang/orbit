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
  # decision undecided (raise) instead of silently using a pool-outside default.
  # Credential/catalog resolvability is never quality.
  #
  # A cheap `signature` (pool contents, session catalog, validated evidence and
  # the effective instruction) lets a caller reuse the previous decision without
  # another JEV call when nothing that can change it has changed. A changed pool
  # still affects the next check; an in-flight check never changes model (the
  # caller only reselects before starting a new one).
  class CheckerModelSelector
    # Startup argument errors keep the same class family the CLI already
    # handled, and every message ends with the explicit-model instruction.
    Error = Class.new(ArgumentError)

    QUALITY_THRESHOLD = 0.55
    TIME_FAST_THRESHOLD = 0.66
    TIME_MEDIUM_THRESHOLD = 0.33
    MAX_SOURCES = 3
    MAX_USAGE_BYTES = 512

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

    private

    def same_explicit?(previous, text)
      previous.is_a?(Hash) && previous["source"] == "explicit" && previous["model"] == text
    end

    def pinned_explicit?(previous)
      previous.is_a?(Hash) && previous["source"] == "explicit" && !previous["model"].to_s.empty?
    end

    def explicit_selection(model, selected_for)
      raise Error, "OMP review model must be provider/id from the session, --review-model, or ORBIT_REVIEW_MODEL" unless model.match?(OmpCheckRunner::MODEL_ID)

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
        []
      end
      evidence = CheckerModelSelection.cached_evidence(models: models, entries: entries, now: @clock.call)
      {
        "pool" => pool, "pool_empty" => false, "catalog" => catalog, "models" => models,
        "evidence" => evidence, "default_model" => nil, "instruction" => instruction.to_s,
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
      raise undecided("the OMP session model catalog is unavailable") unless catalog.is_a?(Hash)
      raise undecided("no candidate pool model is available in this session") if prepared["models"].empty?

      evidence = prepared["evidence"]
      judged = prepared["models"].select { |candidate| evidence.key?(candidate) }
      raise undecided("no candidate pool model has valid cached quality evidence") if judged.empty?

      advisor = resolved_advisor
      raise undecided("the JEV quality judgment is unavailable") if advisor.nil?

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
      raise undecided("no candidate pool model passed the JEV quality line") if quality.empty?

      time_cost = judged.each_with_object({}) do |candidate, out|
        tiers = { "time" => time_tier(scores.dig(candidate, "time")) }
        band = evidence.dig(candidate, "cost_tier", "band")
        tiers["cost"] = band if band
        out[candidate] = tiers
      end

      resolvable = begin
        @probe.call(quality.keys).fetch("resolvable")
      rescue StandardError => error
        raise undecided("qualified pool models could not be checked in the isolated profile (#{error.class})")
      end
      decision = CheckerModelSelection.choose(
        pool: prepared["pool"], catalog: catalog, quality: quality, resolvable: resolvable, time_cost: time_cost
      )
      raise undecided("no checker model could be selected from the candidate pool (#{decision['reason']})") if decision["model"].nil?

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

    def undecided(reason)
      Error.new("#{reason}; pass --review-model provider/id to choose explicitly")
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
