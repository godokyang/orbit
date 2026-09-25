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
      if config.key?("probe_models")
        record = ENV["ORBIT_FAKE_PROBE_RECORD"]
        if record && !record.empty?
          File.write(record, JSON.generate(
            "argv" => ARGV,
            "profile" => config["profile"],
            "pi_dir" => ENV["PI_CODING_AGENT_DIR"],
            "omp_profile_set" => ENV.key?("OMP_PROFILE"),
            "probe_models" => config["probe_models"]
          ))
        end
        case ENV["ORBIT_FAKE_PROBE"]
        when "fail"
          File.write(config.fetch("out"), JSON.generate("ok" => false, "probe_models" => nil, "problems" => ["probe crashed"], "token" => "SECRET"))
          exit 1
        when "sleep"
          sleep 30
          exit 0
        end
        reasons = {
          "provider/missing" => "model not in isolated catalog",
          "provider/nocred" => "no credential for provider",
          "notamodel" => "model must be provider/id"
        }
        list = config["probe_models"].split(",")
        File.write(config.fetch("out"), JSON.generate(
          "ok" => true, "problems" => [], "token" => "SECRET",
          "probe_models" => {
            "resolvable" => list.reject { |model| reasons.key?(model) },
            "unresolvable" => list.select { |model| reasons.key?(model) }.map { |model| { "model" => model, "reason" => reasons[model] } }
          }
        ))
        exit 0
      end

      if ENV["ORBIT_FAKE_CHECK"] == "sleep"
        sleep 30
        exit 0
      end

      failure = ENV["ORBIT_FAKE_CHECK"]
      if %w[fail_auth fail_quota_heuristic fail_unknown fail_contract].include?(failure)
        payload = {
          "ok" => false, "review_ran" => false,
          "fingerprint_before" => "sha256:fixed", "fingerprint_after" => "sha256:fixed"
        }
        case failure
        when "fail_auth"
          payload["error"] = { "kind" => "auth_or_quota", "message" => "provider returned 401" }
          payload["problems"] = ["401 unauthorized"]
        when "fail_quota_heuristic"
          payload["problems"] = ["429 rate limit exceeded"]
        when "fail_contract"
          payload["review_ran"] = true
          payload["model"] = "zenmux/x-ai/grok-4.7"
          payload["problems"] = ["next_check_seconds must be a positive integer"]
          payload["contract_problems"] = ["next_check_seconds must be a positive integer"]
          payload["result"] = nil
        else
          payload["problems"] = ["model request failed"]
        end
        File.write(config.fetch("out"), JSON.generate(payload))
        exit 1
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

  def probe_reports_models_with_reasons_and_no_token
    root = Dir.mktmpdir("orbit-omp-probe-")
    fake = write_fake(root)
    record = File.join(root, "probe-record.json")
    previous = ENV["ORBIT_FAKE_PROBE_RECORD"]
    ENV["ORBIT_FAKE_PROBE_RECORD"] = record
    begin
      result = Orbit::OmpCheckRunner.probe_models(
        models: ["zhipu-coding-plan/glm-5.2", "zenmux/x-ai/grok-4.7", "provider/missing", "provider/nocred", "notamodel", "zhipu-coding-plan/glm-5.2"],
        command: [RbConfig.ruby, fake]
      )
      assert(result["resolvable"] == ["zhipu-coding-plan/glm-5.2", "zenmux/x-ai/grok-4.7"],
             "resolvable models are returned as provider/id, including ids that contain slashes")
      assert(result["resolvable"].include?("zenmux/x-ai/grok-4.7"),
             "a multi-segment id is kept intact, not rejected or truncated")
      reasons = result["unresolvable"].to_h { |item| [item["model"], item["reason"]] }
      assert(reasons["provider/missing"] == "model not in isolated catalog", "catalog miss keeps a structured reason")
      assert(reasons["provider/nocred"] == "no credential for provider", "credential miss keeps a structured reason")
      assert(reasons.key?("notamodel"), "a bare model id is reported unusable, not silently dropped")
      assert(!result.to_s.include?("SECRET"), "no credential value is returned")
      view = JSON.parse(File.read(record))
      assert(view["pi_dir"] == view["profile"] && view["omp_profile_set"] == false,
             "the probe child gets a fresh isolated profile and no OMP_PROFILE")
      assert(view["probe_models"].split(",").length == 5 && view["probe_models"].split(",").uniq.length == 5,
             "duplicate candidates are collapsed before the reviewer runs")
    ensure
      previous ? ENV["ORBIT_FAKE_PROBE_RECORD"] = previous : ENV.delete("ORBIT_FAKE_PROBE_RECORD")
      FileUtils.remove_entry(root)
    end
  end

  def probe_fails_closed_on_reviewer_error
    root = Dir.mktmpdir("orbit-omp-probe-")
    fake = write_fake(root)
    ENV["ORBIT_FAKE_PROBE"] = "fail"
    begin
      raised = false
      leaked = false
      begin
        Orbit::OmpCheckRunner.probe_models(models: ["provider/good"], command: [RbConfig.ruby, fake])
      rescue Orbit::CheckRunner::Error => error
        raised = error.message.include?("model probe failed") && error.message.include?("probe crashed")
        leaked = error.message.include?("SECRET")
      end
      assert(raised, "a reviewer failure raises instead of returning an empty pass")
      assert(!leaked, "the failure text reports status/problems/stderr only, never an evidence token field")
    ensure
      ENV.delete("ORBIT_FAKE_PROBE")
      FileUtils.remove_entry(root)
    end
  end

  def probe_stops_when_the_reviewer_hangs
    root = Dir.mktmpdir("orbit-omp-probe-")
    fake = write_fake(root)
    ENV["ORBIT_FAKE_PROBE"] = "sleep"
    begin
      raised = false
      begin
        Orbit::OmpCheckRunner.probe_models(models: ["provider/good"], command: [RbConfig.ruby, fake], timeout: 0.5)
      rescue Orbit::CheckRunner::Error => error
        raised = error.message.include?("timed out")
      end
      assert(raised, "a hung probe is bounded and reported, not left running")
    ensure
      ENV.delete("ORBIT_FAKE_PROBE")
      FileUtils.remove_entry(root)
    end
  end

  def selects_model_for_the_next_check_and_refuses_while_in_flight
    root, snapshot, output = fixture
    check = runner(write_fake(root))
    begin
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: output, role: "reviewer")
      wait_result(check)
      first = JSON.parse(File.read(File.join(output, "request.json")))
      assert(first["model"] == "zhipu-coding-plan/glm-5.2", "the first request uses the initial model")

      check.select_model!("zenmux/x-ai/grok-4.7")
      assert(check.model == "zenmux/x-ai/grok-4.7", "a completed check allows selecting the next model")

      invalid = false
      begin
        check.select_model!("not-a-model")
      rescue Orbit::CheckRunner::Error
        invalid = true
      end
      assert(invalid && check.model == "zenmux/x-ai/grok-4.7", "a model without a provider is refused and leaves the model unchanged")

      second_output = File.join(root, "output-second")
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: second_output, role: "reviewer")
      second = JSON.parse(File.read(File.join(second_output, "request.json")))
      assert(second["model"] == "zenmux/x-ai/grok-4.7",
             "the second request uses the newly selected model, including an id with slashes")
      wait_result(check)

      in_flight_output = File.join(root, "output-in-flight")
      ENV["ORBIT_FAKE_CHECK"] = "sleep"
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: in_flight_output, role: "reviewer")
      refused = false
      begin
        check.select_model!("zhipu-coding-plan/glm-5.2")
      rescue Orbit::CheckRunner::Error => error
        refused = error.message.include?("in flight")
      end
      assert(refused, "selecting a model while a check is in flight is refused")
      assert(check.model == "zenmux/x-ai/grok-4.7", "a refused selection leaves the model unchanged")
      check.stop!
      check.select_model!("zhipu-coding-plan/glm-5.2")
      assert(check.model == "zhipu-coding-plan/glm-5.2", "a stopped check allows selecting again")
    ensure
      ENV.delete("ORBIT_FAKE_CHECK")
      check.close
      FileUtils.remove_entry(root)
    end
  end

  def recovers_after_a_classified_failure_without_terminating
    root, snapshot, output = fixture
    check = runner(write_fake(root))
    begin
      ENV["ORBIT_FAKE_CHECK"] = "fail_auth"
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: output, role: "reviewer")
      raised = false
      begin
        wait_result(check)
      rescue Orbit::CheckRunner::Error
        raised = true
      end
      assert(raised, "a failed check is reported, never returned as a pass")
      assert(check.failure_kind == "auth_or_quota" && check.failure_basis == "structured",
             "a structured evidence error kind classifies the failure")

      # A failed run is over: the runner accepts a new model and can restart, so
      # the task stays alive and blocked instead of terminating.
      check.select_model!("zenmux/x-ai/grok-4.7")
      second = File.join(root, "output-second")
      ENV["ORBIT_FAKE_CHECK"] = "pass"
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: second, role: "reviewer")
      result = wait_result(check)
      request = JSON.parse(File.read(File.join(second, "request.json")))
      assert(result["verdict"] == "correct", "the same runner retries after Root chooses a model")
      assert(request["model"] == "zenmux/x-ai/grok-4.7", "the retry uses the explicitly chosen model")

      ENV["ORBIT_FAKE_CHECK"] = "fail_quota_heuristic"
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: File.join(root, "output-third"),
                  role: "reviewer")
      begin
        wait_result(check)
      rescue Orbit::CheckRunner::Error
        nil
      end
      assert(check.failure_kind == "auth_or_quota" && check.failure_basis == "heuristic",
             "a bound heuristic labels an auth/quota-looking failure and marks it heuristic")

      ENV["ORBIT_FAKE_CHECK"] = "fail_unknown"
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: File.join(root, "output-fourth"),
                  role: "reviewer")
      begin
        wait_result(check)
      rescue Orbit::CheckRunner::Error
        nil
      end
      assert(check.failure_kind == "unavailable", "an unknown failure still blocks as a failure, not a pass")
    ensure
      ENV.delete("ORBIT_FAKE_CHECK")
      check.close
      FileUtils.remove_entry(root)
    end
  end

  def classifies_a_contract_failure_as_invalid_result
    root, snapshot, output = fixture
    check = runner(write_fake(root))
    ENV["ORBIT_FAKE_CHECK"] = "fail_contract"
    begin
      check.start(directory: snapshot, inputs: inputs, context: {}, output_dir: output, role: "reviewer")
      raised = false
      begin
        wait_result(check)
      rescue Orbit::CheckRunner::Error => error
        raised = error.message.include?("next_check_seconds")
      end
      assert(raised, "a contract-invalid result is reported, never returned as a pass")
      assert(check.failure_kind == "invalid_result" && check.failure_basis == "structural",
             "a parseable result that violates the evidence contract is invalid_result/structural, not unavailable/heuristic")
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
    selects_model_for_the_next_check_and_refuses_while_in_flight
    recovers_after_a_classified_failure_without_terminating
    classifies_a_contract_failure_as_invalid_result
    probe_reports_models_with_reasons_and_no_token
    probe_fails_closed_on_reviewer_error
    probe_stops_when_the_reviewer_hangs
    puts "PASS omp check runner"
  end
end

OmpCheckRunnerTest.run
