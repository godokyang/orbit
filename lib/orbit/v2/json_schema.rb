# frozen_string_literal: true

require "json"

require_relative "canonical_json"
require_relative "errors"

module Orbit
  module V2
    module JSONSchema
      class Registry
        SUPPORTED_KEYWORDS = %w[
          $schema $id $defs $ref title type required properties additionalProperties
          items minItems maxItems uniqueItems minLength minimum pattern enum const oneOf allOf
          if then else not
        ].freeze

        def initialize(schema_dir:)
          @schema_dir = File.expand_path(schema_dir)
          @documents = {}
        end

        def validate(file_name, instance, fragment: nil)
          schema = schema_document(file_name)
          schema = resolve_pointer(schema, fragment) if fragment
          errors = []
          validate_node(schema, instance, "$", file_name, errors)
          errors
        end

        def validate_fragment(schema, instance, current_file:)
          errors = []
          validate_node(schema, instance, "$", current_file, errors)
          errors
        end

        def schema_document(file_name)
          @documents[file_name] ||= JSON.parse(
            File.read(File.join(@schema_dir, file_name))
          )
        end

        private

        def validate_node(schema, instance, path, current_file, errors)
          unless schema.is_a?(Hash)
            add(errors, "contract_shape_invalid", "schema node must be an object", path)
            return
          end

          unknown_keywords = schema.keys - SUPPORTED_KEYWORDS
          unless unknown_keywords.empty?
            add(
              errors,
              "schema_definition_unsupported",
              "unsupported Draft 2020-12 keyword(s): #{unknown_keywords.sort.join(", ")}",
              path
            )
            return
          end

          if schema["$ref"]
            target, target_file = resolve_reference(schema["$ref"], current_file)
            validate_node(target, instance, path, target_file, errors)
          end

          Array(schema["allOf"]).each do |child|
            validate_node(child, instance, path, current_file, errors)
          end

          if schema["oneOf"]
            matches = schema["oneOf"].count do |child|
              child_errors = []
              validate_node(child, instance, path, current_file, child_errors)
              child_errors.empty?
            end
            add(errors, code_for(path), "value must match exactly one oneOf branch", path) unless matches == 1
          end

          if schema["not"]
            child_errors = []
            validate_node(schema["not"], instance, path, current_file, child_errors)
            add(errors, code_for(path), "value matches a forbidden schema", path) if child_errors.empty?
          end

          if schema["if"]
            condition_errors = []
            validate_node(schema["if"], instance, path, current_file, condition_errors)
            branch = condition_errors.empty? ? schema["then"] : schema["else"]
            validate_node(branch, instance, path, current_file, errors) if branch
          end

          validate_const(schema, instance, path, errors)
          validate_enum(schema, instance, path, errors)
          type_valid = validate_type(schema, instance, path, errors)
          return unless type_valid

          validate_string(schema, instance, path, errors) if instance.is_a?(String)
          validate_integer(schema, instance, path, errors) if instance.is_a?(Integer)
          validate_array(schema, instance, path, current_file, errors) if instance.is_a?(Array)
          validate_object(schema, instance, path, current_file, errors) if instance.is_a?(Hash)
        end

        def validate_const(schema, instance, path, errors)
          return unless schema.key?("const")
          return if instance == schema["const"]

          add(errors, code_for(path), "value must equal schema const", path)
        end

        def validate_enum(schema, instance, path, errors)
          return unless schema.key?("enum")
          return if schema["enum"].include?(instance)

          add(errors, code_for(path), "value is not in the allowed enum", path)
        end

        def validate_type(schema, instance, path, errors)
          return true unless schema["type"]

          valid = case schema["type"]
                  when "object" then instance.is_a?(Hash)
                  when "array" then instance.is_a?(Array)
                  when "string" then instance.is_a?(String)
                  when "integer" then instance.is_a?(Integer)
                  when "boolean" then instance == true || instance == false
                  when "null" then instance.nil?
                  else
                    add(
                      errors,
                      "schema_definition_unsupported",
                      "unsupported schema type #{schema["type"].inspect}",
                      path
                    )
                    return false
                  end
          add(errors, code_for(path), "value must have type #{schema["type"]}", path) unless valid
          valid
        end

        def validate_string(schema, instance, path, errors)
          if schema["minLength"] && instance.length < schema["minLength"]
            add(errors, code_for(path), "string is shorter than minLength", path)
          end
          return unless schema["pattern"]
          return if Regexp.new(schema["pattern"]).match?(instance)

          add(errors, code_for(path), "string does not match required pattern", path)
        rescue RegexpError => e
          add(errors, "schema_definition_unsupported", "invalid schema pattern: #{e.message}", path)
        end

        def validate_integer(schema, instance, path, errors)
          return unless schema["minimum"] && instance < schema["minimum"]

          add(errors, code_for(path), "integer is below minimum", path)
        end

        def validate_array(schema, instance, path, current_file, errors)
          if schema["minItems"] && instance.length < schema["minItems"]
            add(errors, code_for(path), "array has fewer than minItems", path)
          end
          if schema["maxItems"] && instance.length > schema["maxItems"]
            add(errors, code_for(path), "array has more than maxItems", path)
          end
          if schema["uniqueItems"]
            canonical = instance.map { |item| CanonicalJSON.dump(item) }
            add(errors, code_for(path), "array items must be unique", path) unless canonical.uniq.length == canonical.length
          end
          return unless schema["items"]

          instance.each_with_index do |item, index|
            validate_node(schema["items"], item, "#{path}[#{index}]", current_file, errors)
          end
        rescue ArgumentError => e
          add(errors, "canonicalization_error", e.message, path)
        end

        def validate_object(schema, instance, path, current_file, errors)
          Array(schema["required"]).each do |field|
            next if instance.key?(field)

            add(errors, code_for("#{path}.#{field}"), "required property is missing", "#{path}.#{field}")
          end
          properties = schema["properties"] || {}
          properties.each do |field, child|
            next unless instance.key?(field)

            validate_node(child, instance[field], "#{path}.#{field}", current_file, errors)
          end
          return unless schema["additionalProperties"] == false

          (instance.keys - properties.keys).each do |field|
            add(
              errors,
              "contract_shape_invalid",
              "unknown property is forbidden by the frozen schema",
              "#{path}.#{field}"
            )
          end
        end

        def resolve_reference(reference, current_file)
          file_part, fragment = reference.split("#", 2)
          file_name = file_part.nil? || file_part.empty? ? current_file : file_part
          schema = schema_document(file_name)
          [resolve_pointer(schema, fragment), file_name]
        end

        def resolve_pointer(document, fragment)
          return document if fragment.nil? || fragment.empty?
          unless fragment.start_with?("/")
            raise ContractError.new(
              "schema_definition_unsupported",
              "only JSON Pointer fragments are supported",
              path: fragment
            )
          end

          fragment.split("/").drop(1).reduce(document) do |current, token|
            current.fetch(token.gsub("~1", "/").gsub("~0", "~"))
          end
        rescue KeyError
          raise ContractError.new(
            "schema_definition_unsupported",
            "schema reference does not resolve",
            path: fragment
          )
        end

        def code_for(path)
          return "unsupported_schema_version" if path.end_with?(".schema_version")
          return "protocol_epoch_mismatch" if path.end_with?(".protocol_epoch")

          "contract_shape_invalid"
        end

        def add(errors, code, message, path)
          errors << ContractError.new(code, message, path: path)
        end
      end
    end
  end
end
