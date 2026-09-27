# frozen_string_literal: true

require "stringio"
require "time"
require_relative "../lib/orbit/checker_model_selector"

# ADR-009 checker-model selection shared by `orbit start` and TaskRuntime.
# These tests cover the decision rules that matter to a running task: an
# explicit model is frozen, an empty pool keeps the session default, an
# unchanged input reuses the recorded decision without another JEV call, a
# changed pool reselects, and undecided never silently falls back.
module CheckerModelSelectorTest
  module_function

  FakePool = Struct.new(:models) do
    def read
      models
    end

    def include?(model)
      models.include?(model)
    end
  end

  FakeConnection = Struct.new(:catalog, :default) do
    def model_catalog
      catalog
    end

    def configured_model
      default
    end
  end

  FakeEvidence = Struct.new(:entries) do
    def stored_entries
      entries
    end
  end

  class FakeAdvisor
    attr_reader :calls

    def initialize(scores)
      @scores = scores
      @calls = 0
    end

    def assess_checker_quality(state:, candidates:)
      @calls += 1
      @state = state
      @candidates = candidates
      { "provider" => "typesafe", "model" => "jev-test", "question_set_version" => "jev-checker-quality-1",
        "scores" => @scores, "usage" => { "input" => 7, "output" => 3 } }
    end
    attr_reader :state, :candidates
  end

  class FakeProbe
    attr_reader :calls, :models

    def initialize(resolvable)
      @resolvable = resolvable
      @calls = 0
    end

    def call(models)
      @calls += 1
      @models = models
      { "resolvable" => @resolvable }
    end
  end

  def assert(value, message)
    raise message unless value
  end

  def assert_raises
    yield
    raise "expected a CheckerModelSelector::Error"
  rescue Orbit::CheckerModelSelector::Error => error
    error
  end

  def silence
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end

  def entry(model, cost_band: nil, valid_until: "2026-12-01T00:00:00Z")
    provider, id = model.split("/", 2)
    value = {
      "provider" => provider, "model" => id, "reasoning" => "default", "status" => "evidence",
      "retrieved_at" => "2026-09-01T00:00:00Z", "valid_until" => valid_until,
      "sources" => ["https://example.com/facts"],
      "metrics" => { "quality_reasoning" => { "value" => 1, "unit" => "bool", "basis" => "local sample" } }
    }
    value["cost_tier"] = { "band" => cost_band, "confidence" => "low", "basis" => "vendor list" } if cost_band
    value
  end

  def selector(pool:, catalog:, entries:, advisor:, probe:, default_model: "session/default")
    Orbit::CheckerModelSelector.new(
      connection: FakeConnection.new(catalog, default_model), project_root: "/tmp",
      pool: FakePool.new(pool), evidence_cache: FakeEvidence.new(entries),
      advisor: advisor, probe: probe, clock: -> { Time.utc(2026, 9, 25) }
    )
  end

  def explicit_outside_pool_is_used_with_a_notice_and_no_judgment
    advisor = FakeAdvisor.new({})
    probe = FakeProbe.new(["openai/gpt-x"])
    model, selection = silence do
      selector(pool: ["a/one"], catalog: nil, entries: [], advisor: advisor, probe: probe)
        .select(explicit: "openai/gpt-x", instruction: "build it")
    end
    assert(model == "openai/gpt-x", "an explicit model is used as given")
    assert(selection["source"] == "explicit" && selection["in_pool"] == false,
           "an outside-pool explicit model is recorded as such")
    assert(selection["notice"].to_s.include?("outside the candidate pool"), "the notice is recorded")
    assert(advisor.calls.zero? && probe.calls == 1 && probe.models == ["openai/gpt-x"],
           "an explicit start probes the isolated checker without calling JEV")
  end

  def explicit_model_missing_from_isolated_catalog_is_rejected
    advisor = FakeAdvisor.new({})
    probe = FakeProbe.new([])
    error = assert_raises do
      selector(pool: ["a/one"], catalog: nil, entries: [], advisor: advisor, probe: probe)
        .select(explicit: "openai/gpt-x", instruction: "build it")
    end
    assert(error.message.include?("unavailable") && probe.models == ["openai/gpt-x"],
           "a model absent from the isolated checker fails before task creation")
    assert(advisor.calls.zero?, "an explicit selection never calls JEV")
  end

  def empty_pool_keeps_the_session_default
    advisor = FakeAdvisor.new({})
    model, selection = selector(pool: [], catalog: nil, entries: [], advisor: advisor,
                                probe: FakeProbe.new([])).select(explicit: nil, instruction: "x")
    assert(model == "session/default" && selection["source"] == "session_default",
           "an empty pool keeps the session default")
    assert(advisor.calls.zero?, "the empty-pool path does not call JEV")
  end

  def unchanged_input_reuses_the_recorded_decision
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.9, "time" => 0.9 } })
    probe = FakeProbe.new(["a/one"])
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [entry("a/one")],
                     advisor: advisor, probe: probe)
    model, first = built.select(explicit: nil, instruction: "build it")
    assert(model == "a/one" && first["source"] == "candidate_pool", "the first selection judges and records")
    assert(first["judgment_provider"] == "typesafe" && first["judgment_model"] == "jev-test" &&
           first["question_set_version"] == "jev-checker-quality-1" && first.dig("usage", "input") == 7,
           "the recorded checker decision retains judgment provenance and usage")
    again, second = built.select(explicit: nil, instruction: "build it", previous: first)
    assert(again == "a/one" && second == first, "an unchanged input returns the recorded decision")
    assert(advisor.calls == 1 && probe.calls == 1, "no second JEV call or probe when nothing changed")
  end

  def changed_pool_reselects_before_the_next_check
    advisor = FakeAdvisor.new({ "b/two" => { "quality" => 0.9, "time" => 0.9 } })
    previous = { "source" => "candidate_pool", "model" => "a/one", "signature" => "old" }
    model, selection = selector(pool: ["b/two"], catalog: catalog_for(["b/two"]), entries: [entry("b/two")],
                                advisor: advisor, probe: FakeProbe.new(["b/two"]))
                       .select(explicit: nil, instruction: "build it", previous: previous,
                               selected_for: "before_check")
    assert(model == "b/two" && selection["source"] == "candidate_pool", "a changed pool reselects")
    assert(selection["selected_for"] == "before_check" && selection["signature"].is_a?(String),
           "the reselection is marked and carries a signature")
    assert(advisor.calls == 1, "the changed pool is re-judged once")
  end

  def end_to_end_time_orders_the_qualified_candidates
    advisor = FakeAdvisor.new({ "a/slow" => { "quality" => 0.9, "time" => 0.1 },
                                "b/fast" => { "quality" => 0.9, "time" => 0.9 } })
    model, selection = selector(pool: ["a/slow", "b/fast"], catalog: catalog_for(["a/slow", "b/fast"]),
                                entries: [entry("a/slow"), entry("b/fast")],
                                advisor: advisor, probe: FakeProbe.new(["a/slow", "b/fast"]))
                       .select(explicit: nil, instruction: "build it")
    assert(model == "b/fast", "the faster end-to-end candidate wins even when later in pool order")
    assert(selection["time_tier"] == "fast" && selection["quality_score"] == 0.9,
           "the JEV time tier and quality score are recorded")
  end

  def no_valid_evidence_is_undecided_not_a_silent_default
    advisor = FakeAdvisor.new({})
    error = assert_raises do
      selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [],
               advisor: advisor, probe: FakeProbe.new(["a/one"]))
        .select(explicit: nil, instruction: "build it")
    end
    assert(error.message.include?("valid cached quality evidence") && error.message.include?("a/one"),
           "the missing-evidence reason names the model that Root can investigate")
    assert(error.message.include?("--review-model") && advisor.calls.zero?,
           "JEV is not called without evidence; an explicit model remains available")
  end


  # ADR-009 2026-09-27 supplement: undecided errors and the read-only status
  # listing report per-candidate facts that were actually checked — the
  # recurring second-task failure was evidence for a near-variant identity
  # collapsed into one unactionable "no evidence".
  def undecided_error_lists_precise_evidence_reasons_per_identity
    advisor = FakeAdvisor.new({})
    near_variant = entry("kimi-code/k3")
    error = assert_raises do
      selector(pool: ["kimi-code/k3-256k"], catalog: catalog_for(["kimi-code/k3-256k"]),
               entries: [near_variant], advisor: advisor, probe: FakeProbe.new(["kimi-code/k3-256k"]))
        .select(explicit: nil, instruction: "build it")
    end
    assert(error.message.include?("kimi-code/k3-256k: absent") &&
           error.message.include?("the cache holds kimi-code/k3 under provider kimi-code"),
           "the absent candidate names its exact identity and the near variant actually held: #{error.message}")
    assert(error.message.include?("orbit model-evidence --file FILE|-") &&
           error.message.include?("--review-model provider/id"),
           "both recovery paths are stated")
    assert(advisor.calls.zero?, "no JEV call without evidence")
  end

  def quality_line_failure_names_each_score
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.42, "time" => 0.9 } })
    error = assert_raises do
      selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [entry("a/one")],
               advisor: advisor, probe: FakeProbe.new(["a/one"]))
        .select(explicit: nil, instruction: "build it")
    end
    assert(error.message.include?("a/one scored 0.42") && error.message.include?("threshold 0.55"),
           "the below-threshold score is named per candidate: #{error.message}")
  end

  def candidate_statuses_are_read_only_and_precise
    advisor = FakeAdvisor.new({})
    probe = FakeProbe.new([])
    built = selector(pool: ["a/valid", "a/stale", "a/absent"], catalog: nil,
                     entries: [entry("a/valid"), entry("a/stale", valid_until: "2026-09-20T00:00:00Z")],
                     advisor: advisor, probe: probe)
    report = built.candidate_statuses
    by_model = report["candidates"].to_h { |candidate| [candidate["model"], candidate] }
    assert(report["session_catalog"] == "unavailable" && by_model["a/valid"]["in_session"].nil?,
           "an unavailable catalog leaves membership unchecked, not guessed")
    assert(by_model["a/valid"]["evidence_status"] == "valid" &&
           by_model["a/stale"]["evidence_status"] == "expired" &&
           by_model["a/stale"]["evidence_detail"].to_s.include?("2026-09-20") &&
           by_model["a/absent"]["evidence_status"] == "absent",
           "per-candidate evidence facts are precise")
    assert(report["candidates"].all? { |candidate| candidate["quality"] == "not_judged" && candidate["isolated_probe"] == "not_probed" },
           "listing never judges or probes; unknown candidates stay unprobed")
    assert(advisor.calls.zero? && probe.calls.zero?, "the status listing is side-effect free")
  end

  def catalog_for(available)
    { "current" => "session/default", "available" => available,
      "families" => available.to_h { |model| [model, "fam-#{model.split('/').first}"] }
                            .merge("session/default" => "fam-session") }
  end

  def main
    %w[explicit_outside_pool_is_used_with_a_notice_and_no_judgment
       explicit_model_missing_from_isolated_catalog_is_rejected
       empty_pool_keeps_the_session_default
       unchanged_input_reuses_the_recorded_decision
       changed_pool_reselects_before_the_next_check
       end_to_end_time_orders_the_qualified_candidates
       no_valid_evidence_is_undecided_not_a_silent_default
       undecided_error_lists_precise_evidence_reasons_per_identity
       quality_line_failure_names_each_score
       candidate_statuses_are_read_only_and_precise].each do |test|
      send(test)
      puts "CHECKER_MODEL_SELECTOR_TEST_PASS #{test}"
    end
  end
end

CheckerModelSelectorTest.main
