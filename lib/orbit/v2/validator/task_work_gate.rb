# frozen_string_literal: true

unless defined?(Orbit::V2::Validator)
  raise LoadError, "load Validator internals through orbit/v2/validator"
end

module Orbit
  module V2
    class Validator
      module TaskWorkGate
        private

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
      end

      include TaskWorkGate
      private_constant :TaskWorkGate
    end
  end
end
