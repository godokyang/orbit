# frozen_string_literal: true

module Orbit
  module V2
    class ContractError < StandardError
      attr_reader :code, :path, :details

      def initialize(code, message, path: nil, details: nil)
        @code = code
        @path = path
        @details = details
        super(message)
      end

      def to_h
        {
          "code" => code,
          "message" => message,
          "path" => path,
          "details" => details
        }.compact
      end
    end

    class ValidationFailure < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.map { |error| "#{error.code}: #{error.message}" }.join("; "))
      end
    end
  end
end
