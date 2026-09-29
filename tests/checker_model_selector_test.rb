# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "time"
require_relative "../lib/orbit/checker_model_selector"
require_relative "../lib/orbit/task_view"

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

  # Mirrors ModelEvidenceCache#lookup: the first entry of the same exact
  # identity that is still inside its validity window. Structural validity is
  # not part of lookup (and is checked separately), so an unavailable or
  # hand-edited record still surfaces instead of disappearing. Scripted only.
  FakeEvidence = Struct.new(:entries) do
    def stored_entries
      entries
    end

    def lookup(provider:, model:, reasoning: nil, billing_route: nil)
      return nil unless entries.is_a?(Array)

      wanted = { "provider" => provider, "model" => model, "reasoning" => reasoning || "unknown",
                 "billing_route" => billing_route || "unknown" }
      entries.find do |entry|
        next false unless entry.is_a?(Hash) && entry["provider"] == wanted["provider"] &&
                          entry["model"] == wanted["model"] && entry["reasoning"] == wanted["reasoning"] &&
                          entry.fetch("billing_route", "unknown") == wanted["billing_route"]

        expiry = Orbit::CheckerModelSelection.parse_timestamp(entry["valid_until"])
        !expiry.nil? && expiry > Time.utc(2026, 9, 25)
      end
    end
  end

  # Mirrors OpenRouterModelOverview#lookup: facts whenever the identity maps,
  # and a weak prior only for the task-selected indices. Scripted states only.
  class FakeOverview
    attr_reader :refreshes

    def initialize(states = {})
      @states = states
      @refreshes = 0
    end

    def refresh(project_root:)
      @refreshes += 1
      { "status" => "fresh" }
    end

    def status(project_root:)
      { "status" => @states.values.any? { |entry| entry["status"] == "fresh" } ? "fresh" : "not_configured" }
    end

    def lookup(model:, reasoning: "unknown", billing_route: "unknown", project_root:, indices: [],
               require_measurement_date: false)
      state = @states.fetch(model, { "status" => "not_configured" })
      return state unless state["facts"] || state["prior"]

      selected = Array(indices) & Orbit::OpenRouterModelOverview::BENCHMARK_KEYS
      prior = state["prior"]
      prior = nil if prior.nil? || selected.empty? || require_measurement_date
      { "status" => state["status"], "facts" => state["facts"], "prior" => prior }
    end

    def mapping_provenance(model:, reasoning: "unknown", billing_route: "unknown", project_root:)
      { "verified_at" => "2026-09-20T00:00:00Z", "verified_by" => "scripted source audit",
        "sources" => ["https://example.com/mapping"] }
    end
  end


  class FakeAdvisor
    attr_reader :calls

    def initialize(scores, model: "jev-1.13")
      @scores = scores
      @model = model
      @calls = 0
    end

    # Mirrors JevAdvisor#assess_checker_quality: the real provider, the real
    # question-set version and the answered status a release must match.
    def assess_checker_quality(state:, candidates:)
      @calls += 1
      @state = state
      @candidates = candidates
      { "provider" => "typesafe", "model" => @model, "status" => "answered",
        "input_version" => Orbit::ModelQualityPolicy.project_selection_state(state)["input_version"],
        "question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch("checker_quality"),
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

  def entry(model, valid_until: "2026-12-01T00:00:00Z", billing_route: "unknown", metrics: nil)
    provider, id = model.split("/", 2)
    {
      "provider" => provider, "model" => id, "reasoning" => "unknown", "billing_route" => billing_route,
      "status" => "evidence",
      "retrieved_at" => "2026-09-01T00:00:00Z", "valid_until" => valid_until,
      "sources" => ["https://example.com/facts"],
      "metrics" => metrics || { "quality_reasoning" => { "value" => 1, "unit" => "bool", "basis" => "scripted fixture" } }
    }
  end

  def selector(pool:, catalog:, entries:, advisor:, probe:, default_model: "session/default", project_root: "/tmp",
               overview: FakeOverview.new, release: nil)
    Orbit::CheckerModelSelector.new(
      connection: FakeConnection.new(catalog, default_model), project_root: project_root,
      pool: FakePool.new(pool), evidence_cache: FakeEvidence.new(entries),
      advisor: advisor, probe: probe, clock: -> { Time.utc(2026, 9, 25) }, overview: overview, release: release
    )
  end

  # A structurally valid reviewed release, matching the current questions,
  # input and decision versions. Production loads this from the calibration
  # file; here it is injected explicitly so no file is read or written.
  def release_for(model: "jev-1.13", threshold: 0.5, scope: Orbit::ModelQualityPolicy::SUPPORTED_PROFILE)
    { "allows_positive_ranking" => true, "proves_samples_real" => false,
      "decision_version" => Orbit::ModelQualityPolicy::DECISION_VERSION,
      "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
      "question_digest" => Orbit::ModelQualityPolicy.question_digest,
      "question_set_versions" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS,
      "structural_validation" => "passed", "provider" => "typesafe", "model" => model,
      "thresholds" => Orbit::ModelQualityPolicy::GATING_QUESTIONS.to_h { |question| [question, threshold] },
      "scope" => scope, "reviewed_by" => "scripted fixture", "reviewed_at" => "2026-09-25T00:00:00Z" }
  end

  # The task-record context a release scope is derived from: a git workspace
  # with a bounded work unit, plus the checker's own review role.
  def task_state(requirements: nil, review_role: "reviewer")
    unit = { "objective" => "deliver the reviewed change",
             "scope" => { "allowed_paths" => ["lib/orbit/checker_model_selector.rb"] },
             "acceptance" => ["the checker selection is verifiable"] }
    unit["model_requirements"] = requirements if requirements
    { "workspace" => { "project" => { "git" => true }, "artifact_root" => "/tmp" },
      "work_unit" => unit, "review_role" => review_role }
  end

  def root_selected_model_is_probed_and_jev_ranked_without_user_grant
    advisor = FakeAdvisor.new({ "openai/gpt-x" => { "quality" => 0.9 } })
    probe = FakeProbe.new(["openai/gpt-x"])
    model, selection = selector(pool: ["a/one"], catalog: catalog_for(["a/one", "openai/gpt-x"]),
                                entries: [entry("openai/gpt-x")], advisor: advisor, probe: probe,
                                release: release_for)
                       .select(explicit: "openai/gpt-x", instruction: "build it", state: task_state)
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
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.9 } })
    probe = FakeProbe.new(["a/one"])
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [entry("a/one")],
                     advisor: advisor, probe: probe, release: release_for)
    model, first = built.select(explicit: nil, instruction: "build it", state: task_state)
    assert(model == "a/one" && first["source"] == "candidate_pool", "the first selection judges and records")
    assert(first["judgment_provider"] == "typesafe" && first["judgment_model"] == "jev-1.13" &&
           first.dig("usage", "input") == 7 &&
           first.dig("task_fit_scores", "a/one", "quality") == 0.9 &&
           first.dig("judgment_state", "instruction") == "build it",
           "the recorded checker decision retains judgment provenance and usage")
    again, second = built.select(explicit: nil, instruction: "build it", previous: first, state: task_state)
    assert(again == "a/one" && second == first, "an unchanged input returns the recorded decision")
    assert(advisor.calls == 1 && probe.calls == 1, "no second JEV call or probe when nothing changed")
  end

  def changed_pool_reselects_before_the_next_check
    advisor = FakeAdvisor.new({ "b/two" => { "quality" => 0.9 } })
    previous = { "source" => "candidate_pool", "model" => "a/one", "signature" => "old" }
    model, selection = selector(pool: ["b/two"], catalog: catalog_for(["b/two"]), entries: [entry("b/two")],
                                advisor: advisor, probe: FakeProbe.new(["b/two"]), release: release_for)
                       .select(explicit: nil, instruction: "build it", previous: previous,
                               selected_for: "before_check", state: task_state)
    assert(model == "b/two" && selection["source"] == "candidate_pool", "a changed pool reselects")
    assert(selection["selected_for"] == "before_check" && selection["signature"].is_a?(String),
           "the reselection is marked and carries a signature")
    assert(advisor.calls == 1, "the changed pool is re-judged once")
  end

  def unreleased_task_fit_never_orders_candidates
    advisor = FakeAdvisor.new({ "a/slow" => { "quality" => 0.9 }, "b/fast" => { "quality" => 0.03 } })
    model, selection = selector(pool: ["a/slow", "b/fast"], catalog: catalog_for(["a/slow", "b/fast"]),
                                entries: [entry("a/slow"), entry("b/fast")],
                                advisor: advisor, probe: FakeProbe.new(["a/slow", "b/fast"]))
                       .select(explicit: nil, instruction: "build it", state: task_state)
    assert(model == "a/slow" && selection["selection_tier"] == "fallback" &&
           selection["basis"] == "pool_order_unreleased",
           "without a reviewed release a task-fit score never becomes a positive model ranking")
    assert(advisor.calls.zero? && selection["task_fit_scores"].empty? && selection["quality_score"].nil? &&
           selection["judgment_call_id"].nil? && selection["calibration_note"].include?("no reviewed release"),
           "without a release no paid judgment runs and no judgment field is fabricated")
    assert(selection["release"].nil? && selection["cost_comparison"] == "not_applied" &&
           selection["evidence_needed"].empty? && selection["eligibility"].is_a?(Hash) &&
           !selection.key?("time_tier") && !selection.key?("cost_tier") && !selection.key?("time_score"),
           "facts and the stable runnable order stay; no route-cost comparison and no time or coarse-tier field")
  end

  def no_valid_evidence_still_selects_a_runnable_pool_model
    advisor = FakeAdvisor.new({})
    model, selection = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [],
                                advisor: advisor, probe: FakeProbe.new(["a/one"]))
                       .select(explicit: nil, instruction: "build it")
    assert(model == "a/one" && selection["selection_tier"] == "fallback" &&
           selection["quality_score"].nil? && selection["unscored_candidates"] == ["a/one"] &&
           selection["evidence_needed"] == [{ "model" => "a/one", "reasoning" => "unknown",
                                               "billing_route" => "unknown", "status" => "absent" }],
           "a runnable model still starts and tells Root exactly which model needs real evidence")
    assert(advisor.calls.zero?, "Jev is not asked to guess without candidate evidence")
  end

  def mapped_catalog_prior_orders_only_under_a_reviewed_release
    prior = { "canonical_slug" => "moonshotai/kimi-k3-20260715",
              "coding_index" => 76.2, "agentic_index" => 50.0,
              "fetched_at" => "2026-09-25T00:00:00Z", "relevant_indices" => ["coding_index"],
              "sources" => ["https://www.kimi.com/code/docs/en/kimi-code/models.html"],
              "reasoning_note" => "推理变体未核实" }
    overview = FakeOverview.new("kimi-code/k3-256k" => { "status" => "fresh", "prior" => prior })
    models = ["a/unmapped", "kimi-code/k3-256k"]
    requirements = { "relevant_indices" => ["coding_index"] }
    advisor = FakeAdvisor.new({ "kimi-code/k3-256k" => { "quality" => 0.82 } })
    built = selector(pool: models, catalog: catalog_for(models), entries: [],
                     advisor: advisor, probe: FakeProbe.new(models), overview: overview)
    chosen, selection = built.select(explicit: nil, instruction: "Review a bounded coding change",
                                     state: task_state(requirements: requirements))
    assert(chosen == "a/unmapped" && selection["selection_tier"] == "fallback" &&
           selection["task_fit_scores"].empty? && advisor.calls.zero? &&
           selection["calibration_note"].include?("no reviewed release"),
           "without a reviewed release the mapped prior is never judged into a paid score or an order")
    assert(selection["evidence_needed"].map { |request| request["model"] } == models &&
           selection["eligibility"].is_a?(Hash),
           "the projected facts and missing exact evidence stay visible for Root without a paid judgment")

    released = selector(pool: models, catalog: catalog_for(models), entries: [],
                        advisor: FakeAdvisor.new({ "kimi-code/k3-256k" => { "quality" => 0.82 } }, model: "jev-1.13"),
                        probe: FakeProbe.new(models), overview: overview, release: release_for)
    released_model, released_selection = released.select(explicit: nil, instruction: "Review a bounded coding change",
                                                        state: task_state(requirements: requirements))
    assert(released_model == "kimi-code/k3-256k" && released_selection["selection_tier"] == "preferred" &&
           released_selection["quality_basis"] == "model_overview_prior" &&
           !released_selection.key?("time_tier") && !released_selection.key?("cost_tier"),
           "a matching reviewed release can order a prior-backed runnable checker without route time or cost")
    assert(Orbit::TaskView.checker_model_line("review" => { "model" => released_model, "selection" => released_selection })
                  .include?("不证明当前路由与推理变体适配"),
           "the user-facing checker status identifies the model-level prior's route limits")

    before = overview.refreshes
    status = built.candidate_statuses
    coverage = status["candidates"].to_h { |item| [item["model"], item] }
    assert(overview.refreshes == before && status.dig("model_overview", "status") == "fresh" &&
           coverage.dig("kimi-code/k3-256k", "model_overview") == "fresh",
           "read-only status exposes overview coverage and external-fetch state without another API refresh")
  end

  def exact_checker_facts_and_catalog_prior_are_both_presented
    prior = { "canonical_slug" => "moonshotai/kimi-k3-20260715",
              "coding_index" => 76.2, "agentic_index" => 50.0, "fetched_at" => "2026-09-25T00:00:00Z",
              "relevant_indices" => ["coding_index"],
              "sources" => ["https://www.kimi.com/code/docs/en/kimi-code/models.html"],
              "reasoning_note" => "推理变体未核实" }
    model = "kimi-code/k3-256k"
    advisor = FakeAdvisor.new({ model => { "quality" => 0.91 } })
    _, selection = selector(pool: [model], catalog: catalog_for([model]), entries: [entry(model)],
                            advisor: advisor, probe: FakeProbe.new([model]),
                            overview: FakeOverview.new(model => { "status" => "fresh", "prior" => prior }),
                            release: release_for)
                   .select(explicit: nil, instruction: "Review the change",
                           state: task_state(requirements: { "relevant_indices" => ["coding_index"] }))
    assert(advisor.candidates.first.key?("evidence") &&
           advisor.candidates.first["model_overview_prior"] == prior &&
           selection["quality_basis"] == "exact_model_evidence" &&
           selection["evidence_needed"].empty?,
           "exact route facts and the model-level prior are both presented with their own provenance")
  end

  def checker_rejects_default_reasoning_and_another_billing_route
    entries = %w[a/older a/nearby a/other].map { |model| entry(model) }
    entries << entry("a/one").merge("reasoning" => "default")
    entries << entry("a/one").merge("billing_route" => "direct_api")
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.9 } })
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: entries,
                     advisor: advisor, probe: FakeProbe.new(["a/one"]))
    model, initial = built.select(explicit: nil, instruction: "build it")
    assert(model == "a/one" && initial["selection_tier"] == "fallback" &&
           initial["evidence_needed"] == [{ "model" => "a/one", "reasoning" => "unknown",
                                            "billing_route" => "unknown", "status" => "absent" }] &&
           advisor.calls.zero?,
           "other reasoning and billing routes do not supply checker quality evidence")
    status = built.candidate_statuses["candidates"].first
    assert(status["evidence_status"] == "absent" &&
           status["evidence_detail"].include?("a/one (reasoning: default, billing_route: unknown)") &&
           status["evidence_detail"].include?("a/one (reasoning: unknown, billing_route: direct_api)"),
           "read-only diagnostics show the same-model identity mismatch ahead of unrelated cached models")

    entries << entry("a/one")
    _, updated = built.select(explicit: nil, instruction: "build it", previous: initial, selected_for: "before_check")
    assert(updated["selection_tier"] == "fallback" && updated["release"].nil? &&
           updated["quality_score"].nil? && updated["task_fit_scores"].empty? &&
           updated["evidence_needed"].empty? && advisor.calls.zero?,
           "a sourced fact under the requested identity closes the evidence request; without a release it is never a paid score")
  end

  def near_variant_evidence_does_not_fabricate_a_score
    advisor = FakeAdvisor.new({})
    model, selection = selector(pool: ["kimi-code/k3-256k"], catalog: catalog_for(["kimi-code/k3-256k"]),
                                entries: [entry("kimi-code/k3")], advisor: advisor,
                                probe: FakeProbe.new(["kimi-code/k3-256k"]))
                       .select(explicit: nil, instruction: "build it")
    assert(model == "kimi-code/k3-256k" && selection["task_fit_scores"].empty? &&
           selection["quality_sources"].empty? && advisor.calls.zero? &&
           selection["evidence_needed"] == [{ "model" => "kimi-code/k3-256k", "reasoning" => "unknown",
                                               "billing_route" => "unknown", "status" => "absent" }],
           "near-variant evidence is not transferred, and Root is asked for the exact candidate")
  end

  def submitted_checker_evidence_rejudges_before_the_next_check
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.9 } })
    entries = []
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: entries,
                     advisor: advisor, probe: FakeProbe.new(["a/one"]), release: release_for)
    model, initial = built.select(explicit: nil, instruction: "build it", state: task_state)
    assert(advisor.calls.zero?, "no evidence means no paid judgment even under a release")
    entries << entry("a/one")
    updated_model, updated = built.select(explicit: nil, instruction: "build it",
                                          previous: initial, selected_for: "before_check", state: task_state)
    assert(model == updated_model && initial["evidence_needed"].length == 1 &&
           updated["evidence_needed"].empty? && updated["quality_score"] == 0.9 &&
           updated["selected_for"] == "before_check" && advisor.calls == 1,
           "Root's new exact evidence triggers a fresh judgment and closes the evidence request")
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
    entries = [entry("b/expired", valid_until: "2026-09-20T00:00:00Z"), entry("c/valid")]
    released = selector(pool: pool, catalog: catalog_for(pool), entries: entries,
                        advisor: FakeAdvisor.new({ "c/valid" => { "quality" => 0.9 } }, model: "jev-1.13"),
                        probe: FakeProbe.new(%w[b/expired c/valid]), release: release_for)
    model, selection = released.select(explicit: nil, instruction: "build it", state: task_state)
    assert(model == "c/valid" && selection["selection_tier"] == "preferred" &&
           selection["quality_score"] == 0.9 &&
           selection["evidence_needed"] == [{ "model" => "b/expired", "reasoning" => "unknown",
                                               "billing_route" => "unknown", "status" => "expired" }],
           "a released task-fit signal orders the judged candidate and Root is asked only for the expired facts")

    unreleased_advisor = FakeAdvisor.new({ "c/valid" => { "quality" => 0.9 } })
    unreleased = selector(pool: pool, catalog: catalog_for(pool), entries: entries,
                          advisor: unreleased_advisor,
                          probe: FakeProbe.new(%w[b/expired c/valid]))
    plain_model, plain = unreleased.select(explicit: nil, instruction: "build it", state: task_state)
    assert(plain_model == "b/expired" && plain["selection_tier"] == "fallback" &&
           plain["task_fit_scores"].empty? && unreleased_advisor.calls.zero? &&
           plain["calibration_note"].include?("no reviewed release"),
           "without a release the runnable pool order decides and no paid judgment runs")
  end

  def low_score_selects_without_claiming_verified_quality
    advisor = FakeAdvisor.new({ "kimi-code/k3-256k" => { "quality" => 0.03 } })
    probe = FakeProbe.new(["kimi-code/k3-256k"])
    model, selection = selector(pool: ["kimi-code/k3-256k"], catalog: catalog_for(["kimi-code/k3-256k"]),
                                entries: [entry("kimi-code/k3-256k")], advisor: advisor, probe: probe,
                                release: release_for)
                       .select(explicit: nil, instruction: "implement approved plan", state: task_state)
    assert(model == "kimi-code/k3-256k" && selection["quality_score"] == 0.03 &&
           selection["selection_tier"] == "fallback" && selection["notice"].include?("未经证实"),
           "the reported 0.03 task-fit score ranks a runnable pooled checker, never blocks entry")
    assert(probe.models == ["kimi-code/k3-256k"] && selection.dig("judgment_state", "instruction") == "implement approved plan",
           "the actual scored input and independent checker probe remain inspectable")
  end

  def unavailable_task_fit_judgment_uses_pool_order
    advisor = Object.new
    receipt = Orbit::JudgmentResult.unavailable(
      provider: "typesafe", reason: "JEV unavailable", actual_model: "jev-failure-fixture",
      usage: { "input_tokens" => 17, "output_tokens" => 2 }
    ).to_h.merge("question_set_version" => Orbit::JevAdvisor::QUESTION_SET_VERSIONS["checker_quality"])
    advisor.define_singleton_method(:assess_checker_quality) do |**_args|
      raise Orbit::JevAdvisor::Error.new("JEV unavailable", receipt: receipt)
    end
    pool = %w[a/first b/second]
    model, selection = selector(pool: pool, catalog: catalog_for(pool),
                                entries: pool.map { |candidate| entry(candidate) },
                                advisor: advisor, probe: FakeProbe.new(pool), release: release_for)
                       .select(explicit: nil, instruction: "build it", state: task_state)
    assert(model == "a/first" && selection["selection_tier"] == "fallback" &&
           selection["quality_score"].nil? && selection["judgment_error"].include?("failed"),
           "a JEV outage never invents a score or forces a user to supply an outside-pool model")
    assert(selection["judgment_model"] == "jev-failure-fixture" && selection["usage"] == receipt["usage"] &&
           selection["task_fit_scores"].empty?,
           "failed checker selection keeps its real consumption without actionable task-fit scores")
  end

  def unresolvable_preferred_model_falls_through_to_a_runnable_pool_model
    advisor = FakeAdvisor.new({ "a/preferred" => { "quality" => 0.9 },
                                "b/fallback" => { "quality" => 0.03 } })
    probe = FakeProbe.new(["b/fallback"])
    model, selection = selector(pool: %w[a/preferred b/fallback], catalog: catalog_for(%w[a/preferred b/fallback]),
                                entries: [entry("a/preferred"), entry("b/fallback")], advisor: advisor, probe: probe,
                                release: release_for)
                       .select(explicit: nil, instruction: "build it", state: task_state)
    assert(model == "b/fallback" && selection["selection_tier"] == "fallback" &&
           advisor.state["candidates"].map { |item| item["model"] } == ["b/fallback"] &&
           probe.models == %w[a/preferred b/fallback],
           "JEV judges only runnable candidates; a high but unusable model cannot block a fallback")
  end

  def unusable_pool_falls_back_to_omp_and_keeps_jev_ranking
    advisor = FakeAdvisor.new({ "root/model" => { "quality" => 0.9 } })
    probe = FakeProbe.new(["root/model"])
    model, selection = selector(pool: ["pool/unusable"],
                                catalog: catalog_for(["pool/unusable", "root/model"]),
                                entries: [entry("root/model")], advisor: advisor, probe: probe,
                                release: release_for)
                       .select(explicit: nil, instruction: "review this change", state: task_state)
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
      advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.03 } })
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
    assert(by_model["a/valid"]["identity"] == { "provider" => "a", "model" => "valid", "reasoning" => "unknown",
                                                "billing_route" => "unknown" } &&
           by_model["a/valid"].dig("facts", "precise_evidence", "status") == "evidence" &&
           by_model["a/absent"].dig("facts", "catalog", "status") == "not_configured",
           "each candidate reports its resolved exact identity and its projected facts")
    assert(report["candidates"].all? { |candidate| candidate["quality"] == "not_judged" && candidate["isolated_probe"] == "not_probed" },
           "listing never judges or probes; unknown candidates stay unprobed")
    assert(advisor.calls.zero? && probe.calls.zero?, "the status listing is side-effect free")
  end

  def catalog_billing_route_forms_the_exact_identity
    model = "a/routed"
    catalog = catalog_for([model]).merge("routes" => { model => "subscription_quota" })
    advisor = FakeAdvisor.new({ model => { "quality" => 0.9 } })
    built = selector(pool: [model], catalog: catalog,
                     entries: [entry(model), entry(model, billing_route: "subscription_quota")],
                     advisor: advisor, probe: FakeProbe.new([model]), release: release_for)
    chosen, selection = built.select(explicit: nil, instruction: "review", state: task_state)
    assert(chosen == model && selection["model_identity"] ==
             { "provider" => "a", "model" => "routed", "reasoning" => "unknown", "billing_route" => "subscription_quota" },
           "the checker identity carries the host's resolved billing route for that exact model")
    assert(advisor.candidates.first["model"] == model &&
           advisor.candidates.first["identity"] == selection["model_identity"] &&
           advisor.candidates.first.dig("evidence", "evidence_scope") == "exact_identity",
           "the exact-identity fact reaches Jev unchanged")

    _, unverified = selector(pool: [model], catalog: catalog, entries: [entry(model)],
                             advisor: FakeAdvisor.new({}), probe: FakeProbe.new([model]))
                    .select(explicit: nil, instruction: "review")
    assert(unverified["evidence_needed"] == [{ "model" => model, "reasoning" => "unknown",
                                               "billing_route" => "subscription_quota", "status" => "absent" }],
           "facts recorded under another billing route are not evidence for this route")
  end

  def task_requirements_come_from_the_task_record
    model = "a/one"
    prior = { "canonical_slug" => "x/y", "coding_index" => 70.0, "relevant_indices" => ["coding_index"],
              "fetched_at" => "2026-09-25T00:00:00Z", "sources" => ["https://example.com/bench"] }
    overview = FakeOverview.new(model => { "status" => "fresh", "prior" => prior })
    advisor = FakeAdvisor.new({ model => { "quality" => 0.8 } })
    _, with_requirements = selector(pool: [model], catalog: catalog_for([model]), entries: [],
                                    advisor: advisor, probe: FakeProbe.new([model]), overview: overview,
                                    release: release_for)
                           .select(explicit: nil, instruction: "review",
                                   state: task_state(requirements: { "relevant_indices" => ["coding_index"] }))
    assert(advisor.calls == 1 && advisor.candidates.first["model_overview_prior"] == prior &&
           with_requirements["quality_basis"] == "model_overview_prior",
           "only the task record's explicit indices turn a catalog fact into a prior")

    mixed_catalog_advisor = FakeAdvisor.new({ model => { "quality" => 0.8 } })
    _, mixed_catalog = selector(pool: [model], catalog: catalog_for([model, "other/-invalid-identity"]), entries: [],
                               advisor: mixed_catalog_advisor, probe: FakeProbe.new([model]), overview: overview,
                               release: release_for)
                      .select(explicit: nil, instruction: "review",
                              state: task_state(requirements: { "relevant_indices" => ["coding_index"] }))
    assert(mixed_catalog_advisor.calls == 1 && mixed_catalog["requirements_error"].nil? &&
           mixed_catalog["quality_basis"] == "model_overview_prior",
           "a malformed unrelated catalog identity cannot downgrade valid task requirements or suppress Jev")

    _, plain = selector(pool: [model], catalog: catalog_for([model]), entries: [],
                        advisor: FakeAdvisor.new({}), probe: FakeProbe.new([model]), overview: overview)
               .select(explicit: nil, instruction: "review", state: task_state)
    assert(plain["quality_basis"] == "unknown" && plain["task_fit_scores"].empty?,
           "without explicit requirements no index is assumed and no prior is auto-applied")

    unusable_advisor = FakeAdvisor.new({})
    _, unusable = selector(pool: [model], catalog: catalog_for([model]), entries: [],
                           advisor: unusable_advisor, probe: FakeProbe.new([model]), overview: overview,
                           release: release_for)
                  .select(explicit: nil, instruction: "review",
                          state: task_state(requirements: { "relevant_indices" => ["not_a_benchmark"] }))
    assert(unusable["requirements_error"].to_s.include?("dropped") && unusable["task_fit_scores"].empty? &&
           unusable_advisor.calls.zero?,
           "an unusable requirements block downgrades to facts only and is never a paid judgment")

    evidenced_advisor = FakeAdvisor.new({ model => { "quality" => 0.9 } })
    _, blocked = selector(pool: [model], catalog: catalog_for([model]), entries: [entry(model)],
                          advisor: evidenced_advisor, probe: FakeProbe.new([model]), overview: overview,
                          release: release_for)
                 .select(explicit: nil, instruction: "review",
                         state: task_state(requirements: { "relevant_indices" => ["not_a_benchmark"] }))
    assert(blocked["selection_tier"] == "fallback" && blocked["task_fit_scores"].empty? &&
           evidenced_advisor.calls.zero? && blocked["calibration_note"].include?("not paid for") &&
           blocked["judgment_call_id"].nil?,
           "even with exact evidence and a release, an unusable requirements block blocks the paid call and says why")
  end

  def reviewed_release_orders_only_with_a_matching_task_profile
    model = "a/one"
    entries = [entry(model)]
    unreleased_advisor = FakeAdvisor.new({ model => { "quality" => 0.9 } })
    unreleased = selector(pool: [model], catalog: catalog_for([model]), entries: entries,
                          advisor: unreleased_advisor, probe: FakeProbe.new([model]))
    _, without = unreleased.select(explicit: nil, instruction: "review", state: task_state)
    assert(without["selection_tier"] == "fallback" && without["release"].nil? &&
           without["basis"] == "pool_order_unreleased" && unreleased_advisor.calls.zero? &&
           without["calibration_note"].include?("no reviewed release"),
           "no reviewed release means pool order without a paid judgment, with the reason recorded")

    released_advisor = FakeAdvisor.new({ model => { "quality" => 0.9 } }, model: "jev-1.13")
    released = selector(pool: [model], catalog: catalog_for([model]), entries: entries,
                        advisor: released_advisor,
                        probe: FakeProbe.new([model]), release: release_for)
    _, positive = released.select(explicit: nil, instruction: "review", state: task_state)
    assert(positive["selection_tier"] == "preferred" && positive["basis"] == "released_task_fit" &&
           positive.dig("release", "model") == "jev-1.13" && positive["judgment_model"] == "jev-1.13",
           "a reviewed release that matches the derived task profile and the actual judgment model clears the bar")

    _, other_model = selector(pool: [model], catalog: catalog_for([model]), entries: entries,
                              advisor: FakeAdvisor.new({ model => { "quality" => 0.9 } }, model: "jev-1.13"),
                              probe: FakeProbe.new([model]), release: release_for(model: "jev-1.99"))
                     .select(explicit: nil, instruction: "review", state: task_state)
    assert(other_model["selection_tier"] == "fallback",
           "a release reviewed on another judgment model only downgrades the order")

    _, other_profile = released.select(explicit: nil, instruction: "review", state: {})
    assert(other_profile["selection_tier"] == "fallback" && released_advisor.calls == 1 &&
           other_profile["calibration_note"].include?("outside the released profile"),
           "a release never applies outside the task profile derived from the record, and no second call is paid")
  end

  def conflicting_catalog_and_exact_facts_hold_the_candidate
    model = "a/one"
    prior = { "canonical_slug" => "x/y", "coding_index" => 80.0, "relevant_indices" => ["coding_index"],
              "fetched_at" => "2026-09-25T00:00:00Z", "sources" => ["https://example.com/bench"] }
    diverging = entry(model, metrics: { "coding_index" => { "value" => 20.0, "unit" => "index",
                                                           "basis" => "scripted diverging record" } })
    _, selection = selector(pool: [model], catalog: catalog_for([model]), entries: [diverging],
                            advisor: FakeAdvisor.new({ model => { "quality" => 0.95 } }), probe: FakeProbe.new([model]),
                            overview: FakeOverview.new(model => { "status" => "fresh", "prior" => prior }),
                            release: release_for)
                   .select(explicit: nil, instruction: "review",
                           state: task_state(requirements: { "relevant_indices" => ["coding_index"] }))
    assert(selection["recommendation_hold"] == true && selection["selection_tier"] == "fallback" &&
           selection["hold_reason"].to_s.include?("冲突"),
           "a potential catalog/exact conflict holds the candidate's automatic positive recommendation")
    assert(selection["quality_score"] == 0.95 && selection["eligibility"].is_a?(Hash),
           "the score and eligibility facts stay visible for Root; only the recommendation is held")
  end

  def an_explicit_choice_is_not_reused_after_the_task_state_changes
    model = "openai/gpt-x"
    advisor = FakeAdvisor.new({ model => { "quality" => 0.9 } })
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one", model]), entries: [entry(model)],
                     advisor: advisor, probe: FakeProbe.new([model]), release: release_for)
    first_model, first = built.select(explicit: model, instruction: "build it", state: task_state)
    again_model, again = built.select(explicit: model, instruction: "build it", previous: first, state: task_state)
    assert(first_model == again_model && again == first && advisor.calls == 1,
           "an unchanged explicit choice reuses the recorded decision without paying again")

    requirements = { "relevant_indices" => ["coding_index"] }
    _, changed = built.select(explicit: model, instruction: "build it", previous: first,
                              state: task_state(requirements: requirements))
    assert(advisor.calls == 2 && changed["signature"] != first["signature"] &&
           changed.dig("judgment_state", "work_unit", "model_requirements") == requirements,
           "a changed task state never reuses an old explicit suggestion")
  end

  def actual_execution_limits_hold_an_explicit_requirement_the_route_cannot_meet
    model = "kimi-code/k3-256k"
    facts = { "id" => "moonshotai/kimi-k3", "context_length" => 1_000_000, "architecture" => {},
              "capability_scope" => "model_catalog" }
    overview = FakeOverview.new(model => { "status" => "fresh", "facts" => facts })
    limits = { model => { "source" => "omp_model_registry", "context_window" => 262_144,
                          "input_modalities" => ["text"], "supports_tools" => true } }
    catalog = catalog_for([model], limits: limits)

    held = selector(pool: [model], catalog: catalog, entries: [entry(model)],
                    advisor: FakeAdvisor.new({ model => { "quality" => 0.95 } }, model: "jev-1.13"),
                    probe: FakeProbe.new([model]), overview: overview, release: release_for)
    _, selection = held.select(explicit: nil, instruction: "review",
                               state: task_state(requirements: { "required_context_tokens" => 1_048_576 }))
    assert(selection["recommendation_hold"] == true && selection["selection_tier"] == "fallback" &&
           selection.dig("execution_eligibility", "context", "status") == "unmet" &&
           selection.dig("execution_eligibility", "context", "configured_limit") == 262_144,
           "an explicit requirement the resolved route cannot meet holds the automatic recommendation")
    assert(selection.dig("execution_eligibility", "context", "configured_limit") != facts["context_length"] &&
           selection.dig("eligibility", "context", "catalog_value") == facts["context_length"],
           "the catalog's model-level limit is shown as catalog scope and never stands in for the route limit")

    met = selector(pool: [model], catalog: catalog, entries: [entry(model)],
                   advisor: FakeAdvisor.new({ model => { "quality" => 0.95 } }, model: "jev-1.13"),
                   probe: FakeProbe.new([model]), overview: overview, release: release_for)
    _, resolved = met.select(explicit: nil, instruction: "review",
                             state: task_state(requirements: { "required_context_tokens" => 131_072 }))
    assert(resolved["recommendation_hold"] == false && resolved["selection_tier"] == "preferred" &&
           resolved.dig("execution_eligibility", "context", "status") == "met",
           "a requirement the resolved route meets leaves the released order intact")

    unrequired = selector(pool: [model], catalog: catalog, entries: [entry(model)],
                          advisor: FakeAdvisor.new({ model => { "quality" => 0.95 } }, model: "jev-1.13"),
                          probe: FakeProbe.new([model]), overview: overview, release: release_for)
    _, plain = unrequired.select(explicit: nil, instruction: "review", state: task_state)
    assert(plain["recommendation_hold"] == false && plain["selection_tier"] == "preferred" &&
           plain.dig("execution_eligibility", "context", "status") == "not_required",
           "without an explicit requirement the resolved limit is not a new selection gate")
  end

  def catalog_for(available, routes: {}, limits: {})
    { "current" => "session/default", "available" => available, "routes" => routes, "limits" => limits,
      "families" => available.to_h { |model| [model, "fam-#{model.split('/').first}"] }
                            .merge("session/default" => "fam-session") }
  end

  def unclassified_overview_facts_do_not_auto_score
    facts = { "id" => "example/catalog-model", "coding_index" => 17.0,
              "context_length" => 8192, "measurement_date_status" => "unknown" }
    overview = FakeOverview.new("a/one" => { "status" => "fresh", "facts" => facts, "prior" => nil })
    advisor = FakeAdvisor.new({ "a/one" => { "quality" => 0.99 } })
    built = selector(pool: ["a/one"], catalog: catalog_for(["a/one"]), entries: [],
                     advisor: advisor, probe: FakeProbe.new(["a/one"]), overview: overview)
    model, selection = built.select(explicit: nil, instruction: "deliver the requested audit")
    assert(model == "a/one" && selection["selection_tier"] == "fallback" && advisor.calls.zero?,
           "facts without task-selected indices do not become an automatic task-fit judgment")
    report = built.candidate_statuses
    assert(report.dig("candidates", 0, "model_overview_facts") == facts && advisor.calls.zero?,
           "read-only diagnostics retain catalog facts for Root's own decision")
  end

  def main
    %w[root_selected_model_is_probed_and_jev_ranked_without_user_grant
       root_selected_model_must_be_omp_available_and_checker_resolvable
       empty_pool_uses_omp_catalog_and_checks_availability
       profile_agent_directory_is_used_by_preflight_and_recorded_for_the_check
       unchanged_input_reuses_the_recorded_decision
       changed_pool_reselects_before_the_next_check
       unreleased_task_fit_never_orders_candidates
       catalog_billing_route_forms_the_exact_identity
       task_requirements_come_from_the_task_record
       reviewed_release_orders_only_with_a_matching_task_profile
       conflicting_catalog_and_exact_facts_hold_the_candidate
       actual_execution_limits_hold_an_explicit_requirement_the_route_cannot_meet
       an_explicit_choice_is_not_reused_after_the_task_state_changes
       no_valid_evidence_still_selects_a_runnable_pool_model
       mapped_catalog_prior_orders_only_under_a_reviewed_release
       exact_checker_facts_and_catalog_prior_are_both_presented
       checker_rejects_default_reasoning_and_another_billing_route
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
       unclassified_overview_facts_do_not_auto_score
       candidate_statuses_are_read_only_and_precise].each do |test|
      send(test)
      puts "CHECKER_MODEL_SELECTOR_TEST_PASS #{test}"
    end
  end
end

CheckerModelSelectorTest.main
