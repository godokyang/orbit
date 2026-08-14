# frozen_string_literal: true

unless defined?(Orbit::V2::Validator)
  raise LoadError, "load Validator internals through orbit/v2/validator"
end

module Orbit
  module V2
    class Validator
      module FindingsLineage
        private

        def validate_findings(bundle)
          evaluations = @indexes.fetch("gate_evaluations", {})
          findings = @indexes.fetch("findings", {})
          Array(bundle["findings"]).each do |finding|
            next unless finding.is_a?(Hash)

            path = "findings.#{finding["finding_id"]}"
            evaluation = evaluations[finding["gate_evaluation_id"]]
            unless evaluation && Array(evaluation["finding_refs"]).include?(finding["finding_id"])
              add("reference_not_found", "Finding must be reported by its GateEvaluation", path)
            end
            allowed_evidence = Array(evaluation&.dig("subject", "evidence_record_refs")).map do |ref|
              ref["evidence_record_id"]
            end
            allowed_evidence << evaluation["evaluator_submission_record_id"] if evaluation
            source_refs = Array(finding["source_evidence_record_refs"])
            unless source_refs.any? &&
                   source_refs.all? { |record_id| @indexes.fetch("evidence_records", {}).key?(record_id) } &&
                   subset?(source_refs, allowed_evidence)
              add(
                "finding_source_invalid",
                "Finding source evidence must resolve through its GateEvaluation subject or evaluator submission",
                "#{path}.source_evidence_record_refs"
              )
            end
            unless finding_lineage(finding)
              add(
                "finding_lineage_invalid",
                "Finding must derive one existing GateEvaluation/GateRequirement/TaskRevision lineage",
                path
              )
            end
            validate_supersedes(
              finding,
              "supersedes_finding_id",
              @graphs.fetch("findings"),
              "finding_id",
              path,
              same_scope: %w[project_id],
              compatible: method(:finding_lineage_compatible?)
            )
            validate_related_refs(
              finding,
              "related_finding_refs",
              @graphs.fetch("findings"),
              "finding_id",
              path,
              &method(:finding_lineage_compatible?)
            )
          end
          validate_supersedes_cycles(
            @graphs.fetch("findings"),
            "supersedes_finding_id",
            "finding_id",
            "findings"
          )
          Array(bundle["gate_evaluations"]).each do |evaluation|
            next unless evaluation.is_a?(Hash)

            Array(evaluation["finding_refs"]).each do |finding_id|
              finding = findings[finding_id]
              unless finding && finding["gate_evaluation_id"] == evaluation["gate_evaluation_id"]
                add(
                  "finding_reference_invalid",
                  "every GateEvaluation finding ref must resolve back to that evaluation",
                  "gate_evaluations.#{evaluation["gate_evaluation_id"]}.finding_refs"
                )
              end
            end
          end
          Array(bundle["task_revisions"]).each do |task|
            next unless task.is_a?(Hash)

            Array(task["unresolved_finding_refs"]).each do |finding_id|
              finding = findings[finding_id]
              lineage = finding && finding_lineage(finding)
              unless lineage &&
                     lineage["task_id"] == task["task_id"] &&
                     task_revision_in_lineage?(task, lineage["task_revision_id"])
                add(
                  "finding_reference_invalid",
                  "TaskRevision unresolved Finding must exist in its task/gate lineage",
                  "task_revisions.#{task["task_revision_id"]}.unresolved_finding_refs"
                )
              end
            end
          end
        end

        def validate_finding_resolutions(bundle, active_policy)
          findings = @indexes.fetch("findings", {})
          attempts = @indexes.fetch("work_unit_attempts", {})
          records = @indexes.fetch("evidence_records", {})
          authorizations = @indexes.fetch("authorization_records", {})
          Array(bundle["finding_resolutions"]).each do |resolution|
            next unless resolution.is_a?(Hash)

            path = "finding_resolutions.#{resolution["finding_resolution_id"]}"
            finding = findings[resolution["finding_id"]]
            add("reference_not_found", "FindingResolution Finding does not exist", path) unless finding
            if resolution.key?("issuer") || resolution.key?("issuer_name")
              add("finding_resolution_authority_invalid", "free-text resolution issuer is forbidden", path)
            end
            validate_resolution_provenance_fields(resolution, path)
            supporting = validate_resolution_supporting_records(
              resolution,
              @graphs.fetch("evidence_records"),
              path
            )
            case resolution["resolution"]
            when "addressed", "disproved"
              attempt = attempts[resolution["issuer_attempt_id"]]
              submission = records[resolution["issuer_submission_record_id"]]
              purpose = attempt&.dig("events", 0, "assignment", "purpose")
              resolving = @indexes.fetch("gate_evaluations", {}).dig(
                resolution.dig("resolving_gate_evaluation_ref", "gate_evaluation_id")
              )
              resolving_requirement = resolving &&
                @indexes.fetch("gate_requirements", {})[resolving["gate_requirement_id"]]
              support_valid = supporting.any? && supporting.none?(&:nil?)
              unless attempt && submission &&
                     submission["attempt_id"] == attempt["attempt_id"] &&
                     submission["record_kind"] == "evaluator_submission" &&
                     resolving_requirement &&
                     attempt["task_id"] == resolving_requirement["task_id"] &&
                     attempt["task_revision_id"] == resolving_requirement["task_revision_id"] &&
                     submission["task_id"] == resolving_requirement["task_id"] &&
                     submission["task_revision_id"] == resolving_requirement["task_revision_id"] &&
                     %w[review test adjudication].include?(purpose) &&
                     support_valid
                add(
                  "finding_resolution_authority_invalid",
                  "#{resolution["resolution"]} requires authorized evaluator/adjudicator Attempt, submission, and support",
                  path
                )
              end
              unless finding_resolution_gate_binding_valid?(
                resolution,
                finding,
                attempt,
                submission,
                supporting
              )
                add(
                  "finding_resolution_gate_binding_invalid",
                  "#{resolution["resolution"]} issuer must be the evaluator of the exact " \
                    "Finding GateRequirement and immutable evaluation subject",
                  "#{path}.resolving_gate_evaluation_ref"
                )
              end
              authority_policy = attempt&.dig(
                "events",
                0,
                "assignment",
                "authority_snapshot",
                "project_policy_revision_ref",
                "policy_revision_id"
              )
              if active_policy && authority_policy != active_policy["policy_revision_id"]
                add(
                  "finding_resolution_authority_invalid",
                  "resolution issuer Attempt must pin the active authority policy",
                  path
                )
              end
              issuer_agent_id =
                attempt&.dig("events", 0, "assignment", "agent_instance_id")
              issuer_identity = runtime_identity_key_for_agent_id(issuer_agent_id)
              producer_identities = supporting.compact.map do |record|
                producer = attempts[record["attempt_id"]]
                producer_agent_id =
                  producer&.dig("events", 0, "assignment", "agent_instance_id")
                runtime_identity_key_for_agent_id(producer_agent_id)
              end.compact
              if issuer_identity && producer_identities.include?(issuer_identity)
                add(
                  "independence_violation",
                  "resolution confirmer runtime identity cannot produce its supporting evidence",
                  path
                )
              end
              if resolution["resolution"] == "addressed"
                proposal = records[resolution["proposal_evidence_record_id"]]
                unless proposal &&
                       proposal["record_kind"] == "implementation" &&
                       Array(resolution["supporting_record_refs"]).include?(proposal["evidence_record_id"])
                  add(
                    "finding_resolution_authority_invalid",
                    "addressed requires an implementation proposal record confirmed by the evaluator",
                    path
                  )
                end
              end
            when "waived"
              authorization = authorizations[resolution["authorization_record_ref"]]
              unless authorization &&
                     authorization["action"] == "finding.waive" &&
                     authorization["subject_ref"] == resolution["finding_id"] &&
                     active_policy &&
                     authorization["project_policy_revision_id"] == active_policy["policy_revision_id"]
                add("finding_resolution_authority_invalid", "waiver requires active-policy authorization", path)
              end
            else
              add("finding_resolution_authority_invalid", "unknown FindingResolution outcome", "#{path}.resolution")
            end
            validate_supersedes(
              resolution,
              "supersedes_finding_resolution_id",
              @graphs.fetch("finding_resolutions"),
              "finding_resolution_id",
              path,
              same_scope: %w[finding_id]
            )
          end
        end

        def validate_resolution_provenance_fields(resolution, path)
          common = %w[
            schema_version protocol_epoch project_id finding_resolution_id finding_id
            resolution supporting_record_refs supersedes_finding_resolution_id content_digest
          ]
          outcome_fields = {
            "addressed" => %w[
              issuer_attempt_id issuer_submission_record_id source_finding_ref
              source_gate_evaluation_ref resolving_gate_evaluation_ref
              proposal_evidence_record_id
            ],
            "disproved" => %w[
              issuer_attempt_id issuer_submission_record_id source_finding_ref
              source_gate_evaluation_ref resolving_gate_evaluation_ref
            ],
            "waived" => %w[authorization_record_ref]
          }
          allowed = common + Array(outcome_fields[resolution["resolution"]])
          extra = resolution.keys - allowed
          return if extra.empty?

          add(
            "finding_resolution_provenance_invalid",
            "#{resolution["resolution"]} carries outcome-inapplicable provenance: #{extra.sort.join(", ")}",
            path
          )
        end

        def validate_resolution_supporting_records(resolution, records, path)
          ids = Array(resolution["supporting_record_refs"])
          supporting = ids.map { |id| records[id] }
          if supporting.any?(&:nil?)
            add(
              "finding_resolution_authority_invalid",
              "every FindingResolution supporting_record_ref must resolve to immutable evidence",
              "#{path}.supporting_record_refs"
            )
          end
          if resolution["resolution"] == "waived" && !ids.empty?
            add(
              "finding_resolution_authority_invalid",
              "waived resolution uses only its policy AuthorizationRecord; supporting evidence must be empty",
              "#{path}.supporting_record_refs"
            )
          end
          supporting
        end

        def validate_finding_closure(bundle, active_policy)
          tasks = @indexes.fetch("task_revisions", {})
          checkpoints = Array(bundle["lead_checkpoints"])
          resolutions = Array(bundle["finding_resolutions"]).select { |item| item.is_a?(Hash) }
          Array(bundle["findings"]).each do |finding|
            next unless finding.is_a?(Hash)

            lineage = finding_lineage(finding)
            next unless lineage

            task = tasks[lineage["task_revision_id"]]
            matching = resolutions.select { |resolution| resolution["finding_id"] == finding["finding_id"] }
            tips = resolution_lineage_tips(finding["finding_id"], matching)
            disposition = finding_disposition(finding, active_policy)
            if disposition == "blocking" && tips.empty?
              unless task && Array(task["unresolved_finding_refs"]).include?(finding["finding_id"])
                add(
                  "finding_closure_invalid",
                  "an unresolved blocking Finding must remain referenced by its TaskRevision",
                  "findings.#{finding["finding_id"]}"
                )
              end
              source_evaluation = @indexes.fetch("gate_evaluations", {})[
                finding["gate_evaluation_id"]
              ]
              if source_evaluation && source_evaluation["verdict"] == "pass"
                add(
                  "blocking_finding_unresolved",
                  "a passing GateEvaluation cannot derive closure while its blocking Finding is unresolved",
                  "findings.#{finding["finding_id"]}"
                )
              end
            elsif disposition == "adjudication_required" && tips.empty? &&
                  !risk_escalation_proven?(finding, lineage, checkpoints)
              add(
                "finding_risk_unobserved",
                "an unadjudicated newly_discovered_risk must be introduced through exact finding_change checkpoint provenance",
                "findings.#{finding["finding_id"]}"
              )
            end
          end
        end

        def risk_escalation_proven?(finding, lineage, checkpoints)
          ref = {
            "kind" => "finding",
            "id" => finding["finding_id"],
            "digest" => finding["content_digest"]
          }
          checkpoints.any? do |checkpoint|
            next false unless checkpoint.is_a?(Hash)
            next false unless checkpoint.dig("reconcile_trigger", "event") == "finding_change"
            next false unless exact_refs_of_kind(checkpoint, "finding").include?(ref)

            predecessor = @indexes.fetch("lead_checkpoints", {})[
              checkpoint.dig("predecessor_lead_checkpoint_ref", "lead_checkpoint_id")
            ]
            next false if predecessor && exact_refs_of_kind(predecessor, "finding").include?(ref)

            checkpoint_revision = checkpoint.dig("active_task_ref", "task_revision_id") ||
              Array(checkpoint["task_queue"]).first&.dig("task_revision_id")
            checkpoint_task = @indexes.fetch("task_revisions", {})[checkpoint_revision]
            checkpoint_task && task_revision_in_lineage?(checkpoint_task, lineage["task_revision_id"])
          end
        end

        def resolution_lineage_tips(finding_id, resolutions)
          analysis = ProjectionPrimitives.supersedes_tips(
            resolutions,
            id_key: "finding_resolution_id",
            supersedes_key: "supersedes_finding_resolution_id"
          )
          case analysis.status
          when :unique
            analysis.tips
          when :empty
            []
          when :ambiguous
            add(
              "finding_resolution_lineage_invalid",
              "Finding #{finding_id} must have one append-only current resolution tip",
              "finding_resolutions"
            )
            []
          when :cycle
            add(
              "finding_resolution_lineage_invalid",
              "Finding #{finding_id} resolution lineage contains a cycle",
              "finding_resolutions.#{analysis.at}"
            )
            []
          when :disconnected
            add(
              "finding_resolution_lineage_invalid",
              "Finding #{finding_id} resolution lineage contains a fork or orphan",
              "finding_resolutions"
            )
            []
          end
        end

        def finding_lineage(finding)
          ProjectionPrimitives.finding_lineage(
            finding,
            evaluations: @indexes.fetch("gate_evaluations", {}),
            requirements: @indexes.fetch("gate_requirements", {}),
            tasks: @indexes.fetch("task_revisions", {})
          )
        end

        def finding_lineage_compatible?(left, right)
          left_lineage = finding_lineage(left)
          right_lineage = finding_lineage(right)
          left_evaluation = @indexes.fetch("gate_evaluations", {})[left["gate_evaluation_id"]]
          right_evaluation = @indexes.fetch("gate_evaluations", {})[right["gate_evaluation_id"]]
          left_lineage &&
            right_lineage &&
            left["project_id"] == right["project_id"] &&
            left_lineage["task_id"] == right_lineage["task_id"] &&
            left_lineage["gate_lineage_id"] == right_lineage["gate_lineage_id"] &&
            gate_evaluation_lineage_compatible?(left_evaluation, right_evaluation)
        end

        def finding_resolution_gate_binding_valid?(
          resolution,
          finding,
          attempt,
          submission,
          supporting
        )
          return false unless finding && attempt && submission

          ref = resolution["resolving_gate_evaluation_ref"]
          source_finding_ref = resolution["source_finding_ref"]
          source_evaluation_ref = resolution["source_gate_evaluation_ref"]
          return false unless ref.is_a?(Hash) &&
                              source_finding_ref.is_a?(Hash) &&
                              source_evaluation_ref.is_a?(Hash) &&
                              source_finding_ref["finding_id"] == finding["finding_id"] &&
                              source_finding_ref["content_digest"] == finding["content_digest"] &&
                              source_evaluation_ref["gate_evaluation_id"] ==
                                finding["gate_evaluation_id"]

          evaluation = @indexes.fetch("gate_evaluations", {})[ref["gate_evaluation_id"]]
          source_evaluation =
            @indexes.fetch("gate_evaluations", {})[finding["gate_evaluation_id"]]
          return false unless evaluation &&
                              evaluation["content_digest"] == ref["content_digest"] &&
                              source_evaluation &&
                              source_evaluation["content_digest"] ==
                                source_evaluation_ref["content_digest"] &&
                              evaluation["gate_evaluation_id"] !=
                                source_evaluation["gate_evaluation_id"] &&
                              gate_evaluation_descends_from?(
                                evaluation,
                                source_evaluation["gate_evaluation_id"]
                              )

          requirement =
            @indexes.fetch("gate_requirements", {})[evaluation["gate_requirement_id"]]
          source_requirement =
            @indexes.fetch("gate_requirements", {})[source_evaluation["gate_requirement_id"]]
          task = requirement &&
            @indexes.fetch("task_revisions", {})[requirement["task_revision_id"]]
          source_task = source_requirement &&
            @indexes.fetch("task_revisions", {})[source_requirement["task_revision_id"]]
          return false unless requirement &&
                              source_requirement &&
                              task &&
                              source_task &&
                              requirement["task_id"] == source_requirement["task_id"] &&
                              requirement["gate_lineage_id"] ==
                                source_requirement["gate_lineage_id"] &&
                              task_revision_in_lineage?(
                                task,
                                source_task["task_revision_id"]
                              ) &&
                              evidence_level_at_least?(
                                requirement["evidence_level"],
                                source_requirement["evidence_level"]
                              ) &&
                              GateStrength.independence_at_least?(
                                requirement["independence"],
                                source_requirement["independence"]
                              ) &&
                              evaluation["gate_requirement_content_digest"] ==
                                requirement["content_digest"] &&
                              evaluation["evaluator_attempt_id"] ==
                                resolution["issuer_attempt_id"] &&
                              evaluation["evaluator_submission_record_id"] ==
                                resolution["issuer_submission_record_id"] &&
                              gate_evaluation_lineage_compatible?(
                                evaluation,
                                source_evaluation
                              )

          subject_record_ids = Array(
            evaluation.dig("subject", "evidence_record_refs")
          ).map { |record_ref| record_ref["evidence_record_id"] }
          return false unless supporting.all? do |record|
            record && subject_record_ids.include?(record["evidence_record_id"])
          end

          assignment = attempt.dig("events", 0, "assignment")
          binding = GATE_EVALUATOR_BINDINGS[requirement["kind"]]
          unit = @indexes.fetch("work_units", {})[attempt["work_unit_id"]]
          agent = assignment &&
            @indexes.fetch("agent_instances", {})[assignment["agent_instance_id"]]
          return false unless binding &&
                              assignment &&
                              assignment["purpose"] == binding["purpose"] &&
                              assignment["resolved_role"] == binding["resolved_role"] &&
                              assignment_binding_valid?(assignment, unit, agent)

          if requirement["independence"] == "independent_evaluator"
            issuer_identity =
              runtime_identity_key_for_agent_id(assignment["agent_instance_id"])
            producer_identities = EvaluationSubject.producer_runtime_identities(
              evaluation["subject"],
              @indexes.fetch("work_unit_attempts", {}).values,
              @indexes.fetch("evidence_records", {}).values,
              @indexes.fetch("agent_instances", {}).values
            )
            return false if issuer_identity &&
                            producer_identities.include?(issuer_identity)
          end

          true
        end
      end

      include FindingsLineage
      private_constant :FindingsLineage
    end
  end
end
