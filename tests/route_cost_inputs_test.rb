# frozen_string_literal: true

# High-value seams only: a credible recorded prediction drives the ordering
# of candidates that already passed the quality gate; broken bindings degrade
# to unknown; unverifiable references/facts stay unknown. Fixtures are local
# and deterministic - no model or network calls.

require "fileutils"
require "tmpdir"

require_relative "../lib/orbit/route_cost_inputs"
require_relative "../lib/orbit/model_quality_policy"
require_relative "../lib/orbit/resource_call_ledger"
require_relative "../lib/orbit/work_unit"

module RouteCostInputsTest
  NOW = Time.utc(2026, 9, 29, 12, 0, 0)
  ACCOUNT = "provider account acct-1"
  PLAN = "pay as you go"

  module_function

  def assert(value, message)
    raise "ASSERTION FAILED: #{message}" unless value
  end

  def route(model)
    { "provider" => "zhipu", "model" => model, "reasoning" => "unknown", "billing_route" => "direct_api" }
  end

  def fact_document(model, output_price)
    { "schema_version" => Orbit::RouteResourceFacts::SCHEMA_VERSION, "scope" => "omp_route",
      "route" => route(model),
      "source" => { "kind" => "first_party_pricing", "detail" => "provider price list section 3",
                    "verifier" => "orbit maintainer", "reference" => "https://example.test/pricing" },
      "verification" => { "retrieved_at" => "2026-09-28T00:00:00Z", "valid_until" => "2026-10-05T00:00:00Z" },
      "effective" => { "from" => "2026-08-01T00:00:00Z", "until" => nil },
      "applicability" => { "account_scope" => ACCOUNT, "plan" => PLAN, "conditions" => "standard list price" },
      "currency" => "USD",
      "categories" => { "input" => { "unit" => "token", "price" => 0.6, "per" => 1_000_000 },
                        "output" => { "unit" => "token", "price" => output_price, "per" => 1_000_000 } } }
  end

  def prediction(kind, output, references = nil, input: 1_000)
    base = { "kind" => kind, "usage" => { "input" => input, "output" => output },
             "basis" => "same-shape unit of this task", "applies_to" => "this work unit only" }
    references ? base.merge("reference_call_ids" => references) : base
  end

  def candidate(model, prediction)
    { "route" => route(model), "account_scope" => ACCOUNT, "plan" => PLAN, "prediction" => prediction }
  end

  def with_task
    Dir.mktmpdir do |root|
      record = Orbit::TaskRecord.create(project_root: root, instruction: "Implement the approved plan",
                                        source: "test", connection: {}, review: {})
      store = Orbit::RouteResourceStore.new(project_root: root, clock: -> { NOW })
      inputs = Orbit::RouteCostInputs.new(record: record, store: store, clock: -> { NOW })
      yield root, record, store, inputs
    end
  end

  def policy_release
    Orbit::ModelQualityPolicy.binding.merge(
      "model" => "jev-1.13", "provider" => "typesafe", "scope" => Orbit::ModelQualityPolicy::SUPPORTED_PROFILE,
      "thresholds" => { "candidate_task_fit" => 0.70, "checker_task_fit" => 0.72,
                        "handoff_fit" => 0.74, "member_task_fit" => 0.71 },
      "structural_validation" => "passed", "allows_positive_ranking" => true, "proves_samples_real" => false
    )
  end

  def policy_judgment
    { "status" => "answered", "provider" => "typesafe", "model" => "jev-1.13",
      "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
      "question_set_version" => Orbit::ModelQualityPolicy::CHECKER_QUESTION_SET }
  end

  def policy_state
    Orbit::ModelQualityPolicy.project_selection_state(
      "instruction" => "Review the change", "review_role" => "reviewer",
      "acceptance" => ["regression paths pass"],
      "workspace" => { "project" => { "git" => true }, "artifact_root" => "/fixture/project" }
    )
  end

  # A Root-declared composition can show conditional amounts, but without an
  # attributed sample it cannot order candidates by total cost.
  def declared_workload_is_conditional_only
    with_task do |_root, record, store, inputs|
      store.import([fact_document("glm-5.2", 2.2), fact_document("glm-5.2x", 0.2)])
      inputs.record_inputs(scope: "review", candidates: {
        "zhipu/glm-5.2" => candidate("glm-5.2", prediction("declared_workload", 900_000)),
        "zhipu/glm-5.2x" => candidate("glm-5.2x", prediction("declared_workload", 900_000))
      })

      built = inputs.build(scope: "review")
      assert(built.keys.sort == ["zhipu/glm-5.2", "zhipu/glm-5.2x"], "both candidates priced from the imported facts")
      built.each_value do |input|
        assert(input["usage_source"] == "prediction:declared_workload", "predictions never pose as recorded usage")
        assert(input.dig("prediction", "basis") == "same-shape unit of this task" &&
               input.dig("prediction", "applies_to") == "this work unit only",
               "the forecast basis and applicability survive into the recorded decision inputs")
        assert(input["fact"].is_a?(Hash) && input["observed_route"].is_a?(Hash) && input["at"].is_a?(String),
               "the policy-validated fact/route/at shape is preserved")
      end

      signals = %w[zhipu/glm-5.2 zhipu/glm-5.2x].map do |model|
        { "id" => model, "quality" => 0.9, "question" => "checker_task_fit" }
      end
      ranking = Orbit::ModelQualityPolicy.order(signals, release: policy_release, route_costs: built,
                                                state: policy_state, judgment: policy_judgment)
      assert(ranking["basis"] == "released_task_fit" && ranking["cost_comparison"] == "incomparable" &&
             ranking["ordered_ids"].first == "zhipu/glm-5.2",
             "a declared token mix does not become an automatic cheaper-model claim")
      assert(ranking.dig("cost_estimates", "zhipu/glm-5.2x", "amount") <
             ranking.dig("cost_estimates", "zhipu/glm-5.2", "amount"),
             "conditional estimate amounts remain visible for Root to assess")
    end
  end

  # The file is bound to this task: a wrong unit, a foreign scope or a stale
  # input digest degrades to unknown without touching quality judgment.
  def broken_binding_degrades_to_unknown
    with_task do |_root, record, store, inputs|
      store.import([fact_document("glm-5.2", 2.2)])
      units = Orbit::WorkUnitStore.new(record)
      unit = units.declare("objective" => "build it", "acceptance" => "tests pass",
                           "escalation" => "stop and report", "requirements" => ["instruction"],
                           "allowed_paths" => ["lib/"])
      assert(inputs.build(scope: "review").empty?, "no file means cost unknown")

      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"),
                           candidates: { "zhipu/glm-5.2" => candidate("glm-5.2", prediction("declared_workload", 100)) })
      assert(File.stat(inputs.path).mode & 0o777 == 0o600, "the inputs file is 0600")

      bound = inputs.build(scope: "member", work_unit_id: unit.fetch("id"),
                           artifact_root: unit["artifact_root"], input_digest: unit["input_digest"])
      assert(bound.keys == ["zhipu/glm-5.2"], "the correctly bound unit builds its input")

      assert(inputs.build(scope: "member", work_unit_id: "wu-other",
                          artifact_root: unit["artifact_root"], input_digest: unit["input_digest"]).empty?,
             "another unit can never consume this unit's prediction")
      assert(inputs.build(scope: "review").empty?,
             "a member-scope file never prices the review scope")
      assert(inputs.build(scope: "member", work_unit_id: unit.fetch("id"),
                          artifact_root: unit["artifact_root"], input_digest: "stale").empty?,
             "a stale input digest degrades to unknown")

      document = JSON.parse(File.read(inputs.path)).merge("input_digest" => "hand-edited")
      File.write(inputs.path, JSON.generate(document))
      assert(inputs.build(scope: "member", work_unit_id: unit.fetch("id"),
                          artifact_root: unit["artifact_root"], input_digest: unit["input_digest"]).empty?,
             "a hand-edited binding degrades to unknown")
    end
  end

  # similar_unit references must be real: fabricated or failed calls, an
  # unaccepted unit, an unknown route or an expired fact all stay unknown;
  # only a completed, same-identity call attributed to an accepted unit of
  # this task makes the forecast credible.
  def unverifiable_references_and_facts_stay_unknown
    with_task do |_root, record, store, inputs|
      store.import([fact_document("glm-5.2", 2.2)])
      units = Orbit::WorkUnitStore.new(record)
      unit = units.declare("objective" => "build it", "acceptance" => "tests pass",
                           "escalation" => "stop and report", "requirements" => ["instruction"],
                           "allowed_paths" => ["lib/"])
      ledger = Orbit::ResourceCallLedger.new(task_path: record.path, task_id: File.basename(record.path),
                                             clock: -> { NOW })
      ledger.record(call_id: "real-1", role: "member", phase: "exec", status: "failed",
                    provider: "zhipu", actual_model: "glm-5.2", reasoning: "unknown",
                    billing_route: "direct_api", usage: { "input" => 10, "output" => 5 },
                    usage_source: "provider_response", member_id: "orbit-m1", work_unit_id: unit.fetch("id"))

      fabricated = candidate("glm-5.2", prediction("similar_unit", 100, ["never-happened"]))
      failed_call = candidate("glm-5.2", prediction("similar_unit", 100, ["real-1"]))
      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"),
                           candidates: { "zhipu/glm-5.2" => fabricated })
      args = { scope: "member", work_unit_id: unit.fetch("id"),
               artifact_root: unit["artifact_root"], input_digest: unit["input_digest"] }
      assert(inputs.build(**args).empty?, "a fabricated reference call id is not credible usage")

      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"),
                           candidates: { "zhipu/glm-5.2" => failed_call })
      assert(inputs.build(**args).empty?, "a failed call is not credible usage")

      units.bind(unit.fetch("id"), member_id: "orbit-m1", tool_call_id: "tc-1", model: "zhipu/glm-5.2")
      units.finish(unit.fetch("id"), status: "accepted", result: "done", verification: "tests pass")
      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"),
                           candidates: { "zhipu/glm-5.2" => failed_call })
      assert(inputs.build(**args).empty?, "a failed call stays uncredible even for an accepted unit")

      ledger.record(call_id: "real-2", role: "member", phase: "exec", status: "completed",
                    provider: "zhipu", actual_model: "glm-5.2", reasoning: "unknown",
                    billing_route: "direct_api", usage: { "input" => 10, "output" => 5 },
                    usage_source: "provider_response", member_id: "orbit-m1", work_unit_id: unit.fetch("id"))
      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"),
                           candidates: { "zhipu/glm-5.2" => candidate("glm-5.2", prediction("similar_unit", 100, ["real-2"])) })
      assert(inputs.build(**args).empty?, "a real reference cannot launder an invented token mix")
      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"),
                           candidates: { "zhipu/glm-5.2" => candidate("glm-5.2", prediction("similar_unit", 5, ["real-2"], input: 10)) })
      built = inputs.build(**args)
      assert(built.dig("zhipu/glm-5.2", "usage_source") == "prediction:similar_unit" &&
             built.dig("zhipu/glm-5.2", "prediction", "reference_call_ids") == ["real-2"],
             "a completed same-identity call on an accepted unit makes the forecast credible")

      # A second accepted same-role sample keeps the positive comparison path
      # real: policy may prefer the cheaper route only after both compositions
      # are tied to reported calls, not to Root-stated estimates.
      store.import(fact_document("glm-5.2x", 0.2))
      other = units.declare("objective" => "build another bounded part", "acceptance" => "tests pass",
                            "escalation" => "stop and report", "requirements" => ["instruction"],
                            "allowed_paths" => ["lib/"])
      units.bind(other.fetch("id"), member_id: "orbit-m2", tool_call_id: "tc-2", model: "zhipu/glm-5.2x")
      units.finish(other.fetch("id"), status: "accepted", result: "done", verification: "tests pass")
      ledger.record(call_id: "real-3", role: "member", phase: "exec", status: "completed",
                    provider: "zhipu", actual_model: "glm-5.2x", reasoning: "unknown",
                    billing_route: "direct_api", usage: { "input" => 10, "output" => 5 },
                    usage_source: "provider_response", member_id: "orbit-m2", work_unit_id: other.fetch("id"))
      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"), candidates: {
        "zhipu/glm-5.2" => candidate("glm-5.2", prediction("similar_unit", 5, ["real-2"], input: 10)),
        "zhipu/glm-5.2x" => candidate("glm-5.2x", prediction("similar_unit", 5, ["real-3"], input: 10))
      })
      compared = Orbit::ModelQualityPolicy.order(
        %w[zhipu/glm-5.2 zhipu/glm-5.2x].map { |model| { "id" => model, "quality" => 0.9, "question" => "checker_task_fit" } },
        release: policy_release, route_costs: inputs.build(**args), state: policy_state, judgment: policy_judgment)
      assert(compared["cost_comparison"] == "heuristic" && compared["ordered_ids"].first == "zhipu/glm-5.2x",
             "verified historical usage and route facts can still guide a released cost comparison")

      retry_unit = units.declare("objective" => "complete the retried part", "acceptance" => "tests pass",
                                 "escalation" => "stop and report", "requirements" => ["instruction"],
                                 "allowed_paths" => ["lib/"])
      units.bind(retry_unit.fetch("id"), member_id: "orbit-rejected", tool_call_id: "tc-rejected", model: "zhipu/glm-5.2")
      ledger.record(call_id: "rejected-result", role: "member", phase: "exec", status: "completed",
                    provider: "zhipu", actual_model: "glm-5.2", reasoning: "unknown",
                    billing_route: "direct_api", usage: { "input" => 10, "output" => 5 },
                    usage_source: "provider_response", member_id: "orbit-rejected", work_unit_id: retry_unit.fetch("id"))
      units.finish(retry_unit.fetch("id"), status: "rejected", result: "missing behavior", verification: "acceptance failed")
      units.bind(retry_unit.fetch("id"), member_id: "orbit-replacement", tool_call_id: "tc-replacement", model: "zhipu/glm-5.2x")
      units.finish(retry_unit.fetch("id"), status: "accepted", result: "fixed", verification: "acceptance passed")
      inputs.record_inputs(scope: "member", work_unit_id: unit.fetch("id"), candidates: {
        "zhipu/glm-5.2" => candidate("glm-5.2", prediction("similar_unit", 5, ["rejected-result"], input: 10))
      })
      assert(inputs.build(**args).empty?,
             "a later accepted replacement cannot turn a rejected member's calls into accepted historical samples")
      assert(ledger.calls.any? { |call| call["call_id"] == "rejected-result" && call.dig("usage", "input") == 10 },
             "excluding a rejected result from predictions must not erase its actual consumption")

      expired = fact_document("glm-5.2", 2.2).merge(
        "verification" => { "retrieved_at" => "2026-09-01T00:00:00Z", "valid_until" => "2026-09-02T00:00:00Z" })
      Dir.mktmpdir do |other|
        stale_store = Orbit::RouteResourceStore.new(project_root: other, clock: -> { NOW })
        stale_store.import([expired])
        stale_inputs = Orbit::RouteCostInputs.new(record: record, store: stale_store, clock: -> { NOW })
        assert(stale_inputs.build(**args).empty?, "an expired price fact yields cost unknown, never a guess")
      end
    end
  end

  def run
    declared_workload_is_conditional_only
    broken_binding_degrades_to_unknown
    unverifiable_references_and_facts_stay_unknown
    puts "ROUTE_COST_INPUTS_TEST_PASS"
  end
end

RouteCostInputsTest.run
