# frozen_string_literal: true

require "time"

require_relative "canonical_json"

module Orbit
  module V2
    # Slice 2 increment 4: the deterministic authority seams of the control
    # loop that may never be written by agents or free text.
    #
    # - fingerprint identity: the ONLY hash input is `fingerprint_identity_basis`
    #   (canonicalization version + TaskRevision/WorkUnit scope + typed
    #   category/code + stable Finding identity OR stable test/rule/check
    #   identity + stable signal subject + normalized failure code). Attempt/
    #   checkpoint/session/AgentInstance/outcome record identities, digests,
    #   ordering, message wording and paths never enter the hash domain.
    # - task.retry.override / test.budget.override / control.fallback.authorize:
    #   provider-verified create-only AuthorizationRecord scope digests.
    # - the one-way digest chain:
    #   budget_adjustment_digest (iff present) -> complete ordered
    #   effective_budget_bindings -> effective_verification_plan_digest ->
    #   closure_basis_digest. No preimage ever contains the enclosing
    #   checkpoint ID/content digest (no self-reference) and no measurement
    #   tuple travels inside an authorization fact.
    #
    # This module only hashes and derives; it does not validate bundles and
    # does not know about LeadCheckpoint identity. Both the controlled writer
    # path (fixtures) and the Validator recompute through the same functions,
    # so any stored digest is always re-checked byte-identical.
    module ControlAuthority
      module_function

      FINGERPRINT_CANONICALIZATION_VERSION = "orbit-fingerprint-v1"
      RETRY_OVERRIDE_ACTION = "task.retry.override"
      BUDGET_OVERRIDE_ACTION = "test.budget.override"
      FALLBACK_AUTHORIZE_ACTION = "control.fallback.authorize"
      CHECKPOINT_DUE_OBSERVE_ACTION = "control.checkpoint_due.observe"
      MEASUREMENT_ATTEST_ACTION = "test.measurement.attest"
      BUDGET_SCOPES = %w[work_unit_lineage task_lineage].freeze
      BUDGET_REVIEW_RESULT_FIELDS = %w[
        review_status lead_disposition review_gate_evaluation_ref
      ].freeze
      FINGERPRINT_CATEGORIES = %w[finding test rule check].freeze

      # The canonical budget review subject projection: the assessed binding's
      # canonical bytes with ONLY the three review-result fields excluded.
      # The pending and reviewed bindings differ exactly in those fields, so
      # the projection is the byte-for-byte freshness identity — the complete
      # binding digest (which includes the review fields) is never a
      # freshness basis.
      def budget_review_subject_projection(binding)
        projected = Marshal.load(Marshal.dump(binding))
        measurements = projected.is_a?(Hash) ? projected["measurements"] : nil
        if measurements.is_a?(Hash)
          measurements.each_value do |measurement|
            assessment = measurement.is_a?(Hash) ? measurement["unverified_assessment"] : nil
            next unless assessment.is_a?(Hash)

            BUDGET_REVIEW_RESULT_FIELDS.each { |field| assessment.delete(field) }
          end
        end
        projected
      end

      # The single Slice 4 typed exception: exactly one deterministic
      # current->inherited transition of the assessed adjustment source.
      # Predecessor mode=current, successor mode=inherited, the same
      # adjustment digest, inherited_checkpoint_ref exactly equal to the
      # assessed predecessor ref; every other byte stays equal (the three
      # review-result fields aside). Shared by the deterministic replay
      # (LeadControl) and the trigger/consumption proofs (Validator).
      def exact_budget_review_transition?(binding, predecessor_binding, predecessor_ref)
        return false unless binding.is_a?(Hash) &&
                            predecessor_binding.is_a?(Hash) &&
                            predecessor_ref.is_a?(Hash)

        current_source = binding["lead_adjustment_source"]
        predecessor_source = predecessor_binding["lead_adjustment_source"]
        return false unless current_source.is_a?(Hash) && predecessor_source.is_a?(Hash)
        return false unless predecessor_source["mode"] == "current" &&
                            current_source["mode"] == "inherited" &&
                            current_source["adjustment_digest"] ==
                              predecessor_source["adjustment_digest"] &&
                            current_source["inherited_checkpoint_ref"] == predecessor_ref

        projected = budget_review_subject_projection(predecessor_binding)
        projected["lead_adjustment_source"] = current_source
        budget_review_subject_projection(binding) == projected
      end

      # The exact accepted review consumption basis: at least one unverified
      # metric; every unverified metric accepted against the SAME exact
      # review ref; every other metric verified with the canonical nil
      # assessment. Returns [statuses, refs] or nil.
      def accepted_unverified_review_consumption(measurements)
        return nil unless measurements.is_a?(Hash)

        unverified = measurements.select do |_key, metric|
          metric.is_a?(Hash) && metric["status"] == "unverified"
        end
        verified = measurements.select do |_key, metric|
          metric.is_a?(Hash) && metric["status"] == "verified"
        end
        return nil unless unverified.any? &&
                            unverified.length + verified.length == measurements.length
        return nil unless verified.values.all? do |metric|
          metric["unverified_assessment"].nil?
        end

        statuses = unverified.values.map do |metric|
          metric.dig("unverified_assessment", "review_status")
        end
        refs = unverified.values.map do |metric|
          metric.dig("unverified_assessment", "review_gate_evaluation_ref")
        end
        return nil unless statuses.all? { |status| status == "accepted" }
        return nil unless refs.uniq.length == 1 && refs.first.is_a?(Hash)

        [statuses, refs]
      end
      def budget_review_subject_projection_digest(binding)
        "sha256:#{CanonicalJSON.sha256(budget_review_subject_projection(binding))}"
      end
      # ---------------------------------------------------------------- fingerprint

      def fingerprint_digest(identity_basis)
        "sha256:#{CanonicalJSON.sha256(identity_basis)}"
      end

      def retry_override_scope_digest(
        project_id:, task_ref:, work_unit_ref:, fingerprint:,
        prior_attempt_chain:, authorizing_checkpoint_ref:, lead_control_id:
      )
        "sha256:#{CanonicalJSON.sha256(
          "scope_schema" => "orbit-task-retry-override-scope-v1",
          "project_id" => project_id,
          "task_ref" => task_ref,
          "work_unit_ref" => work_unit_ref,
          "fingerprint" => fingerprint,
          "prior_attempt_chain" => prior_attempt_chain,
          "authorizing_checkpoint_ref" => authorizing_checkpoint_ref,
          "lead_control_id" => lead_control_id
        )}"
      end

      # ---------------------------------------------------------------- budget

      def budget_adjustment_digest(payload)
        "sha256:#{CanonicalJSON.sha256(payload)}"
      end

      def budget_override_scope_digest(
        budget_scope_type:, project_id:, policy_ref:, task_ref:, work_unit_ref:,
        authorizing_checkpoint_ref:, predecessor_binding_digest:,
        effective_test_count:, effective_test_code_lines:, lead_control_id:
      )
        "sha256:#{CanonicalJSON.sha256(
          "scope_schema" => "orbit-test-budget-override-scope-v1",
          "budget_scope_type" => budget_scope_type,
          "project_id" => project_id,
          "project_policy_revision_ref" => policy_ref,
          "task_ref" => task_ref,
          "work_unit_ref" => work_unit_ref,
          "authorizing_checkpoint_ref" => authorizing_checkpoint_ref,
          "predecessor_binding_digest" => predecessor_binding_digest,
          "effective_test_count" => effective_test_count,
          "effective_test_code_lines" => effective_test_code_lines,
          "lead_control_id" => lead_control_id
        )}"
      end

      # The wall-clock deadline is never free text: it is deterministically
      # derived from a trusted provider-recorded lifecycle event (the exact
      # schedule basis) plus the exact policy/record interval. Both the
      # controlled writer and the Validator compute through this function, so
      # any self-reported deadline fails closed.
      def fallback_deadline(recorded_at:, interval_seconds:)
        unless interval_seconds.is_a?(Integer) && interval_seconds >= 1
          raise ArgumentError, "fallback interval must be a finite positive integer"
        end

        (Time.iso8601(recorded_at) + interval_seconds).iso8601
      rescue ArgumentError, TypeError
        raise ArgumentError, "fallback schedule basis recorded_at must be a valid ISO-8601 instant"
      end

      def fallback_scope_digest(
        project_id:, policy_ref:, lead_control_id:, interval_seconds:, upper_bound_seconds:
      )
        "sha256:#{CanonicalJSON.sha256(
          "scope_schema" => "orbit-control-fallback-scope-v1",
          "project_id" => project_id,
          "project_policy_revision_ref" => policy_ref,
          "lead_control_id" => lead_control_id,
          "interval_seconds" => interval_seconds,
          "upper_bound_seconds" => upper_bound_seconds
        )}"
      end

      # The timer occurrence proof: a provider-verified AuthorityAssertion
      # with the typed control.checkpoint_due.observe grant, exactly binding
      # project, active policy, control, the scheduled checkpoint ref+digest,
      # the derived deadline and the observed_at instant. asserted_at and the
      # receipt issued_at must equal observed_at; an ordinary lifecycle event
      # never proves the timer fired.
      def checkpoint_due_scope_digest(
        project_id:, policy_ref:, lead_control_id:, scheduled_checkpoint_ref:,
        deadline:, observed_at:
      )
        "sha256:#{CanonicalJSON.sha256(
          "scope_schema" => "orbit-checkpoint-due-observation-scope-v1",
          "project_id" => project_id,
          "project_policy_revision_ref" => policy_ref,
          "lead_control_id" => lead_control_id,
          "scheduled_checkpoint_ref" => scheduled_checkpoint_ref,
          "deadline" => deadline,
          "observed_at" => observed_at
        )}"
      end

      # Verified test-budget usage is never self-reported: each metric has
      # its own provider-verified test.measurement.attest assertion exactly
      # binding project, active policy, TaskRevision, the exact WorkUnit
      # (work_unit_lineage) or canonical null (task_lineage), the metric
      # identity, the usage and the repository snapshot ref+digest. One
      # assertion can never prove both metrics or both scopes.
      def measurement_scope_digest(
        project_id:, policy_ref:, task_ref:, work_unit_ref:, metric_identity:,
        usage:, snapshot_ref:
      )
        "sha256:#{CanonicalJSON.sha256(
          "scope_schema" => "orbit-test-measurement-attestation-scope-v1",
          "project_id" => project_id,
          "project_policy_revision_ref" => policy_ref,
          "task_revision_ref" => task_ref,
          "work_unit_ref" => work_unit_ref,
          "metric_identity" => metric_identity,
          "usage" => usage,
          "repository_snapshot_ref" => snapshot_ref
        )}"
      end

      # ---------------------------------------------------------------- derived digests

      # The deterministic one-way chain. The complete ordered
      # effective_budget_bindings are the ONLY budget input; a separate
      # adjustment digest never enters the plan preimage. No plan truth
      # object exists: only this derived digest.
      def effective_verification_plan_digest(
        policy_ref:, task_revision_ref:, assigned_rule_resolution_ref:,
        effective_budget_bindings:
      )
        "sha256:#{CanonicalJSON.sha256(
          "derivation_schema" => "orbit-effective-verification-plan-v1",
          "project_policy_revision_ref" => policy_ref,
          "task_revision_ref" => task_revision_ref,
          "assigned_rule_resolution_ref" => assigned_rule_resolution_ref,
          "effective_budget_bindings" => effective_budget_bindings
        )}"
      end

      # Frozen at every accepted checkpoint from dispatch-time exact refs and
      # digests; the derived plan digest is a one-way input (closure_basis
      # never enters the plan hash domain). Attempt/agent/session identity,
      # time and conversation content never enter.
      def closure_basis_digest(
        task_revision_ref:, work_unit_ref:, change_thesis_ref:,
        assigned_rule_resolution_ref:, effective_verification_plan_digest:
      )
        "sha256:#{CanonicalJSON.sha256(
          "derivation_schema" => "orbit-closure-basis-v1",
          "task_revision_ref" => task_revision_ref,
          "work_unit_ref" => work_unit_ref,
          "change_thesis_ref" => change_thesis_ref,
          "assigned_rule_resolution_ref" => assigned_rule_resolution_ref,
          "effective_verification_plan_digest" => effective_verification_plan_digest
        )}"
      end

      # ---------------------------------------------------------------- bindings

      def binding_digest(binding)
        CanonicalJSON.content_digest(binding)
      end

      # Canonical derivation of ONE effective budget binding from the
      # authoritative facts of its checkpoint. The source authority is
      # exclusive per binding: user_override > current lead_adjustment >
      # inherited lead_adjustment > policy_default. Mixing source fields,
      # scope mismatch, missing predecessor facts, an out-of-ceiling
      # adjustment, or an override whose scope does not exact bind the
      # predecessor checkpoint/binding, project, policy, task, unit, control
      # and ceilings all fail closed (ArgumentError). Measurements are the
      # binding's own current observation and are passed through untouched:
      # authorization facts never carry them.
      def derive_binding(
        scope:, project_id:, control_id:, policy:, policy_ref:,
        predecessor_binding:, predecessor_checkpoint_ref:,
        predecessor_work_unit_ref: nil,
        adjustment_payload:, adjustment_digest:, override_record:,
        override_mode:, origin_consuming_checkpoint_ref:,
        active_task_ref:, work_unit_ref:, measurements:
      )
        budget = policy && policy.dig("orchestration_policy", "test_budget", scope)
        raise ArgumentError, "policy budget defaults are missing for scope #{scope}" unless budget

        if override_record
          derive_override_binding(
            scope, project_id, control_id, policy_ref, budget,
            predecessor_binding, predecessor_checkpoint_ref,
            override_record, override_mode, origin_consuming_checkpoint_ref,
            active_task_ref, work_unit_ref, measurements
          )
        elsif adjustment_payload
          derive_adjustment_binding(
            scope, project_id, control_id, policy_ref, budget, policy,
            predecessor_binding, predecessor_checkpoint_ref,
            adjustment_payload, adjustment_digest, measurements
          )
        elsif inherited_lead_adjustment?(predecessor_binding, predecessor_checkpoint_ref) &&
              predecessor_work_unit_ref == work_unit_ref
          # The work_unit_lineage adjustment continues only while the
          # checkpoint still selects the SAME WorkUnit: a selection change
          # starts a fresh lineage whose binding derives from the policy
          # default (never inheriting another unit's adjustment).
          inherited_source = {
            "mode" => "inherited",
            "adjustment_digest" => predecessor_binding.dig("lead_adjustment_source", "adjustment_digest"),
            "inherited_checkpoint_ref" => predecessor_checkpoint_ref
          }
          {
            "budget_scope_type" => scope,
            "project_policy_revision_ref" => policy_ref,
            "source_kind" => "lead_adjustment",
            "lead_adjustment_source" => inherited_source,
            "user_override_source" => nil,
            "effective_test_count" => predecessor_binding["effective_test_count"],
            "effective_test_code_lines" => predecessor_binding["effective_test_code_lines"],
            "measurements" => measurements
          }
        else
          {
            "budget_scope_type" => scope,
            "project_policy_revision_ref" => policy_ref,
            "source_kind" => "policy_default",
            "lead_adjustment_source" => nil,
            "user_override_source" => nil,
            "effective_test_count" => budget["default_test_count"],
            "effective_test_code_lines" => budget["default_test_code_lines"],
            "measurements" => measurements
          }
        end
      end

      def inherited_lead_adjustment?(predecessor_binding, predecessor_checkpoint_ref)
        predecessor_binding.is_a?(Hash) &&
          predecessor_binding["source_kind"] == "lead_adjustment" &&
          predecessor_checkpoint_ref.is_a?(Hash) &&
          predecessor_binding.dig("lead_adjustment_source", "adjustment_digest").is_a?(String)
      end

      def derive_override_binding(
        scope, project_id, control_id, policy_ref, _budget,
        predecessor_binding, predecessor_checkpoint_ref,
        override_record, override_mode, origin_consuming_checkpoint_ref,
        active_task_ref, work_unit_ref, measurements
      )
        raise ArgumentError, "user_override source requires mode consume or inherit" unless %w[consume inherit].include?(override_mode)

        envelope = override_record["budget_override_envelope"]
        raise ArgumentError, "test.budget.override record lacks its typed envelope" unless envelope.is_a?(Hash)
        raise ArgumentError, "test.budget.override record action mismatch" unless override_record["action"] == BUDGET_OVERRIDE_ACTION

        unless envelope["budget_scope_type"] == scope &&
               envelope["project_id"] == project_id &&
               envelope["project_policy_revision_ref"] == policy_ref &&
               envelope["task_ref"] == active_task_ref &&
               envelope["work_unit_ref"] == work_unit_ref &&
               envelope["lead_control_id"] == control_id &&
               envelope["effective_test_count"].is_a?(Integer) &&
               envelope["effective_test_code_lines"].is_a?(Integer)
          raise ArgumentError,
                "test.budget.override scope must exact bind project/policy/task/#{scope}/ceilings/control"
        end

        if override_mode == "consume"
          # Consume is valid only at the first consuming checkpoint: its
          # exact predecessor must be the record's authorizing checkpoint and
          # its predecessor binding digest the record's frozen binding digest
          # (the record never carries the measurement tuple).
          authorizing_ref = predecessor_checkpoint_ref
          expected_scope = budget_override_scope_digest(
            budget_scope_type: scope,
            project_id: project_id,
            policy_ref: policy_ref,
            task_ref: active_task_ref,
            work_unit_ref: work_unit_ref,
            authorizing_checkpoint_ref: authorizing_ref,
            predecessor_binding_digest: predecessor_binding && binding_digest(predecessor_binding),
            effective_test_count: envelope["effective_test_count"],
            effective_test_code_lines: envelope["effective_test_code_lines"],
            lead_control_id: control_id
          )
          unless envelope["scope_digest"] == expected_scope &&
                 override_record["subject_ref"] == expected_scope &&
                 envelope["authorizing_checkpoint_ref"] == authorizing_ref &&
                 envelope["predecessor_binding_digest"] ==
                   (predecessor_binding && binding_digest(predecessor_binding))
            raise ArgumentError,
                  "test.budget.override consume must exact bind the authorizing predecessor checkpoint and binding"
          end
        else
          # Inherit never re-derives the origin-bound scope digest: it must
          # pin the exact origin consuming checkpoint of the same continuous
          # lineage and keep the original record's effective ceilings.
          raise ArgumentError, "inherit mode requires the exact origin consuming checkpoint ref" unless origin_consuming_checkpoint_ref.is_a?(Hash)
        end

        {
          "budget_scope_type" => scope,
          "project_policy_revision_ref" => policy_ref,
          "source_kind" => "user_override",
          "lead_adjustment_source" => nil,
          "user_override_source" => {
            "mode" => override_mode,
            "authorization_record_ref" => {
              "authorization_record_id" => override_record["authorization_record_id"],
              "content_digest" => override_record["content_digest"]
            },
            "origin_consuming_checkpoint_ref" => origin_consuming_checkpoint_ref
          },
          "effective_test_count" => envelope["effective_test_count"],
          "effective_test_code_lines" => envelope["effective_test_code_lines"],
          "measurements" => measurements
        }
      end

      def derive_adjustment_binding(
        scope, project_id, control_id, policy_ref, budget, policy,
        predecessor_binding, predecessor_checkpoint_ref,
        payload, adjustment_digest, measurements
      )
        raise ArgumentError, "adjust payload scope mismatch" unless payload["budget_scope_type"] == scope
        raise ArgumentError, "adjust payload policy ref must pin the exact active policy" unless payload["project_policy_revision_ref"] == policy_ref
        raise ArgumentError, "adjust payload must bind the exact predecessor checkpoint ref" unless payload["predecessor_lead_checkpoint_ref"] == predecessor_checkpoint_ref
        raise ArgumentError, "adjust payload must bind the predecessor effective-budget-binding digest" unless payload["predecessor_binding_digest"] == (predecessor_binding && binding_digest(predecessor_binding))
        raise ArgumentError, "adjust old_effective_budget must equal the predecessor binding effective ceilings" unless payload["old_effective_budget"] == effective_ceiling(predecessor_binding)
        raise ArgumentError, "budget_adjustment_digest must equal the canonical payload digest" unless adjustment_digest == budget_adjustment_digest(payload)

        lead_ceiling = {
          "test_count" => budget["lead_ceiling_test_count"],
          "test_code_lines" => budget["lead_ceiling_test_code_lines"]
        }
        requested = payload["new_effective_budget"] || {}
        raise ArgumentError, "adjust requested ceilings must be non-negative integers" unless
          requested["test_count"].is_a?(Integer) && requested["test_count"] >= 0 &&
          requested["test_code_lines"].is_a?(Integer) && requested["test_code_lines"] >= 0
        raise ArgumentError, "adjust requested ceilings must stay within the policy lead ceiling for #{scope}" unless
          requested["test_count"] <= lead_ceiling["test_count"] &&
          requested["test_code_lines"] <= lead_ceiling["test_code_lines"]

        {
          "budget_scope_type" => scope,
          "project_policy_revision_ref" => policy_ref,
          "source_kind" => "lead_adjustment",
          "lead_adjustment_source" => {
            "mode" => "current",
            "adjustment_digest" => adjustment_digest,
            "inherited_checkpoint_ref" => nil
          },
          "user_override_source" => nil,
          "effective_test_count" => requested["test_count"],
          "effective_test_code_lines" => requested["test_code_lines"],
          "measurements" => measurements
        }
      end

      def effective_ceiling(binding)
        binding && {
          "test_count" => binding["effective_test_count"],
          "test_code_lines" => binding["effective_test_code_lines"]
        }
      end
    end
  end
end
