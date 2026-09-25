# frozen_string_literal: true

require "json"
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

  def fake_connection(cwd, model)
    connection = Object.new
    connection.define_singleton_method(:connect!) { self }
    connection.define_singleton_method(:close) { nil }
    connection.define_singleton_method(:state) { { "cwd" => cwd, "status" => "idle" } }
    connection.define_singleton_method(:configured_model) { model }
    connection.define_singleton_method(:model_catalog) do
      { "current" => model, "available" => [], "families" => {} }
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

  def start_omp(project, prompt, env: {}, review_model: nil)
    argv = ["start", "--provider", "omp", "--project", project, "--thread", "root-session",
            "--socket", File.join(project, "unused.sock"), "--prompt-file", prompt, "--foreground"]
    argv.insert(3, "--review-model", review_model) if review_model
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

  def omp_start_uses_session_model_and_run_task_selects_omp_checker
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum and satisfy REQUIREMENTS.md.\n")
      marker = File.join(tmp, "checker-class.txt")
      connection = fake_connection(File.realpath(project), "zhipu-coding-plan/glm-5.2")
      status = with_stubs(connection, marker) { start_omp(project, prompt) }
      assert(status == 0, "OMP start with a session provider/id reaches run_task")
      assert(File.read(marker) == "Orbit::OmpCheckRunner", "run_task builds the independent OMP checker, not Codex CheckRunner")
      record = Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)
      state = JSON.parse(File.read(record))
      assert(state.dig("review", "model") == "zhipu-coding-plan/glm-5.2", "the default review model is the OMP session model")
      assert(state.dig("connection", "provider") == "omp", "the task stays on the OMP connection")
    end
  end

  def explicit_review_model_overrides_the_session_model
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      marker = File.join(tmp, "checker-class.txt")
      connection = fake_connection(File.realpath(project), "other-provider/other-model")
      status = with_stubs(connection, marker) do
        start_omp(project, prompt, review_model: "zhipu-coding-plan/glm-5.2")
      end
      assert(status == 0 && File.read(marker) == "Orbit::OmpCheckRunner", "an explicit model still uses the OMP checker")
      state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
      assert(state.dig("review", "model") == "zhipu-coding-plan/glm-5.2", "--review-model overrides the session model")
    end
  end

  def environment_review_model_overrides_the_session_model
    Dir.mktmpdir("orbit-omp-cli-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "Implement sum.\n")
      marker = File.join(tmp, "checker-class.txt")
      connection = fake_connection(File.realpath(project), "other-provider/other-model")
      previous = ENV["ORBIT_REVIEW_MODEL"]
      ENV["ORBIT_REVIEW_MODEL"] = "zhipu-coding-plan/glm-5.2"
      begin
        status = with_stubs(connection, marker) { start_omp(project, prompt) }
        state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
        assert(status == 0 && state.dig("review", "model") == "zhipu-coding-plan/glm-5.2",
               "ORBIT_REVIEW_MODEL overrides the session model and still selects the OMP checker")
      ensure
        previous ? ENV["ORBIT_REVIEW_MODEL"] = previous : ENV.delete("ORBIT_REVIEW_MODEL")
      end
    end
  end

  def candidate_pool_auto_selects_a_jev_qualified_model
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
        { "model" => "jev-test",
          "scores" => candidates.to_h { |c| [c["model"], { "quality" => 0.9, "time" => 0.8 }] },
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
               "a JEV-qualified pool model is auto-selected, not the session default")
        assert(state.dig("review", "selection", "source") == "candidate_pool" &&
               state.dig("review", "selection", "basis") == "different_family",
               "the pool decision records the cross-family basis")
        assert(state.dig("review", "selection", "evidence_gap").nil?,
               "with a verified time and coarse-cost tier the evidence gap is clear, not fabricated")
        selection = state.dig("review", "selection")
        assert(selection["quality_score"] == 0.9,
               "the JEV quality score behind the decision is recorded")
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

  def a_nonempty_pool_requires_an_explicit_model
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
      connection = fake_connection(File.realpath(project), "root/model")
      status = with_stubs(connection, marker) { start_omp(project, prompt) }
      assert(status == 1, "a non-empty pool does not silently fall back to the session default")
      assert(Dir.glob(File.join(project, ".orbit/tasks/*")).empty?,
             "no task is left running; Root must pass --review-model explicitly")
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
      connection = fake_connection(File.realpath(project), "root/model")
      status = with_stubs(connection, marker) do
        start_omp(project, prompt, review_model: "zhipu-coding-plan/glm-5.2")
      end
      state = JSON.parse(File.read(Dir.glob(File.join(project, ".orbit/tasks/*/state.json")).fetch(0)))
      assert(status == 0 && state.dig("review", "model") == "zhipu-coding-plan/glm-5.2",
             "an explicit model wins even when the pool is non-empty")
      assert(state.dig("review", "selection", "source") == "explicit" &&
             state.dig("review", "selection", "notice").to_s.include?("outside the candidate pool"),
             "the out-of-pool explicit choice is recorded with a notice")
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

  def run
    omp_start_uses_session_model_and_run_task_selects_omp_checker
    explicit_review_model_overrides_the_session_model
    environment_review_model_overrides_the_session_model
    a_nonempty_pool_requires_an_explicit_model
    explicit_model_overrides_a_nonempty_pool_and_is_allowed_outside_it
    candidate_pool_auto_selects_a_jev_qualified_model
    a_model_without_provider_does_not_start
    puts "PASS omp cli checker wiring"
  end
end

OmpCliCheckerTest.run
