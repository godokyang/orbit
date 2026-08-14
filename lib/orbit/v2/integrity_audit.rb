# frozen_string_literal: true

require_relative "aggregate_outcome"
require_relative "canonical_json"
require_relative "errors"
require_relative "evaluation_subject"
require_relative "path_scope"
require_relative "projection_primitives"

module Orbit
  module V2
    # Slice 5 increment 6: the pure structural integrity/drift audit
    # projection.
    #
    # IntegrityAudit.derive(bundle, validator:) reads validated authoritative
    # facts through the shared projection-validation boundary (including the
    # exact historical `.subject` staleness allowance) and emits four
    # mechanically frozen sections: drifted GateEvaluations (stored subject
    # no longer equals the current canonical selector result), orphaned
    # CodeSurface paths (no segment-aware overlap with any accepted WorkUnit
    # writable authority), stale implementation EvidenceRecords (pinned
    # ChangeThesis revision is not the accepted lineage tip), and unresolved
    # Findings (no current valid FindingResolution lineage tip) with their
    # active-policy-derived disposition. It writes nothing, owns no audit
    # truth, performs no scoring, free-text judgment, or filesystem reads,
    # and is not a second validator — every other schema/authority/
    # provenance/independence error fails closed at the shared boundary.
    #
    # Output is canonical, sorted, and order-independent with
    # schema_version/protocol_epoch/project_id, the four sections, the
    # complete shared bundle source_manifest, source_digest, and
    # content_digest; deletion/rebuild is byte-identical and any source
    # change invalidates the digests.
    module IntegrityAudit
      module_function

      SCHEMA_VERSION = "orbit-integrity-audit-v1"
      PROTOCOL_EPOCH = "orbit-v2"
      DISPOSITIONS = %w[blocking adjudication_required nonblocking].freeze

      def derive(bundle, validator:)
        AggregateOutcome.validate_projection_input!(
          bundle,
          validator: validator,
          seam: "integrity audit"
        )
        project(bundle)
      rescue KeyError, TypeError, ArgumentError => e
        raise ContractError.new("integrity_audit_invalid", e.message)
      end

      def project(bundle)
        manifest = ProjectionPrimitives.bundle_source_manifest(
          bundle,
          error_code: "integrity_audit_invalid"
        )
        document = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => bundle.fetch("protocol_root").fetch("project_id"),
          "drifted_gate_evaluations" => drifted_gate_evaluations(bundle),
          "orphan_code_surface_paths" => orphan_code_surface_paths(bundle),
          "stale_evidence_records" => stale_evidence_records(bundle),
          "unresolved_findings" => unresolved_findings(bundle),
          "source_manifest" => manifest,
          "source_digest" => "sha256:#{CanonicalJSON.sha256(manifest)}"
        }
        document.merge(
          "content_digest" => CanonicalJSON.digest_excluding(document, "content_digest")
        )
      end
      private_class_method :project

      # Every stored GateEvaluation whose exact current GateRequirement
      # selector recomputes a different canonical EvaluationSubject. Current
      # evaluations are absent; stale GateRequirement digest or stale
      # active-policy authority remain invalid at the shared boundary and
      # never reach this section.
      def drifted_gate_evaluations(bundle)
        requirements = index(bundle, "gate_requirements", "gate_requirement_id")
        tasks = index(bundle, "task_revisions", "task_revision_id")
        units = Array(bundle["work_units"])
        attempts = Array(bundle["work_unit_attempts"])
        records = Array(bundle["evidence_records"])
        snapshot = bundle["repository_snapshot"]
        code_surface = bundle["code_surface"]
        Array(bundle["gate_evaluations"]).select { |evaluation| evaluation.is_a?(Hash) }.map do |evaluation|
          requirement = requirements[evaluation["gate_requirement_id"]]
          unless requirement.is_a?(Hash)
            raise ContractError.new(
              "integrity_audit_invalid",
              "gate evaluation requirement does not exist",
              path: "gate_evaluations.#{evaluation["gate_evaluation_id"]}"
            )
          end
          task = tasks[requirement["task_revision_id"]]
          unless task.is_a?(Hash)
            raise ContractError.new(
              "integrity_audit_invalid",
              "gate evaluation requirement task revision does not exist",
              path: "gate_evaluations.#{evaluation["gate_evaluation_id"]}"
            )
          end
          expected = EvaluationSubject.select(
            gate_requirement: requirement,
            task_revision: task,
            work_units: units,
            attempts: attempts,
            evidence_records: records,
            repository_snapshot: snapshot,
            code_surface: code_surface
          )
          next nil if ProjectionPrimitives.evaluation_current?(
            evaluation,
            requirement: requirement,
            expected_subject: expected
          )

          {
            "gate_evaluation_ref" => {
              "gate_evaluation_id" => evaluation["gate_evaluation_id"],
              "content_digest" => evaluation["content_digest"]
            },
            "stored_subject_digest" => evaluation.dig("subject", "subject_digest"),
            "current_subject_digest" => expected["subject_digest"]
          }
        end.compact.sort_by { |entry| entry["gate_evaluation_ref"]["gate_evaluation_id"] }
      end
      private_class_method :drifted_gate_evaluations

      # A canonical CodeSurface path is orphaned when no accepted WorkUnit
      # writable scope has segment-aware overlap with it (surface covers the
      # writable path or the writable path covers the surface). Audit-only:
      # an otherwise valid extra surface path is reported, never rejected.
      def orphan_code_surface_paths(bundle)
        surface = bundle["code_surface"]
        paths = surface.is_a?(Hash) ? Array(surface["paths"]) : []
        writable = Array(bundle["work_units"]).flat_map do |unit|
          Array(unit.dig("authority_scope", "writable_paths"))
        end
        paths.select do |path|
          writable.none? do |scope|
            PathScope.covered?(path, scope) || PathScope.covered?(scope, path)
          end
        end.sort
      end
      private_class_method :orphan_code_surface_paths

      # Only implementation EvidenceRecords participate. A record is stale
      # when its exact implementation_check.change_thesis_ref pins a
      # non-tip revision of its accepted ChangeThesis lineage (the tip is
      # the highest contiguous accepted revision, validator-guaranteed).
      # Evaluator submissions are never mislabeled stale. No timestamps or
      # array order participate.
      def stale_evidence_records(bundle)
        theses = Array(bundle["change_theses"]).select { |thesis| thesis.is_a?(Hash) }
        tip_by_id = {}
        theses.group_by { |thesis| thesis["change_thesis_id"] }.each do |thesis_id, lineage|
          tip_by_id[thesis_id] = lineage.max_by { |thesis| thesis["revision"] }
        end
        Array(bundle["evidence_records"]).select do |record|
          record.is_a?(Hash) && record["record_kind"] == "implementation"
        end.map do |record|
          stored_ref = record.dig("implementation_check", "change_thesis_ref")
          unless stored_ref.is_a?(Hash) && stored_ref["change_thesis_id"].is_a?(String)
            raise ContractError.new(
              "integrity_audit_invalid",
              "implementation evidence lacks an exact change thesis ref",
              path: "evidence_records.#{record["evidence_record_id"]}.implementation_check.change_thesis_ref"
            )
          end
          tip = tip_by_id[stored_ref["change_thesis_id"]]
          unless tip.is_a?(Hash)
            raise ContractError.new(
              "integrity_audit_invalid",
              "evidence change thesis ref does not resolve to an accepted lineage",
              path: "evidence_records.#{record["evidence_record_id"]}.implementation_check.change_thesis_ref"
            )
          end
          next nil if tip["revision"] == stored_ref["revision"]

          {
            "evidence_record_ref" => {
              "evidence_record_id" => record["evidence_record_id"],
              "content_digest" => record["content_digest"]
            },
            "stored_change_thesis_ref" => stored_ref,
            "current_change_thesis_ref" => {
              "change_thesis_id" => tip["change_thesis_id"],
              "content_digest" => tip["content_digest"],
              "revision" => tip["revision"]
            }
          }
        end.compact.sort_by { |entry| entry["evidence_record_ref"]["evidence_record_id"] }
      end
      private_class_method :stale_evidence_records

      # Every accepted Finding with no current valid FindingResolution
      # lineage tip, including nonblocking hardening findings, with the
      # active-policy-derived disposition. A valid resolution tip removes
      # it; disposition never comes from severity or free text.
      def unresolved_findings(bundle)
        tasks = index(bundle, "task_revisions", "task_revision_id")
        policies = index(bundle, "project_policy_revisions", "policy_revision_id")
        evaluations = index(bundle, "gate_evaluations", "gate_evaluation_id")
        requirements = index(bundle, "gate_requirements", "gate_requirement_id")
        resolutions = Array(bundle["finding_resolutions"]).select { |resolution| resolution.is_a?(Hash) }
        Array(bundle["findings"]).select { |finding| finding.is_a?(Hash) }.map do |finding|
          lineage = ProjectionPrimitives.finding_lineage(
            finding,
            evaluations: evaluations,
            requirements: requirements,
            tasks: tasks
          )
          unless lineage.is_a?(Hash)
            raise ContractError.new(
              "integrity_audit_invalid",
              "finding lineage does not resolve",
              path: "findings.#{finding["finding_id"]}"
            )
          end
          task = tasks[lineage["task_revision_id"]]
          policy_ref = task.is_a?(Hash) ? task["project_policy_revision_ref"] : nil
          policy = policy_ref.is_a?(Hash) ? policies[policy_ref["policy_revision_id"]] : nil
          disposition = ProjectionPrimitives.finding_disposition(finding, policy)
          unless DISPOSITIONS.include?(disposition)
            raise ContractError.new(
              "integrity_audit_invalid",
              "finding disposition is not a closed active-policy value",
              path: "findings.#{finding["finding_id"]}"
            )
          end
          matching = resolutions.select do |resolution|
            resolution["finding_id"] == finding["finding_id"]
          end
          analysis = ProjectionPrimitives.supersedes_tips(
            matching,
            id_key: "finding_resolution_id",
            supersedes_key: "supersedes_finding_resolution_id"
          )
          case analysis.status
          when :empty
            {
              "finding_ref" => {
                "finding_id" => finding["finding_id"],
                "content_digest" => finding["content_digest"]
              },
              "disposition" => disposition
            }
          when :unique
            nil
          else
            raise ContractError.new(
              "integrity_audit_invalid",
              "finding resolution lineage has no current valid tip",
              path: "finding_resolutions"
            )
          end
        end.compact.sort_by { |entry| entry["finding_ref"]["finding_id"] }
      end
      private_class_method :unresolved_findings

      def index(bundle, collection, id_field)
        result = {}
        Array(bundle[collection]).each do |document|
          next unless document.is_a?(Hash)

          id = document[id_field]
          next if id.nil?

          if result.key?(id)
            raise ContractError.new(
              "integrity_audit_invalid",
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
