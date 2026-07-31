# frozen_string_literal: true

require_relative "canonical_json"
require_relative "errors"

module Orbit
  module V2
    class InvariantGraph
      include Enumerable

      attr_reader :errors

      def initialize(records, identity_key:, path:, digest_key: nil, kind_key: nil)
        @identity_key = identity_key
        @digest_key = digest_key
        @kind_key = kind_key
        @path = path
        @index = {}
        @errors = []
        build(Array(records))
      end

      def [](identity)
        @index[identity]
      end

      def each(&block)
        @index.each(&block)
      end

      def each_value(&block)
        @index.each_value(&block)
      end

      def to_h
        @index
      end

      def resolve!(reference, allowed_kinds: nil, path: @path)
        unless reference.is_a?(Hash)
          raise ContractError.new(
            "reference_not_found",
            "reference must be an exact identity/digest object",
            path: path
          )
        end

        identity = reference[@identity_key]
        record = @index[identity]
        unless record
          raise ContractError.new(
            "reference_not_found",
            "#{@identity_key}=#{identity.inspect} does not resolve",
            path: path
          )
        end
        if @digest_key && reference[@digest_key] != record[@digest_key]
          raise ContractError.new(
            "digest_mismatch",
            "reference digest does not match the immutable target",
            path: path,
            details: {
              "expected" => record[@digest_key],
              "actual" => reference[@digest_key]
            }
          )
        end
        if allowed_kinds && !Array(allowed_kinds).include?(record[@kind_key])
          raise ContractError.new(
            "reference_kind_invalid",
            "reference resolves to #{record[@kind_key].inspect}, expected #{Array(allowed_kinds).join("|")}",
            path: path
          )
        end
        record
      end

      private

      def build(records)
        records.each_with_index do |record, index|
          record_path = "#{@path}[#{index}]"
          unless record.is_a?(Hash)
            add("invalid_document", "#{@path} entries must be objects", record_path)
            next
          end

          identity = record[@identity_key]
          if identity.nil?
            add(
              "invalid_id",
              "#{@path} entry is missing #{@identity_key}",
              "#{record_path}.#{@identity_key}"
            )
          elsif @index.key?(identity)
            previous = @index[identity]
            code = CanonicalJSON.dump(previous) == CanonicalJSON.dump(record) ?
              "duplicate_identity" : "immutable_record_reuse"
            add(
              code,
              "#{@path} reuses #{@identity_key}=#{identity.inspect}",
              "#{record_path}.#{@identity_key}"
            )
          else
            @index[identity] = record
          end
        end
      end

      def add(code, message, path)
        @errors << ContractError.new(code, message, path: path)
      end
    end
  end
end
