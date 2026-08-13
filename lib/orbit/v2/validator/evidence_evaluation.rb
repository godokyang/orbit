# frozen_string_literal: true

unless defined?(Orbit::V2::Validator)
  raise LoadError, "load Validator internals through orbit/v2/validator"
end

module Orbit
  module V2
    class Validator
      module EvidenceEvaluation
        private

        def validate_rule_resolutions(bundle)
          attempts = @indexes.fetch("work_unit_attempts", {})
          Array(bundle["rule_resolution_artifacts"]).each do |artifact|
            next unless artifact.is_a?(Hash)

            check("rule_resolution_artifacts.#{artifact["resolution_id"]}") do
              RuleResolution.validate!(artifact, project_root: @project_root)
            end
            identity = artifact["identity"]
            next unless identity.is_a?(Hash)

            attempt = attempts[identity["attempt_id"]]
            unless attempt
              add("rule_resolution_identity_mismatch", "RuleResolution Attempt does not exist", "rule_resolution.identity.attempt_id")
              next
            end
            assignment = attempt.fetch("events").first["assignment"] || {}
            unless rule_resolution_identity_matches_attempt?(artifact, attempt, assignment)
              add(
                "rule_resolution_identity_mismatch",
                "RuleResolution identity must exact-match its Attempt immutable assignment",
                "rule_resolution.identity"
              )
            end
          end
        end

        def validate_evidence_records(bundle, active_policy)
          attempts = @indexes.fetch("work_unit_attempts", {})
          rules = @indexes.fetch("rule_resolution_artifacts", {})
          tasks = @indexes.fetch("task_revisions", {})
          Array(bundle["evidence_records"]).each do |record|
            next unless record.is_a?(Hash)

            path = "evidence_records.#{record["evidence_record_id"]}"
            attempt = attempts[record["attempt_id"]]
            unless attempt
              add("reference_not_found", "EvidenceRecord Attempt does not exist", "#{path}.attempt_id")
              next
            end
            assignment = attempt.fetch("events").first.fetch("assignment")
            submitted = rules[record["submitted_rule_resolution_id"]]
            assigned_id = assignment["assigned_rule_resolution_id"]
            unless submitted && submitted["resolution_id"] == assigned_id
              add("rule_resolution_identity_mismatch", "submitted rules must equal assigned canonical identity", "#{path}.submitted_rule_resolution_id")
            end
            if submitted && !rule_resolution_identity_matches_attempt?(submitted, attempt, assignment)
              add(
                "rule_resolution_identity_mismatch",
                "submitted RuleResolution identity must exact-match the record Attempt immutable assignment",
                "#{path}.submitted_rule_resolution_id"
              )
            end
            unit = @indexes.fetch("work_units", {})[attempt["work_unit_id"]]
            unless unit &&
                   record["project_id"] == attempt["project_id"] &&
                   record["project_id"] == unit["project_id"] &&
                   record["task_id"] == attempt["task_id"] &&
                   record["task_id"] == unit["task_id"] &&
                   record["task_revision_id"] == attempt["task_revision_id"] &&
                   record["task_revision_id"] == unit["task_revision_id"] &&
                   record["work_unit_id"] == attempt["work_unit_id"] &&
                   record["work_unit_id"] == unit["work_unit_id"]
              add(
                "evidence_record_invalid",
                "EvidenceRecord must share exact project/task/revision/WorkUnit identity with its Attempt",
                path
              )
            end
            unless record["accepted"] == true
              add("evidence_record_invalid", "authoritative EvidenceRecord must be accepted at create time", "#{path}.accepted")
            end
            acceptance_recorded_at = begin
              Time.iso8601(record["acceptance_recorded_at"])
            rescue ArgumentError, TypeError
              add(
                "evidence_record_invalid",
                "EvidenceRecord acceptance_recorded_at must be an ISO-8601 timestamp",
                "#{path}.acceptance_recorded_at"
              )
              nil
            end
            attempt_started_at = begin
              Time.iso8601(attempt.dig("events", 0, "started_at"))
            rescue ArgumentError, TypeError
              nil
            end
            if acceptance_recorded_at &&
               attempt_started_at &&
               acceptance_recorded_at < attempt_started_at
              add(
                "evidence_chronology_invalid",
                "EvidenceRecord acceptance cannot precede its Attempt start",
                "#{path}.acceptance_recorded_at"
              )
            end
            task = tasks[record["task_revision_id"]]
            task_policy_ref = task && task["project_policy_revision_ref"]
            if active_policy &&
               task_policy_ref&.dig("policy_revision_id") != active_policy["policy_revision_id"] &&
               !historical_evidence_before_policy_replacement?(
                 record,
                 attempt,
                 task_policy_ref
               )
              add(
                "evidence_authority_stale",
                "accepted evidence cannot be created at or after replacement of its TaskRevision policy",
                path
              )
            end
            if record["record_kind"] == "evaluator_submission"
              FORBIDDEN_EVALUATOR_EVIDENCE_FACTS.each do |field|
                if record.key?(field)
                  add(
                    "forbidden_second_fact_source",
                    "evaluator EvidenceRecord cannot own #{field}",
                    "#{path}.#{field}"
                  )
                end
              end
            elsif record["record_kind"] != "implementation"
              add("evidence_record_invalid", "record_kind is unsupported", "#{path}.record_kind")
            end
            if %w[implementation evaluator_submission].include?(record["record_kind"])
              @errors.concat(
                EvidenceContract.validate(
                  record: record,
                  work_unit: unit,
                  task_revision: task,
                  assignment: assignment,
                  code_surface: bundle["code_surface"]
                )
              )
            end
            validate_supersedes(
              record,
              "supersedes_evidence_record_id",
              @graphs.fetch("evidence_records"),
              "evidence_record_id",
              path,
              same_scope: %w[project_id task_id task_revision_id work_unit_id record_kind]
            )
            validate_related_refs(
              record,
              "related_evidence_record_refs",
              @graphs.fetch("evidence_records"),
              "evidence_record_id",
              path
            ) do |left, right|
              %w[project_id task_id task_revision_id].all? do |field|
                left[field] == right[field]
              end
            end
          end
          validate_supersedes_cycles(
            @graphs.fetch("evidence_records"),
            "supersedes_evidence_record_id",
            "evidence_record_id",
            "evidence_records"
          )
        end

        def validate_gate_evaluations(bundle, active_policy)
          tasks = @indexes.fetch("task_revisions", {})
          requirements = @indexes.fetch("gate_requirements", {})
          attempts = Array(bundle["work_unit_attempts"])
          records = Array(bundle["evidence_records"])
          units = Array(bundle["work_units"])
          Array(bundle["gate_evaluations"]).each do |evaluation|
            next unless evaluation.is_a?(Hash)

            path = "gate_evaluations.#{evaluation["gate_evaluation_id"]}"
            if evaluation.key?("work_unit_id")
              add("forbidden_second_fact_source", "GateEvaluation work_unit_id cannot overload evaluator and subject", "#{path}.work_unit_id")
            end
            requirement = requirements[evaluation["gate_requirement_id"]]
            task = tasks[evaluation.dig("subject", "task_revision_ref", "task_revision_id")]
            unless requirement && task && task["task_revision_id"] == requirement["task_revision_id"]
              add("reference_not_found", "GateEvaluation requirement/task subject does not exist", path)
              next
            end
            unless evaluation["gate_requirement_content_digest"] == requirement["content_digest"]
              add("subject_stale", "GateEvaluation pins a stale GateRequirement digest", "#{path}.gate_requirement_content_digest")
            end
            evaluator_attempt = @indexes["work_unit_attempts"][evaluation["evaluator_attempt_id"]]
            submission = @indexes["evidence_records"][evaluation["evaluator_submission_record_id"]]
            unless evaluator_attempt && submission &&
                   submission["attempt_id"] == evaluator_attempt["attempt_id"] &&
                   submission["record_kind"] == "evaluator_submission"
              add("gate_evaluation_invalid", "evaluator provenance must bind one Attempt and submission record", path)
              next
            end
            validate_evaluator_binding(
              evaluation,
              requirement,
              evaluator_attempt,
              submission,
              path
            )
            expected = nil
            check("#{path}.subject") do
              expected = EvaluationSubject.select(
                gate_requirement: requirement,
                task_revision: task,
                work_units: units,
                attempts: attempts,
                evidence_records: records,
                repository_snapshot: bundle["repository_snapshot"],
                code_surface: bundle["code_surface"]
              )
            end
            if expected && !EvaluationSubject.same?(expected, evaluation["subject"])
              actual = evaluation["subject"]
              code = subject_shape_complete?(actual) ? "subject_stale" : "subject_incomplete"
              add(code, "GateEvaluation subject is not the current canonical selector result", "#{path}.subject")
            end
            if expected
              evaluator_agent_id = evaluator_attempt.fetch("events").first
                                                    .fetch("assignment")
                                                    .fetch("agent_instance_id")
              evaluator_identity =
                runtime_identity_key_for_agent_id(evaluator_agent_id)
              producers = EvaluationSubject.producer_runtime_identities(
                expected,
                attempts,
                records,
                @indexes.fetch("agent_instances", {}).values
              )
              if requirement["independence"] == "independent_evaluator" &&
                 evaluator_identity &&
                 producers.include?(evaluator_identity)
                add(
                  "independence_violation",
                  "evaluator runtime identity overlaps at least one subject producer",
                  "#{path}.evaluator_attempt_id"
                )
              end
            end
            validate_evaluation_answers(evaluation, requirement, task, path)
            validate_evaluation_answer_evidence(evaluation, path)
            validate_evaluation_quality_outcome(evaluation, path)
            validate_evaluation_coverage(evaluation, path)
            validate_supersedes(
              evaluation,
              "supersedes_gate_evaluation_id",
              @graphs.fetch("gate_evaluations"),
              "gate_evaluation_id",
              path,
              same_scope: %w[project_id],
              compatible: method(:gate_evaluation_lineage_compatible?)
            )
            validate_related_refs(
              evaluation,
              "related_gate_evaluation_refs",
              @graphs.fetch("gate_evaluations"),
              "gate_evaluation_id",
              path,
              &method(:gate_evaluation_lineage_compatible?)
            )
            policy_id = task.dig("project_policy_revision_ref", "policy_revision_id")
            if active_policy && policy_id != active_policy["policy_revision_id"]
              add("subject_stale", "GateEvaluation TaskRevision is governed by a stale policy", "#{path}.subject.task_revision_ref")
            end
          end
          validate_supersedes_cycles(
            @graphs.fetch("gate_evaluations"),
            "supersedes_gate_evaluation_id",
            "gate_evaluation_id",
            "gate_evaluations"
          )
        end

        def validate_evaluation_answers(evaluation, requirement, task, path)
          question_ids = Array(evaluation["quality_question_answers"]).map { |answer| answer["question_id"] }
          acceptance_ids = Array(evaluation["acceptance_results"]).map { |answer| answer["acceptance_id"] }
          unless question_ids.sort == Array(requirement["required_question_refs"]).sort &&
                 question_ids.uniq.length == question_ids.length
            add("gate_evaluation_invalid", "quality answers must exactly cover required stable question IDs", "#{path}.quality_question_answers")
          end
          unless acceptance_ids.sort == Array(requirement["acceptance_refs"]).sort &&
                 acceptance_ids.uniq.length == acceptance_ids.length
            add("gate_evaluation_invalid", "acceptance results must exactly cover required stable acceptance IDs", "#{path}.acceptance_results")
          end
          known_acceptance = Array(task["acceptance"]).map { |entry| entry["acceptance_id"] }
          add("gate_evaluation_invalid", "acceptance result references unknown TaskRevision ID", "#{path}.acceptance_results") unless subset?(acceptance_ids, known_acceptance)
          subject_unit_ids = Array(evaluation.dig("subject", "work_unit_refs")).map do |ref|
            ref["work_unit_id"]
          end
          selected_acceptance_ids = subject_unit_ids.flat_map do |unit_id|
            Array(@indexes.fetch("work_units", {}).dig(unit_id, "acceptance_refs"))
          end.uniq
          unless subset?(acceptance_ids, selected_acceptance_ids)
            add(
              "gate_evaluation_invalid",
              "acceptance results exceed the subject WorkUnits' acceptance refs",
              "#{path}.acceptance_results"
            )
          end
        end

        def validate_evaluator_binding(evaluation, requirement, attempt, submission, path)
          assignment = attempt.fetch("events").first.fetch("assignment")
          binding = GATE_EVALUATOR_BINDINGS[requirement["kind"]]
          unit = @indexes.fetch("work_units", {})[attempt["work_unit_id"]]
          agent = @indexes.fetch("agent_instances", {})[assignment["agent_instance_id"]]
          unless binding &&
                 assignment["purpose"] == binding["purpose"] &&
                 assignment["resolved_role"] == binding["resolved_role"] &&
                 assignment_binding_valid?(assignment, unit, agent)
            add(
              "gate_evaluator_binding_invalid",
              "#{requirement["kind"]} gate requires the exact purpose/role/capability/" \
                "permission/context/action binding declared by the AgentInstance and WorkUnit",
              "#{path}.evaluator_attempt_id"
            )
          end
          unless unit &&
                 unit["work_unit_kind"] == "evaluation" &&
                 attempt["task_id"] == requirement["task_id"] &&
                 attempt["task_revision_id"] == requirement["task_revision_id"] &&
                 unit["task_id"] == requirement["task_id"] &&
                 unit["task_revision_id"] == requirement["task_revision_id"] &&
                 submission["task_id"] == requirement["task_id"] &&
                 submission["task_revision_id"] == requirement["task_revision_id"] &&
                 submission["work_unit_id"] == unit["work_unit_id"]
            add(
              "gate_evaluator_binding_invalid",
              "cross-task evaluation is unsupported; evaluator WorkUnit, Attempt, and submission " \
                "must belong to the GateRequirement task revision",
              "#{path}.evaluator_attempt_id"
            )
          end
        end

        def validate_evaluation_quality_outcome(evaluation, path)
          return unless evaluation["verdict"] == "pass"

          answer_verdicts = (
            Array(evaluation["quality_question_answers"]) +
            Array(evaluation["acceptance_results"])
          ).map { |answer| answer["verdict"] }
          unless evaluation["quality_outcome_verdict"] == "pass" &&
                 answer_verdicts.all? { |verdict| verdict == "pass" } &&
                 Array(evaluation["missing"]).empty?
            add(
              "gate_evaluation_invalid",
              "passing GateEvaluation requires passing quality outcome/answers and no missing evidence",
              path
            )
          end
        end

        def validate_evaluation_coverage(evaluation, path)
          coverage = evaluation["coverage"]
          return unless coverage.is_a?(Hash)

          subject_units = Array(evaluation.dig("subject", "work_unit_refs")).map do |ref|
            ref["work_unit_id"]
          end
          covered = Array(coverage["covered_work_unit_refs"])
          uncovered = Array(coverage["uncovered_work_unit_refs"])
          subject_evidence = Array(evaluation.dig("subject", "evidence_record_refs")).map do |ref|
            ref["evidence_record_id"]
          end
          unless (covered + uncovered).sort == subject_units.sort &&
                 (covered & uncovered).empty? &&
                 subset?(coverage["evidence_record_refs"], subject_evidence)
            add(
              "gate_evaluation_invalid",
              "coverage must partition subject WorkUnits and cite only subject EvidenceRecords",
              "#{path}.coverage"
            )
          end
          if evaluation["verdict"] == "pass" && !uncovered.empty?
            add(
              "gate_evaluation_invalid",
              "passing GateEvaluation cannot leave subject WorkUnits uncovered",
              "#{path}.coverage.uncovered_work_unit_refs"
            )
          end
        end

        def validate_evaluation_answer_evidence(evaluation, path)
          subject_record_ids = Array(evaluation.dig("subject", "evidence_record_refs")).map do |ref|
            ref["evidence_record_id"]
          end
          answers = Array(evaluation["quality_question_answers"]) + Array(evaluation["acceptance_results"])
          answer_record_ids = answers.flat_map { |answer| Array(answer["evidence_record_refs"]) }
          unless answer_record_ids.all? { |id| subject_record_ids.include?(id) }
            add(
              "gate_evaluation_invalid",
              "answers may cite only immutable EvidenceRecords pinned by the canonical subject",
              path
            )
          end
          if evaluation["verdict"] == "pass" &&
             answers.any? { |answer| Array(answer["evidence_record_refs"]).empty? }
            add(
              "gate_evaluation_invalid",
              "every passing quality and acceptance answer requires immutable subject evidence",
              path
            )
          end
        end

        def gate_evaluation_lineage_compatible?(left, right)
          left_requirement =
            @indexes.fetch("gate_requirements", {})[left["gate_requirement_id"]]
          right_requirement =
            @indexes.fetch("gate_requirements", {})[right["gate_requirement_id"]]
          left_requirement &&
            right_requirement &&
            left["project_id"] == right["project_id"] &&
            left_requirement["task_id"] == right_requirement["task_id"] &&
            left_requirement["gate_lineage_id"] == right_requirement["gate_lineage_id"] &&
            (
              left_requirement["gate_requirement_id"] ==
                right_requirement["gate_requirement_id"] ||
              gate_requirement_descends_from?(
                left_requirement,
                right_requirement["gate_requirement_id"]
              ) ||
              gate_requirement_descends_from?(
                right_requirement,
                left_requirement["gate_requirement_id"]
              )
            )
        end

        def evaluation_subject_lineage(evaluation)
          return nil unless evaluation.is_a?(Hash)

          subject = evaluation["subject"]
          return nil unless subject.is_a?(Hash)

          [
            subject.dig("task_revision_ref", "task_revision_id"),
            Array(subject["work_unit_refs"]).map { |ref| ref["work_unit_id"] }.sort
          ]
        end

        def gate_evaluation_descends_from?(evaluation, ancestor_evaluation_id)
          seen = Set.new
          cursor = evaluation
          while cursor && seen.add?(cursor["gate_evaluation_id"])
            parent_id = cursor["supersedes_gate_evaluation_id"]
            return true if parent_id == ancestor_evaluation_id

            cursor = parent_id &&
              @indexes.fetch("gate_evaluations", {})[parent_id]
          end
          false
        end
      end

      include EvidenceEvaluation
      private_constant :EvidenceEvaluation
    end
  end
end
