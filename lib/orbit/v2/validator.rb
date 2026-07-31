# frozen_string_literal: true

require "set"
require "time"

require_relative "authority_verifier"
require_relative "canonical_json"
require_relative "errors"
require_relative "evidence_contract"
require_relative "evaluation_subject"
require_relative "gate_strength"
require_relative "identifiers"
require_relative "invariant_graph"
require_relative "lifecycle_verifier"
require_relative "policy_issuance"
require_relative "path_scope"
require_relative "protected_change"
require_relative "rule_resolution"
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
        agent_instances logical_leads lead_sessions work_unit_attempts
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
        finding_resolutions
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
        validate_attempts(bundle, active_policy)
        validate_rule_resolutions(bundle)
        validate_evidence_records(bundle, active_policy)
        validate_gate_evaluations(bundle, active_policy)
        validate_findings(bundle)
        validate_finding_resolutions(bundle, active_policy)
        validate_finding_closure(bundle)
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

      def validate_protocol_root(root)
        check("protocol_root") { SchemaCatalog.check!("protocol_root", root) }
        validate_epoch(root, "protocol_root")
        validate_identifier("project_id", root["project_id"], "protocol_root.project_id")
        validate_content_digest(root, "protocol_root")
        %w[artifact_root policy_body task goal].each do |forbidden|
          if root.key?(forbidden)
            add(
              "forbidden_second_fact_source",
              "ProtocolRoot must not copy #{forbidden}",
              "protocol_root.#{forbidden}"
            )
          end
        end
        ref = root["project_policy_genesis_ref"]
        unless ref.is_a?(Hash) &&
               Identifiers.valid?("policy_revision_id", ref["policy_revision_id"]) &&
               Identifiers.digest?(ref["content_digest"])
          add(
            "authority_bootstrap_invalid",
            "ProtocolRoot requires an immutable policy genesis ID/digest ref",
            "protocol_root.project_policy_genesis_ref"
          )
        end
      end

      def validate_policy_lineage(bundle, root)
        assertions = @verified_authority_assertions
        policies = Array(bundle["project_policy_revisions"]).select { |policy| policy.is_a?(Hash) }
        validate_policy_configuration(policies)
        genesis = policies.select { |policy| policy["parent_policy_revision_id"].nil? }
        if genesis.length != 1
          add("policy_lineage_invalid", "policy lineage requires exactly one genesis", "project_policy_revisions")
          return nil
        end
        root_ref = root["project_policy_genesis_ref"] || {}
        unless root_ref["policy_revision_id"] == genesis.first["policy_revision_id"] &&
               root_ref["content_digest"] == genesis.first["content_digest"]
          add(
            "authority_bootstrap_invalid",
            "ProtocolRoot genesis ref does not match the create-only genesis policy",
            "protocol_root.project_policy_genesis_ref"
          )
        end
        children = Hash.new { |hash, key| hash[key] = [] }
        policies.each do |policy|
          parent = policy["parent_policy_revision_id"]
          children[parent] << policy["policy_revision_id"] if parent
          assertion = assertions[policy["authorization_source_ref"]]
          parent_policy = parent && @indexes["project_policy_revisions"][parent]
          if assertion.nil? ||
             !policy_issuance_valid?(policy, parent_policy, assertion)
            add(
              parent.nil? ? "authority_bootstrap_invalid" : "policy_issuance_invalid",
              "policy revision lacks a provider-signed issuance envelope for its exact immutable content",
              "project_policy_revisions.#{policy["policy_revision_id"]}.authorization_source_ref"
            )
          end
          if parent
            rotation_grant = unique_policy_grant(parent_policy, "policy.rotate")
            unless rotation_grant &&
                   assertion &&
                   Array(assertion["grants"]) == [rotation_grant["required_external_grant"]]
              add(
                "policy_rotation_unauthorized",
                "policy successor requires the unique rotation authority granted by its exact parent",
                "project_policy_revisions.#{policy["policy_revision_id"]}.authorization_source_ref"
              )
            end
          end
          if parent && !@indexes["project_policy_revisions"].key?(parent)
            add(
              "policy_lineage_invalid",
              "policy parent does not exist",
              "project_policy_revisions.#{policy["policy_revision_id"]}.parent_policy_revision_id"
            )
          end
        end
        children.each do |parent, child_ids|
          next if child_ids.length <= 1

          add(
            "policy_lineage_invalid",
            "policy #{parent} has multiple successor tips",
            "project_policy_revisions"
          )
        end
        reachable = Set.new
        cursor = genesis.first["policy_revision_id"]
        loop do
          break if cursor.nil? || reachable.include?(cursor)

          reachable << cursor
          cursor = children[cursor]&.first
        end
        unless reachable.length == policies.length
          add("policy_lineage_invalid", "policy lineage contains a fork, cycle, or orphan", "project_policy_revisions")
        end
        tips = policies.reject { |policy| children.key?(policy["policy_revision_id"]) && !children[policy["policy_revision_id"]].empty? }
        if tips.length != 1
          add("policy_lineage_invalid", "policy lineage must have one deterministic active tip", "project_policy_revisions")
          nil
        else
          tips.first
        end
      end

      def validate_policy_configuration(policies)
        policies.each do |policy|
          path = "project_policy_revisions.#{policy["policy_revision_id"]}"
          grant_actions = Array(policy["authority_grants"]).each_with_object([]) do |grant, actions|
            actions << grant["action"] if grant.is_a?(Hash)
          end
          unless grant_actions.uniq.length == grant_actions.length
            add(
              "policy_authority_grant_ambiguous",
              "ProjectPolicyRevision authority_grants require one unique entry per action",
              "#{path}.authority_grants"
            )
          end
          gate_kinds = Array(policy["protected_gate_minimums"]).each_with_object([]) do |minimum, kinds|
            kinds << minimum["gate_kind"] if minimum.is_a?(Hash)
          end
          unless gate_kinds.uniq.length == gate_kinds.length
            add(
              "policy_gate_minimum_ambiguous",
              "ProjectPolicyRevision protected_gate_minimums require one unique entry per gate kind",
              "#{path}.protected_gate_minimums"
            )
          end
        end
      end

      def policy_issuance_valid?(policy, parent_policy, assertion)
        envelope = assertion["policy_issuance_envelope"]
        receipt = assertion["verification_receipt"]
        expected_grant =
          if parent_policy
            unique_policy_grant(parent_policy, "policy.rotate")&.dig("required_external_grant")
          else
            "policy.genesis"
          end
        return false unless envelope.is_a?(Hash) &&
                            receipt.is_a?(Hash) &&
                            expected_grant &&
                            policy["authorization_assertion_digest"] ==
                              assertion["assertion_digest"] &&
                            assertion["project_id"] == policy["project_id"] &&
                            %w[user control_plane].include?(assertion["issuer_kind"]) &&
                            Array(assertion["grants"]) == [expected_grant]

        envelope["schema_version"] == PolicyIssuance::SCHEMA_VERSION &&
          envelope["issuance_kind"] == (parent_policy ? "rotation" : "genesis") &&
          envelope["project_id"] == policy["project_id"] &&
          envelope["parent_policy_revision_ref"] == PolicyIssuance.policy_ref(parent_policy) &&
          envelope["candidate_policy_revision_ref"] == PolicyIssuance.policy_ref(policy) &&
          envelope["authority_source_revision_ref"] == {
            "provider_id" => assertion["provider_id"],
            "receipt_id" => receipt["receipt_id"],
            "assertion_id" => assertion["assertion_id"],
            "assertion_digest" => assertion["assertion_digest"]
          } &&
          envelope["decision"] == "approved" &&
          envelope["issued_at"] == receipt["issued_at"] &&
          policy_issuance_time_valid?(parent_policy, envelope["issued_at"]) &&
          envelope["envelope_digest"] == PolicyIssuance.envelope_digest(envelope) &&
          assertion["authority_scope_ref"] == envelope["envelope_digest"]
      rescue KeyError, ArgumentError
        false
      end

      def policy_issuance_time_valid?(parent_policy, issued_at)
        current_time = Time.iso8601(issued_at)
        return true unless parent_policy

        parent_assertion = @verified_authority_assertions[parent_policy["authorization_source_ref"]]
        parent_issued_at = parent_assertion&.dig("policy_issuance_envelope", "issued_at")
        parent_issued_at && current_time > Time.iso8601(parent_issued_at)
      rescue ArgumentError, TypeError
        false
      end

      def unique_policy_grant(policy, action)
        matches = Array(policy && policy["authority_grants"]).select do |candidate|
          candidate.is_a?(Hash) && candidate["action"] == action
        end
        matches.length == 1 ? matches.first : nil
      end

      def validate_authorizations(bundle)
        assertions = @verified_authority_assertions
        policies = @indexes.fetch("project_policy_revisions", {})
        Array(bundle["authorization_records"]).each do |authorization|
          next unless authorization.is_a?(Hash)

          path = "authorization_records.#{authorization["authorization_record_id"]}"
          assertion = assertions[authorization["authorization_source_ref"]]
          policy = policies[authorization["project_policy_revision_id"]]
          expected_scope =
            if authorization["action"] == "task.protected_contract.change"
              authorization.dig("protected_change_envelope", "protected_change_digest")
            elsif TaskAuthority.action?(authorization["action"]) ||
                  WorkAuthority.action?(authorization["action"])
              authorization["subject_ref"]
            else
              authorization["project_policy_revision_id"]
            end
          unless assertion &&
                 assertion["assertion_digest"] == authorization["authorization_assertion_digest"] &&
                 assertion["authority_scope_ref"] == expected_scope &&
                 %w[user control_plane].include?(assertion["issuer_kind"]) &&
                 Array(assertion["grants"]).include?(authorization["action"])
            add(
              "authorization_invalid",
              "AuthorizationRecord must bind an external assertion that grants the exact action",
              path
            )
          end
          grant = unique_policy_grant(policy, authorization["action"])
          unless policy && grant &&
                 assertion &&
                 Array(assertion["grants"]).include?(grant["required_external_grant"])
            add(
              "authorization_invalid",
              "AuthorizationRecord action is not enabled by its ProjectPolicyRevision",
              path
            )
          end
          if TaskAuthority.action?(authorization["action"]) &&
             !task_authority_subject_resolves?(authorization)
            add(
              "authorization_invalid",
              "task authority must bind the canonical scope of one exact TaskRevision",
              "#{path}.subject_ref"
            )
          end
          if WorkAuthority.action?(authorization["action"]) &&
             !work_authority_subject_resolves?(authorization)
            add(
              "authorization_invalid",
              "work authority must bind the canonical scope of one exact WorkUnit action",
              "#{path}.subject_ref"
            )
          end
        end
      end

      def task_authority_subject_resolves?(authorization)
        @indexes.fetch("task_revisions", {}).values.any? do |task|
          task["project_id"] == authorization["project_id"] &&
            task.dig("project_policy_revision_ref", "policy_revision_id") ==
              authorization["project_policy_revision_id"] &&
            TaskAuthority.scope_digest(task) == authorization["subject_ref"]
        end
      rescue KeyError, ArgumentError
        false
      end

      def work_authority_subject_resolves?(authorization)
        tasks = @indexes.fetch("task_revisions", {})
        @indexes.fetch("work_units", {}).values.any? do |unit|
          task = tasks[unit["task_revision_id"]]
          task &&
            unit["project_id"] == authorization["project_id"] &&
            task.dig("project_policy_revision_ref", "policy_revision_id") ==
              authorization["project_policy_revision_id"] &&
            Array(unit.dig("authority_scope", "allowed_actions")).include?(
              authorization["action"]
            ) &&
            WorkAuthority.scope_digest(
              unit,
              task,
              authorization["action"]
            ) == authorization["subject_ref"]
        end
      rescue KeyError, ArgumentError
        false
      end

      def validate_authority_assertions(bundle)
        Array(bundle["authority_assertions"]).each do |assertion|
          next unless assertion.is_a?(Hash)

          path = "authority_assertions.#{assertion["assertion_id"]}"
          check(path) do
            @authority_verifier.verify!(assertion)
            @verified_authority_assertions[assertion["assertion_id"]] = assertion
          end
        end
      end

      def validate_tasks(bundle, active_policy)
        authorizations = @indexes.fetch("authorization_records", {})
        tasks = Array(bundle["task_revisions"]).select { |task| task.is_a?(Hash) }
        validate_task_revision_graph(tasks)
        tasks.each do |task|
          path = "task_revisions.#{task["task_revision_id"]}"
          validate_identifier("task_id", task["task_id"], "#{path}.task_id")
          validate_identifier("task_revision_id", task["task_revision_id"], "#{path}.task_revision_id")
          unless task["revision_number"].is_a?(Integer) && task["revision_number"].positive?
            add("task_contract_invalid", "revision_number must be a positive integer", "#{path}.revision_number")
          end
          policy_ref = task["project_policy_revision_ref"]
          policy = policy_ref.is_a?(Hash) && @indexes["project_policy_revisions"][policy_ref["policy_revision_id"]]
          unless policy && policy["content_digest"] == policy_ref["content_digest"]
            add("task_authority_invalid", "TaskRevision policy ref is missing or forged", "#{path}.project_policy_revision_ref")
          end
          validate_task_requirement_ids(task, path)
          validate_task_gate_ownership(task, path)
          validate_task_authorization_reference(task, authorizations, path)
          validate_task_authority_grants(task, policy, authorizations, path)
          %w[risk_owner adjudicator waiver_issuer].each do |forbidden|
            if task.key?(forbidden)
              add("task_authority_invalid", "free-form #{forbidden} cannot be an authority root", "#{path}.#{forbidden}")
            end
          end
          validate_task_parent(task, tasks, authorizations, active_policy, path)
          validate_policy_minimums(task, policy, path)
        end
      end

      def validate_task_authority_grants(task, policy, authorizations, path)
        expected_scope = TaskAuthority.scope_digest(task)
        Array(task["authority_grant_refs"]).each do |ref|
          record = authorizations[ref]
          unless record &&
                 policy &&
                 record["project_id"] == task["project_id"] &&
                 record["project_policy_revision_id"] == policy["policy_revision_id"] &&
                 TaskAuthority.action?(record["action"]) &&
                 record["subject_ref"] == expected_scope
            add(
              "task_authority_invalid",
              "TaskRevision authority refs require an allowed action and the exact canonical task/revision scope",
              "#{path}.authority_grant_refs"
            )
          end
        end
      rescue KeyError, ArgumentError
        add(
          "task_authority_invalid",
          "TaskRevision authority scope cannot be derived from an invalid task identity",
          "#{path}.authority_grant_refs"
        )
      end

      def validate_task_revision_graph(tasks)
        tasks.group_by { |task| [task["project_id"], task["task_id"]] }.each do |scope, revisions|
          path = "task_revisions.#{scope.compact.join(".")}"
          genesis = revisions.select { |task| task["parent_task_revision_id"].nil? }
          revision_numbers = revisions.map { |task| task["revision_number"] }
          children = Hash.new { |hash, key| hash[key] = [] }
          revisions.each do |task|
            parent_id = task["parent_task_revision_id"]
            children[parent_id] << task if parent_id
          end

          unless genesis.length == 1 && genesis.first["revision_number"] == 1
            add(
              "task_lineage_invalid",
              "each task requires exactly one parentless revision-number-1 genesis",
              path
            )
          end
          expected_revisions = (1..revisions.length).to_a
          unless revision_numbers.all? { |number| number.is_a?(Integer) } &&
                 revision_numbers.sort == expected_revisions
            add(
              "task_lineage_invalid",
              "TaskRevision numbers must be unique, contiguous, and start at one",
              path
            )
          end
          children.each do |parent_id, child_revisions|
            next if child_revisions.length <= 1

            add(
              "task_lineage_invalid",
              "TaskRevision lineage is linear; #{parent_id} has multiple successors",
              path
            )
          end

          revision_index = revisions.to_h { |task| [task["task_revision_id"], task] }
          revisions.each do |task|
            next if task["parent_task_revision_id"].nil?

            parent = revision_index[task["parent_task_revision_id"]]
            unless parent &&
                   parent["revision_number"].is_a?(Integer) &&
                   task["revision_number"].is_a?(Integer) &&
                   task["revision_number"] == parent["revision_number"] + 1
              add(
                "task_lineage_invalid",
                "every non-genesis TaskRevision must pin its immediate predecessor",
                "#{path}.#{task["task_revision_id"]}.parent_task_revision_id"
              )
            end
          end

          reachable = Set.new
          cursor = genesis.length == 1 ? genesis.first : nil
          while cursor && reachable.add?(cursor["task_revision_id"])
            cursor = children[cursor["task_revision_id"]]&.first
          end
          unless reachable.length == revisions.length
            add(
              "task_lineage_invalid",
              "TaskRevision lineage contains an orphan, fork, or cycle",
              path
            )
          end
        end
      end

      def validate_task_authorization_reference(task, authorizations, path)
        authorization_ref = task["protected_change_authorization_ref"]
        return if authorization_ref.nil?

        unless authorizations.key?(authorization_ref)
          add(
            "task_authority_invalid",
            "protected_change_authorization_ref must resolve to an immutable AuthorizationRecord",
            "#{path}.protected_change_authorization_ref"
          )
          return
        end
        return unless task["parent_task_revision_id"].nil?

        add(
          "task_authority_invalid",
          "a genesis TaskRevision cannot claim protected-change authorization",
          "#{path}.protected_change_authorization_ref"
        )
      end

      def validate_task_parent(task, tasks, authorizations, active_policy, path)
        parent_id = task["parent_task_revision_id"]
        return if parent_id.nil?

        parent = tasks.find { |candidate| candidate["task_revision_id"] == parent_id }
        unless parent &&
               parent["project_id"] == task["project_id"] &&
               parent["task_id"] == task["task_id"] &&
               task["revision_number"] == parent["revision_number"].to_i + 1
          add("task_lineage_invalid", "TaskRevision parent must exist in the same task", "#{path}.parent_task_revision_id")
          return
        end

        parent_gates = gate_requirements_for(parent)
        current_gates = gate_requirements_for(task)
        parent_by_lineage = parent_gates.to_h { |gate| [gate["gate_lineage_id"], gate] }
        current_by_lineage = current_gates.to_h { |gate| [gate["gate_lineage_id"], gate] }
        parent_by_lineage.each do |lineage_id, parent_gate|
          child_gate = current_by_lineage[lineage_id]
          next unless child_gate

          parent_ref = child_gate["parent_gate_requirement_ref"]
          unless parent_ref.is_a?(Hash) &&
                 parent_ref["gate_requirement_id"] == parent_gate["gate_requirement_id"] &&
                 parent_ref["content_digest"] == parent_gate["content_digest"] &&
                 child_gate["task_revision_id"] == task["task_revision_id"]
            add(
              "protected_gate_lineage_invalid",
              "every inherited GateRequirement must be recreated for the child revision " \
                "and pin its exact parent, regardless of protection level",
              "#{path}.gate_requirement_refs"
            )
          end
        end

        authorization_required = ProtectedChange.authorization_required?(
          parent_gates,
          current_gates
        ) || Array(parent["authority_grant_refs"]).sort !=
          Array(task["authority_grant_refs"]).sort
        authorization_ref = task["protected_change_authorization_ref"]
        authorization = authorizations[authorization_ref]
        if authorization_required || !authorization_ref.nil?
          unless validate_protected_change_authorization(
            authorization,
            parent,
            task,
            parent_gates,
            current_gates,
            active_policy
          )
            add(
              "protected_gate_lineage_invalid",
              "protected gate changes require a provider-bound authorization for the exact " \
                "parent, candidate, and canonical diff",
              "#{path}.protected_change_authorization_ref"
            )
          end
        end
        unresolved = Array(parent["unresolved_finding_refs"]) - Array(task["unresolved_finding_refs"])
        unresolved.each do |finding_id|
          resolved = @indexes.fetch("finding_resolutions", {}).values.any? do |resolution|
            resolution["finding_id"] == finding_id
          end
          add(
            "protected_gate_lineage_invalid",
            "unresolved Finding #{finding_id} must carry forward",
            "#{path}.unresolved_finding_refs"
          ) unless resolved
        end
      end

      def validate_task_gate_ownership(task, path)
        requirements = @indexes.fetch("gate_requirements", {})
        lineage_ids = []
        Array(task["gate_requirement_refs"]).each do |id|
          requirement = requirements[id]
          unless requirement &&
                 requirement["project_id"] == task["project_id"] &&
                 requirement["task_id"] == task["task_id"] &&
                 requirement["task_revision_id"] == task["task_revision_id"]
            add(
              "gate_requirement_ownership_invalid",
              "every TaskRevision gate ref must resolve to a GateRequirement owned by that exact revision",
              "#{path}.gate_requirement_refs"
            )
            next
          end
          lineage_ids << requirement["gate_lineage_id"]
        end
        if lineage_ids.any?(&:nil?) || lineage_ids.uniq.length != lineage_ids.length
          add(
            "protected_gate_lineage_invalid",
            "a TaskRevision cannot contain duplicate or missing gate lineage identities",
            "#{path}.gate_requirement_refs"
          )
        end
      end

      def gate_requirements_for(task)
        return [] unless task.is_a?(Hash)

        Array(task["gate_requirement_refs"]).map do |id|
          @indexes.fetch("gate_requirements", {})[id]
        end.compact
      end

      def validate_protected_change_authorization(
        authorization,
        parent,
        candidate,
        parent_gates,
        candidate_gates,
        active_policy
      )
        return false unless authorization &&
                            active_policy &&
                            authorization["action"] == "task.protected_contract.change" &&
                            authorization["subject_ref"] == candidate["task_revision_id"] &&
                            authorization["project_id"] == candidate["project_id"] &&
                            authorization["project_policy_revision_id"] ==
                              active_policy["policy_revision_id"] &&
                            candidate.dig(
                              "project_policy_revision_ref",
                              "policy_revision_id"
                            ) == active_policy["policy_revision_id"] &&
                            candidate.dig(
                              "project_policy_revision_ref",
                              "content_digest"
                            ) == active_policy["content_digest"]

        envelope = authorization["protected_change_envelope"]
        assertion = @verified_authority_assertions[authorization["authorization_source_ref"]]
        policy = @indexes.fetch("project_policy_revisions", {})[
          authorization["project_policy_revision_id"]
        ]
        return false unless envelope.is_a?(Hash) &&
                            assertion &&
                            policy &&
                            policy["policy_revision_id"] == active_policy["policy_revision_id"] &&
                            policy["content_digest"] == active_policy["content_digest"]

        expected_change_digest = ProtectedChange.diff_digest(
          parent_task: parent,
          candidate_task: candidate,
          parent_gates: parent_gates,
          candidate_gates: candidate_gates
        )
        receipt = assertion["verification_receipt"]
        envelope["schema_version"] == "orbit-protected-change-authorization-v1" &&
          envelope["project_id"] == candidate["project_id"] &&
          envelope["task_id"] == candidate["task_id"] &&
          envelope["parent_task_revision_ref"] == {
            "task_revision_id" => parent["task_revision_id"],
            "content_digest" => parent["content_digest"]
          } &&
          envelope["candidate_task_revision_ref"] == {
            "task_revision_id" => candidate["task_revision_id"],
            "content_digest" => candidate["content_digest"]
          } &&
          envelope["protected_change_digest"] == expected_change_digest &&
          envelope["envelope_digest"] == ProtectedChange.envelope_digest(envelope) &&
          envelope["issuer_authority_ref"] == {
            "assertion_id" => assertion["assertion_id"],
            "assertion_digest" => assertion["assertion_digest"]
          } &&
          envelope["authority_source_revision_ref"] == {
            "provider_id" => assertion["provider_id"],
            "receipt_id" => receipt["receipt_id"],
            "assertion_id" => assertion["assertion_id"],
            "assertion_digest" => assertion["assertion_digest"]
          } &&
          envelope["project_policy_revision_ref"] == {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => policy["content_digest"]
          } &&
          envelope["decision"] == "approved" &&
          envelope["issued_at"] == receipt["issued_at"] &&
          authorization["authorization_source_ref"] == assertion["assertion_id"] &&
          authorization["authorization_assertion_digest"] == assertion["assertion_digest"] &&
          assertion["authority_scope_ref"] == expected_change_digest
      rescue KeyError, ArgumentError
        false
      end

      def validate_task_requirement_ids(task, path)
        {
          "acceptance" => "acceptance_id",
          "source_requirements" => "source_requirement_id",
          "evidence_requirements" => "evidence_requirement_id",
          "task_questions" => "question_id"
        }.each do |field, id_field|
          values = Array(task[field])
          ids = values.map { |entry| entry.is_a?(Hash) ? entry[id_field] : nil }
          if ids.any? { |id| !stable_contract_ref?(id) } || ids.uniq.length != ids.length
            add("task_contract_invalid", "#{field} requires unique stable IDs", "#{path}.#{field}")
          end
        end
      end

      def validate_policy_minimums(task, policy, path)
        return unless policy

        requirements = Array(task["gate_requirement_refs"]).map do |id|
          @indexes.fetch("gate_requirements", {})[id]
        end.compact
        Array(policy["protected_gate_minimums"]).each do |minimum|
          matching = requirements.select do |requirement|
            requirement["kind"] == minimum["gate_kind"]
          end
          protected_matching = matching.select do |requirement|
            requirement["protected"] == true
          end
          all_meet_minimum = protected_matching.all? do |requirement|
            evidence_level_at_least?(
              requirement["evidence_level"],
              minimum["evidence_level"]
            ) &&
              GateStrength.independence_at_least?(
                requirement["independence"],
                minimum["independence"]
              )
          end
          unless protected_matching.any? && all_meet_minimum
            add(
              "task_authority_invalid",
              "every matching protected GateRequirement must meet the ProjectPolicy minimum",
              "#{path}.gate_requirement_refs"
            )
          end
        end
      end

      def validate_gate_requirements(bundle)
        tasks = @indexes.fetch("task_revisions", {})
        requirements = @indexes.fetch("gate_requirements", {})
        lineage_scopes = {}
        requirements_by_lineage = Array(bundle["gate_requirements"])
          .select { |requirement| requirement.is_a?(Hash) }
          .group_by { |requirement| requirement["gate_lineage_id"] }
        Array(bundle["gate_requirements"]).each do |requirement|
          next unless requirement.is_a?(Hash)

          path = "gate_requirements.#{requirement["gate_requirement_id"]}"
          validate_identifier(
            "gate_lineage_id",
            requirement["gate_lineage_id"],
            "#{path}.gate_lineage_id"
          )
          lineage_scope = [requirement["project_id"], requirement["task_id"]]
          previous_scope = lineage_scopes[requirement["gate_lineage_id"]]
          if previous_scope && previous_scope != lineage_scope
            add(
              "protected_gate_lineage_invalid",
              "a stable gate_lineage_id cannot be reused across projects or tasks",
              "#{path}.gate_lineage_id"
            )
          else
            lineage_scopes[requirement["gate_lineage_id"]] = lineage_scope
          end
          task = tasks[requirement["task_revision_id"]]
          unless task && task["task_id"] == requirement["task_id"] &&
                 Array(task["gate_requirement_refs"]).include?(requirement["gate_requirement_id"])
            add("reference_not_found", "GateRequirement must be owned by its TaskRevision", path)
            next
          end
          parent_ref = requirement["parent_gate_requirement_ref"]
          parent_task_id = task["parent_task_revision_id"]
          inherited_parent = gate_requirements_for(tasks[parent_task_id]).find do |parent|
            parent["gate_lineage_id"] == requirement["gate_lineage_id"]
          end
          if inherited_parent
            unless exact_gate_parent_ref?(requirement, inherited_parent)
              add(
                "protected_gate_lineage_invalid",
                "an inherited GateRequirement requires the exact immediate-parent ref",
                "#{path}.parent_gate_requirement_ref"
              )
            end
          elsif parent_ref
            add(
              "protected_gate_lineage_invalid",
              "GateRequirement parent ref must resolve to the same lineage in the immediate parent TaskRevision",
              "#{path}.parent_gate_requirement_ref"
            )
          elsif prior_gate_lineage_reuse?(
            requirement,
            task,
            requirements_by_lineage[requirement["gate_lineage_id"]],
            tasks
          )
            add(
              "protected_gate_lineage_invalid",
              "a GateRequirement lineage cannot disappear and later reappear without an immediate-parent edge",
              "#{path}.parent_gate_requirement_ref"
            )
          end
          acceptance_ids = Array(task["acceptance"]).map { |entry| entry["acceptance_id"] }
          question_ids = Array(task["task_questions"]).map { |entry| entry["question_id"] }
          unless subset?(requirement["acceptance_refs"], acceptance_ids) &&
                 subset?(requirement["required_question_refs"], question_ids)
            add("gate_requirement_invalid", "gate refs must resolve to TaskRevision stable IDs", path)
          end
          selector = requirement["subject_selector"]
          unless selector.is_a?(Hash) &&
                 %w[task_wide selected_work_units].include?(selector["scope"]) &&
                 selector["work_unit_kind"] == "implementation" &&
                 selector["implementation_attempt_policy"] == "all_accepted_contributors_to_snapshot" &&
                 selector["evidence_record_policy"] == "all_accepted_required_evidence_for_selected_attempts" &&
                 selector["freshness"] == "exact_current_subject"
            add("gate_requirement_invalid", "GateRequirement subject selector is incomplete", "#{path}.subject_selector")
          end
          waiver = requirement["waiver_policy"]
          unless waiver.is_a?(Hash) &&
                 waiver["mode"] == "finding_resolution_only" &&
                 waiver["required_authorization_action"] == "finding.waive" &&
                 waiver["risk_authority_source"] == "project_policy_or_task_authorization"
            add("gate_requirement_invalid", "GateRequirement waiver policy cannot be free-form or Lead-owned", "#{path}.waiver_policy")
          end
        end
      end

      def exact_gate_parent_ref?(requirement, parent)
        ref = requirement["parent_gate_requirement_ref"]
        ref.is_a?(Hash) &&
          ref["gate_requirement_id"] == parent["gate_requirement_id"] &&
          ref["content_digest"] == parent["content_digest"] &&
          parent["project_id"] == requirement["project_id"] &&
          parent["task_id"] == requirement["task_id"] &&
          parent["gate_lineage_id"] == requirement["gate_lineage_id"]
      end

      def prior_gate_lineage_reuse?(requirement, task, lineage_requirements, tasks)
        Array(lineage_requirements).any? do |other|
          next false if other["gate_requirement_id"] == requirement["gate_requirement_id"]
          next false unless other["project_id"] == requirement["project_id"] &&
                            other["task_id"] == requirement["task_id"]

          other_task = tasks[other["task_revision_id"]]
          other_task &&
            other_task["revision_number"].is_a?(Integer) &&
            task["revision_number"].is_a?(Integer) &&
            other_task["revision_number"] < task["revision_number"]
        end
      end

      def validate_work_units(bundle)
        tasks = @indexes.fetch("task_revisions", {})
        Array(bundle["work_units"]).each do |unit|
          next unless unit.is_a?(Hash)

          path = "work_units.#{unit["work_unit_id"]}"
          task = tasks[unit["task_revision_id"]]
          unless task && task["task_id"] == unit["task_id"]
            add("reference_not_found", "WorkUnit TaskRevision does not exist", path)
            next
          end
          FORBIDDEN_WORK_UNIT_FACTS.each do |field|
            if unit.key?(field)
              add(
                "forbidden_second_fact_source",
                "WorkUnit cannot own task or assignment fact #{field}",
                "#{path}.#{field}"
              )
            end
          end
          {
            "acceptance_refs" => Array(task["acceptance"]).map { |entry| entry["acceptance_id"] },
            "evidence_requirement_refs" => Array(task["evidence_requirements"]).map { |entry| entry["evidence_requirement_id"] },
            "source_requirement_refs" => Array(task["source_requirements"]).map { |entry| entry["source_requirement_id"] }
          }.each do |field, allowed|
            add("work_unit_contract_invalid", "#{field} contains an unknown TaskRevision ref", "#{path}.#{field}") unless subset?(unit[field], allowed)
          end
          authority_scope = unit["authority_scope"]
          allowed_actions = Array(authority_scope && authority_scope["allowed_actions"])
          forbidden_actions = Array(authority_scope && authority_scope["forbidden_actions"])
          authorization_refs =
            Array(authority_scope && authority_scope["authorization_record_refs"])
          unless (allowed_actions & forbidden_actions).empty?
            add(
              "work_unit_authority_invalid",
              "WorkUnit authority cannot both allow and forbid the same action",
              "#{path}.authority_scope"
            )
          end
          unless allowed_actions.all? { |action| WorkAuthority.action?(action) }
            add(
              "work_unit_authority_invalid",
              "WorkUnit allowed_actions must use stable executable work authority actions",
              "#{path}.authority_scope.allowed_actions"
            )
          end
          if authorization_refs.empty?
            add(
              "work_unit_authority_missing",
              "every executable WorkUnit requires exact AuthorizationRecord provenance",
              "#{path}.authority_scope.authorization_record_refs"
            )
          end
          authorization_refs.each do |record_id|
            record = @indexes.fetch("authorization_records", {})[record_id]
            unless record &&
                   allowed_actions.include?(record["action"]) &&
                   valid_work_authorization?(
                     record,
                     task: task,
                     unit: unit,
                     action: record["action"]
                   )
              add(
                "work_unit_authority_invalid",
                "WorkUnit authority refs require an allowed action and exact canonical work scope",
                "#{path}.authority_scope.authorization_record_refs"
              )
            end
          end
          allowed_actions.each do |action|
            authorized = authorization_refs.any? do |record_id|
              valid_work_authorization?(
                @indexes.fetch("authorization_records", {})[record_id],
                task: task,
                unit: unit,
                action: action
              )
            end
            unless authorized
              add(
                "work_unit_authority_missing",
                "each allowed executable action requires an exact AuthorizationRecord",
                "#{path}.authority_scope.authorization_record_refs"
              )
            end
          end
          writable_paths = Array(authority_scope && authority_scope["writable_paths"])
          expected_non_empty = unit["work_unit_kind"] == "implementation"
          unless PathScope.canonical_set?(
            writable_paths,
            allow_empty: !expected_non_empty
          ) && (expected_non_empty || writable_paths.empty?)
            add(
              "work_unit_authority_invalid",
              "implementation WorkUnits require a canonical sorted writable path set; " \
                "non-implementation WorkUnits cannot claim code-write paths",
              "#{path}.authority_scope.writable_paths"
            )
          end
          unless %w[implementation evaluation research release].include?(unit["work_unit_kind"])
            add("work_unit_contract_invalid", "work_unit_kind is not stable", "#{path}.work_unit_kind")
          end
          validate_initial_change_thesis_ref(unit, path)
        end
      end

      def validate_change_theses(bundle)
        units = @indexes.fetch("work_units", {})
        grouped = Hash.new { |hash, key| hash[key] = [] }
        Array(bundle["change_theses"]).each do |thesis|
          next unless thesis.is_a?(Hash)

          path = "change_theses.#{thesis["change_thesis_id"]}:#{thesis["revision"]}"
          unit = units[thesis["work_unit_id"]]
          unless unit &&
                 unit["project_id"] == thesis["project_id"] &&
                 unit["task_id"] == thesis["task_id"] &&
                 unit["task_revision_id"] == thesis["task_revision_id"]
            add(
              "change_thesis_lineage_invalid",
              "ChangeThesis must belong to one exact project/task/revision/WorkUnit lineage",
              path
            )
          end
          unless thesis["revision"].is_a?(Integer) && thesis["revision"].positive?
            add("change_thesis_invalid", "ChangeThesis revision must be positive", "#{path}.revision")
          end
          %w[
            observed_problem root_cause_status system_property smallest_sufficient_mechanism
            expected_benefit introduced_cost blast_radius disconfirming_evidence
          ].each do |field|
            add("change_thesis_invalid", "ChangeThesis requires #{field}", "#{path}.#{field}") unless thesis.key?(field)
          end
          grouped[thesis["change_thesis_id"]] << thesis
        end
        grouped.each do |thesis_id, revisions|
          ownership = revisions.map do |thesis|
            [
              thesis["project_id"],
              thesis["task_id"],
              thesis["task_revision_id"],
              thesis["work_unit_id"]
            ]
          end.uniq
          if ownership.length != 1
            add(
              "change_thesis_lineage_invalid",
              "ChangeThesis #{thesis_id} cannot cross project/task/revision/WorkUnit ownership",
              "change_theses.#{thesis_id}"
            )
          end
          numbers = revisions.map { |thesis| thesis["revision"] }.sort
          unless numbers.count(1) == 1
            add(
              "change_thesis_lineage_invalid",
              "ChangeThesis #{thesis_id} lineage requires exactly one revision 1 genesis",
              "change_theses.#{thesis_id}"
            )
          end
          unless numbers.empty? || numbers == (1..numbers.last).to_a
            add(
              "change_thesis_lineage_invalid",
              "ChangeThesis #{thesis_id} revisions must be contiguous from revision 1",
              "change_theses.#{thesis_id}"
            )
          end
        end
      end

      def validate_initial_change_thesis_ref(unit, path)
        ref = unit["initial_change_thesis_ref"]
        thesis = thesis_for_ref(ref)
        unless thesis &&
               thesis["project_id"] == unit["project_id"] &&
               thesis["task_id"] == unit["task_id"] &&
               thesis["task_revision_id"] == unit["task_revision_id"] &&
               thesis["work_unit_id"] == unit["work_unit_id"] &&
               thesis["revision"] == 1 &&
               ref["revision"] == 1
          add(
            "change_thesis_lineage_invalid",
            "WorkUnit initial ChangeThesis ref must resolve the exact revision 1 genesis and ownership",
            "#{path}.initial_change_thesis_ref"
          )
          return
        end
        revisions = @indexes.fetch("change_theses", {}).values.select do |candidate|
          candidate["change_thesis_id"] == thesis["change_thesis_id"] &&
            candidate["work_unit_id"] == unit["work_unit_id"]
        end.map { |candidate| candidate["revision"] }
        if revisions.any? { |revision| revision < thesis["revision"] }
          add(
            "change_thesis_lineage_invalid",
            "WorkUnit initial ChangeThesis ref must pin the first revision in its lineage",
            "#{path}.initial_change_thesis_ref"
          )
        end
      end

      def validate_attempt_thesis_ref(attempt, unit, ref, path)
        thesis = thesis_for_ref(ref)
        initial = unit && unit["initial_change_thesis_ref"]
        initial_thesis = thesis_for_ref(initial)
        unless thesis &&
               initial_thesis &&
               thesis["project_id"] == attempt["project_id"] &&
               thesis["task_id"] == attempt["task_id"] &&
               thesis["task_revision_id"] == attempt["task_revision_id"] &&
               thesis["work_unit_id"] == attempt["work_unit_id"] &&
               thesis["change_thesis_id"] == initial_thesis["change_thesis_id"] &&
               thesis["revision"] >= initial_thesis["revision"]
          add(
            "change_thesis_lineage_invalid",
            "Attempt must pin the WorkUnit initial ChangeThesis or a same-lineage successor",
            path
          )
          return
        end
        present = @indexes.fetch("change_theses", {}).values.select do |candidate|
          candidate["change_thesis_id"] == thesis["change_thesis_id"] &&
            candidate["work_unit_id"] == thesis["work_unit_id"] &&
            candidate["revision"].between?(initial_thesis["revision"], thesis["revision"])
        end.map { |candidate| candidate["revision"] }.sort
        expected = (initial_thesis["revision"]..thesis["revision"]).to_a
        unless present == expected
          add(
            "change_thesis_lineage_invalid",
            "Attempt ChangeThesis successor chain contains a missing revision",
            path
          )
        end
      end

      def thesis_for_ref(ref)
        return nil unless ref.is_a?(Hash)

        thesis = @indexes.fetch("change_theses", {})[
          [ref["change_thesis_id"], ref["revision"]]
        ]
        if thesis && thesis["content_digest"] == ref["content_digest"]
          thesis
        else
          nil
        end
      end

      def agent_context_generations(agent)
        Array(agent && agent["lifecycle_events"]).each_with_object([]) do |event, generations|
          if %w[AgentCreated AgentContextAdvanced].include?(event["event_type"])
            generations << event["context_generation"]
          end
        end
      end

      def assignment_binding_valid?(assignment, unit, agent)
        binding = ASSIGNMENT_BINDINGS[assignment && assignment["purpose"]]
        created = Array(agent && agent["lifecycle_events"]).first
        return false unless binding && unit && agent && created

        assignment["resolved_role"] == binding["resolved_role"] &&
          created["role"] == binding["resolved_role"] &&
          WorkAuthority.purpose_allowed_for_kind?(
            assignment["purpose"],
            unit["work_unit_kind"]
          ) &&
          agent_context_generations(agent).include?(assignment["context_generation"]) &&
          Array(agent.dig("capability_profile", "capabilities")).include?(
            binding["capability"]
          ) &&
          Array(agent.dig("permission_profile", "permissions")).include?(
            binding["permission"]
          ) &&
          Array(unit.dig("authority_scope", "allowed_actions")).include?(
            binding["authority_action"]
          )
      end

      def validate_assignment_binding(assignment, unit, agent, path)
        return if assignment_binding_valid?(assignment, unit, agent)

        binding = ASSIGNMENT_BINDINGS[assignment && assignment["purpose"]]
        expected = if binding
                     binding.values_at(
                       "resolved_role",
                       "capability",
                       "permission",
                       "authority_action"
                     ).join("/")
                   else
                     "known purpose binding"
                   end
        add(
          "attempt_assignment_invalid",
          "Assignment purpose must bind the WorkUnit kind plus authoritative AgentInstance " \
            "role/context, capability, permission, and action (#{expected})",
          path
        )
      end

      def validate_agent_context_lineage(agent, path)
        generations = agent_context_generations(agent)
        return if generations.empty?

        expected = (generations.first...(generations.first + generations.length)).to_a
        unless generations == expected
          add(
            "agent_lifecycle_invalid",
            "Agent context generations must advance contiguously without overwrite",
            "#{path}.lifecycle_events"
          )
        end
      end

      def validate_attempt_agent_chronology(agent, created, assignment, path)
        return unless agent && created.is_a?(Hash) && assignment.is_a?(Hash)

        attempt_created_at = Time.iso8601(created.fetch("recorded_at"))
        agent_events = Array(agent["lifecycle_events"])
        agent_created = agent_events.first
        context_event = agent_events.find do |event|
          %w[AgentCreated AgentContextAdvanced].include?(event["event_type"]) &&
            event["context_generation"] == assignment["context_generation"]
        end
        terminated = agent_events.find do |event|
          event["event_type"] == "AgentTerminated"
        end
        active = agent_created &&
          Time.iso8601(agent_created.fetch("recorded_at")) <= attempt_created_at &&
          context_event &&
          Time.iso8601(context_event.fetch("recorded_at")) <= attempt_created_at &&
          (
            terminated.nil? ||
            attempt_created_at < Time.iso8601(terminated.fetch("recorded_at"))
          )
        return if active

        add(
          "attempt_agent_lifecycle_invalid",
          "AttemptCreated requires an active AgentInstance whose exact context generation " \
            "already exists at the trusted creation time",
          path
        )
      rescue ArgumentError, KeyError, TypeError
        add(
          "attempt_agent_lifecycle_invalid",
          "Attempt/Agent cross-stream chronology must use parseable trusted timestamps",
          path
        )
      end

      def validate_agents(bundle)
        Array(bundle["agent_instances"]).each do |agent|
          next unless agent.is_a?(Hash)

          path = "agent_instances.#{agent["agent_instance_id"]}"
          unless agent["object_type"] == "agent_instance"
            add("agent_runtime_invalid", "AgentInstance object_type is required", "#{path}.object_type")
          end
          validate_event_chain(
            agent["lifecycle_events"],
            path,
            stream: "agent",
            field: "lifecycle_events",
            project_id: agent["project_id"]
          )
          validate_agent_context_lineage(agent, path)
          check("#{path}.runtime_identity") do
            identity_key = @runtime_identity_verifier.verify!(agent)
            existing_agent_id = @verified_runtime_identities[identity_key]
            if existing_agent_id &&
               existing_agent_id != agent["agent_instance_id"]
              add(
                "runtime_identity_duplicate",
                "one verified provider runtime subject cannot back multiple AgentInstance IDs",
                "#{path}.runtime_identity",
                "existing_agent_instance_id" => existing_agent_id
              )
            else
              @verified_runtime_identities[identity_key] =
                agent["agent_instance_id"]
            end
          end
        end
      end

      def validate_logical_leads(bundle)
        task_ids = @indexes.fetch("task_revisions", {}).values.map { |task| task["task_id"] }.uniq
        Array(bundle["logical_leads"]).each do |lead|
          next unless lead.is_a?(Hash)

          path = "logical_leads.#{lead["logical_lead_id"]}"
          unless lead["object_type"] == "logical_lead" && task_ids.include?(lead["task_id"])
            add(
              "logical_lead_invalid",
              "LogicalLead must bind an existing task orchestration identity",
              path
            )
          end
        end
      end

      def validate_lead_sessions(bundle)
        leads = @indexes.fetch("logical_leads", {})
        agents = @indexes.fetch("agent_instances", {})
        tasks = @indexes.fetch("task_revisions", {})
        Array(bundle["lead_sessions"]).each do |session|
          next unless session.is_a?(Hash)

          path = "lead_sessions.#{session["lead_session_id"]}"
          lead = leads[session["logical_lead_id"]]
          agent = agents[session["agent_instance_id"]]
          task = tasks[session["task_revision_id"]]
          unless session["object_type"] == "lead_session" &&
                 lead &&
                 agent &&
                 task &&
                 lead["task_id"] == session["task_id"] &&
                 task["task_id"] == session["task_id"]
            add(
              "lead_session_invalid",
              "LeadSession must bind one LogicalLead, AgentInstance, task, and revision",
              path
            )
          end
          unless lead && lead["durable_context_ref"] == session["durable_context_ref"]
            add(
              "lead_session_invalid",
              "LeadSession recovery context must match its LogicalLead durable context",
              "#{path}.durable_context_ref"
            )
          end
          capabilities = Array(agent&.dig("capability_profile", "capabilities"))
          permissions = Array(agent&.dig("permission_profile", "permissions"))
          unless capabilities.include?("task.orchestrate") &&
                 permissions.include?("task_revision.propose")
            add(
              "lead_session_invalid",
              "LeadSession AgentInstance lacks orchestration capability or permission",
              "#{path}.agent_instance_id"
            )
          end
          validate_event_chain(
            session["lifecycle_events"],
            path,
            stream: "lead_session",
            field: "lifecycle_events",
            project_id: session["project_id"]
          )
          started = Array(session["lifecycle_events"]).first
          unless started &&
                 started["context_generation"] == session["session_generation"] &&
                 agent_context_generations(agent).include?(started["context_generation"])
            add(
              "lead_session_invalid",
              "LeadSession start must bind its session generation to an existing Agent context",
              "#{path}.lifecycle_events[0].context_generation"
            )
          end
        end
      end

      def validate_attempts(bundle, active_policy)
        units = @indexes.fetch("work_units", {})
        agents = @indexes.fetch("agent_instances", {})
        rules = @indexes.fetch("rule_resolution_artifacts", {})
        tasks = @indexes.fetch("task_revisions", {})
        Array(bundle["work_unit_attempts"]).each do |attempt|
          next unless attempt.is_a?(Hash)

          path = "work_unit_attempts.#{attempt["attempt_id"]}"
          unless attempt["object_type"] == "work_unit_attempt"
            add("attempt_lifecycle_invalid", "WorkUnitAttempt object_type is required", "#{path}.object_type")
          end
          %w[assignment agent_instance_id context_generation started_at ended_at status].each do |field|
            if attempt.key?(field)
              add("attempt_lifecycle_invalid", "Attempt #{field} must derive from append-only events", "#{path}.#{field}")
            end
          end
          validate_event_chain(
            attempt["events"],
            path,
            stream: "attempt",
            field: "events",
            project_id: attempt["project_id"]
          )
          created = Array(attempt["events"]).first
          next unless created.is_a?(Hash)

          assignment = created["assignment"]
          unless assignment.is_a?(Hash)
            add("attempt_lifecycle_invalid", "AttemptCreated requires immutable assignment", "#{path}.events[0].assignment")
            next
          end
          unless created["started_at"].is_a?(String) && created["status"] == "active"
            add(
              "attempt_lifecycle_invalid",
              "AttemptCreated is the only started_at source and must establish active status",
              "#{path}.events[0]"
            )
          end
          unit = units[attempt["work_unit_id"]]
          unless unit &&
                 unit["project_id"] == attempt["project_id"] &&
                 unit["task_id"] == attempt["task_id"] &&
                 unit["task_revision_id"] == attempt["task_revision_id"]
            add(
              "attempt_lineage_invalid",
              "Attempt and WorkUnit must share exact project/task/revision identity",
              path
            )
          end
          agent = agents[assignment["agent_instance_id"]]
          add("reference_not_found", "Attempt AgentInstance does not exist", "#{path}.events[0].assignment.agent_instance_id") unless agent
          thesis_ref = assignment["change_thesis_ref"]
          validate_attempt_thesis_ref(
            attempt,
            unit,
            thesis_ref,
            "#{path}.events[0].assignment.change_thesis_ref"
          )
          rule = rules[assignment["assigned_rule_resolution_id"]]
          add("reference_not_found", "Attempt assigned RuleResolution does not exist", "#{path}.events[0].assignment.assigned_rule_resolution_id") unless rule
          validate_assignment_binding(
            assignment,
            unit,
            agent,
            "#{path}.events[0].assignment"
          )
          validate_attempt_agent_chronology(
            agent,
            created,
            assignment,
            "#{path}.events[0].assignment"
          )
          authority = assignment["authority_snapshot"]
          policy_ref = authority.is_a?(Hash) && authority["project_policy_revision_ref"]
          policy = policy_ref.is_a?(Hash) &&
            @indexes["project_policy_revisions"][policy_ref["policy_revision_id"]]
          task = tasks[attempt["task_revision_id"]]
          task_policy_ref = task && task["project_policy_revision_ref"]
          unless policy && policy["content_digest"] == policy_ref["content_digest"]
            add(
              "attempt_authority_invalid",
              "Attempt assignment must pin an immutable ProjectPolicyRevision ID/digest",
              "#{path}.events[0].assignment.authority_snapshot"
            )
          end
          unless task_policy_ref.is_a?(Hash) &&
                 policy_ref.is_a?(Hash) &&
                 CanonicalJSON.dump(task_policy_ref) == CanonicalJSON.dump(policy_ref)
            add(
              "attempt_authority_invalid",
              "Attempt authority snapshot must exactly equal its TaskRevision policy ref",
              "#{path}.events[0].assignment.authority_snapshot.project_policy_revision_ref"
            )
          end
          if active_policy &&
             task_policy_ref&.dig("policy_revision_id") != active_policy["policy_revision_id"] &&
             !historical_attempt_before_policy_replacement?(attempt, task_policy_ref)
            add(
              "attempt_authority_stale",
              "an active or post-rotation Attempt cannot continue under a stale TaskRevision policy",
              path
            )
          end
          actual_attempt_refs =
            Array(authority && authority["authorization_record_refs"])
          actual_attempt_refs.each do |record_id|
            record = @indexes["authorization_records"][record_id]
            action = WorkAuthority.action_for_purpose(assignment["purpose"])
            unless record &&
                   valid_work_authorization?(
                     record,
                     task: task,
                     unit: unit,
                     action: action
                   )
              add(
                "attempt_authority_invalid",
                "Attempt authority refs require the assignment action and exact canonical WorkUnit scope",
                "#{path}.events[0].assignment.authority_snapshot.authorization_record_refs"
              )
            end
          end
          expected_attempt_refs = Array(unit&.dig("authority_scope", "authorization_record_refs"))
            .select do |record_id|
              @indexes.dig("authorization_records", record_id, "action") ==
                WorkAuthority.action_for_purpose(assignment["purpose"])
            end
            .sort
          if expected_attempt_refs.empty? || actual_attempt_refs.empty?
            add(
              "attempt_authority_missing",
              "AttemptCreated must pin at least one exact AuthorizationRecord for its purpose",
              "#{path}.events[0].assignment.authority_snapshot.authorization_record_refs"
            )
          end
          actual_attempt_refs = actual_attempt_refs.sort
          unless actual_attempt_refs == expected_attempt_refs
            add(
              "attempt_authority_invalid",
              "Attempt authority snapshot must pin exactly the WorkUnit records for its assignment purpose",
              "#{path}.events[0].assignment.authority_snapshot.authorization_record_refs"
            )
          end
        end
      end

      def valid_work_authorization?(record, task:, unit:, action:)
        return false unless record && task && unit && WorkAuthority.action?(action)

        record["project_id"] == unit["project_id"] &&
          record["project_policy_revision_id"] ==
            task.dig("project_policy_revision_ref", "policy_revision_id") &&
          record["action"] == action &&
          Array(unit.dig("authority_scope", "allowed_actions")).include?(action) &&
          record["subject_ref"] == WorkAuthority.scope_digest(unit, task, action)
      rescue KeyError, ArgumentError
        false
      end

      def validate_event_chain(events, path, stream:, field:, project_id:)
        unless events.is_a?(Array) && !events.empty?
          add("append_only_chain_invalid", "event stream cannot be empty", "#{path}.#{field}")
          return
        end
        contract = EVENT_STREAMS.fetch(stream)
        seen = Set.new
        previous_digest = nil
        previous_recorded_at = nil
        terminal_seen = false
        events.each_with_index do |event, index|
          event_path = "#{path}.#{field}[#{index}]"
          unless event.is_a?(Hash)
            add("append_only_chain_invalid", "event must be an object", event_path)
            next
          end
          validate_identifier("event_id", event["event_id"], "#{event_path}.event_id")
          add("append_only_chain_invalid", "event ID is reused", "#{event_path}.event_id") unless seen.add?(event["event_id"])
          event_id = event["event_id"]
          if @event_ids.key?(event_id)
            code = CanonicalJSON.dump(@event_ids[event_id]) == CanonicalJSON.dump(event) ?
              "duplicate_identity" : "append_only_event_reuse"
            add(
              code,
              "event ID is globally create-only and cannot be reused across lifecycle streams",
              "#{event_path}.event_id"
            )
          else
            @event_ids[event_id] = event
          end
          event_type = event["event_type"]
          unless contract["allowed"].include?(event_type)
            add(
              "append_only_chain_invalid",
              "#{event_type.inspect} is not a typed #{stream} lifecycle event",
              "#{event_path}.event_type"
            )
          end
          if index.zero? && event_type != contract["initial"]
            add(
              "append_only_chain_invalid",
              "first event must be #{contract["initial"]}",
              "#{event_path}.event_type"
            )
          elsif index.positive? && event_type == contract["initial"]
            add(
              "append_only_chain_invalid",
              "#{contract["initial"]} can occur only once",
              "#{event_path}.event_type"
            )
          end
          if terminal_seen
            add(
              "append_only_chain_invalid",
              "no lifecycle event may follow a terminal event",
              event_path
            )
          end
          if contract["terminal"].include?(event_type)
            if terminal_seen
              add(
                "append_only_chain_invalid",
                "event stream may contain only one terminal event",
                "#{event_path}.event_type"
              )
            end
            terminal_seen = true
          end
          unless event["previous_event_digest"] == previous_digest
            add("append_only_chain_invalid", "event does not extend previous digest", "#{event_path}.previous_event_digest")
          end
          expected = CanonicalJSON.digest_excluding(
            event,
            "event_digest",
            "writer_receipt",
            "created_at",
            "accepted_at",
            "envelope"
          )
          unless event["event_digest"] == expected
            add("digest_mismatch", "event digest does not match canonical content", "#{event_path}.event_digest")
          end
          recorded_at = parse_lifecycle_time(
            event["recorded_at"],
            "#{event_path}.recorded_at"
          )
          if recorded_at && previous_recorded_at && recorded_at <= previous_recorded_at
            add(
              "lifecycle_chronology_invalid",
              "lifecycle recorded_at values must increase strictly in append order",
              "#{event_path}.recorded_at"
            )
          end
          if index.zero?
            started_at = parse_lifecycle_time(
              event["started_at"],
              "#{event_path}.started_at"
            )
            if started_at && recorded_at && started_at != recorded_at
              add(
                "lifecycle_chronology_invalid",
                "initial started_at must equal the trusted writer recorded_at",
                "#{event_path}.started_at"
              )
            end
          elsif contract["terminal"].include?(event_type)
            ended_at = parse_lifecycle_time(
              event["ended_at"],
              "#{event_path}.ended_at"
            )
            if ended_at && recorded_at && ended_at != recorded_at
              add(
                "lifecycle_chronology_invalid",
                "terminal ended_at must equal the trusted writer recorded_at",
                "#{event_path}.ended_at"
              )
            end
          end
          begin
            @lifecycle_verifier.verify!(event, project_id: project_id)
          rescue ContractError => e
            add(e.code, e.message, "#{event_path}.writer_receipt", e.details)
          end
          previous_recorded_at = recorded_at if recorded_at
          previous_digest = event["event_digest"]
        end
      end

      def parse_lifecycle_time(value, path)
        Time.iso8601(value)
      rescue ArgumentError, TypeError
        add(
          "lifecycle_chronology_invalid",
          "lifecycle timestamps must be parseable ISO-8601 values",
          path
        )
        nil
      end

      def attempt_terminal?(attempt)
        last_event = Array(attempt && attempt["events"]).last
        last_event.is_a?(Hash) &&
          EVENT_STREAMS.fetch("attempt").fetch("terminal").include?(last_event["event_type"])
      end

      def historical_attempt_before_policy_replacement?(attempt, policy_ref)
        return false unless attempt_terminal?(attempt)

        created = Array(attempt["events"]).first
        terminal = Array(attempt["events"]).last
        cutoff = policy_replacement_cutoff(policy_ref && policy_ref["policy_revision_id"])
        started_at = Time.iso8601(created["started_at"])
        ended_at = Time.iso8601(terminal["ended_at"])
        cutoff &&
          started_at <= ended_at &&
          started_at < cutoff &&
          ended_at < cutoff
      rescue ArgumentError, TypeError
        false
      end

      def historical_evidence_before_policy_replacement?(record, attempt, policy_ref)
        return false unless historical_attempt_before_policy_replacement?(attempt, policy_ref)

        started_at = Time.iso8601(attempt.dig("events", 0, "started_at"))
        accepted_at = Time.iso8601(record["acceptance_recorded_at"])
        cutoff = policy_replacement_cutoff(policy_ref && policy_ref["policy_revision_id"])
        cutoff && accepted_at >= started_at && accepted_at < cutoff
      rescue ArgumentError, TypeError
        false
      end

      def policy_replacement_cutoff(policy_revision_id)
        successor = @indexes.fetch("project_policy_revisions", {}).values.find do |policy|
          policy["parent_policy_revision_id"] == policy_revision_id
        end
        assertion = successor &&
          @verified_authority_assertions[successor["authorization_source_ref"]]
        issued_at = assertion&.dig("policy_issuance_envelope", "issued_at")
        issued_at && Time.iso8601(issued_at)
      rescue ArgumentError, TypeError
        nil
      end

      def validate_rule_resolutions(bundle)
        attempts = @indexes.fetch("work_unit_attempts", {})
        Array(bundle["rule_resolution_artifacts"]).each do |artifact|
          next unless artifact.is_a?(Hash)

          check("rule_resolution_artifacts.#{artifact["resolution_id"]}") do
            RuleResolution.validate!(artifact, project_root: @project_root)
          end
          identity = artifact["identity"]
          next unless identity.is_a?(Hash)

          attempt = attempts[identity["attempt_id"]]
          unless attempt
            add("rule_resolution_identity_mismatch", "RuleResolution Attempt does not exist", "rule_resolution.identity.attempt_id")
            next
          end
          assignment = attempt.fetch("events").first["assignment"] || {}
          expected = {
            "project_id" => attempt["project_id"],
            "task_id" => attempt["task_id"],
            "task_revision_id" => attempt["task_revision_id"],
            "work_unit_id" => attempt["work_unit_id"],
            "attempt_id" => attempt["attempt_id"],
            "resolved_role" => assignment["resolved_role"],
            "agent_instance_id" => assignment["agent_instance_id"],
            "context_generation" => assignment["context_generation"]
          }
          expected.each do |field, value|
            if identity[field] != value
              add("rule_resolution_identity_mismatch", "#{field} does not match Attempt assignment", "rule_resolution.identity.#{field}")
            end
          end
        end
      end

      def validate_evidence_records(bundle, active_policy)
        attempts = @indexes.fetch("work_unit_attempts", {})
        rules = @indexes.fetch("rule_resolution_artifacts", {})
        tasks = @indexes.fetch("task_revisions", {})
        Array(bundle["evidence_records"]).each do |record|
          next unless record.is_a?(Hash)

          path = "evidence_records.#{record["evidence_record_id"]}"
          attempt = attempts[record["attempt_id"]]
          unless attempt
            add("reference_not_found", "EvidenceRecord Attempt does not exist", "#{path}.attempt_id")
            next
          end
          assignment = attempt.fetch("events").first.fetch("assignment")
          submitted = rules[record["submitted_rule_resolution_id"]]
          assigned_id = assignment["assigned_rule_resolution_id"]
          unless submitted && submitted["resolution_id"] == assigned_id
            add("rule_resolution_identity_mismatch", "submitted rules must equal assigned canonical identity", "#{path}.submitted_rule_resolution_id")
          end
          unit = @indexes.fetch("work_units", {})[attempt["work_unit_id"]]
          unless unit &&
                 record["project_id"] == attempt["project_id"] &&
                 record["project_id"] == unit["project_id"] &&
                 record["task_id"] == attempt["task_id"] &&
                 record["task_id"] == unit["task_id"] &&
                 record["task_revision_id"] == attempt["task_revision_id"] &&
                 record["task_revision_id"] == unit["task_revision_id"] &&
                 record["work_unit_id"] == attempt["work_unit_id"] &&
                 record["work_unit_id"] == unit["work_unit_id"]
            add(
              "evidence_record_invalid",
              "EvidenceRecord must share exact project/task/revision/WorkUnit identity with its Attempt",
              path
            )
          end
          unless record["accepted"] == true
            add("evidence_record_invalid", "authoritative EvidenceRecord must be accepted at create time", "#{path}.accepted")
          end
          acceptance_recorded_at = begin
            Time.iso8601(record["acceptance_recorded_at"])
          rescue ArgumentError, TypeError
            add(
              "evidence_record_invalid",
              "EvidenceRecord acceptance_recorded_at must be an ISO-8601 timestamp",
              "#{path}.acceptance_recorded_at"
            )
            nil
          end
          attempt_started_at = begin
            Time.iso8601(attempt.dig("events", 0, "started_at"))
          rescue ArgumentError, TypeError
            nil
          end
          if acceptance_recorded_at &&
             attempt_started_at &&
             acceptance_recorded_at < attempt_started_at
            add(
              "evidence_chronology_invalid",
              "EvidenceRecord acceptance cannot precede its Attempt start",
              "#{path}.acceptance_recorded_at"
            )
          end
          task = tasks[record["task_revision_id"]]
          task_policy_ref = task && task["project_policy_revision_ref"]
          if active_policy &&
             task_policy_ref&.dig("policy_revision_id") != active_policy["policy_revision_id"] &&
             !historical_evidence_before_policy_replacement?(
               record,
               attempt,
               task_policy_ref
             )
            add(
              "evidence_authority_stale",
              "accepted evidence cannot be created at or after replacement of its TaskRevision policy",
              path
            )
          end
          if record["record_kind"] == "evaluator_submission"
            FORBIDDEN_EVALUATOR_EVIDENCE_FACTS.each do |field|
              if record.key?(field)
                add(
                  "forbidden_second_fact_source",
                  "evaluator EvidenceRecord cannot own #{field}",
                  "#{path}.#{field}"
                )
              end
            end
          elsif record["record_kind"] != "implementation"
            add("evidence_record_invalid", "record_kind is unsupported", "#{path}.record_kind")
          end
          if %w[implementation evaluator_submission].include?(record["record_kind"])
            @errors.concat(
              EvidenceContract.validate(
                record: record,
                work_unit: unit,
                task_revision: task,
                assignment: assignment,
                code_surface: bundle["code_surface"]
              )
            )
          end
          validate_supersedes(
            record,
            "supersedes_evidence_record_id",
            @graphs.fetch("evidence_records"),
            "evidence_record_id",
            path,
            same_scope: %w[project_id task_id task_revision_id work_unit_id record_kind]
          )
          validate_related_refs(
            record,
            "related_evidence_record_refs",
            @graphs.fetch("evidence_records"),
            "evidence_record_id",
            path
          ) do |left, right|
            %w[project_id task_id task_revision_id].all? do |field|
              left[field] == right[field]
            end
          end
        end
        validate_supersedes_cycles(
          @graphs.fetch("evidence_records"),
          "supersedes_evidence_record_id",
          "evidence_record_id",
          "evidence_records"
        )
      end

      def validate_gate_evaluations(bundle, active_policy)
        tasks = @indexes.fetch("task_revisions", {})
        requirements = @indexes.fetch("gate_requirements", {})
        attempts = Array(bundle["work_unit_attempts"])
        records = Array(bundle["evidence_records"])
        units = Array(bundle["work_units"])
        Array(bundle["gate_evaluations"]).each do |evaluation|
          next unless evaluation.is_a?(Hash)

          path = "gate_evaluations.#{evaluation["gate_evaluation_id"]}"
          if evaluation.key?("work_unit_id")
            add("forbidden_second_fact_source", "GateEvaluation work_unit_id cannot overload evaluator and subject", "#{path}.work_unit_id")
          end
          requirement = requirements[evaluation["gate_requirement_id"]]
          task = tasks[evaluation.dig("subject", "task_revision_ref", "task_revision_id")]
          unless requirement && task && task["task_revision_id"] == requirement["task_revision_id"]
            add("reference_not_found", "GateEvaluation requirement/task subject does not exist", path)
            next
          end
          unless evaluation["gate_requirement_content_digest"] == requirement["content_digest"]
            add("subject_stale", "GateEvaluation pins a stale GateRequirement digest", "#{path}.gate_requirement_content_digest")
          end
          evaluator_attempt = @indexes["work_unit_attempts"][evaluation["evaluator_attempt_id"]]
          submission = @indexes["evidence_records"][evaluation["evaluator_submission_record_id"]]
          unless evaluator_attempt && submission &&
                 submission["attempt_id"] == evaluator_attempt["attempt_id"] &&
                 submission["record_kind"] == "evaluator_submission"
            add("gate_evaluation_invalid", "evaluator provenance must bind one Attempt and submission record", path)
            next
          end
          validate_evaluator_binding(
            evaluation,
            requirement,
            evaluator_attempt,
            submission,
            path
          )
          expected = nil
          check("#{path}.subject") do
            expected = EvaluationSubject.select(
              gate_requirement: requirement,
              task_revision: task,
              work_units: units,
              attempts: attempts,
              evidence_records: records,
              repository_snapshot: bundle["repository_snapshot"],
              code_surface: bundle["code_surface"]
            )
          end
          if expected && !EvaluationSubject.same?(expected, evaluation["subject"])
            actual = evaluation["subject"]
            code = subject_shape_complete?(actual) ? "subject_stale" : "subject_incomplete"
            add(code, "GateEvaluation subject is not the current canonical selector result", "#{path}.subject")
          end
          if expected
            evaluator_agent_id = evaluator_attempt.fetch("events").first
                                                  .fetch("assignment")
                                                  .fetch("agent_instance_id")
            evaluator_identity =
              runtime_identity_key_for_agent_id(evaluator_agent_id)
            producers = EvaluationSubject.producer_runtime_identities(
              expected,
              attempts,
              records,
              @indexes.fetch("agent_instances", {}).values
            )
            if requirement["independence"] == "independent_evaluator" &&
               evaluator_identity &&
               producers.include?(evaluator_identity)
              add(
                "independence_violation",
                "evaluator runtime identity overlaps at least one subject producer",
                "#{path}.evaluator_attempt_id"
              )
            end
          end
          validate_evaluation_answers(evaluation, requirement, task, path)
          validate_evaluation_answer_evidence(evaluation, path)
          validate_evaluation_quality_outcome(evaluation, path)
          validate_evaluation_coverage(evaluation, path)
          validate_supersedes(
            evaluation,
            "supersedes_gate_evaluation_id",
            @graphs.fetch("gate_evaluations"),
            "gate_evaluation_id",
            path,
            same_scope: %w[project_id],
            compatible: method(:gate_evaluation_lineage_compatible?)
          )
          validate_related_refs(
            evaluation,
            "related_gate_evaluation_refs",
            @graphs.fetch("gate_evaluations"),
            "gate_evaluation_id",
            path,
            &method(:gate_evaluation_lineage_compatible?)
          )
          policy_id = task.dig("project_policy_revision_ref", "policy_revision_id")
          if active_policy && policy_id != active_policy["policy_revision_id"]
            add("subject_stale", "GateEvaluation TaskRevision is governed by a stale policy", "#{path}.subject.task_revision_ref")
          end
        end
        validate_supersedes_cycles(
          @graphs.fetch("gate_evaluations"),
          "supersedes_gate_evaluation_id",
          "gate_evaluation_id",
          "gate_evaluations"
        )
      end

      def validate_evaluation_answers(evaluation, requirement, task, path)
        question_ids = Array(evaluation["quality_question_answers"]).map { |answer| answer["question_id"] }
        acceptance_ids = Array(evaluation["acceptance_results"]).map { |answer| answer["acceptance_id"] }
        unless question_ids.sort == Array(requirement["required_question_refs"]).sort &&
               question_ids.uniq.length == question_ids.length
          add("gate_evaluation_invalid", "quality answers must exactly cover required stable question IDs", "#{path}.quality_question_answers")
        end
        unless acceptance_ids.sort == Array(requirement["acceptance_refs"]).sort &&
               acceptance_ids.uniq.length == acceptance_ids.length
          add("gate_evaluation_invalid", "acceptance results must exactly cover required stable acceptance IDs", "#{path}.acceptance_results")
        end
        known_acceptance = Array(task["acceptance"]).map { |entry| entry["acceptance_id"] }
        add("gate_evaluation_invalid", "acceptance result references unknown TaskRevision ID", "#{path}.acceptance_results") unless subset?(acceptance_ids, known_acceptance)
        subject_unit_ids = Array(evaluation.dig("subject", "work_unit_refs")).map do |ref|
          ref["work_unit_id"]
        end
        selected_acceptance_ids = subject_unit_ids.flat_map do |unit_id|
          Array(@indexes.fetch("work_units", {}).dig(unit_id, "acceptance_refs"))
        end.uniq
        unless subset?(acceptance_ids, selected_acceptance_ids)
          add(
            "gate_evaluation_invalid",
            "acceptance results exceed the subject WorkUnits' acceptance refs",
            "#{path}.acceptance_results"
          )
        end
      end

      def validate_evaluator_binding(evaluation, requirement, attempt, submission, path)
        assignment = attempt.fetch("events").first.fetch("assignment")
        binding = GATE_EVALUATOR_BINDINGS[requirement["kind"]]
        unit = @indexes.fetch("work_units", {})[attempt["work_unit_id"]]
        agent = @indexes.fetch("agent_instances", {})[assignment["agent_instance_id"]]
        unless binding &&
               assignment["purpose"] == binding["purpose"] &&
               assignment["resolved_role"] == binding["resolved_role"] &&
               assignment_binding_valid?(assignment, unit, agent)
          add(
            "gate_evaluator_binding_invalid",
            "#{requirement["kind"]} gate requires the exact purpose/role/capability/" \
              "permission/context/action binding declared by the AgentInstance and WorkUnit",
            "#{path}.evaluator_attempt_id"
          )
        end
        unless unit &&
               unit["work_unit_kind"] == "evaluation" &&
               attempt["task_id"] == requirement["task_id"] &&
               attempt["task_revision_id"] == requirement["task_revision_id"] &&
               unit["task_id"] == requirement["task_id"] &&
               unit["task_revision_id"] == requirement["task_revision_id"] &&
               submission["task_id"] == requirement["task_id"] &&
               submission["task_revision_id"] == requirement["task_revision_id"] &&
               submission["work_unit_id"] == unit["work_unit_id"]
          add(
            "gate_evaluator_binding_invalid",
            "cross-task evaluation is unsupported; evaluator WorkUnit, Attempt, and submission " \
              "must belong to the GateRequirement task revision",
            "#{path}.evaluator_attempt_id"
          )
        end
      end

      def validate_evaluation_quality_outcome(evaluation, path)
        return unless evaluation["verdict"] == "pass"

        answer_verdicts = (
          Array(evaluation["quality_question_answers"]) +
          Array(evaluation["acceptance_results"])
        ).map { |answer| answer["verdict"] }
        unless evaluation["quality_outcome_verdict"] == "pass" &&
               answer_verdicts.all? { |verdict| verdict == "pass" } &&
               Array(evaluation["missing"]).empty?
          add(
            "gate_evaluation_invalid",
            "passing GateEvaluation requires passing quality outcome/answers and no missing evidence",
            path
          )
        end
      end

      def validate_evaluation_coverage(evaluation, path)
        coverage = evaluation["coverage"]
        return unless coverage.is_a?(Hash)

        subject_units = Array(evaluation.dig("subject", "work_unit_refs")).map do |ref|
          ref["work_unit_id"]
        end
        covered = Array(coverage["covered_work_unit_refs"])
        uncovered = Array(coverage["uncovered_work_unit_refs"])
        subject_evidence = Array(evaluation.dig("subject", "evidence_record_refs")).map do |ref|
          ref["evidence_record_id"]
        end
        unless (covered + uncovered).sort == subject_units.sort &&
               (covered & uncovered).empty? &&
               subset?(coverage["evidence_record_refs"], subject_evidence)
          add(
            "gate_evaluation_invalid",
            "coverage must partition subject WorkUnits and cite only subject EvidenceRecords",
            "#{path}.coverage"
          )
        end
        if evaluation["verdict"] == "pass" && !uncovered.empty?
          add(
            "gate_evaluation_invalid",
            "passing GateEvaluation cannot leave subject WorkUnits uncovered",
            "#{path}.coverage.uncovered_work_unit_refs"
          )
        end
      end

      def validate_evaluation_answer_evidence(evaluation, path)
        subject_record_ids = Array(evaluation.dig("subject", "evidence_record_refs")).map do |ref|
          ref["evidence_record_id"]
        end
        answers = Array(evaluation["quality_question_answers"]) + Array(evaluation["acceptance_results"])
        answer_record_ids = answers.flat_map { |answer| Array(answer["evidence_record_refs"]) }
        unless answer_record_ids.all? { |id| subject_record_ids.include?(id) }
          add(
            "gate_evaluation_invalid",
            "answers may cite only immutable EvidenceRecords pinned by the canonical subject",
            path
          )
        end
        if evaluation["verdict"] == "pass" &&
           answers.any? { |answer| Array(answer["evidence_record_refs"]).empty? }
          add(
            "gate_evaluation_invalid",
            "every passing quality and acceptance answer requires immutable subject evidence",
            path
          )
        end
      end

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

      def validate_finding_closure(bundle)
        tasks = @indexes.fetch("task_revisions", {})
        resolutions = Array(bundle["finding_resolutions"]).select { |item| item.is_a?(Hash) }
        Array(bundle["findings"]).each do |finding|
          next unless finding.is_a?(Hash)

          lineage = finding_lineage(finding)
          next unless lineage

          task = tasks[lineage["task_revision_id"]]
          matching = resolutions.select { |resolution| resolution["finding_id"] == finding["finding_id"] }
          tips = resolution_lineage_tips(finding["finding_id"], matching)
          if finding["blocking"] == true && tips.empty?
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
          end
        end
      end

      def resolution_lineage_tips(finding_id, resolutions)
        return [] if resolutions.empty?

        by_id = resolutions.to_h { |resolution| [resolution["finding_resolution_id"], resolution] }
        superseded = resolutions.each_with_object([]) do |resolution, ids|
          ref = resolution["supersedes_finding_resolution_id"]
          ids << ref if ref
        end
        tips = resolutions.reject do |resolution|
          superseded.include?(resolution["finding_resolution_id"])
        end
        if tips.length != 1
          add(
            "finding_resolution_lineage_invalid",
            "Finding #{finding_id} must have one append-only current resolution tip",
            "finding_resolutions"
          )
          return []
        end
        visited = Set.new
        cursor = tips.first
        while cursor
          id = cursor["finding_resolution_id"]
          if visited.include?(id)
            add(
              "finding_resolution_lineage_invalid",
              "Finding #{finding_id} resolution lineage contains a cycle",
              "finding_resolutions.#{id}"
            )
            return []
          end
          visited << id
          parent_id = cursor["supersedes_finding_resolution_id"]
          cursor = parent_id && by_id[parent_id]
        end
        unless visited.length == resolutions.length
          add(
            "finding_resolution_lineage_invalid",
            "Finding #{finding_id} resolution lineage contains a fork or orphan",
            "finding_resolutions"
          )
          return []
        end
        tips
      end

      def finding_lineage(finding)
        return nil unless finding.is_a?(Hash)

        evaluation = @indexes.fetch("gate_evaluations", {})[finding["gate_evaluation_id"]]
        requirement = evaluation &&
          @indexes.fetch("gate_requirements", {})[evaluation["gate_requirement_id"]]
        task = requirement &&
          @indexes.fetch("task_revisions", {})[requirement["task_revision_id"]]
        subject_ref = evaluation && evaluation.dig("subject", "task_revision_ref")
        return nil unless evaluation &&
                          requirement &&
                          task &&
                          requirement["task_id"] == task["task_id"] &&
                          subject_ref &&
                          subject_ref["task_revision_id"] == task["task_revision_id"] &&
                          subject_ref["content_digest"] == task["content_digest"]

        {
          "task_id" => task["task_id"],
          "task_revision_id" => task["task_revision_id"],
          "gate_requirement_id" => requirement["gate_requirement_id"],
          "gate_lineage_id" => requirement["gate_lineage_id"]
        }
      end

      def task_revision_in_lineage?(task, ancestor_revision_id)
        seen = Set.new
        cursor = task
        while cursor && seen.add?(cursor["task_revision_id"])
          return true if cursor["task_revision_id"] == ancestor_revision_id

          parent_id = cursor["parent_task_revision_id"]
          cursor = parent_id && @indexes.fetch("task_revisions", {})[parent_id]
        end
        false
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

      def gate_evaluation_lineage_compatible?(left, right)
        left_requirement =
          @indexes.fetch("gate_requirements", {})[left["gate_requirement_id"]]
        right_requirement =
          @indexes.fetch("gate_requirements", {})[right["gate_requirement_id"]]
        left_requirement &&
          right_requirement &&
          left["project_id"] == right["project_id"] &&
          left_requirement["task_id"] == right_requirement["task_id"] &&
          left_requirement["gate_lineage_id"] == right_requirement["gate_lineage_id"] &&
          (
            left_requirement["gate_requirement_id"] ==
              right_requirement["gate_requirement_id"] ||
            gate_requirement_descends_from?(
              left_requirement,
              right_requirement["gate_requirement_id"]
            ) ||
            gate_requirement_descends_from?(
              right_requirement,
              left_requirement["gate_requirement_id"]
            )
          )
      end

      def gate_requirement_descends_from?(requirement, ancestor_requirement_id)
        seen = Set.new
        cursor = requirement
        requirements = @indexes.fetch("gate_requirements", {})
        while cursor && seen.add?(cursor["gate_requirement_id"])
          parent_ref = cursor["parent_gate_requirement_ref"]
          return false unless parent_ref.is_a?(Hash)

          parent = requirements[parent_ref["gate_requirement_id"]]
          cursor_task = @indexes.fetch("task_revisions", {})[cursor["task_revision_id"]]
          parent_task = parent &&
            @indexes.fetch("task_revisions", {})[parent["task_revision_id"]]
          return false unless parent &&
                              parent["content_digest"] == parent_ref["content_digest"] &&
                              parent["project_id"] == cursor["project_id"] &&
                              parent["task_id"] == cursor["task_id"] &&
                              parent["gate_lineage_id"] == cursor["gate_lineage_id"] &&
                              cursor_task &&
                              parent_task &&
                              cursor_task["parent_task_revision_id"] ==
                                parent_task["task_revision_id"]
          return true if parent["gate_requirement_id"] == ancestor_requirement_id

          cursor = parent
        end
        false
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

      def evaluation_subject_lineage(evaluation)
        return nil unless evaluation.is_a?(Hash)

        subject = evaluation["subject"]
        return nil unless subject.is_a?(Hash)

        [
          subject.dig("task_revision_ref", "task_revision_id"),
          Array(subject["work_unit_refs"]).map { |ref| ref["work_unit_id"] }.sort
        ]
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

      def runtime_identity_key_for_agent_id(agent_instance_id)
        agent = @indexes.fetch("agent_instances", {})[agent_instance_id]
        agent && RuntimeIdentityVerifier.identity_key(agent.fetch("runtime_identity"))
      rescue KeyError, TypeError
        nil
      end

      def gate_evaluation_descends_from?(evaluation, ancestor_evaluation_id)
        seen = Set.new
        cursor = evaluation
        while cursor && seen.add?(cursor["gate_evaluation_id"])
          parent_id = cursor["supersedes_gate_evaluation_id"]
          return true if parent_id == ancestor_evaluation_id

          cursor = parent_id &&
            @indexes.fetch("gate_evaluations", {})[parent_id]
        end
        false
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

      def subset?(values, allowed)
        values.is_a?(Array) && (values - allowed).empty?
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
