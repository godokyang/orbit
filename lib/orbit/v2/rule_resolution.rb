# frozen_string_literal: true

require_relative "canonical_json"
require_relative "errors"
require_relative "identifiers"
require_relative "schema_catalog"
require "pathname"

module Orbit
  module V2
    module RuleResolution
      module_function

      RELATION_PRECEDENCE = {
        "baseline" => 0,
        "supplements" => 1,
        "stricter_than" => 2,
        "overrides" => 3
      }.freeze

      def canonical_identity(identity, project_root: Dir.pwd)
        normalized = CanonicalJSON.normalize(deep_copy(identity))
        unless normalized["identity_schema"] == "orbit-rule-resolution-identity-v1"
          raise ContractError.new(
            "unsupported_schema_version",
            "rule resolution identity_schema must be orbit-rule-resolution-identity-v1",
            path: "identity.identity_schema"
          )
        end
        rules = Array(normalized["required_rules"])
        duplicate_rule = duplicate_value(rules.map { |rule| rule["rule_id"] })
        if duplicate_rule
          raise ContractError.new(
            "rule_resolution_duplicate",
            "required rules must have unique rule_id and canonical path",
            path: "identity.required_rules",
            details: { "duplicate_rule_id" => duplicate_rule }
          )
        end
        rules.each do |rule|
          relation = rule["relation"]
          unless RELATION_PRECEDENCE.key?(relation)
            raise ContractError.new(
              "rule_resolution_relation",
              "unknown rule relation #{relation.inspect}",
              path: "identity.required_rules.relation"
            )
          end
          rule["path"] = canonicalize_path!(rule["path"], project_root)
          unless Identifiers.digest?(rule["content_sha256"])
            raise ContractError.new(
              "rule_resolution_digest",
              "rule content_sha256 must be sha256-prefixed lowercase hex",
              path: "identity.required_rules.content_sha256"
            )
          end
          expected_digest = "sha256:#{Digest::SHA256.file(File.join(project_root, rule["path"])).hexdigest}"
          unless rule["content_sha256"] == expected_digest
            raise ContractError.new(
              "rule_resolution_digest",
              "rule content_sha256 does not match canonical rule bytes",
              path: "identity.required_rules.content_sha256"
            )
          end
        end
        duplicate_path = duplicate_value(rules.map { |rule| rule["path"] })
        if duplicate_path
          raise ContractError.new(
            "rule_resolution_duplicate",
            "required rules resolve to the same canonical file",
            path: "identity.required_rules",
            details: { "duplicate_path" => duplicate_path }
          )
        end
        normalized["required_rules"] = rules.sort_by do |rule|
          [
            RELATION_PRECEDENCE.fetch(rule["relation"]),
            rule["rule_id"],
            rule["path"],
            rule["content_sha256"]
          ]
        end
        normalized
      end

      def build(identity, created_at:, project_root: Dir.pwd)
        canonical = canonical_identity(identity, project_root: project_root)
        digest = CanonicalJSON.sha256(canonical)
        {
          "schema_version" => SchemaCatalog::SUPPORTED.fetch("rule_resolution"),
          "protocol_epoch" => canonical.fetch("protocol_epoch"),
          "project_id" => canonical.fetch("project_id"),
          "resolution_id" => "rr-sha256-#{digest}",
          "identity" => canonical,
          "identity_sha256" => "sha256:#{digest}",
          "envelope" => { "created_at" => created_at }
        }
      end

      def validate!(artifact, project_root: Dir.pwd)
        SchemaCatalog.check!("rule_resolution", artifact)
        expected = build(
          artifact.fetch("identity"),
          created_at: artifact.dig("envelope", "created_at"),
          project_root: project_root
        )
        unless artifact["protocol_epoch"] == expected["protocol_epoch"] &&
               artifact["project_id"] == expected["project_id"] &&
               artifact["resolution_id"] == expected["resolution_id"] &&
               artifact["identity_sha256"] == expected["identity_sha256"] &&
               CanonicalJSON.dump(artifact["identity"]) == CanonicalJSON.dump(expected["identity"])
          raise ContractError.new(
            "rule_resolution_identity_mismatch",
            "resolution ID, digest, and canonical identity must describe the same bytes",
            path: "rule_resolution"
          )
        end
        true
      end

      def canonicalize_path!(path, project_root)
        unless path.is_a?(String) &&
               !path.empty? &&
               !path.start_with?("/") &&
               path.split("/").none? { |segment| segment.empty? || segment == "." || segment == ".." } &&
               path == path.tr("\\", "/")
          raise ContractError.new(
            "rule_resolution_path",
            "rule path must be a canonical project-relative POSIX path",
            path: "identity.required_rules.path"
          )
        end
        normalized = path.unicode_normalize(:nfc)
        root = File.realpath(project_root)
        candidate = File.realpath(File.join(root, normalized))
        unless candidate.start_with?("#{root}#{File::SEPARATOR}")
          raise ContractError.new(
            "rule_resolution_path",
            "rule path resolves outside the project root",
            path: "identity.required_rules.path"
          )
        end
        Pathname.new(candidate).relative_path_from(Pathname.new(root)).to_s.tr("\\", "/")
      rescue Errno::ENOENT, ArgumentError
        raise ContractError.new(
          "rule_resolution_path",
          "rule path must resolve to an existing file inside the project root",
          path: "identity.required_rules.path"
        )
      end

      def duplicate_value(values)
        values.group_by(&:itself).find { |value, grouped| !value.nil? && grouped.length > 1 }&.first
      end

      def deep_copy(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end
