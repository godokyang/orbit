# frozen_string_literal: true

require "time"

require_relative "errors"

module Orbit
  module V2
    class LifecycleVerifier
      RECEIPT_SCHEMA = "orbit-lifecycle-writer-receipt-v1"

      def initialize(providers: {})
        @providers = providers.transform_keys(&:to_s).freeze
      end

      def verify!(event, project_id:)
        receipt = event["writer_receipt"]
        provider_id = receipt.is_a?(Hash) && receipt["provider_id"]
        provider = @providers[provider_id]
        unless provider
          raise ContractError.new(
            "lifecycle_provider_unconfigured",
            "lifecycle writer provider #{provider_id.inspect} is not configured",
            path: "lifecycle_event.writer_receipt.provider_id"
          )
        end

        recorded_at = Time.iso8601(event["recorded_at"])
        expected = {
          "schema_version" => RECEIPT_SCHEMA,
          "provider_id" => provider_id,
          "project_id" => project_id,
          "event_id" => event["event_id"],
          "event_type" => event["event_type"],
          "event_digest" => event["event_digest"],
          "recorded_at" => event["recorded_at"]
        }
        unless receipt.is_a?(Hash) &&
               expected.all? { |key, value| receipt[key] == value } &&
               receipt["receipt_id"].is_a?(String) &&
               receipt["receipt"].is_a?(String)
          raise ContractError.new(
            "lifecycle_receipt_invalid",
            "writer receipt must bind the exact event digest, identity, type, project, and recorded timestamp",
            path: "lifecycle_event.writer_receipt"
          )
        end

        verified = provider.verify(
          receipt: deep_copy(receipt),
          event_digest: event["event_digest"],
          project_id: project_id,
          event_id: event["event_id"],
          recorded_at: event["recorded_at"]
        )
        unless verified == true
          raise ContractError.new(
            "lifecycle_receipt_invalid",
            "configured provider did not verify the lifecycle writer receipt",
            path: "lifecycle_event.writer_receipt"
          )
        end

        recorded_at
      rescue ContractError
        raise
      rescue ArgumentError, TypeError
        raise ContractError.new(
          "lifecycle_chronology_invalid",
          "lifecycle recorded_at must be a parseable ISO-8601 timestamp",
          path: "lifecycle_event.recorded_at"
        )
      rescue StandardError => e
        raise ContractError.new(
          "lifecycle_provider_error",
          "lifecycle writer verification failed: #{e.class}",
          path: "lifecycle_event.writer_receipt"
        )
      end

      private

      def deep_copy(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end
