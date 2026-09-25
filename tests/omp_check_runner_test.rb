# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/orbit/omp_check_runner"

# No-model stand-in for reviewer.ts. Proves the Ruby adapter reuses CheckRunner's
# prompt and schema gate, records evidence, and stops the process group. It does
# not start bun, the OMP SDK, or codex.
module OmpCheckRunnerTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def write_fake(dir)
    path = File.join(dir, "fake-reviewer.rb")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      config = JSON.parse(File.read(ARGV[ARGV.index("--config") + 1]))
      out_dir = File.dirname(config.fetch("out"))
      File.write(File.join(out_dir, "argv.json"), JSON.generate(ARGV))
      File.write(File.join(out_dir, "child-env.json"), JSON.generate(
        "PI_CODING_AGENT_DIR" => ENV["PI_CODING_AGENT_DIR"],
        "OMP_PROFILE_set" => ENV.key?("OMP_PROFILE")
      ))
      if ENV["ORBIT_FAKE_CHECK"] == "sleep"
        sleep 30
        exit 0
      end

      mode = ENV["ORBIT_FAKE_CHECK"] || "pass"
      result = {
        "verdict" => "correct", "reason" => "empty sum is undefined",
        "findings" => [{ "id" => "sum", "requirement" => "return 0", "evidence" => "src/sum.js:2", "action" => "return 0" }],
        "resolved_ids" => [], "next_check_seconds" => mode == "invalid" ? 0 : 30
      }
      File.write(config.fetch("out"), JSON.generate(
        "ok" => true, "result" => result, "model" => "zhipu-coding-plan/glm-5.2",
        "usage" => [{ "input" => 3140, "output" => 291, "cacheRead" => 2944 }],
        "fingerprint_before" => "sha256:fixed",
        "fingerprint_after" => mode == "mismatch" ? "sha256:changed" : "sha256:fixed",
        "review_ran" => true, "problems" => []
      ))
    RUBY
    File.chmod(0o755, path)
    path
  end

  def runner(fake, model: "zhipu-coding-plan/glm-5.2")
    Orbit::OmpCheckRunner.new(model: model, command: [RbConfig.ruby, fake], stop_grace_seconds: 2)
  end

  def fixture
    root = Dir.mktmpdir("orbit-omp-check-")
    snapshot = File.join(root, "snapshot")
    output = File.join(root, "output")
    FileUtils.mkdir_p(snapshot)
    File.write(File.join(snapshot, "README.md"), "fixture\n")
    [root, snapshot, output]
  end

  def inputs
    { "instruction" => "Make sum return 0 for an empty array.", "amendments" => [], "basis" => [] }
  end

  def wait_result(check)
    20.times do
      result = check.poll
      return result if result

      sleep 0.05
    end
    raise "fake reviewer did not exit"
  end

  def passes_prompt_result_usage_and_does_not_call_codex
    root, snapshot, output = fixture
    previous = ENV["OMP_PROFILE"]
    ENV["OMP_PROFILE"] = "must-not-leak"
    check = runner(write_fake(root))
    begin
      check.start(directory: snapshot, inputs: inputs, context: { "dispute" => "use the empty-array rule" }, output_dir: output, role: "adjudicator")
      result = wait_result(check)
      prompt = File.read(File.join(output, "prompt.txt"))
      request = JSON.parse(File.read(File.join(output, "request.json")))
      argv = JSON.parse(File.read(File.join(output, "argv.json")))
      child_env = JSON.parse(File.read(File.join(output, "child-env.json")))
      run = JSON.parse(File.read(File.join(output, "run.json")))
      assert(result["verdict"] == "correct" && result["findings"].first["id"] == "sum", "schema-valid result is returned")
      assert(prompt.include?("Make sum return 0 for an empty array.") && prompt.include?("adjudicator"),
             "the prompt is the adjudicator session prompt, not a fixture stub")
      assert_omp_prompt(prompt)
      assert(request["model"] == "zhipu-coding-plan/glm-5.2" && request["snapshot"] == File.realpath(snapshot),
             "the child receives the fixed snapshot and the explicit OMP model")
      assert(!argv.join(" ").include?("codex") && run["executable"] != "codex", "codex exec is not launched")
      assert(check.actual_model == "zhipu-coding-plan/glm-5.2", "actual model is recovered from evidence")
      assert(check.usage == {
               "input" => 3140, "cacheRead" => 2944, "output" => 291,
               "input_tokens" => 6084, "output_tokens" => 291, "total_tokens" => 6375
             }, "cacheRead is kept separate and included in the tokens TaskRuntime sums")
      assert(check.evidence["fingerprint_before"] == "sha256:fixed", "snapshot fingerprints are recoverable")
      assert(child_env["PI_CODING_AGENT_DIR"] == request["profile"] && child_env["OMP_PROFILE_set"] == false,
             "the child gets a private profile and not OMP_PROFILE")
      assert(File.file?(Orbit::OmpCheckRunner::REVIEWER), "the default command points at reviewer.ts")
    ensure
      previous ? ENV["OMP_PROFILE"] = previous : ENV.delete("OMP_PROFILE")
      check.close
      FileUtils.remove_entry(root)
    end
  end

  def assert_omp_prompt(prompt)
    assert(!prompt.include?("--cd") && !prompt.include?("attached output schema") && !prompt.include?("skills/orbit"),
           "old Codex mechanism words do not appear in the OMP prompt")
    assert(prompt.include?("Use the SDK read/grep/glob tools on the fixed snapshot") &&
           prompt.include?("Return JSON matching these fields"),
           "the prompt states the SDK tools and the JSON fields")
    assert(prompt.include?("did it only partly") && prompt.include?("verifiable") &&
           prompt.include?("does not reopen") && prompt.include?("not the artifact"),
           "the retained check rules stay in the prompt")
  end

  def reviewer_prompt_uses_the_same_independent_session_facts
    root, snapshot, output = fixture
    check = runner(write_fake(root))
    begin
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: output, role: "reviewer")
      wait_result(check)
      prompt = File.read(File.join(output, "prompt.txt"))
      assert(prompt.include?("independent Orbit check session") && !prompt.include?("adjudicator session"),
             "reviewer and adjudicator are different sessions")
      assert(prompt.include?("input shape") && prompt.include?("field-count") &&
             prompt.include?("even when the provided tests pass"),
             "the reviewer prompt requires explicit shape, field-count and validation rules to be verified against the enforcing code")
      assert_omp_prompt(prompt)
    ensure
      check.close
      FileUtils.remove_entry(root)
    end
  end

  def rejects_invalid_result_and_changed_fingerprint
    root, snapshot, output = fixture
    check = runner(write_fake(root))
    ENV["ORBIT_FAKE_CHECK"] = "invalid"
    begin
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: output, role: "reviewer")
      raised = false
      begin
        wait_result(check)
      rescue Orbit::CheckRunner::Error => error
        raised = error.message.include?("next_check_seconds")
      end
      assert(raised, "an invalid check result is not returned as a pass")
    ensure
      ENV.delete("ORBIT_FAKE_CHECK")
      check.close
      FileUtils.remove_entry(root)
    end

    root, snapshot, output = fixture
    check = runner(write_fake(root))
    ENV["ORBIT_FAKE_CHECK"] = "mismatch"
    begin
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: output, role: "reviewer")
      raised = false
      begin
        wait_result(check)
      rescue Orbit::CheckRunner::Error => error
        raised = error.message.include?("fingerprint")
      end
      assert(raised, "a changed snapshot fingerprint is not a pass")
    ensure
      ENV.delete("ORBIT_FAKE_CHECK")
      check.close
      FileUtils.remove_entry(root)
    end
  end

  def real_sample_cache_is_counted_and_missing_cache_is_unknown
    sample = [
      { "input" => 5497, "output" => 127, "cacheRead" => 0, "cacheWrite" => 0, "cost" => { "total" => 0 } },
      { "input" => 206, "output" => 43, "cacheRead" => 5440, "cacheWrite" => 0 },
      { "input" => 166, "output" => 732, "cacheRead" => 5632, "reasoningTokens" => 518 }
    ]
    usage = Orbit::OmpCheckRunner.normalize_usage(sample)
    assert(usage["input"] == 5869 && usage["cacheRead"] == 11072 && usage["output"] == 902,
           "the real sample split is preserved")
    assert(usage["input_tokens"] + usage["output_tokens"] == 17843 && usage["total_tokens"] == 17843,
           "TaskRuntime's input_tokens + output_tokens includes cacheRead and matches the sample total")
    assert(!usage.key?("cost"), "directory price is not copied or invented")
    assert(Orbit::OmpCheckRunner.normalize_usage([{ "input" => 1, "output" => 1 }]).nil?,
           "missing cacheRead stays unknown instead of being treated as free")
  end

  def stops_the_process_group
    root, snapshot, output = fixture
    check = runner(write_fake(root))
    ENV["ORBIT_FAKE_CHECK"] = "sleep"
    begin
      run = check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: output, role: "reviewer")
      check.stop!
      gone = false
      begin
        Process.kill(0, -run.pgid)
      rescue Errno::ESRCH
        gone = true
      end
      assert(gone && run.pgid == run.pid, "stop! confirms the reviewer process group has exited")
    ensure
      ENV.delete("ORBIT_FAKE_CHECK")
      check.close
      FileUtils.remove_entry(root)
    end
  end

  def run
    passes_prompt_result_usage_and_does_not_call_codex
    reviewer_prompt_uses_the_same_independent_session_facts
    rejects_invalid_result_and_changed_fingerprint
    real_sample_cache_is_counted_and_missing_cache_is_unknown
    stops_the_process_group
    puts "PASS omp check runner"
  end
end

OmpCheckRunnerTest.run
