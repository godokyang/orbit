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
require_relative "protected_change"
require_relative "schema_catalog"
require_relative "task_authority"
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
    # Successor TaskRevisions and ChangeTheses are create-only transactions:
    # exact linear parents, active-policy writer pins, gate lineage closure,
    # protected-change envelopes, and exact WorkAuthority/TaskAuthority
    # partitions. Activation remains a later ControlStore checkpoint fact;
    # evidence/finding durable stores are still deferred.
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
    # - `successor(...)` appends one complete TaskRevision definition that
    #   exact-extends the unique tip. `revise_thesis(...)` appends one
    #   contiguous exact-owner ChangeThesis revision. Both write only under
    #   the active policy snapshot and return `:appended` or verified
    #   `:idempotent`.
    # - `records` returns detached TransactionLog-verified payloads in
    #   chain order (store-level reverification requires `resolve`);
    #   `resolve(task_id:, task_revision_id: nil, authority_verifier:)`
    #   selects the unique tip or an exact historical revision and returns
    #   its complete definition plus revision/thesis histories after replay
    #   from the ProtocolRoot anchor with provider reverification.
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
      SUCCESSOR_PAYLOAD_KEYS = %w[
        authority_assertions authorization_records change_theses
        gate_requirements task work_units
      ].freeze
      THESIS_PAYLOAD_KEYS = %w[change_thesis].freeze
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

      # Appends one complete immutable TaskRevision proposal. Activation is
      # deliberately not a TaskStore side effect: a later controlled
      # LeadCheckpoint must exact-pin the accepted revision before it can
      # become executable truth.
      def successor(task:, gate_requirements:, work_units:, change_theses:,
                    authority_assertions:, authorization_records:,
                    authority_verifier:)
        candidate = {
          "authority_assertions" => authority_assertions,
          "authorization_records" => authorization_records,
          "change_theses" => change_theses,
          "gate_requirements" => gate_requirements,
          "task" => task,
          "work_units" => work_units
        }
        unless task.is_a?(Hash) &&
               task["task_revision_id"].is_a?(String) &&
               Identifiers.valid?("task_revision_id", task["task_revision_id"]) &&
               [gate_requirements, work_units, change_theses,
                authority_assertions, authorization_records].all? { |value| value.is_a?(Array) } &&
               authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "task_store_argument_invalid",
            "successor requires a stable TaskRevision, complete owned records, and a configured verifier",
            path: "task_store.successor"
          )
        end
        append_task_candidate!(
          transaction_id: task.fetch("task_revision_id"),
          candidate: candidate,
          authority_verifier: authority_verifier,
          kind: :successor
        )
      rescue ContractError => error
        raise error unless error.code == "transaction_log_reuse"

        raise ContractError.new(
          "task_store_reuse",
          "TaskRevision #{task.fetch("task_revision_id")} already exists with different canonical content",
          path: "task_store.#{task.fetch("task_revision_id")}"
        )
      end

      # Appends a same-identity, next-revision ChangeThesis proposal. The
      # composite identity is (change_thesis_id, revision); the stable thesis
      # id itself intentionally remains unchanged across the contiguous
      # lineage.
      def revise_thesis(change_thesis:, authority_verifier:)
        unless change_thesis.is_a?(Hash) &&
               change_thesis["change_thesis_id"].is_a?(String) &&
               Identifiers.valid?("change_thesis_id", change_thesis["change_thesis_id"]) &&
               change_thesis["revision"].is_a?(Integer) &&
               change_thesis["revision"] > 1 &&
               authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "task_store_argument_invalid",
            "thesis revision requires a stable identity, revision above one, and a configured verifier",
            path: "task_store.revise_thesis"
          )
        end
        transaction_id = "#{change_thesis.fetch("change_thesis_id")}@#{change_thesis.fetch("revision")}"
        append_task_candidate!(
          transaction_id: transaction_id,
          candidate: { "change_thesis" => change_thesis },
          authority_verifier: authority_verifier,
          kind: :thesis
        )
      rescue ContractError => error
        raise error unless error.code == "transaction_log_reuse"

        raise ContractError.new(
          "task_store_reuse",
          "ChangeThesis revision #{transaction_id} already exists with different canonical content",
          path: "task_store.#{transaction_id}"
        )
      end

      def records
        payloads(@log.records)
      end

      def resolve(task_id:, task_revision_id: nil, authority_verifier:)
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
        if task_revision_id &&
           (!task_revision_id.is_a?(String) || !Identifiers.valid?("task_revision_id", task_revision_id))
          raise ContractError.new(
            "task_store_argument_invalid",
            "task_revision_id must be a stable task revision identifier",
            path: "task_store.task_revision_id"
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
        task_txs = verified.select do |tx|
          [PAYLOAD_KEYS, SUCCESSOR_PAYLOAD_KEYS].include?(tx.keys.sort) &&
            tx.fetch("task").fetch("task_id") == task_id
        end
        unless task_txs.any?
          raise ContractError.new(
            "task_store_missing",
            "no accepted genesis exists for task #{task_id}",
            path: "task_store.#{task_id}"
          )
        end
        selected = if task_revision_id
                     task_txs.find do |tx|
                       tx.fetch("task").fetch("task_revision_id") == task_revision_id
                     end
                   else
                     task_txs.max_by { |tx| tx.fetch("task").fetch("revision_number") }
                   end
        unless selected
          raise ContractError.new(
            "task_store_missing",
            "no accepted TaskRevision #{task_revision_id} exists for task #{task_id}",
            path: "task_store.#{task_id}.#{task_revision_id}"
          )
        end
        genesis_tx = task_txs.find { |tx| tx.keys.sort == PAYLOAD_KEYS }
        selected_revision_id = selected.fetch("task").fetch("task_revision_id")
        thesis_updates = verified.select do |tx|
          tx.keys.sort == THESIS_PAYLOAD_KEYS &&
            tx.fetch("change_thesis").fetch("task_id") == task_id &&
            tx.fetch("change_thesis").fetch("task_revision_id") == selected_revision_id
        end.map { |tx| tx.fetch("change_thesis") }
        result = JSON.parse(CanonicalJSON.dump(selected))
        result["logical_lead"] = genesis_tx.fetch("logical_lead")
        result["change_theses"] = result.fetch("change_theses") + thesis_updates
        result["task_revisions"] = task_txs.map { |tx| tx.fetch("task") }
        result["all_gate_requirements"] = task_txs.flat_map { |tx| tx.fetch("gate_requirements") }
        result["all_work_units"] = task_txs.flat_map { |tx| tx.fetch("work_units") }
        result["all_change_theses"] = task_txs.flat_map { |tx| tx.fetch("change_theses") } +
          verified.select { |tx| tx.keys.sort == THESIS_PAYLOAD_KEYS }
                  .map { |tx| tx.fetch("change_thesis") }
                  .select { |thesis| thesis["task_id"] == task_id }
        result
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
        verified_existing = verify_existing_for_write!(txs, marker, policy, authority_verifier)
        existing = verified_existing.find do |tx|
          tx.keys.sort == PAYLOAD_KEYS && tx.fetch("task").fetch("task_id") == task_id
        end
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
          authority_verifier: authority_verifier, seen_ids: ids_from(verified_existing),
          prior_transactions: verified_existing)
        nil
      end

      def append_task_candidate!(transaction_id:, candidate:, authority_verifier:, kind:)
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          @log.append_with(
            transaction_id: transaction_id,
            payload: candidate,
            validate: lambda do |records, _tip|
              validate_candidate_snapshot!(
                records, candidate, transaction_id, authority_verifier, kind
              )
            end
          )
        end
      end

      def validate_candidate_snapshot!(log_records, candidate, transaction_id,
                                       authority_verifier, kind)
        txs = payloads(log_records)
        marker = ActiveRoot.marker_for(@active_root, code: "task_store_unpinned", label: "task_store")
        policy = resolve_active_policy(marker, authority_verifier)
        verified = verify_existing_for_write!(txs, marker, policy, authority_verifier)
        existing = verified.find do |tx|
          case kind
          when :successor
            [PAYLOAD_KEYS, SUCCESSOR_PAYLOAD_KEYS].include?(tx.keys.sort) &&
              tx.fetch("task").fetch("task_revision_id") == transaction_id
          when :thesis
            tx.keys.sort == THESIS_PAYLOAD_KEYS &&
              "#{tx.dig("change_thesis", "change_thesis_id")}@#{tx.dig("change_thesis", "revision")}" ==
                transaction_id
          end
        end
        if existing
          return :idempotent if canonical_equal?(existing, candidate)

          raise ContractError.new(
            "task_store_reuse",
            "transaction #{transaction_id} already exists with different canonical content",
            path: "task_store.#{transaction_id}"
          )
        end
        validate_transaction!(candidate, policy: policy.fetch("active"),
          pinned_policies: policy.fetch("accepted"), marker: marker,
          authority_verifier: authority_verifier, seen_ids: ids_from(verified),
          prior_transactions: verified)
        nil
      end

      def verify_all_transactions!(txs, marker, policy, authority_verifier)
        verified = []
        seen_ids = Set.new
        txs.each_with_index do |tx, index|
          begin
            validated = validate_transaction!(tx, policy: nil,
              pinned_policies: policy.fetch("accepted"), marker: marker,
              authority_verifier: authority_verifier, seen_ids: seen_ids,
              prior_transactions: verified)
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

      def verify_existing_for_write!(txs, marker, policy, authority_verifier)
        verify_all_transactions!(txs, marker, policy, authority_verifier)
      rescue ContractError => error
        raise error unless error.code == "task_store_lineage_invalid"

        raise genesis_invalid("existing task lineage does not reverify: #{error.message}")
      end

      # Full final validation of one task-genesis transaction: schemas,
      # content digests, epoch, project, exact ownership/ref closure for
      # the task, gates, work graph, theses, and authorizations, with
      # provider verification and policy-enabled grants.
      def validate_transaction!(tx, policy:, pinned_policies:, marker:,
                                authority_verifier:, seen_ids:, prior_transactions:)
        case tx.is_a?(Hash) && tx.keys.sort
        when PAYLOAD_KEYS
          validate_genesis_transaction!(tx, policy: policy,
            pinned_policies: pinned_policies, marker: marker,
            authority_verifier: authority_verifier, seen_ids: seen_ids)
        when SUCCESSOR_PAYLOAD_KEYS
          validate_successor_transaction!(tx, policy: policy,
            pinned_policies: pinned_policies, marker: marker,
            authority_verifier: authority_verifier, seen_ids: seen_ids,
            prior_transactions: prior_transactions)
        when THESIS_PAYLOAD_KEYS
          validate_thesis_transaction!(tx, policy: policy,
            pinned_policies: pinned_policies, marker: marker, seen_ids: seen_ids,
            prior_transactions: prior_transactions)
        else
          raise genesis_invalid("transaction carries malformed component types or unknown fields")
        end
      end

      def validate_genesis_transaction!(tx, policy:, pinned_policies:, marker:,
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

      def validate_successor_transaction!(tx, policy:, pinned_policies:, marker:,
                                          authority_verifier:, seen_ids:,
                                          prior_transactions:)
        unless tx["task"].is_a?(Hash) &&
               [tx["gate_requirements"], tx["work_units"], tx["change_theses"],
                tx["authority_assertions"], tx["authorization_records"]].all? { |list| list.is_a?(Array) }
          raise genesis_invalid("successor transaction carries malformed component types")
        end
        task = tx.fetch("task")
        gates = tx.fetch("gate_requirements")
        units = tx.fetch("work_units")
        theses = tx.fetch("change_theses")
        assertions = tx.fetch("authority_assertions")
        authorizations = tx.fetch("authorization_records")
        project_id = policy ? policy.fetch("project_id") : marker.fetch("project_id")
        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("task_revision", task)
          gates.each { |gate| validator.validate_document!("gate_requirement", gate) }
          units.each { |unit| validator.validate_document!("work_unit", unit) }
          theses.each { |thesis| validator.validate_document!("change_thesis", thesis) }
          assertions.each { |assertion| validator.validate_document!("authority_assertion", assertion) }
          authorizations.each { |record| validator.validate_document!("authorization_record", record) }
        rescue ValidationFailure, ContractError
          raise genesis_invalid("successor records violate their contracts")
        end
        [task, *gates, *units, *theses, *authorizations].each do |record|
          unless CanonicalJSON.content_digest(record) == record["content_digest"]
            raise genesis_invalid("successor record content_digest is not self-consistent")
          end
        end
        unless [task, *gates, *units, *theses, *assertions, *authorizations].all? do |record|
                 record["project_id"] == project_id
               end
          raise genesis_invalid("successor records do not all carry the marker project identity")
        end

        lineage = task_transactions(prior_transactions, task.fetch("task_id"))
        raise genesis_invalid("successor requires one accepted task genesis") if lineage.empty?

        parent = lineage.max_by { |candidate| candidate.fetch("task").fetch("revision_number") }
                        .fetch("task")
        unless task["parent_task_revision_id"] == parent["task_revision_id"] &&
               task["revision_number"] == parent["revision_number"] + 1 &&
               task["project_id"] == parent["project_id"] &&
               task["task_id"] == parent["task_id"]
          raise genesis_invalid("TaskRevision successor must exact-extend the unique accepted tip")
        end
        effective_policy = pinned_policy_for(task, policy, pinned_policies)
        register_id!(seen_ids, "task_revision", task.fetch("task_revision_id"))
        validate_successor_task!(task, parent, gates, policy, pinned_policies)
        parent_tx = lineage.find do |candidate|
          candidate.fetch("task").fetch("task_revision_id") == parent.fetch("task_revision_id")
        end
        validate_successor_gates!(task, gates, effective_policy, units,
          parent_tx.fetch("gate_requirements"), prior_transactions, seen_ids)
        validate_theses!(task, units, theses, seen_ids)
        validate_work_units!(task, units, theses, seen_ids)
        validate_successor_authorizations!(task, parent, gates,
          parent_tx.fetch("gate_requirements"), units, assertions, authorizations,
          effective_policy, authority_verifier, seen_ids)
        tx
      end

      def validate_thesis_transaction!(tx, policy:, pinned_policies:, marker:,
                                       seen_ids:, prior_transactions:)
        thesis = tx["change_thesis"]
        unless thesis.is_a?(Hash)
          raise genesis_invalid("thesis transaction carries a malformed component")
        end
        begin
          Orbit::V2::Validator.new(project_root: @active_root)
            .validate_document!("change_thesis", thesis)
        rescue ValidationFailure, ContractError
          raise genesis_invalid("ChangeThesis successor violates its contract")
        end
        unless CanonicalJSON.content_digest(thesis) == thesis["content_digest"] &&
               thesis["project_id"] == marker["project_id"]
          raise genesis_invalid("ChangeThesis successor digest or project identity is invalid")
        end
        task_tx = task_transactions(prior_transactions, thesis.fetch("task_id")).find do |candidate|
          candidate.fetch("task").fetch("task_revision_id") == thesis.fetch("task_revision_id")
        end
        unit = task_tx && task_tx.fetch("work_units").find do |candidate|
          candidate["work_unit_id"] == thesis["work_unit_id"]
        end
        raise genesis_invalid("ChangeThesis successor owner does not resolve") unless unit
        pinned_policy_for(task_tx.fetch("task"), policy, pinned_policies)

        revisions = thesis_history(prior_transactions, thesis.fetch("change_thesis_id"))
        raise genesis_invalid("ChangeThesis successor requires an accepted revision-1 genesis") if revisions.empty?

        tip = revisions.max_by { |candidate| candidate.fetch("revision") }
        ownership = %w[project_id task_id task_revision_id work_unit_id]
        unless thesis["revision"] == tip["revision"] + 1 &&
               ownership.all? { |field| thesis[field] == tip[field] } &&
               ownership.all? { |field| thesis[field] == unit[field] }
          raise genesis_invalid("ChangeThesis successor must contiguously extend one exact owned lineage")
        end
        # The stable ChangeThesis id is intentionally reused; the log's
        # composite transaction id makes each revision create-only.
        seen_ids
        tx
      end

      def task_transactions(transactions, task_id)
        transactions.select do |tx|
          [PAYLOAD_KEYS, SUCCESSOR_PAYLOAD_KEYS].include?(tx.keys.sort) &&
            tx.dig("task", "task_id") == task_id
        end
      end

      def thesis_history(transactions, thesis_id)
        transactions.flat_map do |tx|
          case tx.keys.sort
          when PAYLOAD_KEYS, SUCCESSOR_PAYLOAD_KEYS
            Array(tx["change_theses"])
          when THESIS_PAYLOAD_KEYS
            [tx.fetch("change_thesis")]
          else
            []
          end
        end.select { |thesis| thesis["change_thesis_id"] == thesis_id }
      end

      def pinned_policy_for(task, active_policy, accepted_policies)
        ref = task["project_policy_revision_ref"]
        if active_policy
          unless ref == {
            "policy_revision_id" => active_policy["policy_revision_id"],
            "content_digest" => active_policy["content_digest"]
          }
            raise genesis_invalid("successor does not pin the currently active policy")
          end
          active_policy
        else
          accepted = accepted_policies.find do |candidate|
            ref == {
              "policy_revision_id" => candidate["policy_revision_id"],
              "content_digest" => candidate["content_digest"]
            }
          end
          raise genesis_invalid("successor pins a policy the store never accepted") unless accepted

          accepted
        end
      end

      def validate_successor_task!(task, parent, gates, policy, pinned_policies)
        pinned_policy_for(task, policy, pinned_policies)
        unless Array(task["unresolved_finding_refs"]) == Array(parent["unresolved_finding_refs"])
          raise genesis_invalid("unresolved Finding refs must carry forward until durable resolutions exist")
        end
        owned_gate_ids = gates.map { |gate| gate.fetch("gate_requirement_id") }.sort
        unless Array(task["gate_requirement_refs"]).sort == owned_gate_ids
          raise genesis_invalid("successor gate_requirement_refs must exact-equal its owned gate set")
        end
        {
          "acceptance" => "acceptance_id",
          "source_requirements" => "source_requirement_id",
          "evidence_requirements" => "evidence_requirement_id",
          "task_questions" => "question_id"
        }.each do |field, id_key|
          ids = Array(task[field]).map { |entry| entry[id_key] }
          unless ids.all? { |id| id.is_a?(String) && STABLE_ID.match?(id) } && ids == ids.uniq
            raise genesis_invalid("successor #{field} must carry unique stable IDs")
          end
        end
      end

      def validate_successor_gates!(task, gates, policy, units, parent_gates,
                                    prior_transactions, seen_ids)
        parent_by_lineage = parent_gates.to_h { |gate| [gate["gate_lineage_id"], gate] }
        prior_gates = prior_transactions.flat_map do |tx|
          [PAYLOAD_KEYS, SUCCESSOR_PAYLOAD_KEYS].include?(tx.keys.sort) ? tx.fetch("gate_requirements") : []
        end
        candidate_lineages = gates.map { |gate| gate["gate_lineage_id"] }
        if candidate_lineages.any?(&:nil?) || candidate_lineages.uniq.length != candidate_lineages.length
          raise genesis_invalid("successor cannot carry duplicate or missing gate lineage identities")
        end
        acceptance_ids = Array(task["acceptance"]).map { |entry| entry["acceptance_id"] }
        question_ids = Array(task["task_questions"]).map { |entry| entry["question_id"] }
        unit_ids = units.map { |unit| unit.fetch("work_unit_id") }
        gates.each do |gate|
          register_id!(seen_ids, "gate_requirement", gate.fetch("gate_requirement_id"))
          unless gate["task_id"] == task["task_id"] &&
                 gate["task_revision_id"] == task["task_revision_id"]
            raise genesis_invalid("successor GateRequirement is not owned by the exact TaskRevision")
          end
          immediate = parent_by_lineage[gate["gate_lineage_id"]]
          if immediate
            unless gate["parent_gate_requirement_ref"] == {
              "gate_requirement_id" => immediate["gate_requirement_id"],
              "content_digest" => immediate["content_digest"]
            }
              raise genesis_invalid("inherited gate must exact-pin its immediate parent")
            end
          elsif gate["parent_gate_requirement_ref"]
            raise genesis_invalid("new gate lineage must be parentless")
          elsif prior_gates.any? { |prior| prior["gate_lineage_id"] == gate["gate_lineage_id"] }
            raise genesis_invalid("a disappeared gate lineage cannot later reappear")
          else
            register_id!(seen_ids, "gate_lineage", gate.fetch("gate_lineage_id"))
          end
          unless Array(gate["acceptance_refs"]).all? { |id| acceptance_ids.include?(id) } &&
                 Array(gate["required_question_refs"]).all? { |id| question_ids.include?(id) }
            raise genesis_invalid("successor gate refs must resolve within its TaskRevision")
          end
          selector = gate["subject_selector"] || {}
          unless (selector["scope"] == "task_wide" && Array(selector["work_unit_refs"]).empty?) ||
                 (selector["scope"] == "selected_work_units" &&
                   Array(selector["work_unit_refs"]).all? { |id| unit_ids.include?(id) })
            raise genesis_invalid("successor gate selector must close against its owned WorkUnits")
          end
        end
        validate_policy_minimums!(task, gates, policy)
      end

      def validate_successor_authorizations!(task, parent, gates, parent_gates,
                                             units, assertions, authorizations,
                                             policy, authority_verifier, seen_ids)
        assertions.each do |assertion|
          register_id!(seen_ids, "authority_assertion", assertion.fetch("assertion_id"))
          begin
            authority_verifier.verify!(assertion)
          rescue ContractError => error
            raise genesis_invalid("successor authority assertion was not provider-verified: #{error.code}")
          end
        end
        assertion_by_id = assertions.to_h { |assertion| [assertion["assertion_id"], assertion] }
        authorizations.each do |record|
          register_id!(seen_ids, "authorization_record", record.fetch("authorization_record_id"))
        end
        work_records = authorizations.select { |record| WorkAuthority.action?(record["action"]) }
        task_records = authorizations.select { |record| TaskAuthority.action?(record["action"]) }
        protected_records = authorizations.select do |record|
          record["action"] == "task.protected_contract.change"
        end
        unless work_records.length + task_records.length + protected_records.length == authorizations.length &&
               protected_records.length <= 1
          raise genesis_invalid("successor authorization transaction contains an unsupported or duplicate record")
        end

        validate_successor_work_authority!(
          task, units, work_records, assertion_by_id, policy
        )
        validate_successor_task_authority!(task, task_records, assertion_by_id, policy)

        authorization_required = ProtectedChange.authorization_required?(parent_gates, gates) ||
          Array(parent["authority_grant_refs"]).sort != Array(task["authority_grant_refs"]).sort
        protected_ref = task["protected_change_authorization_ref"]
        protected = protected_records.first
        if authorization_required || protected_ref
          unless protected && protected["authorization_record_id"] == protected_ref &&
                 valid_protected_change_authorization?(
                   protected, assertion_by_id, parent, task, parent_gates, gates, policy
                 )
            raise genesis_invalid(
              "protected contract changes require the exact active-policy authorization envelope"
            )
          end
        elsif protected
          raise genesis_invalid("orphan protected-change authorization is not allowed")
        end

        consumed = authorizations.map { |record| record["authorization_source_ref"] }
        unless consumed.sort == assertions.map { |assertion| assertion["assertion_id"] }.sort &&
               consumed.uniq.length == consumed.length
          raise genesis_invalid("successor assertions must exact-equal uniquely consumed authorization sources")
        end
      end

      def validate_successor_work_authority!(task, units, records, assertion_by_id, policy)
        units.each do |unit|
          refs = Array(unit.dig("authority_scope", "authorization_record_refs"))
          owned = records.select { |record| refs.include?(record["authorization_record_id"]) }
          allowed_actions = Array(unit.dig("authority_scope", "allowed_actions"))
          unless refs.sort == owned.map { |record| record["authorization_record_id"] }.sort &&
                 refs.uniq.length == refs.length &&
                 owned.all? { |record| allowed_actions.include?(record["action"]) }
            raise genesis_invalid("WorkUnit authorization refs must exact-equal newly committed records")
          end
          allowed_actions.each do |action|
            matching = owned.select { |record| record["action"] == action }
            unless matching.length == 1 && valid_scoped_authorization?(
              matching.first, assertion_by_id, policy,
              WorkAuthority.scope_digest(unit, task, action), action
            )
              raise genesis_invalid("each successor WorkUnit action requires exact policy-enabled provenance")
            end
          end
        end
        unit_refs = units.flat_map do |unit|
          Array(unit.dig("authority_scope", "authorization_record_refs"))
        end
        unless unit_refs.sort == records.map { |record| record["authorization_record_id"] }.sort
          raise genesis_invalid("successor WorkAuthority records cannot be orphaned or borrowed")
        end
      end

      def validate_successor_task_authority!(task, records, assertion_by_id, policy)
        refs = Array(task["authority_grant_refs"])
        unless refs.sort == records.map { |record| record["authorization_record_id"] }.sort &&
               refs.uniq.length == refs.length
          raise genesis_invalid("TaskAuthority refs must exact-equal newly committed records")
        end
        expected_scope = TaskAuthority.scope_digest(task)
        records.each do |record|
          unless valid_scoped_authorization?(
            record, assertion_by_id, policy, expected_scope, record["action"]
          )
            raise genesis_invalid("TaskAuthority record is not exact-bound to the successor revision")
          end
        end
      end

      def valid_scoped_authorization?(record, assertion_by_id, policy, expected_scope, action)
        assertion = assertion_by_id[record["authorization_source_ref"]]
        grant = unique_policy_grant(policy, action)
        record["project_policy_revision_id"] == policy["policy_revision_id"] &&
          record["subject_ref"] == expected_scope &&
          record["action"] == action &&
          assertion &&
          assertion["assertion_digest"] == record["authorization_assertion_digest"] &&
          assertion["authority_scope_ref"] == expected_scope &&
          %w[user control_plane].include?(assertion["issuer_kind"]) &&
          Array(assertion["grants"]).include?(action) &&
          grant &&
          Array(assertion["grants"]).include?(grant["required_external_grant"])
      end

      def valid_protected_change_authorization?(record, assertion_by_id, parent,
                                                candidate, parent_gates,
                                                candidate_gates, policy)
        assertion = assertion_by_id[record["authorization_source_ref"]]
        envelope = record["protected_change_envelope"]
        receipt = assertion && assertion["verification_receipt"]
        grant = unique_policy_grant(policy, "task.protected_contract.change")
        expected_diff = ProtectedChange.diff_digest(
          parent_task: parent,
          candidate_task: candidate,
          parent_gates: parent_gates,
          candidate_gates: candidate_gates
        )
        record["action"] == "task.protected_contract.change" &&
          record["subject_ref"] == candidate["task_revision_id"] &&
          record["project_id"] == candidate["project_id"] &&
          record["project_policy_revision_id"] == policy["policy_revision_id"] &&
          record["authorization_assertion_digest"] == assertion&.dig("assertion_digest") &&
          assertion && receipt && grant &&
          %w[user control_plane].include?(assertion["issuer_kind"]) &&
          assertion["authority_scope_ref"] == expected_diff &&
          Array(assertion["grants"]).include?("task.protected_contract.change") &&
          Array(assertion["grants"]).include?(grant["required_external_grant"]) &&
          envelope.is_a?(Hash) &&
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
          envelope["protected_change_digest"] == expected_diff &&
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
          envelope["issued_at"] == receipt["issued_at"]
      rescue KeyError, ArgumentError
        false
      end

      def ids_from(transactions)
        ids = Set.new
        transactions.each do |tx|
          case tx.keys.sort
          when PAYLOAD_KEYS
            ids << tx.dig("task", "task_id")
            ids << tx.dig("logical_lead", "logical_lead_id")
            ids << tx.dig("task", "task_revision_id")
            %w[gate_requirements work_units authority_assertions authorization_records].each do |field|
              Array(tx[field]).each { |record| ids << primary_id(record) }
            end
            Array(tx["gate_requirements"]).each { |record| ids << record["gate_lineage_id"] }
            Array(tx["change_theses"]).each { |record| ids << record["change_thesis_id"] }
          when SUCCESSOR_PAYLOAD_KEYS
            ids << tx.dig("task", "task_revision_id")
            %w[gate_requirements work_units authority_assertions authorization_records].each do |field|
              Array(tx[field]).each { |record| ids << primary_id(record) }
            end
            Array(tx["gate_requirements"]).each { |record| ids << record["gate_lineage_id"] }
            Array(tx["change_theses"]).each { |record| ids << record["change_thesis_id"] }
          end
        end
        ids.delete(nil)
        ids
      end

      def primary_id(record)
        return unless record.is_a?(Hash)

        %w[gate_requirement_id work_unit_id assertion_id authorization_record_id].each do |field|
          return record[field] if record[field]
        end
        nil
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
        register_id!(seen_ids, "task_revision", task.fetch("task_revision_id"))
        unless task["parent_task_revision_id"].nil? && task["revision_number"] == 1
          raise genesis_invalid("task genesis requires a parentless revision-1 TaskRevision")
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
            raise genesis_invalid("gate genesis lineages must be parentless")
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
            raise genesis_invalid("task genesis requires revision-1 ChangeTheses only")
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
