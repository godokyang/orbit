# frozen_string_literal: true

require_relative "aggregate_outcome"
require_relative "canonical_json"
require_relative "control_authority"
require_relative "errors"
require_relative "projection_primitives"

module Orbit
  module V2
    # Slice 5 increment 4: the agent-independent digest and two-layer budget
    # projection.
    #
    # One pure derived seam: BudgetProjection.derive(bundle, validator:)
    # reads validated authoritative facts through the shared
    # projection-validation boundary and emits one canonical view per
    # accepted LeadCheckpoint. Each view projects
    # `budget_adjustment_digest` (iff the checkpoint carries the current
    # typed adjustment), `effective_verification_plan_digest`, and
    # `closure_basis_digest`, all recomputed byte-identical through the
    # ControlAuthority canonical functions from the checkpoint's exact
    # authority sources — no new hashing rule, no persisted plan truth
    # object, no second fact source.
    #
    # The two cumulative budget scopes project in fixed order
    # (work_unit_lineage, then task_lineage) straight from each checkpoint's
    # canonical `effective_budget_bindings`; bindings are cumulative
    # snapshots and are never summed across checkpoints. Verified
    # measurements expose deterministic within/over status vs the binding's
    # effective ceilings; unverified measurements expose
    # unverified_pending/accepted/rejected per the existing review-status
    # semantics and are never zero or within-budget.
    #
    # Every view carries its exact source refs+digests and a source digest,
    # so deletion/recomputation is byte-identical and any source mutation
    # either changes the view or fails closed at the boundary. Timestamps
    # and array order never participate.
    module BudgetProjection
      module_function

      SCHEMA_VERSION = "orbit-budget-projection-v1"
      PROTOCOL_EPOCH = "orbit-v2"
      BUDGET_SCOPES = %w[work_unit_lineage task_lineage].freeze
      METRICS = %w[test_count test_code_lines].freeze
      REVIEW_STATUS = {
        "pending" => "unverified_pending",
        "accepted" => "unverified_accepted",
        "rejected" => "unverified_rejected"
      }.freeze

      def derive(bundle, validator:)
        AggregateOutcome.validate_projection_input!(
          bundle,
          validator: validator,
          seam: "budget projection"
        )
        project(bundle)
      rescue KeyError, TypeError, ArgumentError => e
        raise ContractError.new("budget_projection_invalid", e.message)
      end

      def project(bundle)
        project_id = bundle.fetch("protocol_root").fetch("project_id")
        artifacts = index(bundle, "rule_resolution_artifacts", "resolution_id")
        attempts = index(bundle, "work_unit_attempts", "attempt_id")
        thesis_digests = {}
        Array(bundle["change_theses"]).each do |thesis|
          next unless thesis.is_a?(Hash)

          (thesis_digests[thesis["change_thesis_id"]] ||= []) << thesis["content_digest"]
        end
        views = Array(bundle["lead_checkpoints"]).select { |checkpoint| checkpoint.is_a?(Hash) }
                  .map do |checkpoint|
          project_checkpoint(bundle, checkpoint, artifacts, attempts, thesis_digests)
        end.sort_by { |view| view["lead_checkpoint_ref"]["lead_checkpoint_id"] }
        document = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => project_id,
          "checkpoint_views" => views
        }
        document.merge(
          "content_digest" => CanonicalJSON.digest_excluding(document, "content_digest")
        )
      end
      private_class_method :project

      def project_checkpoint(bundle, checkpoint, artifacts, attempts, thesis_digests)
        bindings = Array(checkpoint["effective_budget_bindings"])
        scope_bindings = bindings.select do |binding|
          binding.is_a?(Hash) && BUDGET_SCOPES.include?(binding["budget_scope_type"])
        end
        unless scope_bindings.length == 2 &&
               scope_bindings.map { |binding| binding["budget_scope_type"] }.uniq.length == 2
          raise ContractError.new(
            "budget_projection_invalid",
            "effective_budget_bindings must contain exactly the two fixed scopes",
            path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}.effective_budget_bindings"
          )
        end
        policy_ref = checkpoint["project_policy_revision_ref"]
        task_ref = checkpoint["active_task_ref"]
        task_ref ||= Array(checkpoint["task_queue"]).first
        unless policy_ref.is_a?(Hash) && task_ref.is_a?(Hash)
          raise ContractError.new(
            "budget_projection_invalid",
            "checkpoint must pin exact policy and task basis refs",
            path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
          )
        end
        rule_ref = ProjectionPrimitives.basis_rule_ref(checkpoint, artifacts, attempts)
        plan = ControlAuthority.effective_verification_plan_digest(
          policy_ref: policy_ref,
          task_revision_ref: task_ref,
          assigned_rule_resolution_ref: rule_ref,
          effective_budget_bindings: bindings
        )
        thesis_ref = ProjectionPrimitives.basis_thesis_ref(checkpoint, attempts, thesis_digests)
        basis = ControlAuthority.closure_basis_digest(
          task_revision_ref: task_ref,
          work_unit_ref: checkpoint["selected_work_unit_ref"],
          change_thesis_ref: thesis_ref,
          assigned_rule_resolution_ref: rule_ref,
          effective_verification_plan_digest: plan
        )
        unless checkpoint["effective_verification_plan_digest"] == plan &&
               checkpoint["closure_basis_digest"] == basis
          raise ContractError.new(
            "budget_projection_invalid",
            "checkpoint digest recomputation is not byte-identical",
            path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
          )
        end
        adjustment = checkpoint["test_budget_adjust"]
        adjustment_digest = checkpoint["budget_adjustment_digest"]
        if adjustment.is_a?(Hash)
          unless adjustment_digest.is_a?(String) &&
                 adjustment_digest == ControlAuthority.budget_adjustment_digest(adjustment)
            raise ContractError.new(
              "budget_projection_invalid",
              "budget_adjustment_digest must equal the canonical digest of the typed adjust payload",
              path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}.budget_adjustment_digest"
            )
          end
        elsif adjustment_digest.is_a?(String)
          raise ContractError.new(
            "budget_projection_invalid",
            "budget_adjustment_digest must be explicitly absent when no adjustment exists",
            path: "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}.budget_adjustment_digest"
          )
        end

        source_refs = {
          "project_policy_revision_ref" => policy_ref,
          "task_revision_ref" => task_ref,
          "selected_work_unit_ref" => checkpoint["selected_work_unit_ref"],
          "change_thesis_ref" => thesis_ref,
          "assigned_rule_resolution_ref" => rule_ref
        }
        manifest = view_source_manifest(bundle, checkpoint, scope_bindings, source_refs)
        view = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => checkpoint["project_id"],
          "lead_checkpoint_ref" => {
            "lead_checkpoint_id" => checkpoint["lead_checkpoint_id"],
            "content_digest" => checkpoint["content_digest"]
          },
          "budget_scopes" => BUDGET_SCOPES.map do |scope|
            project_scope(scope, scope_bindings.find { |binding| binding["budget_scope_type"] == scope })
          end,
          "source_refs" => source_refs,
          "source_manifest" => manifest,
          "source_digest" => "sha256:#{CanonicalJSON.sha256(manifest)}"
        }
        view["budget_adjustment_digest"] = adjustment_digest if adjustment_digest.is_a?(String)
        view["effective_verification_plan_digest"] = plan
        view["closure_basis_digest"] = basis
        view["content_digest"] = CanonicalJSON.digest_excluding(view, "content_digest")
        view
      end
      private_class_method :project_checkpoint

      def project_scope(scope, binding)
        measurements = binding["measurements"]
        unless measurements.is_a?(Hash)
          raise ContractError.new(
            "budget_projection_invalid",
            "budget binding measurements must be an object",
            path: "budget_scopes.#{scope}.measurements"
          )
        end
        {
          "budget_scope_type" => scope,
          "binding_digest" => ControlAuthority.binding_digest(binding),
          "effective_test_count" => binding["effective_test_count"],
          "effective_test_code_lines" => binding["effective_test_code_lines"],
          "measurements" => METRICS.map do |metric|
            measurement = measurements[metric]
            unless measurement.is_a?(Hash)
              raise ContractError.new(
                "budget_projection_invalid",
                "budget binding measurement is missing",
                path: "budget_scopes.#{scope}.measurements.#{metric}"
              )
            end
            project_measurement(binding, metric, measurement)
          end
        }
      end
      private_class_method :project_scope

      def project_measurement(binding, metric, measurement)
        row = { "metric" => metric }
        if measurement["status"] == "verified"
          usage = measurement["usage"]
          unless usage.is_a?(Integer) && usage >= 0
            raise ContractError.new(
              "budget_projection_invalid",
              "verified measurement usage must be a non-negative integer",
              path: "measurements.#{metric}.usage"
            )
          end
          effective = metric == "test_count" ? binding["effective_test_count"] : binding["effective_test_code_lines"]
          row["verified"] = true
          row["usage"] = usage
          row["budget_status"] = usage > effective ? "over" : "within"
          row["source_ref"] = measurement["source_ref"]
        elsif measurement["status"] == "unverified"
          review_status = measurement.dig("unverified_assessment", "review_status")
          status = REVIEW_STATUS[review_status]
          unless status
            raise ContractError.new(
              "budget_projection_invalid",
              "unverified measurement has no closed review status",
              path: "measurements.#{metric}.unverified_assessment.review_status"
            )
          end
          row["verified"] = false
          row["budget_status"] = status
          review_ref = measurement.dig("unverified_assessment", "review_gate_evaluation_ref")
          row["review_gate_evaluation_ref"] = review_ref if review_ref.is_a?(Hash)
        else
          raise ContractError.new(
            "budget_projection_invalid",
            "measurement status must be verified or unverified",
            path: "measurements.#{metric}.status"
          )
        end
        row
      end
      private_class_method :project_measurement

      # The complete canonical source closure of one checkpoint view: the
      # exact checkpoint ref+digest, both ordered binding digests, every
      # binding's external authority (measurement attestations, unverified
      # assessment supporting/review refs, adjustment and override
      # provenance), and the basis refs. A legitimate source change always
      # changes the manifest and therefore source_digest.
      def view_source_manifest(bundle, checkpoint, scope_bindings, source_refs)
        entries = []
        entries << manifest_entry(
          "lead_checkpoint",
          checkpoint["lead_checkpoint_id"],
          checkpoint["content_digest"]
        )
        entries << manifest_entry("project_policy_revision", source_refs["project_policy_revision_ref"]["policy_revision_id"], source_refs["project_policy_revision_ref"]["content_digest"])
        entries << manifest_entry("task_revision", source_refs["task_revision_ref"]["task_revision_id"], source_refs["task_revision_ref"]["content_digest"])
        unit_ref = source_refs["selected_work_unit_ref"]
        entries << manifest_entry("work_unit", unit_ref["work_unit_id"], unit_ref["content_digest"]) if unit_ref.is_a?(Hash)
        thesis_ref = source_refs["change_thesis_ref"]
        if thesis_ref.is_a?(Hash)
          revision = thesis_ref["revision"]
          unless revision.is_a?(Integer)
            thesis = Array(bundle["change_theses"]).select do |candidate|
              candidate.is_a?(Hash) &&
                candidate["change_thesis_id"] == thesis_ref["change_thesis_id"] &&
                candidate["content_digest"] == thesis_ref["content_digest"]
            end.min_by { |candidate| candidate["revision"] }
            revision = thesis && thesis["revision"]
          end
          unless revision.is_a?(Integer)
            raise ContractError.new(
              "budget_projection_invalid",
              "change thesis basis ref does not resolve to an exact revision",
              path: "source_manifest"
            )
          end
          entries << manifest_entry(
            "change_thesis",
            "#{thesis_ref["change_thesis_id"]}@#{revision}",
            thesis_ref["content_digest"]
          )
        end
        rule_ref = source_refs["assigned_rule_resolution_ref"]
        entries << manifest_entry("rule_resolution_artifact", rule_ref["resolution_id"], rule_ref["identity_sha256"]) if rule_ref.is_a?(Hash)

        scope_bindings.each do |binding|
          scope = binding["budget_scope_type"]
          entries << manifest_entry("budget_binding", scope, ControlAuthority.binding_digest(binding))
          adjustment_source = binding["lead_adjustment_source"]
          if adjustment_source.is_a?(Hash) && adjustment_source["adjustment_digest"].is_a?(String)
            entries << manifest_entry("budget_adjustment", scope, adjustment_source["adjustment_digest"])
          end
          if adjustment_source.is_a?(Hash) && adjustment_source["inherited_checkpoint_ref"].is_a?(Hash)
            entries << manifest_entry(
              "lead_checkpoint",
              adjustment_source["inherited_checkpoint_ref"]["lead_checkpoint_id"],
              adjustment_source["inherited_checkpoint_ref"]["content_digest"]
            )
          end
          override_source = binding["user_override_source"]
          if override_source.is_a?(Hash) && override_source["authorization_record_ref"].is_a?(Hash)
            entries << manifest_entry(
              "authorization_record",
              override_source["authorization_record_ref"]["authorization_record_id"],
              override_source["authorization_record_ref"]["content_digest"]
            )
          end
          if override_source.is_a?(Hash) && override_source["origin_consuming_checkpoint_ref"].is_a?(Hash)
            entries << manifest_entry(
              "lead_checkpoint",
              override_source["origin_consuming_checkpoint_ref"]["lead_checkpoint_id"],
              override_source["origin_consuming_checkpoint_ref"]["content_digest"]
            )
          end
          measurements = binding["measurements"]
          next unless measurements.is_a?(Hash)

          METRICS.each do |metric|
            measurement = measurements[metric]
            next unless measurement.is_a?(Hash)

            if measurement["status"] == "verified" && measurement["source_ref"].is_a?(Hash)
              entries << manifest_entry(
                measurement["source_ref"]["kind"],
                measurement["source_ref"]["id"],
                measurement["source_ref"]["digest"]
              )
            elsif measurement["status"] == "unverified"
              Array(measurement.dig("unverified_assessment", "lead_supporting_refs")).each do |ref|
                entry = supporting_manifest_entry(ref)
                entries << entry if entry
              end
              review_ref = measurement.dig("unverified_assessment", "review_gate_evaluation_ref")
              if review_ref.is_a?(Hash)
                entries << manifest_entry("gate_evaluation", review_ref["gate_evaluation_id"], review_ref["content_digest"])
              end
            end
          end
        end

        adjustment = checkpoint["test_budget_adjust"]
        if adjustment.is_a?(Hash)
          predecessor_ref = adjustment["predecessor_lead_checkpoint_ref"]
          entries << manifest_entry("lead_checkpoint", predecessor_ref["lead_checkpoint_id"], predecessor_ref["content_digest"]) if predecessor_ref.is_a?(Hash)
          if adjustment["predecessor_binding_digest"].is_a?(String)
            entries << manifest_entry(
              "budget_binding_predecessor",
              adjustment["budget_scope_type"],
              adjustment["predecessor_binding_digest"]
            )
          end
          Array(adjustment["supporting_refs"]).each do |ref|
            entry = supporting_manifest_entry(ref)
            entries << entry if entry
          end
        end

        seen = {}
        entries.each do |entry|
          key = [entry["kind"], entry["id"]]
          existing = seen[key]
          if existing
            unless existing["content_digest"] == entry["content_digest"]
              raise ContractError.new(
                "budget_projection_invalid",
                "source manifest contains a conflicting (kind, id)",
                path: "source_manifest"
              )
            end
            next
          end
          seen[key] = entry
        end
        seen.values.sort_by { |entry| [entry["kind"], entry["id"]] }
      end
      private_class_method :view_source_manifest

      def manifest_entry(kind, id, content_digest)
        { "kind" => kind, "id" => id, "content_digest" => content_digest }
      end
      private_class_method :manifest_entry

      # One manifest identity rule for EVERY SupportingRef source (adjustment
      # payload and unverified-assessment lead_supporting_refs): event kinds
      # keep owner::event_id so two distinct events from one owner never
      # collide and one event is never misidentified as the whole owner;
      # other kinds retain their object id. The digest stays exact.
      def supporting_manifest_entry(ref)
        return nil unless ref.is_a?(Hash) && ref["id"].is_a?(String) && ref["digest"].is_a?(String)

        id = %w[attempt_event agent_event].include?(ref["kind"]) ?
          "#{ref["id"]}::#{ref["event_id"]}" : ref["id"]
        manifest_entry(ref["kind"], id, ref["digest"])
      end
      private_class_method :supporting_manifest_entry

      def index(bundle, collection, id_field)
        result = {}
        Array(bundle[collection]).each do |document|
          next unless document.is_a?(Hash)

          id = document[id_field]
          next if id.nil?

          if result.key?(id)
            raise ContractError.new(
              "budget_projection_invalid",
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
