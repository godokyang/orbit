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
    Orbit::CLI.run(argv)
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
    a_model_without_provider_does_not_start
    puts "PASS omp cli checker wiring"
  end
end

OmpCliCheckerTest.run
