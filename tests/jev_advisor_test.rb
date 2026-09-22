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

  MEMBER_FIT_TEXT = "Given the callable member options and the supplied model evidence, is at least one member likely to meet the best bounded subtask's acceptance bar without enough rework to erase the benefit? Treat missing or stale evidence as unknown and do not infer capability from a model name alone. When Root and a candidate have the same validated provider, model and reasoning identity, treat that identity equality as direct evidence of capability parity; a shared unknown reasoning label is not a mismatch."
  PARALLEL_GAIN_TEXT = "Given the remaining task dependencies and the supplied execution evidence, would delegating the best bounded subtask now likely shorten the overall critical path after handoff, expected rework, integration, shared-resource contention, and verification are included? Independent substantive surfaces can gain from concurrency even when Root and member use the same model. Output speed alone is not task completion speed."
  DELEGATABLE_TEXT = "Is there likely a bounded, independent subtask in the effective task requirements or remaining work that an authorized execution member could deliver now while the main agent continues? Prioritize the instruction, basis and amendments over whether the main agent has already mentioned or started that subtask in recent activity. Explicit disjoint files, modules or acceptance surfaces are strong evidence. Count only separable work with a clear result; do not count trivial, overlapping, preference-only or dependency-blocked work. Member availability is enforced separately by the caller, so do not lower this task-structure probability merely because availability is unknown."

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

  STAGE_ONE_ANSWERS = {
    "stuck" => noul(0.1), "off_track" => noul(0.2),
    "artifact_ready" => noul(0.3), "delegatable" => noul(0.9)
  }.freeze
  STAGE_TWO_ANSWERS = { "member_fit" => noul(0.8), "parallel_gain" => noul(0.7) }.freeze
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

  def run
    check_delegation_question_text
    check_stage_one_questions_unchanged
    check_stage_one_request_and_parsing
    check_stage_two_request_state_and_parsing
    check_stages_ignore_each_others_answers
    check_stage_two_rejects_invalid_probabilities
    check_error_boundaries
    puts "JEV_ADVISOR_TEST_PASS (deterministic, local fixture only)"
  end

  # The two second-stage questions exist, are single noul questions, and the
  # wording matches docs/plan/jev-delegation-optimization.md exactly.
  def check_delegation_question_text
    questions = Orbit::JevAdvisor::DELEGATION_QUESTIONS
    check(questions.keys.sort == %w[member_fit parallel_gain], "stage two asks exactly member_fit and parallel_gain")
    %w[member_fit parallel_gain].each do |name|
      check(questions[name]["type"] == "noul", "#{name} is a single noul question")
      check(questions[name]["criteria"].keys.sort == %w[false true], "#{name} keeps the shared question shape")
    end
    check(questions["member_fit"]["instructions"] == MEMBER_FIT_TEXT, "member_fit wording matches the frozen plan text")
    check(questions["parallel_gain"]["instructions"] == PARALLEL_GAIN_TEXT, "parallel_gain wording matches the frozen plan text")
  end

  # Stage one keeps exactly the four scheduling questions; the calibrated
  # delegatable wording stays synchronized with the plan.
  def check_stage_one_questions_unchanged
    questions = Orbit::JevAdvisor::QUESTIONS
    check(questions.keys.sort == %w[artifact_ready delegatable off_track stuck], "stage one keeps its four questions only")
    check(questions["delegatable"]["instructions"] == DELEGATABLE_TEXT, "stage one delegatable wording matches the calibrated plan")
  end

  def check_stage_one_request_and_parsing
    with_fixture([payload(STAGE_ONE_ANSWERS)]) do |endpoint, requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess(state: { "instruction" => "stage one" })
      sent = requests.first
      check(sent["questions"].keys.sort == %w[artifact_ready delegatable off_track stuck],
            "stage one sends only its own four questions")
      check(!sent["questions"].key?("member_fit") && !sent["questions"].key?("parallel_gain"),
            "stage one does not ask the delegation questions")
      check(sent["state"] == { "instruction" => "stage one" } && sent["model"] == "jev-latest",
            "the caller's bounded state passes through unchanged")
      check(result["scores"] == { "stuck" => 0.1, "off_track" => 0.2, "artifact_ready" => 0.3, "delegatable" => 0.9 },
            "stage one parses exactly its own answers")
      check(result["model"] == "jev-test" && result["usage"] == { "input_tokens" => 12 }, "model and usage are returned")
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
      check(sent["questions"].keys.sort == %w[member_fit parallel_gain], "stage two sends only its own two questions")
      check(sent["state"] == state, "stage two consumes the caller's bounded state verbatim; it fabricates nothing")
      check(result["scores"] == { "member_fit" => 0.8, "parallel_gain" => 0.7 },
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
      check(one["scores"].keys.sort == %w[artifact_ready delegatable off_track stuck],
            "stage one scores contain only stage one answers")
      check(two["scores"].keys.sort == %w[member_fit parallel_gain],
            "stage two scores contain only stage two answers")
    end
  end

  def check_stage_two_rejects_invalid_probabilities
    cases = {
      "out of range" => { "member_fit" => noul(1.5), "parallel_gain" => noul(0.7) },
      "non numeric" => { "member_fit" => { "type" => "noul", "noul" => "high" }, "parallel_gain" => noul(0.7) },
      "wrong answer type" => { "member_fit" => { "type" => "bool", "noul" => 0.8 }, "parallel_gain" => noul(0.7) }
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

    infinite = '{"model":"jev-test","answers":{"member_fit":{"type":"noul","noul":1e999},"parallel_gain":{"type":"noul","noul":0.7}}}'
    with_fixture([infinite]) do |endpoint, _requests|
      expect_error("stage two rejects a non-finite probability") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end

    with_fixture([payload({ "member_fit" => noul(0.8) })]) do |endpoint, _requests|
      expect_error("stage two rejects a missing answer") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end
  end

  # The shared poster keeps the existing error boundaries for both stages.
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
