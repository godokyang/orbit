# frozen_string_literal: true

require_relative "aggregate_outcome"
require_relative "canonical_json"
require_relative "control_authority"
require_relative "errors"
require_relative "evaluation_subject"
require_relative "projection_primitives"

module Orbit
  module V2
    # Slice 5 increment 3: the pure deterministic Typed RelationshipView.
    #
    # One derived seam: RelationshipView.derive(bundle, validator:) reads
    # validated authoritative facts through the shared projection-validation
    # boundary (including the exact historical `.subject` staleness
    # allowance) and emits canonical typed nodes and edges for the ADR-003
    # authoritative chains. It writes nothing, owns no collection/schema,
    # activates no runtime behavior, and has no persisted cache.
    #
    # Edges are derived exclusively from authoritative refs. Candidate edges
    # have no authoritative fact source in the contract — BUNDLE_KEYS has no
    # candidate collection and the Validator rejects any unknown bundle key
    # (`forbidden_second_fact_source`) — so the view exposes an explicit
    # empty `candidate_edges` section instead of a speculative graph
    # framework; a candidate relation therefore cannot alter derived edges,
    # scope, permission, state, gates, AggregateOutcome, or ContextProjection.
    #
    # Historical stale GateEvaluations stay stored with their derived edges;
    # their node carries `current: false` and they never become a
    # current/closing relation. Every node/edge uses exact stable identities
    # and digests; output is canonical and order-independent.
    module RelationshipView
      module_function

      SCHEMA_VERSION = "orbit-relationship-view-v1"
      PROTOCOL_EPOCH = "orbit-v2"

      def derive(bundle, validator:)
        AggregateOutcome.validate_projection_input!(
          bundle,
          validator: validator,
          seam: "relationship view"
        )
        project(bundle)
      rescue KeyError, TypeError, ArgumentError => e
        raise ContractError.new("relationship_view_invalid", e.message)
      end

      def project(bundle)
        project_id = bundle.fetch("protocol_root").fetch("project_id")
        nodes = {}
        edges = []
        add_node = lambda do |kind, id, digest, extra = {}|
          key = [kind, id]
          existing = nodes[key]
          if existing
            if existing["content_digest"] != digest
              raise ContractError.new(
                "relationship_view_invalid",
                "conflicting node identity #{kind} #{id}",
                path: "nodes"
              )
            end
            return existing
          end
          node = { "kind" => kind, "id" => id, "content_digest" => digest }.merge(extra)
          nodes[key] = node
          node
        end
        add_edge = lambda do |kind, source, target|
          edges << {
            "kind" => kind,
            "source" => {
              "kind" => source["kind"],
              "id" => source["id"],
              "content_digest" => source["content_digest"]
            },
            "target" => {
              "kind" => target["kind"],
              "id" => target["id"],
              "content_digest" => target["content_digest"]
            }
          }
        end
        node_by_id = lambda do |kind, id|
          node = nodes[[kind, id]]
          unless node
            raise ContractError.new(
              "relationship_view_invalid",
              "#{kind} #{id} does not exist",
              path: "derived_edges"
            )
          end
          node
        end
        node_by_ref = lambda do |kind, ref, id_key|
          unless ref.is_a?(Hash)
            raise ContractError.new(
              "relationship_view_invalid",
              "#{kind} ref is missing",
              path: "derived_edges"
            )
          end
          node = nodes[[kind, ref[id_key]]]
          unless node && node["content_digest"] == ref["content_digest"]
            raise ContractError.new(
              "relationship_view_invalid",
              "#{kind} ref does not resolve exactly",
              path: "derived_edges"
            )
          end
          node
        end

        requirements = index(bundle, "gate_requirements", "gate_requirement_id")
        tasks = index(bundle, "task_revisions", "task_revision_id")
        artifacts_index = index(bundle, "rule_resolution_artifacts", "resolution_id")
        attempts_index = index(bundle, "work_unit_attempts", "attempt_id")
        assertions_index = index(bundle, "authority_assertions", "assertion_id")
        checkpoints_index = index(bundle, "lead_checkpoints", "lead_checkpoint_id")
        agents_index = index(bundle, "agent_instances", "agent_instance_id")
        thesis_digests_by_id = {}
        Array(bundle["change_theses"]).each do |thesis|
          next unless thesis.is_a?(Hash)

          (thesis_digests_by_id[thesis["change_thesis_id"]] ||= []) << thesis["content_digest"]
        end

        # ---- nodes -------------------------------------------------------
        root = bundle["protocol_root"]
        add_node.call("protocol_root", root["project_id"], ProjectionPrimitives.source_digest(root))
        ProjectionPrimitives::COLLECTION_SOURCES.each do |collection, (kind, id_field)|
          Array(bundle[collection]).each do |document|
            next unless document.is_a?(Hash)

            id = document[id_field]
            next if id.nil?

            extra =
              if kind == "gate_evaluation"
                { "current" => evaluation_current?(document, bundle, tasks, requirements) }
              else
                {}
              end
            add_node.call(kind, id, ProjectionPrimitives.source_digest(document), extra)
          end
        end
        Array(bundle["change_theses"]).each do |thesis|
          next unless thesis.is_a?(Hash)

          add_node.call(
            "change_thesis",
            "#{thesis["change_thesis_id"]}@#{thesis["revision"]}",
            thesis["content_digest"]
          )
        end
        snapshot = bundle["repository_snapshot"]
        code_surface = bundle["code_surface"]
        if snapshot.is_a?(Hash)
          add_node.call("repository_snapshot", snapshot["commit_sha"], snapshot["tree_digest"])
        end
        if code_surface.is_a?(Hash)
          add_node.call(
            "code_surface",
            code_surface["code_surface_digest"],
            code_surface["code_surface_digest"]
          )
        end
        Array(bundle["lead_sessions"]).each do |session|
          next unless session.is_a?(Hash)

          pins = runtime_subject_pins(session)
          add_node.call("runtime_subject", pins[0], pins[1]) if pins
        end

        # ---- edges -------------------------------------------------------
        add_edge.call(
          "protocol_root_pins_policy_genesis",
          node_by_id.call("protocol_root", root["project_id"]),
          node_by_ref.call("project_policy_revision", root["project_policy_genesis_ref"], "policy_revision_id")
        )
        Array(bundle["project_policy_revisions"]).each do |policy|
          next unless policy.is_a?(Hash)

          parent_id = policy["parent_policy_revision_id"]
          next unless parent_id

          add_edge.call(
            "policy_parent_lineage",
            node_by_id.call("project_policy_revision", policy["policy_revision_id"]),
            node_by_id.call("project_policy_revision", parent_id)
          )
        end
        Array(bundle["task_revisions"]).each do |task|
          next unless task.is_a?(Hash)

          add_edge.call(
            "task_revision_governed_by_policy",
            node_by_id.call("task_revision", task["task_revision_id"]),
            node_by_ref.call("project_policy_revision", task["project_policy_revision_ref"], "policy_revision_id")
          )
          Array(task["gate_requirement_refs"]).each do |gate_id|
            add_edge.call(
              "task_revision_requires_gate",
              node_by_id.call("task_revision", task["task_revision_id"]),
              node_by_id.call("gate_requirement", gate_id)
            )
          end
        end
        Array(bundle["work_units"]).each do |unit|
          next unless unit.is_a?(Hash)

          task = tasks[unit["task_revision_id"]]
          if task.is_a?(Hash) && task["task_id"] == unit["task_id"]
            add_edge.call(
              "task_revision_owns_work_unit",
              node_by_id.call("task_revision", task["task_revision_id"]),
              node_by_id.call("work_unit", unit["work_unit_id"])
            )
          end
          parent_id = unit["parent_work_unit_ref"]
          if parent_id
            add_edge.call(
              "work_unit_parent",
              node_by_id.call("work_unit", unit["work_unit_id"]),
              node_by_id.call("work_unit", parent_id)
            )
          end
          Array(unit["depends_on_work_unit_refs"]).each do |dependency_id|
            add_edge.call(
              "work_unit_depends_on",
              node_by_id.call("work_unit", unit["work_unit_id"]),
              node_by_id.call("work_unit", dependency_id)
            )
          end
          add_edge.call(
            "work_unit_pins_initial_thesis",
            node_by_id.call("work_unit", unit["work_unit_id"]),
            thesis_node_by_ref(unit["initial_change_thesis_ref"], node_by_id)
          )
        end
        Array(bundle["control_registries"]).each do |registry|
          next unless registry.is_a?(Hash)

          add_edge.call(
            "control_registry_has_genesis_checkpoint",
            node_by_id.call("control_registry", registry["lead_control_id"]),
            node_by_ref.call("lead_checkpoint", registry["genesis_checkpoint_ref"], "lead_checkpoint_id")
          )
          Array(registry["owned_task_refs"]).each do |task_ref|
            task = tasks[task_ref["task_revision_id"]]
            unless task.is_a?(Hash) && task["content_digest"] == task_ref["content_digest"]
              raise ContractError.new(
                "relationship_view_invalid",
                "control registry owned task ref does not resolve exactly",
                path: "control_registries.#{registry["lead_control_id"]}.owned_task_refs"
              )
            end
            add_edge.call(
              "control_registry_owns_task",
              node_by_id.call("control_registry", registry["lead_control_id"]),
              node_by_id.call("task_revision", task["task_revision_id"])
            )
          end
        end
        Array(bundle["lead_checkpoints"]).each do |checkpoint|
          next unless checkpoint.is_a?(Hash)

          checkpoint_node = node_by_id.call("lead_checkpoint", checkpoint["lead_checkpoint_id"])
          add_edge.call(
            "lead_checkpoint_under_control",
            checkpoint_node,
            node_by_id.call("control_registry", checkpoint["lead_control_id"])
          )
          Array(checkpoint["task_queue"]).each do |task_ref|
            queued = tasks[task_ref["task_revision_id"]]
            unless queued.is_a?(Hash) && queued["content_digest"] == task_ref["content_digest"]
              raise ContractError.new(
                "relationship_view_invalid",
                "checkpoint task queue ref does not resolve exactly",
                path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}.task_queue"
              )
            end
            add_edge.call(
              "lead_checkpoint_queues_task_revision",
              checkpoint_node,
              node_by_id.call("task_revision", queued["task_revision_id"])
            )
          end
          if checkpoint["active_task_ref"].is_a?(Hash)
            add_edge.call(
              "lead_checkpoint_active_task",
              node_by_id.call("lead_checkpoint", checkpoint["lead_checkpoint_id"]),
              node_by_ref.call("task_revision", checkpoint["active_task_ref"], "task_revision_id")
            )
          end
          if checkpoint["selected_work_unit_ref"].is_a?(Hash)
            add_edge.call(
              "lead_checkpoint_selected_work_unit",
              node_by_id.call("lead_checkpoint", checkpoint["lead_checkpoint_id"]),
              node_by_ref.call("work_unit", checkpoint["selected_work_unit_ref"], "work_unit_id")
            )
          end
          # The three derived digest identities are distinct typed nodes;
          # each connects only to its canonical inputs (adjustment payload
          # provenance; plan policy/task/rule + ordered binding identities;
          # closure task/unit/thesis/rule + the plan digest).
          plan_task_ref = checkpoint["active_task_ref"]
          plan_task_ref ||= Array(checkpoint["task_queue"]).first
          thesis_basis = ProjectionPrimitives.basis_thesis_ref(
            checkpoint,
            attempts_index,
            thesis_digests_by_id
          )
          rule_basis = ProjectionPrimitives.basis_rule_ref(
            checkpoint,
            artifacts_index,
            attempts_index
          )
          plan_digest = checkpoint["effective_verification_plan_digest"]
          basis_digest = checkpoint["closure_basis_digest"]
          adjustment_digest = checkpoint["budget_adjustment_digest"]
          if plan_digest.is_a?(String) && basis_digest.is_a?(String)
            # Only the plan and basis digest nodes are per checkpoint (the
            # checkpoint + digest value is the identity); two checkpoints may
            # share a digest value and each keeps its own exact derivation
            # chain. The budget_adjustment_digest node below is
            # content-addressed (the digest itself as id), shared by current
            # and inherited binding links.
            plan_node = add_node.call(
              "effective_verification_plan_digest",
              "#{checkpoint["lead_checkpoint_id"]}::#{plan_digest}",
              plan_digest
            )
            basis_node = add_node.call(
              "closure_basis_digest",
              "#{checkpoint["lead_checkpoint_id"]}::#{basis_digest}",
              basis_digest
            )
            adjustment_node =
              if adjustment_digest.is_a?(String)
                add_node.call("budget_adjustment_digest", adjustment_digest, adjustment_digest)
              end
            add_edge.call("lead_checkpoint_derives_plan_digest", checkpoint_node, plan_node)
            add_edge.call("lead_checkpoint_derives_basis_digest", checkpoint_node, basis_node)
            add_edge.call(
              "effective_verification_plan_digest_policy_source",
              plan_node,
              node_by_ref.call("project_policy_revision", checkpoint["project_policy_revision_ref"], "policy_revision_id")
            )
            if plan_task_ref.is_a?(Hash)
              add_edge.call(
                "effective_verification_plan_digest_task_source",
                plan_node,
                node_by_ref.call("task_revision", plan_task_ref, "task_revision_id")
              )
            end
            if rule_basis.is_a?(Hash)
              # The canonical plan rule ref is {resolution_id, identity_sha256};
              # the typed rule-identity node carries that exact hash, never
              # the artifact object digest.
              rule_identity_node = add_node.call(
                "rule_identity",
                rule_basis["resolution_id"],
                rule_basis["identity_sha256"]
              )
              add_edge.call("effective_verification_plan_digest_rule_source", plan_node, rule_identity_node)
            end
            Array(checkpoint["effective_budget_bindings"]).each do |binding|
              next unless binding.is_a?(Hash) && %w[work_unit_lineage task_lineage].include?(binding["budget_scope_type"])

              binding_node = add_node.call(
                "budget_binding",
                "#{checkpoint["lead_checkpoint_id"]}::#{binding["budget_scope_type"]}",
                ControlAuthority.binding_digest(binding),
                "budget_scope_type" => binding["budget_scope_type"]
              )
              add_edge.call("lead_checkpoint_has_budget_binding", checkpoint_node, binding_node)
              add_edge.call("effective_verification_plan_digest_uses_binding", plan_node, binding_node)
              measurements = binding["measurements"]
              next unless measurements.is_a?(Hash)

              review_refs = {}
              lead_support_refs = {}
              %w[test_count test_code_lines].each do |metric|
                measurement = measurements[metric]
                next unless measurement.is_a?(Hash)

                if measurement["status"] == "verified" && measurement["source_ref"].is_a?(Hash)
                  source_ref = measurement["source_ref"]
                  assertion = assertions_index[source_ref["id"]]
                  unless assertion.is_a?(Hash) && assertion["assertion_digest"] == source_ref["digest"]
                    raise ContractError.new(
                      "relationship_view_invalid",
                      "measurement attestation source does not resolve exactly",
                      path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
                    )
                  end
                  add_edge.call(
                    "budget_binding_uses_measurement_attestation",
                    binding_node,
                    node_by_id.call("authority_assertion", source_ref["id"])
                  )
                elsif measurement["status"] == "unverified"
                  review_ref = measurement.dig("unverified_assessment", "review_gate_evaluation_ref")
                  review_refs[[review_ref["gate_evaluation_id"], review_ref["content_digest"]]] = review_ref if review_ref.is_a?(Hash)
                  Array(measurement.dig("unverified_assessment", "lead_supporting_refs")).each do |ref|
                    next unless ref.is_a?(Hash)

                    lead_support_refs[[ref["kind"], ref["id"], ref["event_id"], ref["digest"]]] = ref
                  end
                end
              end
              # Both unverified metrics canonically share the same review
              # ref; identical semantic refs emit exactly one relation.
              review_refs.values.sort_by { |ref| ref["gate_evaluation_id"] }.each do |review_ref|
                add_edge.call(
                  "budget_binding_uses_review",
                  binding_node,
                  node_by_ref.call("gate_evaluation", review_ref, "gate_evaluation_id")
                )
              end
              # Exact unverified-assessment supporting refs are binding
              # sources; both metrics may legally share one, so dedupe by
              # exact semantic identity before emission.
              lead_support_refs.values.sort_by do |ref|
                [ref["kind"], ref["id"], ref["event_id"], ref["digest"]]
              end.each do |ref|
                support_node = supporting_ref_node(
                  ref, bundle, artifacts_index, attempts_index, agents_index, node_by_id, add_node
                )
                add_edge.call("budget_binding_uses_supporting_source", binding_node, support_node)
              end
              override_source = binding["user_override_source"]
              if override_source.is_a?(Hash) && override_source["authorization_record_ref"].is_a?(Hash)
                add_edge.call(
                  "budget_binding_uses_override",
                  binding_node,
                  node_by_ref.call(
                    "authorization_record",
                    override_source["authorization_record_ref"],
                    "authorization_record_id"
                  )
                )
              end
              adjustment_source = binding["lead_adjustment_source"]
              if adjustment_source.is_a?(Hash) && adjustment_source["adjustment_digest"].is_a?(String)
                case adjustment_source["mode"]
                when "current"
                  add_edge.call(
                    "budget_binding_uses_adjustment_digest",
                    binding_node,
                    add_node.call(
                      "budget_adjustment_digest",
                      adjustment_source["adjustment_digest"],
                      adjustment_source["adjustment_digest"]
                    )
                  )
                when "inherited"
                  inherited_ref = adjustment_source["inherited_checkpoint_ref"]
                  if inherited_ref.is_a?(Hash)
                    inherited_checkpoint = node_by_ref.call(
                      "lead_checkpoint",
                      inherited_ref,
                      "lead_checkpoint_id"
                    )
                    add_edge.call(
                      "budget_binding_inherited_checkpoint_source",
                      binding_node,
                      inherited_checkpoint
                    )
                    add_edge.call(
                      "budget_binding_uses_adjustment_digest",
                      binding_node,
                      add_node.call(
                        "budget_adjustment_digest",
                        adjustment_source["adjustment_digest"],
                        adjustment_source["adjustment_digest"]
                      )
                    )
                  end
                end
              end
            end
            add_edge.call(
              "closure_basis_digest_task_source",
              basis_node,
              node_by_ref.call("task_revision", plan_task_ref, "task_revision_id")
            ) if plan_task_ref.is_a?(Hash)
            if checkpoint["selected_work_unit_ref"].is_a?(Hash)
              add_edge.call(
                "closure_basis_digest_work_unit_source",
                basis_node,
                node_by_ref.call("work_unit", checkpoint["selected_work_unit_ref"], "work_unit_id")
              )
            end
            if thesis_basis.is_a?(Hash)
              add_edge.call(
                "closure_basis_digest_thesis_source",
                basis_node,
                thesis_node_by_id_digest(
                  thesis_basis["change_thesis_id"],
                  thesis_basis["content_digest"],
                  Array(bundle["change_theses"]),
                  node_by_id
                )
              )
            end
            if rule_basis.is_a?(Hash)
              rule_identity_node = add_node.call(
                "rule_identity",
                rule_basis["resolution_id"],
                rule_basis["identity_sha256"]
              )
              add_edge.call("closure_basis_digest_rule_source", basis_node, rule_identity_node)
            end
            add_edge.call("closure_basis_digest_plan_source", basis_node, plan_node)
          end
          if adjustment_digest.is_a?(String) && adjustment_node
            add_edge.call("lead_checkpoint_derives_adjustment_digest", checkpoint_node, adjustment_node)
            payload = checkpoint["test_budget_adjust"]
            if payload.is_a?(Hash)
              predecessor_ref = payload["predecessor_lead_checkpoint_ref"]
              if predecessor_ref.is_a?(Hash)
                predecessor_checkpoint = node_by_ref.call("lead_checkpoint", predecessor_ref, "lead_checkpoint_id")
                add_edge.call(
                  "budget_adjustment_digest_predecessor_source",
                  adjustment_node,
                  predecessor_checkpoint
                )
                predecessor_binding = Array(checkpoints_index[predecessor_ref["lead_checkpoint_id"]]["effective_budget_bindings"]).find do |candidate|
                  candidate.is_a?(Hash) && candidate["budget_scope_type"] == payload["budget_scope_type"]
                end
                if predecessor_binding.is_a?(Hash)
                  add_edge.call(
                    "budget_adjustment_digest_predecessor_binding",
                    adjustment_node,
                    add_node.call(
                      "budget_binding",
                      "#{predecessor_ref["lead_checkpoint_id"]}::#{payload["budget_scope_type"]}",
                      ControlAuthority.binding_digest(predecessor_binding),
                      "budget_scope_type" => payload["budget_scope_type"]
                    )
                  )
                end
              end
              policy_ref = payload["project_policy_revision_ref"]
              if policy_ref.is_a?(Hash)
                add_edge.call(
                  "budget_adjustment_digest_policy_source",
                  adjustment_node,
                  node_by_ref.call("project_policy_revision", policy_ref, "policy_revision_id")
                )
              end
              # The schema does not require payload supporting refs unique;
              # identical semantic refs emit exactly one edge.
              supporting_refs = {}
              Array(payload["supporting_refs"]).each do |ref|
                next unless ref.is_a?(Hash)

                supporting_refs[[ref["kind"], ref["id"], ref["event_id"], ref["digest"]]] = ref
              end
              supporting_refs.values.sort_by do |ref|
                [ref["kind"], ref["id"], ref["event_id"], ref["digest"]]
              end.each do |ref|
                support_node = supporting_ref_node(
                  ref, bundle, artifacts_index, attempts_index, agents_index, node_by_id, add_node
                )
                add_edge.call("budget_adjustment_digest_supporting_source", adjustment_node, support_node)
              end
            end
          end
          if checkpoint["current_or_terminal_attempt_ref"].is_a?(Hash)
            add_edge.call(
              "lead_checkpoint_tracks_attempt",
              node_by_id.call("lead_checkpoint", checkpoint["lead_checkpoint_id"]),
              node_by_id.call("work_unit_attempt", checkpoint.dig("current_or_terminal_attempt_ref", "attempt_id"))
            )
          end
        end
        Array(bundle["lead_sessions"]).each do |session|
          next unless session.is_a?(Hash)

          add_edge.call(
            "lead_session_belongs_to_control",
            node_by_id.call("lead_session", session["lead_session_id"]),
            node_by_id.call("control_registry", session["lead_control_id"])
          )
          pins = runtime_subject_pins(session)
          if pins
            add_edge.call(
              "lead_session_binds_runtime_subject",
              node_by_id.call("lead_session", session["lead_session_id"]),
              node_by_id.call("runtime_subject", pins[0])
            )
          end
        end
        Array(bundle["work_unit_attempts"]).each do |attempt|
          next unless attempt.is_a?(Hash)

          assignment = attempt.dig("events", 0, "assignment")
          unless assignment.is_a?(Hash)
            raise ContractError.new(
              "relationship_view_invalid",
              "attempt has no immutable assignment",
              path: "work_unit_attempts.#{attempt["attempt_id"]}.events"
            )
          end
          attempt_node = node_by_id.call("work_unit_attempt", attempt["attempt_id"])
          add_edge.call("work_unit_attempt_belongs_to_unit", attempt_node, node_by_id.call("work_unit", attempt["work_unit_id"]))
          add_edge.call("work_unit_has_attempt", node_by_id.call("work_unit", attempt["work_unit_id"]), attempt_node)
          add_edge.call("work_unit_attempt_belongs_to_task", attempt_node, node_by_id.call("task_revision", attempt["task_revision_id"]))
          add_edge.call("work_unit_attempt_under_control", attempt_node, node_by_id.call("control_registry", attempt["lead_control_id"]))
          add_edge.call("work_unit_attempt_uses_agent", attempt_node, node_by_id.call("agent_instance", assignment["agent_instance_id"]))
          add_edge.call("work_unit_attempt_uses_thesis", attempt_node, thesis_node_by_ref(assignment["change_thesis_ref"], node_by_id))
          add_edge.call(
            "work_unit_attempt_uses_rule_resolution",
            attempt_node,
            node_by_id.call("rule_resolution_artifact", assignment["assigned_rule_resolution_id"])
          )
          add_edge.call(
            "work_unit_attempt_dispatched_by",
            attempt_node,
            node_by_ref.call("lead_checkpoint", attempt["dispatch_lead_checkpoint_ref"], "lead_checkpoint_id")
          )
        end
        Array(bundle["evidence_records"]).each do |record|
          next unless record.is_a?(Hash)

          record_node = node_by_id.call("evidence_record", record["evidence_record_id"])
          add_edge.call("evidence_record_produced_by_attempt", record_node, node_by_id.call("work_unit_attempt", record["attempt_id"]))
          add_edge.call(
            "evidence_record_submits_rule_resolution",
            record_node,
            node_by_id.call("rule_resolution_artifact", record["submitted_rule_resolution_id"])
          )
          thesis_ref = record.dig("implementation_check", "change_thesis_ref")
          if thesis_ref.is_a?(Hash)
            add_edge.call("evidence_record_supports_change_thesis", record_node, thesis_node_by_ref(thesis_ref, node_by_id))
          end
          Array(record["submission_artifact_refs"]).each do |claim|
            next unless claim.is_a?(Hash) && claim["artifact_ref"].is_a?(String)

            # Claim identity is per-record: the Validator enforces artifact
            # uniqueness only inside one EvidenceRecord, so two records may
            # reuse the same artifact URI with different content digests
            # (historical/versioned claims). The node id is therefore
            # record ownership + artifact_ref, never the URI alone.
            claim_node = add_node.call(
              "artifact_claim",
              "#{record["evidence_record_id"]}::#{claim["artifact_ref"]}",
              claim["content_digest"],
              "artifact_ref" => claim["artifact_ref"]
            )
            add_edge.call("evidence_record_claims_artifact", record_node, claim_node)
          end
        end
        Array(bundle["gate_evaluations"]).each do |evaluation|
          next unless evaluation.is_a?(Hash)

          evaluation_node = node_by_id.call("gate_evaluation", evaluation["gate_evaluation_id"])
          add_edge.call(
            "gate_evaluation_requires_gate",
            evaluation_node,
            node_by_ref.call(
              "gate_requirement",
              {
                "gate_requirement_id" => evaluation["gate_requirement_id"],
                "content_digest" => evaluation["gate_requirement_content_digest"]
              },
              "gate_requirement_id"
            )
          )
          add_edge.call("gate_evaluation_evaluated_by_attempt", evaluation_node, node_by_id.call("work_unit_attempt", evaluation["evaluator_attempt_id"]))
          add_edge.call("gate_evaluation_submitted_by_record", evaluation_node, node_by_id.call("evidence_record", evaluation["evaluator_submission_record_id"]))
          subject = evaluation["subject"]
          if subject.is_a?(Hash)
            add_edge.call(
              "gate_evaluation_subject_task_revision",
              evaluation_node,
              node_by_ref.call("task_revision", subject["task_revision_ref"], "task_revision_id")
            )
            Array(subject["work_unit_refs"]).each do |ref|
              add_edge.call("gate_evaluation_subject_work_unit", evaluation_node, node_by_ref.call("work_unit", ref, "work_unit_id"))
            end
            Array(subject["implementation_attempt_refs"]).each do |ref|
              add_edge.call(
                "gate_evaluation_subject_implementation_attempt",
                evaluation_node,
                node_by_id.call("work_unit_attempt", ref["attempt_id"])
              )
            end
            Array(subject["evidence_record_refs"]).each do |ref|
              add_edge.call("gate_evaluation_subject_evidence_record", evaluation_node, node_by_ref.call("evidence_record", ref, "evidence_record_id"))
            end
            if subject["repository_snapshot_ref"].is_a?(Hash)
              snapshot_ref = subject["repository_snapshot_ref"]
              snapshot_node = add_node.call(
                "repository_snapshot",
                snapshot_ref["commit_sha"],
                snapshot_ref["tree_digest"]
              )
              add_edge.call("gate_evaluation_subject_repository_snapshot", evaluation_node, snapshot_node)
            end
            if subject["code_surface_ref"].is_a?(Hash)
              surface_ref = subject["code_surface_ref"]
              surface_node = add_node.call(
                "code_surface",
                surface_ref["code_surface_digest"],
                surface_ref["code_surface_digest"]
              )
              add_edge.call("gate_evaluation_subject_code_surface", evaluation_node, surface_node)
            end
          end
          Array(evaluation["finding_refs"]).each do |finding_id|
            add_edge.call("gate_evaluation_reports_finding", evaluation_node, node_by_id.call("finding", finding_id))
          end
          supersedes = evaluation["supersedes_gate_evaluation_id"]
          if supersedes
            add_edge.call("gate_evaluation_supersedes", evaluation_node, node_by_id.call("gate_evaluation", supersedes))
          end
          Array(evaluation["related_gate_evaluation_refs"]).each do |related_id|
            add_edge.call("gate_evaluation_related_to", evaluation_node, node_by_id.call("gate_evaluation", related_id))
          end
        end
        Array(bundle["findings"]).each do |finding|
          next unless finding.is_a?(Hash)

          finding_node = node_by_id.call("finding", finding["finding_id"])
          add_edge.call("finding_reported_by_gate_evaluation", finding_node, node_by_id.call("gate_evaluation", finding["gate_evaluation_id"]))
          supersedes = finding["supersedes_finding_id"]
          if supersedes
            add_edge.call("finding_supersedes", finding_node, node_by_id.call("finding", supersedes))
          end
          Array(finding["related_finding_refs"]).each do |related_id|
            add_edge.call("finding_related_to", finding_node, node_by_id.call("finding", related_id))
          end
        end
        Array(bundle["finding_resolutions"]).each do |resolution|
          next unless resolution.is_a?(Hash)

          resolution_node = node_by_id.call("finding_resolution", resolution["finding_resolution_id"])
          add_edge.call("finding_resolution_resolves_finding", resolution_node, node_by_id.call("finding", resolution["finding_id"]))
          if resolution["issuer_attempt_id"].is_a?(String)
            add_edge.call("finding_resolution_issued_by_attempt", resolution_node, node_by_id.call("work_unit_attempt", resolution["issuer_attempt_id"]))
          end
          if resolution["issuer_submission_record_id"].is_a?(String)
            add_edge.call("finding_resolution_submitted_by_record", resolution_node, node_by_id.call("evidence_record", resolution["issuer_submission_record_id"]))
          end
          if resolution["source_gate_evaluation_ref"].is_a?(Hash)
            add_edge.call(
              "finding_resolution_source_evaluation",
              resolution_node,
              node_by_ref.call("gate_evaluation", resolution["source_gate_evaluation_ref"], "gate_evaluation_id")
            )
          end
          if resolution["resolving_gate_evaluation_ref"].is_a?(Hash)
            add_edge.call(
              "finding_resolution_resolving_evaluation",
              resolution_node,
              node_by_ref.call("gate_evaluation", resolution["resolving_gate_evaluation_ref"], "gate_evaluation_id")
            )
          end
          Array(resolution["supporting_record_refs"]).each do |record_id|
            add_edge.call("finding_resolution_supports_evidence", resolution_node, node_by_id.call("evidence_record", record_id))
          end
          supersedes = resolution["supersedes_finding_resolution_id"]
          if supersedes
            add_edge.call("finding_resolution_supersedes", resolution_node, node_by_id.call("finding_resolution", supersedes))
          end
        end

        # ---- canonical output ---------------------------------------------
        edge_keys = edges.map do |edge|
          [edge["kind"], edge["source"]["kind"], edge["source"]["id"], edge["target"]["kind"], edge["target"]["id"]]
        end
        if edge_keys.uniq.length != edge_keys.length
          duplicate = edge_keys.group_by(&:itself).find { |_key, items| items.length > 1 }&.first
          raise ContractError.new(
            "relationship_view_invalid",
            "derived edge set contains a duplicate edge identity #{duplicate.inspect}",
            path: "derived_edges"
          )
        end
        manifest = ProjectionPrimitives.bundle_source_manifest(
          bundle,
          error_code: "relationship_view_invalid"
        )
        document = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => project_id,
          "nodes" => nodes.values.sort_by { |node| [node["kind"], node["id"]] },
          "derived_edges" => edges.sort_by do |edge|
            [
              edge["kind"],
              edge["source"]["kind"],
              edge["source"]["id"],
              edge["target"]["kind"],
              edge["target"]["id"]
            ]
          end,
          "candidate_edges" => [],
          "source_manifest" => manifest,
          "source_digest" => "sha256:#{CanonicalJSON.sha256(manifest)}"
        }
        document.merge(
          "content_digest" => CanonicalJSON.digest_excluding(document, "content_digest")
        )
      end
      private_class_method :project

      def evaluation_current?(evaluation, bundle, tasks, requirements)
        requirement = requirements[evaluation["gate_requirement_id"]]
        unless requirement.is_a?(Hash)
          raise ContractError.new(
            "relationship_view_invalid",
            "gate evaluation requirement does not exist",
            path: "gate_evaluations.#{evaluation["gate_evaluation_id"]}"
          )
        end
        task = tasks[requirement["task_revision_id"]]
        unless task.is_a?(Hash)
          raise ContractError.new(
            "relationship_view_invalid",
            "gate evaluation requirement task revision does not exist",
            path: "gate_evaluations.#{evaluation["gate_evaluation_id"]}"
          )
        end
        expected = EvaluationSubject.select(
          gate_requirement: requirement,
          task_revision: task,
          work_units: Array(bundle["work_units"]),
          attempts: Array(bundle["work_unit_attempts"]),
          evidence_records: Array(bundle["evidence_records"]),
          repository_snapshot: bundle["repository_snapshot"],
          code_surface: bundle["code_surface"]
        )
        ProjectionPrimitives.evaluation_current?(
          evaluation,
          requirement: requirement,
          expected_subject: expected
        )
      end
      private_class_method :evaluation_current?

      def thesis_node_by_ref(ref, node_by_id)
        unless ref.is_a?(Hash) && ref["revision"].is_a?(Integer)
          raise ContractError.new(
            "relationship_view_invalid",
            "change thesis ref is missing its exact revision",
            path: "derived_edges"
          )
        end
        node = node_by_id.call("change_thesis", "#{ref["change_thesis_id"]}@#{ref["revision"]}")
        unless node["content_digest"] == ref["content_digest"]
          raise ContractError.new(
            "relationship_view_invalid",
            "change thesis ref does not resolve exactly",
            path: "derived_edges"
          )
        end
        node
      end
      private_class_method :thesis_node_by_ref

      def thesis_node_by_id_digest(change_thesis_id, content_digest, theses, node_by_id)
        thesis = Array(theses).select do |candidate|
          candidate.is_a?(Hash) &&
            candidate["change_thesis_id"] == change_thesis_id &&
            candidate["content_digest"] == content_digest
        end.min_by { |candidate| candidate["revision"] }
        unless thesis.is_a?(Hash)
          raise ContractError.new(
            "relationship_view_invalid",
            "change thesis ref does not resolve exactly",
            path: "derived_edges"
          )
        end
        node_by_id.call("change_thesis", "#{thesis["change_thesis_id"]}@#{thesis["revision"]}")
      end
      private_class_method :thesis_node_by_id_digest

      def runtime_subject_pins(session)
        subject_ref = session["lead_runtime_subject_ref"]
        assertion_digest = session["lead_runtime_subject_assertion_digest"]
        [subject_ref, assertion_digest] if subject_ref.is_a?(String) && assertion_digest.is_a?(String)
      end
      private_class_method :runtime_subject_pins

      def supporting_ref_node(ref, bundle, artifacts_index, attempts_index, agents_index,
                              node_by_id, add_node)
        case ref["kind"]
        when "work_unit", "task_revision", "evidence_record", "finding", "finding_resolution",
             "gate_evaluation", "lead_checkpoint"
          node = node_by_id.call(ref["kind"], ref["id"])
          unless node["content_digest"] == ref["digest"]
            raise ContractError.new(
              "relationship_view_invalid",
              "adjustment supporting ref does not resolve exactly",
              path: "derived_edges"
            )
          end
          node
        when "change_thesis"
          thesis_node_by_id_digest(ref["id"], ref["digest"], Array(bundle["change_theses"]), node_by_id)
        when "rule_resolution"
          rule = artifacts_index[ref["id"]]
          unless rule.is_a?(Hash) && rule["identity_sha256"] == ref["digest"]
            raise ContractError.new(
              "relationship_view_invalid",
              "adjustment supporting rule ref does not resolve exactly",
              path: "derived_edges"
            )
          end
          add_node.call("rule_identity", ref["id"], ref["digest"])
        when "attempt_event"
          event_supporting_node(ref, attempts_index, "events", "attempt_event", add_node)
        when "agent_event"
          event_supporting_node(ref, agents_index, "lifecycle_events", "agent_event", add_node)
        else
          raise ContractError.new(
            "relationship_view_invalid",
            "adjustment supporting ref kind is not resolvable",
            path: "derived_edges"
          )
        end
      end
      private_class_method :supporting_ref_node

      # Event source identity is owner id + event_id + exact event_digest;
      # the typed event node never aliases the enclosing owner object digest.
      def event_supporting_node(ref, owner_index, events_field, kind, add_node)
        owner = owner_index[ref["id"]]
        event = owner.is_a?(Hash) && Array(owner[events_field]).find do |candidate|
          candidate["event_id"] == ref["event_id"]
        end
        unless event.is_a?(Hash) && event["event_digest"] == ref["digest"]
          raise ContractError.new(
            "relationship_view_invalid",
            "adjustment supporting event ref does not resolve exactly",
            path: "derived_edges"
          )
        end
        add_node.call(kind, "#{ref["id"]}::#{ref["event_id"]}", ref["digest"])
      end
      private_class_method :event_supporting_node

      def index(bundle, collection, id_field)
        result = {}
        Array(bundle[collection]).each do |document|
          next unless document.is_a?(Hash)

          id = document[id_field]
          next if id.nil?

          if result.key?(id)
            raise ContractError.new(
              "relationship_view_invalid",
              "#{collection} contains a duplicate #{id_field} identity",
              path: "#{collection}.#{id}"
            )
          end
          result[id] = document
        end
        result
      end
      private_class_method :index
    end
  end
end
