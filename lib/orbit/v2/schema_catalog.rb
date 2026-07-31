# frozen_string_literal: true

require_relative "errors"
require_relative "json_schema"

module Orbit
  module V2
    module SchemaCatalog
      module_function

      SUPPORTED = {
        "protocol_root" => "orbit-protocol-root-v1",
        "authority_assertion" => "orbit-authority-assertion-v1",
        "authorization_record" => "orbit-authorization-record-v1",
        "project_policy_revision" => "orbit-project-policy-v1",
        "task_revision" => "orbit-task-v2",
        "work_unit" => "orbit-work-unit-v1",
        "change_thesis" => "orbit-change-thesis-v1",
        "agent_instance" => "orbit-agent-runtime-v1",
        "logical_lead" => "orbit-agent-runtime-v1",
        "lead_session" => "orbit-agent-runtime-v1",
        "work_unit_attempt" => "orbit-agent-runtime-v1",
        "rule_resolution" => "orbit-rule-resolution-v2",
        "evidence_record" => "orbit-evidence-v2",
        "gate_requirement" => "orbit-gate-requirement-v1",
        "gate_evaluation" => "orbit-gate-evaluation-v1",
        "finding" => "orbit-finding-v1",
        "finding_resolution" => "orbit-finding-resolution-v1",
        "contract_bundle" => "orbit-v2-contract-bundle-v1"
      }.freeze
      STRUCTURAL_SCHEMAS = {
        "protocol_root" => ["protocol-root.schema.json", nil],
        "authority_assertion" => ["authority.schema.json", "/$defs/AuthorityAssertion"],
        "authorization_record" => ["authority.schema.json", "/$defs/AuthorizationRecord"],
        "project_policy_revision" => ["authority.schema.json", "/$defs/ProjectPolicyRevision"],
        "task_revision" => ["task-work.schema.json", "/$defs/TaskRevision"],
        "work_unit" => ["task-work.schema.json", "/$defs/WorkUnit"],
        "change_thesis" => ["task-work.schema.json", "/$defs/ChangeThesis"],
        "agent_instance" => ["agent-runtime.schema.json", "/$defs/AgentInstance"],
        "logical_lead" => ["agent-runtime.schema.json", "/$defs/LogicalLead"],
        "lead_session" => ["agent-runtime.schema.json", "/$defs/LeadSession"],
        "work_unit_attempt" => ["agent-runtime.schema.json", "/$defs/WorkUnitAttempt"],
        "rule_resolution" => ["rule-resolution.schema.json", nil],
        "evidence_record" => ["evidence.schema.json", nil],
        "gate_requirement" => ["gate.schema.json", "/$defs/GateRequirement"],
        "gate_evaluation" => ["gate.schema.json", "/$defs/GateEvaluation"],
        "finding" => ["finding.schema.json", "/$defs/Finding"],
        "finding_resolution" => ["finding.schema.json", "/$defs/FindingResolution"],
        "contract_bundle" => ["contract-bundle.schema.json", nil]
      }.freeze
      SCHEMA_DIR = File.expand_path("../../../contracts/orbit-v2/schemas", __dir__)

      def check!(kind, document)
        expected = SUPPORTED.fetch(kind)
        actual = document.is_a?(Hash) ? document["schema_version"] : nil
        return if actual == expected

        raise ContractError.new(
          "unsupported_schema_version",
          "expected #{expected.inspect}, received #{actual.inspect}",
          path: "#{kind}.schema_version",
          details: { "expected" => expected, "actual" => actual }
        )
      end

      def structure_errors(kind, document)
        file_name, fragment = STRUCTURAL_SCHEMAS.fetch(kind)
        schema_registry.validate(file_name, document, fragment: fragment)
      end

      def validate_structure!(kind, document)
        errors = structure_errors(kind, document)
        raise ValidationFailure, errors unless errors.empty?

        true
      end

      def schema_registry
        @schema_registry ||= JSONSchema::Registry.new(schema_dir: SCHEMA_DIR)
      end
    end
  end
end
