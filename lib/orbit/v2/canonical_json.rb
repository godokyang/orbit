# frozen_string_literal: true

require "digest"
require "json"

module Orbit
  module V2
    module CanonicalJSON
      module_function

      ENVELOPE_FIELDS = %w[accepted_at content_digest created_at envelope].freeze
      MAX_SAFE_INTEGER = 9_007_199_254_740_991

      def dump(value)
        encode(normalize(value))
      end

      def sha256(value)
        Digest::SHA256.hexdigest(dump(value))
      end

      def content_digest(document)
        digest_excluding(document, *ENVELOPE_FIELDS)
      end

      def digest_excluding(document, *fields)
        semantic = document.each_with_object({}) do |(key, value), result|
          result[key] = value unless fields.map(&:to_s).include?(key.to_s)
        end
        "sha256:#{sha256(semantic)}"
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), normalized|
            raise ArgumentError, "canonical JSON object keys must be strings" unless key.is_a?(String)

            normalized_key = normalize_string(key)
            if normalized.key?(normalized_key)
              raise ArgumentError, "canonical JSON object keys collide after Unicode NFC normalization"
            end
            normalized[normalized_key] = normalize(child)
          end
        when Array
          value.map { |child| normalize(child) }
        when String
          normalize_string(value)
        when Integer
          unless value.between?(-MAX_SAFE_INTEGER, MAX_SAFE_INTEGER)
            raise ArgumentError, "Orbit v2 canonical integers must be within the interoperable signed 53-bit range"
          end
          value
        when TrueClass, FalseClass, NilClass
          value
        when Float
          raise ArgumentError, "Orbit v2 canonical contract values do not permit floating-point numbers"
        else
          raise ArgumentError, "unsupported canonical JSON value: #{value.class}"
        end
      end

      def encode(value)
        case value
        when Hash
          pairs = value.keys.sort_by { |key| key.encode(Encoding::UTF_16BE).bytes }.map do |key|
            "#{JSON.generate(key)}:#{encode(value.fetch(key))}"
          end
          "{#{pairs.join(",")}}"
        when Array
          "[#{value.map { |child| encode(child) }.join(",")}]"
        when String
          JSON.generate(value)
        when Integer
          value.to_s
        when TrueClass
          "true"
        when FalseClass
          "false"
        when NilClass
          "null"
        else
          raise ArgumentError, "value was not normalized: #{value.class}"
        end
      end

      def normalize_string(value)
        value.encode(Encoding::UTF_8).unicode_normalize(:nfc)
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise ArgumentError, "canonical JSON strings must be valid UTF-8"
      end
    end
  end
end
