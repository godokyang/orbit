# frozen_string_literal: true

require_relative "canonical_json"
require_relative "gate_strength"

module Orbit
  module V2
    module ProtectedChange
      module_function

      PER_REVISION_GATE_FIELDS = %w[
        gate_requirement_id parent_gate_requirement_ref task_revision_id content_digest
      ].freeze

      def authorization_required?(parent_gates, candidate_gates)
        parent_by_lineage = protected_by_lineage(parent_gates)
        candidate_by_lineage = protected_by_lineage(candidate_gates)
        parent_by_lineage.any? do |lineage_id, parent|
          candidate = candidate_by_lineage[lineage_id]
          candidate.nil? || !same_or_stronger?(parent, candidate)
        end
      end

      def diff_digest(parent_task:, candidate_task:, parent_gates:, candidate_gates:)
        projection = {
          "schema_version" => "orbit-protected-change-diff-v1",
          "project_id" => candidate_task.fetch("project_id"),
          "task_id" => candidate_task.fetch("task_id"),
          "parent_task_revision_ref" => task_ref(parent_task),
          "candidate_task_revision_ref" => task_ref(candidate_task),
          "parent_protected_gate_refs" => gate_refs(parent_gates),
          "candidate_protected_gate_refs" => gate_refs(candidate_gates)
        }
        CanonicalJSON.content_digest(projection)
      end

      def envelope_digest(envelope)
        CanonicalJSON.digest_excluding(envelope, "envelope_digest")
      end

      def same_or_stronger?(parent, candidate)
        parent_semantic = semantic_gate(parent)
        candidate_semantic = semantic_gate(candidate)
        return true if parent_semantic == candidate_semantic

        parent_without_strength = parent_semantic.reject do |key, _value|
          %w[evidence_level independence].include?(key)
        end
        candidate_without_strength = candidate_semantic.reject do |key, _value|
          %w[evidence_level independence].include?(key)
        end
        parent_without_strength == candidate_without_strength &&
          GateStrength.evidence_at_least?(
            candidate["evidence_level"],
            parent["evidence_level"]
          ) &&
          GateStrength.independence_at_least?(
            candidate["independence"],
            parent["independence"]
          )
      end

      def semantic_gate(gate)
        gate.reject { |key, _value| PER_REVISION_GATE_FIELDS.include?(key) }
      end

      def protected_by_lineage(gates)
        Array(gates).select { |gate| gate.is_a?(Hash) && gate["protected"] == true }
                    .to_h { |gate| [gate["gate_lineage_id"], gate] }
      end

      def gate_refs(gates)
        Array(gates).select { |gate| gate.is_a?(Hash) && gate["protected"] == true }
                    .map do |gate|
          {
            "gate_lineage_id" => gate.fetch("gate_lineage_id"),
            "gate_requirement_id" => gate.fetch("gate_requirement_id"),
            "content_digest" => gate.fetch("content_digest")
          }
        end.sort_by { |ref| [ref["gate_lineage_id"], ref["gate_requirement_id"]] }
      end

      def task_ref(task)
        {
          "task_revision_id" => task.fetch("task_revision_id"),
          "content_digest" => task.fetch("content_digest")
        }
      end
    end
  end
end
