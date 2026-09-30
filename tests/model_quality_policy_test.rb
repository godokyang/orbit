# frozen_string_literal: true

# Selection policy: new question binding, no default release, and route-cost
# ordering that does not treat an unknown price as free or as a block.
#   ruby --disable-gems tests/model_quality_policy_test.rb

require_relative "../lib/orbit/model_quality_policy"
require "digest"
require_relative "../lib/orbit/jev_advisor"

module ModelQualityPolicyTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def thresholds
    { "candidate_task_fit" => 0.70, "checker_task_fit" => 0.72, "handoff_fit" => 0.74, "member_task_fit" => 0.71 }
  end

  SCOPE = Orbit::ModelQualityPolicy::SUPPORTED_PROFILE

  def projected_state(with_evidence = true)
    raw = {
      "instruction" => "Implement the bounded login change",
      "workspace" => { "project" => { "git" => true }, "artifact_root" => "/fixture/project" },
      "work_unit" => { "objective" => "Implement login", "acceptance" => "Login and rejection paths pass",
                       "scope" => { "allowed_paths" => ["src/login.rb"] } },
      "candidates" => [{ "agent" => "fixture", "provider" => "fixture", "model" => "model" }]
    }
    if with_evidence
      raw["model_overview_prior"] = {
        "id" => "fixture/model", "coding_index" => 70, "sources" => ["https://example.test/benchmark"],
        "measurement_date" => nil, "methodology" => nil
      }
    end
    Orbit::ModelQualityPolicy.project_selection_state(raw)
  end

  def sample(question, kind, score, expected, evidence)
    policy = Orbit::ModelQualityPolicy
    state = projected_state(evidence == "present")
    wire = { "candidate_task_fit" => "candidate_0_task_fit", "checker_task_fit" => "quality_0" }.fetch(question, question)
    item = { "id" => "#{kind}-#{question}", "kind" => kind, "mode" => "model_backed", "question" => question,
             "wire_question" => wire, "question_set_version" => policy::GATING_QUESTION_SETS.fetch(question),
             "requested_model" => "jev-1.13", "expected_positive" => expected, "state" => state }
    questions = policy.sample_questions(item)
    # Scripted structural fixture: these receipts are not real calibration evidence.
    item.merge("questions" => questions, "judgment" => {
      "schema_version" => 1, "status" => kind == "failure" ? "unavailable" : "answered",
      "source" => { "provider" => "typesafe", "actual_model" => kind == "failure" ? nil : "jev-1.13" },
      "call_id" => "scripted-call-#{kind}-#{question}", "error" => kind == "failure" ? "fixture failure" : nil,
      "answers" => kind == "failure" ? {} : questions.to_h { |id, _| [id, { "probability_true" => score }] }
    })
  end

  def judgment(question = "candidate_task_fit", **changes)
    { "provider" => "typesafe", "model" => "jev-1.13", "status" => "answered",
      "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
      "question_set_version" => Orbit::ModelQualityPolicy::GATING_QUESTION_SETS.fetch(question) }.merge(changes.transform_keys(&:to_s))
  end

  def rank(candidates, **options)
    Orbit::ModelQualityPolicy.order(candidates, state: projected_state, judgment: judgment, **options)
  end

  def route_quote(output_tokens, model: "glm-5.2")
    identity = { "provider" => "zhipu", "model" => model, "reasoning" => "unknown", "billing_route" => "direct_api" }
    { "fact" => {
        "schema_version" => Orbit::RouteResourceFacts::SCHEMA_VERSION, "scope" => "omp_route", "route" => identity,
        "source" => { "kind" => "first_party_pricing", "detail" => "provider price list section 3",
                      "verifier" => "orbit maintainer", "reference" => "https://example.test/pricing" },
        "verification" => { "retrieved_at" => "2026-09-28T00:00:00Z", "valid_until" => "2026-10-05T00:00:00Z" },
        "effective" => { "from" => "2026-08-01T00:00:00Z", "until" => nil },
        "applicability" => { "account_scope" => "provider account acct-1", "plan" => "pay as you go",
                             "conditions" => "standard list price" },
        "currency" => "USD",
        "categories" => { "input" => { "unit" => "token", "price" => 0.6, "per" => 1_000_000 },
                          "output" => { "unit" => "token", "price" => 2.2, "per" => 1_000_000 } }
      },
      "observed_route" => identity, "usage" => { "input" => 1_000, "output" => output_tokens },
      "account_scope" => "provider account acct-1", "at" => "2026-09-29T12:00:00Z" }
  end

  def document(extra = {})
    policy = Orbit::ModelQualityPolicy
    samples = []
    thresholds.each do |question, line|
      samples << sample(question, "positive", line, true, "present")
      samples << sample(question, "negative", [line - 0.25, 0.05].max, false, "present")
    end
    samples << sample("member_task_fit", "failure", nil, false, nil)
    samples << sample("member_task_fit", "missing_evidence", 0.2, false, "missing")
    policy.binding.merge(
      "model" => "jev-1.13", "provider" => "typesafe", "thresholds" => thresholds,
      "release" => { "reason" => "fixture binding only", "scope" => SCOPE,
                     "reviewed_by" => "test", "reviewed_at" => "2026-09-29T00:00:00Z" },
      "samples" => samples
    ).merge(extra)
  end

  def release
    result = Orbit::ModelQualityPolicy.validate(document("proves_samples_real" => true))
    raise result if result.is_a?(String)

    result
  end

  def fit(id, quality, question = "candidate_task_fit")
    { "id" => id, "quality" => quality, "question" => question }
  end

  def total(amount, currency = "USD")
    { "source" => "omp_route", "currency" => currency, "total" => { "amount" => amount, "currency" => currency } }
  end

  def missing_release_is_unreleased
    policy = Orbit::ModelQualityPolicy
    assert(policy.load("/fixture/nonexistent-selection-release.json").nil?, "missing release is absent")
    source = File.read(File.expand_path("../lib/orbit/model_quality_policy.rb", __dir__))
    %w[0.55 0.50 0.80].each do |legacy|
      assert(!source.include?(legacy), "the policy does not carry the old #{legacy} gate")
    end
  end

  def structure_does_not_prove_samples_or_accept_old_bindings
    policy = Orbit::ModelQualityPolicy
    reviewed = release
    assert(reviewed["structural_validation"] == "passed" && reviewed["proves_samples_real"] == false &&
           reviewed["allows_positive_ranking"] == true,
           "a matching document is a binding and still does not prove its samples happened")
    forged = reviewed.merge("proves_samples_real" => true)
    ranked = rank([fit("a", 0.99), fit("b", 0.1)], release: forged,
                           route_costs: { "b" => route_quote(1) })
    assert(ranked["positive"] == false && ranked["ordered_ids"] == %w[a b],
           "claiming the samples are proven does not unlock a positive rank")
    assert(policy.validate(document("model" => "jev-latest")).is_a?(String), "jev-latest cannot be a release model")
    stale = document
    stale["question_set_versions"] = stale["question_set_versions"].merge("candidates" => "jev-candidates-1")
    assert(policy.validate(stale).is_a?(String), "an old candidate question version does not bind")
    high_missing = document
    high_missing["samples"] = high_missing["samples"].map do |item|
      next item unless item["kind"] == "missing_evidence"

      item.merge("judgment" => item["judgment"].merge(
        "answers" => item["questions"].to_h { |id, _| [id, { "probability_true" => 0.99 }] }
      ), "expected_positive" => true)
    end
    assert(policy.validate(high_missing).is_a?(String),
           "a missing-evidence sample that clears the line does not validate a release")
    stub = document
    stub["samples"] = stub["samples"].map do |item|
      item.merge("state" => { "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
                              "task_scope" => SCOPE, "instruction" => "Implement the bounded login change",
                              "evidence_status" => "present" })
    end
    assert(policy.validate(stub).is_a?(String),
           "instruction and evidence_status markers are not the input sent to the API")
    templates = policy.question_templates
    texts_only = Digest::SHA256.hexdigest(JSON.generate(
      "handoff" => Orbit::ModelQualityPolicy::HANDOFF_TEXT,
      "member_task_fit" => Orbit::ModelQualityPolicy::MEMBER_TASK_FIT_TEXT,
      "candidate_task_fit" => Orbit::ModelQualityPolicy::CANDIDATE_TASK_FIT_TEXT,
      "checker_task_fit" => Orbit::ModelQualityPolicy::CHECKER_TASK_FIT_TEXT
    ))
    assert(templates["handoff_fit"]["criteria"]["false"] == Orbit::ModelQualityPolicy::HANDOFF_FALSE &&
           templates["versions"]["candidates"] == Orbit::ModelQualityPolicy::CANDIDATE_QUESTION_SET &&
           policy.question_digest == Digest::SHA256.hexdigest(JSON.generate(templates)) &&
           policy.question_digest != texts_only,
           "the question digest covers criteria and versions, not only the four bodies")
  end

  def unreleased_scores_and_cheap_cost_keep_input_order
    ranked = Orbit::ModelQualityPolicy.order(
      [fit("first", 0.2), fit("second", 0.99)],
      route_costs: { "second" => total(0) }
    )
    assert(ranked["positive"] == false && ranked["ordered_ids"] == %w[first second] &&
           ranked["cost_comparison"] == "not_applied" && ranked["proves_samples_real"] == false,
           "without a release, a higher score and a zero route total do not reorder")
  end

  def released_bar_then_credible_cost
    reviewed = release
    chosen = rank([fit("dear", 0.95), fit("cheap", 0.80)], release: reviewed,
                  route_costs: { "dear" => route_quote(1_000_000), "cheap" => route_quote(1_000) })
    assert(chosen["ordered_ids"] == %w[cheap dear] && chosen["positive_ids"] == %w[cheap dear] &&
           chosen["basis"] == "released_task_fit_then_route_cost_heuristic",
           "both clear the reviewed task-fit bar; credible cost guides the resource preference")
    alone = rank([fit("dear", 0.95)], release: reviewed,
                 route_costs: { "dear" => route_quote(1_000_000) })
    assert(alone["basis"] == "released_task_fit" && alone["cost_comparison"] != "heuristic",
           "one positive candidate has an estimate but no cost comparison")
    below = rank([fit("dear", 0.95), fit("cheap", 0.1)], release: reviewed,
                 route_costs: { "cheap" => route_quote(1) })
    assert(below["ordered_ids"] == %w[dear cheap] && below["positive_ids"] == ["dear"],
           "low price cannot promote a model that did not clear the task-fit bar")
    held = rank([fit("held", 0.99).merge("recommendation_hold" => true), fit("ok", 0.9)], release: reviewed)
    assert(held["ordered_ids"] == %w[ok held] && held["positive_ids"] == ["ok"], "a conflict requires Root review")
  end

  def actual_profile_model_and_question_binding
    policy = Orbit::ModelQualityPolicy
    reviewed = release
    cases = [
      [projected_state.merge("task_context" => { "task_scope" => SCOPE }), judgment],
      [projected_state, judgment(model: "jev-1.14")],
      [projected_state, judgment(provider: nil, model: nil)],
      [projected_state, judgment(question_set_version: policy::CHECKER_QUESTION_SET)],
      [projected_state, judgment(input_version: "jev-selection-input-1")],
      [projected_state, judgment(status: "unavailable")]
    ]
    cases.each_with_index do |(state, actual), index|
      result = policy.order([fit("a", 0.2), fit("b", 0.99)], release: reviewed, state: state, judgment: actual)
      assert(!result["positive"] && result["ordered_ids"] == %w[a b], "actual model, profile and question must bind")
      if index.zero?
        assert(result["reason"].include?("outside its released profile"),
               "a profile mismatch must not be reported as a missing release: #{result['reason']}")
      elsif index == 3
        assert(result["reason"].include?("different question set"),
               "a cross-question-set judgment is reported as such: #{result['reason']}")
      else
        assert(result["reason"].include?("judgment is unanswered or from another"),
               "a judgment mismatch must not be reported as a missing release: #{result['reason']}")
      end
    end
    assert(policy.activation_block(release: reviewed, state: projected_state, judgment: judgment).nil?,
           "a bound release, profile and judgment activates")
    assert(policy.activation_block(release: nil, state: projected_state, judgment: judgment) == "no_reviewed_release",
           "absent release is reported as absent")
    assert(policy.activation_block(release: reviewed, state: nil, judgment: judgment) == "task_profile_mismatch",
           "a task outside the released profile is reported as such")
    assert(policy.activation_block(release: reviewed, state: projected_state,
                                   judgment: judgment(status: "unavailable")) == "judgment_mismatch",
           "an unanswered judgment is reported as a judgment mismatch")
    checker = projected_state["task_context"].reject { |key, _| key == "work_unit" }.merge(
      "acceptance" => ["CLI result matches requirements"], "review_role" => "reviewer")
    assert(policy.profile_for(checker) == SCOPE, "bound review artifacts qualify without inventing a work unit")
    assert(!policy.ranking_release(reviewed.merge("provider" => nil, "model" => nil)), "nil identity cannot match nil metadata")
    assert(!policy.ranking_release(reviewed.merge("thresholds" => { "candidate_task_fit" => 0 })), "forged gates stay unreleased")
    altered = document
    altered["samples"].first["questions"]["candidate_0_task_fit"]["criteria"]["true"] = "Different decision"
    assert(policy.validate(altered).is_a?(String), "sample question wording is retained and bound")
    renamed = document
    renamed["samples"].first["judgment"]["answers"] = { "candidate_task_fit" => { "probability_true" => 1 } }
    assert(policy.validate(renamed).is_a?(String), "renamed raw answers cannot certify the actual wire question")
  end

  def unknown_crossed_and_non_route_prices_do_not_reorder
    reviewed = release
    unknown = rank([fit("priced", 0.9), fit("missing", 0.9)], release: reviewed,
                   route_costs: { "priced" => route_quote(1_000) })
    assert(unknown["ordered_ids"] == %w[priced missing] && unknown["cost_comparison"] == "unknown" &&
           unknown["positive_ids"] == %w[priced missing], "unknown price neither drops nor makes a candidate free")
    invalid = rank([fit("a", 0.9), fit("b", 0.9)], release: reviewed, route_costs: {
      "a" => total(1), "b" => { "status" => "priced", "amount" => 0, "currency" => "USD", "source" => "openrouter" }
    })
    assert(invalid["ordered_ids"] == %w[a b] && invalid["cost_comparison"] == "incomparable", "bare totals do not prove route cost")
    partial = route_quote(1_000)
    partial["usage"].delete("output")
    crossed = rank([fit("a", 0.9), fit("b", 0.9)], release: reviewed,
                   route_costs: { "a" => partial, "b" => route_quote(1) })
    assert(crossed["cost_comparison"] == "incomparable" && crossed["ordered_ids"] == %w[a b],
           "without complete input/output composition, unit rates do not prove task cost")
    wrong = fit("a", 0.9).merge("identity" => { "provider" => "different", "model" => "route" })
    mismatch = rank([wrong], release: reviewed, route_costs: { "a" => route_quote(1) })
    assert(mismatch["cost_comparison"] == "incomparable", "a price cannot be borrowed from another execution identity")
  end

  def unknown_cost_keeps_pool_order_among_gated_candidates
    reviewed = release
    ranked = rank([fit("pooled", 0.70), fit("flagship", 0.95),
                   fit("held", 0.99).merge("recommendation_hold" => true), fit("below", 0.10)], release: reviewed)
    assert(ranked["ordered_ids"] == %w[pooled flagship held below] && ranked["positive_ids"] == %w[pooled flagship],
           "without comparable costs the gated candidates keep the input pool order: the lower-scored pooled model stays ahead of the higher score")
    assert(ranked["basis"] == "released_task_fit" && ranked["cost_comparison"] == "unknown",
           "the incomparable branch is reported as pool order, not a cost or quality verdict")
    assert(ranked["reason"].include?("pool order") && !ranked["reason"].include?("task fit determines the order"),
           "the reason states the stable pool order without presenting task fit as an ordering advantage")
  end

  def projection_keeps_prior_and_exact_facts_apart
    projected = Orbit::ModelQualityPolicy.project_selection_state(
      "instruction" => "Add the login page",
      "elapsed_seconds" => 30,
      "work_unit" => { "goal" => "login", "handoff" => "serial" },
      "model_overview_prior" => { "id" => "moonshotai/kimi-k3", "coding_index" => 70, "agentic_index" => 40,
                                  "intelligence_index" => 55, "pricing" => { "prompt" => 1 } },
      "evidence" => { "status" => "evidence", "sources" => ["https://example.test/fact"],
                      "metrics" => { "quality_reasoning" => { "value" => 9, "unit" => "score", "basis" => "vendor" },
                                     "local_sample_latency_ms" => { "value" => 800, "unit" => "ms", "basis" => "local" } },
                      "cost_tier" => { "band" => "low" } }
    )
    prior = projected["catalog_priors"].first
    exact = projected["exact_evidence"].first
    omitted = projected["omitted_from_judgment"]
    assert(projected["combination"] == "none" && prior["coding_index"] == 70 && prior["agentic_index"] == 40 &&
           prior["intelligence_index"] == 55 && exact.dig("metrics", "quality_reasoning", "value") == 9,
           "catalog indexes and the exact quality fact both enter the input")
    assert(!prior.key?("pricing") && !exact["metrics"].key?("local_sample_latency_ms") &&
           !projected["task_context"].key?("elapsed_seconds") &&
           omitted.include?("elapsed_seconds") && omitted.include?("catalog_prior.pricing") &&
           omitted.include?("metrics.local_sample_latency_ms") && omitted.include?("exact_evidence.cost_tier") &&
           !JSON.generate(projected).include?("combined_score") && prior["not_a_weighted_input"] == true,
           "price, latency and elapsed time are omitted and no weighted total is created")
    assert(projected.dig("task_context", "work_unit", "handoff") == "serial", "the work unit stays in the task context")
    again = Orbit::ModelQualityPolicy.project_selection_state(projected)
    assert(again == projected, "projecting an envelope again does not nest it")
    dirty = projected.merge("task_context" => projected["task_context"].merge("elapsed_seconds" => 9, "speed_ratio" => 3.48))
    cleaned = Orbit::ModelQualityPolicy.project_selection_state(dirty)
    assert(!cleaned["task_context"].key?("elapsed_seconds") && !cleaned["task_context"].key?("speed_ratio") &&
           cleaned["omitted_from_judgment"].include?("elapsed_seconds") &&
           cleaned["omitted_from_judgment"].include?("speed_ratio"),
           "an envelope that still carries elapsed time or speed is projected again")
    raw = Orbit::ModelQualityPolicy.project_selection_state(
      "instruction" => "Add the login page",
      "wall_clock_ms" => 12,
      "task" => { "turn_duration_seconds" => 3, "speed_ratio" => 1.5,
                  "measurement_date" => "2026-09-01", "fetched_at" => "2026-09-29T00:00:00Z",
                  "valid_until" => "2026-10-06T00:00:00Z" }
    )
    task = raw["task_context"]["task"]
    assert(!raw["task_context"].key?("wall_clock_ms") && !task.key?("turn_duration_seconds") &&
           !task.key?("speed_ratio") &&
           raw["omitted_from_judgment"].include?("wall_clock_ms") &&
           raw["omitted_from_judgment"].include?("turn_duration_seconds"),
           "raw input strips speed, duration and wall-clock keys anywhere in the tree")
    assert(task["measurement_date"] == "2026-09-01" && task["fetched_at"] == "2026-09-29T00:00:00Z" &&
           task["valid_until"] == "2026-10-06T00:00:00Z",
           "measurement and retrieval dates stay in the selection input")
  end

  def run
    missing_release_is_unreleased
    structure_does_not_prove_samples_or_accept_old_bindings
    unreleased_scores_and_cheap_cost_keep_input_order
    released_bar_then_credible_cost
    actual_profile_model_and_question_binding
    unknown_crossed_and_non_route_prices_do_not_reorder
    unknown_cost_keeps_pool_order_among_gated_candidates
    projection_keeps_prior_and_exact_facts_apart
    puts "MODEL_QUALITY_POLICY_TEST_PASS"
  end
end

ModelQualityPolicyTest.run
