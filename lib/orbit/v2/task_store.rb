# frozen_string_literal: true

require "set"

require_relative "active_root"
require_relative "authority_verifier"
require_relative "canonical_json"
require_relative "durable_file"
require_relative "errors"
require_relative "gate_strength"
require_relative "identifiers"
require_relative "path_scope"
require_relative "policy_store"
require_relative "schema_catalog"
require_relative "transaction_log"
require_relative "validator"
require_relative "work_authority"

module Orbit
  module V2
    # Slice 6 increment 5: the durable controlled task-definition store.
    #
    # One canonical TransactionLog transaction per task, committed
    # atomically under the canonical ProtocolRoot active root, carrying the
    # exact records that close a task genesis: the revision-1 TaskRevision,
    # its owned GateRequirement set, the WorkUnit graph, the revision-1
    # ChangeTheses, and their AuthorityAssertions + AuthorizationRecords.
    # All-or-nothing; no partial task definition ever becomes accepted
    # truth.
    #
    # Commit and resolve prove the canonical ActiveRoot/ProtocolRoot marker
    # and the marker project exact-binding, then resolve the
    # provider-verified accepted policy lineage from the PolicyStore with a
    # FIXED root lock order (policy log lock -> task log lock), so a policy
    # rotation can never create stale-policy acceptance. Validation and the
    # append share ONE locked snapshot (TransactionLog#append_with).
    #
    # Task GENESIS is supported: parentless revision-1 TaskRevision, owned
    # gate requirements with parentless lineages, revision-1 theses, exact
    # work authority scopes with provider-verified policy-enabled grants,
    # and NO protected-change authorization or self-authorization (the
    # genesis carries empty authority_grant_refs and a nil
    # protected_change_authorization_ref).
    #
    # DEFERRED explicitly to later increments: successor TaskRevisions
    # (revision_number > 1, parent refs, protected-change authorization
    # envelopes), ChangeThesis revisions > 1, GateRequirement successor
    # lineages (parent refs), TaskAuthority task-level records, and
    # evidence/finding machinery.
    #
    # Public behavior:
    # - `genesis(task:, gate_requirements:, work_units:, change_theses:,
    #   authority_assertions:, authorization_records:, authority_verifier:)`
    #   returns `:appended` or `:idempotent` (same task id with
    #   byte-identical canonical content, and only after the WHOLE existing
    #   snapshot re-verifies — invalid persisted records never report
    #   success). Same task id with different content, malformed/unknown/
    #   half/forked persisted data, or IDs borrowed from another task fail
    #   closed; concurrent same-identity genesis accepts exactly one
    #   transaction.
    # - `records` returns detached TransactionLog-verified payloads in
    #   chain order (store-level reverification requires `resolve`); `resolve(task_id:,
    #   authority_verifier:)` returns {task, gate_requirements, work_units,
    #   change_theses, authority_assertions, authorization_records} after
    #   replaying every transaction from the ProtocolRoot anchor with
    #   provider reverification and the cross-transaction create-only
    #   closure.
    #
    # Error codes: task_store_argument_invalid, task_store_reuse,
    # task_store_unpinned, task_store_genesis_invalid,
    # task_store_lineage_invalid, task_store_missing. TransactionLog
    # storage-level failures propagate as-is.
    class TaskStore
      TASK_DEFINITIONS_FILE = "task-definitions.json".freeze
      PAYLOAD_KEYS = %w[
        authority_assertions authorization_records change_theses
        gate_requirements logical_lead task work_units
      ].freeze
      STABLE_ID = /\A(?:acc|src|evreq|question)_[a-z0-9][a-z0-9_-]{2,95}\z/.freeze
      WORK_UNIT_KINDS = %w[implementation evaluation research release].freeze

      def initialize(active_root:)
        @active_root = File.expand_path(active_root)
        unless File.directory?(@active_root)
          raise ContractError.new(
            "task_store_argument_invalid",
            "active root must be an existing directory",
            path: "task_store.active_root"
          )
        end
        @log = TransactionLog.new(path: File.join(@active_root, TASK_DEFINITIONS_FILE))
      end

      def genesis(task:, gate_requirements:, work_units:, change_theses:,
                  authority_assertions:, authorization_records:, logical_lead:,
                  authority_verifier:)
        records = {
          "task" => task,
          "gate_requirements" => gate_requirements,
          "work_units" => work_units,
          "change_theses" => change_theses,
          "authority_assertions" => authority_assertions,
          "authorization_records" => authorization_records,
          "logical_lead" => logical_lead
        }
        unless task.is_a?(Hash) && task["task_id"].is_a?(String) && !task["task_id"].empty? &&
               logical_lead.is_a?(Hash) &&
               [gate_requirements, work_units, change_theses,
                authority_assertions, authorization_records].all? { |list| list.is_a?(Array) } &&
               authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "task_store_argument_invalid",
            "task records with a stable task_id and a configured authority verifier are required",
            path: "task_store"
          )
        end
        unless Identifiers.valid?("task_id", task["task_id"])
          raise ContractError.new(
            "task_store_argument_invalid",
            "task_id must be a stable task identifier",
            path: "task_store.task_id"
          )
        end
        candidate = payload(records)
        task_id = task["task_id"]
        # Fixed root lock order: policy log lock -> task log lock (same as
        # ControlStore), so the policy resolution inside the snapshot and
        # the task append are atomic with respect to policy rotations.
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          @log.append_with(
            transaction_id: task_id,
            payload: candidate,
            validate: lambda do |records, _tip|
              validate_task_snapshot!(records, candidate, task_id, authority_verifier)
            end
          )
        end
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "task_store_reuse",
          "task #{task.fetch("task_id")} already exists with different canonical content",
          path: "task_store.#{task.fetch("task_id")}"
        )
      end

      def records
        payloads(@log.records)
      end

      def resolve(task_id:, authority_verifier:)
        unless authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "task_store_argument_invalid",
            "resolve requires a configured authority verifier",
            path: "task_store.resolve"
          )
        end
        unless task_id.is_a?(String) && Identifiers.valid?("task_id", task_id)
          raise ContractError.new(
            "task_store_argument_invalid",
            "task_id must be a stable task identifier",
            path: "task_store.task_id"
          )
        end
        txs = payloads(@log.records)
        marker = ActiveRoot.marker_for(@active_root, code: "task_store_unpinned", label: "task_store")
        policy = begin
          resolve_active_policy(marker, authority_verifier)
        rescue ContractError => e
          raise lineage_invalid("#{e.code}: #{e.message}")
        end
        verified = verify_all_transactions!(txs, marker, policy, authority_verifier)
        target = verified.find { |tx| tx.fetch("task").fetch("task_id") == task_id }
        unless target
          raise ContractError.new(
            "task_store_missing",
            "no accepted genesis exists for task #{task_id}",
            path: "task_store.#{task_id}"
          )
        end
        target
      end

      private

      def payload(records)
        {
          "authority_assertions" => records.fetch("authority_assertions"),
          "authorization_records" => records.fetch("authorization_records"),
          "change_theses" => records.fetch("change_theses"),
          "gate_requirements" => records.fetch("gate_requirements"),
          "logical_lead" => records.fetch("logical_lead"),
          "task" => records.fetch("task"),
          "work_units" => records.fetch("work_units")
        }
      end

      def payloads(log_records)
        log_records.map do |record|
          payload = record["payload"]
          raise lineage_invalid("transaction payload is not a canonical object") unless payload.is_a?(Hash)

          JSON.parse(CanonicalJSON.dump(payload))
        end
      end

      def canonical_equal?(left, right)
        CanonicalJSON.dump(left) == CanonicalJSON.dump(right)
      end

      def lineage_invalid(message, index = nil)
        ContractError.new(
          "task_store_lineage_invalid",
          "task authority store lineage is invalid: #{message}",
          path: "task_store",
          details: index.nil? ? nil : { "transaction_index" => index }
        )
      end

      def genesis_invalid(message, details = nil)
        ContractError.new(
          "task_store_genesis_invalid",
          "task genesis rejected: #{message}",
          path: "task_store",
          details: details
        )
      end

      def resolve_active_policy(marker, authority_verifier)
        policy_store = PolicyStore.new(active_root: @active_root)
        resolved = policy_store.resolve(
          pinned_genesis_ref: marker.fetch("project_policy_genesis_ref"),
          authority_verifier: authority_verifier
        )
        unless resolved.fetch("genesis_policy").fetch("project_id") == marker["project_id"]
          raise genesis_invalid("policy store genesis project does not match the marker project")
        end
        {
          "active" => resolved.fetch("active_policy"),
          # Accepted revisions come from the SAME provider-verified
          # PolicyStore snapshot as the resolved lineage (never a separate
          # read), so an old task can never be authorized against a
          # separately read or unverified list.
          "accepted" => resolved.fetch("accepted_policies")
        }
      rescue ContractError => e
        raise e if e.code == "task_store_genesis_invalid"

        raise genesis_invalid(
          "durable policy store does not resolve the pinned genesis",
          { "cause" => e.code, "message" => e.message }
        )
      end

      def validate_task_snapshot!(log_records, candidate, task_id, authority_verifier)
        txs = payloads(log_records)
        marker = ActiveRoot.marker_for(@active_root, code: "task_store_unpinned", label: "task_store")
        policy = resolve_active_policy(marker, authority_verifier)
        seen_ids = Set.new
        verified_existing = txs.map do |tx|
          validate_transaction!(tx, policy: nil, pinned_policies: policy.fetch("accepted"),
            marker: marker, authority_verifier: authority_verifier, seen_ids: seen_ids)
        end
        existing = verified_existing.find { |tx| tx.fetch("task").fetch("task_id") == task_id }
        if existing
          return :idempotent if canonical_equal?(existing, candidate)

          raise ContractError.new(
            "task_store_reuse",
            "task #{task_id} already exists with different canonical content",
            path: "task_store.#{task_id}"
          )
        end
        validate_transaction!(candidate, policy: policy.fetch("active"),
          pinned_policies: policy.fetch("accepted"), marker: marker,
          authority_verifier: authority_verifier, seen_ids: seen_ids)
        nil
      end

      def verify_all_transactions!(txs, marker, policy, authority_verifier)
        verified = []
        seen_ids = Set.new
        txs.each_with_index do |tx, index|
          begin
            validated = validate_transaction!(tx, policy: nil,
              pinned_policies: policy.fetch("accepted"), marker: marker,
              authority_verifier: authority_verifier, seen_ids: seen_ids)
          rescue ContractError => e
            raise e if %w[
              task_store_lineage_invalid task_store_unpinned
            ].include?(e.code)

            raise lineage_invalid("#{e.code}: #{e.message}", index)
          end
          verified << validated
        end
        verified
      end

      # Full final validation of one task-genesis transaction: schemas,
      # content digests, epoch, project, exact ownership/ref closure for
      # the task, gates, work graph, theses, and authorizations, with
      # provider verification and policy-enabled grants.
      def validate_transaction!(tx, policy:, pinned_policies:, marker:,
                                authority_verifier:, seen_ids:)
        unless tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS &&
               tx["task"].is_a?(Hash) && tx["logical_lead"].is_a?(Hash) &&
               [tx["gate_requirements"], tx["work_units"], tx["change_theses"],
                tx["authority_assertions"], tx["authorization_records"]].all? do |list|
                 list.is_a?(Array)
               end
          raise genesis_invalid("transaction carries malformed component types or unknown fields")
        end
        task = tx.fetch("task")
        gates = tx.fetch("gate_requirements")
        units = tx.fetch("work_units")
        theses = tx.fetch("change_theses")
        assertions = tx.fetch("authority_assertions")
        authorizations = tx.fetch("authorization_records")
        logical_lead = tx.fetch("logical_lead")
        project_id = policy ? policy["project_id"] : marker["project_id"]

        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("task_revision", task)
          validator.validate_document!("logical_lead", logical_lead)
          gates.each { |gate| validator.validate_document!("gate_requirement", gate) }
          units.each { |unit| validator.validate_document!("work_unit", unit) }
          theses.each { |thesis| validator.validate_document!("change_thesis", thesis) }
          assertions.each { |assertion| validator.validate_document!("authority_assertion", assertion) }
          authorizations.each { |record| validator.validate_document!("authorization_record", record) }
        rescue ValidationFailure, ContractError
          raise genesis_invalid("records violate their contracts")
        end
        [task, *gates, *units, *theses, *authorizations, logical_lead].each do |record|
          unless CanonicalJSON.content_digest(record) == record["content_digest"]
            raise genesis_invalid("record content_digest is not self-consistent")
          end
        end
        unless ([task, *gates, *units, *theses, *assertions, *authorizations, logical_lead]).all? do |record|
                 record["project_id"] == project_id
               end
          raise genesis_invalid("records do not all carry the marker project identity")
        end

        effective_policy = policy || pinned_policies.find do |candidate|
          candidate["policy_revision_id"] == task.dig("project_policy_revision_ref", "policy_revision_id")
        end
        raise genesis_invalid("task pins a policy the store never accepted") unless effective_policy

        validate_logical_lead!(task, logical_lead, seen_ids)
        validate_task!(task, gates, policy, pinned_policies, seen_ids, project_id)
        validate_gates!(task, gates, effective_policy, units, seen_ids)
        validate_theses!(task, units, theses, seen_ids)
        validate_work_units!(task, units, theses, seen_ids)
        validate_authorizations!(task, units, assertions, authorizations,
          effective_policy, authority_verifier, seen_ids)
        tx
      end

      # Exactly one LogicalLead per task transaction with exact closure:
      # the task_id must equal the task, the authority_scope_ref must
      # exact-equal the task's pinned policy revision id (the active policy
      # for the writer, the accepted revision for the reader), and the
      # durable_context_ref must be a canonical artifact URI. Logical lead
      # ids are globally create-only.
      def validate_logical_lead!(task, logical_lead, seen_ids)
        register_id!(seen_ids, "logical_lead", logical_lead.fetch("logical_lead_id"))
        unless logical_lead["task_id"] == task["task_id"]
          raise genesis_invalid("LogicalLead task_id must exact-equal the task")
        end
        unless logical_lead["authority_scope_ref"] ==
               task.dig("project_policy_revision_ref", "policy_revision_id")
          raise genesis_invalid(
            "LogicalLead authority_scope_ref must exact-equal the task's pinned policy revision"
          )
        end
        durable_context_ref = logical_lead["durable_context_ref"]
        unless durable_context_ref.is_a?(String) && /\Aartifact:\/\/[^\s]+\z/.match?(durable_context_ref)
          raise genesis_invalid("LogicalLead durable_context_ref must be a canonical artifact URI")
        end
      end

      def validate_task!(task, gates, policy, pinned_policies, seen_ids, project_id)
        task_id = task.fetch("task_id")
        register_id!(seen_ids, "task", task_id)
        unless task["parent_task_revision_id"].nil? && task["revision_number"] == 1
          raise genesis_invalid("task genesis requires a parentless revision-1 TaskRevision " \
            "(successor revisions are deferred)")
        end
        unless task["protected_change_authorization_ref"].nil? &&
               Array(task["authority_grant_refs"]).empty?
          raise genesis_invalid("task genesis must not claim protected-change authorization or self-authorize")
        end
        unless Array(task["unresolved_finding_refs"]).empty?
          raise genesis_invalid("task genesis must carry empty unresolved_finding_refs " \
            "(findings are later create-only facts; no forward dangling refs)")
        end
        pinned_ref = task["project_policy_revision_ref"]
        if policy
          unless pinned_ref == {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => policy["content_digest"]
          }
            raise genesis_invalid("task does not pin the currently active policy (stale authority)")
          end
        else
          pinned_policy = pinned_policies.find do |candidate|
            candidate["policy_revision_id"] == pinned_ref["policy_revision_id"] &&
              candidate["content_digest"] == pinned_ref["content_digest"]
          end
          unless pinned_policy
            raise genesis_invalid("task pins a policy revision the store never accepted")
          end
        end
        owned_gate_ids = gates.map { |gate| gate.fetch("gate_requirement_id") }.sort
        unless Array(task["gate_requirement_refs"]).sort == owned_gate_ids
          raise genesis_invalid("task gate_requirement_refs must exact-equal the owned gate set")
        end
        {
          "acceptance" => "acceptance_id",
          "source_requirements" => "source_requirement_id",
          "evidence_requirements" => "evidence_requirement_id",
          "task_questions" => "question_id"
        }.each do |field, id_key|
          ids = Array(task[field]).map { |entry| entry[id_key] }
          unless ids.all? { |id| id.is_a?(String) && STABLE_ID.match?(id) } && ids == ids.uniq
            raise genesis_invalid("task #{field} must carry unique stable requirement/question IDs")
          end
        end
      end

      def validate_gates!(task, gates, policy, units, seen_ids)
        task_id = task.fetch("task_id")
        task_revision_id = task.fetch("task_revision_id")
        acceptance_ids = Array(task["acceptance"]).map { |entry| entry["acceptance_id"] }
        question_ids = Array(task["task_questions"]).map { |entry| entry["question_id"] }
        unit_ids = units.map { |unit| unit.fetch("work_unit_id") }
        gates.each do |gate|
          register_id!(seen_ids, "gate_requirement", gate.fetch("gate_requirement_id"))
          register_id!(seen_ids, "gate_lineage", gate.fetch("gate_lineage_id"))
          unless gate["task_id"] == task_id && gate["task_revision_id"] == task_revision_id
            raise genesis_invalid("gate #{gate["gate_requirement_id"]} is not owned by the task revision")
          end
          unless gate["parent_gate_requirement_ref"].nil?
            raise genesis_invalid("gate genesis lineages must be parentless (successors deferred)")
          end
          unless Array(gate["acceptance_refs"]).all? { |id| acceptance_ids.include?(id) } &&
                 Array(gate["required_question_refs"]).all? { |id| question_ids.include?(id) }
            raise genesis_invalid("gate refs must resolve to TaskRevision stable IDs")
          end
          selector = gate["subject_selector"] || {}
          unless (selector["scope"] == "task_wide" && Array(selector["work_unit_refs"]).empty?) ||
                 (selector["scope"] == "selected_work_units" &&
                   Array(selector["work_unit_refs"]).all? { |id| unit_ids.include?(id) })
            raise genesis_invalid("gate selector work unit refs must close against the owned WorkUnits")
          end
        end
        validate_policy_minimums!(task, gates, policy)
      end

      # Mirrors Validator#validate_policy_minimums exactly: for EACH policy
      # protected_gate_minimums entry, at least one same-kind PROTECTED gate
      # must exist and ALL same-kind protected gates must meet the
      # GateStrength evidence-level and independence minimums. Unrelated
      # additional legal gates (different kinds or non-protected) remain
      # allowed.
      def validate_policy_minimums!(task, gates, policy)
        Array(policy["protected_gate_minimums"]).each do |minimum|
          matching = gates.select { |gate| gate["kind"] == minimum["gate_kind"] }
          protected_matching = matching.select { |gate| gate["protected"] == true }
          all_meet = protected_matching.all? do |gate|
            GateStrength.evidence_at_least?(gate["evidence_level"], minimum["evidence_level"]) &&
              GateStrength.independence_at_least?(gate["independence"], minimum["independence"])
          end
          unless protected_matching.any? && all_meet
            raise genesis_invalid(
              "every matching protected GateRequirement must meet the ProjectPolicy minimum"
            )
          end
        end
      end

      def validate_theses!(task, units, theses, seen_ids)
        unit_ids = units.map { |unit| unit.fetch("work_unit_id") }
        theses.each do |thesis|
          register_id!(seen_ids, "change_thesis", thesis.fetch("change_thesis_id"))
          unless thesis["revision"] == 1
            raise genesis_invalid("task genesis requires revision-1 ChangeTheses only (successors deferred)")
          end
          unless thesis["task_id"] == task["task_id"] &&
                 thesis["task_revision_id"] == task["task_revision_id"] &&
                 unit_ids.include?(thesis["work_unit_id"])
            raise genesis_invalid("ChangeThesis must belong to one exact task/revision/WorkUnit lineage")
          end
        end
        referenced = theses.each_with_object(Hash.new(0)) do |thesis, counts|
          units.each do |unit|
            counts[thesis["change_thesis_id"]] += 1 if unit.dig("initial_change_thesis_ref", "change_thesis_id") == thesis["change_thesis_id"]
          end
        end
        unless referenced.length == theses.length && referenced.values.all? { |count| count == 1 }
          raise genesis_invalid(
            "every revision-1 ChangeThesis must be the exact unique thesis referenced by exactly one WorkUnit"
          )
        end
      end

      def validate_work_units!(task, units, theses, seen_ids)
        task_id = task.fetch("task_id")
        task_revision_id = task.fetch("task_revision_id")
        thesis_by_unit = theses.group_by { |thesis| thesis["work_unit_id"] }
        index = {}
        units.each do |unit|
          register_id!(seen_ids, "work_unit", unit.fetch("work_unit_id"))
          index[unit.fetch("work_unit_id")] = unit
          unless unit["task_id"] == task_id && unit["task_revision_id"] == task_revision_id
            raise genesis_invalid("WorkUnit #{unit["work_unit_id"]} is not owned by the task revision")
          end
          unless WORK_UNIT_KINDS.include?(unit["work_unit_kind"])
            raise genesis_invalid("work_unit_kind is not stable")
          end
          scope = unit["authority_scope"] || {}
          allowed = Array(scope["allowed_actions"])
          forbidden = Array(scope["forbidden_actions"])
          unless (allowed & forbidden).empty? && allowed.all? { |action| WorkAuthority.action?(action) }
            raise genesis_invalid("WorkUnit authority cannot allow+forbid the same action and must use stable actions")
          end
          writable = Array(scope["writable_paths"])
          expected_non_empty = unit["work_unit_kind"] == "implementation"
          unless PathScope.canonical_set?(writable, allow_empty: !expected_non_empty) &&
                 (expected_non_empty || writable.empty?)
            raise genesis_invalid("implementation WorkUnits require a canonical sorted writable path set")
          end
          allowed = {
            "acceptance_refs" => Array(task["acceptance"]).map { |entry| entry["acceptance_id"] },
            "evidence_requirement_refs" => Array(task["evidence_requirements"]).map { |entry| entry["evidence_requirement_id"] },
            "source_requirement_refs" => Array(task["source_requirements"]).map { |entry| entry["source_requirement_id"] }
          }
          allowed.each do |field, ids|
            unless Array(unit[field]).all? { |id| ids.include?(id) }
              raise genesis_invalid("WorkUnit #{field} contains an unknown TaskRevision ref")
            end
          end
          initial = unit["initial_change_thesis_ref"]
          thesis = (thesis_by_unit[unit.fetch("work_unit_id")] || []).find do |candidate|
            candidate["change_thesis_id"] == initial["change_thesis_id"]
          end
          unless thesis && thesis["revision"] == 1 &&
                 initial["revision"] == 1 &&
                 initial["content_digest"] == thesis["content_digest"]
            raise genesis_invalid("WorkUnit initial ChangeThesis ref must exact-pin the revision-1 thesis")
          end
        end
        validate_work_graph!(units, index)
        index
      end

      def validate_work_graph!(units, index)
        roots = units.select { |unit| unit["parent_work_unit_ref"].nil? }
        unless roots.length == 1
          raise genesis_invalid("each TaskRevision requires exactly one root WorkUnit")
        end
        units.each do |unit|
          parent = unit["parent_work_unit_ref"]
          if parent && (parent == unit["work_unit_id"] || !index.key?(parent))
            raise genesis_invalid("parent_work_unit_ref must resolve to a different WorkUnit in the same revision")
          end
          Array(unit["depends_on_work_unit_refs"]).each do |dependency|
            if dependency == unit["work_unit_id"] || !index.key?(dependency)
              raise genesis_invalid("depends_on_work_unit_refs must resolve within the same revision and exclude self")
            end
          end
        end
        # Parent-tree cycle detection: walk each unit's parent chain; a
        # node revisited on its own chain is a cycle.
        units.each do |unit|
          chain = Set.new
          cursor = unit
          while cursor
            raise genesis_invalid("parent tree contains a cycle") unless chain.add?(cursor["work_unit_id"])
            parent_ref = cursor["parent_work_unit_ref"]
            break unless parent_ref
            cursor = index[parent_ref]
          end
        end
        reachable = Set.new
        stack = [roots.first]
        while (cursor = stack.pop)
          next unless reachable.add?(cursor["work_unit_id"])
          units.each { |unit| stack << unit if unit["parent_work_unit_ref"] == cursor["work_unit_id"] }
        end
        unless reachable.length == units.length
          raise genesis_invalid("every WorkUnit must be reachable from the unique root through its parent tree")
        end
        state = {}
        visit = lambda do |unit_id|
          return false if state[unit_id] == :done
          return true if state[unit_id] == :visiting
          state[unit_id] = :visiting
          Array(index.dig(unit_id, "depends_on_work_unit_refs")).each do |dependency|
            return true if visit.call(dependency)
          end
          state[unit_id] = :done
          false
        end
        index.each_key { |unit_id| raise genesis_invalid("depends_on refs must form an acyclic DAG") if visit.call(unit_id) }
      end

      def validate_authorizations!(task, units, assertions, authorizations, policy,
                                    authority_verifier, seen_ids)
        assertions.each do |assertion|
          register_id!(seen_ids, "authority_assertion", assertion.fetch("assertion_id"))
          begin
            authority_verifier.verify!(assertion)
          rescue ContractError => error
            raise genesis_invalid("authority assertion was not provider-verified: #{error.code}")
          end
        end
        assertion_by_id = assertions.to_h { |assertion| [assertion["assertion_id"], assertion] }
        authorizations.each do |record|
          register_id!(seen_ids, "authorization_record", record.fetch("authorization_record_id"))
          action = record["action"]
          unless WorkAuthority.action?(action)
            raise genesis_invalid("authorization action is not a stable work authority action")
          end
          owners = units.select do |unit|
            Array(unit.dig("authority_scope", "authorization_record_refs")).include?(record["authorization_record_id"])
          end
          unless owners.length == 1
            raise genesis_invalid("each authorization record must have exactly one owning WorkUnit")
          end
          owner = owners.first
          expected_scope = WorkAuthority.scope_digest(owner, task, action)
          assertion = assertion_by_id[record["authorization_source_ref"]]
          grant = unique_policy_grant(policy, action)
          unless record["project_policy_revision_id"] == policy["policy_revision_id"] &&
                 record["subject_ref"] == expected_scope &&
                 record["action"] == action &&
                 assertion &&
                 assertion["assertion_digest"] == record["authorization_assertion_digest"] &&
                 assertion["authority_scope_ref"] == expected_scope &&
                 %w[user control_plane].include?(assertion["issuer_kind"]) &&
                 Array(assertion["grants"]).include?(action) &&
                 grant &&
                 Array(assertion["grants"]).include?(grant["required_external_grant"])
            raise genesis_invalid(
              "authorization #{record["authorization_record_id"]} is not exact-bound with a policy-enabled grant"
            )
          end
          unless Array(owner.dig("authority_scope", "allowed_actions")).include?(action)
            raise genesis_invalid("authorization action is not allowed on its owning WorkUnit")
          end
        end
        consumed_assertion_ids = authorizations.map { |record| record["authorization_source_ref"] }
        unless consumed_assertion_ids.sort == assertions.map { |assertion| assertion["assertion_id"] }.sort &&
               consumed_assertion_ids.uniq.length == consumed_assertion_ids.length
          raise genesis_invalid(
            "authority assertion set must exact-equal the sources consumed by AuthorizationRecords (no orphans)"
          )
        end
        unit_refs = units.flat_map { |unit| Array(unit.dig("authority_scope", "authorization_record_refs")) }.sort
        unless unit_refs == authorizations.map { |record| record["authorization_record_id"] }.sort
          raise genesis_invalid(
            "WorkUnit authorization refs must exact-equal the committed records (no orphans or extra refs)"
          )
        end
        units.each do |unit|
          scope = unit["authority_scope"] || {}
          refs = Array(scope["authorization_record_refs"])
          raise genesis_invalid("every executable WorkUnit requires exact AuthorizationRecord provenance") if refs.empty?
          Array(scope["allowed_actions"]).each do |action|
            covered = authorizations.any? do |record|
              record["action"] == action &&
                Array(unit.dig("authority_scope", "authorization_record_refs")).include?(record["authorization_record_id"]) &&
                record["subject_ref"] == WorkAuthority.scope_digest(unit, task, action)
            end
            raise genesis_invalid("each allowed executable action requires an exact AuthorizationRecord") unless covered
          end
        end
      end

      def register_id!(seen_ids, kind, id)
        if seen_ids.include?(id)
          raise genesis_invalid("#{kind} id #{id} is globally create-only and borrowed across transactions")
        end
        seen_ids << id
      end

      def unique_policy_grant(policy, action)
        matches = Array(policy["authority_grants"]).select do |grant|
          grant.is_a?(Hash) && grant["action"] == action
        end
        matches.length == 1 ? matches.first : nil
      end
    end
  end
end
