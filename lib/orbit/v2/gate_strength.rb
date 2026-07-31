# frozen_string_literal: true

module Orbit
  module V2
    module GateStrength
      module_function

      EVIDENCE_LEVELS = {
        "mechanical_check" => 0,
        "outcome_quality" => 1,
        "implementation_readiness" => 2,
        "real_path_test" => 3,
        "release_readiness" => 4
      }.freeze
      INDEPENDENCE_LEVELS = {
        "same_agent_allowed" => 0,
        "independent_evaluator" => 1
      }.freeze

      def evidence_at_least?(actual, minimum)
        at_least?(EVIDENCE_LEVELS, actual, minimum)
      end

      def independence_at_least?(actual, minimum)
        at_least?(INDEPENDENCE_LEVELS, actual, minimum)
      end

      def at_least?(levels, actual, minimum)
        levels.key?(actual) &&
          levels.key?(minimum) &&
          levels.fetch(actual) >= levels.fetch(minimum)
      end
      private_class_method :at_least?
    end
  end
end
