# frozen_string_literal: true

require "time"
require_relative "../lib/orbit/checker_model_selection"
require_relative "../lib/orbit/member_model_selector"

# Delegation assessment fixtures are scripted: no network, no cache, no model call.
module MemberModelSelectorTest
  module_function

  FakePool = Struct.new(:models) do
    def read
      raise "scripted pool read failure" if models == :error

      models
    end
  end
  class FakeConnection
    attr_reader :resolutions

    def initialize(catalog, resolution: nil)
      @catalog = catalog
      @resolution = resolution
      @resolutions = 0
    end

    def model_catalog
      raise "scripted catalog failure" if @catalog == :error

      @catalog
    end

    def member_model_resolution
      @resolutions += 1
      @resolution
    end
  end

  FakeEvidence = Struct.new(:entries) do
    def stored_entries = entries
    def lookup(provider:, model:, reasoning: nil, billing_route: nil)
      return nil unless entries.is_a?(Array)

      entries.find do |entry|
        entry.is_a?(Hash) && entry["provider"] == provider && entry["model"] == model &&
          entry["reasoning"] == (reasoning || "unknown") &&
          entry.fetch("billing_route", "unknown") == (billing_route || "unknown") &&
          Orbit::CheckerModelSelection.valid_evidence_entry?(entry, Time.utc(2026, 9, 25))
      end
    end
  end

  class FakeOverview
    def initialize(states = {}) = @states = states
    def lookup(model:, reasoning: "unknown", billing_route: "unknown", project_root:, indices: [],
               require_measurement_date: false)
      state = @states.fetch(model, { "status" => "not_configured" })
      return state unless state["facts"] || state["prior"]

      prior = state["prior"]
      prior = nil if prior.nil? || (Array(indices) & Orbit::OpenRouterModelOverview::BENCHMARK_KEYS).empty?
      { "status" => state["status"], "facts" => state["facts"], "prior" => prior }
    end

    def mapping_provenance(model:, reasoning: "unknown", billing_route: "unknown", project_root:)
      { "verified_at" => "2026-09-20T00:00:00Z", "verified_by" => "scripted audit", "sources" => ["https://e.test"] }
    end
  end

  class FakeAdvisor
    attr_reader :calls

    attr_reader :states

    def initialize(delegation:, candidates: {}, model: "jev-1.13", failure: nil, input_version_override: nil)
      @delegation = delegation
      @candidates = candidates
      @model = model
      @failure = failure
      @input_version_override = input_version_override
      @calls = []
      @states = {}
    end

    def assess_delegation(state:)
      @calls << "delegation"
      @states["delegation"] = state
      fail_judgment("delegation") if @failure == "delegation"

      receipt("d1", "delegation", @delegation, 11, state)
    end

    def assess_candidates(state:, candidates:)
      @calls << "candidates"
      @states["candidates"] = state
      fail_judgment("candidates") if @failure == "candidates"

      scores = candidates.each_index.to_h { |index| [index.to_s, { "quality" => @candidates[index.to_s] }] }
      receipt("c1", "candidates", scores, 21, state)
    end

    # Mirrors JevAdvisor#post_questions: the input version is the projected
    # state's, never a local constant.
    def receipt(id, phase, scores, input, state)
      version = @input_version_override == :missing ? nil : (@input_version_override ||
        Orbit::ModelQualityPolicy.project_selection_state(state)["input_version"])
      receipt = { "provider" => "typesafe", "model" => @model, "status" => "answered",
                  "call_id" => "orbit-judgment-#{id}", "requested_model" => @model,
                  "question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch(phase),
                  "scores" => scores, "usage" => { "input_tokens" => input, "output_tokens" => 1 } }
      version.nil? ? receipt : receipt.merge("input_version" => version)
    end

    def fail_judgment(phase)
      receipt = Orbit::JudgmentResult.unavailable(
        provider: "typesafe", reason: "scripted outage", actual_model: "jev-failure-fixture",
        usage: { "input_tokens" => 17, "output_tokens" => 2 }
      ).to_h.merge("question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch(phase),
                   "call_id" => "orbit-judgment-fail")
      raise Orbit::JevAdvisor::Error.new("scripted outage", receipt: receipt)
    end
  end

  def assert(value, message)
    raise message unless value
  end

  def state(input_digest: "sha256:one")
    { "input_digest" => input_digest, "instruction" => "deliver the reviewed change",
      "workspace" => { "project" => { "git" => true }, "artifact_root" => "/tmp" } }
  end

  def work_unit(input_digest: "sha256:one", requirements: nil, id: "unit-1")
    unit = { "id" => id, "input_digest" => input_digest, "status" => "planned",
             "objective" => "deliver the reviewed change", "requirements" => ["REQ-1"],
             "context" => { "note" => "scripted" }, "decisions" => [{ "id" => "D-1" }],
             "escalation" => "none", "artifact_root" => "/tmp",
             "scope" => { "allowed_paths" => ["lib/orbit/member_model_selector.rb"] }, "acceptance" => "verifiable" }
    unit["model_requirements"] = requirements if requirements
    unit
  end

  def catalog_for(models, agents: {}, limits: {})
    { "current" => "native/model", "available" => models, "agents" => agents, "limits" => limits,
      "routes" => {}, "families" => {} }
  end
  def entry(model)
    provider, id = model.split("/", 2)
    { "provider" => provider, "model" => id, "reasoning" => "unknown", "billing_route" => "unknown",
      "status" => "evidence", "retrieved_at" => "2026-09-01T00:00:00Z", "valid_until" => "2026-12-01T00:00:00Z",
      "sources" => ["https://example.com/facts"],
      "metrics" => { "quality_reasoning" => { "value" => 1, "unit" => "bool", "basis" => "scripted" } } }
  end
  def release_for(model: "jev-1.13", threshold: 0.5)
    { "allows_positive_ranking" => true, "proves_samples_real" => false, "provider" => "typesafe", "model" => model,
      "decision_version" => Orbit::ModelQualityPolicy::DECISION_VERSION,
      "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
      "question_digest" => Orbit::ModelQualityPolicy.question_digest,
      "question_set_versions" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS,
      "structural_validation" => "passed", "scope" => Orbit::ModelQualityPolicy::SUPPORTED_PROFILE,
      "thresholds" => Orbit::ModelQualityPolicy::GATING_QUESTIONS.to_h { |question| [question, threshold] },
      "reviewed_by" => "scripted fixture", "reviewed_at" => "2026-09-25T00:00:00Z" }
  end
  def selector(pool:, catalog:, entries: [], advisor:, resolution: nil, release: nil, overview: FakeOverview.new)
    Orbit::MemberModelSelector.new(
      connection: FakeConnection.new(catalog, resolution: resolution), project_root: "/tmp",
      pool: FakePool.new(pool), evidence_cache: FakeEvidence.new(entries), advisor: advisor,
      overview: overview, release: release
    )
  end

  def candidates_need_host_agents_and_an_empty_pool_uses_one_real_native_resolution
    pool = %w[a/one b/two c/three]
    advisor = FakeAdvisor.new(delegation: {})
    built = selector(pool: pool,
                     catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a", "b/two" => "orbit-agent-b" }),
                     entries: [entry("a/one")], advisor: advisor)
    result = built.assess(state: state, work_unit: work_unit)
    assert(result["decision"] == "facts_only" && result["reused"] == false &&
           result["candidates"].map { |item| item["agent"] } == %w[orbit-agent-a orbit-agent-b] &&
           result["candidates"].first["identity"] == { "provider" => "a", "model" => "one",
                                                       "reasoning" => "unknown", "billing_route" => "unknown" },
           "only pooled models the session resolves and maps to a host agent become candidates")
    assert(result["recommendation"] == { "first" => nil, "backups" => [] } && result["judgments"] == [] &&
           advisor.calls.empty? && built.instance_variable_get(:@connection).resolutions.zero?,
           "without a release the assessment reports facts only, pays nothing and never mixes in the default @task")

    resolution = { "provider" => "native", "id" => "model", "billing_route" => "subscription_quota" }
    native = selector(pool: [], catalog: catalog_for(["native/model"], agents: { "native/model" => "orbit-native" }),
                      advisor: FakeAdvisor.new(delegation: {}), resolution: resolution,
                      entries: [entry("native/model").merge("billing_route" => "subscription_quota")])
    empty = native.assess(state: state, work_unit: work_unit)
    assert(empty["candidates"].length == 1 && empty["candidates"].first["agent"] == "task" &&
           empty["candidates"].first["native"] == true &&
           empty["candidates"].first.dig("identity", "billing_route") == "subscription_quota" &&
           native.instance_variable_get(:@connection).resolutions == 1,
           "an empty pool uses the one real native @task resolution and the generic task agent")
    assert(empty["candidates"].first["quality_basis"] == "exact_model_evidence",
           "the native candidate's facts are projected with the same resolved identity, not a degraded one")

    unreadable = selector(pool: :error, catalog: catalog_for(["a/one"], agents: { "a/one" => "orbit-agent-a" }),
                          entries: [entry("a/one")], advisor: FakeAdvisor.new(delegation: {}), release: release_for)
    unknown = unreadable.assess(state: state, work_unit: work_unit)
    assert(unknown["decision"] == "facts_only" && unknown["candidates"].empty? &&
           unknown["reason"].to_s.include?("pool") &&
           unreadable.instance_variable_get(:@connection).resolutions.zero?,
           "an unreadable pool is reported as unknown facts and never silently becomes the native fallback")
  end

  def a_matching_release_pays_two_judgments_and_orders_the_candidates
    pool = %w[a/one b/two]
    limits = { "a/one" => { "source" => "omp_model_registry", "context_window" => 200_000,
                            "input_modalities" => ["text"], "supports_tools" => true },
               "b/two" => { "source" => "omp_model_registry", "context_window" => 8_192,
                            "input_modalities" => ["text"], "supports_tools" => true } }
    advisor = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.8 },
                              candidates: { "0" => 0.9, "1" => 0.95 })
    prior = { "canonical_slug" => "a/one-catalog", "coding_index" => 70.0, "relevant_indices" => ["coding_index"],
              "fetched_at" => "2026-09-25T00:00:00Z", "sources" => ["https://example.com/bench"] }
    overview = FakeOverview.new("a/one" => { "status" => "fresh", "facts" => { "id" => "a/one" }, "prior" => prior })
    built = selector(pool: pool,
                     catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a", "b/two" => "orbit-agent-b" },
                                          limits: limits),
                     entries: [entry("a/one"), entry("b/two")], advisor: advisor, overview: overview,
                     release: release_for)
    result = built.assess(state: state, work_unit: work_unit(requirements: { "required_context_tokens" => 100_000,
                                                                            "relevant_indices" => ["coding_index"] }))
    assert(advisor.calls == %w[delegation candidates] &&
           result["judgments"].map { |item| item["phase"] } == %w[delegation candidates] &&
           result["judgments"].map { |item| item["call_id"] } == %w[orbit-judgment-d1 orbit-judgment-c1] &&
           result["judgments"].first.dig("usage", "input_tokens") == 11,
           "a matching release pays the delegation judgment and then the per-candidate one, each with its own receipt")
    assert(result["decision"] == "recommended" && result["recommendation"] == { "first" => "orbit-agent-a",
                                                                                "backups" => [] },
           "only the candidate that clears the released bar is recommended")
    held = result["candidates"].find { |item| item["agent"] == "orbit-agent-b" }
    assert(held["verdict"] == "not_recommended" && held["recommendation_hold"] == true &&
           held["hold_reason"].to_s.include?("执行限制") &&
           held.dig("execution_eligibility", "context", "configured_limit") == 8_192,
           "an explicit requirement the resolved route cannot meet holds that candidate instead of rejecting it")
    assert(result["order"]["cost_comparison"] == "unknown" &&
           result["candidates"].find { |item| item["agent"] == "orbit-agent-a" }
                 .dig("execution_eligibility", "context", "status") == "met",
           "unknown route cost decides nothing; a resolved limit that meets the requirement is reported as met")

    handed_unit = advisor.states["delegation"]["work_unit"]
    assert(handed_unit["id"] == "unit-1" && handed_unit["status"] == "planned" &&
           handed_unit["requirements"] == ["REQ-1"] && handed_unit["decisions"] == [{ "id" => "D-1" }] &&
           handed_unit["escalation"] == "none" && handed_unit["artifact_root"] == "/tmp" &&
           handed_unit["context"] == { "note" => "scripted" } && handed_unit["dependencies"].nil?,
           "the real handoff fields reach the judgment input instead of being dropped")

    handed = advisor.states["delegation"]["candidates"].find { |item| item["model"] == "one" }
    assert(handed["capability_facts"].is_a?(Hash) &&
           handed["capability_facts"]["execution_eligibility"].is_a?(Hash) &&
           handed["capability_facts"]["recommendation_hold"] == false && handed.key?("evidence") &&
           handed.key?("model_overview_prior"),
           "each candidate hands over its complete projected facts and both evidence classes together")
    assert(result["judgments"].all? { |item| item["input_version"] == Orbit::ModelQualityPolicy::INPUT_VERSION },
           "the recorded receipts copy the real input version instead of substituting a local constant")

    wrong = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.9 },
                            candidates: { "0" => 0.9 }, input_version_override: "jev-selection-input-0")
    wrong_result = selector(pool: pool, catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a" }),
                            entries: [entry("a/one")], advisor: wrong, release: release_for)
                   .assess(state: state, work_unit: work_unit)
    assert(wrong_result["decision"] == "not_recommended" && wrong.calls == ["delegation"] &&
           wrong_result["judgments"].first["input_version"] == "jev-selection-input-0",
           "a receipt carrying another input version can never become a positive recommendation")

    missing = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.9 },
                              candidates: { "0" => 0.9 }, input_version_override: :missing)
    missing_result = selector(pool: pool, catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a" }),
                              entries: [entry("a/one")], advisor: missing, release: release_for)
                     .assess(state: state, work_unit: work_unit)
    assert(missing_result["decision"] == "not_recommended" &&
           !missing_result["judgments"].first.key?("input_version"),
           "a receipt without an input version is recorded as-is and never recommended")

    bound = selector(pool: pool, catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a" }),
                     entries: [entry("a/one")], advisor: FakeAdvisor.new(delegation: { "handoff_fit" => 0.9,
                                                                                     "member_task_fit" => 0.9 },
                                                                         candidates: { "0" => 0.9 }),
                     release: release_for.merge("validated_calibration" => "sha256:fixture",
                                                "review_reason" => "scripted review"))
    rebound = bound.assess(state: state, work_unit: work_unit, previous: result)
    assert(rebound["reused"] == false && rebound["signature"] != result["signature"] &&
           rebound.dig("release", "validated_calibration") == "sha256:fixture" &&
           rebound.dig("release", "review_reason") == "scripted review" &&
           rebound.dig("release", "proves_samples_real") == false,
           "every release binding, including invalidation toggles, is echoed and part of the signature")

    invalid = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.9 })
    refused = selector(pool: pool, catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a" }),
                       entries: [entry("a/one")], advisor: invalid,
                       release: release_for.merge("question_digest" => "sha256:other"))
              .assess(state: state, work_unit: work_unit)
    assert(refused["decision"] == "facts_only" && refused["judgments"] == [] && invalid.calls.empty? &&
           refused["reason"].to_s.include?("valid ranking binding"),
           "an invalid calibration is downgraded before any judgment is paid")

    unmatched = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.9 })
    unmatched_result = selector(pool: pool, catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a" }),
                                entries: [entry("a/one")], advisor: unmatched, release: release_for)
                       .assess(state: { "input_digest" => "sha256:one" }, work_unit: work_unit)
    assert(unmatched_result["decision"] == "facts_only" && unmatched.calls.empty? &&
           unmatched_result["reason"].to_s.include?("profile"),
           "a task profile with no reviewed release scope is downgraded before any judgment is paid")
  end

  def insufficient_delegation_signal_stops_before_the_candidate_judgment
    advisor = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.05 },
                              candidates: { "0" => 0.99 })
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"], agents: { "a/one" => "orbit-agent-a" }),
                     entries: [entry("a/one")], advisor: advisor, release: release_for)
    result = built.assess(state: state, work_unit: work_unit)
    assert(advisor.calls == ["delegation"] && result["decision"] == "not_recommended" &&
           result["judgments"].length == 1 && result["recommendation"]["first"].nil?,
           "the second paid judgment happens only when the delegation receipt clears both gates")
  end

  def a_failed_judgment_keeps_its_real_receipt_and_never_fabricates_success
    advisor = FakeAdvisor.new(delegation: {}, failure: "delegation")
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"], agents: { "a/one" => "orbit-agent-a" }),
                     entries: [entry("a/one")], advisor: advisor, release: release_for)
    receipt = built.assess(state: state, work_unit: work_unit)["judgments"].first
    assert(receipt["status"] == "unavailable" && receipt["model"] == "jev-failure-fixture" &&
           receipt["call_id"] == "orbit-judgment-fail" && receipt.dig("usage", "input_tokens") == 17 &&
           receipt["error"].to_s.include?("scripted outage"),
           "a failed judgment keeps the service's real receipt and consumption instead of a fabricated zero")
  end

  def an_unchanged_assessment_is_reused_and_a_real_change_is_not
    pool = %w[a/one]
    advisor = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.9 },
                              candidates: { "0" => 0.9 })
    built = selector(pool: pool, catalog: catalog_for(pool, agents: { "a/one" => "orbit-agent-a" }),
                     entries: [entry("a/one")], advisor: advisor, release: release_for)
    first = built.assess(state: state, work_unit: work_unit)
    again = built.assess(state: state, work_unit: work_unit, previous: first)
    assert(again["reused"] == true && again["signature"] == first["signature"] && advisor.calls.length == 2,
           "an unchanged input/unit/facts/release assessment is returned as reused without another call")

    changed = built.assess(state: state(input_digest: "sha256:two"),
                           work_unit: work_unit(input_digest: "sha256:two"), previous: first)
    assert(changed["reused"] == false && changed["signature"] != first["signature"] && advisor.calls.length == 4,
           "a changed task input version re-assesses instead of reusing the old recommendation")

    sibling = built.assess(state: state, work_unit: work_unit(id: "unit-2"), previous: first)
    assert(sibling["reused"] == false && sibling["signature"] != first["signature"],
           "two identically described units with different ids are never conflated into one cached decision")

    priced = built.assess(state: state, work_unit: work_unit, previous: first.merge("signature" => "stale"),
                          route_costs: { "a/one" => nil })
    assert(priced["reused"] == false && priced["order"]["cost_comparison"] == "unknown",
           "route costs are part of the signature, and unknown cost never rejects a candidate")
  end

  def a_stale_work_unit_and_a_broken_catalog_never_pass_as_verified
    advisor = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.9 })
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"], agents: { "a/one" => "orbit-agent-a" }),
                     entries: [entry("a/one")], advisor: advisor, release: release_for)
    stale = built.assess(state: state(input_digest: "sha256:new"), work_unit: work_unit(input_digest: "sha256:old"))
    assert(stale["decision"] == "stale" && stale["stale"] == true && stale["judgments"] == [] && advisor.calls.empty?,
           "a work unit from another input version is reported stale, never judged or dispatched")

    broken = selector(pool: ["a/one"], catalog: :error, entries: [entry("a/one")], advisor: advisor,
                      release: release_for)
    failed = broken.assess(state: state, work_unit: work_unit)
    assert(failed["decision"] == "facts_only" && failed["candidates"].empty? &&
           failed["reason"].to_s.include?("catalog") && advisor.calls.empty?,
           "an unavailable catalog keeps unknown facts and leaves the native choice to Root without paying a judgment")
  end

  def provider_model_forecasts_price_the_actual_native_agent
    pool = %w[a/one b/two]
    catalog = catalog_for(pool, agents: { "a/one" => "orbit-agent-a", "b/two" => "orbit-agent-b" })
    catalog["routes"] = pool.to_h { |model| [model, "direct_api"] }
    entries = pool.map { |model| entry(model).merge("billing_route" => "direct_api") }
    advisor = FakeAdvisor.new(delegation: { "handoff_fit" => 0.9, "member_task_fit" => 0.9 },
                              candidates: { "0" => 0.9, "1" => 0.9 })
    built = selector(pool: pool, catalog: catalog, entries: entries, advisor: advisor, release: release_for)
    costs = pool.each_with_index.to_h do |model, index|
      provider, id = model.split("/", 2)
      route = { "provider" => provider, "model" => id, "reasoning" => "unknown", "billing_route" => "direct_api" }
      fact = { "schema_version" => Orbit::RouteResourceFacts::SCHEMA_VERSION, "scope" => "omp_route", "route" => route,
        "source" => { "kind" => "first_party_pricing", "reference" => "https://example.test/prices",
                      "detail" => "deterministic fixture", "verifier" => "test fixture" },
        "verification" => { "retrieved_at" => "2026-09-01T00:00:00Z", "valid_until" => "2026-12-01T00:00:00Z" },
        "effective" => { "from" => "2026-09-01T00:00:00Z", "until" => nil },
        "applicability" => { "account_scope" => "fixture account", "plan" => nil, "conditions" => "fixture price" },
        "currency" => "USD", "categories" => {
          "input" => { "unit" => "token", "price" => 0.5, "per" => 1_000_000 },
          "output" => { "unit" => "token", "price" => index.zero? ? 2 : 0.2, "per" => 1_000_000 } } }
      [model, { "fact" => fact, "observed_route" => route, "account_scope" => "fixture account",
                "usage" => { "input" => 1000, "output" => 200 }, "at" => "2026-09-29T12:00:00Z",
                "usage_source" => "prediction:declared_workload",
                "prediction" => { "kind" => "declared_workload", "basis" => "bounded stated workload",
                                  "applies_to" => "unit-1" } }]
    end
    result = built.assess(state: state, work_unit: work_unit, route_costs: costs)
    assert(result.dig("recommendation", "first") == "orbit-agent-a" &&
           result.dig("order", "cost_comparison") == "incomparable",
           "an unmeasured Root forecast does not override the quality-order tie")
    estimate = result.dig("order", "cost_estimates", "orbit-agent-b")
    assert(estimate.dig("route", "provider") == "b" &&
           estimate.dig("source_fact", "source", "verifier") == "test fixture" &&
           estimate.dig("prediction", "basis") == "bounded stated workload" && result["route_cost_inputs"] == costs,
           "the decision retains the exact price snapshot and forecast basis for later audit")
  end

  def main
    %w[candidates_need_host_agents_and_an_empty_pool_uses_one_real_native_resolution
       a_matching_release_pays_two_judgments_and_orders_the_candidates
       insufficient_delegation_signal_stops_before_the_candidate_judgment
       a_failed_judgment_keeps_its_real_receipt_and_never_fabricates_success
       an_unchanged_assessment_is_reused_and_a_real_change_is_not
       a_stale_work_unit_and_a_broken_catalog_never_pass_as_verified
       provider_model_forecasts_price_the_actual_native_agent].each do |test|
      send(test)
      puts "MEMBER_MODEL_SELECTOR_TEST_PASS #{test}"
    end
  end
end

MemberModelSelectorTest.main
