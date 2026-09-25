# frozen_string_literal: true

require "time"
require "uri"

module Orbit
  # Pure checker-model selection for ADR-009.
  #
  # Given the user's long-lived candidate pool, the current OMP session catalog,
  # the isolated checker's resolve-only probe result, caller-supplied quality
  # verdicts and optional time/cost tiers, decide the model for the next
  # independent check.
  #
  # Order of narrowing (ADR-009 §3/§4):
  #
  #   1. pool ∩ current session catalog;
  #   2. must have a verifiable quality verdict (the quality line comes first);
  #   3. must resolve in the checker's isolated profile;
  #   4. among the survivors, prefer the best available end-to-end time tier,
  #      then the coarse cost tier, then a different model family as a same-level
  #      preference, then pool order.
  #
  # Credential/catalog resolvability is not quality. A model with no verifiable
  # quality verdict stays "待评估" and is never auto-picked; if nothing passes
  # the quality gate the decision is undecided and the caller must have Root
  # specify a model explicitly. The module never fabricates quality, time or
  # cost facts; when time/cost tiers are missing it records the gap instead.
  module CheckerModelSelection
    DECISION_VERSION = "orbit-checker-selection-v1"

    NO_TIME_COST_EVIDENCE = "no time/cost facts were available and none were invented"

    # Bounded evidence handed to the JEV quality judgment. ModelEvidenceCache
    # validates every field at submission time and caps an entry at MAX_METRICS
    # (24), but `stored_entries` reads raw JSON and `lookup` re-checks only
    # identity and expiry. A hand-edited cache file could therefore present a
    # source-less or value-less entry as "evidence". The selector is what hands
    # facts to JEV, so it re-applies the cache's structural rules here and drops
    # any entry that fails; the model then stays undecided. Actual entries use
    # names such as `quality_reasoning`, `swe_bench_pro`, `code_arena_rank` and
    # `local_sample_latency_ms`, so every validated metric is passed through
    # rather than filtered by a guessed prefix allowlist.
    EVIDENCE_MAX_SOURCES = 5
    EVIDENCE_MAX_METRICS = 24
    EVIDENCE_MAX_URL_LENGTH = 2048
    EVIDENCE_MAX_METRIC_NAME_LENGTH = 64
    EVIDENCE_CLOCK_SKEW_SECONDS = 300
    RESERVED_METRIC_NAMESPACE = "comparison"
    EVIDENCE_METRIC_NAME_PATTERN = /\A[A-Za-z][A-Za-z0-9_.-]*\z/
    EVIDENCE_TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
    EVIDENCE_CONTROL_CHARS = /[\x00-\x1F\x7F]/

    COST_RANK = { "low" => 0, "medium" => 1, "high" => 2 }.freeze
    TIME_RANK = { "fast" => 0, "medium" => 1, "slow" => 2 }.freeze

    module_function

    # Ordered pool identifiers that are also present in the session catalog.
    # Returns [] when the catalog is unavailable, so a non-empty pool is never
    # silently matched against a guess.
    def pool_candidates(pool:, catalog:)
      return [] unless catalog.is_a?(Hash)

      available = normalize(catalog["available"])
      normalize(pool).select { |model| available.include?(model) }
    end

    # pool ∩ catalog ∩ quality-qualified. This is the quality line: anything
    # without a verifiable verdict is excluded and stays "待评估".
    def qualified_candidates(pool:, catalog:, quality:)
      qualified = qualified_models(quality)
      pool_candidates(pool: pool, catalog: catalog).select { |model| qualified.include?(model) }
    end

    # Bounded, per-candidate cache evidence for the JEV quality judgment. Only
    # entries that match the exact provider/model and pass the structural rules
    # below (valid status, timestamps, sources and metrics) are used; the newest
    # retrieved_at wins. Returns { model => bounded evidence }. It never invents
    # facts and never reads or returns credentials.
    def cached_evidence(models:, entries:, now:, max_sources: EVIDENCE_MAX_SOURCES, max_metrics: EVIDENCE_MAX_METRICS)
      return {} unless entries.is_a?(Array)

      normalize(models).each_with_object({}) do |model, out|
        provider, id = model.split("/", 2)
        candidates = entries.select do |entry|
          entry.is_a?(Hash) && entry["provider"].to_s == provider && entry["model"].to_s == id &&
            valid_evidence_entry?(entry, now)
        end
        next if candidates.empty?

        newest = candidates.max_by { |entry| entry["retrieved_at"].to_s }
        out[model] = bound_entry(newest, max_sources, max_metrics)
      end
    end

    # pool: ordered provider/id strings from ModelCandidatePool#read.
    # catalog: { "current" =>, "available" => [...], "families" => {id=>family} } or nil.
    # quality: Hash of provider/id => verdict entry, or nil.
    # resolvable: provider/id strings the isolated probe resolved.
    # time_cost: optional Hash model => { "time" =>, "cost" => } coarse tiers.
    def choose(pool:, catalog:, quality:, resolvable:, time_cost: nil)
      ordered = normalize(pool)
      return undecided("empty_pool") if ordered.empty?
      return undecided("session_catalog_unavailable") unless catalog.is_a?(Hash)

      in_session = pool_candidates(pool: ordered, catalog: catalog)
      return undecided("no_pool_model_in_session") if in_session.empty?

      qualified = qualified_candidates(pool: ordered, catalog: catalog, quality: quality)
      return undecided("no_verifiable_quality_evidence") if qualified.empty?

      resolved = normalize(resolvable)
      eligible = qualified.select { |model| resolved.include?(model) }
      return undecided("qualified_pool_models_unresolvable_in_checker") if eligible.empty?

      families = catalog["families"].is_a?(Hash) ? catalog["families"] : {}
      writing_family = families[catalog["current"].to_s.strip].to_s.strip
      cross_candidates = eligible.select do |model|
        family = families[model].to_s.strip
        !writing_family.empty? && !family.empty? && family != writing_family
      end
      chosen = order_by_time_cost(eligible, families, writing_family, time_cost).first
      chosen_family = families[chosen].to_s.strip
      chosen_cross = !writing_family.empty? && !chosen_family.empty? && chosen_family != writing_family
      basis = if chosen_cross
                "different_family"
              elsif !cross_candidates.empty?
                "faster_or_cheaper_same_family"
              elsif writing_family.empty?
                "pool_order_writing_family_unknown"
              else
                "pool_order_no_other_family"
              end
      {
        "model" => chosen,
        "reason" => "#{basis}: selected a quality-qualified resolvable pool model; #{ordering_note(eligible, time_cost)}",
        "basis" => basis, "candidates" => eligible,
        "evidence_gap" => time_cost_gap(eligible, time_cost), "version" => DECISION_VERSION
      }
    end

    # A model qualifies only with an explicit, sourced verdict. Credentials,
    # catalog membership and an anonymous id are not quality evidence.
    def qualified_models(quality)
      return [] unless quality.is_a?(Hash)

      quality.filter_map do |model, entry|
        id = model.to_s.strip
        id if !id.empty? && qualification?(entry)
      end
    end

    def qualification?(entry)
      return false unless entry.is_a?(Hash)
      return false if entry["source"].to_s.strip.empty?

      entry["qualified"] == true || entry["verdict"].to_s == "qualified"
    end

    # ADR-009 order after the quality line: end-to-end time first, then coarse
    # cost, then a different model family as a same-level preference, then the
    # user's pool order. A lower time/cost rank is better; missing tiers sort
    # last but never remove a quality-qualified candidate.
    def order_by_time_cost(eligible, families, writing_family, time_cost)
      index = eligible.each_with_index.to_h
      eligible.sort_by.with_index do |model, position|
        tiers = time_cost.is_a?(Hash) && time_cost[model].is_a?(Hash) ? time_cost[model] : {}
        family = families[model].to_s.strip
        family_rank = !writing_family.empty? && !family.empty? && family != writing_family ? 0 : 1
        [TIME_RANK.fetch(tiers["time"], 9), COST_RANK.fetch(tiers["cost"], 9), family_rank, index[model] || position]
      end
    end

    # The reason must describe the evidence actually used: complete time and
    # cost tiers, a partial set, or none at all (never claiming facts that were
    # not supplied).
    def ordering_note(eligible, time_cost)
      return NO_TIME_COST_EVIDENCE unless time_cost.is_a?(Hash) && !time_cost.empty?

      times = eligible.count { |model| time_cost[model].is_a?(Hash) && time_cost[model]["time"] }
      costs = eligible.count { |model| time_cost[model].is_a?(Hash) && time_cost[model]["cost"] }
      return "ordered by end-to-end time then coarse cost" if times == eligible.length && costs == eligible.length
      return "ordered by end-to-end time; no coarse cost tiers were available" if times == eligible.length && costs.zero?

      "ordered by end-to-end time then coarse cost where known " \
        "(#{times} of #{eligible.length} had time, #{costs} had cost)"
    end

    def time_cost_gap(eligible, time_cost)
      unless time_cost.is_a?(Hash)
        return "no time/cost evidence for #{eligible.length} of #{eligible.length} qualified candidates"
      end

      missing = eligible.count do |model|
        tiers = time_cost[model]
        !tiers.is_a?(Hash) || tiers["time"].nil? || tiers["cost"].nil?
      end
      return nil if missing.zero?

      "time or cost evidence missing for #{missing} of #{eligible.length} qualified candidates"
    end

    # Mirror ModelEvidenceCache's submission-time rules for an entry with
    # status "evidence". A hand-edited cache entry that fails any rule is
    # dropped whole, so JEV never receives facts that were not verified.
    def valid_evidence_entry?(entry, now)
      return false unless entry.is_a?(Hash) && entry["status"] == "evidence"

      retrieved_at = parse_timestamp(entry["retrieved_at"])
      return false if retrieved_at.nil? || retrieved_at > now + EVIDENCE_CLOCK_SKEW_SECONDS

      valid_until = parse_timestamp(entry["valid_until"])
      return false if valid_until.nil? || valid_until <= retrieved_at || valid_until <= now

      valid_sources?(entry["sources"]) && valid_metrics?(entry["metrics"]) && valid_cost_tier?(entry["cost_tier"])
    end

    # The optional coarse tier must be absent or a structurally valid
    # {band, confidence, basis}; anything else is dropped with the entry so a
    # hand-edited tier never reaches ordering.
    def valid_cost_tier?(tier)
      return true if tier.nil?
      return false unless tier.is_a?(Hash)

      valid_cost_band?(tier["band"]) && valid_cost_band?(tier["confidence"]) && !tier["basis"].to_s.strip.empty?
    end

    def valid_cost_band?(value)
      %w[low medium high].include?(value.to_s.strip)
    end

    def parse_timestamp(value)
      return nil unless value.is_a?(String) && value.match?(EVIDENCE_TIMESTAMP_PATTERN)

      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def valid_sources?(value)
      return false unless value.is_a?(Array) && value.length.between?(1, EVIDENCE_MAX_SOURCES)

      value.all? { |url| valid_source?(url) }
    end

    def valid_source?(value)
      text = value.to_s.strip
      return false unless text.length.between?(1, EVIDENCE_MAX_URL_LENGTH) && !text.match?(EVIDENCE_CONTROL_CHARS)

      parsed =
        begin
          URI.parse(text)
        rescue URI::InvalidURIError
          nil
        end
      parsed.is_a?(URI::HTTP) && !parsed.host.to_s.empty? && parsed.userinfo.nil?
    end

    def valid_metrics?(value)
      return false unless value.is_a?(Hash) && value.length.between?(1, EVIDENCE_MAX_METRICS)

      value.all? do |name, metric|
        key = name.to_s.strip
        key.length.between?(1, EVIDENCE_MAX_METRIC_NAME_LENGTH) && key.match?(EVIDENCE_METRIC_NAME_PATTERN) &&
          !comparison_metric?(key) && valid_metric?(metric)
      end
    end

    # A stored metric is an object with a finite numeric value and non-empty
    # unit and basis text; the cache never stores a bare or value-less metric.
    def valid_metric?(metric)
      return false unless metric.is_a?(Hash)

      metric["value"].is_a?(Numeric) && metric["value"].to_f.finite? &&
        !metric["unit"].to_s.strip.empty? && !metric["basis"].to_s.strip.empty?
    end

    def bound_entry(entry, max_sources, max_metrics)
      metrics = entry["metrics"].is_a?(Hash) ? entry["metrics"] : {}
      bounded = {
        "status" => entry["status"],
        "retrieved_at" => entry["retrieved_at"],
        "valid_until" => entry["valid_until"],
        "sources" => Array(entry["sources"]).first(max_sources),
        "metrics" => metrics.first(max_metrics).to_h
      }
      bounded["cost_tier"] = entry["cost_tier"] if entry["cost_tier"].is_a?(Hash)
      bounded
    end

    # Mirror ModelEvidenceCache's reserved namespace: comparison claims depend
    # on two identities and are never stored, so they are never judged either.
    def comparison_metric?(name)
      name.to_s.split(".", 2).first.to_s.downcase == RESERVED_METRIC_NAMESPACE
    end

    def normalize(list)
      Array(list).map { |item| item.to_s.strip }.reject(&:empty?).uniq
    end

    def undecided(reason)
      { "model" => nil, "reason" => reason, "basis" => "none", "version" => DECISION_VERSION }
    end
  end
end
