# frozen_string_literal: true

# Deterministic tests for the unified judgment data model and the TypeSafe
# adapter. The transport is a local TCP fixture; no TypeSafe call is made and
# no real key is read. Run:
#   ruby --disable-gems tests/judgment_test.rb

require "json"
require "socket"

require_relative "../lib/orbit/jev_advisor"

module JudgmentTest
  module_function

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition

    true
  end

  def expect_model_error(message)
    yield
    raise "ASSERTION FAILED: #{message}"
  rescue Orbit::JudgmentRequest::Error, Orbit::JudgmentResult::Error
    true
  end

  def noul(value)
    { "type" => "noul", "noul" => value }
  end

  def payload(answers, model: "jev-test")
    JSON.generate("model" => model, "answers" => answers, "usage" => { "input_tokens" => 9, "note" => "x" })
  end

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

  def request_questions
    {
      "authorized" => { "instruction" => "Has the user authorized execution?",
                        "true_criterion" => "The work is asked to be done",
                        "false_criterion" => "The message only discusses options" }
    }
  end

  def check_request_validation
    base = { state: {}, questions: request_questions, question_set_version: "v1", provider: "typesafe" }
    check(Orbit::JudgmentRequest.new(**base).to_h["schema_version"] == 1, "schema version is carried")
    check(Orbit::JudgmentRequest.new(**base).to_h["model"].nil?, "model stays optional")
    expect_model_error("empty question sets are rejected") do
      Orbit::JudgmentRequest.new(state: {}, questions: {}, question_set_version: "v1", provider: "typesafe")
    end
    expect_model_error("questions without criteria are rejected") do
      Orbit::JudgmentRequest.new(state: {}, questions: { "q" => { "instruction" => "i" } },
                                 question_set_version: "v1", provider: "typesafe")
    end
    expect_model_error("blank providers are rejected") do
      Orbit::JudgmentRequest.new(state: {}, questions: request_questions, question_set_version: "v1", provider: " ")
    end
    expect_model_error("blank question set versions are rejected") do
      Orbit::JudgmentRequest.new(state: {}, questions: request_questions, question_set_version: " ", provider: "typesafe")
    end
  end

  def check_result_validation
    answered = Orbit::JudgmentResult.answered(
      answers: { "authorized" => { "probability_true" => 0.75 } }, provider: "typesafe", actual_model: "jev-1.13.0"
    )
    check(answered.answered? && answered.probability_true("authorized") == 0.75, "valid answers are readable")
    check(answered.complete_for?(Struct.new(:questions).new(request_questions)), "completeness accepts exact ids")
    expect_model_error("probabilities above 1 are rejected") do
      Orbit::JudgmentResult.answered(answers: { "q" => { "probability_true" => 1.5 } }, provider: "p", actual_model: "m")
    end
    expect_model_error("non-finite probabilities are rejected") do
      Orbit::JudgmentResult.answered(answers: { "q" => { "probability_true" => Float::INFINITY } }, provider: "p", actual_model: "m")
    end
    expect_model_error("missing probability_true is rejected") do
      Orbit::JudgmentResult.answered(answers: { "q" => {} }, provider: "p", actual_model: "m")
    end
    unavailable = Orbit::JudgmentResult.unavailable(provider: "typesafe", reason: "HTTP 500")
    check(unavailable.unavailable? && unavailable.answers.empty? && unavailable.error == "HTTP 500",
          "unavailable carries a structured reason and no answers")
    expect_model_error("unavailable results cannot answer questions") { unavailable.probability_true("q") }
    check(!unavailable.complete_for?(Struct.new(:questions).new(request_questions)), "unavailable is never complete")
    check(!answered.complete_for?(Struct.new(:questions).new(request_questions.merge("extra" => request_questions["authorized"]))),
          "a missing requested id keeps the result incomplete")
  end

  def check_typesafe_wire_and_parsing
    with_fixture([payload({ "authorized" => noul(0.82) })]) do |endpoint, requests|
      result = Orbit::TypeSafeJudgment.new(api_key: "test-key", endpoint: endpoint, model: "jev-1.13.0")
                                     .judge(Orbit::JudgmentRequest.new(
                                              state: { "instruction" => "x" }, questions: request_questions,
                                              question_set_version: "orbit-entry-1", provider: "typesafe", model: "jev-1.13.0"
                                            ))
      sent = requests.first
      check(sent["model"] == "jev-1.13.0" && sent["state"] == { "instruction" => "x" },
            "the adapter sends the explicit provider-level model and the request state")
      check(sent["questions"]["authorized"] == { "type" => "noul",
                                                "instructions" => "Has the user authorized execution?",
                                                "criteria" => { "true" => "The work is asked to be done",
                                                                "false" => "The message only discusses options" } },
            "the wire question keeps the frozen noul shape")
      check(result.answered? && result.actual_model == "jev-test" && result.probability_true("authorized") == 0.82,
            "noul answers map to probability_true with the service-reported model")
      check(result.usage == { "input_tokens" => 9 }, "only numeric usage fields are kept")
    end
  end

  def check_typesafe_failures_are_unavailable
    cases = {
      "http error" => ["500 Internal Server Error", payload({})],
      "malformed json" => ["200 OK", "{not json"],
      "answers null" => ["200 OK", '{"model":"jev-test","answers":null}'],
      "missing requested answer" => ["200 OK", payload({ "other" => noul(0.9) })],
      "invalid probability" => ["200 OK", payload({ "authorized" => noul(1.5) })],
      "non numeric answer" => ["200 OK", payload({ "authorized" => { "type" => "noul", "noul" => "high" } })]
    }
    with_fixture(cases.values) do |endpoint, _requests|
      provider = Orbit::TypeSafeJudgment.new(api_key: "test-key", endpoint: endpoint, model: "jev-1.13.0")
      cases.each_key do |label|
        result = provider.judge(Orbit::JudgmentRequest.new(
                                  state: {}, questions: request_questions,
                                  question_set_version: "v1", provider: "typesafe", model: "jev-1.13.0"
                                ))
        check(result.unavailable? && !result.error.to_s.empty? && result.answers.empty?,
              "a #{label} failure becomes unavailable with a reason and no partial answers (#{result.error})")
      end
    end
  end

  def check_jev_advisor_carries_model_metadata
    answers = { "stuck" => noul(0.1), "off_track" => noul(0.2), "artifact_ready" => noul(0.3), "delegatable" => noul(0.4) }
    with_fixture([payload(answers)]) do |endpoint, _requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess(state: { "instruction" => "x" })
      check(result["provider"] == "typesafe" && result["question_set_version"] == "jev-observation-1" &&
            result["scores"] == { "stuck" => 0.1, "off_track" => 0.2, "artifact_ready" => 0.3, "delegatable" => 0.4 },
            "JevAdvisor results expose the unified provider and question set version without changing scores")
    end
  end

  def run
    check_request_validation
    check_result_validation
    check_typesafe_wire_and_parsing
    check_typesafe_failures_are_unavailable
    check_jev_advisor_carries_model_metadata
    puts "JUDGMENT_TEST_PASS (deterministic, local fixture only)"
  end
end

JudgmentTest.run
