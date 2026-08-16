# frozen_string_literal: true

unless defined?(Orbit::V2::Validator)
  raise LoadError, "load Validator internals through orbit/v2/validator"
end

module Orbit
  module V2
    class Validator
      module AuthorityPolicy
        private

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
              elsif authorization["action"] == ControlAuthority::RETRY_OVERRIDE_ACTION
                authorization.dig("retry_override_envelope", "scope_digest")
              elsif authorization["action"] == ControlAuthority::BUDGET_OVERRIDE_ACTION
                authorization.dig("budget_override_envelope", "scope_digest")
              elsif authorization["action"] == ControlAuthority::FALLBACK_AUTHORIZE_ACTION
                authorization.dig("fallback_envelope", "scope_digest")
              elsif authorization["action"] == "finding.waive"
                authorization["subject_ref"]
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
      end

      include AuthorityPolicy
      private_constant :AuthorityPolicy
    end
  end
end
