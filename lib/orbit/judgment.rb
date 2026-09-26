# frozen_string_literal: true

module Orbit
  # Unified external-judgment data model (ADR-008 2026-09-26 supplement;
  # contracts/task-runtime.md「统一判断数据模型与 provider 适配」). Business
  # code builds a JudgmentRequest and consumes a JudgmentResult; service
  # adapters translate between this model and their own native form. The first
  # version covers only the binary probabilistic judgments Orbit actually uses:
  # every question states when it is true and when it is false, and an answer
  # is a finite probability in [0, 1] that the question is true — never a
  # model's self-reported confidence or free text.
  #
  # An `unavailable` result carries a structured reason and no partial answers:
  # incomplete or unmappable responses must never feed an automatic action.
  class JudgmentRequest
    SCHEMA_VERSION = 1
    class Error < StandardError; end

    attr_reader :state, :questions, :question_set_version, :provider, :model

    def initialize(state:, questions:, question_set_version:, provider:, model: nil)
      raise Error, "judgment state must be a hash" unless state.is_a?(Hash)
      unless question_set_version.is_a?(String) && !question_set_version.strip.empty?
        raise Error, "question set version must be a non-empty string"
      end
      raise Error, "provider must be a non-empty string" unless provider.is_a?(String) && !provider.strip.empty?
      raise Error, "at least one judgment question is required" unless questions.is_a?(Hash) && !questions.empty?

      questions.each do |id, question|
        unless id.is_a?(String) && !id.strip.empty?
          raise Error, "question ids must be non-empty strings"
        end
        unless question.is_a?(Hash) && plain_string?(question["instruction"]) &&
               plain_string?(question["true_criterion"]) && plain_string?(question["false_criterion"])
          raise Error, "question #{id} needs instruction, true_criterion and false_criterion"
        end
      end

      @state = state
      @questions = questions.dup.freeze
      @question_set_version = question_set_version
      @provider = provider
      @model = model
    end

    def to_h
      result = {
        "schema_version" => SCHEMA_VERSION, "state" => state, "questions" => questions,
        "question_set_version" => question_set_version, "provider" => provider
      }
      result["model"] = model if model
      result
    end

    private

    def plain_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end
  end

  class JudgmentResult
    SCHEMA_VERSION = 1
    class Error < StandardError; end

    attr_reader :status, :answers, :provider, :actual_model, :usage, :error

    # `answers` maps question ids to {"probability_true" => 0..1}. Validation
    # happens here, not in the adapters: Orbit owns result validation and every
    # value must be a finite number in [0, 1].
    def self.answered(answers:, provider:, actual_model:, usage: nil)
      raise Error, "provider must be a non-empty string" unless provider.is_a?(String) && !provider.strip.empty?
      raise Error, "actual_model must be a non-empty string" unless actual_model.is_a?(String) && !actual_model.strip.empty?
      raise Error, "answered results need at least one answer" unless answers.is_a?(Hash) && !answers.empty?

      scores = {}
      answers.each do |id, answer|
        raise Error, "answer ids must be non-empty strings" unless id.is_a?(String) && !id.strip.empty?
        raise Error, "answer #{id} must be a hash with probability_true" unless answer.is_a?(Hash)

        value = answer["probability_true"]
        unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
          raise Error, "probability_true for #{id} must be a finite number in [0, 1]"
        end

        scores[id] = value
      end
      new("answered", scores, provider, actual_model, bounded_usage(usage), nil)
    end

    def self.unavailable(provider:, reason:, actual_model: nil)
      raise Error, "unavailable results need a non-empty reason" unless reason.is_a?(String) && !reason.strip.empty?

      new("unavailable", {}, provider, actual_model, nil, reason)
    end

    def initialize(status, answers, provider, actual_model, usage, error)
      @status = status
      @answers = answers
      @provider = provider
      @actual_model = actual_model
      @usage = usage
      @error = error
      freeze
    end

    def answered? = status == "answered"
    def unavailable? = status == "unavailable"

    # Complete for a request when every requested question id carries a finite
    # in-range score. Extra ids the provider volunteered are ignored, matching
    # the previous per-question extraction behavior.
    def complete_for?(request)
      answered? && request.questions.keys.all? { |id| answers.key?(id) }
    end

    def probability_true(question_id)
      raise Error, "judgment is unavailable: #{error}" unless answered?
      raise Error, "no answer for question #{question_id}" unless answers.key?(question_id)

      answers.fetch(question_id)
    end

    def to_h
      result = {
        "schema_version" => SCHEMA_VERSION, "status" => status,
        "source" => { "provider" => provider }.tap { |source| source["actual_model"] = actual_model if actual_model }
      }
      result["answers"] = answers.transform_values { |value| { "probability_true" => value } } if answered?
      result["usage"] = usage if usage
      result["error"] = error if unavailable?
      result
    end

    # Usage is recorded when the service reports it in a usable shape; it is
    # reference-only and never gates a decision.
    def self.bounded_usage(usage)
      return nil unless usage.is_a?(Hash) && !usage.empty?

      usage.select { |_key, value| value.is_a?(Numeric) && value.finite? }
    end
  end
end
