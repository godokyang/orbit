# frozen_string_literal: true

require_relative "aggregate_outcome"
require_relative "canonical_json"
require_relative "errors"
require_relative "evaluation_subject"
require_relative "projection_primitives"

module Orbit
  module V2
    # Slice 5 increment 2: the three responsibility-scoped context
    # projections.
    #
    # Pure derived seams over validated authoritative facts: lead(...),
    # work_agent(...), and evaluator(...) each read the bundle, write nothing,
    # and are not authoritative collections or schemas. The role is chosen by
    # the seam, never by a label: lead resolves a control registry, and the
    # attempt seams resolve one exact WorkUnitAttempt whose immutable
    # assignment purpose matches the role (implementation/research for
    # work_agent; review/test/release/adjudication for evaluator).
    #
    # Every projection shares the AggregateOutcome validated-input boundary
    # (including its exact historical `.subject` staleness allowance), so
    # invalid authority/independence, wrong-purpose refs, non-exact
    # assignment/rules/checkpoint pins, and ambiguous control tips fail
    # closed. Historical stale GateEvaluations stay stored but are marked
    # stale in the lead/evaluator gate refs and never participate in current
    # context.
    #
    # Each output is canonical and order-independent:
    # schema_version/protocol_epoch/project_id/context_kind, an exact subject
    # ref, role-scoped sections, a sorted source_manifest of exactly the
    # authoritative sources the role projection exposes (once each),
    # source_digest, and content_digest. Unrelated bundle changes never
    # perturb the narrower work_agent/evaluator projections.
    module ContextProjection
      module_function

      SCHEMA_VERSION = "orbit-context-projection-v1"
      PROTOCOL_EPOCH = "orbit-v2"
      WORK_AGENT_PURPOSES = %w[implementation research].freeze
      EVALUATOR_PURPOSES = %w[review test release adjudication].freeze
      TERMINAL_ATTEMPT_EVENTS = %w[
        AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled AttemptSuperseded
      ].freeze

      def lead(bundle, lead_control_id, validator:)
        project(bundle, validator: validator, context_kind: "lead") do
          build_lead(bundle, lead_control_id, validator)
        end
      end

      def work_agent(bundle, attempt_id, validator:)
        project(bundle, validator: validator, context_kind: "work_agent") do
          build_work_agent(bundle, attempt_id)
        end
      end

      def evaluator(bundle, attempt_id, validator:)
        project(bundle, validator: validator, context_kind: "evaluator") do
          build_evaluator(bundle, attempt_id)
        end
      end

      def project(bundle, validator:, context_kind:)
        AggregateOutcome.validate_projection_input!(
          bundle,
          validator: validator,
          seam: "context projection"
        )
        document, sources = yield
        finalize(document, sources)
      rescue KeyError, TypeError, ArgumentError => e
        raise ContractError.new("context_projection_invalid", e.message)
      end
      private_class_method :project

      def finalize(document, sources)
        manifest = sources.uniq { |entry| [entry["kind"], entry["id"]] }
                            .sort_by { |entry| [entry["kind"], entry["id"]] }
        document["source_manifest"] = manifest
        document["source_digest"] = "sha256:#{CanonicalJSON.sha256(manifest)}"
        document["content_digest"] = CanonicalJSON.digest_excluding(document, "content_digest")
        document
      end
      private_class_method :finalize

      def build_lead(bundle, lead_control_id, validator)
        project_id = bundle.fetch("protocol_root").fetch("project_id")
        registries = index(bundle, "control_registries", "lead_control_id")
        registry = registries[lead_control_id]
        unless registry.is_a?(Hash)
          raise ContractError.new(
            "context_projection_invalid",
            "lead control registry does not exist",
            path: "control_registries"
          )
        end
        unless registry["project_id"] == project_id
          raise ContractError.new(
            "context_projection_invalid",
            "lead control registry belongs to another project",
            path: "control_registries.#{lead_control_id}"
          )
        end

        checkpoints = Array(bundle["lead_checkpoints"]).select do |checkpoint|
          checkpoint.is_a?(Hash) && checkpoint["lead_control_id"] == lead_control_id
        end
        tip = resolve_unique_tip(checkpoints)

        tasks = index(bundle, "task_revisions", "task_revision_id")
        active_task_ref = tip["active_task_ref"]
        unless active_task_ref.is_a?(Hash)
          raise ContractError.new(
            "context_projection_invalid",
            "accepted checkpoint tip has no exact active task ref",
            path: "lead_checkpoints.#{tip["lead_checkpoint_id"]}.active_task_ref"
          )
        end
        task = tasks[active_task_ref["task_revision_id"]]
        unless task.is_a?(Hash) && task["content_digest"] == active_task_ref["content_digest"]
          raise ContractError.new(
            "context_projection_invalid",
            "accepted checkpoint tip active task ref does not resolve exactly",
            path: "lead_checkpoints.#{tip["lead_checkpoint_id"]}.active_task_ref"
          )
        end
        unless task["project_id"] == project_id
          raise ContractError.new(
            "context_projection_invalid",
            "active task belongs to another project",
            path: "task_revisions.#{task["task_revision_id"]}"
          )
        end

        policies = index(bundle, "project_policy_revisions", "policy_revision_id")
        policy = resolve_exact_ref(
          task["project_policy_revision_ref"],
          policies,
          id_key: "policy_revision_id",
          path: "task_revisions.#{task["task_revision_id"]}.project_policy_revision_ref",
          label: "active project policy revision"
        )

        requirement_ids = Array(task["gate_requirement_refs"])
        requirements = index(bundle, "gate_requirements", "gate_requirement_id")
        task_requirements = requirement_ids.map do |id|
          requirement = requirements[id]
          unless requirement.is_a?(Hash)
            raise ContractError.new(
              "context_projection_invalid",
              "TaskRevision gate requirement ref does not resolve",
              path: "task_revisions.#{task["task_revision_id"]}.gate_requirement_refs"
            )
          end
          requirement
        end

        units = Array(bundle["work_units"]).select do |unit|
          unit.is_a?(Hash) &&
            unit["task_id"] == task["task_id"] &&
            unit["task_revision_id"] == task["task_revision_id"]
        end
        attempts = Array(bundle["work_unit_attempts"]).select do |attempt|
          attempt.is_a?(Hash) &&
            attempt["task_id"] == task["task_id"] &&
            attempt["task_revision_id"] == task["task_revision_id"]
        end
        evaluations = Array(bundle["gate_evaluations"]).select do |evaluation|
          evaluation.is_a?(Hash) && requirement_ids.include?(evaluation["gate_requirement_id"])
        end

        findings = relevant_findings(
          bundle,
          task,
          index(bundle, "findings", "finding_id"),
          index(bundle, "gate_evaluations", "gate_evaluation_id"),
          requirements,
          tasks
        )
        finding_ids = findings.map { |finding| finding["finding_id"] }
        resolutions = Array(bundle["finding_resolutions"]).select do |resolution|
          resolution.is_a?(Hash) && finding_ids.include?(resolution["finding_id"])
        end

        all_units = Array(bundle["work_units"])
        all_attempts = Array(bundle["work_unit_attempts"])
        all_records = Array(bundle["evidence_records"])
        snapshot = bundle["repository_snapshot"]
        code_surface = bundle["code_surface"]
        gate_evaluation_refs = evaluations.map do |evaluation|
          requirement = requirements[evaluation["gate_requirement_id"]]
          expected = EvaluationSubject.select(
            gate_requirement: requirement,
            task_revision: task,
            work_units: all_units,
            attempts: all_attempts,
            evidence_records: all_records,
            repository_snapshot: snapshot,
            code_surface: code_surface
          )
          {
            "gate_evaluation_id" => evaluation["gate_evaluation_id"],
            "content_digest" => evaluation["content_digest"],
            "current" => ProjectionPrimitives.evaluation_current?(
              evaluation,
              requirement: requirement,
              expected_subject: expected
            )
          }
        end.sort_by { |ref| ref["gate_evaluation_id"] }

        document = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => project_id,
          "context_kind" => "lead",
          "subject_ref" => {
            "lead_control_id" => registry["lead_control_id"],
            "content_digest" => registry["content_digest"]
          },
          "control_registry" => registry,
          "active_checkpoint_ref" => {
            "lead_checkpoint_id" => tip["lead_checkpoint_id"],
            "content_digest" => tip["content_digest"]
          },
          "task_queue" => Array(tip["task_queue"]),
          "active_task_ref" => tip["active_task_ref"],
          "selected_work_unit_ref" => tip["selected_work_unit_ref"],
          "current_or_terminal_attempt_ref" => tip["current_or_terminal_attempt_ref"],
          "project_policy_revision" => policy,
          "task_revision" => task,
          "work_units" => units.sort_by { |unit| unit["work_unit_id"] },
          "work_unit_attempts" => attempts.sort_by { |attempt| attempt["attempt_id"] },
          "attempt_status" => attempts.map { |attempt| attempt_status(attempt) }
                                       .sort_by { |entry| entry["attempt_id"] },
          "gate_requirement_refs" => task_requirements.map do |requirement|
            {
              "gate_requirement_id" => requirement["gate_requirement_id"],
              "content_digest" => requirement["content_digest"]
            }
          end.sort_by { |ref| ref["gate_requirement_id"] },
          "gate_evaluation_refs" => gate_evaluation_refs,
          "finding_refs" => findings.map do |finding|
            {
              "finding_id" => finding["finding_id"],
              "content_digest" => finding["content_digest"]
            }
          end.sort_by { |ref| ref["finding_id"] },
          "finding_resolution_refs" => resolutions.map do |resolution|
            {
              "finding_resolution_id" => resolution["finding_resolution_id"],
              "content_digest" => resolution["content_digest"]
            }
          end.sort_by { |ref| ref["finding_resolution_id"] },
          "aggregate_outcome" => AggregateOutcome.derive(
            bundle,
            task["task_revision_id"],
            validator: validator
          )
        }
        sources = [registry, tip, policy, task]
        sources.concat(task_requirements)
        sources.concat(units)
        sources.concat(attempts)
        sources.concat(evaluations)
        sources.concat(findings)
        sources.concat(resolutions)
        entries = sources.map do |source|
          kind = source_kind(source)
          ProjectionPrimitives.manifest_entry(
            kind,
            source_id(source, kind),
            ProjectionPrimitives.source_digest(source)
          )
        end
        # The embedded AggregateOutcome is part of the lead context, so its
        # complete transitive source manifest joins the lead manifest
        # (canonical union; finalize dedupes by kind+id). A bundle change
        # that alters the outcome therefore alters the lead source_digest.
        entries.concat(Array(document.fetch("aggregate_outcome").fetch("source_manifest")))
        [document, entries]
      end
      private_class_method :build_lead

      def build_work_agent(bundle, attempt_id)
        attempt, assignment, unit, task, policy, artifact, thesis, checkpoint =
          resolve_attempt_context(bundle, attempt_id, WORK_AGENT_PURPOSES)
        plan = checkpoint["effective_verification_plan_digest"]
        basis = checkpoint["closure_basis_digest"]
        unless plan.is_a?(String) && basis.is_a?(String)
          raise ContractError.new(
            "context_projection_invalid",
            "dispatch checkpoint must pin effective plan and closure basis digests",
            path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
          )
        end

        acceptance = Array(task["acceptance"]).select do |entry|
          Array(unit["acceptance_refs"]).include?(entry["acceptance_id"])
        end
        evidence_requirements = Array(task["evidence_requirements"]).select do |entry|
          Array(unit["evidence_requirement_refs"]).include?(entry["evidence_requirement_id"])
        end
        source_requirements = Array(task["source_requirements"]).select do |entry|
          Array(unit["source_requirement_refs"]).include?(entry["source_requirement_id"])
        end

        units = index(bundle, "work_units", "work_unit_id")
        related_ids = Array(unit["depends_on_work_unit_refs"]) + [unit["parent_work_unit_ref"]].compact
        related_units = related_ids.map do |id|
          related = units[id]
          unless related.is_a?(Hash)
            raise ContractError.new(
              "context_projection_invalid",
              "WorkUnit parent/dependency ref does not resolve",
              path: "work_units.#{unit["work_unit_id"]}"
            )
          end
          related
        end

        document = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => attempt["project_id"],
          "context_kind" => "work_agent",
          "subject_ref" => attempt_ref(attempt),
          "task_revision_ref" => {
            "task_revision_id" => task["task_revision_id"],
            "content_digest" => task["content_digest"]
          },
          "task_contract" => {
            "acceptance" => acceptance,
            "evidence_requirements" => evidence_requirements,
            "source_requirements" => source_requirements
          },
          "work_unit" => unit,
          "parent_work_unit_ref" => unit["parent_work_unit_ref"],
          "depends_on_work_unit_refs" => Array(unit["depends_on_work_unit_refs"]),
          "related_work_unit_refs" => related_units.map do |related|
            {
              "work_unit_id" => related["work_unit_id"],
              "content_digest" => related["content_digest"]
            }
          end.sort_by { |ref| ref["work_unit_id"] },
          "assignment" => assignment,
          "assigned_rule_resolution" => artifact,
          "change_thesis_ref" => assignment["change_thesis_ref"],
          "dispatch_checkpoint_ref" => attempt["dispatch_lead_checkpoint_ref"],
          "effective_verification_plan_digest" => plan,
          "closure_basis_digest" => basis,
          "plan_basis_source_refs" => {
            "project_policy_revision_ref" => checkpoint["project_policy_revision_ref"],
            "active_task_ref" => checkpoint["active_task_ref"],
            "selected_work_unit_ref" => checkpoint["selected_work_unit_ref"],
            "current_or_terminal_attempt_ref" => checkpoint["current_or_terminal_attempt_ref"],
            "supporting_refs" => Array(checkpoint.dig("delivery_progress", "supporting_refs"))
          }
        }
        sources = [attempt, unit, task, policy, artifact, thesis, checkpoint]
        sources.concat(related_units)
        [
          document,
          sources.map do |source|
            kind = source_kind(source)
            ProjectionPrimitives.manifest_entry(kind, source_id(source, kind), ProjectionPrimitives.source_digest(source))
          end
        ]
      end
      private_class_method :build_work_agent

      def build_evaluator(bundle, attempt_id)
        attempt, assignment, unit, task, policy, artifact, thesis, checkpoint =
          resolve_attempt_context(bundle, attempt_id, EVALUATOR_PURPOSES)
        plan = checkpoint["effective_verification_plan_digest"]
        basis = checkpoint["closure_basis_digest"]
        unless plan.is_a?(String) && basis.is_a?(String)
          raise ContractError.new(
            "context_projection_invalid",
            "dispatch checkpoint must pin effective plan and closure basis digests",
            path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
          )
        end

        requirements = index(bundle, "gate_requirements", "gate_requirement_id")
        task_requirements = Array(task["gate_requirement_refs"]).map do |id|
          requirement = requirements[id]
          unless requirement.is_a?(Hash)
            raise ContractError.new(
              "context_projection_invalid",
              "TaskRevision gate requirement ref does not resolve",
              path: "task_revisions.#{task["task_revision_id"]}.gate_requirement_refs"
            )
          end
          requirement
        end

        # The evaluator role is bound to the gate kinds its immutable
        # assignment purpose authorizes: GATE_EVALUATOR_BINDINGS maps each
        # GateRequirement kind exactly to one purpose (review->review,
        # test->test, release->release, adjudication->adjudication). Only
        # those requirements are applicable; every other TaskRevision gate
        # subject/criteria/ref stays out of this evaluator projection.
        applicable_requirements = task_requirements.select do |requirement|
          requirement["kind"] == assignment["purpose"]
        end
        applicable_ids = applicable_requirements.map do |requirement|
          requirement["gate_requirement_id"]
        end

        all_units = Array(bundle["work_units"])
        all_attempts = Array(bundle["work_unit_attempts"])
        all_records = Array(bundle["evidence_records"])
        snapshot = bundle["repository_snapshot"]
        code_surface = bundle["code_surface"]
        subjects = applicable_requirements.sort_by do |requirement|
          requirement["gate_requirement_id"]
        end.map do |requirement|
          {
            "gate_requirement_ref" => {
              "gate_requirement_id" => requirement["gate_requirement_id"],
              "content_digest" => requirement["content_digest"]
            },
            "subject" => EvaluationSubject.select(
              gate_requirement: requirement,
              task_revision: task,
              work_units: all_units,
              attempts: all_attempts,
              evidence_records: all_records,
              repository_snapshot: snapshot,
              code_surface: code_surface
            )
          }
        end
        criteria = applicable_requirements.sort_by do |requirement|
          requirement["gate_requirement_id"]
        end.map do |requirement|
          {
            "gate_requirement_ref" => {
              "gate_requirement_id" => requirement["gate_requirement_id"],
              "content_digest" => requirement["content_digest"]
            },
            "questions" => Array(task["task_questions"]).select do |question|
              Array(requirement["required_question_refs"]).include?(question["question_id"])
            end,
            "acceptance" => Array(task["acceptance"]).select do |entry|
              Array(requirement["acceptance_refs"]).include?(entry["acceptance_id"])
            end
          }
        end

        evaluations = Array(bundle["gate_evaluations"]).select do |evaluation|
          evaluation.is_a?(Hash) && applicable_ids.include?(evaluation["gate_requirement_id"])
        end
        gate_evaluation_refs = evaluations.map do |evaluation|
          requirement = requirements[evaluation["gate_requirement_id"]]
          expected = EvaluationSubject.select(
            gate_requirement: requirement,
            task_revision: task,
            work_units: all_units,
            attempts: all_attempts,
            evidence_records: all_records,
            repository_snapshot: snapshot,
            code_surface: code_surface
          )
          {
            "gate_evaluation_id" => evaluation["gate_evaluation_id"],
            "content_digest" => evaluation["content_digest"],
            "current" => ProjectionPrimitives.evaluation_current?(
              evaluation,
              requirement: requirement,
              expected_subject: expected
            )
          }
        end.sort_by { |ref| ref["gate_evaluation_id"] }

        evaluations_index = index(bundle, "gate_evaluations", "gate_evaluation_id")
        tasks_index = index(bundle, "task_revisions", "task_revision_id")
        findings = relevant_findings(
          bundle,
          task,
          index(bundle, "findings", "finding_id"),
          evaluations_index,
          requirements,
          tasks_index
        ).select do |finding|
          lineage = ProjectionPrimitives.finding_lineage(
            finding,
            evaluations: evaluations_index,
            requirements: requirements,
            tasks: tasks_index
          )
          lineage && applicable_ids.include?(lineage["gate_requirement_id"])
        end
        finding_ids = findings.map { |finding| finding["finding_id"] }
        resolutions = Array(bundle["finding_resolutions"]).select do |resolution|
          resolution.is_a?(Hash) && finding_ids.include?(resolution["finding_id"])
        end

        subject_unit_ids = subjects.flat_map do |entry|
          Array(entry.dig("subject", "work_unit_refs")).map { |ref| ref["work_unit_id"] }
        end.uniq
        subject_attempt_ids = subjects.flat_map do |entry|
          Array(entry.dig("subject", "implementation_attempt_refs")).map { |ref| ref["attempt_id"] }
        end.uniq
        subject_record_ids = subjects.flat_map do |entry|
          Array(entry.dig("subject", "evidence_record_refs")).map { |ref| ref["evidence_record_id"] }
        end.uniq
        units = index(bundle, "work_units", "work_unit_id")
        attempts = index(bundle, "work_unit_attempts", "attempt_id")
        records = index(bundle, "evidence_records", "evidence_record_id")

        document = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => attempt["project_id"],
          "context_kind" => "evaluator",
          "subject_ref" => attempt_ref(attempt),
          "task_revision" => task,
          "assignment" => assignment,
          "assigned_rule_resolution" => artifact,
          "subjects" => subjects,
          "evaluation_criteria" => criteria,
          "gate_evaluation_refs" => gate_evaluation_refs,
          "findings" => findings.sort_by { |finding| finding["finding_id"] },
          "finding_resolutions" => resolutions.sort_by do |resolution|
            resolution["finding_resolution_id"]
          end,
          "dispatch_checkpoint_ref" => attempt["dispatch_lead_checkpoint_ref"],
          "effective_verification_plan_digest" => plan,
          "closure_basis_digest" => basis,
          "plan_basis_source_refs" => {
            "project_policy_revision_ref" => checkpoint["project_policy_revision_ref"],
            "active_task_ref" => checkpoint["active_task_ref"],
            "selected_work_unit_ref" => checkpoint["selected_work_unit_ref"],
            "current_or_terminal_attempt_ref" => checkpoint["current_or_terminal_attempt_ref"],
            "supporting_refs" => Array(checkpoint.dig("delivery_progress", "supporting_refs"))
          }
        }
        sources = [attempt, task, policy, artifact, thesis, checkpoint]
        sources.concat(applicable_requirements)
        sources.concat(findings)
        sources.concat(resolutions)
        sources.concat(evaluations)
        subject_unit_ids.each { |id| sources << units[id] }
        subject_attempt_ids.each { |id| sources << attempts[id] }
        subject_record_ids.each { |id| sources << records[id] }
        sources << snapshot if snapshot.is_a?(Hash)
        sources << code_surface if code_surface.is_a?(Hash)
        [
          document,
          sources.map do |source|
            kind = source_kind(source)
            ProjectionPrimitives.manifest_entry(kind, source_id(source, kind), ProjectionPrimitives.source_digest(source))
          end
        ]
      end
      private_class_method :build_evaluator

      def resolve_attempt_context(bundle, attempt_id, allowed_purposes)
        project_id = bundle.fetch("protocol_root").fetch("project_id")
        attempts = index(bundle, "work_unit_attempts", "attempt_id")
        attempt = attempts[attempt_id]
        unless attempt.is_a?(Hash)
          raise ContractError.new(
            "context_projection_invalid",
            "work unit attempt does not exist",
            path: "work_unit_attempts"
          )
        end
        unless attempt["project_id"] == project_id
          raise ContractError.new(
            "context_projection_invalid",
            "work unit attempt belongs to another project",
            path: "work_unit_attempts.#{attempt_id}"
          )
        end
        assignment = attempt.fetch("events").first.fetch("assignment")
        unless allowed_purposes.include?(assignment["purpose"])
          raise ContractError.new(
            "context_projection_invalid",
            "attempt purpose #{assignment["purpose"].inspect} is not valid for this context seam",
            path: "work_unit_attempts.#{attempt_id}.events"
          )
        end

        units = index(bundle, "work_units", "work_unit_id")
        unit = units[attempt["work_unit_id"]]
        unless unit.is_a?(Hash) &&
               unit["task_id"] == attempt["task_id"] &&
               unit["task_revision_id"] == attempt["task_revision_id"]
          raise ContractError.new(
            "context_projection_invalid",
            "attempt WorkUnit does not resolve to the exact attempt task revision",
            path: "work_units.#{attempt["work_unit_id"]}"
          )
        end
        tasks = index(bundle, "task_revisions", "task_revision_id")
        task = tasks[attempt["task_revision_id"]]
        unless task.is_a?(Hash)
          raise ContractError.new(
            "context_projection_invalid",
            "attempt TaskRevision does not exist",
            path: "task_revisions"
          )
        end
        policies = index(bundle, "project_policy_revisions", "policy_revision_id")
        policy = resolve_exact_ref(
          assignment.dig("authority_snapshot", "project_policy_revision_ref"),
          policies,
          id_key: "policy_revision_id",
          path: "work_unit_attempts.#{attempt_id}.events.assignment.authority_snapshot.project_policy_revision_ref",
          label: "assignment authority policy revision"
        )
        artifacts = index(bundle, "rule_resolution_artifacts", "resolution_id")
        artifact = artifacts[assignment["assigned_rule_resolution_id"]]
        unless artifact.is_a?(Hash)
          raise ContractError.new(
            "context_projection_invalid",
            "assignment rule resolution does not resolve exactly",
            path: "work_unit_attempts.#{attempt_id}.events.assignment.assigned_rule_resolution_id"
          )
        end
        thesis = resolve_change_thesis(bundle, assignment["change_thesis_ref"])
        checkpoint = resolve_dispatch_checkpoint(bundle, attempt["dispatch_lead_checkpoint_ref"])
        [attempt, assignment, unit, task, policy, artifact, thesis, checkpoint]
      end
      private_class_method :resolve_attempt_context

      def resolve_change_thesis(bundle, ref)
        unless ref.is_a?(Hash)
          raise ContractError.new(
            "context_projection_invalid",
            "assignment change thesis ref is missing",
            path: "assignment.change_thesis_ref"
          )
        end
        thesis = Array(bundle["change_theses"]).find do |candidate|
          candidate.is_a?(Hash) &&
            candidate["change_thesis_id"] == ref["change_thesis_id"] &&
            candidate["revision"] == ref["revision"]
        end
        unless thesis.is_a?(Hash) && thesis["content_digest"] == ref["content_digest"]
          raise ContractError.new(
            "context_projection_invalid",
            "assignment change thesis ref does not resolve exactly",
            path: "change_theses"
          )
        end
        thesis
      end
      private_class_method :resolve_change_thesis

      def resolve_dispatch_checkpoint(bundle, ref)
        unless ref.is_a?(Hash)
          raise ContractError.new(
            "context_projection_invalid",
            "attempt dispatch checkpoint ref is missing",
            path: "dispatch_lead_checkpoint_ref"
          )
        end
        checkpoints = index(bundle, "lead_checkpoints", "lead_checkpoint_id")
        checkpoint = checkpoints[ref["lead_checkpoint_id"]]
        unless checkpoint.is_a?(Hash) && checkpoint["content_digest"] == ref["content_digest"]
          raise ContractError.new(
            "context_projection_invalid",
            "attempt dispatch checkpoint ref does not resolve exactly",
            path: "lead_checkpoints"
          )
        end
        checkpoint
      end
      private_class_method :resolve_dispatch_checkpoint

      def resolve_unique_tip(checkpoints)
        analysis = ProjectionPrimitives.supersedes_tips(
          checkpoints.map do |checkpoint|
            {
              "lead_checkpoint_id" => checkpoint["lead_checkpoint_id"],
              "_predecessor" => checkpoint.dig("predecessor_lead_checkpoint_ref", "lead_checkpoint_id"),
              "checkpoint" => checkpoint
            }
          end,
          id_key: "lead_checkpoint_id",
          supersedes_key: "_predecessor"
        )
        case analysis.status
        when :unique
          analysis.tips.first["checkpoint"]
        when :empty
          raise ContractError.new(
            "context_projection_invalid",
            "lead control has no accepted checkpoint",
            path: "lead_checkpoints"
          )
        else
          raise ContractError.new(
            "context_projection_invalid",
            "lead control checkpoint lineage has multiple tips or a fork",
            path: "lead_checkpoints"
          )
        end
      end
      private_class_method :resolve_unique_tip

      def relevant_findings(bundle, task, findings_index, evaluations_index, requirements, tasks)
        lineage_findings = findings_index.values.select do |finding|
          lineage = ProjectionPrimitives.finding_lineage(
            finding,
            evaluations: evaluations_index,
            requirements: requirements,
            tasks: tasks
          )
          lineage && lineage["task_id"] == task["task_id"]
        end
        carried = Array(task["unresolved_finding_refs"]).map do |id|
          finding = findings_index[id]
          unless finding.is_a?(Hash)
            raise ContractError.new(
              "context_projection_invalid",
              "unresolved Finding ref must resolve to an existing Finding",
              path: "task_revisions.#{task["task_revision_id"]}.unresolved_finding_refs"
            )
          end
          finding
        end
        (lineage_findings + carried).uniq { |finding| finding["finding_id"] }
      end
      private_class_method :relevant_findings

      def attempt_status(attempt)
        terminal = Array(attempt["events"]).reverse.find do |event|
          event.is_a?(Hash) && TERMINAL_ATTEMPT_EVENTS.include?(event["event_type"])
        end
        {
          "attempt_id" => attempt["attempt_id"],
          "status" => terminal ? terminal["event_type"] : "active"
        }
      end
      private_class_method :attempt_status

      def attempt_ref(attempt)
        {
          "attempt_id" => attempt["attempt_id"],
          "creation_event_digest" => attempt.fetch("events").first.fetch("event_digest")
        }
      end
      private_class_method :attempt_ref

      def index(bundle, collection, id_field)
        result = {}
        Array(bundle[collection]).each do |document|
          next unless document.is_a?(Hash)

          id = document[id_field]
          next if id.nil?

          if result.key?(id)
            raise ContractError.new(
              "context_projection_invalid",
              "#{collection} contains a duplicate #{id_field} identity",
              path: "#{collection}.#{id}"
            )
          end
          result[id] = document
        end
        result
      end
      private_class_method :index

      def resolve_exact_ref(ref, index, id_key:, path:, label:)
        target = ref.is_a?(Hash) && index[ref[id_key]]
        return target if target.is_a?(Hash) && target["content_digest"] == ref["content_digest"]

        raise ContractError.new(
          "context_projection_invalid",
          "#{label} ref must resolve to an exact existing revision",
          path: path
        )
      end
      private_class_method :resolve_exact_ref

      def source_kind(document)
        case document["schema_version"]
        when "orbit-lead-control-registry-v1"
          "control_registry"
        when "orbit-lead-checkpoint-v1"
          "lead_checkpoint"
        when "orbit-agent-runtime-v1"
          "work_unit_attempt"
        when "orbit-work-unit-v1"
          "work_unit"
        when "orbit-task-v2"
          "task_revision"
        when "orbit-project-policy-v1"
          "project_policy_revision"
        when "orbit-rule-resolution-v2"
          "rule_resolution_artifact"
        when "orbit-change-thesis-v1"
          "change_thesis"
        when "orbit-gate-requirement-v1"
          "gate_requirement"
        when "orbit-gate-evaluation-v1"
          "gate_evaluation"
        when "orbit-finding-v1"
          "finding"
        when "orbit-finding-resolution-v1"
          "finding_resolution"
        when "orbit-evidence-v2"
          "evidence_record"
        else
          if document["kind"] == "git"
            "repository_snapshot"
          elsif document["kind"] == "derived_code_surface"
            "code_surface"
          else
            raise ContractError.new(
              "context_projection_invalid",
              "unknown context source object type",
              path: "source_manifest"
            )
          end
        end
      end
      private_class_method :source_kind

      def source_id(document, kind)
        case kind
        when "control_registry"
          document["lead_control_id"]
        when "lead_checkpoint"
          document["lead_checkpoint_id"]
        when "work_unit_attempt"
          document["attempt_id"]
        when "work_unit"
          document["work_unit_id"]
        when "task_revision"
          document["task_revision_id"]
        when "project_policy_revision"
          document["policy_revision_id"]
        when "rule_resolution_artifact"
          document["resolution_id"]
        when "change_thesis"
          "#{document["change_thesis_id"]}@#{document["revision"]}"
        when "gate_requirement"
          document["gate_requirement_id"]
        when "gate_evaluation"
          document["gate_evaluation_id"]
        when "finding"
          document["finding_id"]
        when "finding_resolution"
          document["finding_resolution_id"]
        when "evidence_record"
          document["evidence_record_id"]
        when "repository_snapshot"
          document["commit_sha"]
        when "code_surface"
          document["code_surface_digest"]
        end
      end
      private_class_method :source_id
    end
  end
end
