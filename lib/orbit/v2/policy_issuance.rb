# frozen_string_literal: true

require_relative "canonical_json"

module Orbit
  module V2
    module PolicyIssuance
      module_function

      SCHEMA_VERSION = "orbit-policy-issuance-v1"

      def build_envelope(candidate_policy:, parent_policy:, assertion_id:, assertion_digest:,
                         provider_id:, receipt_id:, issued_at:)
        envelope = {
          "schema_version" => SCHEMA_VERSION,
          "issuance_kind" => parent_policy ? "rotation" : "genesis",
          "project_id" => candidate_policy.fetch("project_id"),
          "parent_policy_revision_ref" => policy_ref(parent_policy),
          "candidate_policy_revision_ref" => policy_ref(candidate_policy),
          "authority_source_revision_ref" => {
            "provider_id" => provider_id,
            "receipt_id" => receipt_id,
            "assertion_id" => assertion_id,
            "assertion_digest" => assertion_digest
          },
          "decision" => "approved",
          "issued_at" => issued_at
        }
        envelope.merge("envelope_digest" => envelope_digest(envelope))
      end

      def envelope_digest(envelope)
        CanonicalJSON.digest_excluding(envelope, "envelope_digest")
      end

      def policy_ref(policy)
        return nil unless policy

        {
          "policy_revision_id" => policy.fetch("policy_revision_id"),
          "content_digest" => policy.fetch("content_digest")
        }
      end
    end
  end
end
