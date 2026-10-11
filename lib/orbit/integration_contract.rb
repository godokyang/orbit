# frozen_string_literal: true

require "json"
require_relative "version"

module Orbit
  # Serves contracts/integration.json, the machine-readable integration
  # contract. Read-only: no session, task or model is involved. A missing or
  # foreign file fails closed instead of reporting a guessed capability list.
  module IntegrationContract
    PATH = File.join(Orbit::ROOT, "contracts", "integration.json")
    NAME = "orbit-integration"

    class Error < StandardError; end

    module_function

    def document
      parsed = JSON.parse(File.read(PATH))
      unless parsed.is_a?(Hash) && parsed["contract"] == NAME && parsed["version"].is_a?(String) &&
             parsed["major"].is_a?(Integer) && parsed["version"].split(".").first.to_i == parsed["major"] &&
             parsed["capabilities"].is_a?(Hash)
        raise Error, "integration contract file is not a valid #{NAME} document: #{PATH}"
      end

      parsed
    rescue Errno::ENOENT
      raise Error, "integration contract file not found: #{PATH}"
    rescue JSON::ParserError => error
      raise Error, "integration contract file is not valid JSON: #{error.message}"
    end

    def report
      contract = document
      {
        "integration_contract" => { "name" => NAME, "version" => contract.fetch("version"), "major" => contract.fetch("major") },
        "orbit" => { "version" => Orbit::VERSION },
        "capabilities" => contract.fetch("capabilities")
      }
    end
  end
end
