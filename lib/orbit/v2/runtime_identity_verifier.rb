# frozen_string_literal: true

require_relative "errors"

module Orbit
  module V2
    class RuntimeIdentityVerifier
      def initialize(providers: {})
        @providers = providers.transform_keys(&:to_s).freeze
      end

      def verify!(agent)
        identity = agent["runtime_identity"]
        provider_id = identity.is_a?(Hash) && identity["provider_id"]
        provider = @providers[provider_id]
        unless provider
          raise ContractError.new(
            "runtime_identity_provider_unconfigured",
            "runtime identity provider #{provider_id.inspect} is not configured",
            path: "agent_instance.runtime_identity.provider_id"
          )
        end

        verified = provider.verify(
          verification_receipt_ref: identity["verification_receipt_ref"],
          provider_id: provider_id,
          project_id: agent["project_id"],
          agent_instance_id: agent["agent_instance_id"],
          runtime_subject_id: identity["runtime_subject_id"]
        )
        unless verified == true
          raise ContractError.new(
            "runtime_identity_receipt_invalid",
            "configured provider did not verify the AgentInstance runtime identity binding",
            path: "agent_instance.runtime_identity.verification_receipt_ref"
          )
        end

        self.class.identity_key(identity)
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError.new(
          "runtime_identity_provider_error",
          "runtime identity provider verification failed: #{e.class}",
          path: "agent_instance.runtime_identity.verification_receipt_ref"
        )
      end

      def self.identity_key(identity)
        [
          identity.fetch("provider_id"),
          identity.fetch("runtime_subject_id")
        ].freeze
      end
    end
  end
end
