# frozen_string_literal: true

# Failed judgments must retain reported consumption without enabling an action.
# Scripted responses exercise the provider boundary; no socket, key or model call.
require "tmpdir"
require_relative "../lib/orbit/jev_advisor"
require_relative "../lib/orbit/prestart"

module JudgmentUsageTest
  module_function

  class ScriptedProvider < Orbit::TypeSafeJudgment
    def initialize(response)
      super(api_key: "test-key", model: "jev-requested")
      @response = response
    end

    private

    def post(_state, _questions)
      @response
    end
  end

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition
  end

  def request
    Orbit::JudgmentRequest.new(
      state: {}, provider: "typesafe", model: "jev-requested", question_set_version: "usage-fixture-1",
      questions: { "fit" => { "instruction" => "Does the evidence support task fit?",
                               "true_criterion" => "The supplied evidence supports task fit",
                               "false_criterion" => "The evidence is missing or contradicts task fit" } }
    )
  end

  def judge(body, response_class: Net::HTTPOK)
    code = response_class == Net::HTTPOK ? "200" : "500"
    response = response_class.new("1.1", code, "fixture")
    response.define_singleton_method(:body) { body.is_a?(String) ? body : JSON.generate(body) }
    ScriptedProvider.new(response).judge(request)
  end

  def reported(answers)
    { "model" => "jev-actual", "answers" => answers,
      "usage" => { "input_tokens" => 123, "output_tokens" => 7 } }
  end

  def assert_failed_receipt(result)
    check(result.unavailable? && result.answers.empty? && !result.complete_for?(request),
          "failure cannot provide partial answers or authorize an action")
    check(result.actual_model == "jev-actual" && result.usage == { "input_tokens" => 123, "output_tokens" => 7 },
          "the service-reported model and consumption survive a failed judgment")
    check(result.to_h["source"]["actual_model"] == "jev-actual" && result.to_h["usage"] == result.usage,
          "the failure receipt exposes facts to downstream accounting")
    check(result.call_id.to_s.start_with?("orbit-judgment-") && result.to_h["call_id"] == result.call_id,
          "failed invocation identity remains available for deduplicated accounting")
  end

  def check_invalid_answers_keep_consumption
    [{}, { "fit" => { "type" => "noul", "noul" => 1.5 } }, nil].each do |answers|
      assert_failed_receipt(judge(reported(answers)))
    end
  end

  def check_http_failure_keeps_consumption
    result = judge(reported({ "fit" => { "type" => "noul", "noul" => 0.95 } }),
                   response_class: Net::HTTPInternalServerError)
    assert_failed_receipt(result)
    check(result.error == "TypeSafe HTTP 500", "HTTP failure cannot be treated as a successful judgment")
  end

  def check_missing_identity_is_not_requested_identity
    result = judge({ "answers" => {}, "usage" => { "input_tokens" => 12 } })
    check(result.unavailable? && result.actual_model.nil? && result.usage == { "input_tokens" => 12 },
          "known usage survives while the missing actual identity remains unknown")
    check(!result.to_h["source"].key?("actual_model"), "the requested model is not invented as the actual model")
  end

  def check_missing_consumption_is_unknown
    [judge("bad JSON"), judge({ "answers" => {}, "model" => "jev-actual" })].each do |result|
      check(result.unavailable? && result.usage.nil? && !result.to_h.key?("usage"),
            "an absent usage receipt is unknown, never zero")
    end
    http_failure = judge("bad JSON", response_class: Net::HTTPInternalServerError)
    check(http_failure.error == "TypeSafe HTTP 500" && http_failure.usage.nil?,
          "an unreadable HTTP failure keeps its status without fabricating facts")
  end

  def check_invalid_usage_fields_are_not_accounted
    result = Orbit::JudgmentResult.unavailable(
      provider: "typesafe", reason: "invalid answer",
      usage: { "input_tokens" => -1, "output_tokens" => "7", "other" => Float::INFINITY }
    )
    check(result.usage.nil?, "invalid-only usage is unknown rather than an empty or negative receipt")
    zero = Orbit::JudgmentResult.unavailable(provider: "typesafe", reason: "invalid answer",
                                            usage: { "input_tokens" => 0 })
    check(zero.usage == { "input_tokens" => 0 }, "a genuinely reported zero remains a reported fact")
  end

  def check_success_still_returns_complete_answers
    result = judge(reported("fit" => { "type" => "noul", "noul" => 0.8 }))
    check(result.answered? && result.complete_for?(request) && result.probability_true("fit") == 0.8,
          "a valid complete response still supplies the judgment")
    check(result.actual_model == "jev-actual" && result.usage["input_tokens"] == 123,
          "successful consumption is retained unchanged")
    response = Net::HTTPOK.new("1.1", "200", "fixture")
    response.define_singleton_method(:body) { JSON.generate(reported("fit" => { "type" => "noul", "noul" => 0.8 })) }
    provider = ScriptedProvider.new(response)
    same_request = request
    first, retry_result = provider.judge(same_request), provider.judge(same_request)
    check(first.call_id != retry_result.call_id && first.usage == retry_result.usage,
          "retrying the same semantic request produces a distinct potentially paid invocation")
  end

  def check_advisor_exposes_failed_receipt
    response = judge(reported({}))
    provider = Object.new
    provider.define_singleton_method(:judge) { |_request| response }
    advisor = Orbit::JevAdvisor.new(api_key: "test-key")
    advisor.define_singleton_method(:judgment_provider) { provider }
    begin
      advisor.assess(state: {})
      raise "ASSERTION FAILED: an unavailable assessment must fail"
    rescue Orbit::JevAdvisor::Error => error
      check(error.receipt["status"] == "unavailable" && !error.receipt.key?("answers"),
            "the public advisor error carries no actionable partial scores")
      check(error.receipt["usage"] == response.usage && error.receipt.dig("source", "actual_model") == "jev-actual" &&
            error.receipt["question_set_version"] == Orbit::JevAdvisor::QUESTION_SET_VERSIONS["observation"],
            "callers can persist failed consumption with its actual model and question version")
      check(error.judgment["call_id"] == response.call_id && error.judgment["requested_model"] == Orbit::JevAdvisor::MODEL,
            "the advisor preserves invocation identity and separates requested from actual models")
    end
  end

  def check_entry_failure_keeps_receipt_without_starting
    response = judge(reported({}))
    provider = Object.new
    provider.define_singleton_method(:judge) { |_request| response }
    Dir.mktmpdir("orbit-judgment-entry") do |project|
      check(system("git", "-C", project, "init", "-q", out: File::NULL, err: File::NULL),
            "fixture project must be a real Git repository for the reviewed entry profile")
      # The real validated calibration document (production shape: model,
      # thresholds, release with the observable profile) — never an empty
      # stand-in that would bypass the profile/binding normalization.
      calibration = Orbit::EntryCalibration.load(project)
      classifier = Orbit::PrestartClassifier.new(
        project_root: project, provider_for: ->(_model) { provider },
        calibration_loader: -> { calibration }
      )
      decision = classifier.decide("Implement the requested feature and verify the deliverable.")
      check(decision["decision"] == "root_decides" && !decision["trace"].key?("probabilities"),
            "an unavailable entry judgment cannot start a task or expose partial probabilities")
      check(decision.dig("trace", "actual_model") == "jev-actual" && decision.dig("trace", "usage") == response.usage,
            "the entry ledger receives the real failed consumption without guessing the requested model")
      check(decision.dig("trace", "call_id") == response.call_id && decision.dig("trace", "judgment_status") == "unavailable",
            "entry consumption retains the invocation identity and failed outcome")
    end
  end

  def run
    check_invalid_answers_keep_consumption
    check_http_failure_keeps_consumption
    check_missing_identity_is_not_requested_identity
    check_missing_consumption_is_unknown
    check_invalid_usage_fields_are_not_accounted
    check_success_still_returns_complete_answers
    check_advisor_exposes_failed_receipt
    check_entry_failure_keeps_receipt_without_starting
    puts "JUDGMENT_USAGE_TEST_PASS (scripted responses; no model call)"
  end
end

JudgmentUsageTest.run
