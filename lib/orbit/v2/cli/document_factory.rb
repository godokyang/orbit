# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

require_relative "../canonical_json"
require_relative "../code_surface"
require_relative "../control_authority"
require_relative "../errors"
require_relative "../evaluation_subject"
require_relative "../identifiers"
require_relative "../local_provider"
require_relative "../policy_issuance"
require_relative "../rule_resolution"
require_relative "../work_authority"

module Orbit
  module V2
    # Minimal happy-path document factory for the phase D CLI. Every builder
    # is a dynamic-id/dynamic-timestamp port of the corresponding fixture in
    # tests/fixtures/orbit-v2/fixture_factory.rb (the frozen semantic
    # authority); record shapes are NOT reinvented here. Receipts are issued
    # by the configured local providers (LocalProvider).
    class DocumentFactory
      DISPATCH_DECISION = {
        "state" => "blocked", "action" => "dispatch", "reason" => "dispatch authorized"
      }.freeze

      def initialize(project_id:, policy:, authority:, runtime:, lifecycle:,
                     issuer_subject:, clock:, project_root:)
        @project_id = project_id
        @policy = policy
        @authority = authority
        @runtime = runtime
        @lifecycle = lifecycle
        @issuer_subject = issuer_subject
        @clock = clock
        @project_root = project_root
      end

      attr_reader :project_id, :policy

      def self.hex(length = 10)
        SecureRandom.hex(length / 2)
      end

      def new_id(prefix)
        "#{prefix}#{self.class.hex}"
      end

      def stamp
        @clock.call
      end

      # -- policy genesis ----------------------------------------------------
      #
      # Circular binding order (same as the fixture): the policy pins the
      # issuance assertion digest computed over the PENDING assertion shape
      # (scope placeholder, no envelope); the envelope then binds the digested
      # policy; the final assertion carries the envelope and the SAME digest.

      def policy_genesis_pair(policy_revision_id, assertion_id)
        issued_at = stamp
        pending_digest = AuthorityVerifier.assertion_digest(
          "schema_version" => "orbit-authority-assertion-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "assertion_id" => assertion_id,
          "issuer_kind" => "user",
          "issuer_subject" => @issuer_subject,
          "provider_id" => LocalProvider::AUTHORITY_PROVIDER_ID,
          "authority_scope_ref" => "policy-issuance-scope-pending",
          "grants" => ["policy.genesis"],
          "asserted_at" => issued_at
        )
        policy = digested(
          "schema_version" => "orbit-project-policy-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "policy_revision_id" => policy_revision_id,
          "parent_policy_revision_id" => nil,
          "authorization_source_ref" => assertion_id,
          "authorization_assertion_digest" => pending_digest,
          "protected_gate_minimums" => [
            { "gate_kind" => "review", "evidence_level" => "outcome_quality",
              "independence" => "independent_evaluator" }
          ],
          "finding_disposition" => {
            "contract_violation" => "blocking",
            "regression" => "blocking",
            "newly_discovered_risk" => "adjudication_required",
            "hardening_opportunity" => "nonblocking"
          },
          "authority_grants" => [
            { "action" => "control.genesis", "required_external_grant" => "control.genesis" },
            { "action" => "control.checkpoint", "required_external_grant" => "control.checkpoint" },
            { "action" => "work.implement", "required_external_grant" => "work.implement" },
            { "action" => "gate.review.evaluate", "required_external_grant" => "gate.review.evaluate" },
            { "action" => "finding.waive", "required_external_grant" => "finding.waive" }
          ],
          "orchestration_policy" => {
            "wall_clock_fallback" => { "interval_seconds" => 3600, "upper_bound_seconds" => 86_400 },
            "test_budget" => {
              "work_unit_lineage" => {
                "default_test_count" => 10, "default_test_code_lines" => 300,
                "lead_ceiling_test_count" => 20, "lead_ceiling_test_code_lines" => 600
              },
              "task_lineage" => {
                "default_test_count" => 30, "default_test_code_lines" => 900,
                "lead_ceiling_test_count" => 60, "lead_ceiling_test_code_lines" => 1800
              }
            }
          }
        )
        receipt_id = "oareceipt_#{assertion_id.delete_prefix('oassert_')}"
        envelope = PolicyIssuance.build_envelope(
          candidate_policy: policy,
          parent_policy: nil,
          assertion_id: assertion_id,
          assertion_digest: pending_digest,
          provider_id: LocalProvider::AUTHORITY_PROVIDER_ID,
          receipt_id: receipt_id,
          issued_at: issued_at
        )
        document = {
          "schema_version" => "orbit-authority-assertion-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "assertion_id" => assertion_id,
          "issuer_kind" => "user",
          "issuer_subject" => @issuer_subject,
          "provider_id" => LocalProvider::AUTHORITY_PROVIDER_ID,
          "authority_scope_ref" => envelope["envelope_digest"],
          "grants" => ["policy.genesis"],
          "asserted_at" => issued_at,
          "policy_issuance_envelope" => envelope
        }
        document["assertion_digest"] = pending_digest
        document["verification_receipt"] = @authority.issue(
          document, receipt_id: receipt_id, issued_at: issued_at
        )
        [policy, document]
      end

      # -- assertions ---------------------------------------------------------

      def assertion(id, grants, subject = @issuer_subject, authority_scope_ref: nil)
        document = {
          "schema_version" => "orbit-authority-assertion-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "assertion_id" => id,
          "issuer_kind" => "user",
          "issuer_subject" => subject,
          "provider_id" => LocalProvider::AUTHORITY_PROVIDER_ID,
          "authority_scope_ref" => authority_scope_ref ||
            (grants.include?("policy.genesis") ? @project_id : @policy["policy_revision_id"]),
          "grants" => grants,
          "asserted_at" => stamp
        }
        document["assertion_digest"] = AuthorityVerifier.assertion_digest(document)
        document["verification_receipt"] = @authority.issue(
          document,
          receipt_id: "oareceipt_#{id.delete_prefix('oassert_')}",
          issued_at: document["asserted_at"]
        )
        document
      end

      # -- task definition ----------------------------------------------------

      # task_def: {goal, non_goals, acceptance, question, units:
      # [{objective, writable_paths}]}. One implementation WorkUnit per def
      # unit plus one auto evaluation unit carrying the independent review.
      def task_records(task_id:, task_def:)
        task_revision_id = new_id("trev_")
        gate_id = new_id("ogreq_")
        acceptance = [{
          "acceptance_id" => "acc_main0",
          "text" => Array(task_def["acceptance"]).first || "The task outcome satisfies its goal."
        }]
        requirements = [{
          "evidence_requirement_id" => "evreq_main",
          "text" => "Regression evidence covers the change.",
          "verification_class" => "regression"
        }]
        requirement_refs = requirements.map { |r| r["evidence_requirement_id"] }
        task = digested(
          "schema_version" => "orbit-task-v2",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "task_id" => task_id,
          "task_revision_id" => task_revision_id,
          "revision_number" => 1,
          "parent_task_revision_id" => nil,
          "project_policy_revision_ref" => policy_ref,
          "goal" => task_def.fetch("goal"),
          "non_goals" => Array(task_def["non_goals"]),
          "quality_outcome" => {
            "user_problem" => task_def.fetch("goal"),
            "desired_property" => "The change is reviewable and evidence-bound.",
            "measurable_thresholds" => ["The gate evaluation passes on current evidence."],
            "invalid_completions" => ["Unverified self-reported completion."]
          },
          "acceptance" => acceptance,
          "source_requirements" => [
            { "source_requirement_id" => "src_main", "text" => "Task definition supplied at start." }
          ],
          "evidence_requirements" => requirements,
          "task_questions" => [
            { "question_id" => "question_main",
              "text" => task_def["question"] || "Does the change satisfy the task goal?" }
          ],
          "gate_requirement_refs" => [gate_id],
          "authority_grant_refs" => [],
          "protected_change_authorization_ref" => nil,
          "unresolved_finding_refs" => []
        )
        gate = digested(
          "schema_version" => "orbit-gate-requirement-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "gate_requirement_id" => gate_id,
          "gate_lineage_id" => new_id("ogline_"),
          "parent_gate_requirement_ref" => nil,
          "task_id" => task_id,
          "task_revision_id" => task_revision_id,
          "kind" => "review",
          "protected" => true,
          "evidence_level" => "outcome_quality",
          "independence" => "independent_evaluator",
          "acceptance_refs" => ["acc_main0"],
          "required_question_refs" => ["question_main"],
          "subject_selector" => {
            "scope" => "task_wide",
            "work_unit_kind" => "implementation",
            "work_unit_refs" => [],
            "implementation_attempt_policy" => "all_accepted_contributors_to_snapshot",
            "evidence_record_policy" => "all_accepted_required_evidence_for_selected_attempts",
            "freshness" => "exact_current_subject"
          },
          "waiver_policy" => {
            "mode" => "finding_resolution_only",
            "required_authorization_action" => "finding.waive",
            "risk_authority_source" => "project_policy_or_task_authorization"
          }
        )
        impl_defs = Array(task_def.fetch("units"))
        raise ContractError.new("v2_cli_def_invalid", "task definition needs at least one unit",
          path: "task_def.units") if impl_defs.empty?

        specs = impl_defs.each_with_index.map do |unit_def, index|
          ["owu_impl#{index}_main", "implementation", unit_def]
        end
        specs << ["owu_review_main", "evaluation", { "objective" => "Independently evaluate the task subject." }]
        theses = specs.map do |unit_id, _kind, unit_def|
          digested(
            "schema_version" => "orbit-change-thesis-v1",
            "protocol_epoch" => "orbit-v2",
            "project_id" => @project_id,
            "change_thesis_id" => "othesis_#{unit_id.delete_prefix('owu_')}",
            "revision" => 1,
            "task_id" => task_id,
            "task_revision_id" => task_revision_id,
            "work_unit_id" => unit_id,
            "observed_problem" => unit_def["objective"],
            "root_cause_status" => "confirmed",
            "system_property" => "The change has one authoritative representation.",
            "smallest_sufficient_mechanism" => "Make the change explicit and evidence-bound.",
            "expected_benefit" => "The outcome is attributable and reviewable.",
            "introduced_cost" => "Explicit records for every controlled step.",
            "blast_radius" => Array(unit_def["writable_paths"]),
            "disconfirming_evidence" => ["A review counterexample against the change."]
          )
        end
        impl_ids = specs.take(impl_defs.length).map { |unit_id, _kind, _defn| unit_id }
        units = specs.map do |unit_id, kind, unit_def|
          thesis = theses.find { |t| t["work_unit_id"] == unit_id }
          digested(
            "schema_version" => "orbit-work-unit-v1",
            "protocol_epoch" => "orbit-v2",
            "project_id" => @project_id,
            "work_unit_id" => unit_id,
            "task_id" => task_id,
            "task_revision_id" => task_revision_id,
            "work_unit_kind" => kind,
            "parent_work_unit_ref" => unit_id == impl_ids.first ? nil : impl_ids.first,
            "depends_on_work_unit_refs" => kind == "evaluation" ? impl_ids : [],
            "objective" => unit_def["objective"],
            "scope" => unit_def["objective"],
            "authority_scope" => {
              "allowed_actions" => [kind == "evaluation" ? "gate.review.evaluate" : "work.implement"],
              "forbidden_actions" => ["task.goal.write", "gate.waive"],
              "authorization_record_refs" => [],
              "writable_paths" => Array(unit_def["writable_paths"])
            },
            "input_refs" => ["task-revision://#{task_revision_id}"],
            "output_refs" => ["work-unit-output://#{unit_id}"],
            "stop_conditions" => ["Stop when acceptance evidence is complete or authority is insufficient."],
            "acceptance_refs" => ["acc_main0"],
            "evidence_requirement_refs" => requirement_refs,
            "source_requirement_refs" => ["src_main"],
            "initial_change_thesis_ref" => ref("change_thesis_id",
              thesis["change_thesis_id"], thesis["content_digest"]).merge("revision" => 1)
          )
        end
        assertions = []
        authorizations = []
        units.each do |unit|
          Array(unit.dig("authority_scope", "allowed_actions")).each do |action|
            built = work_authorization(unit, task, action)
            assertions << built["assertion"]
            authorizations << built["record"]
          end
        end
        lead = digested(
          "schema_version" => "orbit-agent-runtime-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "object_type" => "logical_lead",
          "logical_lead_id" => new_id("olead_"),
          "task_id" => task_id,
          "authority_scope_ref" => @policy["policy_revision_id"],
          "durable_context_ref" => "artifact://#{@project_id}/lead-context"
        )
        [task, [gate], units, theses, assertions, authorizations, lead]
      end

      def work_authorization(unit, task, action)
        suffix = "#{unit.fetch('work_unit_id').delete_prefix('owu_')}_#{action.delete('.')}"
        scope = WorkAuthority.scope_digest(unit, task, action)
        authority_assertion = assertion("oassert_#{suffix}", [action], authority_scope_ref: scope)
        record = digested(
          "schema_version" => "orbit-authorization-record-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "authorization_record_id" => "oauthz_#{suffix}",
          "project_policy_revision_id" => task.dig("project_policy_revision_ref", "policy_revision_id"),
          "action" => action,
          "subject_ref" => scope,
          "authorization_source_ref" => authority_assertion.fetch("assertion_id"),
          "authorization_assertion_digest" => authority_assertion.fetch("assertion_digest")
        )
        unit.dig("authority_scope", "authorization_record_refs") << record["authorization_record_id"]
        unit["content_digest"] = CanonicalJSON.content_digest(unit)
        { "assertion" => authority_assertion, "record" => record }
      end

      # -- control genesis ------------------------------------------------------

      def control_genesis_records(task:, lead:, control_id:)
        agent = agent_document(new_id("oagent_"), "lead")
        session = {
          "schema_version" => "orbit-agent-runtime-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "object_type" => "lead_session",
          "lead_session_id" => new_id("oleadsession_"),
          "logical_lead_id" => lead["logical_lead_id"],
          "agent_instance_id" => agent["agent_instance_id"],
          "task_id" => task["task_id"],
          "task_revision_id" => task["task_revision_id"],
          "session_generation" => 1,
          "durable_context_ref" => lead["durable_context_ref"],
          "lead_control_id" => control_id,
          "lead_runtime_subject_ref" => agent.dig("runtime_identity", "runtime_subject_id"),
          "lead_runtime_subject_assertion_digest" =>
            digest_of(agent.dig("runtime_identity", "verification_receipt_ref")),
          "predecessor_lead_session_ref" => nil,
          "lifecycle_events" => [
            lifecycle_event("oevent_sessionstart_#{self.class.hex}", "LeadSessionStarted", nil,
              "role" => "lead", "context_generation" => 1,
              "started_at" => stamp, "status" => "active")
          ]
        }
        writer_assertion = assertion("oassert_#{control_id.delete_prefix('olcontrol_')}writer",
          %w[control.genesis control.checkpoint], "control-plane-writer",
          authority_scope_ref: control_id)
        genesis = lead_checkpoint(
          new_id("olcheckpoint_genesis_"),
          is_genesis: true, predecessor_ref: nil,
          session: session, agent: agent, logical_lead: lead, task: task,
          writer_action: "control.genesis", writer_assertion: writer_assertion,
          lead_control_id: control_id
        )
        registry = digested(
          "schema_version" => "orbit-lead-control-registry-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "object_type" => "lead_control_registry",
          "lead_control_id" => control_id,
          "genesis_checkpoint_ref" => ref("lead_checkpoint_id",
            genesis["lead_checkpoint_id"], genesis["content_digest"]),
          "writer_authority_provenance" => writer_provenance("control.genesis", writer_assertion),
          "owned_task_refs" => [task_ref(task)]
        )
        [registry, session, genesis, agent, writer_assertion]
      end

      def agent_document(id, role)
        profiles = {
          "lead" => { "capability" => "task.orchestrate", "permission" => "task_revision.propose" },
          "coder" => { "capability" => "coder.execute", "permission" => "work_unit.write" },
          "reviewer" => { "capability" => "review.evaluate", "permission" => "gate.review.submit" }
        }
        profile = profiles.fetch(role)
        runtime_subject_id = "runtime-subject:#{id}"
        {
          "schema_version" => "orbit-agent-runtime-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "object_type" => "agent_instance",
          "agent_instance_id" => id,
          "runtime_identity" => {
            "provider_id" => LocalProvider::RUNTIME_PROVIDER_ID,
            "runtime_subject_id" => runtime_subject_id,
            "verification_receipt_ref" => @runtime.issue(
              provider_id: LocalProvider::RUNTIME_PROVIDER_ID,
              project_id: @project_id,
              agent_instance_id: id,
              runtime_subject_id: runtime_subject_id
            )
          },
          "capability_profile" => {
            "profile_id" => "capability-profile:#{role}",
            "capabilities" => [profile.fetch("capability")]
          },
          "permission_profile" => {
            "profile_id" => "permission-profile:#{role}",
            "permissions" => [profile.fetch("permission")]
          },
          "lifecycle_events" => [
            lifecycle_event("oevent_agent_#{self.class.hex}", "AgentCreated", nil,
              "role" => role, "context_generation" => 1,
              "started_at" => stamp, "status" => "active")
          ]
        }
      end

      def lifecycle_event(id, type, previous_digest, fields)
        document = { "event_id" => id, "event_type" => type,
                     "previous_event_digest" => previous_digest }.merge(fields)
        document["recorded_at"] ||= document["started_at"] || document["ended_at"] || stamp
        document["event_digest"] = CanonicalJSON.digest_excluding(
          document, "event_digest", "writer_receipt", "created_at", "accepted_at", "envelope"
        )
        document["writer_receipt"] = @lifecycle.issue(document, project_id: @project_id)
        document
      end

      # -- checkpoints ------------------------------------------------------------

      def lead_checkpoint(id, is_genesis:, predecessor_ref:, session:, agent:, logical_lead:,
                          task:, writer_action:, writer_assertion:, lead_control_id:,
                          active_task_ref: nil, selected_work_unit_ref: nil, attempt_ref: nil,
                          task_queue: nil, unit: nil, proposed_thesis_ref: nil,
                          proposed_rule_ref: nil, predecessor_checkpoint: nil,
                          delivery: nil, assurance: nil, decision: nil,
                          reconcile_trigger: nil, next_trigger: nil)
        bindings = default_budget_bindings(lead_control_id,
          predecessor_checkpoint: predecessor_checkpoint,
          active_task_ref: active_task_ref,
          selected_work_unit_ref: selected_work_unit_ref)
        basis_task_ref = active_task_ref || task_ref(task)
        basis_unit_ref = selected_work_unit_ref || (unit && work_unit_ref(unit))
        plan_digest = ControlAuthority.effective_verification_plan_digest(
          policy_ref: policy_ref,
          task_revision_ref: basis_task_ref,
          assigned_rule_resolution_ref: proposed_rule_ref,
          effective_budget_bindings: bindings
        )
        closure_digest = ControlAuthority.closure_basis_digest(
          task_revision_ref: basis_task_ref,
          work_unit_ref: basis_unit_ref,
          change_thesis_ref: proposed_thesis_ref,
          assigned_rule_resolution_ref: proposed_rule_ref,
          effective_verification_plan_digest: plan_digest
        )
        delivery_progress = (delivery || checkpoint_progress("not_assessed")).merge(
          "predecessor_lead_checkpoint_ref" => predecessor_ref
        )
        proposal_refs = []
        if proposed_thesis_ref.is_a?(Hash)
          proposal_refs << { "kind" => "change_thesis", "id" => proposed_thesis_ref["change_thesis_id"],
                             "digest" => proposed_thesis_ref["content_digest"] }
        end
        if proposed_rule_ref.is_a?(Hash)
          proposal_refs << { "kind" => "rule_resolution", "id" => proposed_rule_ref["resolution_id"],
                             "digest" => proposed_rule_ref["identity_sha256"] }
        end
        unless proposal_refs.empty?
          delivery_progress = delivery_progress.merge(
            "supporting_refs" => Array(delivery_progress["supporting_refs"]) + proposal_refs
          )
        end
        digested(
          "schema_version" => "orbit-lead-checkpoint-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "object_type" => "lead_checkpoint",
          "lead_checkpoint_id" => id,
          "lead_control_id" => lead_control_id,
          "is_genesis" => is_genesis,
          "predecessor_lead_checkpoint_ref" => predecessor_ref,
          "project_policy_revision_ref" => policy_ref,
          "lead_agent_instance_ref" => { "agent_instance_id" => agent["agent_instance_id"] },
          "active_lead_session_ref" => session_ref(session),
          "lead_runtime_subject_ref" => session["lead_runtime_subject_ref"],
          "lead_runtime_subject_assertion_digest" => session["lead_runtime_subject_assertion_digest"],
          "logical_lead_refs" => [
            ref("logical_lead_id", logical_lead["logical_lead_id"], logical_lead["content_digest"])
          ],
          "task_queue" => task_queue || [task_ref(task)],
          "task_transfer_acquire" => nil,
          "active_task_ref" => active_task_ref,
          "selected_work_unit_ref" => selected_work_unit_ref,
          "current_or_terminal_attempt_ref" => attempt_ref,
          "assessments" => checkpoint_assessments(active_task_ref, selected_work_unit_ref, attempt_ref),
          "delivery_progress" => delivery_progress,
          "assurance_progress" => (assurance || checkpoint_progress("not_assessed")).merge(
            "predecessor_lead_checkpoint_ref" => predecessor_ref
          ),
          "effective_budget_bindings" => bindings,
          "budget_adjustment_digest" => nil,
          "test_budget_adjust" => nil,
          "effective_verification_plan_digest" => plan_digest,
          "closure_basis_digest" => closure_digest,
          "wall_clock_fallback" => nil,
          "checkpoint_due_observation_ref" => nil,
          "fingerprint_identity_basis" => nil,
          "fingerprint" => nil,
          "fingerprint_supporting_provenance" => nil,
          "retry_override_ref" => nil,
          "lead_decision" => decision || {
            "state" => "blocked", "action" => is_genesis ? "establish" : "continue",
            "reason" => is_genesis ? "control anchored" : "observation accepted"
          },
          "reconcile_trigger" => reconcile_trigger || {
            "event" => if is_genesis
                         "genesis"
                       elsif decision && decision["action"] == "dispatch"
                         "dispatch_before"
                       else
                         "attempt_terminal"
                       end,
            "reason" => "Decision trigger recorded for this checkpoint."
          },
          "next_trigger" => next_trigger || {
            "event" => if is_genesis
                         "dispatch_before"
                       elsif decision && decision["action"] == "dispatch"
                         "attempt_created"
                       else
                         "successor_before"
                       end,
            "reason" => "Awaiting the next control event."
          },
          "writer_authority_provenance" => writer_provenance(writer_action, writer_assertion)
        )
      end

      def default_budget_bindings(lead_control_id, predecessor_checkpoint: nil,
                                  active_task_ref: nil, selected_work_unit_ref: nil)
        ControlAuthority::BUDGET_SCOPES.map do |scope|
          predecessor_binding = predecessor_checkpoint &&
            Array(predecessor_checkpoint["effective_budget_bindings"]).find do |binding|
              binding["budget_scope_type"] == scope
            end
          ControlAuthority.derive_binding(
            scope: scope,
            project_id: @project_id,
            control_id: lead_control_id,
            policy: @policy,
            policy_ref: policy_ref,
            predecessor_binding: predecessor_binding,
            predecessor_checkpoint_ref: predecessor_checkpoint && cp_ref(predecessor_checkpoint),
            predecessor_work_unit_ref: predecessor_checkpoint &&
              (scope == "work_unit_lineage" ? predecessor_checkpoint["selected_work_unit_ref"] : nil),
            adjustment_payload: nil,
            adjustment_digest: nil,
            override_record: nil,
            override_mode: nil,
            origin_consuming_checkpoint_ref: nil,
            active_task_ref: active_task_ref,
            work_unit_ref: selected_work_unit_ref,
            measurements: unverified_pending_measurements
          )
        end
      end

      def unverified_pending_measurements
        assessment = {
          "lead_disposition" => "proceed_pending_independent_review",
          "lead_reason_code" => "Lead judgment: default dispatch proceeds pending independent review.",
          "lead_supporting_refs" => [],
          "review_status" => "pending",
          "review_gate_evaluation_ref" => nil
        }
        {
          "test_count" => { "status" => "unverified", "usage" => nil, "source_ref" => nil,
                            "unverified_assessment" => assessment },
          "test_code_lines" => { "status" => "unverified", "usage" => nil, "source_ref" => nil,
                                 "unverified_assessment" => assessment }
        }
      end

      def checkpoint_progress(change, measured = nil, substantive = [])
        {
          "change" => change,
          "rationale" => "Lead judgment recorded for the control checkpoint.",
          "measured_terminal_attempt_ref" => measured,
          "substantive_change_kinds" => substantive,
          "supporting_refs" => measured ? [
            { "kind" => "attempt_event", "id" => measured["attempt_id"],
              "event_id" => measured["event_id"], "digest" => measured["event_digest"] }
          ] : []
        }
      end

      def checkpoint_assessments(active_task_ref, selected_work_unit_ref, attempt_ref)
        layer = lambda do |basis, status|
          { "status" => status, "rationale" => "Layer assessed against its exact basis projection.",
            "basis_projection" => basis, "supporting_refs" => [] }
        end
        {
          "task_queue" => layer.call("task_queue", "ok"),
          "active_mainline" => layer.call("active_task_ref", active_task_ref ? "ok" : "none"),
          "work_graph_branches" => layer.call("selected_work_unit_ref", selected_work_unit_ref ? "ok" : "none"),
          "current_attempt" => layer.call("current_or_terminal_attempt_ref", attempt_ref ? "ok" : "none")
        }
      end

      def observation_checkpoint(dispatch, attempt, resolution:, observation_assertion:)
        observation = deep_copy(dispatch)
        observation["lead_checkpoint_id"] = new_id("olcheckpoint_created_")
        observation["predecessor_lead_checkpoint_ref"] = cp_ref(dispatch)
        observation["current_or_terminal_attempt_ref"] = attempt_event_ref([attempt], attempt["attempt_id"], 0)
        observation["assessments"] = checkpoint_assessments(
          observation["active_task_ref"], observation["selected_work_unit_ref"],
          observation["current_or_terminal_attempt_ref"]
        )
        predecessor = observation["predecessor_lead_checkpoint_ref"]
        %w[delivery_progress assurance_progress].each do |field|
          observation[field] = checkpoint_progress("not_assessed")
            .merge("predecessor_lead_checkpoint_ref" => predecessor)
        end
        observation["effective_budget_bindings"] = default_budget_bindings(
          observation["lead_control_id"],
          predecessor_checkpoint: dispatch,
          active_task_ref: observation["active_task_ref"],
          selected_work_unit_ref: observation["selected_work_unit_ref"]
        )
        observation["budget_adjustment_digest"] = nil
        observation["test_budget_adjust"] = nil
        observation["fingerprint_identity_basis"] = nil
        observation["fingerprint"] = nil
        observation["fingerprint_supporting_provenance"] = nil
        observation["retry_override_ref"] = nil
        rule_ref = pinned_rule_ref(attempt, resolution)
        observation["effective_verification_plan_digest"] =
          ControlAuthority.effective_verification_plan_digest(
            policy_ref: observation["project_policy_revision_ref"],
            task_revision_ref: observation["active_task_ref"],
            assigned_rule_resolution_ref: rule_ref,
            effective_budget_bindings: observation["effective_budget_bindings"]
          )
        observation["closure_basis_digest"] =
          ControlAuthority.closure_basis_digest(
            task_revision_ref: observation["active_task_ref"],
            work_unit_ref: observation["selected_work_unit_ref"],
            change_thesis_ref: attempt.dig("events", 0, "assignment", "change_thesis_ref"),
            assigned_rule_resolution_ref: rule_ref,
            effective_verification_plan_digest: observation["effective_verification_plan_digest"]
          )
        observation["lead_decision"] = {
          "state" => "blocked", "action" => "continue", "reason" => "attempt creation observed"
        }
        observation["reconcile_trigger"] = { "event" => "attempt_created", "reason" => "Observing AttemptCreated." }
        observation["next_trigger"] = { "event" => "attempt_terminal", "reason" => "Awaiting the Attempt terminal event." }
        observation["writer_authority_provenance"] = writer_provenance("control.checkpoint", observation_assertion)
        digested(observation)
      end

      # -- execution / terminal ---------------------------------------------------

      def rule_identity(unit, attempt_id, worker, role, rule_paths)
        {
          "identity_schema" => "orbit-rule-resolution-identity-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "task_id" => unit["task_id"],
          "task_revision_id" => unit["task_revision_id"],
          "work_unit_id" => unit["work_unit_id"],
          "attempt_id" => attempt_id,
          "resolved_role" => role,
          "agent_instance_id" => worker["agent_instance_id"],
          "context_generation" => 1,
          "required_rules" => rule_paths.map do |path|
            {
              "rule_id" => File.basename(path, ".*"),
              "path" => path,
              "content_sha256" =>
                "sha256:#{Digest::SHA256.file(File.join(@project_root, path)).hexdigest}",
              "relation" => "baseline"
            }
          end
        }
      end

      def build_resolution(identity)
        RuleResolution.build(deep_copy(identity), created_at: stamp, project_root: @project_root)
      end

      def attempt_document(id:, unit:, worker:, role:, purpose:, thesis:, resolution_id:,
                           control_id:, predecessor_ref: nil, started_at:, dispatch_ref: nil)
        assignment = {
          "agent_instance_id" => worker["agent_instance_id"],
          "context_generation" => 1,
          "resolved_role" => role,
          "purpose" => purpose,
          "authority_snapshot" => {
            "project_policy_revision_ref" => policy_ref,
            "authorization_record_refs" => deep_copy(unit.dig("authority_scope", "authorization_record_refs"))
          },
          "change_thesis_ref" => ref("change_thesis_id",
            thesis["change_thesis_id"], thesis["content_digest"]).merge("revision" => thesis["revision"]),
          "assigned_rule_resolution_id" => resolution_id
        }
        creation = lifecycle_event("oevent_#{id.delete_prefix('oattempt_')}_created", "AttemptCreated", nil,
          "assignment" => assignment, "started_at" => started_at, "status" => "active")
        {
          "schema_version" => "orbit-agent-runtime-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "object_type" => "work_unit_attempt",
          "attempt_id" => id,
          "lead_control_id" => control_id,
          "predecessor_work_unit_attempt_ref" => predecessor_ref,
          "dispatch_lead_checkpoint_ref" => dispatch_ref,
          "task_id" => unit["task_id"],
          "task_revision_id" => unit["task_revision_id"],
          "work_unit_id" => unit["work_unit_id"],
          "events" => [creation]
        }
      end

      def execution_records(task:, unit:, thesis:, lead:, control_records:, rule_paths:,
                            role: "coder", purpose: "implementation")
        control_id = control_records[0]["lead_control_id"]
        attempt_id = new_id("oattempt_")
        worker = agent_document(new_id("oagent_"), role)
        resolution = build_resolution(rule_identity(unit, attempt_id, worker, role, rule_paths))
        attempt = attempt_document(id: attempt_id, unit: unit, worker: worker, role: role,
          purpose: purpose, thesis: thesis, resolution_id: resolution["resolution_id"],
          control_id: control_id, started_at: stamp)
        dispatch_assertion = assertion("oassert_#{attempt_id.delete_prefix('oattempt_')}dispatch",
          %w[control.checkpoint], "control-plane-writer", authority_scope_ref: control_id)
        dispatch = lead_checkpoint(
          new_id("olcheckpoint_dispatch_"), is_genesis: false,
          predecessor_ref: cp_ref(control_records[2]),
          predecessor_checkpoint: control_records[2],
          session: control_records[1], agent: control_records[3], logical_lead: lead,
          task: task, writer_action: "control.checkpoint", writer_assertion: dispatch_assertion,
          lead_control_id: control_id, active_task_ref: task_ref(task),
          selected_work_unit_ref: work_unit_ref(unit), unit: unit,
          proposed_thesis_ref: { "change_thesis_id" => thesis["change_thesis_id"],
                                 "content_digest" => thesis["content_digest"] },
          proposed_rule_ref: pinned_rule_ref(attempt, resolution),
          decision: DISPATCH_DECISION)
        attempt["dispatch_lead_checkpoint_ref"] = cp_ref(dispatch)
        observation_assertion = assertion("oassert_#{attempt_id.delete_prefix('oattempt_')}observation",
          %w[control.checkpoint], "control-plane-writer", authority_scope_ref: control_id)
        observation = observation_checkpoint(dispatch, attempt,
          resolution: resolution, observation_assertion: observation_assertion)
        [resolution, dispatch, dispatch_assertion, attempt, worker, observation, observation_assertion]
      end

      def terminal_records(task:, unit:, thesis:, lead:, control_records:, execution:, rule_paths:,
                           role:, purpose:, event_type: "AttemptCompleted")
        control_id = control_records[0]["lead_control_id"]
        stored = execution[3]
        ended_at = stamp
        terminal_event = lifecycle_event(
          "oevent_#{stored['attempt_id'].delete_prefix('oattempt_')}_#{event_type.downcase}",
          event_type, stored.dig("events", -1, "event_digest"),
          "ended_at" => ended_at,
          "status" => { "AttemptCompleted" => "completed", "AttemptFailed" => "failed",
                        "AttemptBlocked" => "blocked", "AttemptCancelled" => "cancelled",
                        "AttemptSuperseded" => "superseded" }.fetch(event_type)
        )
        attempt = deep_copy(stored)
        attempt["events"] = stored["events"] + [terminal_event]
        terminal_assertion = assertion("oassert_#{stored['attempt_id'].delete_prefix('oattempt_')}terminal",
          %w[control.checkpoint], "control-plane-writer", authority_scope_ref: control_id)
        successor_id = new_id("oattempt_")
        worker = agent_document(new_id("oagent_"), role)
        successor_resolution = build_resolution(
          rule_identity(unit, successor_id, worker, role, rule_paths)
        )
        same_unit = unit["work_unit_id"] == stored["work_unit_id"]
        successor = attempt_document(id: successor_id, unit: unit, worker: worker, role: role,
          purpose: purpose, thesis: thesis,
          resolution_id: successor_resolution["resolution_id"], control_id: control_id,
          predecessor_ref: same_unit ? stored["attempt_id"] : nil,
          started_at: stamp)
        checkpoint = lead_checkpoint(
          new_id("olcheckpoint_terminal_"), is_genesis: false,
          predecessor_ref: cp_ref(execution[5]),
          predecessor_checkpoint: execution[5],
          session: control_records[1], agent: control_records[3], logical_lead: lead,
          task: task, writer_action: "control.checkpoint", writer_assertion: terminal_assertion,
          lead_control_id: control_id, active_task_ref: task_ref(task),
          selected_work_unit_ref: work_unit_ref(unit), unit: unit,
          attempt_ref: attempt_event_ref([attempt], attempt["attempt_id"], -1),
          proposed_thesis_ref: { "change_thesis_id" => thesis["change_thesis_id"],
                                 "content_digest" => thesis["content_digest"] },
          proposed_rule_ref: pinned_rule_ref(successor, successor_resolution),
          decision: DISPATCH_DECISION,
          reconcile_trigger: { "event" => "attempt_terminal",
                               "reason" => "Terminal observation authorizes the successor dispatch." },
          next_trigger: { "event" => "attempt_created",
                          "reason" => "Awaiting the successor AttemptCreated observation." })
        successor["dispatch_lead_checkpoint_ref"] = cp_ref(checkpoint)
        observation_assertion = assertion("oassert_#{successor_id.delete_prefix('oattempt_')}observation",
          %w[control.checkpoint], "control-plane-writer", authority_scope_ref: control_id)
        successor_observation = observation_checkpoint(checkpoint, successor,
          resolution: successor_resolution, observation_assertion: observation_assertion)
        [attempt, checkpoint, terminal_assertion, successor, worker, successor_resolution,
         successor_observation, observation_assertion]
      end

      # -- evidence -----------------------------------------------------------------

      def implementation_evidence(id:, attempt:, resolution:, paths:)
        change_claim = {
          "artifact_ref" => "artifact://#{id}/change", "artifact_kind" => "change",
          "content_digest" => digest_of("#{id}:change:#{paths.sort.join(':')}"),
          "paths" => paths.sort
        }
        verification_claim = {
          "artifact_ref" => "artifact://#{id}/verification", "artifact_kind" => "verification",
          "content_digest" => digest_of("#{id}:verification:regression"),
          "paths" => []
        }
        change_ref = { "artifact_ref" => change_claim["artifact_ref"],
                       "content_digest" => change_claim["content_digest"] }
        verification_ref = { "artifact_ref" => verification_claim["artifact_ref"],
                             "content_digest" => verification_claim["content_digest"] }
        digested(
          "schema_version" => "orbit-evidence-v2",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "evidence_record_id" => id,
          "record_kind" => "implementation",
          "task_id" => attempt["task_id"],
          "task_revision_id" => attempt["task_revision_id"],
          "work_unit_id" => attempt["work_unit_id"],
          "attempt_id" => attempt["attempt_id"],
          "submitted_rule_resolution_id" => resolution["resolution_id"],
          "accepted" => true,
          "acceptance_recorded_at" => nil,
          "implementation_check" => {
            "change_thesis_ref" => attempt.dig("events", 0, "assignment", "change_thesis_ref"),
            "scope_match" => { "status" => "pass", "evidence_refs" => [change_ref] },
            "acceptance_results" => [
              { "acceptance_id" => "acc_main0", "status" => "pass", "evidence_refs" => [verification_ref] }
            ],
            "evidence_requirement_results" => [
              { "evidence_requirement_id" => "evreq_main", "verification_use" => "permanent_test_evidence",
                "status" => "pass", "evidence_refs" => [verification_ref] }
            ],
            "change_thesis_status" => { "status" => "supported", "evidence_refs" => [change_ref] },
            "changed_paths" => paths,
            "verification_refs" => [verification_ref],
            "assumptions_changed" => [],
            "known_gaps" => []
          },
          "submission_artifact_refs" => [change_claim, verification_claim],
          "supersedes_evidence_record_id" => nil
        )
      end

      def evaluator_submission(id:, attempt:, resolution:)
        report_claim = {
          "artifact_ref" => "artifact://#{id}/report", "artifact_kind" => "report",
          "content_digest" => digest_of("#{id}:review-report"),
          "paths" => []
        }
        digested(
          "schema_version" => "orbit-evidence-v2",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "evidence_record_id" => id,
          "record_kind" => "evaluator_submission",
          "task_id" => attempt["task_id"],
          "task_revision_id" => attempt["task_revision_id"],
          "work_unit_id" => attempt["work_unit_id"],
          "attempt_id" => attempt["attempt_id"],
          "submitted_rule_resolution_id" => resolution["resolution_id"],
          "accepted" => true,
          "acceptance_recorded_at" => nil,
          "submission_artifact_refs" => [report_claim],
          "supersedes_evidence_record_id" => nil
        )
      end

      # -- gate evaluation ------------------------------------------------------------

      def evaluation_records(gate:, task:, units:, attempts:, evidence_records:, snapshot:,
                             code_surface:, evaluator_attempt:, submission_id:, defn:)
        subject = EvaluationSubject.select(
          gate_requirement: gate, task_revision: task, work_units: units,
          attempts: attempts, evidence_records: evidence_records,
          repository_snapshot: snapshot, code_surface: code_surface
        )
        evidence_ids = subject["evidence_record_refs"].map { |r| r["evidence_record_id"] }
        verdict = defn.fetch("verdict", "pass")
        quality = defn.fetch("quality_verdict", verdict)
        answers = [{ "question_id" => "question_main",
                     "verdict" => defn.dig("answers", "question_main") || "pass",
                     "evidence_record_refs" => evidence_ids }]
        acceptance = [{ "acceptance_id" => "acc_main0",
                        "verdict" => defn.dig("acceptance", "acc_main0") || "pass",
                        "evidence_record_refs" => evidence_ids }]
        findings = Array(defn["findings"]).map do |finding_def|
          digested(
            "schema_version" => "orbit-finding-v1",
            "protocol_epoch" => "orbit-v2",
            "project_id" => @project_id,
            "finding_id" => new_id("ofinding_"),
            "gate_evaluation_id" => nil,
            "severity" => finding_def["severity"] || "P1",
            "basis" => finding_def["basis"] || "regression",
            "body" => finding_def.fetch("body"),
            "source_evidence_record_refs" => evidence_ids,
            "supersedes_finding_id" => nil
          )
        end
        evaluation = digested(
          "schema_version" => "orbit-gate-evaluation-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "gate_evaluation_id" => new_id("ogeval_"),
          "gate_requirement_id" => gate["gate_requirement_id"],
          "gate_requirement_content_digest" => gate["content_digest"],
          "evaluator_attempt_id" => evaluator_attempt["attempt_id"],
          "evaluator_submission_record_id" => submission_id,
          "subject" => subject,
          "verdict" => verdict,
          "quality_outcome_verdict" => quality,
          "quality_question_answers" => answers,
          "acceptance_results" => acceptance,
          "counterexample_cases" => Array(defn["counterexamples"]),
          "confirmed" => ["The selected subject is complete."],
          "assumed" => [],
          "missing" => [],
          "coverage" => {
            "summary" => "All implementation WorkUnits and evidence records were evaluated.",
            "covered_work_unit_refs" => subject["work_unit_refs"].map { |r| r["work_unit_id"] },
            "uncovered_work_unit_refs" => [],
            "evidence_record_refs" => evidence_ids
          },
          "residual_risk" => defn["residual_risk"] || "None recorded.",
          "finding_refs" => findings.map { |f| f["finding_id"] },
          "supersedes_gate_evaluation_id" => defn["supersedes"]
        )
        findings.each do |finding|
          finding["gate_evaluation_id"] = evaluation["gate_evaluation_id"]
          finding["content_digest"] = CanonicalJSON.content_digest(finding)
        end
        [evaluation, findings]
      end

      def resolution_record(finding:, source_evaluation:, resolving_evaluation:, issuer_attempt:,
                            submission_id:, proposal_evidence_id:)
        digested(
          "schema_version" => "orbit-finding-resolution-v1",
          "protocol_epoch" => "orbit-v2",
          "project_id" => @project_id,
          "finding_resolution_id" => new_id("ofres_"),
          "finding_id" => finding["finding_id"],
          "resolution" => "addressed",
          "issuer_attempt_id" => issuer_attempt["attempt_id"],
          "issuer_submission_record_id" => submission_id,
          "source_finding_ref" => ref("finding_id", finding["finding_id"], finding["content_digest"]),
          "source_gate_evaluation_ref" => ref("gate_evaluation_id",
            source_evaluation["gate_evaluation_id"], source_evaluation["content_digest"]),
          "resolving_gate_evaluation_ref" => ref("gate_evaluation_id",
            resolving_evaluation["gate_evaluation_id"], resolving_evaluation["content_digest"]),
          "proposal_evidence_record_id" => proposal_evidence_id,
          "supporting_record_refs" => [proposal_evidence_id],
          "supersedes_finding_resolution_id" => nil
        )
      end

      # -- repository snapshot ----------------------------------------------------------

      # Deterministic git snapshot identity: real git values when available,
      # otherwise a stable digest over the sorted working tree (excluding
      # .orbit). Cross-run consistency is the only hard requirement
      # (evidence exact-binding); nothing validates it against live git.
      def self.repository_snapshot(project_root)
        root = File.realpath(project_root)
        git_commit = nil
        IO.popen(["git", "-C", root, "rev-parse", "HEAD"], err: File::NULL) do |io|
          git_commit = io.read.to_s.strip
        end
        if git_commit.to_s.match?(/\A[0-9a-f]{40}\z/)
          listing = IO.popen(["git", "-C", root, "ls-tree", "-r", "--full-tree", "HEAD"], err: File::NULL, &:read)
          tree_digest = "sha256:#{Digest::SHA256.hexdigest(listing.to_s)}"
          commit_sha = git_commit
        else
          paths = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
            .map { |path| path.delete_prefix("#{root}/") }
            .reject { |path| path.start_with?(".orbit/") || path.end_with?("/.") || path == "." }
            .sort
          commit_sha = "0" * 40
          tree_digest = "sha256:#{Digest::SHA256.hexdigest(paths.join("\n"))}"
        end
        { "kind" => "git", "commit_sha" => commit_sha, "tree_digest" => tree_digest }
      end

      # -- shared helpers -----------------------------------------------------------------

      def policy_ref
        ref("policy_revision_id", @policy["policy_revision_id"], @policy["content_digest"])
      end

      def task_ref(task)
        ref("task_id", task["task_id"], task["content_digest"])
          .merge("task_revision_id" => task["task_revision_id"])
      end

      def work_unit_ref(unit)
        ref("work_unit_id", unit["work_unit_id"], unit["content_digest"])
      end

      def cp_ref(checkpoint)
        checkpoint.slice("lead_checkpoint_id", "content_digest")
      end

      def session_ref(session)
        session.slice("lead_session_id", "session_generation")
      end

      def attempt_event_ref(attempts, attempt_id, index = -1)
        attempt = attempts.find { |candidate| candidate["attempt_id"] == attempt_id }
        event = attempt.fetch("events")[index]
        { "attempt_id" => attempt_id, "event_id" => event["event_id"],
          "event_digest" => event["event_digest"] }
      end

      def pinned_rule_ref(attempt, resolution)
        return nil unless resolution.is_a?(Hash)

        { "resolution_id" => resolution["resolution_id"],
          "identity_sha256" => resolution["identity_sha256"] }
      end

      def writer_provenance(action, assertion_document)
        {
          "policy_revision_ref" => policy_ref,
          "action" => action,
          "assertion_ref" => {
            "assertion_id" => assertion_document["assertion_id"],
            "assertion_digest" => assertion_document["assertion_digest"]
          }
        }
      end

      def ref(id_key, id, digest)
        { id_key => id, "content_digest" => digest }
      end

      def digest_of(value)
        "sha256:#{Digest::SHA256.hexdigest(value)}"
      end

      def digested(document)
        document.merge("content_digest" => CanonicalJSON.content_digest(document))
      end

      def deep_copy(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end
