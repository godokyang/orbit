# frozen_string_literal: true

require "time"
require "uri"

require_relative "model_quality_policy"

module Orbit
  # Pool and session identity are mandatory; the isolated checker's resolve
  # probe determines which pool models can actually run. A released task-fit
  # signal can prioritize a runnable model. Without that release, pool order
  # is the fallback and is not a quality or cost ranking. Unknown route cost
  # does not remove a runnable model. Time and coarse tiers are not inputs.
  module CheckerModelSelection
    DECISION_VERSION = "orbit-checker-selection-v6"

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

    module_function

    # Ordered pool identifiers that are also present in the session catalog.
    # Returns [] when the catalog is unavailable, so a non-empty pool is never
    # silently matched against a guess.
    def pool_candidates(pool:, catalog:)
      return [] unless catalog.is_a?(Hash)

      available = normalize(catalog["available"])
      normalize(pool).select { |model| available.include?(model) }
    end

    # A checker catalog exposes provider/id but not reasoning effort or billing
    # route. Use the explicit unknown identity, never a provider-default entry
    # or another billing route, until that information is actually observable.
    # Returns { model => bounded evidence }. It never invents facts or
    # credentials.
    def cached_evidence(models:, entries:, now:, max_sources: EVIDENCE_MAX_SOURCES, max_metrics: EVIDENCE_MAX_METRICS)
      return {} unless entries.is_a?(Array)

      normalize(models).each_with_object({}) do |model, out|
        provider, id = model.split("/", 2)
        candidates = entries.select do |entry|
          exact_identity?(entry, provider, id) && valid_evidence_entry?(entry, now)
        end
        next if candidates.empty?

        newest = candidates.max_by { |entry| entry["retrieved_at"].to_s }
        out[model] = bound_entry(newest, max_sources, max_metrics)
      end
    end

    def exact_identity?(entry, provider, id)
      entry.is_a?(Hash) && entry["provider"] == provider && entry["model"] == id &&
        entry["reasoning"] == "unknown" && entry.fetch("billing_route", "unknown") == "unknown"
    end

    # Read-only classification of one candidate's cached evidence for
    # diagnostics. A matching provider/model with another reasoning or route
    # is related evidence, not valid evidence for the unknown checker identity.
    # Statuses report what was actually checked:
    #
    #   valid       an exact-identity entry passes every structural rule and
    #               is inside its validity window (same test the selector
    #               applies when judging)
    #   expired     exact-identity entries exist and every parseable expiry
    #               is in the past (newest expiry reported)
    #   unavailable Root reported evidence could not be obtained (reason kept)
    #   invalid     entries exist but fail structural validation
    #   absent      no exact-identity entry at all
    def evidence_status(model:, entries:, now:, max_related: 3)
      provider, id = model.split("/", 2)
      exact = []
      same_model = []
      other_models = []
      Array(entries).each do |entry|
        next unless entry.is_a?(Hash) && entry["provider"] == provider

        if exact_identity?(entry, provider, id)
          exact << entry
        else
          identity = "#{entry['provider']}/#{entry['model']} " \
                     "(reasoning: #{entry.fetch('reasoning', 'default')}, billing_route: #{entry.fetch('billing_route', 'unknown')})"
          related = entry["model"] == id ? same_model : other_models
          related << identity if related.length < max_related && !related.include?(identity)
        end
      end
      related = (same_model + other_models).first(max_related)
      if exact.empty?
        detail = if related.empty?
                   "no cached entry for this exact identity (reasoning: unknown, billing_route: unknown)"
                 else
                   "no cached entry for this exact identity (reasoning: unknown, billing_route: unknown); " \
                     "the cache holds #{related.join(', ')} under provider #{provider}"
                 end
        return { "status" => "absent", "detail" => detail }
      end
      return { "status" => "valid", "detail" => nil } if exact.any? { |entry| valid_evidence_entry?(entry, now) }

      newest_expired = exact.filter_map { |entry| parse_timestamp(entry["valid_until"]) }
                            .select { |time| time <= now }.max
      if newest_expired
        return { "status" => "expired", "detail" => "evidence for this exact identity expired #{newest_expired.utc.iso8601}" }
      end

      unavailable = exact.find { |entry| entry["status"] == "unavailable" }
      if unavailable
        reason = unavailable["reason"].to_s.strip
        reason = "no reason recorded" if reason.empty?
        return { "status" => "unavailable", "detail" => "reported unavailable: #{reason.slice(0, 200)}" }
      end

      { "status" => "invalid", "detail" => "cached entries for this exact identity failed structural validation" }
    end

    # A released checker task-fit signal for this task scope sets the preferred
    # order. route_costs are RouteResourceFacts estimates. Time and coarse tiers
    # are not arguments and do not affect the order.
    def choose(pool:, catalog:, quality:, resolvable:, fit_scores: nil, route_costs: nil, release: nil, state: nil, judgment: nil)
      ordered = normalize(pool)
      return undecided("empty_pool") if ordered.empty?
      return undecided("session_catalog_unavailable") unless catalog.is_a?(Hash)

      in_session = pool_candidates(pool: ordered, catalog: catalog)
      return undecided("no_pool_model_in_session") if in_session.empty?

      resolved = normalize(resolvable)
      runnable = in_session.select { |model| resolved.include?(model) }
      return undecided("pool_models_unresolvable_in_checker") if runnable.empty?

      scores = quality.is_a?(Hash) ? quality : {}
      signals = runnable.map do |model|
        entry = scores[model]
        value = entry.is_a?(Hash) && entry["score"].is_a?(Numeric) ? entry["score"] : nil
        value = fit_scores[model] if value.nil? && fit_scores.is_a?(Hash) && fit_scores[model].is_a?(Numeric)
        { "id" => model, "quality" => value, "question" => "checker_task_fit",
          "identity" => entry.is_a?(Hash) ? entry["identity"] : nil,
          "recommendation_hold" => entry.is_a?(Hash) && entry["recommendation_hold"] == true }
      end
      ranking = ModelQualityPolicy.order(signals, release: release, route_costs: route_costs, state: state, judgment: judgment)
      if ranking["positive"]
        chosen = ranking["ordered_ids"].first
        return {
          "model" => chosen, "basis" => ranking["basis"], "candidates" => ranking["positive_ids"],
          "selection_tier" => "preferred", "version" => DECISION_VERSION,
          "cost_comparison" => ranking["cost_comparison"],
          "reason" => "#{ranking["basis"]}: #{ranking["reason"]}."
        }
      end

      {
        "model" => runnable.first, "basis" => "pool_order_unreleased", "candidates" => runnable,
        "selection_tier" => "fallback", "notice" => "候选池降级选择：独立检查模型质量未经证实",
        "version" => DECISION_VERSION, "cost_comparison" => "not_applied",
        "reason" => ranking["reason"]
      }
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
    # {band, confidence, basis}. A hand-edited tier drops the entry. A valid
    # coarse tier may remain on the cached fact and is not a route-cost rank.
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
