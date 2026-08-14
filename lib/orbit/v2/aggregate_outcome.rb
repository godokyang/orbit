# frozen_string_literal: true

require_relative "canonical_json"
require_relative "errors"
require_relative "evaluation_subject"
require_relative "projection_primitives"
require_relative "validator"

module Orbit
  module V2
    # Slice 5 increment 1: the deterministic AggregateOutcome projection.
    #
    # A pure derived seam over authoritative facts. It writes nothing, is not
    # an authoritative bundle collection/schema, and never produces an outcome
    # an agent or Lead can persist as a fact source.
    #
    # Validated-input boundary: derive(bundle, task_revision_id, validator:)
    # mechanically runs `validator.validate` on the bundle before projecting.
    # Validation is the single eligibility boundary — evaluator provenance and
    # independence, active-policy/authorization, resolution authority, and
    # every unresolved ref are enforced by the real Validator, never
    # re-derived here. The ONLY tolerated validation error is the historical
    # stale-evaluation error (see ProjectionPrimitives
    # .historical_stale_evaluation_error?): a structurally complete
    # create-only GateEvaluation whose pinned subject no longer equals the
    # CURRENT canonical subject. ADR-005 keeps such an evaluation immutable;
    # later subject changes make it stale for closure while the artifact
    # remains stored, and project_requirement excludes it. Every other error
    # (shape/authority/provenance/independence/resolution, stale GateRequirement
    # digest, stale active-policy authority, malformed subject) raises
    # `aggregate_outcome_invalid` and produces no projection, so no cache
    # identity can claim validity for an invalid fact set.
    #
    # The output is a canonical hash: exact task/policy refs, gate results
    # sorted by gate_requirement_id, sorted unresolved blocking and
    # adjudication-required finding refs, a closed boolean, a complete sorted
    # source ID+digest manifest, and source/content digests. The manifest
    # covers every bundle source the boundary consumes (authority assertions,
    # authorization records, agent instances/runtime identity, rule
    # resolutions, checkpoints, protocol root, snapshot, CodeSurface, and all
    # domain records), so source_digest is a complete future deletable-cache
    # key: repeat recomputation is byte-identical and any participating
    # source change changes the projection.
    module AggregateOutcome
      module_function

      SCHEMA_VERSION = "orbit-aggregate-outcome-v1"
      PROTOCOL_EPOCH = "orbit-v2"

      STATUSES = %w[passed not_passed missing ambiguous].freeze

      def derive(bundle, task_revision_id, validator:)
        unless validator.is_a?(Orbit::V2::Validator)
          raise ContractError.new(
            "aggregate_outcome_invalid",
            "derive requires an Orbit::V2::Validator validated-context seam",
            path: "validator"
          )
        end
        errors = validator.validate(bundle)
        unless errors.all? do |error|
                 ProjectionPrimitives.historical_stale_evaluation_error?(error)
               end
          raise ContractError.new(
            "aggregate_outcome_invalid",
            "bundle is not an accepted validated fact set and cannot be projected",
            details: errors.map(&:to_h)
          )
        end
        project(bundle, task_revision_id)
      rescue KeyError, TypeError, ArgumentError => e
        raise ContractError.new("aggregate_outcome_invalid", e.message)
      end

      def project(bundle, task_revision_id)
        tasks = index(bundle, "task_revisions", "task_revision_id")
        task = tasks[task_revision_id]
        unless task.is_a?(Hash)
          raise ContractError.new(
            "aggregate_outcome_invalid",
            "task revision does not exist",
            path: "task_revisions"
          )
        end

        policies = index(bundle, "project_policy_revisions", "policy_revision_id")
        policy = resolve_exact_ref(
          task["project_policy_revision_ref"],
          policies,
          id_key: "policy_revision_id",
          path: "task_revisions.#{task_revision_id}.project_policy_revision_ref",
          label: "project policy revision"
        )

        requirements = index(bundle, "gate_requirements", "gate_requirement_id")
        task_requirements = Array(task["gate_requirement_refs"]).map do |id|
          requirement = requirements[id]
          unless requirement.is_a?(Hash) &&
                 requirement["task_id"] == task["task_id"] &&
                 requirement["task_revision_id"] == task["task_revision_id"]
            raise ContractError.new(
              "aggregate_outcome_invalid",
              "GateRequirement ref must resolve to a requirement owned by the projected TaskRevision",
              path: "task_revisions.#{task_revision_id}.gate_requirement_refs"
            )
          end
          requirement
        end.uniq { |requirement| requirement["gate_requirement_id"] }

        evaluations_index = index(bundle, "gate_evaluations", "gate_evaluation_id")
        findings_index = index(bundle, "findings", "finding_id")
        evaluations = Array(bundle["gate_evaluations"]).select { |document| document.is_a?(Hash) }
        resolutions = Array(bundle["finding_resolutions"]).select { |document| document.is_a?(Hash) }
        units = Array(bundle["work_units"])
        attempts = Array(bundle["work_unit_attempts"])
        records = Array(bundle["evidence_records"])
        snapshot = bundle["repository_snapshot"]
        code_surface = bundle["code_surface"]
        unless snapshot.is_a?(Hash) && code_surface.is_a?(Hash)
          raise ContractError.new(
            "aggregate_outcome_invalid",
            "repository snapshot and CodeSurface are required projection inputs",
            path: "repository_snapshot"
          )
        end

        evaluations_by_requirement = evaluations.group_by do |evaluation|
          evaluation["gate_requirement_id"]
        end
        gate_results = task_requirements.sort_by do |requirement|
          requirement["gate_requirement_id"]
        end.map do |requirement|
          project_requirement(
            requirement,
            task,
            evaluations_by_requirement,
            units,
            attempts,
            records,
            snapshot,
            code_surface
          )
        end

        relevant_findings = relevant_findings(
          task,
          findings_index,
          evaluations_index,
          requirements,
          tasks
        )
        blocking_refs = []
        adjudication_refs = []
        relevant_findings.each do |finding|
          disposition = ProjectionPrimitives.finding_disposition(finding, policy)
          case disposition
          when "blocking"
            if resolution_tips(finding["finding_id"], resolutions).empty?
              blocking_refs << finding_ref(finding)
            end
          when "adjudication_required"
            if resolution_tips(finding["finding_id"], resolutions).empty?
              adjudication_refs << finding_ref(finding)
            end
          when "nonblocking"
            # hardening_opportunity never blocks closure
          else
            raise ContractError.new(
              "aggregate_outcome_invalid",
              "Finding disposition must be a closed active-policy value",
              path: "findings.#{finding["finding_id"]}"
            )
          end
        end
        blocking_refs.sort_by! { |ref| ref["finding_id"] }
        adjudication_refs.sort_by! { |ref| ref["finding_id"] }

        closed =
          gate_results.all? { |result| result["status"] == "passed" } &&
          blocking_refs.empty? &&
          adjudication_refs.empty?

        manifest = source_manifest(bundle)
        document = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => task["project_id"],
          "task_revision_ref" => ref("task_revision_id", task),
          "project_policy_revision_ref" => ref("policy_revision_id", policy),
          "gate_results" => gate_results,
          "unresolved_blocking_finding_refs" => blocking_refs,
          "unresolved_adjudication_required_finding_refs" => adjudication_refs,
          "closed" => closed,
          "source_manifest" => manifest,
          "source_digest" => "sha256:#{CanonicalJSON.sha256(manifest)}"
        }
        document.merge(
          "content_digest" => CanonicalJSON.digest_excluding(document, "content_digest")
        )
      end
      private_class_method :project

      def project_requirement(requirement, task, evaluations_by_requirement, units, attempts,
                              records, snapshot, code_surface)
        candidates = Array(evaluations_by_requirement[requirement["gate_requirement_id"]])
        status = "missing"
        deciding = nil
        unless candidates.empty?
          expected = EvaluationSubject.select(
            gate_requirement: requirement,
            task_revision: task,
            work_units: units,
            attempts: attempts,
            evidence_records: records,
            repository_snapshot: snapshot,
            code_surface: code_surface
          )
          budget_gate = requirement.dig("subject_selector", "budget_assessment_required") == true
          participating = candidates.select do |evaluation|
            next false unless evaluation["gate_requirement_content_digest"] == requirement["content_digest"]
            next false unless evaluation["subject"].is_a?(Hash)

            expected_subject =
              if budget_gate
                ProjectionPrimitives.canonical_budget_subject(expected, evaluation)
              else
                expected
              end
            EvaluationSubject.same?(expected_subject, evaluation["subject"])
          end
          status, deciding = decide_gate(participating)
        end

        result = {
          "gate_requirement_ref" => {
            "gate_requirement_id" => requirement["gate_requirement_id"],
            "content_digest" => requirement["content_digest"]
          },
          "status" => status,
          "gate_evaluation_ref" => nil
        }
        if deciding
          result["gate_evaluation_ref"] = {
            "gate_evaluation_id" => deciding["gate_evaluation_id"],
            "content_digest" => deciding["content_digest"]
          }
        end
        result
      end
      private_class_method :project_requirement

      def decide_gate(participating)
        analysis = ProjectionPrimitives.supersedes_tips(
          participating,
          id_key: "gate_evaluation_id",
          supersedes_key: "supersedes_gate_evaluation_id"
        )
        case analysis.status
        when :unique
          evaluation = analysis.tips.first
          status = evaluation["verdict"] == "pass" ? "passed" : "not_passed"
          [status, evaluation]
        when :empty
          ["missing", nil]
        when :ambiguous
          ["ambiguous", nil]
        else
          raise ContractError.new(
            "aggregate_outcome_invalid",
            "GateEvaluation supersedes lineage contains a cycle, fork, or orphan",
            path: "gate_evaluations"
          )
        end
      end
      private_class_method :decide_gate

      def relevant_findings(task, findings_index, evaluations_index, requirements, tasks)
        lineage_findings = findings_index.values.select do |finding|
          lineage = ProjectionPrimitives.finding_lineage(
            finding,
            evaluations: evaluations_index,
            requirements: requirements,
            tasks: tasks
          )
          lineage &&
            lineage["task_id"] == task["task_id"] &&
            lineage["task_revision_id"] == task["task_revision_id"]
        end
        carried = Array(task["unresolved_finding_refs"]).map do |id|
          finding = findings_index[id]
          unless finding.is_a?(Hash)
            raise ContractError.new(
              "aggregate_outcome_invalid",
              "unresolved Finding ref must resolve to an existing Finding",
              path: "task_revisions.#{task["task_revision_id"]}.unresolved_finding_refs"
            )
          end
          finding
        end
        (lineage_findings + carried).uniq { |finding| finding["finding_id"] }
      end
      private_class_method :relevant_findings

      def resolution_tips(finding_id, resolutions)
        matching = resolutions.select do |resolution|
          resolution["finding_id"] == finding_id
        end
        analysis = ProjectionPrimitives.supersedes_tips(
          matching,
          id_key: "finding_resolution_id",
          supersedes_key: "supersedes_finding_resolution_id"
        )
        case analysis.status
        when :unique, :empty
          analysis.tips
        else
          raise ContractError.new(
            "aggregate_outcome_invalid",
            "FindingResolution lineage must have one append-only current tip",
            path: "finding_resolutions"
          )
        end
      end
      private_class_method :resolution_tips

      def index(bundle, collection, id_field)
        result = {}
        Array(bundle[collection]).each do |document|
          next unless document.is_a?(Hash)

          id = document[id_field]
          next if id.nil?

          if result.key?(id)
            raise ContractError.new(
              "aggregate_outcome_invalid",
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
          "aggregate_outcome_invalid",
          "#{label} ref must resolve to an exact existing revision",
          path: path
        )
      end
      private_class_method :resolve_exact_ref

      COLLECTION_KINDS = {
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
      private_constant :COLLECTION_KINDS

      # The complete sorted source ID+digest manifest of every validated
      # bundle source. This is whole-bundle over-invalidation by design: the
      # eligibility boundary consumes the entire bundle, so every source is
      # part of the key. protocol_root is a singleton and is included exactly
      # once; every collection document appears exactly once (task revisions
      # and policy revisions come from their collections, not from preseeded
      # refs). Documents without a stored content_digest (authority
      # assertions, agent instances/runtime identity, lead sessions, rule
      # resolutions, attempts) get their canonical content digest recomputed,
      # so any byte change to any source changes the manifest and therefore
      # source_digest/content_digest.
      def source_manifest(bundle)
        entries = []
        root = bundle["protocol_root"]
        if root.is_a?(Hash) && root["project_id"].is_a?(String)
          digest = root["content_digest"]
          digest = CanonicalJSON.content_digest(root) unless digest.is_a?(String)
          entries << manifest_entry("protocol_root", root["project_id"], digest)
        end
        COLLECTION_KINDS.each do |collection, (kind, id_field)|
          Array(bundle[collection]).each do |document|
            next unless document.is_a?(Hash)

            id = document[id_field]
            next if id.nil?

            digest = document["content_digest"]
            digest = CanonicalJSON.content_digest(document) unless digest.is_a?(String)
            entries << manifest_entry(kind, id, digest)
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
              "aggregate_outcome_invalid",
              "source manifest contains a duplicate (kind, id)",
              path: "source_manifest"
            )
          end
          seen[key] = true
        end
        entries.sort_by { |entry| [entry["kind"], entry["id"]] }
      end
      private_class_method :source_manifest

      def manifest_entry(kind, id, content_digest)
        { "kind" => kind, "id" => id, "content_digest" => content_digest }
      end
      private_class_method :manifest_entry

      def finding_ref(finding)
        { "finding_id" => finding["finding_id"], "content_digest" => finding["content_digest"] }
      end
      private_class_method :finding_ref

      def ref(id_key, document)
        { id_key => document[id_key], "content_digest" => document["content_digest"] }
      end
      private_class_method :ref
    end
  end
end
