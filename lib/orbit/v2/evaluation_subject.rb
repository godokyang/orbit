# frozen_string_literal: true

require_relative "canonical_json"
require_relative "code_surface"
require_relative "errors"
require_relative "identifiers"
require_relative "path_scope"
require_relative "projection_primitives"
require_relative "runtime_identity_verifier"

module Orbit
  module V2
    module EvaluationSubject
      module_function

      def select(gate_requirement:, task_revision:, work_units:, attempts:, evidence_records:,
                 repository_snapshot:, code_surface:)
        validate_derived_inputs!(repository_snapshot, code_surface)
        selector = gate_requirement.fetch("subject_selector")
        unless gate_requirement["project_id"] == task_revision["project_id"] &&
               gate_requirement["task_id"] == task_revision["task_id"] &&
               gate_requirement["task_revision_id"] == task_revision["task_revision_id"]
          raise ContractError.new(
            "subject_lineage_invalid",
            "GateRequirement and subject TaskRevision must share exact project/task/revision identity",
            path: "gate_requirement"
          )
        end
        eligible_units = work_units.select do |unit|
          same_subject_lineage?(unit, task_revision) &&
            unit["work_unit_kind"] == selector.fetch("work_unit_kind")
        end
        selected_units = case selector.fetch("scope")
                         when "task_wide"
                           unless Array(selector["work_unit_refs"]).empty?
                             raise ContractError.new(
                               "subject_selector_invalid",
                               "task_wide selectors must not carry selected work_unit_refs",
                               path: "gate_requirement.subject_selector.work_unit_refs"
                             )
                           end
                           eligible_units
                         when "selected_work_units"
                           refs = Array(selector["work_unit_refs"])
                           eligible_units.select { |unit| refs.include?(unit["work_unit_id"]) }
                         else
                           raise ContractError.new(
                             "subject_selector_invalid",
                             "unknown subject selector scope",
                             path: "gate_requirement.subject_selector.scope"
                           )
                         end
        selected_ids = selected_units.map { |unit| unit["work_unit_id"] }
        if selected_ids.empty? ||
           (selector["scope"] == "selected_work_units" &&
             selected_ids.sort != Array(selector["work_unit_refs"]).sort)
          raise ContractError.new(
            "subject_incomplete",
            "subject selector did not resolve every required WorkUnit",
            path: "gate_requirement.subject_selector"
          )
        end

        accepted_implementation_records = evidence_records.select do |record|
          record["record_kind"] == "implementation" &&
            record["accepted"] == true &&
            same_subject_lineage?(record, task_revision)
        end
        accepted_attempt_ids = accepted_implementation_records.map { |record| record["attempt_id"] }.uniq
        candidate_attempts = attempts.select do |attempt|
          selected_ids.include?(attempt["work_unit_id"]) &&
            attempt_purpose(attempt) == "implementation"
        end
        invalid_attempt = candidate_attempts.find do |attempt|
          !same_subject_lineage?(attempt, task_revision)
        end
        if invalid_attempt
          raise ContractError.new(
            "subject_lineage_invalid",
            "selected implementation Attempt belongs to another project/task/revision",
            path: "work_unit_attempts.#{invalid_attempt["attempt_id"]}"
          )
        end
        candidate_attempt_ids = candidate_attempts.map { |attempt| attempt["attempt_id"] }
        relevant_records = evidence_records.select do |record|
          record["record_kind"] == "implementation" &&
            (
              selected_ids.include?(record["work_unit_id"]) ||
              candidate_attempt_ids.include?(record["attempt_id"])
            )
        end
        invalid_record = relevant_records.find do |record|
          !same_subject_lineage?(record, task_revision) ||
            !selected_ids.include?(record["work_unit_id"]) ||
            !candidate_attempt_ids.include?(record["attempt_id"])
        end
        if invalid_record
          raise ContractError.new(
            "subject_lineage_invalid",
            "selected implementation EvidenceRecord belongs to another subject lineage",
            path: "evidence_records.#{invalid_record["evidence_record_id"]}"
          )
        end
        selected_attempts = attempts.select do |attempt|
          selected_ids.include?(attempt["work_unit_id"]) &&
            attempt_purpose(attempt) == "implementation" &&
            accepted_attempt_ids.include?(attempt["attempt_id"]) &&
            same_subject_lineage?(attempt, task_revision)
        end
        selected_attempt_ids = selected_attempts.map { |attempt| attempt["attempt_id"] }
        selected_records = accepted_implementation_records.select do |record|
          selected_attempt_ids.include?(record["attempt_id"])
        end
        unless selected_ids.all? { |id| selected_attempts.any? { |attempt| attempt["work_unit_id"] == id } } &&
               selected_attempt_ids.all? { |id| selected_records.any? { |record| record["attempt_id"] == id } }
          raise ContractError.new(
            "subject_incomplete",
            "every selected WorkUnit and implementation Attempt needs accepted implementation evidence",
            path: "gate_evaluation.subject"
          )
        end

        digest_input = {
          "gate_requirement_ref" => ref(
            "gate_requirement_id",
            gate_requirement.fetch("gate_requirement_id"),
            gate_requirement.fetch("content_digest")
          ),
          "task_revision_ref" => ref(
            "task_revision_id",
            task_revision.fetch("task_revision_id"),
            task_revision.fetch("content_digest")
          ),
          "work_unit_refs" => selected_units.map do |unit|
            ref("work_unit_id", unit.fetch("work_unit_id"), unit.fetch("content_digest"))
          end.sort_by { |item| item["work_unit_id"] },
          "implementation_attempt_refs" => selected_attempts.map do |attempt|
            {
              "attempt_id" => attempt.fetch("attempt_id"),
              "creation_event_digest" => attempt.fetch("events").first.fetch("event_digest")
            }
          end.sort_by { |item| item["attempt_id"] },
          "evidence_record_refs" => selected_records.map do |record|
            ref("evidence_record_id", record.fetch("evidence_record_id"), record.fetch("content_digest"))
          end.sort_by { |item| item["evidence_record_id"] },
          "repository_snapshot_ref" => repository_snapshot,
          "code_surface_ref" => code_surface
        }
        digest_input.merge("subject_digest" => "sha256:#{CanonicalJSON.sha256(digest_input)}")
      end

      def same?(expected, actual)
        CanonicalJSON.dump(expected) == CanonicalJSON.dump(actual)
      end

      def attempt_purpose(attempt)
        attempt.fetch("events").first.fetch("assignment").fetch("purpose")
      end

      def same_subject_lineage?(document, task_revision)
        document["project_id"] == task_revision["project_id"] &&
          document["task_id"] == task_revision["task_id"] &&
          document["task_revision_id"] == task_revision["task_revision_id"]
      end

      def producer_agent_ids(subject, attempts, evidence_records)
        evidence_ids = subject.fetch("evidence_record_refs").map { |ref| ref.fetch("evidence_record_id") }
        attempt_ids = evidence_records.select { |record| evidence_ids.include?(record["evidence_record_id"]) }
                                      .map { |record| record["attempt_id"] }
        attempts.select { |attempt| attempt_ids.include?(attempt["attempt_id"]) }
                .map { |attempt| attempt.fetch("events").first.fetch("assignment").fetch("agent_instance_id") }
                .uniq
      end

      def producer_runtime_identities(subject, attempts, evidence_records, agent_instances)
        agents_by_id = agent_instances.to_h do |agent|
          [agent.fetch("agent_instance_id"), agent]
        end
        producer_agent_ids(subject, attempts, evidence_records).map do |agent_id|
          RuntimeIdentityVerifier.identity_key(agents_by_id.fetch(agent_id).fetch("runtime_identity"))
        end.uniq
      end

      def validate_derived_inputs!(repository_snapshot, code_surface)
        unless code_surface.is_a?(Hash)
          raise ContractError.new(
            "derived_input_invalid",
            "CodeSurface must be a deterministic projection of version, tree digest, and sorted paths",
            path: "code_surface"
          )
        end
        derived =
          begin
            CodeSurface.derive(
              repository_snapshot: repository_snapshot,
              paths: code_surface["paths"]
            )
          rescue ContractError => e
            # Preserve the established EvaluationSubject error paths: an
            # invalid snapshot reports at repository_snapshot, any other
            # invalid stored CodeSurface reports at code_surface (the direct
            # CodeSurface seam itself reports path-level detail).
            raise ContractError.new(
              "derived_input_invalid",
              e.message,
              path: e.path == "repository_snapshot" ? "repository_snapshot" : "code_surface"
            )
          end
        unless code_surface["kind"] == derived["kind"] &&
               code_surface["derivation_version"] == derived["derivation_version"] &&
               code_surface["repository_tree_digest"] == derived["repository_tree_digest"] &&
               code_surface["paths"] == derived["paths"] &&
               code_surface["code_surface_digest"] == derived["code_surface_digest"]
          raise ContractError.new(
            "derived_input_invalid",
            "CodeSurface must be a deterministic projection of version, tree digest, and sorted paths",
            path: "code_surface"
          )
        end
      end

      def code_surface_digest(derivation_version:, repository_tree_digest:, paths:)
        ProjectionPrimitives.code_surface_digest(
          derivation_version: derivation_version,
          repository_tree_digest: repository_tree_digest,
          paths: paths
        )
      end

      def ref(id_key, id, digest)
        { id_key => id, "content_digest" => digest }
      end
    end
  end
end
