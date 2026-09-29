# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/orbit/model_capability_facts"
# Deterministic verification of the shared capability-facts projection:
# explicit task requirements in, catalog + precise evidence out together,
# conflicts held for Root review, contrasts visible, no time signals. All
# benchmark numbers are fixture values, never real catalog measurements.
module ModelCapabilityFactsTest
  NOW = Time.utc(2026, 9, 29, 12)

  module_function

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-capability-facts") do |tmp|
      test_unclassified_task_gets_facts_only(tmp)
      test_task_indices_select_prior(tmp)
      test_require_measurement_date_withholds_prior_keeps_facts(tmp)
      test_eligibility_projection(tmp)
      test_precise_evidence_and_catalog_presented_together(tmp)
      test_benchmark_value_conflict_holds_and_presents_both(tmp)
      test_minor_divergence_is_contrast_without_hold(tmp)
      test_unavailable_record_is_contrast_not_covered(tmp)
      test_time_sample_and_resource_fields_never_enter_projection(tmp)
      test_exact_identity_routing_to_both_stores(tmp)
      test_shipped_kimi_route_mapping(tmp)
      test_provenance_present_and_gated(tmp)
      test_input_validation_and_pool_bounds(tmp)
    end
    puts("MODEL_CAPABILITY_FACTS_TEST_PASS assertions=#{@assertions}")
  end

  class FakeHttp
    def initialize(responses)
      @responses = responses.dup
    end

    def call(url:, headers:)
      response = @responses.shift
      raise "unexpected OpenRouter request" if response.nil?

      [response[0], response[1]]
    end
  end

  def test_unclassified_task_gets_facts_only(tmp)
    facts = projection(tmp, "unclassified", rows: [row("example/agentic-only", coding: nil, agentic: 17.0)],
                       map: [mapping("openrouter_id" => "example/agentic-only", "canonical_slug" => "example/agentic-only")])
    result = facts.candidate_facts(identity: identity("example", "agentic-only"), task: {}, project_root: tmp)
    assert_equal("fresh", result.dig("catalog", "status"), "agentic-only catalog data resolves")
    assert_equal(nil, result.dig("catalog", "prior"), "an unclassified task gets no quality prior")
    assert_equal("example/agentic-only", result.dig("catalog", "facts", "id"), "catalog facts stay visible")
    assert_equal("none", result.dig("precise_evidence", "status"), "no precise evidence is recorded")
    assert_equal("not_required", result.dig("eligibility", "context", "status"), "context is not required")
    assert_equal("not_required", result.dig("eligibility", "parameters", "status"), "parameters are not required")
    assert_equal([], result.fetch("conflicts"), "no conflicts without evidence")
    assert_equal(false, result.fetch("recommendation_hold"), "nothing is held without a conflict")
  end

  def test_task_indices_select_prior(tmp)
    facts = projection(tmp, "indices",
                       rows: [row("example/agentic-only", coding: nil, agentic: 17.0),
                              row("example/analysis-only", coding: nil, agentic: nil, intelligence: 31.0)],
                       map: [mapping("model" => "agentic-only", "openrouter_id" => "example/agentic-only",
                                     "canonical_slug" => "example/agentic-only"),
                             mapping("model" => "analysis-only", "openrouter_id" => "example/analysis-only",
                                     "canonical_slug" => "example/analysis-only")])
    agentic = facts.candidate_facts(identity: identity("example", "agentic-only"),
                                    task: { "relevant_indices" => ["agentic_index"] }, project_root: tmp)
    assert_equal(17.0, agentic.dig("catalog", "prior", "agentic_index"), "the requested agentic index forms the prior")
    assert_equal(["agentic_index"], agentic.dig("catalog", "prior", "relevant_indices"), "the projection records the task index")

    coding = facts.candidate_facts(identity: identity("example", "agentic-only"),
                                   task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("no_benchmark", coding.dig("catalog", "status"), "agentic never fills a coding requirement")
    assert_equal(nil, coding.dig("catalog", "prior"), "a missing required index yields no prior")
    assert(coding.dig("catalog", "facts"), "facts stay visible when the index is missing")

    analysis = facts.candidate_facts(identity: identity("example", "analysis-only"),
                                     task: { "relevant_indices" => ["intelligence_index"] }, project_root: tmp)
    assert_equal(31.0, analysis.dig("catalog", "prior", "intelligence_index"), "intelligence is selectable in scope")
    assert_equal(false, analysis.dig("catalog", "prior").key?("coding_index"), "intelligence never becomes coding")
  end

  def test_require_measurement_date_withholds_prior_keeps_facts(tmp)
    facts = projection(tmp, "measurement", rows: [row("example/agentic-only", coding: nil, agentic: 17.0)],
                       map: [mapping("openrouter_id" => "example/agentic-only", "canonical_slug" => "example/agentic-only")],
                       evidence: [evidence("model" => "undated", "metrics" => { "agentic_index" => metric(11.0) }),
                                  evidence("model" => "dated", "metrics" => { "agentic_index" => metric(12.0) },
                                           "measured_at" => "2026-08-01T00:00:00Z",
                                           "method_version" => "aa-intelligence-2026-07")])
    result = facts.candidate_facts(identity: identity("example", "agentic-only"),
                                   task: { "relevant_indices" => ["agentic_index"], "require_measurement_date" => true },
                                   project_root: tmp)
    assert_equal("measurement_date_unknown", result.dig("catalog", "status"), "fetch time never qualifies as a measurement date")
    assert_equal(nil, result.dig("catalog", "prior"), "the prior is withheld when a date is required")
    assert_equal("unknown", result.dig("catalog", "facts", "measurement_date_status"), "the unknown measurement stays explicit")
    assert_equal(nil, result.dig("catalog", "facts", "method_version"), "no method version is invented")
    assert_equal(true, result["recommendation_hold"], "a required measurement date cannot be filled with fetch time")
    assert_equal("hold", result.dig("measurement_date", "status"),
                 "a withheld catalog prior is a held date requirement, not a passed one")

    undated = facts.candidate_facts(identity: identity("example", "undated"),
                                    task: { "require_measurement_date" => true }, project_root: tmp)
    assert_equal("hold", undated.dig("measurement_date", "status"),
                 "precise evidence without a measurement date cannot satisfy a date requirement either")
    assert_equal(true, undated["recommendation_hold"], "a missing measurement date holds the candidate")

    dated = facts.candidate_facts(identity: identity("example", "dated"),
                                  task: { "require_measurement_date" => true }, project_root: tmp)
    assert_equal("met_by_exact_evidence", dated.dig("measurement_date", "status"),
                 "a verifiable precise measurement date satisfies the date requirement")
    assert_equal(false, dated["recommendation_hold"], "a dated precise fact holds nothing by itself")
    assert_equal("2026-08-01T00:00:00Z", dated.dig("precise_evidence", "entry", "measurement_date"),
                 "the exact measurement date is projected explicitly")
    assert_equal("known", dated.dig("precise_evidence", "entry", "measurement_date_status"),
                 "the measurement date status is explicit")
    assert_equal("aa-intelligence-2026-07", dated.dig("precise_evidence", "entry", "method_version"),
                 "the recorded method version is projected")

    neither = facts.candidate_facts(identity: identity("example", "nothing"),
                                    task: { "require_measurement_date" => true }, project_root: tmp)
    assert_equal("unknown", neither.dig("measurement_date", "status"),
                 "with neither a catalog row nor precise evidence there is nothing to qualify")
    assert_equal(true, neither["recommendation_hold"],
                 "an explicit date requirement remains unmet while its source is unknown; Root can still choose")
  end

  def test_eligibility_projection(tmp)
    rows = [row("example/plain"), row("example/no-context", context: nil)]
    facts = projection(tmp, "eligibility", rows: rows,
                       map: [mapping("model" => "plain", "openrouter_id" => "example/plain", "canonical_slug" => "example/plain"),
                             mapping("model" => "no-context", "openrouter_id" => "example/no-context",
                                     "canonical_slug" => "example/no-context")])
    met = facts.candidate_facts(identity: identity("example", "plain"),
                                task: { "required_context_tokens" => 4096, "required_input_modalities" => ["text"],
                                        "required_output_modalities" => ["text"], "required_parameters" => ["tools"] },
                                project_root: tmp)
    assert_equal("met_by_catalog", met.dig("eligibility", "context", "status"), "catalog context covers the requirement")
    assert(met.dig("eligibility", "context", "note").include?("实际路由"), "the catalog/route distinction stays visible")
    assert_equal("met_by_catalog", met.dig("eligibility", "input_modalities", "status"), "catalog modality covers the requirement")
    assert(met.dig("eligibility", "parameters", "note").include?("工具入口"), "catalog parameters are not runtime grants")
    assert_equal(true, met["recommendation_hold"], "catalog facts do not fill missing execution limits")
    actual = { "source" => "omp_model_registry", "context_window" => 4096, "input_modalities" => ["text"],
               "output_modalities" => ["text"], "supports_tools" => true }
    qualified = facts.candidate_facts(identity: identity("example", "plain"), project_root: tmp,
      task: { "required_context_tokens" => 4096, "required_input_modalities" => ["text"],
              "required_output_modalities" => ["text"], "required_parameters" => ["tools"] }, execution_limits: actual)
    assert_equal(false, qualified["recommendation_hold"], "actual execution limits satisfy the specified requirements")
    smaller = facts.candidate_facts(identity: identity("example", "plain"), project_root: tmp,
      task: { "required_context_tokens" => 6000 }, execution_limits: actual)
    assert_equal("met_by_catalog", smaller.dig("eligibility", "context", "status"), "model-level context remains visible")
    assert_equal("unmet", smaller.dig("execution_eligibility", "context", "status"), "the smaller route limit controls execution")
    assert_equal(true, smaller["recommendation_hold"], "a large catalog cannot silently cover a smaller OMP route")

    tight = facts.candidate_facts(identity: identity("example", "plain"),
                                  task: { "required_context_tokens" => 16_000, "required_input_modalities" => ["image"],
                                          "required_parameters" => ["web_search"] },
                                  project_root: tmp)
    assert_equal("unmet_by_catalog", tight.dig("eligibility", "context", "status"), "a catalog bound below the task cannot pass")
    assert_equal(["image"], tight.dig("eligibility", "input_modalities", "missing"), "the missing modality is named")
    assert_equal(["web_search"], tight.dig("eligibility", "parameters", "missing"), "the missing parameter is named")

    unknown = facts.candidate_facts(identity: identity("example", "no-context"),
                                    task: { "required_context_tokens" => 4096 }, project_root: tmp)
    assert_equal("unknown", unknown.dig("eligibility", "context", "status"), "a missing catalog fact stays unknown")
  end

  def test_precise_evidence_and_catalog_presented_together(tmp)
    facts = projection(tmp, "together", rows: [row("example/coder", coding: 60.0, agentic: 35.0)],
                       map: [mapping("model" => "coder", "openrouter_id" => "example/coder", "canonical_slug" => "example/coder")],
                       evidence: [evidence("model" => "coder", "metrics" => { "agentic_index" => metric(34.0) })])
    result = facts.candidate_facts(identity: identity("example", "coder"),
                                   task: { "relevant_indices" => ["agentic_index"] }, project_root: tmp)
    assert_equal(35.0, result.dig("catalog", "prior", "agentic_index"), "the catalog prior stays visible next to evidence")
    assert_equal("evidence", result.dig("precise_evidence", "status"), "precise evidence is presented, not if/else")
    assert_equal(34.0, result.dig("precise_evidence", "entry", "metrics", "agentic_index", "value"),
                 "the evidence value is preserved")
    assert_equal([], result.fetch("conflicts"), "threshold-internal divergence is not a potential conflict")
    assert_equal("same_index_minor_divergence", result.dig("contrasts", 0, "type"), "the small difference stays visible")
    assert_equal(false, result.fetch("recommendation_hold"), "a contrast never holds recommendation")
    entry = result.dig("precise_evidence", "entry")
    assert_equal(nil, entry.fetch("measurement_date"), "an omitted measurement date stays unknown")
    assert_equal("unknown", entry.fetch("measurement_date_status"), "the unknown measurement date is explicit")
    assert_equal(nil, entry.fetch("method_version"), "no method version is invented")
    assert_equal("not_required", result.dig("measurement_date", "status"), "no date requirement was stated")
  end

  def test_benchmark_value_conflict_holds_and_presents_both(tmp)
    facts = projection(tmp, "conflict", rows: [row("example/coder", coding: 60.0)],
                       map: [mapping("model" => "coder", "openrouter_id" => "example/coder", "canonical_slug" => "example/coder")],
                       evidence: [evidence("model" => "coder", "metrics" => { "coding_index" => metric(30.0) })])
    result = facts.candidate_facts(identity: identity("example", "coder"),
                                   task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal(1, result.fetch("conflicts").length, "the divergence is flagged once")
    conflict = result.fetch("conflicts").first
    assert_equal("potential_benchmark_conflict", conflict.fetch("type"), "the divergence is a potential conflict lead")
    assert_equal("root_review", conflict.fetch("resolution"), "resolution is Root review, never source-name precedence")
    assert_equal(60.0, conflict.fetch("catalog_value"), "the catalog side keeps its value")
    assert_equal(30.0, conflict.fetch("evidence_value"), "the evidence side keeps its value")
    assert(conflict.fetch("catalog_fetched_at") && conflict.fetch("evidence_retrieved_at"), "both dates stay queryable")
    assert_equal(true, result.fetch("recommendation_hold"), "a potential conflict holds automatic positive recommendation")
    assert(result.fetch("hold_reason").include?("Root 复核") && result.fetch("hold_reason").include?("非真伪裁定"),
           "the hold reason names Root review and denies any authenticity verdict")
    assert_equal(60.0, result.dig("catalog", "prior", "coding_index"), "the catalog prior is not overwritten")
    assert_equal(30.0, result.dig("precise_evidence", "entry", "metrics", "coding_index", "value"),
                 "the precise record is not overwritten")
  end

  def test_minor_divergence_is_contrast_without_hold(tmp)
    facts = projection(tmp, "minor", rows: [row("example/coder", coding: 60.0)],
                       map: [mapping("model" => "coder", "openrouter_id" => "example/coder", "canonical_slug" => "example/coder")],
                       evidence: [evidence("model" => "coder", "metrics" => { "coding_index" => metric(62.0) })])
    result = facts.candidate_facts(identity: identity("example", "coder"),
                                   task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal([], result.fetch("conflicts"), "a threshold-internal difference is not a conflict")
    assert_equal("same_index_minor_divergence", result.dig("contrasts", 0, "type"), "the difference is still presented")
    assert_equal(false, result.fetch("recommendation_hold"), "no hold without a substantive conflict")
  end

  def test_unavailable_record_is_contrast_not_covered(tmp)
    facts = projection(tmp, "unavailable", rows: [row("example/agentic-only", coding: nil, agentic: 17.0)],
                       map: [mapping("openrouter_id" => "example/agentic-only", "canonical_slug" => "example/agentic-only")],
                       evidence: [{ "model" => "agentic-only", "status" => "unavailable",
                                    "reason" => "plan rejected this model" }])
    result = facts.candidate_facts(identity: identity("example", "agentic-only"),
                                   task: { "relevant_indices" => ["agentic_index"] }, project_root: tmp)
    assert_equal("exact_identity_unavailable_vs_catalog_prior", result.dig("contrasts", 0, "type"),
                 "the recorded unavailability is presented next to the prior")
    assert_equal(17.0, result.dig("catalog", "prior", "agentic_index"), "the catalog score never covers the record")
    assert_equal("plan rejected this model", result.dig("precise_evidence", "entry", "reason"), "the reason survives")
    assert_equal(false, result.fetch("recommendation_hold"), "not automatically a contradiction per ADR-009 §6.1")
  end

  def test_time_sample_and_resource_fields_never_enter_projection(tmp)
    history = { "provider" => "example", "reasoning" => "unknown", "billing_route" => "unknown",
                "status" => "evidence", "retrieved_at" => "2026-09-29T08:00:00Z",
                "valid_until" => "2026-10-06T08:00:00Z", "sources" => ["https://vendor.example/evidence"] }
    facts = projection(tmp, "time-signals", rows: [row("example/coder", coding: 60.0)],
                       map: [mapping("model" => "coder", "openrouter_id" => "example/coder", "canonical_slug" => "example/coder")],
                       raw_evidence: [history.merge("model" => "coder", "metrics" => {
                         "speed.tokens_per_second" => metric(180.0, unit: "tok/s"),
                         "elapsed_seconds" => metric(42.0, unit: "s"),
                         "local_sample_latency_ms" => metric(300.0, unit: "ms"),
                         "end_to_end_seconds" => metric(95.0, unit: "s"),
                         "local_samples.success_rate" => metric(0.5, unit: "ratio"),
                         "cost.input_price" => metric(0.8, unit: "USD/Mtok"),
                         "quota.monthly_allowance" => metric(2000.0, unit: "requests"),
                         "coding_index" => metric(59.0) },
                         "cost_tier" => { "band" => "low", "confidence" => "medium", "basis" => "fixture tier" })])
    result = facts.candidate_facts(identity: identity("example", "coder"),
                                   task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    entry = result.dig("precise_evidence", "entry")
    assert_equal(["coding_index"], entry.fetch("metrics").keys,
                 "time, local-sample and route resource metrics are stripped from a historical entry")
    assert_equal(false, entry.key?("cost_tier"), "a legacy cost tier never reaches a selection input")
    assert_equal(nil, entry.fetch("measurement_date"), "an archived entry without a date stays unknown")
    assert_equal("unknown", entry.fetch("measurement_date_status"), "the unknown date is stated, not filled in")
    assert_equal(nil, entry.fetch("method_version"), "the fetch time is never presented as a method version")
    assert_equal(59.0, entry.dig("metrics", "coding_index", "value"), "the meaningful measurement survives the strip")
  end

  def test_exact_identity_routing_to_both_stores(tmp)
    entries = [mapping("provider" => "routep", "model" => "m1", "openrouter_id" => "example/routed",
                       "canonical_slug" => "example/routed"),
               mapping("provider" => "routep", "model" => "m1", "billing_route" => "subscription_quota",
                       "openrouter_id" => "example/routed", "canonical_slug" => "example/routed")]
    facts = projection(tmp, "routes", rows: [row("example/routed", coding: 44.0)], map: entries,
                       evidence: [evidence("provider" => "routep", "model" => "m1", "reasoning" => "high",
                                           "metrics" => { "coding_index" => metric(43.0) })])
    quota = facts.candidate_facts(identity: identity("routep", "m1", billing_route: "subscription_quota"),
                                  task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("subscription_quota", quota.dig("catalog", "prior", "mapping_identity", "billing_route"),
                 "the route-specific entry matches exactly")
    assert_equal("none", quota.dig("precise_evidence", "status"), "reasoning=unknown never borrows a reasoning=high record")

    direct = facts.candidate_facts(identity: identity("routep", "m1", billing_route: "direct_api"),
                                   task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("unmapped", direct.dig("catalog", "status"), "billing_route matches exactly, never wildcarded")

    high = facts.candidate_facts(identity: identity("routep", "m1", reasoning: "high"),
                                 task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("evidence", high.dig("precise_evidence", "status"), "the exact reasoning variant finds its record")
  end

  def test_shipped_kimi_route_mapping(tmp)
    facts = projection(tmp, "shipped", rows: [row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715",
                                                  coding: 66.5, agentic: 41.5)],
                       map: nil)
    quota = facts.candidate_facts(identity: identity("kimi-code", "k3-256k", billing_route: "subscription_quota"),
                                  task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("fresh", quota.dig("catalog", "status"), "the verified subscription_quota identity resolves")
    assert_equal(66.5, quota.dig("catalog", "prior", "coding_index"), "the route variant reuses the audited model-level prior")
    assert(quota.dig("catalog", "provenance", "verified_by").include?("structural route proof"),
           "the provenance names the route verification basis")

    plain = facts.candidate_facts(identity: identity("kimi-code", "k3-256k"),
                                  task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("unknown", plain.dig("catalog", "prior", "mapping_identity", "billing_route"),
                 "the unknown-route entry is preserved untouched")

    direct = facts.candidate_facts(identity: identity("kimi-code", "k3-256k", billing_route: "direct_api"),
                                   task: {}, project_root: tmp)
    assert_equal("unmapped", direct.dig("catalog", "status"), "no route is ever rewritten to hit an entry")
  end

  def test_provenance_present_and_gated(tmp)
    facts = projection(tmp, "provenance", rows: [row("example/coder", coding: 60.0)],
                       map: [mapping("model" => "coder", "openrouter_id" => "example/coder", "canonical_slug" => "example/coder")])
    mapped = facts.candidate_facts(identity: identity("example", "coder"), task: {}, project_root: tmp)
    provenance = mapped.dig("catalog", "provenance")
    assert_equal("2026-09-28T00:00:00Z", provenance.fetch("verified_at"), "the mapping review date is queryable")
    assert_equal(["https://vendor.example/coder"], provenance.fetch("sources"), "the mapping sources are queryable")

    unmapped = facts.candidate_facts(identity: identity("example", "stranger"), task: {}, project_root: tmp)
    assert_equal(nil, unmapped.dig("catalog", "provenance"), "an unmapped identity has no provenance")

    keyless = projection(tmp, "provenance-keyless", env: { "OPENROUTER_API_KEY" => nil },
                         rows: [row("example/coder")],
                         map: [mapping("model" => "coder", "openrouter_id" => "example/coder",
                                       "canonical_slug" => "example/coder")], refresh: false)
    gated = keyless.candidate_facts(identity: identity("example", "coder"), task: {}, project_root: tmp)
    assert_equal("not_configured", gated.dig("catalog", "status"), "no key keeps the catalog gate closed")
    assert_equal(nil, gated.dig("catalog", "provenance"), "no provenance leaks without configuration")
  end

  def test_input_validation_and_pool_bounds(tmp)
    facts = projection(tmp, "validation", rows: [row("example/coder", coding: 60.0)],
                       map: [mapping("model" => "coder", "openrouter_id" => "example/coder", "canonical_slug" => "example/coder")],
                       evidence: [evidence("model" => "coder", "reasoning" => nil,
                                           "metrics" => { "coding_index" => metric(61.0) })])
    assert_raises { facts.candidate_facts(identity: identity("example", "coder"), task: { "relevant_indices" => ["speed"] }, project_root: tmp) }
    assert_raises { facts.candidate_facts(identity: identity("example", "coder"), task: { "required_context_tokens" => 0 }, project_root: tmp) }
    assert_raises { facts.candidate_facts(identity: identity("example", "coder"), task: { "required_input_modalities" => Array.new(9, "text") }, project_root: tmp) }
    assert_raises { facts.candidate_facts(identity: { "provider" => "example", "model" => "coder", "reasoning" => "unknown" }, task: {}, project_root: tmp) }

    default = facts.candidate_facts(identity: identity("example", "coder", reasoning: "default"),
                                    task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("evidence", default.dig("precise_evidence", "status"), "default finds a default record")
    unknown = facts.candidate_facts(identity: identity("example", "coder", reasoning: "unknown"),
                                    task: { "relevant_indices" => ["coding_index"] }, project_root: tmp)
    assert_equal("none", unknown.dig("precise_evidence", "status"), "unknown and default never interchange")

    pool = facts.pool_facts(identities: [identity("example", "coder"), identity("example", "coder", reasoning: "high")],
                            task: {}, project_root: tmp)
    assert_equal("orbit-capability-facts-v1", pool.fetch("version"), "the projection carries its version")
    assert_equal(%w[unknown high], pool.fetch("candidates").map { |c| c.dig("identity", "reasoning") },
                 "input order is preserved, never a ranking")
    assert_raises { facts.pool_facts(identities: [], task: {}, project_root: tmp) }
    assert_raises { facts.pool_facts(identities: Array.new(65) { identity("example", "coder") }, task: {}, project_root: tmp) }
  end

  # ---- fixtures -----------------------------------------------------------

  def projection(tmp, name, env: {}, rows:, map:, evidence: [], raw_evidence: [], refresh: true)
    home = File.join(tmp, "home-#{name}")
    base_env = { "HOME" => home, "OPENROUTER_API_KEY" => "or-test-key-1" }.merge(env)
    http = FakeHttp.new([[200, JSON.generate({ "data" => rows, "links" => { "next" => nil },
                                               "total_count" => rows.length })]])
    overview = Orbit::OpenRouterModelOverview.new(env: base_env, home: home, clock: -> { NOW },
                                                  cache_path: File.join(tmp, name, "overview.json"),
                                                  map_path: File.join(tmp, name, "map.json"),
                                                  http_get: http)
    if map
      FileUtils.mkdir_p(File.dirname(overview.map_path))
      File.write(overview.map_path,
                 JSON.pretty_generate({ "schema_version" => "orbit-openrouter-model-map-v1", "entries" => map }))
    end
    overview.refresh(project_root: tmp) if refresh && base_env["OPENROUTER_API_KEY"]

    cache = Orbit::ModelEvidenceCache.new(path: File.join(tmp, name, "evidence.json"), clock: -> { NOW })
    unless evidence.empty?
      cache.record_all(evidence.map do |entry|
        { "provider" => "example", "reasoning" => "unknown", "billing_route" => "unknown",
          "retrieved_at" => "2026-09-29T08:00:00Z", "sources" => ["https://vendor.example/evidence"] }.merge(entry)
      end)
    end
    # Pre-existing history, written directly: the current submission gate would
    # refuse these legacy fields, and the projection must still strip them.
    unless raw_evidence.empty?
      FileUtils.mkdir_p(File.dirname(cache.path))
      File.write(cache.path, JSON.pretty_generate("schema_version" => Orbit::ModelEvidenceCache::SCHEMA_VERSION,
                                                 "entries" => raw_evidence))
    end
    Orbit::ModelCapabilityFacts.new(overview: overview, evidence_cache: cache)
  end

  def row(id, slug: id, coding: 50.0, agentic: 40.0, intelligence: nil, context: 8192)
    { "id" => id, "canonical_slug" => slug, "name" => "Model", "description" => "Bounded description.",
      "context_length" => context,
      "supported_parameters" => ["tools"],
      "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["text"], "tokenizer" => "Other" },
      "benchmarks" => { "artificial_analysis" => { "coding_index" => coding, "agentic_index" => agentic,
                                                  "intelligence_index" => intelligence } } }
  end

  def mapping(overrides = {})
    { "provider" => "example", "model" => "agentic-only", "reasoning" => "unknown",
      "billing_route" => "unknown", "openrouter_id" => "example/agentic-only",
      "canonical_slug" => "example/agentic-only",
      "sources" => ["https://vendor.example/coder"],
      "verified_at" => "2026-09-28T00:00:00Z", "verified_by" => "Root" }.merge(overrides)
  end

  def evidence(overrides = {})
    { "status" => "evidence", "metrics" => {} }.merge(overrides)
  end

  def metric(value, unit: "index", basis: "fixture measurement")
    { "value" => value, "unit" => unit, "basis" => basis }
  end

  def identity(provider, model, reasoning: "unknown", billing_route: "unknown")
    { "provider" => provider, "model" => model, "reasoning" => reasoning, "billing_route" => billing_route }
  end

  def assert_raises
    yield
    assert(false, "expected an Error")
  rescue Orbit::ModelCapabilityFacts::Error, Orbit::OpenRouterModelOverview::Error, Orbit::ModelEvidenceCache::Error
    @assertions += 1
  end

  def assert(condition, message)
    @assertions += 1
    raise("assertion failed: #{message}") unless condition
  end

  def assert_equal(expected, actual, message)
    assert(expected == actual, "#{message} (expected #{expected.inspect}, got #{actual.inspect})")
  end
end

ModelCapabilityFactsTest.run
