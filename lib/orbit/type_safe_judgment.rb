# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "judgment"

module Orbit
  # TypeSafe System One adapter — the first judgment provider. It translates a
  # JudgmentRequest into the /v1/systemone noul wire format and maps answers
  # back into the unified result. The adapter owns only auth, transport,
  # timeouts and the native response shape: it never decides when Orbit
  # starts, checks, dispatches or stops, and any failure or unmappable answer
  # becomes a structured `unavailable` result with no partial answers.
  class TypeSafeJudgment
    PROVIDER = "typesafe"
    # Calibrated alias for the in-task Jev question sets (unchanged behavior).
    # A provider-level model is explicit and stable within one configuration:
    # it is never switched after a single failed judgment.
    DEFAULT_MODEL = "jev-latest"
    ENDPOINT = URI("https://api.typesafe.ai/v1/systemone")

    class Error < StandardError; end

    def initialize(api_key:, endpoint: ENDPOINT, model: DEFAULT_MODEL)
      @api_key = api_key.to_s
      @endpoint = endpoint
      @model = model.to_s
    end

    attr_reader :model

    def judge(request)
      raise Error, "TYPESAFE_API_KEY is missing" if @api_key.empty?

      response = post(request.state, wire_questions(request))
      payload = JSON.parse(response.body)
      unless payload.is_a?(Hash) && payload["answers"].is_a?(Hash) && payload["model"].is_a?(String) && !payload["model"].empty?
        return unavailable("invalid TypeSafe response shape")
      end

      answers = {}
      request.questions.each_key do |id|
        answer = payload.fetch("answers")[id]
        return unavailable("missing or invalid #{id} answer") unless valid_answer?(answer)

        answers[id] = { "probability_true" => answer.fetch("noul") }
      end
      JudgmentResult.answered(answers: answers, provider: PROVIDER,
                              actual_model: payload.fetch("model"), usage: payload["usage"])
    rescue Error => error
      unavailable(error.message)
    rescue JudgmentResult::Error => error
      unavailable(error.message)
    rescue StandardError => error
      unavailable("TypeSafe assessment failed: #{error.class}")
    end

    private

    def post(state, questions)
      request = Net::HTTP::Post.new(@endpoint)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate("model" => @model, "state" => state, "questions" => questions)
      response = Net::HTTP.start(@endpoint.host, @endpoint.port, use_ssl: @endpoint.scheme == "https",
                                 open_timeout: 3, read_timeout: 5, write_timeout: 3) do |http|
        http.request(request)
      end
      raise Error, "TypeSafe HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response
    end

    # The unified model carries instruction/true_criterion/false_criterion; the
    # TypeSafe wire keeps the frozen noul shape exactly as before.
    def wire_questions(request)
      request.questions.to_h do |id, question|
        [id, { "type" => "noul",
               "instructions" => question.fetch("instruction"),
               "criteria" => { "true" => question.fetch("true_criterion"),
                               "false" => question.fetch("false_criterion") } }]
      end
    end

    def valid_answer?(answer)
      answer.is_a?(Hash) && answer["type"] == "noul" &&
        answer["noul"].is_a?(Numeric) && answer["noul"].finite? && answer["noul"].between?(0, 1)
    end

    def unavailable(reason)
      JudgmentResult.unavailable(provider: PROVIDER, reason: reason)
    end
  end
end
