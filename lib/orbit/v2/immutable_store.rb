# frozen_string_literal: true

require_relative "canonical_json"
require_relative "errors"

module Orbit
  module V2
    class CreateOnlyStore
      def initialize
        @documents = {}
      end

      def create(type, id, document)
        key = [type, id]
        bytes = CanonicalJSON.dump(document)
        existing = @documents[key]
        if existing
          return :idempotent if existing == bytes

          raise ContractError.new(
            "immutable_record_reuse",
            "#{type} #{id} already exists with different canonical content",
            path: "#{type}.#{id}"
          )
        end
        @documents[key] = bytes
        :created
      end

      def fetch(type, id)
        bytes = @documents.fetch([type, id])
        JSON.parse(bytes)
      end

      def delete(type, id)
        raise ContractError.new(
          "immutable_record_delete",
          "#{type} #{id} is create-only and cannot be deleted",
          path: "#{type}.#{id}"
        )
      end
    end

    class AppendOnlyEventStore
      def initialize
        @streams = Hash.new { |hash, key| hash[key] = [] }
        @event_bytes = {}
      end

      def append(stream_id, event)
        event_id = event.fetch("event_id")
        bytes = CanonicalJSON.dump(event)
        if @event_bytes.key?(event_id)
          return :idempotent if @event_bytes.fetch(event_id) == bytes

          raise ContractError.new(
            "append_only_event_reuse",
            "event #{event_id} already exists with different canonical content",
            path: "events.#{event_id}"
          )
        end
        expected_previous = if @streams[stream_id].empty?
                              nil
                            else
                              JSON.parse(@streams[stream_id].last).fetch("event_digest", nil)
                            end
        unless event["previous_event_digest"] == expected_previous
          raise ContractError.new(
            "append_only_chain_mismatch",
            "event #{event_id} does not extend the current stream tip",
            path: "events.#{event_id}.previous_event_digest"
          )
        end
        @event_bytes[event_id] = bytes.dup.freeze
        @streams[stream_id] << bytes.dup.freeze
        :appended
      end

      def events(stream_id)
        @streams.fetch(stream_id, []).map { |bytes| JSON.parse(bytes) }
      end

      def delete(stream_id, event_id)
        raise ContractError.new(
          "append_only_event_delete",
          "event #{event_id} in #{stream_id} cannot be deleted",
          path: "events.#{event_id}"
        )
      end
    end
  end
end
