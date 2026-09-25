# frozen_string_literal: true

require_relative "../lib/orbit/checker_model_selection"

# ADR-009 structural selection: the pool, session catalog and isolated probe
# narrow candidates, but the quality line comes first. Credential
# resolvability is not quality: without verifiable evidence nothing is
# auto-picked and the caller must ask Root for an explicit model. With
# qualified candidates, end-to-end time then coarse cost then family diversity
# then pool order decide, and no time/cost facts are invented.
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

  def empty_pool_leaves_the_existing_default
    decision = Orbit::CheckerModelSelection.choose(
      pool: [], catalog: catalog(["p/one"]), quality: qualified("p/one"), resolvable: []
    )
    assert(decision["model"].nil? && decision["reason"] == "empty_pool",
           "an empty pool leaves selection to the existing default")
  end

  def resolvability_alone_is_not_quality
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: catalog(["p/one"]), quality: nil, resolvable: ["p/one"]
    )
    assert(decision["model"].nil? && decision["reason"] == "no_verifiable_quality_evidence",
           "a resolvable credential is not treated as quality, so nothing is auto-selected")

    unsourced = { "p/one" => { "verdict" => "qualified" } }
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: catalog(["p/one"]), quality: unsourced, resolvable: ["p/one"]
    )
    assert(decision["model"].nil? && decision["reason"] == "no_verifiable_quality_evidence",
           "a qualification without a source is not verifiable evidence")

    unevaluated = { "p/one" => { "verdict" => "unevaluated", "source" => "https://example.test/quality" } }
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: catalog(["p/one"]), quality: unevaluated, resolvable: ["p/one"]
    )
    assert(decision["model"].nil?, "an unevaluated model stays pending and is not auto-picked")
  end

  def prefers_a_different_family_then_pool_order
    families = { "root/model" => "root-family", "p/shared" => "root-family", "p/other" => "other-family" }
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/shared", "p/other"], catalog: catalog(["p/shared", "p/other"], families),
      quality: qualified("p/shared", "p/other"), resolvable: ["p/shared", "p/other"]
    )
    assert(decision["model"] == "p/other" && decision["basis"] == "different_family",
           "family preference compares only qualified candidates")

    same = { "root/model" => "root-family", "p/shared" => "root-family", "p/other" => "root-family" }
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/shared", "p/other"], catalog: catalog(["p/shared", "p/other"], same),
      quality: qualified("p/shared", "p/other"), resolvable: ["p/shared", "p/other"]
    )
    assert(decision["model"] == "p/shared" && decision["basis"] == "pool_order_no_other_family",
           "with no other family the user's pool order is kept")
  end

  def unqualified_models_are_excluded_before_family_and_probe
    families = { "root/model" => "rf", "p/unqualified" => "of", "p/qualified" => "rf" }
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/unqualified", "p/qualified"], catalog: catalog(["p/unqualified", "p/qualified"], families),
      quality: qualified("p/qualified"), resolvable: ["p/unqualified", "p/qualified"]
    )
    assert(decision["model"] == "p/qualified" && decision["candidates"] == ["p/qualified"],
           "an unqualified model is excluded even when it is cross-family and resolvable")
    assert(Orbit::CheckerModelSelection.qualified_candidates(
             pool: ["p/unqualified"], catalog: catalog(["p/unqualified"]), quality: qualified("p/qualified")
           ).empty?, "the quality line is applied before the probe")
  end

  def qualified_but_unresolvable_is_undecided
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: catalog(["p/one"]), quality: qualified("p/one"), resolvable: []
    )
    assert(decision["model"].nil? && decision["reason"] == "qualified_pool_models_unresolvable_in_checker",
           "a qualified model the isolated checker cannot resolve is not used")

    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: nil, quality: qualified("p/one"), resolvable: ["p/one"]
    )
    assert(decision["model"].nil? && decision["reason"] == "session_catalog_unavailable",
           "an unavailable session catalog does not silently reuse a pool entry")

    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: catalog(["p/two"]), quality: qualified("p/one"), resolvable: ["p/one"]
    )
    assert(decision["model"].nil? && decision["reason"] == "no_pool_model_in_session",
           "only the intersection of pool and session catalog is eligible")
  end

  def never_invents_evidence
    decision = Orbit::CheckerModelSelection.choose(
      pool: ["p/one"], catalog: catalog(["p/one"], { "root/model" => "rf", "p/one" => "rf" }),
      quality: qualified("p/one"), resolvable: ["p/one"]
    )
    assert(decision["reason"].include?("no time/cost facts"),
           "the selection states time/cost facts are absent instead of claiming them")
    assert(!decision.to_s.downcase.include?("best") && !decision.to_s.downcase.include?("cheap"),
           "no fabricated quality or cost ranking words")
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
    bounded = Orbit::CheckerModelSelection.cached_evidence(models: %w[pool/one pool/two pool/three], entries: entries, now: now)
    assert(bounded.keys == ["pool/one"], "only the unexpired evidence entry is used")
    assert(bounded["pool/one"]["sources"] == sources, "the validated sources are passed through")
    kept = bounded["pool/one"]["metrics"]
    assert(kept.length == 24, "all validated metrics within the cache limit are passed through")
    assert(%w[quality_reasoning swe_bench_pro code_arena_rank local_sample_latency_ms].all? { |name| kept.key?(name) },
           "real quality/local-sample names survive; no wrong prefix allowlist drops them")
    assert(!kept.key?("quality_old"), "the newest unexpired entry wins")
    assert(bounded["pool/one"]["cost_tier"] == { "band" => "low", "confidence" => "medium", "basis" => "provider plan comparison" },
           "a validated coarse cost tier is passed through for ordering, not normalized to a per-token price")
  end

  def cached_evidence_rejects_malformed_entries
    now = Time.utc(2026, 9, 25, 12, 0, 0)
    good = { "value" => 9.0, "unit" => "score", "basis" => "vendor" }
    base = { "provider" => "pool", "status" => "evidence", "retrieved_at" => "2026-09-25T10:00:00Z",
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

  def time_cost_tiers_order_within_family_and_record_the_gap
    families = { "root/model" => "rf", "p/a" => "rf", "p/b" => "rf" }
    pool = %w[p/a p/b]
    # ADR-009: after the quality line, compare end-to-end time first, then cost.
    tiers = { "p/a" => { "time" => "fast", "cost" => "high" }, "p/b" => { "time" => "slow", "cost" => "low" } }
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool, families), quality: qualified("p/a", "p/b"),
      resolvable: pool, time_cost: tiers
    )
    assert(decision["model"] == "p/a" && decision["evidence_gap"].nil?,
           "faster end-to-end time wins before coarse cost within a family")
    assert(decision["reason"].include?("time") && !decision["reason"].include?("no time/cost facts"),
           "the reason reports the time/cost evidence actually used, not a missing-facts claim")

    equal_time = { "p/a" => { "time" => "fast", "cost" => "high" }, "p/b" => { "time" => "fast", "cost" => "low" } }
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool, families), quality: qualified("p/a", "p/b"),
      resolvable: pool, time_cost: equal_time
    )
    assert(decision["model"] == "p/b", "coarse cost breaks a time tie")

    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool, families), quality: qualified("p/a", "p/b"), resolvable: pool
    )
    assert(decision["model"] == "p/a" && decision["evidence_gap"].include?("no time/cost evidence"),
           "without tiers the pool order is kept and the gap is recorded")
  end

  def total_time_precedes_family_and_missing_cost_is_a_gap
    families = { "root/model" => "rf", "p/shared" => "rf", "p/other" => "of" }
    pool = %w[p/shared p/other]
    # ADR-009: end-to-end time comes before family; a different family is only a
    # same-level preference. The same-family model is faster here, so it wins.
    tiers = { "p/shared" => { "time" => "fast", "cost" => "high" },
              "p/other" => { "time" => "slow", "cost" => "low" } }
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool, families), quality: qualified(*pool),
      resolvable: pool, time_cost: tiers
    )
    assert(decision["model"] == "p/shared" && decision["basis"] == "faster_or_cheaper_same_family",
           "end-to-end time beats family preference; family is only a same-level tie-break")

    tie = { "p/shared" => { "time" => "fast", "cost" => "low" },
            "p/other" => { "time" => "fast", "cost" => "low" } }
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool, families), quality: qualified(*pool), resolvable: pool, time_cost: tie
    )
    assert(decision["model"] == "p/other" && decision["basis"] == "different_family",
           "at equal time and cost the different family is preferred")

    partial = { "p/shared" => { "time" => "fast" }, "p/other" => { "time" => "slow", "cost" => "low" } }
    decision = Orbit::CheckerModelSelection.choose(
      pool: pool, catalog: catalog(pool, families), quality: qualified(*pool), resolvable: pool, time_cost: partial
    )
    assert(decision["model"] == "p/shared", "time still orders when one cost tier is unknown")
    assert(decision["evidence_gap"].include?("missing"),
           "a missing cost tier is recorded as a gap, not treated as free")
  end

  def run
    empty_pool_leaves_the_existing_default
    resolvability_alone_is_not_quality
    prefers_a_different_family_then_pool_order
    unqualified_models_are_excluded_before_family_and_probe
    qualified_but_unresolvable_is_undecided
    never_invents_evidence
    cached_evidence_is_bounded_and_expiry_checked
    cached_evidence_rejects_malformed_entries
    time_cost_tiers_order_within_family_and_record_the_gap
    total_time_precedes_family_and_missing_cost_is_a_gap
    puts "CHECKER_MODEL_SELECTION_TEST_PASS"
  end
end

CheckerModelSelectionTest.run
