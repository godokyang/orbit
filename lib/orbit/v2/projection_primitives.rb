# frozen_string_literal: true

require "set"

require_relative "canonical_json"
require_relative "errors"
require_relative "evaluation_subject"

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

      # Collection -> (manifest kind, id field) for every authoritative
      # bundle collection. protocol_root is a singleton and is handled
      # separately by each projection.
      COLLECTION_SOURCES = {
        "authority_assertions" => ["authority_assertion", "assertion_id"],
        "authorization_records" => ["authorization_record", "authorization_record_id"],
        "project_policy_revisions" => ["project_policy_revision", "policy_revision_id"],
        "task_revisions" => ["task_revision", "task_revision_id"],
        "gate_requirements" => ["gate_requirement", "gate_requirement_id"],
        "work_units" => ["work_unit", "work_unit_id"],
        "agent_instances" => ["agent_instance", "agent_instance_id"],
        "logical_leads" => ["logical_lead", "logical_lead_id"],
        "lead_sessions" => ["lead_session", "lead_session_id"],
        "control_registries" => ["control_registry", "lead_control_id"],
        "lead_checkpoints" => ["lead_checkpoint", "lead_checkpoint_id"],
        "work_unit_attempts" => ["work_unit_attempt", "attempt_id"],
        "rule_resolution_artifacts" => ["rule_resolution_artifact", "resolution_id"],
        "evidence_records" => ["evidence_record", "evidence_record_id"],
        "gate_evaluations" => ["gate_evaluation", "gate_evaluation_id"],
        "findings" => ["finding", "finding_id"],
        "finding_resolutions" => ["finding_resolution", "finding_resolution_id"]
      }.freeze

      def source_digest(document)
        digest = document.is_a?(Hash) ? document["content_digest"] : nil
        digest.is_a?(String) ? digest : CanonicalJSON.content_digest(document)
      end

      # The complete sorted source ID+digest manifest of every validated
      # bundle source. Whole-bundle over-invalidation by design: the shared
      # eligibility boundary consumes the entire bundle, so every source is
      # part of the key. protocol_root is a singleton and is included exactly
      # once; every collection document appears exactly once; documents
      # without a stored content_digest get their canonical content digest
      # recomputed, so any byte change to any source changes the manifest.
      # A duplicate (kind, id) fails closed with the caller's error code.
      def bundle_source_manifest(bundle, error_code: "projection_invalid")
        entries = []
        root = bundle["protocol_root"]
        if root.is_a?(Hash) && root["project_id"].is_a?(String)
          entries << manifest_entry("protocol_root", root["project_id"], source_digest(root))
        end
        COLLECTION_SOURCES.each do |collection, (kind, id_field)|
          Array(bundle[collection]).each do |document|
            next unless document.is_a?(Hash)

            id = document[id_field]
            next if id.nil?

            entries << manifest_entry(kind, id, source_digest(document))
          end
        end
        Array(bundle["change_theses"]).each do |thesis|
          next unless thesis.is_a?(Hash)

          entries << manifest_entry(
            "change_thesis",
            "#{thesis["change_thesis_id"]}@#{thesis["revision"]}",
            thesis["content_digest"]
          )
        end
        snapshot = bundle["repository_snapshot"]
        code_surface = bundle["code_surface"]
        if snapshot.is_a?(Hash)
          entries << manifest_entry("repository_snapshot", snapshot["commit_sha"], snapshot["tree_digest"])
        end
        if code_surface.is_a?(Hash)
          entries << manifest_entry(
            "code_surface",
            code_surface["code_surface_digest"],
            code_surface["code_surface_digest"]
          )
        end
        seen = {}
        entries.each do |entry|
          key = [entry["kind"], entry["id"]]
          if seen.key?(key)
            raise ContractError.new(
              error_code,
              "source manifest contains a duplicate (kind, id)",
              path: "source_manifest"
            )
          end
          seen[key] = true
        end
        entries.sort_by { |entry| [entry["kind"], entry["id"]] }
      end

      def manifest_entry(kind, id, content_digest)
        { "kind" => kind, "id" => id, "content_digest" => content_digest }
      end

      # Participation predicate shared by AggregateOutcome and the
      # responsibility-scoped context projections: an evaluation participates
      # only when its GateRequirement digest is current and its pinned subject
      # equals the recomputed canonical subject (budget gates fold the
      # canonical budget_review_subject_projection identity). Timestamps and
      # array order never participate.
      def evaluation_current?(evaluation, requirement:, expected_subject:)
        return false unless evaluation.is_a?(Hash) && requirement.is_a?(Hash)
        return false unless evaluation["gate_requirement_content_digest"] == requirement["content_digest"]

        subject = evaluation["subject"]
        return false unless subject.is_a?(Hash)

        expected =
          if requirement.dig("subject_selector", "budget_assessment_required") == true
            canonical_budget_subject(expected_subject, evaluation)
          else
            expected_subject
          end
        EvaluationSubject.same?(expected, subject)
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
