# frozen_string_literal: true

require "set"
require "time"

require_relative "authority_verifier"
require_relative "canonical_json"
require_relative "control_authority"
require_relative "errors"
require_relative "evidence_contract"
require_relative "evaluation_subject"
require_relative "gate_strength"
require_relative "identifiers"
require_relative "invariant_graph"
require_relative "lead_control"
require_relative "lifecycle_verifier"
require_relative "policy_issuance"
require_relative "path_scope"
require_relative "protected_change"
require_relative "rule_resolution"
require_relative "projection_primitives"
require_relative "runtime_identity_verifier"
require_relative "schema_catalog"
require_relative "task_authority"
require_relative "work_authority"

module Orbit
  module V2
    class Validator
      PROTOCOL_EPOCH = "orbit-v2"
      BUNDLE_KEYS = %w[
        schema_version protocol_epoch protocol_root authority_assertions authorization_records
        project_policy_revisions task_revisions gate_requirements work_units change_theses
        agent_instances logical_leads lead_sessions control_registries lead_checkpoints
        work_unit_attempts
        rule_resolution_artifacts evidence_records
        gate_evaluations findings finding_resolutions repository_snapshot code_surface
      ].freeze
      COLLECTIONS = {
        "authority_assertions" => ["authority_assertion", "assertion_id"],
        "authorization_records" => ["authorization_record", "authorization_record_id"],
        "project_policy_revisions" => ["project_policy_revision", "policy_revision_id"],
        "task_revisions" => ["task_revision", "task_revision_id"],
        "gate_requirements" => ["gate_requirement", "gate_requirement_id"],
        "work_units" => ["work_unit", "work_unit_id"],
        "agent_instances" => ["agent_instance", "agent_instance_id"],
        "logical_leads" => ["logical_lead", "logical_lead_id"],
        "lead_sessions" => ["lead_session", "lead_session_id"],
        "control_registries" => ["lead_control_registry", "lead_control_id"],
        "lead_checkpoints" => ["lead_checkpoint", "lead_checkpoint_id"],
        "work_unit_attempts" => ["work_unit_attempt", "attempt_id"],
        "rule_resolution_artifacts" => ["rule_resolution", "resolution_id"],
        "evidence_records" => ["evidence_record", "evidence_record_id"],
        "gate_evaluations" => ["gate_evaluation", "gate_evaluation_id"],
        "findings" => ["finding", "finding_id"],
        "finding_resolutions" => ["finding_resolution", "finding_resolution_id"]
      }.freeze
      CONTENT_DIGEST_COLLECTIONS = %w[
        authorization_records project_policy_revisions task_revisions gate_requirements
        work_units change_theses logical_leads evidence_records gate_evaluations findings
        finding_resolutions control_registries lead_checkpoints
      ].freeze
      FORBIDDEN_WORK_UNIT_FACTS = %w[
        goal acceptance evidence_requirements source_requirements gate_requirements
        assignment agent_instance_id context_generation started_at ended_at status
        current_change_thesis_ref
      ].freeze
      FORBIDDEN_EVALUATOR_EVIDENCE_FACTS = %w[
        verdict quality_outcome_verdict quality_question_answers acceptance_results findings
        finding_refs residual_risk counterexample_cases coverage
      ].freeze
      ASSIGNMENT_BINDINGS = {
        "implementation" => {
          "resolved_role" => "coder",
          "capability" => "coder.execute",
          "permission" => "work_unit.write",
          "authority_action" => WorkAuthority.action_for_purpose("implementation")
        },
        "review" => {
          "resolved_role" => "reviewer",
          "capability" => "review.evaluate",
          "permission" => "gate.review.submit",
          "authority_action" => WorkAuthority.action_for_purpose("review")
        },
        "test" => {
          "resolved_role" => "tester",
          "capability" => "test.execute",
          "permission" => "gate.test.submit",
          "authority_action" => WorkAuthority.action_for_purpose("test")
        },
        "adjudication" => {
          "resolved_role" => "adjudicator",
          "capability" => "adjudication.evaluate",
          "permission" => "finding.resolve",
          "authority_action" => WorkAuthority.action_for_purpose("adjudication")
        },
        "research" => {
          "resolved_role" => "researcher",
          "capability" => "research.execute",
          "permission" => "work_unit.read",
          "authority_action" => WorkAuthority.action_for_purpose("research")
        },
        "release" => {
          "resolved_role" => "release",
          "capability" => "release.evaluate",
          "permission" => "gate.release.submit",
          "authority_action" => WorkAuthority.action_for_purpose("release")
        }
      }.freeze
      GATE_EVALUATOR_BINDINGS = {
        "review" => ASSIGNMENT_BINDINGS.fetch("review").merge("purpose" => "review"),
        "test" => ASSIGNMENT_BINDINGS.fetch("test").merge("purpose" => "test"),
        "release" => ASSIGNMENT_BINDINGS.fetch("release").merge("purpose" => "release"),
        "adjudication" => ASSIGNMENT_BINDINGS.fetch("adjudication").merge(
          "purpose" => "adjudication"
        )
      }.freeze
      EVENT_STREAMS = {
        "agent" => {
          "initial" => "AgentCreated",
          "allowed" => %w[AgentCreated AgentContextAdvanced AgentTerminated],
          "terminal" => %w[AgentTerminated]
        },
        "lead_session" => {
          "initial" => "LeadSessionStarted",
          "allowed" => %w[LeadSessionStarted LeadSessionEnded],
          "terminal" => %w[LeadSessionEnded]
        },
        "attempt" => {
          "initial" => "AttemptCreated",
          "allowed" => %w[
            AttemptCreated AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled
            AttemptSuperseded
          ],
          "terminal" => %w[
            AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled AttemptSuperseded
          ]
        }
      }.freeze

      attr_reader :errors

      def initialize(
        project_root: Dir.pwd,
        authority_verifier: AuthorityVerifier.new,
        lifecycle_verifier: LifecycleVerifier.new,
        runtime_identity_verifier: RuntimeIdentityVerifier.new
      )
        @errors = []
        @indexes = {}
        @graphs = {}
        @event_ids = {}
        @project_root = project_root
        @authority_verifier = authority_verifier
        @lifecycle_verifier = lifecycle_verifier
        @runtime_identity_verifier = runtime_identity_verifier
        @verified_authority_assertions = {}
        @verified_runtime_identities = {}
      end

      def validate(bundle)
        @errors = []
        @indexes = {}
        @graphs = {}
        @event_ids = {}
        @verified_authority_assertions = {}
        @verified_runtime_identities = {}
        @bundle_snapshot = bundle.is_a?(Hash) ? bundle["repository_snapshot"] : nil
        check("contract_bundle") { SchemaCatalog.check!("contract_bundle", bundle) }
        return errors unless bundle.is_a?(Hash)
        structural_errors = SchemaCatalog.structure_errors("contract_bundle", bundle)
        @errors.concat(structural_errors)
        return errors unless structural_errors.empty?

        reject_unknown_bundle_keys(bundle)
        validate_epoch(bundle, "bundle")
        protocol_root = bundle["protocol_root"]
        unless protocol_root.is_a?(Hash)
          add("protocol_root_missing", "bundle requires a ProtocolRoot", "protocol_root")
          return errors
        end
        project_id = protocol_root["project_id"]
        validate_protocol_root(protocol_root)
        build_indexes(bundle)
        validate_documents(bundle, project_id)
        validate_authority_assertions(bundle)
        active_policy = validate_policy_lineage(bundle, protocol_root)
        validate_authorizations(bundle)
        validate_tasks(bundle, active_policy)
        validate_gate_requirements(bundle)
        validate_work_units(bundle)
        validate_change_theses(bundle)
        validate_agents(bundle)
        validate_logical_leads(bundle)
        validate_lead_sessions(bundle)
        validate_active_session_cardinality(bundle)
        validate_control_registries(bundle, active_policy)
        validate_lead_checkpoints(bundle, active_policy)
        validate_multi_lineage_closure(bundle)
        validate_task_transfer_provenance(bundle)
        validate_attempts(bundle, active_policy)
        validate_rule_resolutions(bundle)
        validate_evidence_records(bundle, active_policy)
        validate_gate_evaluations(bundle, active_policy)
        validate_findings(bundle)
        validate_finding_resolutions(bundle, active_policy)
        validate_finding_closure(bundle, active_policy)
        errors
      end

      def validate!(bundle)
        result = validate(bundle)
        raise ValidationFailure, result unless result.empty?

        true
      end

      def validate_document!(kind, document)
        @errors = []
        SchemaCatalog.check!(kind, document)
        @errors.concat(SchemaCatalog.structure_errors(kind, document))
        validate_epoch(document, kind)
        raise ValidationFailure, errors unless errors.empty?

        true
      end

      private

      def reject_unknown_bundle_keys(bundle)
        (bundle.keys - BUNDLE_KEYS).each do |key|
          add(
            "forbidden_second_fact_source",
            "bundle key #{key.inspect} is not an Orbit v2 authority object or approved derived input",
            key
          )
        end
      end

      def build_indexes(bundle)
        COLLECTIONS.each do |collection, (_kind, id_field)|
          graph = InvariantGraph.new(
            bundle[collection],
            identity_key: id_field,
            path: collection
          )
          @graphs[collection] = graph
          @indexes[collection] = graph.to_h
          @errors.concat(graph.errors)
        end
        theses = Array(bundle["change_theses"])
        @indexes["change_theses"] = {}
        theses.each_with_index do |thesis, index|
          next unless thesis.is_a?(Hash)

          key = [thesis["change_thesis_id"], thesis["revision"]]
          if @indexes["change_theses"].key?(key)
            add("immutable_record_reuse", "ChangeThesis revision identity is reused", "change_theses[#{index}]")
          else
            @indexes["change_theses"][key] = thesis
          end
        end
      end

      def validate_documents(bundle, project_id)
        COLLECTIONS.each do |collection, (kind, id_field)|
          Array(bundle[collection]).each_with_index do |document, index|
            next unless document.is_a?(Hash)

            path = "#{collection}[#{index}]"
            check(path) { SchemaCatalog.check!(kind, document) }
            validate_epoch(document, path)
            validate_project(document, project_id, path)
            validate_identifier(id_kind_for(id_field), document[id_field], "#{path}.#{id_field}") unless id_field == "resolution_id"
            if id_field == "resolution_id" && !Identifiers.content_address?(document[id_field])
              add("invalid_id", "resolution_id must be a content address", "#{path}.resolution_id")
            end
          end
        end
        Array(bundle["change_theses"]).each_with_index do |document, index|
          next unless document.is_a?(Hash)

          path = "change_theses[#{index}]"
          check(path) { SchemaCatalog.check!("change_thesis", document) }
          validate_epoch(document, path)
          validate_project(document, project_id, path)
          validate_identifier("change_thesis_id", document["change_thesis_id"], "#{path}.change_thesis_id")
        end
        CONTENT_DIGEST_COLLECTIONS.each do |collection|
          Array(bundle[collection]).each_with_index do |document, index|
            validate_content_digest(document, "#{collection}[#{index}]") if document.is_a?(Hash)
          end
        end
      end

      def validate_supersedes(
        document,
        ref_field,
        index,
        id_field,
        path,
        same_scope:,
        compatible: nil
      )
        ref = document[ref_field]
        return if ref.nil?

        previous = index[ref]
        if previous.nil? || ref == document[id_field]
          add("lineage_invalid", "#{ref_field} must reference a different existing immutable record", "#{path}.#{ref_field}")
          return
        end
        same_scope.each do |field|
          if previous[field] != document[field]
            add("lineage_invalid", "#{ref_field} changes #{field}", "#{path}.#{ref_field}")
          end
        end
        if compatible && !compatible.call(document, previous)
          add(
            "lineage_invalid",
            "#{ref_field} crosses an incompatible authority lineage",
            "#{path}.#{ref_field}"
          )
        end
      end

      def validate_related_refs(document, ref_field, index, id_field, path)
        Array(document[ref_field]).each do |ref|
          related = index[ref]
          if related.nil? || ref == document[id_field]
            add(
              "lineage_invalid",
              "#{ref_field} must reference a different existing immutable record",
              "#{path}.#{ref_field}"
            )
          elsif block_given? && !yield(document, related)
            add(
              "lineage_invalid",
              "#{ref_field} crosses an incompatible authority lineage",
              "#{path}.#{ref_field}"
            )
          end
        end
      end

      def validate_supersedes_cycles(index, ref_field, id_field, path)
        reported = Set.new
        index.each_value do |document|
          visited = Set.new
          cursor = document
          while cursor && cursor[ref_field]
            current_id = cursor[id_field]
            visited << current_id
            next_id = cursor[ref_field]
            if visited.include?(next_id)
              cycle_key = visited.to_a.sort.join(":")
              if reported.add?(cycle_key)
                add(
                  "lineage_invalid",
                  "#{ref_field} lineage contains a cycle",
                  "#{path}.#{current_id}.#{ref_field}"
                )
              end
              break
            end
            cursor = index[next_id]
          end
        end
      end

      def validate_content_digest(document, path)
        expected = CanonicalJSON.content_digest(document)
        return if document["content_digest"] == expected

        add(
          "digest_mismatch",
          "content_digest does not match canonical semantic content",
          "#{path}.content_digest",
          "expected" => expected,
          "actual" => document["content_digest"]
        )
      rescue ArgumentError => e
        add("canonicalization_error", e.message, path)
      end

      def validate_epoch(document, path)
        return if document.is_a?(Hash) && document["protocol_epoch"] == PROTOCOL_EPOCH

        add(
          "protocol_epoch_mismatch",
          "Orbit v2 contracts require protocol_epoch=#{PROTOCOL_EPOCH}",
          "#{path}.protocol_epoch",
          "actual" => document.is_a?(Hash) ? document["protocol_epoch"] : nil
        )
      end

      def validate_project(document, project_id, path)
        return if document["project_id"] == project_id

        add("project_identity_mismatch", "document project_id does not match ProtocolRoot", "#{path}.project_id")
      end

      def validate_identifier(kind, value, path)
        return if Identifiers.valid?(kind, value)

        add("invalid_id", "#{kind} is malformed", path)
      rescue KeyError
        add("invalid_id", "no stable ID contract for #{kind}", path)
      end

      def id_kind_for(field)
        field
      end

      def subject_shape_complete?(subject)
        subject.is_a?(Hash) &&
          subject["task_revision_ref"].is_a?(Hash) &&
          Array(subject["work_unit_refs"]).any? &&
          Array(subject["implementation_attempt_refs"]).any? &&
          Array(subject["evidence_record_refs"]).any? &&
          subject["repository_snapshot_ref"].is_a?(Hash) &&
          subject["code_surface_ref"].is_a?(Hash) &&
          Identifiers.digest?(subject["subject_digest"])
      end

      def evidence_level_at_least?(actual, minimum)
        GateStrength.evidence_at_least?(actual, minimum)
      end

      def stable_contract_ref?(value)
        value.is_a?(String) && /\A(?:acc|src|evreq|question)_[a-z0-9][a-z0-9_-]{2,95}\z/.match?(value)
      end

      def rule_resolution_identity_matches_attempt?(rule, attempt, assignment)
        identity = rule.is_a?(Hash) ? rule["identity"] : nil
        return false unless identity.is_a?(Hash) && attempt.is_a?(Hash) && assignment.is_a?(Hash)

        {
          "protocol_epoch" => PROTOCOL_EPOCH,
          "project_id" => attempt["project_id"],
          "task_id" => attempt["task_id"],
          "task_revision_id" => attempt["task_revision_id"],
          "work_unit_id" => attempt["work_unit_id"],
          "attempt_id" => attempt["attempt_id"],
          "resolved_role" => assignment["resolved_role"],
          "agent_instance_id" => assignment["agent_instance_id"],
          "context_generation" => assignment["context_generation"]
        }.all? { |field, expected| identity[field] == expected }
      end

      def subset?(values, allowed)
        values.is_a?(Array) && (values - allowed).empty?
      end

      def finding_disposition(finding, policy)
        ProjectionPrimitives.finding_disposition(finding, policy)
      end

      def check(path)
        yield
      rescue ContractError => e
        add(e.code, e.message, e.path || path, e.details)
      rescue KeyError, TypeError => e
        add("contract_shape_invalid", e.message, path)
      rescue ArgumentError => e
        add("canonicalization_error", e.message, path)
      end

      def add(code, message, path = nil, details = nil)
        @errors << ContractError.new(code, message, path: path, details: details)
      end
    end
  end
end
require_relative "validator/authority_policy"
require_relative "validator/lead_control"
require_relative "validator/task_work_gate"
require_relative "validator/runtime_lifecycle"
require_relative "validator/evidence_evaluation"
require_relative "validator/findings_lineage"
