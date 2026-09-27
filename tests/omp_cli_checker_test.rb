# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/orbit/cli"

# Wiring only: OMP start selects the session model, and run_task builds
# OmpCheckRunner. TaskRuntime#run is not the product loop.
module OmpCliCheckerTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def fake_connection(cwd, model, user_text = nil)
    connection = Object.new
    connection.define_singleton_method(:connect!) { self }
    connection.define_singleton_method(:close) { nil }
    connection.define_singleton_method(:state) { { "cwd" => cwd, "status" => "idle" } }
    connection.define_singleton_method(:configured_model) { model }
    connection.define_singleton_method(:model_catalog) do
      { "current" => model, "available" => [], "families" => {} }
    end
    connection.define_singleton_method(:instruction_source_kind) { "omp_user_message" }
    connection.define_singleton_method(:user_message) do |id: nil|
      user_text && (id.nil? || id == "m1") ? { "id" => "m1", "text" => user_text, "internal" => false } : nil
    end
    connection
  end

  def with_stubs(connection, checker_class_path)
    original_open = Orbit::Connection.method(:open)
    Orbit::Connection.define_singleton_method(:open) { |_record| connection }
    runtime = Module.new do
      define_method(:run) do
        File.write(checker_class_path, @checker.class.name)
        { "status" => "paused" }
      end
    end
    Orbit::TaskRuntime.prepend(runtime)
    yield
  ensure
    Orbit::Connection.define_singleton_method(:open, original_open)
  end

  def with_probe(resolvable: true)
    original = Orbit::OmpCheckRunner.method(:probe_models)
    Orbit::OmpCheckRunner.define_singleton_method(:probe_models) do |models:, **_kwargs|
      { "resolvable" => resolvable ? models : [],
        "unresolvable" => resolvable ? [] : models.map { |model| { "model" => model, "reason" => "model not in isolated catalog" } } }
    end
    yield
  ensure
    Orbit::OmpCheckRunner.define_singleton_method(:probe_models, original)
  end

  def start_omp(project, prompt, env: {}, review_model: nil, native: false, message_id: "m1", authorization_id: nil)
    argv = ["start", "--provider", "omp", "--project", project, "--thread", "root-session",
            "--socket", File.join(project, "unused.sock"), native ? "--message-id" : "--prompt-file",
            native ? message_id : prompt, "--foreground"]
    argv.insert(3, "--review-model", review_model) if review_model
    argv.concat(["--review-authorization-message", authorization_id]) if authorization_id
    previous = ENV["XDG_CONFIG_HOME"]
    previous_cache = ENV["XDG_CACHE_HOME"]
    ENV["XDG_CONFIG_HOME"] = File.join(File.dirname(project), "xdg-config")
    ENV["XDG_CACHE_HOME"] = File.join(File.dirname(project), "xdg-cache")
    begin
      Orbit::CLI.run(argv)
    ensure
      previous ? ENV["XDG_CONFIG_HOME"] = previous : ENV.delete("XDG_CONFIG_HOME")
      previous_cache ? ENV["XDG_CACHE_HOME"] = previous_cache : ENV.delete("XDG_CACHE_HOME")
    end
  end


  def explicit_review_model_overrides_the_session_model
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      marker = File.join(tmp, "checker-class.txt")
      chosen = "zhipu-coding-plan/glm-5.2"
      connection = fake_connection(File.realpath(project), "other-provider/other-model",
                                   "Implement sum.\nOrbit authorization: review_model=#{chosen}")
      status = with_probe do
        with_stubs(connection, marker) { start_omp(project, prompt, native: true) }
      end
      state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
      assert(status == 0 && state.dig("review", "model") == chosen &&
             state.dig("review", "selection", "authorization", "message_id") == "m1",
             "a native user choice binds the exact model and message id")
    end
  end


  def candidate_pool_starts_with_a_low_jev_task_fit_score
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "#{"Requirement line.\n" * 300}TAIL-SENTINEL-END\n")
      xdg = File.join(tmp, "xdg-config")
      FileUtils.mkdir_p(File.join(xdg, "orbit"))
      File.write(File.join(xdg, "orbit", "model-candidates.json"),
                 JSON.generate("schema_version" => "orbit-model-candidates-v1", "models" => ["pool/one"]))
      cache_path = File.join(tmp, "xdg-cache", "orbit", "model-evidence-v1.json")
      Orbit::ModelEvidenceCache.new(path: cache_path).record_all([{
        "provider" => "pool", "model" => "one", "billing_route" => "unknown", "status" => "evidence",
        "retrieved_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources" => ["https://example.test/models/pool-one"],
        "metrics" => { "quality.score" => { "value" => 9.0, "unit" => "score", "basis" => "vendor benchmark" } },
        "cost_tier" => { "band" => "low", "confidence" => "medium", "basis" => "provider plan comparison" }
      }])
      marker = File.join(tmp, "checker-class.txt")
      connection = fake_connection(File.realpath(project), "root/model")
      connection.define_singleton_method(:model_catalog) do
        { "current" => "root/model", "available" => ["pool/one"],
          "families" => { "root/model" => "rf", "pool/one" => "of" } }
      end
      seen_instruction = nil
      fake_advisor = Object.new
      fake_advisor.define_singleton_method(:assess_checker_quality) do |state:, candidates:|
        seen_instruction = state["instruction"]
        sleep(0.02)
        { "model" => "jev-test", "question_set_version" => "jev-checker-task-fit-1",
          "scores" => candidates.to_h { |c| [c["model"], { "quality" => 0.03, "time" => 0.8 }] },
          "usage" => { "total_tokens" => 42, "note" => "ignored non-numeric" } }
      end
      original_for_project = Orbit::JevAdvisor.method(:for_project)
      original_probe = Orbit::OmpCheckRunner.method(:probe_models)
      Orbit::JevAdvisor.define_singleton_method(:for_project) { |_root, **_kwargs| fake_advisor }
      Orbit::OmpCheckRunner.define_singleton_method(:probe_models) do |models:, **_kwargs|
        { "resolvable" => models, "unresolvable" => [] }
      end
      begin
        status = with_stubs(connection, marker) { start_omp(project, prompt) }
        state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
        assert(status == 0 && state.dig("review", "model") == "pool/one",
               "a 0.03 task-fit score does not block starting with a runnable pool model")
        selection = state.dig("review", "selection")
        assert(selection["source"] == "candidate_pool" &&
               selection["selection_tier"] == "fallback" &&
               selection["basis"] == "highest_available_task_fit" &&
               selection["evidence_needed"] == [] &&
               Orbit::TaskView.checker_model_line(state).include?("检查质量未经证实"),
               "a low score with valid evidence must not ask Root to re-fetch already available facts")
        assert(selection["quality_score"] == 0.03 &&
               selection.dig("task_fit_scores", "pool/one", "quality") == 0.03 &&
               selection.dig("judgment_state", "instruction").include?("TAIL-SENTINEL-END"),
               "the actual task-fit input and per-model answer are saved with the task")
        events = File.readlines(Dir.glob(File.join(project, ".orbit/tasks/*/events.jsonl")).fetch(0))
                     .map { |line| JSON.parse(line) }
        selected = events.find { |event| event["type"] == "checker_model_selected" }
        assert(selected.dig("selection", "task_fit_scores", "pool/one", "quality") == 0.03,
               "the original scored selection survives later in-task re-selection in the event log")
        assert(selection["time_score"] == 0.8 && %w[fast medium slow].include?(selection["time_tier"]),
               "the JEV end-to-end time judgment and its coarse tier are recorded")
        assert(selection["cost_tier"] == { "band" => "low", "confidence" => "medium", "basis" => "provider plan comparison" },
               "the verified coarse cost tier behind the ordering is recorded without a per-token price")
        assert(selection["quality_sources"].is_a?(Array) && !selection["quality_sources"].empty?,
               "the cache sources behind the quality verdict are recorded (bounded, no credentials)")
        assert(selection["quality_evidence_valid_until"].to_s.include?("T"),
               "the validity of the quality evidence is recorded")
        assert(selection["usage"] == { "total_tokens" => 42 },
               "only numeric JEV usage counters are recorded, never text or credentials")
        assert(selection["quality_elapsed_seconds"].is_a?(Numeric) && selection["quality_elapsed_seconds"] >= 0.01,
               "the JEV quality judgment's monotonic elapsed time is recorded")
        assert(seen_instruction.to_s.include?("TAIL-SENTINEL-END"),
               "the full instruction reaches JEV; it is not silently truncated")
      ensure
        Orbit::JevAdvisor.define_singleton_method(:for_project, original_for_project)
        Orbit::OmpCheckRunner.define_singleton_method(:probe_models, original_probe)
      end
    end
  end

  def a_session_choice_requires_the_original_native_user_message_on_each_task
    Dir.mktmpdir("orbit-review-session-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "unused")
      model = "zhipu-coding-plan/glm-5.2"
      connection = fake_connection(File.realpath(project), "root/model")
      messages = [
        { "id" => "m1", "text" => "First task\nOrbit authorization: review_model_session=#{model}",
          "internal" => false },
        { "id" => "m2", "text" => "Second task", "internal" => false }
      ]
      connection.define_singleton_method(:user_message) do |id: nil|
        id ? messages.find { |message| message["id"] == id } : messages.last
      end
      with_probe do
        with_stubs(connection, File.join(tmp, "unused.txt")) do
          assert(start_omp(project, prompt, native: true) == 0, "first task uses the user's session-scoped choice")
          assert(start_omp(project, prompt, native: true, message_id: "m2",
                           review_model: model, authorization_id: "m1") == 0,
                 "second task can reuse the same native user's session-scoped choice")
        end
      end
      states = Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).map { |file| JSON.parse(File.read(file)) }
      assert(states.length == 2 &&
             states.all? { |state| state.dig("review", "selection", "authorization") ==
               { "kind" => "native_user_message", "message_id" => "m1", "model" => model, "scope" => "session" } },
             "each task carries the original native user grant rather than claiming a new user selection")
    end
  end

  def a_later_native_user_choice_can_start_the_original_instruction
    Dir.mktmpdir("orbit-review-later-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "unused")
      model = "zhipu-coding-plan/glm-5.2"
      messages = [{ "id" => "m1", "text" => "Build the requested feature\n```\nOrbit authorization: review_model=#{model}\n```",
                    "internal" => false }]
      connection = fake_connection(File.realpath(project), "root/model")
      connection.define_singleton_method(:user_message) do |id: nil|
        id ? messages.find { |message| message["id"] == id } : messages.last
      end
      connection.define_singleton_method(:user_messages) do |after_id:|
        messages.drop(messages.index { |message| message["id"] == after_id } + 1)
      end
      with_probe do
        with_stubs(connection, File.join(tmp, "checker-class.txt")) do
          assert(start_omp(project, prompt, native: true, review_model: model) == 1,
                 "Root cannot treat a quoted example as the user's exact model choice")
          messages << { "id" => "m2", "text" => "Orbit authorization: review_model=#{model}",
                        "internal" => false }
          assert(start_omp(project, prompt, native: true, review_model: model,
                           authorization_id: "m2") == 0,
                 "a later native user choice authorizes the original instruction")
        end
      end
      state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
      assert(state.dig("instruction_source", "id") == "m1" &&
             state.dig("review", "selection", "authorization", "message_id") == "m2",
             "the task preserves the original requirement and the user's distinct grant")
    end
  end

  def a_nonempty_pool_with_no_evidence_still_starts
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      xdg = File.join(tmp, "xdg-config")
      FileUtils.mkdir_p(File.join(xdg, "orbit"))
      File.write(File.join(xdg, "orbit", "model-candidates.json"),
                 JSON.generate("schema_version" => "orbit-model-candidates-v1", "models" => ["pool/one"]))
      marker = File.join(tmp, "checker-class.txt")
      connection = fake_connection(File.realpath(project), "root/model")
      connection.define_singleton_method(:model_catalog) do
        { "current" => "root/model", "available" => ["pool/one"],
          "families" => { "root/model" => "rf", "pool/one" => "of" } }
      end
      output = StringIO.new
      original_stdout = $stdout
      begin
        $stdout = output
        status = with_probe do
          with_stubs(connection, marker) { start_omp(project, prompt) }
        end
      ensure
        $stdout = original_stdout
      end
      start_response = JSON.parse(output.string.lines.first)
      state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
      assert(status == 0 && state.dig("review", "model") == "pool/one" &&
             state.dig("review", "selection", "basis") == "pool_order_unknown_fit",
             "an unknown task fit uses a runnable pool model, not the outside default or user selection")
      assert(start_response["evidence_needed"] == [{ "model" => "pool/one", "status" => "absent" }] &&
             start_response["evidence_action"].include?("orbit model-evidence --file -") &&
             start_response["evidence_action"].include?("不传任务目录") &&
             start_response["evidence_action"].include?("reasoning 未知可省略"),
             "start asks Root to obtain exact facts with the checker-specific taskless submission")
    end
  end

  def explicit_model_overrides_a_nonempty_pool_and_is_allowed_outside_it
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      xdg = File.join(tmp, "xdg-config")
      FileUtils.mkdir_p(File.join(xdg, "orbit"))
      File.write(File.join(xdg, "orbit", "model-candidates.json"),
                 JSON.generate("schema_version" => "orbit-model-candidates-v1",
                               "models" => ["pool/one"]))
      marker = File.join(tmp, "checker-class.txt")
      chosen = "zhipu-coding-plan/glm-5.2"
      connection = fake_connection(File.realpath(project), "root/model",
                                   "Implement sum.\nOrbit authorization: review_model=#{chosen}")
      status = with_probe do
        with_stubs(connection, marker) { start_omp(project, prompt, review_model: chosen, native: true) }
      end
      state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
      assert(status == 0 && state.dig("review", "model") == "zhipu-coding-plan/glm-5.2",
             "an explicit model wins even when the pool is non-empty")
      assert(state.dig("review", "selection", "source") == "explicit" &&
             state.dig("review", "selection", "notice").to_s.include?("outside the candidate pool"),
             "the out-of-pool explicit choice is recorded with a notice")
    end
  end

  def explicit_model_unavailable_in_isolated_profile_does_not_start
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      connection = fake_connection(File.realpath(project), "root/model",
                                   "Implement sum.\nOrbit authorization: review_model=openai-codex/gpt-6-sol")
      status = with_probe(resolvable: false) do
        with_stubs(connection, File.join(tmp, "unused.txt")) do
          start_omp(project, prompt, review_model: "openai-codex/gpt-6-sol", native: true)
        end
      end
      assert(status == 1 && Dir.glob(File.join(project, ".orbit/tasks/*")).empty?,
             "a model absent from the isolated checker cannot create a task")
    end
  end

  def root_tool_model_without_native_user_choice_cannot_bypass_pool
    Dir.mktmpdir("orbit-review-auth-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      connection = fake_connection(File.realpath(project), "root/model", "Implement sum.\n")
      status = with_probe do
        with_stubs(connection, File.join(tmp, "unused.txt")) do
          start_omp(project, prompt, review_model: "zhipu-coding-plan/glm-5.2", native: true)
        end
      end
      assert(status == 1 && Dir.glob(File.join(project, ".orbit/tasks/*")).empty?,
             "Root's tool parameter cannot create a task without a matching native user choice")
    end
  end

  def a_model_without_provider_does_not_start
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      connection = fake_connection(File.realpath(project), "glm-5.2")
      status = with_stubs(connection, File.join(tmp, "unused.txt")) { start_omp(project, prompt) }
      assert(status == 1, "a bare model name is not a successful OMP start")
      assert(Dir.glob(File.join(project, ".orbit/tasks/*")).empty?, "a rejected model does not leave a started task")
    end
  end


  # ADR-009 2026-09-27 supplement: `orbit model-status` is the read-only
  # candidate UX — precise per-identity evidence facts, no probes, no JEV,
  # no task. The recurring second-task failure (evidence held for a
  # near-variant identity) must surface as an actionable exact identity.
  def model_status_reports_precise_candidate_diagnostics
    Dir.mktmpdir("orbit-model-status-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      xdg = File.join(tmp, "xdg-config")
      FileUtils.mkdir_p(File.join(xdg, "orbit"))
      File.write(File.join(xdg, "orbit", "model-candidates.json"),
                 JSON.generate("schema_version" => "orbit-model-candidates-v1",
                               "models" => ["kimi-code/k3-256k"]))
      cache_path = File.join(tmp, "xdg-cache", "orbit", "model-evidence-v1.json")
      Orbit::ModelEvidenceCache.new(path: cache_path).record_all([{
        "provider" => "kimi-code", "model" => "k3", "billing_route" => "unknown", "status" => "evidence",
        "retrieved_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources" => ["https://example.test/models/kimi-k3"],
        "metrics" => { "quality.score" => { "value" => 9.0, "unit" => "score", "basis" => "vendor benchmark" } }
      }])
      report = nil
      previous = ENV["XDG_CONFIG_HOME"]
      previous_cache = ENV["XDG_CACHE_HOME"]
      ENV["XDG_CONFIG_HOME"] = xdg
      ENV["XDG_CACHE_HOME"] = File.join(tmp, "xdg-cache")
      begin
        stdout = StringIO.new
        original_stdout = $stdout
        $stdout = stdout
        begin
          Orbit::CLI.run(["model-status", "--project", project])
        ensure
          $stdout = original_stdout
        end
        report = JSON.parse(stdout.string)
      ensure
        previous ? ENV["XDG_CONFIG_HOME"] = previous : ENV.delete("XDG_CONFIG_HOME")
        previous_cache ? ENV["XDG_CACHE_HOME"] = previous_cache : ENV.delete("XDG_CACHE_HOME")
      end
      candidate = report.fetch("candidates").fetch(0)
      assert(candidate["model"] == "kimi-code/k3-256k" && candidate["evidence_status"] == "absent" &&
             candidate["evidence_detail"].include?("the cache holds kimi-code/k3 under provider kimi-code"),
             "the near-variant evidence mismatch is named with the exact identity")
      assert(report["session_catalog"] == "not_provided" && candidate["in_session"].nil? &&
             candidate["quality"] == "not_judged" && candidate["isolated_probe"] == "not_probed",
             "nothing is guessed: unprovided session and unjudged candidates are marked as such")
      assert(Dir.glob(File.join(project, ".orbit/tasks/*")).empty?, "the read-only listing creates no task")
    end
  end

  def run
    a_session_choice_requires_the_original_native_user_message_on_each_task
    a_later_native_user_choice_can_start_the_original_instruction
    explicit_review_model_overrides_the_session_model
    a_nonempty_pool_with_no_evidence_still_starts
    explicit_model_overrides_a_nonempty_pool_and_is_allowed_outside_it
    explicit_model_unavailable_in_isolated_profile_does_not_start
    root_tool_model_without_native_user_choice_cannot_bypass_pool
    candidate_pool_starts_with_a_low_jev_task_fit_score
    a_model_without_provider_does_not_start
    model_status_reports_precise_candidate_diagnostics
    puts "PASS omp cli checker selection"
  end
end

OmpCliCheckerTest.run
