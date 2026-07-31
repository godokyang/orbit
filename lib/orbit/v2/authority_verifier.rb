# frozen_string_literal: true

require_relative "canonical_json"
require_relative "errors"

module Orbit
  module V2
    class AuthorityVerifier
      RECEIPT_SCHEMA = "orbit-authority-verification-receipt-v1"

      def initialize(providers: {})
        @providers = providers.transform_keys(&:to_s).freeze
      end

      def verify!(assertion)
        provider_id = assertion["provider_id"]
        provider = @providers[provider_id]
        unless provider
          raise ContractError.new(
            "authority_provider_unconfigured",
            "authority provider #{provider_id.inspect} is not configured",
            path: "authority_assertion.provider_id"
          )
        end

        expected_assertion_digest = assertion_digest(assertion)
        unless assertion["assertion_digest"] == expected_assertion_digest
          raise ContractError.new(
            "digest_mismatch",
            "AuthorityAssertion digest does not match its provider-bound claims",
            path: "authority_assertion.assertion_digest"
          )
        end

        receipt = assertion["verification_receipt"]
        validate_receipt_binding!(assertion, receipt, expected_assertion_digest)
        verified = provider.verify(
          receipt: deep_copy(receipt),
          assertion_digest: expected_assertion_digest,
          project_id: assertion["project_id"],
          assertion_id: assertion["assertion_id"]
        )
        unless verified == true
          raise ContractError.new(
            "authority_receipt_invalid",
            "configured provider did not verify the authority receipt",
            path: "authority_assertion.verification_receipt"
          )
        end

        true
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError.new(
          "authority_provider_error",
          "authority provider verification failed: #{e.class}",
          path: "authority_assertion.verification_receipt"
        )
      end

      def self.assertion_digest(assertion)
        excluded = %w[
          assertion_digest verification_receipt created_at accepted_at envelope
        ]
        if assertion["policy_issuance_envelope"] ||
           Array(assertion["grants"]).any? { |grant| %w[policy.genesis policy.rotate].include?(grant) }
          excluded.concat(%w[authority_scope_ref policy_issuance_envelope])
        end
        CanonicalJSON.digest_excluding(assertion, *excluded)
      end

      private

      def assertion_digest(assertion)
        self.class.assertion_digest(assertion)
      end

      def validate_receipt_binding!(assertion, receipt, assertion_digest)
        expected = {
          "schema_version" => RECEIPT_SCHEMA,
          "provider_id" => assertion["provider_id"],
          "project_id" => assertion["project_id"],
          "assertion_id" => assertion["assertion_id"],
          "assertion_digest" => assertion_digest,
          "issuer_kind" => assertion["issuer_kind"],
          "issuer_subject" => assertion["issuer_subject"],
          "authority_scope_ref" => assertion["authority_scope_ref"],
          "grants" => assertion["grants"]
        }
        unless receipt.is_a?(Hash) &&
               expected.all? { |key, value| receipt[key] == value } &&
               receipt["receipt_id"].is_a?(String) &&
               receipt["issued_at"].is_a?(String) &&
               receipt["receipt"].is_a?(String)
          raise ContractError.new(
            "authority_receipt_invalid",
            "provider receipt must bind the exact assertion digest, project, scope, issuer, and grants",
            path: "authority_assertion.verification_receipt"
          )
        end
      end

      def deep_copy(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end
