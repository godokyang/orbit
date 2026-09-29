# frozen_string_literal: true

require "time"
require "uri"

require_relative "model_evidence_cache"
require_relative "model_quality_policy"

module Orbit
  # Pool and session identity are mandatory; the isolated checker's resolve
  # probe determines which pool models can actually run. A released task-fit
  # signal can prioritize a runnable model. Without that release, pool order
  # is the fallback and is not a quality or cost ranking. Unknown route cost
  # does not remove a runnable model. Time and coarse tiers are not inputs.
  module CheckerModelSelection
    DECISION_VERSION = "orbit-checker-selection-v6"

    # Structural evidence rules shared with CheckerModelSelector#precise_status.
    # ModelEvidenceCache validates every field at submission time, but
    # `stored_entries` reads raw JSON, so a hand-edited cache file could
    # present a source-less or value-less entry as "evidence". The selector is
    # what hands facts to JEV, so this module re-applies the cache's
    # structural rules here: the validity test mirrors
    # ModelEvidenceCache#lookup, which strips legacy time/speed/local-sample
    # metrics, resource (cost.*/quota.*) facts and the historical cost_tier
    # field before validating the remaining quality metrics. An entry whose
    # only measurements are those stripped legacy signals is not a quality
    # fact and never reads valid.
    EVIDENCE_MAX_SOURCES = 5
    EVIDENCE_MAX_METRICS = 24
    EVIDENCE_MAX_URL_LENGTH = 2048
    EVIDENCE_MAX_METRIC_NAME_LENGTH = 64
    EVIDENCE_CLOCK_SKEW_SECONDS = 300
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

    # Mirror ModelEvidenceCache#lookup for an entry with status "evidence":
    # legacy selection/resource signals and the cost_tier field never
    # participate, and the remaining quality metrics must validate in full.
    # A hand-edited cache entry that fails any rule is dropped whole, so JEV
    # never receives facts that were not verified.
    def valid_evidence_entry?(entry, now)
      return false unless entry.is_a?(Hash) && entry["status"] == "evidence"

      retrieved_at = parse_timestamp(entry["retrieved_at"])
      return false if retrieved_at.nil? || retrieved_at > now + EVIDENCE_CLOCK_SKEW_SECONDS

      valid_until = parse_timestamp(entry["valid_until"])
      return false if valid_until.nil? || valid_until <= retrieved_at || valid_until <= now

      valid_sources?(entry["sources"]) && valid_metrics?(entry["metrics"])
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

    # Only quality measurements count: time, speed and local-sample signals
    # (LEGACY_SELECTION_METRIC) and price/quota facts are stripped exactly as
    # the cache's read path strips them; an entry with nothing left is not a
    # quality fact. The remaining metrics must satisfy the same structural
    # rules a new submission would, including the reserved comparison
    # namespace.
    def valid_metrics?(value)
      return false unless value.is_a?(Hash) && value.length.between?(1, EVIDENCE_MAX_METRICS)

      remaining = value.reject do |name, _|
        ModelEvidenceCache.legacy_selection_metric?(name) || ModelEvidenceCache.resource_metric?(name)
      end
      return false if remaining.empty?

      remaining.all? do |name, metric|
        key = name.to_s.strip
        key.length.between?(1, EVIDENCE_MAX_METRIC_NAME_LENGTH) && key.match?(EVIDENCE_METRIC_NAME_PATTERN) &&
          !ModelEvidenceCache.comparison_metric?(key) && valid_metric?(metric)
      end
    end

    # A stored metric is an object with a finite numeric value and non-empty
    # unit and basis text; the cache never stores a bare or value-less metric.
    def valid_metric?(metric)
      return false unless metric.is_a?(Hash)

      metric["value"].is_a?(Numeric) && metric["value"].to_f.finite? &&
        !metric["unit"].to_s.strip.empty? && !metric["basis"].to_s.strip.empty?
    end


    def normalize(list)
      Array(list).map { |item| item.to_s.strip }.reject(&:empty?).uniq
    end

    def undecided(reason)
      { "model" => nil, "reason" => reason, "basis" => "none", "version" => DECISION_VERSION }
    end
  end
end
