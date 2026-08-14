# frozen_string_literal: true

require "set"

require_relative "canonical_json"

module Orbit
  module V2
    # Pure derivation primitives shared by the Validator and the Slice 5
    # AggregateOutcome projection.
    #
    # Every function here is a stateless mapping over already-indexed facts:
    # none reports errors, mutates state, or resolves authority. The Validator
    # and the projection delegate to the same functions, so these semantics
    # cannot drift into two subtly different implementations.
    module ProjectionPrimitives
      module_function

      # Structural supersedes-tip analysis over one node set.
      Lineage = Struct.new(:status, :tips, :at, keyword_init: true)

      # The policy-derived disposition of a Finding. The active
      # ProjectPolicyRevision owns the closed `finding_disposition` mapping;
      # a Finding body, severity, or free text never influences the result.
      # Returns nil when the finding or the policy mapping is absent.
      def finding_disposition(finding, policy)
        mapping = policy.is_a?(Hash) ? policy["finding_disposition"] : nil
        return nil unless mapping.is_a?(Hash) && finding.is_a?(Hash)

        mapping[finding["basis"]]
      end

      # The immutable lineage a Finding derives through its reporting
      # GateEvaluation, that evaluation's GateRequirement, and the subject
      # TaskRevision the evaluation pinned. Returns nil when the chain does
      # not resolve to one exact project/task/revision identity.
      def finding_lineage(finding, evaluations:, requirements:, tasks:)
        return nil unless finding.is_a?(Hash)

        evaluation = evaluations[finding["gate_evaluation_id"]]
        requirement = evaluation && requirements[evaluation["gate_requirement_id"]]
        task = requirement && tasks[requirement["task_revision_id"]]
        subject_ref = evaluation && evaluation.dig("subject", "task_revision_ref")
        return nil unless evaluation &&
                          requirement &&
                          task &&
                          requirement["task_id"] == task["task_id"] &&
                          subject_ref &&
                          subject_ref["task_revision_id"] == task["task_revision_id"] &&
                          subject_ref["content_digest"] == task["content_digest"]

        {
          "task_id" => task["task_id"],
          "task_revision_id" => task["task_revision_id"],
          "gate_requirement_id" => requirement["gate_requirement_id"],
          "gate_lineage_id" => requirement["gate_lineage_id"]
        }
      end

      # Status:
      #   :empty        the node set is empty
      #   :unique       exactly one current tip; no cycle, fork, or orphan
      #   :ambiguous    zero (non-empty set) or multiple tips
      #   :cycle        the single tip's supersedes chain revisits a node
      #   :disconnected the single tip's chain cannot reach every node
      def supersedes_tips(nodes, id_key:, supersedes_key:)
        return Lineage.new(status: :empty, tips: []) if nodes.empty?

        superseded = nodes.each_with_object(Set.new) do |node, ids|
          ref = node[supersedes_key]
          ids << ref if ref
        end
        tips = nodes.reject { |node| superseded.include?(node[id_key]) }
        return Lineage.new(status: :ambiguous, tips: tips) if tips.length != 1

        by_id = nodes.to_h { |node| [node[id_key], node] }
        visited = Set.new
        cursor = tips.first
        while cursor
          id = cursor[id_key]
          return Lineage.new(status: :cycle, tips: tips, at: id) if visited.include?(id)

          visited << id
          parent_id = cursor[supersedes_key]
          cursor = parent_id && by_id[parent_id]
        end
        return Lineage.new(status: :disconnected, tips: tips) unless visited.length == nodes.length

        Lineage.new(status: :unique, tips: tips)
      end

      # The single ValidationFailure error a projection may tolerate: a
      # structurally complete create-only GateEvaluation whose pinned subject
      # no longer equals the CURRENT canonical selector result. The predicate
      # is keyed on code plus the exact error path
      # (gate_evaluations.<id>.subject) — never message text. ADR-005 keeps
      # the accepted evaluation immutable; later subject changes make it
      # historical and nonparticipating instead of rejecting the fact set.
      # Every other currentness error (stale GateRequirement digest at
      # .gate_requirement_content_digest, stale active-policy authority at
      # .subject.task_revision_ref, malformed/incomplete subject) and every
      # shape/authority/provenance/independence/resolution error still
      # rejects.
      def historical_stale_evaluation_error?(error)
        error.is_a?(ContractError) &&
          error.code == "subject_stale" &&
          error.path.is_a?(String) &&
          /\Agate_evaluations\.[^.]+\.subject\z/.match?(error.path)
      end

      # The canonical subject identity of a budget-assessment GateEvaluation:
      # the evaluation's own `budget_review_subject_projection` joins the
      # recomputed subject, and the subject digest is recomputed over that
      # identity. The projection digest itself is validated by the budget
      # assessment producer seam, not re-derived here.
      def canonical_budget_subject(expected, evaluation)
        subject = expected.merge(
          "budget_review_subject_projection" =>
            evaluation.dig("subject", "budget_review_subject_projection")
        )
        identity = subject.reject { |key, _value| key == "subject_digest" }
        subject["subject_digest"] = "sha256:#{CanonicalJSON.sha256(identity)}"
        subject
      end
    end
  end
end
