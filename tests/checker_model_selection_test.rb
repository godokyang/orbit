# frozen_string_literal: true

require_relative "../lib/orbit/checker_model_selection"
require_relative "../lib/orbit/model_quality_policy"

# A non-empty pool with a runnable checker must choose one. A task-fit signal
# prioritizes scored candidates; uncertainty uses pool order, never the
# session default. Only a catalog/probe failure leaves selection unresolved.
module CheckerModelSelectionTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def catalog(available, families = {})
    { "current" => "root/model", "available" => available, "families" => families }
  end

  def qualified(*models)
    models.to_h { |model| [model, { "verdict" => "qualified", "source" => "https://example.test/quality" }] }
  end

  def scored(pairs)
    pairs.to_h { |model, score| [model, { "verdict" => "qualified", "source" => "jev:checker_task_fit", "score" => score }] }
  end

  # Scripted policy binding; it is not a real calibration release.
  def reviewed_release
    policy = Orbit::ModelQualityPolicy
    policy.binding.merge(
      "model" => "jev-1.13", "provider" => "typesafe", "scope" => policy::SUPPORTED_PROFILE,
      "thresholds" => { "candidate_task_fit" => 0.70, "checker_task_fit" => 0.72, "handoff_fit" => 0.74, "member_task_fit" => 0.71 },
      "structural_validation" => "passed", "allows_positive_ranking" => true, "proves_samples_real" => false
    )
  end

  def selection_state
    Orbit::ModelQualityPolicy.project_selection_state(
      "instruction" => "Review the CLI", "review_role" => "reviewer", "acceptance" => ["CLI rejection paths pass"],
      "workspace" => { "project" => { "git" => true }, "artifact_root" => "/fixture/project" }
    )
  end

  def actual_judgment
    { "status" => "answered", "provider" => "typesafe", "model" => "jev-1.13",
      "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
      "question_set_version" => Orbit::ModelQualityPolicy::CHECKER_QUESTION_SET }
  end

  def route_quote(output_tokens)
    identity = { "provider" => "zhipu", "model" => "glm-5.2", "reasoning" => "unknown", "billing_route" => "direct_api" }
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

  def empty_pool_leaves_the_existing_default
    decision = Orbit::CheckerModelSelection.choose(
      pool: [], catalog: catalog(["p/one"]), quality: qualified("p/one"), resolvable: []
    )
    assert(decision["model"].nil? && decision["reason"] == "empty_pool",
           "an empty pool leaves selection to the existing default")
  end

  def no_task_fit_score_selects_a_runnable_pool_model
    pool = %w[p/first p/second]
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: nil, resolvable: ["p/second"]
    )
    assert(decision["model"] == "p/second" && decision["selection_tier"] == "fallback" &&
           decision["basis"] == "pool_order_unreleased" && decision["notice"].include?("未经证实"),
           "unknown quality still selects the runnable pool model, without claiming it passed a quality test")
  end

  def family_name_does_not_reorder_an_unreleased_pool
    families = { "root/model" => "root-family", "p/shared" => "root-family", "p/other" => "other-family" }
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/shared", "p/other"], catalog: catalog(["p/shared", "p/other"], families),
      quality: qualified("p/shared", "p/other"), resolvable: ["p/shared", "p/other"]
    )
    assert(decision["model"] == "p/shared" && decision["basis"] == "pool_order_unreleased" &&
           decision["selection_tier"] == "fallback",
           "a different family is not a released task-fit signal")
  end

  def unreleased_verdict_does_not_precede_pool_order
    pool = %w[p/unknown p/positive]
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: scored("p/positive" => 0.99), resolvable: pool
    )
    assert(decision["model"] == "p/unknown" && decision["selection_tier"] == "fallback",
           "an unreleased high score does not jump the pool order")
  end

  def unavailable_first_choice_falls_through_without_leaving_the_pool
    pool = %w[p/positive p/fallback]
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: qualified("p/positive"),
      resolvable: ["p/fallback"], fit_scores: { "p/positive" => 0.9, "p/fallback" => 0.03 }
    )
    assert(decision["model"] == "p/fallback" && decision["selection_tier"] == "fallback",
           "an unusable preferred model cannot block a runnable lower-scored pool model")

    none = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: qualified("p/positive"), resolvable: []
    )
    assert(none["model"].nil? && none["reason"] == "pool_models_unresolvable_in_checker",
           "a model cannot be invented if none of the pool can run")
  end

  def low_fit_scores_choose_highest_runnable_candidate
    pool = %w[p/first p/better]
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: {}, resolvable: pool,
      fit_scores: { "p/first" => 0.03, "p/better" => 0.42 }
    )
    assert(decision["model"] == "p/first" && decision["basis"] == "pool_order_unreleased",
           "unreleased fit scores do not rank runnable models; the task still gets the first runnable one")
  end

  def unavailable_catalog_does_not_guess_pool_membership
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: nil, quality: qualified("p/one"), resolvable: ["p/one"]
    )
    assert(decision["model"].nil? && decision["reason"] == "session_catalog_unavailable",
           "an unavailable session catalog does not authorize an unknown model")
  end

  def never_invents_evidence
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: catalog(["p/one"], { "root/model" => "rf", "p/one" => "rf" }),
      quality: qualified("p/one"), resolvable: ["p/one"]
    )
    assert(decision["reason"].include?("no reviewed release") &&
           !decision["reason"].downcase.include?("time"),
           "the selection does not invent a time or cost ranking")
    assert(!decision.to_s.downcase.include?("cheap"),
           "no fabricated cost ranking words")
  end

  def cached_evidence_is_bounded_and_expiry_checked
    now = Time.utc(2026, 9, 25, 12, 0, 0)
    metrics = {
      "quality_reasoning" => { "value" => 9.0, "unit" => "score", "basis" => "vendor" },
      "swe_bench_pro" => { "value" => 10.0, "unit" => "score", "basis" => "vendor" },
      "code_arena_rank" => { "value" => 3.0, "unit" => "rank", "basis" => "vendor" },
      "local_sample_latency_ms" => { "value" => 800.0, "unit" => "ms", "basis" => "local sample" }
    }
    20.times { |index| metrics["sample_#{index}"] = { "value" => index, "unit" => "u", "basis" => "b" } }
    sources = (1..5).map { |index| "https://example.test/source-#{index}" }
    entries = [
      { "provider" => "pool", "model" => "one", "status" => "evidence", "retrieved_at" => "2026-09-25T10:00:00Z",
        "valid_until" => "2026-09-26T10:00:00Z", "sources" => sources, "metrics" => metrics,
        "cost_tier" => { "band" => "low", "confidence" => "medium", "basis" => "provider plan comparison" } },
      { "provider" => "pool", "model" => "one", "status" => "evidence", "retrieved_at" => "2026-09-24T10:00:00Z",
        "valid_until" => "2026-09-25T11:00:00Z", "sources" => ["https://example.test/old"],
        "metrics" => { "quality_old" => { "value" => 1.0, "unit" => "u", "basis" => "b" } } },
      { "provider" => "pool", "model" => "two", "status" => "unavailable", "retrieved_at" => "2026-09-25T10:00:00Z",
        "valid_until" => "2026-09-26T10:00:00Z", "reason" => "no data" },
      { "provider" => "pool", "model" => "three", "status" => "evidence", "retrieved_at" => "2026-09-20T10:00:00Z",
        "valid_until" => "2026-09-21T10:00:00Z", "sources" => ["https://example.test/x"],
        "metrics" => { "quality_x" => { "value" => 1.0, "unit" => "u", "basis" => "b" } } }
    ]
    entries.each { |entry| entry["reasoning"] = "unknown"; entry["billing_route"] = "unknown" }
    bounded = Orbit::CheckerModelSelection.cached_evidence(models: %w[pool/one pool/two pool/three], entries: entries, now: now)
    assert(bounded.keys == ["pool/one"], "only the unexpired evidence entry is used")
    assert(bounded["pool/one"]["sources"] == sources, "the validated sources are passed through")
    kept = bounded["pool/one"]["metrics"]
    assert(kept.length == 24, "all validated metrics within the cache limit are passed through")
    assert(%w[quality_reasoning swe_bench_pro code_arena_rank local_sample_latency_ms].all? { |name| kept.key?(name) },
           "real quality/local-sample names survive; no wrong prefix allowlist drops them")
    assert(!kept.key?("quality_old"), "the newest unexpired entry wins")
    assert(bounded["pool/one"]["cost_tier"] == { "band" => "low", "confidence" => "medium", "basis" => "provider plan comparison" },
           "a validated coarse tier stays on the cached fact and is not rewritten into a token price")
  end

  def cached_evidence_rejects_malformed_entries
    now = Time.utc(2026, 9, 25, 12, 0, 0)
    good = { "value" => 9.0, "unit" => "score", "basis" => "vendor" }
    base = { "provider" => "pool", "reasoning" => "unknown", "billing_route" => "unknown",
             "status" => "evidence", "retrieved_at" => "2026-09-25T10:00:00Z",
             "valid_until" => "2026-09-26T10:00:00Z", "sources" => ["https://example.test/a"],
             "metrics" => { "quality_reasoning" => good } }
    entries = [
      base.merge("model" => "nosources", "sources" => []),
      base.merge("model" => "badurl", "sources" => ["ftp://example.test/a"]),
      base.merge("model" => "relative", "sources" => ["/not-absolute"]),
      base.merge("model" => "novalue", "metrics" => { "quality_reasoning" => { "value" => nil, "unit" => "score", "basis" => "vendor" } }),
      base.merge("model" => "nobasis", "metrics" => { "quality_reasoning" => { "value" => 9.0, "unit" => "score" } }),
      base.merge("model" => "future", "retrieved_at" => "2026-09-27T10:00:00Z"),
      base.merge("model" => "badtimestamp", "retrieved_at" => "yesterday"),
      base.merge("model" => "expired", "valid_until" => "2026-09-25T11:00:00Z"),
      base.merge("model" => "comparison", "metrics" => { "comparison.vs_other" => good }),
      base.merge("model" => "badcost", "cost_tier" => { "band" => "cheap", "confidence" => "medium", "basis" => "x" }),
      base.merge("model" => "ok")
    ]
    models = %w[pool/nosources pool/badurl pool/relative pool/novalue pool/nobasis pool/future
                pool/badtimestamp pool/expired pool/comparison pool/badcost pool/ok]
    bounded = Orbit::CheckerModelSelection.cached_evidence(models: models, entries: entries, now: now)
    assert(bounded.keys == ["pool/ok"],
           "a hand-edited entry without valid sources, values, timestamps or names is never handed to JEV")
  end

  def time_tiers_do_not_order_and_released_route_cost_can
    pool = %w[p/a p/b]
    raised = false
    begin
      Orbit::CheckerModelSelection.choose(
        pool: pool, catalog: catalog(pool), quality: scored("p/a" => 0.91, "p/b" => 0.91),
        resolvable: pool, time_cost: { "p/a" => { "time" => "fast" } }, release: reviewed_release
      )
    rescue ArgumentError
      raised = true
    end
    assert(raised, "time_cost is not a selection argument")

    released = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: scored("p/a" => 0.91, "p/b" => 0.91),
      resolvable: pool, release: reviewed_release, state: selection_state, judgment: actual_judgment,
      route_costs: { "p/a" => route_quote(1_000_000), "p/b" => route_quote(1_000) }
    )
    assert(released["model"] == "p/b" && released["basis"] == "released_task_fit_then_route_cost_heuristic" &&
           released["selection_tier"] == "preferred",
           "equal released task fit then uses the lower validated route estimate")

    higher = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: scored("p/a" => 0.95, "p/b" => 0.80),
      resolvable: pool, release: reviewed_release, state: selection_state, judgment: actual_judgment,
      route_costs: { "p/a" => route_quote(1_000_000), "p/b" => route_quote(1_000) }
    )
    assert(higher["model"] == "p/b" && higher["basis"] == "released_task_fit_then_route_cost_heuristic",
           "both clear the released task-fit bar; credible route resource estimates can guide preference")
  end

  def unknown_route_cost_does_not_promote_or_drop
    pool = %w[p/known p/unknown]
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool), quality: scored("p/known" => 0.91, "p/unknown" => 0.91),
      resolvable: pool, release: reviewed_release, state: selection_state, judgment: actual_judgment,
      route_costs: { "p/known" => route_quote(1_000) }
    )
    assert(decision["model"] == "p/known" && decision["cost_comparison"] == "unknown",
           "a missing route cost does not move that candidate ahead of pool order")
    assert(decision["candidates"].include?("p/unknown"),
           "unknown route cost does not drop the other released candidate")
  end

  def run
    empty_pool_leaves_the_existing_default
    no_task_fit_score_selects_a_runnable_pool_model
    family_name_does_not_reorder_an_unreleased_pool
    unreleased_verdict_does_not_precede_pool_order
    unavailable_first_choice_falls_through_without_leaving_the_pool
    low_fit_scores_choose_highest_runnable_candidate
    unavailable_catalog_does_not_guess_pool_membership
    never_invents_evidence
    cached_evidence_is_bounded_and_expiry_checked
    cached_evidence_rejects_malformed_entries
    time_tiers_do_not_order_and_released_route_cost_can
    unknown_route_cost_does_not_promote_or_drop
    puts "CHECKER_MODEL_SELECTION_TEST_PASS"
  end
end

CheckerModelSelectionTest.run
