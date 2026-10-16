# frozen_string_literal: true

# Deterministic tests for Orbit::JevAdvisor. The real transport is a local
# TCP fixture; no TypeSafe call is made and no real key is read. Run:
#   ruby --disable-gems tests/jev_advisor_test.rb

require "json"
require "socket"
require "tmpdir"

require_relative "../lib/orbit/jev_advisor"

module JevAdvisorTest
  module_function

  HANDOFF_TEXT = Orbit::ModelQualityPolicy::HANDOFF_TEXT
  MEMBER_TASK_FIT_TEXT = Orbit::ModelQualityPolicy::MEMBER_TASK_FIT_TEXT

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition

    true
  end

  def noul(value)
    { "type" => "noul", "noul" => value }
  end

  def payload(answers, model: "jev-test")
    JSON.generate("model" => model, "answers" => answers, "usage" => { "input_tokens" => 12 })
  end

  # Legacy extra answers must be ignored; they are never requested or scored.
  STAGE_ONE_ANSWERS = {
    "stuck" => noul(0.1), "off_track" => noul(0.2),
    "artifact_ready" => noul(0.3), "delegatable" => noul(0.9)
  }.freeze
  STAGE_TWO_ANSWERS = { "handoff_fit" => noul(0.8), "member_task_fit" => noul(0.7) }.freeze
  ALL_ANSWERS = STAGE_ONE_ANSWERS.merge(STAGE_TWO_ANSWERS).freeze

  # Serves one HTTP response per entry (String = 200 body, [status, body]
  # otherwise), recording each parsed request body in order.
  def with_fixture(entries)
    queue = entries.map { |entry| entry.is_a?(Array) ? entry : ["200 OK", entry] }
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    worker = Thread.new do
      queue.each do |status, body|
        socket = server.accept
        headers = +""
        headers << socket.gets until headers.end_with?("\r\n\r\n")
        length = headers[/Content-Length:\s*(\d+)/i, 1].to_i
        requests << JSON.parse(socket.read(length))
        socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    end
    yield URI("http://127.0.0.1:#{server.addr[1]}/v1/systemone"), requests
  ensure
    server.close
    worker.join(3)
  end

  def expect_error(message)
    yield
    raise "ASSERTION FAILED: #{message}"
  rescue Orbit::JevAdvisor::Error
    true
  end

  GIT_IDENTITY = ["-c", "user.name=Orbit test", "-c", "user.email=orbit@example.invalid",
                  "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"].freeze

  def git(root, *args)
    ok = system("git", "-C", root, *args, out: File::NULL, err: File::NULL)
    raise "git #{args.join(' ')} failed in #{root}" unless ok
  end

  def commit(root)
    git(root, *GIT_IDENTITY, "commit", "-qm", "fixture")
  end

  def git_bytes(root, *args)
    IO.popen(["git", "-C", root, *args], err: File::NULL) { |io| io.read }.to_s.b
  end

  def run
    check_delegation_question_text
    check_stage_one_process_questions
    check_candidate_assessment_round_trip
    check_stage_one_request_and_parsing
    check_stage_two_request_state_and_parsing
    check_stages_ignore_each_others_answers
    check_checker_quality_request_and_parsing
    check_checker_overview_prior_has_no_time_verdict
    check_stage_two_rejects_invalid_probabilities
    check_observation_includes_user_messages_verbatim
    check_git_excerpt_utf8_boundary
    check_error_boundaries
    puts "JEV_ADVISOR_TEST_PASS (deterministic, local fixture only)"
  end

  # Stage two asks serial handoff and member task fit. Time and coarse cost
  # questions are gone, and the wording is the selection policy text.
  def check_delegation_question_text
    questions = Orbit::JevAdvisor::DELEGATION_QUESTIONS
    check(questions.keys.sort == %w[handoff_fit member_task_fit],
          "stage two asks handoff_fit and member_task_fit")
    %w[handoff_fit member_task_fit].each do |name|
      check(questions[name]["type"] == "noul", "#{name} is a single noul question")
      check(questions[name]["criteria"].keys.sort == %w[false true], "#{name} keeps the shared question shape")
    end
    check(questions["handoff_fit"]["instructions"] == HANDOFF_TEXT, "handoff_fit allows a serial handoff")
    check(questions["handoff_fit"]["instructions"].include?("serial handoff") &&
          !questions["handoff_fit"]["instructions"].include?("critical path"),
          "handoff_fit does not ask for a shorter critical path")
    check(questions["member_task_fit"]["instructions"] == MEMBER_TASK_FIT_TEXT,
          "member_task_fit is the policy question")
    blob = questions.values.map { |question| question["instructions"] }.join("\n")
    check(!blob.include?("coarse cost") && !blob.include?("parallel_gain"),
          "stage two does not ask a coarse cost or parallel-time question")
  end

  # One task-fit question per candidate. The result keeps a quality key and
  # drops the time key. Speed in the caller state is not sent.
  def check_candidate_assessment_round_trip
    answers = { "candidate_0_task_fit" => noul(0.7), "candidate_1_task_fit" => noul(0.4) }
    state = { "instruction" => "Ship the login page", "elapsed_seconds" => 40,
              "comparison" => { "speed_ratio" => 3.48 } }
    with_fixture([payload(answers)]) do |endpoint, requests|
      candidates = [{ "provider" => "opencode-go", "model" => "deepseek-v4.1-flash", "agent" => "orbit-m-deepseek" },
                    { "provider" => "zhipu", "model" => "glm-5", "agent" => "orbit-m-glm" }]
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint)
                                .assess_candidates(state: state, candidates: candidates)
      sent = requests.first
      check(sent["questions"].keys.sort == %w[candidate_0_task_fit candidate_1_task_fit],
            "one task-fit question per candidate and no time question")
      blob = JSON.generate(sent["questions"])
      check(blob.include?("agent orbit-m-deepseek") && blob.include?("model opencode-go/deepseek-v4.1-flash") &&
            blob.include?("agent orbit-m-glm") && blob.include?("Serial handoff is valid"),
            "every instruction names its candidate and allows a serial handoff")
      full_model_questions = Orbit::ModelQualityPolicy.candidate_questions([
        { "agent" => "task", "model" => "kimi-code/k3-256k", "identity" => { "provider" => "kimi-code" } },
        { "agent" => "task", "provider" => "kimi-code", "model" => "kimi-code/k3-256k" }
      ])
      check(full_model_questions.values.all? { |question| question["instructions"].include?("model kimi-code/k3-256k)") },
            "the actual full model id is named once with and without a top-level provider")
      check(!blob.include?("critical path") && !blob.include?("candidate_0_time"),
            "the candidate set has no end-to-end time question")
      context = sent.dig("state", "task_context")
      check(sent["state"]["input_version"] == Orbit::ModelQualityPolicy::INPUT_VERSION &&
            !context.key?("elapsed_seconds") && !context.key?("comparison") &&
            sent["state"]["omitted_from_judgment"].include?("elapsed_seconds"),
            "candidate judgment input drops speed and elapsed time")
      check(result["scores"] == { "0" => { "quality" => 0.7 }, "1" => { "quality" => 0.4 } },
            "task-fit answers map to quality and do not include time")
      check(result["question_set_version"] == Orbit::ModelQualityPolicy::CANDIDATE_QUESTION_SET && result["status"] == "answered" &&
            result["requested_model"] == "jev-latest" && result["call_id"].match?(/\Aorbit-judgment-/),
            "the receipt keeps call id, requested model and answered status")
    end
  end

  # Observation retains only process questions; handoff and final review are separate.
  def check_stage_one_process_questions
    questions = Orbit::JevAdvisor::QUESTIONS
    check(questions.keys.sort == %w[off_track stuck], "observation asks only stuck and off_track")
    check(!questions.key?("delegatable"), "stage one does not ask the old delegatable question")
    check(questions["stuck"]["instructions"].include?("Do not infer this from elapsed time alone"),
          "stuck still refuses an elapsed-only inference")
    check(Orbit::JevAdvisor::QUESTION_SET_VERSIONS.fetch("observation") == "jev-observation-4",
          "the observation set version records removal of artifact readiness")
    check(Orbit::JevAdvisor::DELEGATION_QUESTIONS["handoff_fit"]["instructions"] == HANDOFF_TEXT,
          "serial handoff is the delegation question")
  end

  def check_stage_one_request_and_parsing
    with_fixture([payload(STAGE_ONE_ANSWERS)]) do |endpoint, requests|
      advisor = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint)
      result = advisor.assess(state: { "instruction" => "stage one" })
      sent = requests.first
      check(sent["questions"].keys.sort == %w[off_track stuck],
            "observation never asks JEV to approve artifact readiness")
      check(!sent["questions"].key?("delegatable") && !sent["questions"].key?("handoff_fit"),
            "stage one does not ask the handoff question")
      check(sent["state"] == { "instruction" => "stage one" } && sent["model"] == "jev-latest",
            "the caller's bounded state passes through unchanged")
      check(result["scores"] == { "stuck" => 0.1, "off_track" => 0.2 },
            "stage one ignores legacy readiness and delegation answers")
      check(result["model"] == "jev-test" && result["usage"] == { "input_tokens" => 12 }, "model and usage are returned")
      check(advisor.last_trace.dig("request", "state") == sent["state"] &&
            advisor.last_trace.dig("request", "questions") == sent["questions"] &&
            advisor.last_trace.dig("result", "call_id") == result["call_id"] &&
            advisor.last_trace.dig("provider_response", "body_base64").unpack1("m0") == payload(STAGE_ONE_ANSWERS),
            "the call trace captures the complete wire request, raw response and linked parsed result")
    end
  end

  # Stage two accepts the caller-built bounded state (member options plus the
  # evidence comparison), asks only its two questions, and succeeds without
  # any stage-one answers.
  def check_stage_two_request_state_and_parsing
    state = {
      "instruction" => "Ship the login page",
      "member_options" => %w[codex opencode],
      "comparison" => { "root" => { "provider" => "openai", "model" => "gpt-6-astra", "reasoning" => "max" },
                        "candidate" => { "provider" => "opencode-go", "model" => "deepseek-v4.1-flash", "reasoning" => "default" },
                        "comparison" => { "speed_ratio" => 3.48, "quality_delta" => -14, "cost_ratio" => 0.08, "local_samples" => 0 },
                        "evidence" => { "retrieved_at" => "2026-09-22T10:00:00Z", "valid_until" => "2026-09-29T10:00:00Z",
                                        "sources" => ["https://artificialanalysis.ai/models"] } }
    }
    with_fixture([payload(STAGE_TWO_ANSWERS)]) do |endpoint, requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: state)
      sent = requests.first
      check(sent["questions"].keys.sort == %w[handoff_fit member_task_fit],
            "stage two sends handoff_fit and member_task_fit")
      context = sent.dig("state", "task_context")
      check(sent["state"]["input_version"] == Orbit::ModelQualityPolicy::INPUT_VERSION &&
            context["instruction"] == "Ship the login page" && !context.key?("comparison") &&
            sent["state"]["omitted_from_judgment"].include?("comparison"),
            "stage two drops speed, coarse comparison and local-sample counts")
      check(result["scores"] == { "handoff_fit" => 0.8, "member_task_fit" => 0.7 },
            "stage two parses exactly its own answers")
    end
  end

  # Extra answers in the response must not leak into either stage's scores:
  # each stage parses only the questions it asked.
  def check_stages_ignore_each_others_answers
    with_fixture([payload(ALL_ANSWERS), payload(ALL_ANSWERS)]) do |endpoint, requests|
      advisor = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint)
      one = advisor.assess(state: { "instruction" => "stage one" })
      two = advisor.assess_delegation(state: { "instruction" => "stage two" })
      check(one["scores"].keys.sort == %w[off_track stuck],
            "stage one scores contain only stage one answers")
      check(two["scores"].keys.sort == %w[handoff_fit member_task_fit],
            "stage two scores contain only stage two answers")
    end
  end

  def check_stage_two_rejects_invalid_probabilities
    cases = {
      "out of range" => { "handoff_fit" => noul(1.5), "member_task_fit" => noul(0.7) },
      "non numeric" => { "handoff_fit" => { "type" => "noul", "noul" => "high" }, "member_task_fit" => noul(0.7) },
      "wrong answer type" => { "handoff_fit" => { "type" => "bool", "noul" => 0.8 }, "member_task_fit" => noul(0.7) }
    }
    entries = cases.values.map { |answers| payload(answers) }
    with_fixture(entries) do |endpoint, _requests|
      advisor = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint)
      cases.each_key do |label|
        expect_error("stage two rejects an invalid probability (#{label})") do
          advisor.assess_delegation(state: { "instruction" => "x" })
        end
      end
    end

    infinite = '{"model":"jev-test","answers":{"handoff_fit":{"type":"noul","noul":1e999},"member_task_fit":{"type":"noul","noul":0.7}}}'
    with_fixture([infinite]) do |endpoint, _requests|
      expect_error("stage two rejects a non-finite probability") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end

    with_fixture([payload({ "handoff_fit" => noul(0.8) })]) do |endpoint, _requests|
      expect_error("stage two rejects a missing answer") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end
  end

  def check_observation_includes_user_messages_verbatim
    Dir.mktmpdir("orbit-jev-user-message-") do |root|
      message = { "id" => "native-2", "text" => "Is the deployment note part of this task?",
                  "task_relation" => "unassigned", "observed_at" => "2026-10-16T00:00:00Z" }
      observation = Orbit::JevAdvisor.observation(
        inputs: { "instruction" => "Implement the requested change", "basis" => [], "amendments" => [],
                  "jev_user_messages" => [message] },
        host: { "status" => "active", "observations" => [] }, members: [],
        project_root: root, artifact_digest: "digest", elapsed_seconds: 1
      )
      check(observation.fetch("new_user_messages") == [message],
            "new user text reaches Jev verbatim with its relation labeled")

      command = "SECRET_COMMAND_BODY"
      output = "SECRET_TOOL_OUTPUT"
      receipts = [
        { "kind" => "root_verification", "source" => "omp_native_tool_result", "tool_call_id" => "call-known",
          "tool" => "bash", "status" => "completed", "exit_code" => 0, "at" => "2026-10-16T00:00:02Z",
          "execution_cwd" => root, "artifact_root" => root, "input_digest" => "input-v1",
          "artifact_root_at_completion" => root, "artifact_digest" => "artifact-v2", "artifact_matches" => true,
          "input_matches" => false, "scope" => "root", "coverage" => { "tests" => "partial" },
          "command" => command, "output" => output },
        { "kind" => "root_verification", "source" => "omp_native_tool_result", "tool_call_id" => "call-unknown",
          "tool" => "write", "status" => "failed", "at" => "2026-10-16T00:00:03Z",
          "command" => command, "output" => output }
      ]
      projected = Orbit::JevAdvisor.observation(
        inputs: { "instruction" => "verify" },
        host: { "status" => "active", "artifact_root" => root, "observations" => [
          { "tool_calls" => [{ "id" => "call-known", "declared_intent" => "check the installed CLI" }] }
        ] },
        members: [], project_root: root, artifact_digest: "digest", elapsed_seconds: 1,
        root_verifications: receipts
      ).fetch("root_verifications")
      serialized = JSON.generate(projected)
      check(projected.length == 2 && projected[0]["intent"] == "check the installed CLI" &&
            projected[1]["intent"] == "unknown" && !serialized.include?(command) && !serialized.include?(output) &&
            projected[0].slice("input_digest", "artifact_digest", "input_matches", "artifact_matches",
                               "scope", "coverage") == {
                                 "input_digest" => "input-v1", "artifact_digest" => "artifact-v2",
                                 "input_matches" => false, "artifact_matches" => true,
                                 "scope" => "root", "coverage" => { "tests" => "partial" }
                               },
            "observation verification projection keeps trusted metadata and version matches without command/output bodies")
    end
  end

  # Exact route evidence permits task-fit and time judgments; an overview
  # prior is not a route-specific time sample.
  def check_checker_quality_request_and_parsing
    state = {
      "instruction" => "Add a login page",
      "candidates" => [
        { "model" => "p/one", "evidence" => { "status" => "evidence", "sources" => ["https://s"] } },
        { "model" => "p/two", "evidence" => { "status" => "evidence", "sources" => ["https://s"] } }
      ]
    }
    with_fixture([payload({ "quality_0" => noul(0.8), "quality_1" => noul(0.2) })]) do |endpoint, requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_checker_quality(
        state: state, candidates: state["candidates"]
      )
      sent = requests.first
      check(sent["questions"].keys.sort == %w[quality_0 quality_1],
            "checker task fit does not ask a time question even when exact evidence is present")
      check(result["scores"] == { "p/one" => { "quality" => 0.8 }, "p/two" => { "quality" => 0.2 } },
            "quality answers map back to provider/id and omit time")
      check(result["question_set_version"] == Orbit::ModelQualityPolicy::CHECKER_QUESTION_SET, "checker questions use the new set version")
    end

    expect_error("no checker candidate is rejected before any request") do
      Orbit::JevAdvisor.new(api_key: "test-key").assess_checker_quality(state: {}, candidates: [])
    end
  end

  def check_checker_overview_prior_has_no_time_verdict
    prior = { "canonical_slug" => "moonshotai/kimi-k3-20260715", "coding_index" => 76.2,
              "agentic_index" => 50.0, "reasoning_note" => "推理变体未核实",
              "sources" => ["https://www.kimi.com/code/docs/en/kimi-code/models.html"] }
    state = { "instruction" => "Review a small coding fix",
              "candidates" => [{ "model" => "kimi-code/k3-256k", "model_overview_prior" => prior }] }
    with_fixture([payload({ "quality_0" => noul(0.63) })]) do |endpoint, requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_checker_quality(
        state: state, candidates: state["candidates"]
      )
      sent = requests.first
      prior = sent.dig("state", "catalog_priors", 0)
      check(sent["questions"].keys == ["quality_0"] && !result["scores"]["kimi-code/k3-256k"].key?("time") &&
            prior["coding_index"] == 76.2 && prior["not_a_weighted_input"] == true,
            "a catalog prior is a labeled input and does not create a time score or a weighted total")
    end
  end

  # Real git output is read as raw bytes under a byte budget, so the budget
  # can cut a multibyte character in half. That invalid UTF-8 used to make
  # JSON.generate raise and degrade every assessment to
  # "TypeSafe assessment failed: JSON::GeneratorError" (Zeen task
  # e337c16d). The excerpt must stay valid UTF-8 within the same byte budget
  # and remain byte-identical before the cut; genuinely invalid bytes beyond
  # the cut must still fail closed instead of being silently replaced.
  def check_git_excerpt_utf8_boundary
    Dir.mktmpdir("orbit-jev-cjk") do |root|
      git(root, "init", "-q")
      File.write(File.join(root, "notes.md"), "short\n")
      git(root, "add", "-A")
      commit(root)

      body = "中文页面走查记录，逐条说明修改原因与验收方式。\n"
      filler = ""
      raw = nil
      3.times do
        File.write(File.join(root, "notes.md"), filler + (body * 300))
        raw = git_bytes(root, "diff", "--no-ext-diff", "--no-textconv", "--unified=0", "HEAD", "--")
        head = raw.byteslice(0, 4000).dup.force_encoding(Encoding::UTF_8)
        break unless head.valid_encoding?

        filler = "x#{filler}" # shift the byte alignment of the cut and re-diff
      end
      check(raw.bytesize > 4000 && !raw.byteslice(0, 4000).dup.force_encoding(Encoding::UTF_8).valid_encoding?,
            "the fixture reproduces the real byte-budget cut through a multibyte character")

      state = Orbit::JevAdvisor.observation(
        inputs: { "instruction" => "orbit" }, host: { "status" => "running", "artifact_root" => root, "observations" => [] },
        members: [], project_root: root, artifact_digest: "sha256:fixture", elapsed_seconds: 6
      )
      changes = state.dig("changes", "groups").find { |group| group["scope"] == "root_bound_artifact_root" }
      summary = changes["diff_stat"]
      check(summary.encoding == Encoding::UTF_8 && summary.valid_encoding? && summary.include?("notes.md"),
            "the bounded git summary remains valid UTF-8 and identifies the changed artifact")
      check(changes["status"] == " M notes.md\n", "an untruncated git read still passes through unchanged")

      with_fixture([payload(STAGE_ONE_ANSWERS)]) do |endpoint, requests|
        result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess(state: state)
        check(result["scores"]["stuck"] == 0.1,
              "a diff cut at the byte budget no longer degrades the assessment to JSON::GeneratorError")
        check(requests.first.dig("state", "changes", "groups").first["diff_stat"].valid_encoding?,
              "the assessment request carries the bounded summary as valid JSON text")
      end
    end

    Dir.mktmpdir("orbit-jev-bytes") do |root|
      git(root, "init", "-q")
      File.write(File.join(root, "legacy.txt"), "ascii\n")
      git(root, "add", "-A")
      commit(root)
      File.binwrite(File.join(root, "legacy.txt"), ("legacy \xFF\xFE row\n".b * 400))

      raw = git_bytes(root, "diff", "--no-ext-diff", "--no-textconv", "--unified=0", "HEAD", "--")
      state = Orbit::JevAdvisor.observation(
        inputs: { "instruction" => "orbit" }, host: { "status" => "running", "artifact_root" => root, "observations" => [] },
        members: [], project_root: root, artifact_digest: "sha256:fixture", elapsed_seconds: 6
      )
      changes = state.dig("changes", "groups").find { |group| group["scope"] == "root_bound_artifact_root" }
      check(changes["status"].include?("legacy.txt") && changes["diff_stat"].valid_encoding?,
            "git metadata identifies the changed path without sending invalid file contents")
      with_fixture([payload(STAGE_ONE_ANSWERS)]) do |endpoint, requests|
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess(state: state)
        check(requests.first.dig("state", "changes", "groups").first["diff_stat"].valid_encoding?,
              "binary file contents do not enter the JEV request")
      end
    end
  end

  def check_error_boundaries
    with_fixture([["500 Internal Server Error", payload(STAGE_TWO_ANSWERS)]]) do |endpoint, _requests|
      expect_error("an HTTP error stays a JevAdvisor::Error") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end

    with_fixture(['{"model":"jev-test","answers":null}']) do |endpoint, _requests|
      expect_error("a malformed payload stays a JevAdvisor::Error") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end

    expect_error("an empty key is rejected before any request") do
      Orbit::JevAdvisor.new(api_key: "").assess_delegation(state: { "instruction" => "x" })
    end
  end
end

JevAdvisorTest.run
