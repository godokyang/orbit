# frozen_string_literal: true

require_relative "canonical_json"
require_relative "errors"
require_relative "invariant_graph"
require_relative "path_scope"

module Orbit
  module V2
    class EvidenceContract
      IMPLEMENTATION_KINDS = %w[change verification].freeze

      def self.validate(record:, work_unit:, task_revision:, assignment:, code_surface:)
        new(
          record: record,
          work_unit: work_unit,
          task_revision: task_revision,
          assignment: assignment,
          code_surface: code_surface
        ).validate
      end

      def initialize(record:, work_unit:, task_revision:, assignment:, code_surface:)
        @record = record
        @work_unit = work_unit
        @task_revision = task_revision
        @assignment = assignment
        @code_surface = code_surface
        @path = "evidence_records.#{record["evidence_record_id"]}"
        @errors = []
      end

      def validate
        claims = Array(@record["submission_artifact_refs"])
        graph = InvariantGraph.new(
          claims,
          identity_key: "artifact_ref",
          digest_key: "content_digest",
          kind_key: "artifact_kind",
          path: "#{@path}.submission_artifact_refs"
        )
        graph.errors.each do |error|
          add(
            "evidence_reference_invalid",
            "ArtifactClaim identities must be unique and immutable: #{error.message}",
            error.path,
            error.to_h
          )
        end
        unless canonical_claim_set?(claims)
          add(
            "evidence_reference_invalid",
            "ArtifactClaims must be a canonical sorted set with unique identities",
            "#{@path}.submission_artifact_refs"
          )
        end
        validate_claim_paths(claims)

        case @record["record_kind"]
        when "implementation"
          validate_implementation(graph, claims)
        when "evaluator_submission"
          validate_evaluator_claims(claims)
        end
        @errors
      end

      private

      def validate_implementation(graph, claims)
        check = @record["implementation_check"]
        return unless check.is_a?(Hash) && @work_unit && @task_revision && @assignment

        unless CanonicalJSON.dump(check["change_thesis_ref"]) ==
               CanonicalJSON.dump(@assignment["change_thesis_ref"])
          add(
            "evidence_record_invalid",
            "implementation_check thesis must match Attempt",
            "#{@path}.implementation_check.change_thesis_ref"
          )
        end

        unless claims.all? { |claim| IMPLEMENTATION_KINDS.include?(claim["artifact_kind"]) }
          add(
            "evidence_reference_invalid",
            "implementation EvidenceRecord may claim only change or verification artifacts",
            "#{@path}.submission_artifact_refs"
          )
        end
        change_claims = claims.select { |claim| claim["artifact_kind"] == "change" }
        verification_claims = claims.select do |claim|
          claim["artifact_kind"] == "verification"
        end
        if change_claims.empty? || verification_claims.empty?
          add(
            "implementation_evidence_incomplete",
            "implementation evidence requires both change and verification ArtifactClaims",
            "#{@path}.submission_artifact_refs"
          )
        end

        evidence_ref_groups = [
          [check.dig("scope_match", "evidence_refs"), "scope_match.evidence_refs"],
          [check.dig("change_thesis_status", "evidence_refs"), "change_thesis_status.evidence_refs"]
        ]
        Array(check["acceptance_results"]).each_with_index do |result, index|
          evidence_ref_groups << [
            result["evidence_refs"],
            "acceptance_results[#{index}].evidence_refs"
          ]
        end
        Array(check["evidence_requirement_results"]).each_with_index do |result, index|
          evidence_ref_groups << [
            result["evidence_refs"],
            "evidence_requirement_results[#{index}].evidence_refs"
          ]
        end
        evidence_ref_groups.each do |refs, suffix|
          resolve_refs(
            graph,
            refs,
            allowed_kinds: IMPLEMENTATION_KINDS,
            path: "#{@path}.implementation_check.#{suffix}"
          )
        end
        resolve_refs(
          graph,
          check["verification_refs"],
          allowed_kinds: ["verification"],
          path: "#{@path}.implementation_check.verification_refs"
        )

        validate_paths(check, change_claims)
        validate_result_coverage(
          check["acceptance_results"],
          expected_ids: Array(@work_unit["acceptance_refs"]),
          known_ids: Array(@task_revision["acceptance"]).map do |item|
            item["acceptance_id"]
          end,
          id_field: "acceptance_id",
          path: "#{@path}.implementation_check.acceptance_results"
        )
        validate_result_coverage(
          check["evidence_requirement_results"],
          expected_ids: Array(@work_unit["evidence_requirement_refs"]),
          known_ids: Array(@task_revision["evidence_requirements"]).map do |item|
            item["evidence_requirement_id"]
          end,
          id_field: "evidence_requirement_id",
          path: "#{@path}.implementation_check.evidence_requirement_results"
        )

        scope_match = check["scope_match"]
        unless scope_match.is_a?(Hash) &&
               scope_match["status"] == "pass" &&
               Array(scope_match["evidence_refs"]).any?
          incomplete("accepted implementation evidence requires a claimed scope match", "scope_match")
        end
        thesis_status = check["change_thesis_status"]
        unless thesis_status.is_a?(Hash) &&
               thesis_status["status"] == "supported" &&
               Array(thesis_status["evidence_refs"]).any?
          incomplete("accepted implementation evidence must support its exact ChangeThesis", "change_thesis_status")
        end
        unless Array(check["assumptions_changed"]).empty? &&
               Array(check["known_gaps"]).empty?
          incomplete(
            "changed assumptions or known gaps require a successor thesis/attempt or non-PASS result",
            nil
          )
        end
      end

      def validate_claim_paths(claims)
        claims.each_with_index do |claim, index|
          next if claim.is_a?(Hash) && valid_claim_paths?(claim)

          add(
            "evidence_reference_invalid",
            "change ArtifactClaims require non-empty canonical paths; " \
              "verification and report ArtifactClaims must be path-free",
            "#{@path}.submission_artifact_refs[#{index}].paths"
          )
        end
      end

      def valid_claim_paths?(claim)
        case claim["artifact_kind"]
        when "change"
          PathScope.canonical_set?(claim["paths"], allow_empty: false)
        when "verification", "report"
          claim["paths"] == []
        else
          false
        end
      end

      def validate_evaluator_claims(claims)
        valid = claims.any? && claims.all? { |claim| claim["artifact_kind"] == "report" }
        return if valid

        add(
          "evidence_reference_invalid",
          "evaluator submission requires report ArtifactClaims",
          "#{@path}.submission_artifact_refs"
        )
      end

      def validate_paths(check, change_claims)
        changed_paths = Array(check["changed_paths"])
        claim_paths = change_claims.flat_map { |claim| Array(claim["paths"]) }
        writable_paths = Array(@work_unit.dig("authority_scope", "writable_paths"))
        surface_paths = Array(@code_surface && @code_surface["paths"])
        canonical = PathScope.canonical_set?(changed_paths, allow_empty: false) &&
          change_claims.all? { |claim| valid_claim_paths?(claim) } &&
          PathScope.canonical_set?(writable_paths, allow_empty: false) &&
          PathScope.canonical_set?(surface_paths, allow_empty: false)
        exact_claim = canonical && changed_paths == claim_paths.sort.uniq
        authorized = canonical && changed_paths.all? do |changed_path|
          PathScope.covered_by_any?(changed_path, writable_paths) &&
            PathScope.covered_by_any?(changed_path, surface_paths)
        end
        return if exact_claim && authorized

        add(
          "implementation_path_unauthorized",
          "changed paths must be canonical and exactly covered by change claims, " \
            "WorkUnit writable authority, and canonical CodeSurface",
          "#{@path}.implementation_check.changed_paths"
        )
      end

      def resolve_refs(graph, refs, allowed_kinds:, path:)
        unless canonical_ref_set?(refs)
          add(
            "evidence_reference_invalid",
            "artifact refs must be a non-empty canonical sorted set",
            path
          )
        end
        Array(refs).each_with_index do |ref, index|
          begin
            graph.resolve!(
              ref,
              allowed_kinds: allowed_kinds,
              path: "#{path}[#{index}]"
            )
          rescue ContractError => error
            add(
              "evidence_reference_invalid",
              "artifact ref must resolve to an exact record-owned ArtifactClaim: #{error.message}",
              error.path,
              error.to_h
            )
          end
        end
      end

      def validate_result_coverage(results, expected_ids:, known_ids:, id_field:, path:)
        items = Array(results)
        ids = items.map { |item| item[id_field] }
        valid = ids.sort == expected_ids.sort &&
          ids.uniq.length == ids.length &&
          (ids - known_ids).empty? &&
          items.all? do |item|
            item["status"] == "pass" && Array(item["evidence_refs"]).any?
          end
        return if valid

        add(
          "implementation_evidence_incomplete",
          "implementation results must exactly cover selected stable IDs with claimed evidence",
          path
        )
      end

      def canonical_claim_set?(claims)
        ids = claims.map { |claim| claim.is_a?(Hash) ? claim["artifact_ref"] : nil }
        claims.any? && ids.none?(&:nil?) && ids == ids.sort && ids.uniq.length == ids.length
      rescue ArgumentError
        false
      end

      def canonical_ref_set?(refs)
        values = Array(refs)
        keys = values.map do |ref|
          next unless ref.is_a?(Hash)

          [ref["artifact_ref"], ref["content_digest"]]
        end
        values.any? && keys.none?(&:nil?) && keys == keys.sort &&
          keys.map(&:first).uniq.length == keys.length
      rescue ArgumentError
        false
      end

      def incomplete(message, suffix)
        path = "#{@path}.implementation_check"
        path = "#{path}.#{suffix}" if suffix
        add("implementation_evidence_incomplete", message, path)
      end

      def add(code, message, path, details = nil)
        @errors << ContractError.new(code, message, path: path, details: details)
      end
    end
  end
end
