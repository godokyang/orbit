# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "time"
require_relative "../lib/orbit/checker_model_selector"

# OMP availability permits models; the pool is preference. JEV still ranks
# current-task fit and unknown/low scores remain an explicitly marked fallback.
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
      { "provider" => "typesafe", "model" => "jev-test", "question_set_version" => "jev-checker-task-fit-1",
        "scores" => @scores, "usage" => { "input" => 7, "output" => 3 } }
    end
    attr_reader :state, :candidates
  end

  class FakeProbe
    attr_reader :calls, :models, :source_agent_dir, :source_project_dir

    def initialize(resolvable)
      @resolvable = resolvable
      @calls = 0
    end

    def call(models, source_agent_dir: nil, source_project_dir: nil)
      @calls += 1
      @models = models
      @source_agent_dir = source_agent_dir
      @source_project_dir = source_project_dir
      { "resolvable" => models.select { |model| @resolvable.include?(model) },
        "unresolvable" => models.reject { |model| @resolvable.include?(model) }
                               .map { |model| { "model" => model, "reason" => "unavailable" } } }
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

  def selector(pool:, catalog:, entries:, advisor:, probe:, default_model: "session/default", project_root: "/tmp")
    Orbit::CheckerModelSelector.new(
      connection: FakeConnection.new(catalog, default_model), project_root: project_root,
      pool: FakePool.new(pool), evidence_cache: FakeEvidence.new(entries),
      advisor: advisor, probe: probe, clock: -> { Time.utc(2026, 9, 25) }
    )
  end

  def root_selected_model_is_probed_and_jev_ranked_without_user_grant
    advisor = FakeAdvisor.new({ "openai/gpt-x" => { "quality" => 0.9, "time" => 0.8 } })
    probe = FakeProbe.new(["openai/gpt-x"])
    model, selection = selector(pool: ["a/one"], catalog: catalog_for(["a/one", "openai/gpt-x"]),
                                entries: [entry("openai/gpt-x")], advisor: advisor, probe: probe)
                       .select(explicit: "openai/gpt-x", instruction: "build it")
    assert(model == "openai/gpt-x" && selection["source"] == "explicit" && selection["in_pool"] == false,
           "Root may choose a current OMP model outside the preference pool")
    assert(selection["quality_score"] == 0.9 && advisor.calls == 1 &&
           probe.models == ["openai/gpt-x"], "Root's choice retains JEV task-fit and isolated preflight")
  end

  def root_selected_model_must_be_omp_available_and_checker_resolvable
    Dir.mktmpdir("orbit-root-model-") do |project|
      advisor = FakeAdvisor.new({})
      probe = FakeProbe.new([])
      built = selector(pool: ["a/one"], catalog: catalog_for(["a/one", "openai/gpt-x"]),
                       entries: [], advisor: advisor, probe: probe, project_root: project)
      error = assert_raises { built.select(explicit: "openai/gpt-x", instruction: "build it") }
      assert(error.message.include?("no unused runnable") && probe.models == ["openai/gpt-x"],
             "a Root choice absent from the isolated reviewer cannot start")
      error = assert_raises { built.select(explicit: "other/missing", instruction: "build it") }
      assert(error.message.include?("not available in this OMP session"),
             "Root cannot invent a model outside the OMP catalog")
    end
  end

  def empty_pool_uses_omp_catalog_and_checks_availability
    advisor = FakeAdvisor.new({})
    model, selection = selector(pool: [], catalog: catalog_for(["session/default", "other/second"]),
                                entries: [], advisor: advisor, probe: FakeProbe.new(["session/default"]))
                       .select(explicit: nil, instruction: "x")
    assert(model == "session/default" && selection["source"] == "omp_session" &&
           selection["selection_tier"] == "fallback", "no pool still selects a real runnable OMP model")
    assert(advisor.calls.zero?, "no verified evidence means Jev does not invent a score")
  end

  def profile_agent_directory_is_used_by_preflight_and_recorded_for_the_check
    source = "/tmp/omp-profile-agent"
    probe = FakeProbe.new(["profile/model"])
    catalog = catalog_for(["profile/model"]).merge("agent_dir" => source)
    _, selection = selector(pool: [], catalog: catalog, entries: [],
                            advisor: FakeAdvisor.new({}), probe: probe)
                   .select(explicit: nil, instruction: "review")
    assert(probe.source_agent_dir == source && selection["source_agent_dir"] == source &&
           probe.source_project_dir == "/tmp",
           "the host's active --profile and project directory bind isolated model resolution")
  end

  def unchanged_input_reuses_the_recorded_decision
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.9, "time" => 0.9 } })
    probe = FakeProbe.new(["a/one"])
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [entry("a/one")],
                     advisor: advisor, probe: probe)
    model, first = built.select(explicit: nil, instruction: "build it")
    assert(model == "a/one" && first["source"] == "candidate_pool", "the first selection judges and records")
    assert(first["judgment_provider"] == "typesafe" && first["judgment_model"] == "jev-test" &&
           first["question_set_version"] == "jev-checker-task-fit-1" && first.dig("usage", "input") == 7 &&
           first.dig("task_fit_scores", "a/one", "quality") == 0.9 &&
           first.dig("judgment_state", "instruction") == "build it",
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

  def no_valid_evidence_still_selects_a_runnable_pool_model
    advisor = FakeAdvisor.new({})
    model, selection = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [],
                                advisor: advisor, probe: FakeProbe.new(["a/one"]))
                       .select(explicit: nil, instruction: "build it")
    assert(model == "a/one" && selection["selection_tier"] == "fallback" &&
           selection["quality_score"].nil? && selection["unscored_candidates"] == ["a/one"] &&
           selection["evidence_needed"] == [{ "model" => "a/one", "status" => "absent" }],
           "a runnable model still starts and tells Root exactly which model needs real evidence")
    assert(advisor.calls.zero?, "Jev is not asked to guess without candidate evidence")
  end

  def near_variant_evidence_does_not_fabricate_a_score
    advisor = FakeAdvisor.new({})
    model, selection = selector(pool: ["kimi-code/k3-256k"], catalog: catalog_for(["kimi-code/k3-256k"]),
                                entries: [entry("kimi-code/k3")], advisor: advisor,
                                probe: FakeProbe.new(["kimi-code/k3-256k"]))
                       .select(explicit: nil, instruction: "build it")
    assert(model == "kimi-code/k3-256k" && selection["task_fit_scores"].empty? &&
           selection["quality_sources"].empty? && advisor.calls.zero? &&
           selection["evidence_needed"] == [{ "model" => "kimi-code/k3-256k", "status" => "absent" }],
           "near-variant evidence is not transferred, and Root is asked for the exact candidate")
  end

  def submitted_checker_evidence_rejudges_before_the_next_check
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.9, "time" => 0.8 } })
    entries = []
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: entries,
                     advisor: advisor, probe: FakeProbe.new(["a/one"]))
    model, initial = built.select(explicit: nil, instruction: "build it")
    entries << entry("a/one")
    updated_model, updated = built.select(explicit: nil, instruction: "build it",
                                          previous: initial, selected_for: "before_check")
    assert(model == updated_model && initial["evidence_needed"].length == 1 &&
           updated["evidence_needed"].empty? && updated["selection_tier"] == "preferred" &&
           updated["quality_score"] == 0.9 && updated["selected_for"] == "before_check" &&
           advisor.calls == 1,
           "Root's new exact evidence replaces the earlier fallback with a fresh judgment before review")
  end

  def root_unavailable_evidence_answer_closes_the_request_without_a_fake_score
    entries = []
    advisor = FakeAdvisor.new({})
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: entries,
                     advisor: advisor, probe: FakeProbe.new(["a/one"]))
    _, initial = built.select(explicit: nil, instruction: "build it")
    entries << entry("a/one").merge("status" => "unavailable", "reason" => "no verified source")
    model, updated = built.select(explicit: nil, instruction: "build it",
                                  previous: initial, selected_for: "before_check")
    assert(model == "a/one" && initial["evidence_needed"].length == 1 &&
           updated["evidence_needed"].empty? && updated["quality_score"].nil? &&
           initial["signature"] != updated["signature"] && advisor.calls.zero?,
           "an honest unavailable reply stops requesting facts without claiming model quality")
  end

  def only_runnable_candidates_with_missing_or_expired_facts_request_root_research
    pool = %w[a/unresolvable b/expired c/valid]
    advisor = FakeAdvisor.new({ "c/valid" => { "quality" => 0.9, "time" => 0.8 } })
    model, selection = selector(pool: pool, catalog: catalog_for(pool),
                                entries: [entry("b/expired", valid_until: "2026-09-20T00:00:00Z"),
                                          entry("c/valid")],
                                advisor: advisor, probe: FakeProbe.new(%w[b/expired c/valid]))
                       .select(explicit: nil, instruction: "build it")
    assert(model == "c/valid" && selection["selection_tier"] == "preferred" &&
           selection["evidence_needed"] == [{ "model" => "b/expired", "status" => "expired" }],
           "Root is asked only for missing or expired facts that could change the runnable pool ordering")
  end

  def low_score_selects_without_claiming_verified_quality
    advisor = FakeAdvisor.new({ "kimi-code/k3-256k" => { "quality" => 0.03, "time" => 0.4 } })
    probe = FakeProbe.new(["kimi-code/k3-256k"])
    model, selection = selector(pool: ["kimi-code/k3-256k"], catalog: catalog_for(["kimi-code/k3-256k"]),
                                entries: [entry("kimi-code/k3-256k")], advisor: advisor, probe: probe)
                       .select(explicit: nil, instruction: "implement approved plan")
    assert(model == "kimi-code/k3-256k" && selection["quality_score"] == 0.03 &&
           selection["selection_tier"] == "fallback" && selection["notice"].include?("未经证实"),
           "the reported 0.03 task-fit score ranks a runnable pooled checker, never blocks entry")
    assert(probe.models == ["kimi-code/k3-256k"] && selection.dig("judgment_state", "instruction") == "implement approved plan",
           "the actual scored input and independent checker probe remain inspectable")
  end

  def unavailable_task_fit_judgment_uses_pool_order
    advisor = Object.new
    advisor.define_singleton_method(:assess_checker_quality) { |**_args| raise "JEV unavailable" }
    pool = %w[a/first b/second]
    model, selection = selector(pool: pool, catalog: catalog_for(pool),
                                entries: pool.map { |candidate| entry(candidate) },
                                advisor: advisor, probe: FakeProbe.new(pool))
                       .select(explicit: nil, instruction: "build it")
    assert(model == "a/first" && selection["selection_tier"] == "fallback" &&
           selection["quality_score"].nil? && selection["judgment_error"].include?("failed"),
           "a JEV outage never invents a score or forces a user to supply an outside-pool model")
  end

  def unresolvable_preferred_model_falls_through_to_a_runnable_pool_model
    advisor = FakeAdvisor.new({ "a/preferred" => { "quality" => 0.9, "time" => 0.9 },
                                "b/fallback" => { "quality" => 0.03, "time" => 0.4 } })
    probe = FakeProbe.new(["b/fallback"])
    model, selection = selector(pool: %w[a/preferred b/fallback], catalog: catalog_for(%w[a/preferred b/fallback]),
                                entries: [entry("a/preferred"), entry("b/fallback")], advisor: advisor, probe: probe)
                       .select(explicit: nil, instruction: "build it")
    assert(model == "b/fallback" && selection["selection_tier"] == "fallback" &&
           advisor.state["candidates"].map { |item| item["model"] } == ["b/fallback"] &&
           probe.models == %w[a/preferred b/fallback],
           "JEV judges only runnable candidates; a high but unusable model cannot block a fallback")
  end

  def unusable_pool_falls_back_to_omp_and_keeps_jev_ranking
    advisor = FakeAdvisor.new({ "root/model" => { "quality" => 0.9, "time" => 0.8 } })
    probe = FakeProbe.new(["root/model"])
    model, selection = selector(pool: ["pool/unusable"],
                                catalog: catalog_for(["pool/unusable", "root/model"]),
                                entries: [entry("root/model")], advisor: advisor, probe: probe)
                       .select(explicit: nil, instruction: "review this change")
    assert(model == "root/model" && selection["source"] == "omp_session" &&
           selection["quality_score"] == 0.9 && advisor.calls == 1,
           "unrunnable pool preference falls back to another OMP model with JEV fit preserved")
  end

  def failed_model_is_excluded_from_the_next_check
    pool = %w[pool/first pool/second]
    built = selector(pool: pool, catalog: catalog_for(pool), entries: [],
                     advisor: FakeAdvisor.new({}), probe: FakeProbe.new(pool))
    first, previous = built.select(explicit: nil, instruction: "review")
    next_model, selection = built.select(explicit: nil, instruction: "review",
                                        previous: previous, excluded: [first], selected_for: "before_check")
    assert(first == "pool/first" && next_model == "pool/second" &&
           selection["signature"] != previous["signature"],
           "a failed check cannot be replayed on the same model and changes the selection signature")
  end

  def no_runnable_pool_model_records_the_failed_judgment
    Dir.mktmpdir("orbit-selection-") do |project|
      advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.03, "time" => 0.4 } })
      probe = FakeProbe.new([])
      error = assert_raises do
        selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [entry("a/one")],
                 advisor: advisor, probe: probe, project_root: project)
          .select(explicit: nil, instruction: "build it")
      end
      trace = JSON.parse(File.read(File.join(project, ".orbit", "checker-selection-failures.jsonl")))
      assert(error.message.include?("no unused runnable") &&
             trace["session_candidates"] == ["a/one"] &&
             trace.dig("isolated_probe", "resolvable") == [],
             "all unavailable models fail with the actual probe outcome, not an invented Jev score")
    end
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
    %w[root_selected_model_is_probed_and_jev_ranked_without_user_grant
       root_selected_model_must_be_omp_available_and_checker_resolvable
       empty_pool_uses_omp_catalog_and_checks_availability
       profile_agent_directory_is_used_by_preflight_and_recorded_for_the_check
       unchanged_input_reuses_the_recorded_decision
       changed_pool_reselects_before_the_next_check
       end_to_end_time_orders_the_qualified_candidates
       no_valid_evidence_still_selects_a_runnable_pool_model
       near_variant_evidence_does_not_fabricate_a_score
       low_score_selects_without_claiming_verified_quality
       unavailable_task_fit_judgment_uses_pool_order
       submitted_checker_evidence_rejudges_before_the_next_check
       root_unavailable_evidence_answer_closes_the_request_without_a_fake_score
       only_runnable_candidates_with_missing_or_expired_facts_request_root_research
       unresolvable_preferred_model_falls_through_to_a_runnable_pool_model
       no_runnable_pool_model_records_the_failed_judgment
       unusable_pool_falls_back_to_omp_and_keeps_jev_ranking
       failed_model_is_excluded_from_the_next_check
       candidate_statuses_are_read_only_and_precise].each do |test|
      send(test)
      puts "CHECKER_MODEL_SELECTOR_TEST_PASS #{test}"
    end
  end
end

CheckerModelSelectorTest.main
