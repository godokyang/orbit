# frozen_string_literal: true

require "digest"
require "set"

require_relative "active_root"
require_relative "authority_verifier"
require_relative "canonical_json"
require_relative "durable_file"
require_relative "errors"
require_relative "identifiers"
require_relative "lifecycle_verifier"
require_relative "policy_store"
require_relative "runtime_identity_verifier"
require_relative "rule_resolution"
require_relative "schema_catalog"
require_relative "transaction_log"
require_relative "validator"

module Orbit
  module V2
    # Slice 6 increment 4: the controlled control/session genesis seam.
    #
    # One canonical transaction per control, committed atomically under the
    # canonical ProtocolRoot active root via TransactionLog CAS, carrying
    # the exact records that close the genesis transaction: the create-only
    # LeadControlRegistry claim (stable lead_control_id + owned task refs),
    # the initial active LeadSession with its provider-verified
    # runtime-subject binding, the accepted genesis LeadCheckpoint, the
    # AgentInstance whose runtime identity the session pins, and the
    # provider-verified control.genesis AuthorityAssertion. All-or-nothing:
    # a partial claim never becomes accepted truth.
    #
    # Before any acceptance the writer resolves the provider-verified
    # active policy from the PolicyStore itself (anchored by the in-root
    # ProtocolRoot marker, canonical active root proven) INSIDE the same
    # locked snapshot the append commits on, then exact-binds
    # project/control/policy/assertion/runtime-subject and the
    # LeadSession/AgentInstance lifecycle semantics (one active
    # LeadSessionStarted initial event, exact context generation existing
    # and the agent active at start, task.orchestrate capability +
    # task_revision.propose permission — mirroring the public Validator's
    # runtime_lifecycle rules). Root-level shared serialization uses a
    # FIXED lock order: the policy log's exclusive lock is acquired before
    # the control log's, so a policy rotation can never commit between the
    # policy resolution and the control append — an old active policy can
    # never authorize a new control append, and a stale candidate (built
    # against a pre-rotation policy) fails closed at commit time.
    # PolicyStore.rotate takes only the policy lock, so no cycle exists.
    #
    # Public behavior:
    # - `genesis(registry:, session:, checkpoint:, agent:, assertion:,
    #   authority_verifier:, runtime_identity_verifier:,
    #   lifecycle_verifier:)` returns `:appended` or `:idempotent` (same
    #   control id with byte-identical canonical content, and only after
    #   the whole existing snapshot re-verifies — an invalid persisted
    #   store never reports success). A second genesis for the same
    #   control, a reused control with different content, an overlapping
    #   owned task, or an already-active canonical runtime subject fails
    #   closed.
    # - `records` returns detached TransactionLog-verified transaction payloads in chain
    #   order; `resolve(control_id:, authority_verifier:,
    #   runtime_identity_verifier:, lifecycle_verifier:)` REQUIRES all
    #   three configured verifiers and returns {registry, session,
    #   checkpoint, agent, assertion} for the control after replaying every
    #   transaction from the ProtocolRoot anchor with provider-reverification
    #   of authority, runtime identity, AND lifecycle events (typed
    #   event-chain/digest/writer-receipt semantics) plus the cross-control
    #   disjointness closure. Unknown, malformed, forked, or half
    #   transactions fail closed.
    #
    # Error codes: control_store_argument_invalid, control_store_reuse,
    # control_store_unpinned, control_store_genesis_invalid,
    # control_store_lineage_invalid, control_store_subject_conflict,
    # control_store_task_conflict, control_store_missing. TransactionLog
    # storage-level failures propagate as-is.
    #
    # Task/logical-lead EXISTENCE against TaskRevision/LogicalLead records
    # is not closed here: those records are authored by later writer
    # increments. Their refs are schema- and cross-record validated
    # (registry owned_task_refs == genesis checkpoint task_queue;
    # session/checkpoint logical-lead identity consistency).
    class ControlStore
      CONTROL_TRANSACTIONS_FILE = "control-transactions.json".freeze
      PAYLOAD_KEYS = %w[agent assertion checkpoint registry session].freeze
      CHECKPOINT_PAYLOAD_KEYS = %w[assertion checkpoint].freeze
      SESSION_CHECKPOINT_PAYLOAD_KEYS = %w[agent assertion checkpoint prior_session session].freeze
      EXECUTION_PAYLOAD_KEYS = %w[
        attempt dispatch_assertion dispatch_checkpoint observation_assertion
        observation_checkpoint rule_resolution worker_agent
      ].freeze
      # The terminal reconciliation transaction carries the terminated
      # attempt plus, when the deterministic attempt_terminal reconcile
      # authorizes a successor dispatch, the full successor composite: the
      # terminal checkpoint IS the exact authorizing dispatch checkpoint.
      TERMINAL_PAYLOAD_KEYS = %w[
        assertion attempt checkpoint observation_assertion observation_checkpoint
        rule_resolution successor_attempt worker_agent
      ].freeze
      TERMINAL_EVENT_TYPES = %w[AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled].freeze
      GENESIS_ACTION = "control.genesis".freeze
      CHECKPOINT_ACTION = "control.checkpoint".freeze

      def initialize(active_root:)
        @active_root = File.expand_path(active_root)
        unless File.directory?(@active_root)
          raise ContractError.new(
            "control_store_argument_invalid",
            "active root must be an existing directory",
            path: "control_store.active_root"
          )
        end
        @log = TransactionLog.new(path: File.join(@active_root, CONTROL_TRANSACTIONS_FILE))
      end

      def genesis(registry:, session:, checkpoint:, agent:, assertion:,
                  authority_verifier:, runtime_identity_verifier:, lifecycle_verifier:)
        unless [registry, session, checkpoint, agent, assertion].all? { |record| record.is_a?(Hash) } &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "control_store_argument_invalid",
            "registry, session, checkpoint, agent, assertion, and all three configured verifiers are required",
            path: "control_store"
          )
        end
        candidate = payload(registry, session, checkpoint, agent, assertion)
        control_id = registry.fetch("lead_control_id")
        # Root-level shared serialization with a FIXED lock order: policy
        # log -> task log -> control log. Genesis re-verifies every
        # existing successor checkpoint, so it must hold the task snapshot
        # stable as well as the policy snapshot until its append commits.
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            @log.append_with(
              transaction_id: control_id,
              payload: candidate,
              validate: lambda do |records, _tip|
                validate_genesis_snapshot!(
                  records, candidate, control_id,
                  authority_verifier, runtime_identity_verifier, lifecycle_verifier
                )
              end
            )
          end
        end
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "control_store_reuse",
          "control #{registry.fetch("lead_control_id")} already exists with different canonical content",
          path: "control_store.#{registry.fetch("lead_control_id")}"
        )
      end

      # Controlled successor LeadCheckpoint selection/dispatch: appends a
      # non-genesis checkpoint transaction for an existing control, with
      # the exact prior accepted checkpoint as predecessor, the control's
      # genesis active-session pins, the owned task queue, and a
      # provider-verified control.checkpoint writer assertion. Returns
      # `:appended` or `:idempotent` (same checkpoint id, byte-identical
      # canonical content, only after the whole existing snapshot
      # re-verifies).
      def checkpoint(checkpoint:, assertion:, authority_verifier:,
                     runtime_identity_verifier:, lifecycle_verifier:,
                     prior_session: nil, session: nil, agent: nil)
        unless checkpoint.is_a?(Hash) && assertion.is_a?(Hash) &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "control_store_argument_invalid",
            "checkpoint, assertion, and all three configured verifiers are required",
            path: "control_store"
          )
        end
        session_form = [prior_session, session, agent].any? { |record| !record.nil? }
        if session_form && ![prior_session, session, agent].all? { |record| record.is_a?(Hash) }
          raise ContractError.new(
            "control_store_argument_invalid",
            "session transition requires prior_session, session, and agent records together",
            path: "control_store"
          )
        end
        if checkpoint.dig("reconcile_trigger", "event") == "task_revision_change"
          raise ContractError.new(
            "control_store_argument_invalid",
            "task revision activation is owned by the activate seam",
            path: "control_store.checkpoint"
          )
        end
        checkpoint_id = checkpoint["lead_checkpoint_id"]
        unless checkpoint_id.is_a?(String) && Identifiers.valid?("lead_checkpoint_id", checkpoint_id)
          raise ContractError.new(
            "control_store_argument_invalid",
            "checkpoint lead_checkpoint_id must be a stable checkpoint identifier",
            path: "control_store.lead_checkpoint_id"
          )
        end
        candidate = if session_form
                      { "agent" => agent, "assertion" => assertion, "checkpoint" => checkpoint,
                        "prior_session" => prior_session, "session" => session }
                    else
                      { "assertion" => assertion, "checkpoint" => checkpoint }
                    end
        # Fixed root lock order: policy log -> task log -> control log, so
        # the TaskStore facts resolved inside the checkpoint snapshot and
        # the control append are atomic with respect to task commits and
        # policy rotations.
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            @log.append_with(
              transaction_id: checkpoint_id,
              payload: candidate,
              validate: lambda do |records, _tip|
                validate_checkpoint_snapshot!(
                  records, candidate, checkpoint_id,
                  authority_verifier, runtime_identity_verifier, lifecycle_verifier
                )
              end
            )
          end
        end
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "control_store_reuse",
          "checkpoint #{checkpoint_id} already exists with different canonical content",
          path: "control_store.#{checkpoint_id}"
        )
      end

      # Commits the complete dispatch boundary as one control-log
      # transaction: assigned rules, the authorizing dispatch checkpoint,
      # AttemptCreated, and its immediate observation checkpoint. No
      # accepted dispatch or attempt half-state can exist between files.
      def dispatch(rule_resolution:, dispatch_checkpoint:, dispatch_assertion:,
                   attempt:, worker_agent:, observation_checkpoint:,
                   observation_assertion:, authority_verifier:,
                   runtime_identity_verifier:, lifecycle_verifier:)
        components = [rule_resolution, dispatch_checkpoint, dispatch_assertion,
          attempt, worker_agent, observation_checkpoint, observation_assertion]
        unless components.all? { |record| record.is_a?(Hash) } &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "control_store_argument_invalid",
            "dispatch requires all seven records and three configured verifiers",
            path: "control_store.dispatch"
          )
        end
        attempt_id = attempt["attempt_id"]
        unless attempt_id.is_a?(String) && Identifiers.valid?("attempt_id", attempt_id)
          raise ContractError.new(
            "control_store_argument_invalid",
            "dispatch attempt_id must be a stable attempt identifier",
            path: "control_store.dispatch.attempt_id"
          )
        end
        candidate = {
          "attempt" => attempt,
          "dispatch_assertion" => dispatch_assertion,
          "dispatch_checkpoint" => dispatch_checkpoint,
          "observation_assertion" => observation_assertion,
          "observation_checkpoint" => observation_checkpoint,
          "rule_resolution" => rule_resolution,
          "worker_agent" => worker_agent
        }
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            @log.append_with(
              transaction_id: attempt_id,
              payload: candidate,
              validate: lambda do |records, _tip|
                validate_dispatch_snapshot!(records, candidate, attempt_id,
                  authority_verifier, runtime_identity_verifier, lifecycle_verifier)
              end
            )
          end
        end
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "control_store_reuse",
          "attempt #{attempt_id} already exists with different canonical content",
          path: "control_store.#{attempt_id}"
        )
      end

      # Commits the controlled atomic terminal reconciliation as ONE
      # control-log transaction: the accepted Attempt's byte-identical
      # lifecycle prefix plus exactly one provider-verified terminal event,
      # and the exact successor LeadCheckpoint + writer assertion that
      # terminal-pins it. The terminal checkpoint extends the unique current
      # observation tip of that attempt, and a later dispatch is accepted
      # only once this terminal transaction is the lineage tip.
      def terminal(attempt:, checkpoint:, assertion:, successor_attempt:,
                   worker_agent:, rule_resolution:, observation_checkpoint:,
                   observation_assertion:, authority_verifier:,
                   runtime_identity_verifier:, lifecycle_verifier:)
        unless [attempt, checkpoint, assertion, successor_attempt, worker_agent,
                rule_resolution, observation_checkpoint, observation_assertion].all? { |record| record.is_a?(Hash) } &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "control_store_argument_invalid",
            "terminal reconciliation requires the terminated attempt, terminal checkpoint, " \
              "successor composite (attempt/worker/rule/observation) with assertions, and three verifiers",
            path: "control_store.terminal"
          )
        end
        checkpoint_id = checkpoint["lead_checkpoint_id"]
        unless checkpoint_id.is_a?(String) && Identifiers.valid?("lead_checkpoint_id", checkpoint_id)
          raise ContractError.new(
            "control_store_argument_invalid",
            "terminal checkpoint lead_checkpoint_id must be a stable checkpoint identifier",
            path: "control_store.terminal.lead_checkpoint_id"
          )
        end
        candidate = {
          "assertion" => assertion,
          "attempt" => attempt,
          "checkpoint" => checkpoint,
          "observation_assertion" => observation_assertion,
          "observation_checkpoint" => observation_checkpoint,
          "rule_resolution" => rule_resolution,
          "successor_attempt" => successor_attempt,
          "worker_agent" => worker_agent
        }
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            @log.append_with(
              transaction_id: checkpoint_id,
              payload: candidate,
              validate: lambda do |records, _tip|
                validate_terminal_snapshot!(
                  records, candidate, checkpoint_id,
                  authority_verifier, runtime_identity_verifier, lifecycle_verifier
                )
              end
            )
          end
        end
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "control_store_reuse",
          "terminal checkpoint #{checkpoint_id} already exists with different canonical content",
          path: "control_store.#{checkpoint_id}"
        )
      end

      # Controlled TaskRevision activation: commits ONE exact
      # task_revision_change LeadCheckpoint (plus its writer assertion) that
      # transitions the owned task from the exact accepted parent revision
      # to the exact accepted child revision of the same task, in one
      # closed control-log transaction under policy -> task -> control
      # locks. The TaskStore child append itself is proposal-only: the r1
      # control stays readable/dispatchable until this activation commits,
      # and every later checkpoint resolves the task at its OWN queue
      # revision.
      def activate(task_revision_id:, checkpoint:, assertion:, authority_verifier:,
                   runtime_identity_verifier:, lifecycle_verifier:)
        unless checkpoint.is_a?(Hash) && assertion.is_a?(Hash) &&
               task_revision_id.is_a?(String) && Identifiers.valid?("task_revision_id", task_revision_id) &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "control_store_argument_invalid",
            "activate requires the child task_revision_id, checkpoint, assertion, and three configured verifiers",
            path: "control_store.activate"
          )
        end
        # Canonical same-snapshot copy: the bound revision id and the
        # committed candidate are frozen snapshots taken BEFORE binding, so
        # concurrent caller mutation of the mutable input objects can never
        # swap revision A for committed revision B (the resolved child
        # descends from the snapshot queue ref).
        revision_id = task_revision_id.dup
        candidate = JSON.parse(CanonicalJSON.dump(
          { "assertion" => assertion, "checkpoint" => checkpoint }
        ))
        unless candidate.dig("checkpoint", "reconcile_trigger", "event") == "task_revision_change"
          raise ContractError.new(
            "control_store_argument_invalid",
            "activation checkpoint must reconcile on task_revision_change",
            path: "control_store.activate"
          )
        end
        queue_ref = Array(candidate.dig("checkpoint", "task_queue")).first
        unless queue_ref.is_a?(Hash) &&
               queue_ref["task_revision_id"] == revision_id &&
               candidate.dig("checkpoint", "active_task_ref", "task_revision_id") == revision_id
          raise ContractError.new(
            "control_store_argument_invalid",
            "task_revision_id must exact-bind the activation checkpoint queue and active task ref",
            path: "control_store.activate.task_revision_id"
          )
        end
        checkpoint_id = candidate.dig("checkpoint", "lead_checkpoint_id")
        unless checkpoint_id.is_a?(String) && Identifiers.valid?("lead_checkpoint_id", checkpoint_id)
          raise ContractError.new(
            "control_store_argument_invalid",
            "activation checkpoint lead_checkpoint_id must be a stable checkpoint identifier",
            path: "control_store.activate.lead_checkpoint_id"
          )
        end
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            @log.append_with(
              transaction_id: checkpoint_id,
              payload: candidate,
              validate: lambda do |records, _tip|
                validate_checkpoint_snapshot!(
                  records, candidate, checkpoint_id,
                  authority_verifier, runtime_identity_verifier, lifecycle_verifier
                )
              end
            )
          end
        end
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "control_store_reuse",
          "activation checkpoint #{checkpoint_id} already exists with different canonical content",
          path: "control_store.#{checkpoint_id}"
        )
      end

      def records
        payloads(@log.records)
      end

      def resolve(control_id:, authority_verifier:, runtime_identity_verifier:,
                  lifecycle_verifier:)
        unless authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "control_store_argument_invalid",
            "resolve requires configured authority, runtime identity, and lifecycle verifiers",
            path: "control_store.resolve"
          )
        end
        unless control_id.is_a?(String) && Identifiers.valid?("lead_control_id", control_id)
          raise ContractError.new(
            "control_store_argument_invalid",
            "control_id must be a stable lead control identifier",
            path: "control_store.control_id"
          )
        end
        txs = payloads(@log.records)
        marker = ActiveRoot.marker_for(@active_root, code: "control_store_unpinned", label: "control_store")
        policy = begin
          resolve_active_policy(marker, authority_verifier)
        rescue ContractError => e
          raise lineage_invalid("#{e.code}: #{e.message}")
        end
        verified = verify_all_transactions!(txs, marker, policy, authority_verifier,
          runtime_identity_verifier, lifecycle_verifier)
        target = verified.find do |tx|
          tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS &&
            tx.fetch("registry").fetch("lead_control_id") == control_id
        end
        unless target
          raise ContractError.new(
            "control_store_missing",
            "no accepted genesis exists for control #{control_id}",
            path: "control_store.#{control_id}"
          )
        end
        successor_txs = verified.select do |tx|
          checkpoint_entries(tx).any? do |entry|
            entry.fetch("checkpoint").fetch("lead_control_id") == control_id
          end
        end
        current_session = target.fetch("session")
        current_agent = target.fetch("agent")
        successor_txs.each do |tx|
          if tx.keys.sort == SESSION_CHECKPOINT_PAYLOAD_KEYS
            current_session = tx.fetch("session")
            current_agent = tx.fetch("agent")
          end
        end
        entries = successor_txs.flat_map { |tx| checkpoint_entries(tx) }.select do |entry|
          entry.fetch("checkpoint").fetch("lead_control_id") == control_id
        end
        latest = entries.last || { "checkpoint" => target.fetch("checkpoint"), "assertion" => target.fetch("assertion") }
        # Accepted execution facts: the LATEST attempt representation per
        # attempt id (a terminal reconciliation supersedes the composite's
        # immutable AttemptCreated-only payload) plus the content-addressed
        # rule resolutions carried by the composites.
        attempts = {}
        resolutions = {}
        successor_txs.each do |tx|
          if tx.keys.sort == EXECUTION_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
            resolutions[tx.fetch("rule_resolution").fetch("resolution_id")] = tx.fetch("rule_resolution")
          elsif tx.keys.sort == TERMINAL_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt if attempts.key?(attempt.fetch("attempt_id"))
            successor = tx.fetch("successor_attempt")
            attempts[successor.fetch("attempt_id")] = successor
            resolutions[tx.fetch("rule_resolution").fetch("resolution_id")] = tx.fetch("rule_resolution")
          end
        end
        {
          "registry" => target.fetch("registry"),
          "session" => current_session,
          "checkpoint" => latest.fetch("checkpoint"),
          "agent" => current_agent,
          "assertion" => latest.fetch("assertion"),
          # Accepted successor checkpoints of the control, in accepted
          # transaction order.
          "checkpoints" => entries.map { |entry| entry.fetch("checkpoint") },
          "attempts" => attempts.values,
          "rule_resolutions" => resolutions.values
        }
      end

      # Resolves one exact accepted Attempt from the fully reverified
      # project-wide control log. Callers never need to scan `records` and
      # mistake storage-valid bytes for accepted execution facts. The
      # returned Attempt is its latest immutable representation, accompanied
      # by the exact assigned RuleResolution and provider-verified worker
      # AgentInstance used by evidence/evaluation writers.
      def resolve_attempt(attempt_id:, authority_verifier:, runtime_identity_verifier:,
                          lifecycle_verifier:)
        unless authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!) &&
               attempt_id.is_a?(String) && Identifiers.valid?("attempt_id", attempt_id)
          raise ContractError.new(
            "control_store_argument_invalid",
            "resolve_attempt requires a stable attempt id and all three configured verifiers",
            path: "control_store.resolve_attempt"
          )
        end

        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@active_root, CONTROL_TRANSACTIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
              resolve_attempt_snapshot!(
                attempt_id,
                authority_verifier,
                runtime_identity_verifier,
                lifecycle_verifier
              )
            end
          end
        end
      end

      # Durable recovery from the unique accepted lineage tip as a pure
      # read/reconcile seam: the whole snapshot re-verifies, then the tip's
      # own stored trigger is re-run through the deterministic
      # LeadControl.reconcile projection over the assembled bundle. The
      # recomputed decision must byte-equal the stored tip decision
      # (idempotent by construction); recovery never synthesizes missing
      # facts, never redispatchs an accepted attempt, and returns exactly
      # one documented state: the tip decision's state/action/reason.
      def recover(control_id:, authority_verifier:, runtime_identity_verifier:,
                  lifecycle_verifier:)
        unless authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "control_store_argument_invalid",
            "recover requires configured authority, runtime identity, and lifecycle verifiers",
            path: "control_store.recover"
          )
        end
        unless control_id.is_a?(String) && Identifiers.valid?("lead_control_id", control_id)
          raise ContractError.new(
            "control_store_argument_invalid",
            "control_id must be a stable lead control identifier",
            path: "control_store.recover.control_id"
          )
        end
        # The complete recovery window — log read, whole-snapshot
        # reverification, tip derivation, and reconcile — runs under the
        # SAME fixed policy -> task -> control locks as every writer
        # (writers hold policy + task across their append, and the append
        # itself takes the control log lock), so a concurrent successor can
        # never append between the read and the returned decision: the
        # recovered tip is the unique current tip by construction.
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@active_root, CONTROL_TRANSACTIONS_FILE)
        recovered = DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
            txs = payloads(@log.records)
            marker = ActiveRoot.marker_for(@active_root, code: "control_store_unpinned", label: "control_store")
            policy = begin
              resolve_active_policy(marker, authority_verifier)
            rescue ContractError => e
              raise lineage_invalid("#{e.code}: #{e.message}")
            end
            verified = verify_all_transactions!(txs, marker, policy, authority_verifier,
              runtime_identity_verifier, lifecycle_verifier)
            genesis_tx = verified.find do |tx|
              tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS &&
                tx.fetch("registry").fetch("lead_control_id") == control_id
            end
            unless genesis_tx
              raise ContractError.new(
                "control_store_missing",
                "no accepted genesis exists for control #{control_id}",
                path: "control_store.#{control_id}"
              )
            end
            control_txs = verified.select do |tx|
              checkpoint_entries(tx).any? do |entry|
                entry.fetch("checkpoint").fetch("lead_control_id") == control_id
              end
            end
            entries = control_txs.flat_map { |tx| checkpoint_entries(tx) }.select do |entry|
              entry.fetch("checkpoint").fetch("lead_control_id") == control_id
            end
            # The unique current tip: the genesis checkpoint when no
            # successor exists, else the last accepted checkpoint of the
            # lineage (the log is a single compare-and-append chain, so the
            # last entry is the only tip; the stored-decision reconcile
            # comparison below fails closed on any stale/corrupted tip).
            entries = [{ "checkpoint" => genesis_tx.fetch("checkpoint"),
                         "assertion" => genesis_tx.fetch("assertion") }] + entries
            tip = entries.last
            checkpoint = tip.fetch("checkpoint")
            trigger = checkpoint.dig("reconcile_trigger", "event")
            trigger = "genesis" if trigger.nil? && checkpoint["is_genesis"] == true
            unless trigger.is_a?(String) && !trigger.empty?
              raise recovery_invalid("tip checkpoint carries no stored trigger to re-run")
            end
            registry = genesis_tx.fetch("registry")
            task_facts = begin
              resolve_task_facts!(checkpoint, registry, authority_verifier)
            rescue ContractError => error
              raise recovery_invalid("tip task facts do not resolve: #{error.code}")
            end
            bundle = assemble_bundle(marker, policy.fetch("accepted"),
              policy.fetch("accepted_assertions"), genesis_tx, control_txs,
              {}, task_facts.fetch("payload"))
            begin
              decision = Orbit::V2::LeadControl.reconcile(
                {
                  "bundle" => bundle,
                  "lead_control_id" => control_id,
                  "lead_checkpoint_ref" => {
                    "lead_checkpoint_id" => checkpoint["lead_checkpoint_id"],
                    "content_digest" => checkpoint["content_digest"]
                  }
                },
                trigger
              )
            rescue StandardError
              raise recovery_invalid("tip trigger projection failed to recompute")
            end
            unless canonical_equal?(checkpoint["lead_decision"], decision)
              raise recovery_invalid(
                "tip stored decision does not match the deterministic reconcile projection"
              )
            end
            decision
            end
          end
        end
        recovered
      end

      private

      def resolve_attempt_snapshot!(attempt_id, authority_verifier,
                                    runtime_identity_verifier, lifecycle_verifier)
        txs = payloads(@log.records)
        marker = ActiveRoot.marker_for(
          @active_root,
          code: "control_store_unpinned",
          label: "control_store"
        )
        policy = begin
          resolve_active_policy(marker, authority_verifier)
        rescue ContractError => error
          raise lineage_invalid("#{error.code}: #{error.message}")
        end
        verified = verify_all_transactions!(
          txs,
          marker,
          policy,
          authority_verifier,
          runtime_identity_verifier,
          lifecycle_verifier
        )

        attempts = {}
        agents = {}
        resolutions = {}
        verified.each do |tx|
          case tx.keys.sort
          when PAYLOAD_KEYS
            agent = tx.fetch("agent")
            agents[agent.fetch("agent_instance_id")] = agent
          when SESSION_CHECKPOINT_PAYLOAD_KEYS
            agent = tx.fetch("agent")
            agents[agent.fetch("agent_instance_id")] = agent
          when EXECUTION_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
            agent = tx.fetch("worker_agent")
            agents[agent.fetch("agent_instance_id")] = agent
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
          when TERMINAL_PAYLOAD_KEYS
            terminal = tx.fetch("attempt")
            attempts[terminal.fetch("attempt_id")] = terminal if attempts.key?(terminal.fetch("attempt_id"))
            successor = tx.fetch("successor_attempt")
            attempts[successor.fetch("attempt_id")] = successor
            agent = tx.fetch("worker_agent")
            agents[agent.fetch("agent_instance_id")] = agent
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
          end
        end

        attempt = attempts[attempt_id]
        unless attempt
          raise ContractError.new(
            "control_store_missing",
            "no accepted Attempt exists for #{attempt_id}",
            path: "control_store.attempts.#{attempt_id}"
          )
        end
        assignment = attempt.dig("events", 0, "assignment") || {}
        rule = resolutions[assignment["assigned_rule_resolution_id"]]
        agent = agents[assignment["agent_instance_id"]]
        unless rule && agent
          raise lineage_invalid("accepted Attempt has no exact RuleResolution or worker AgentInstance")
        end

        JSON.parse(
          CanonicalJSON.dump(
            "attempt" => attempt,
            "agent" => agent,
            "rule_resolution" => rule,
            "lead_control_id" => attempt.fetch("lead_control_id")
          )
        )
      end

      def payload(registry, session, checkpoint, agent, assertion)
        {
          "assertion" => assertion,
          "agent" => agent,
          "checkpoint" => checkpoint,
          "registry" => registry,
          "session" => session
        }
      end

      def payloads(records)
        records.map do |record|
          payload = record["payload"]
          raise lineage_invalid("transaction payload is not a canonical object") unless payload.is_a?(Hash)

          JSON.parse(CanonicalJSON.dump(payload))
        end
      end

      def canonical_equal?(left, right)
        CanonicalJSON.dump(left) == CanonicalJSON.dump(right)
      end

      def checkpoint_entries(tx)
        return [] unless tx.is_a?(Hash)

        case tx.keys.sort
        when CHECKPOINT_PAYLOAD_KEYS, SESSION_CHECKPOINT_PAYLOAD_KEYS
          [{ "checkpoint" => tx.fetch("checkpoint"), "assertion" => tx.fetch("assertion") }]
        when EXECUTION_PAYLOAD_KEYS, TERMINAL_PAYLOAD_KEYS
          dispatch = tx["dispatch_checkpoint"] || tx.fetch("checkpoint")
          dispatch_assertion = tx["dispatch_assertion"] || tx.fetch("assertion")
          [
            { "checkpoint" => dispatch, "assertion" => dispatch_assertion },
            { "checkpoint" => tx.fetch("observation_checkpoint"),
              "assertion" => tx.fetch("observation_assertion") }
          ]
        else
          []
        end
      end

      def lineage_invalid(message, index = nil)
        ContractError.new(
          "control_store_lineage_invalid",
          "control authority store lineage is invalid: #{message}",
          path: "control_store",
          details: index.nil? ? nil : { "transaction_index" => index }
        )
      end

      def genesis_invalid(message, details = nil)
        ContractError.new(
          "control_store_genesis_invalid",
          "control genesis rejected: #{message}",
          path: "control_store",
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
          # Accepted revisions and their issuance assertions come from the
          # SAME provider-verified PolicyStore snapshot as the resolved
          # lineage.
          "accepted" => resolved.fetch("accepted_policies"),
          "accepted_assertions" => resolved.fetch("accepted_assertions")
        }
      rescue ContractError => e
        raise e if e.code == "control_store_genesis_invalid"

        raise genesis_invalid(
          "durable policy store does not resolve the pinned genesis",
          { "cause" => e.code, "message" => e.message }
        )
      end

      # Runs inside TransactionLog's exclusive lock against the same
      # verified snapshot the append commits on. Returns nil to proceed,
      # :idempotent for a committed replay, or raises. The marker/policy/
      # provider/lineage verification of the WHOLE existing snapshot runs
      # BEFORE any idempotency short-circuit: a replay can only be
      # idempotent against an already-verified committed transaction, never
      # against invalid persisted records.
      def validate_genesis_snapshot!(records, candidate, control_id,
                                     authority_verifier, runtime_identity_verifier,
                                     lifecycle_verifier)
        txs = payloads(records)
        marker = ActiveRoot.marker_for(@active_root, code: "control_store_unpinned", label: "control_store")
        policy = resolve_active_policy(marker, authority_verifier)
        # Existing controls are re-verified against the same snapshot (a
        # broken/forged store can never be extended), and the candidate is
        # validated against the policy resolved AT COMMIT TIME (never an
        # old active policy read before the lock), so a policy rotation
        # between construction and commit fails closed.
        seen_event_ids = Set.new
        verified_existing = begin
          verify_all_transactions!(txs, marker, policy, authority_verifier,
            runtime_identity_verifier, lifecycle_verifier, seen_event_ids: seen_event_ids)
        rescue ContractError => error
          raise genesis_invalid(
            "existing snapshot does not fully re-verify: #{error.code}"
          )
        end
        existing = verified_existing.find do |tx|
          tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS &&
            tx.fetch("registry").fetch("lead_control_id") == control_id
        end
        if existing
          return :idempotent if canonical_equal?(existing, candidate)

          raise ContractError.new(
            "control_store_reuse",
            "control #{control_id} already exists with different canonical content",
            path: "control_store.#{control_id}"
          )
        end
        validated = validate_transaction!(
          candidate,
          policy: policy.fetch("active"),
          pinned_policies: policy.fetch("accepted"),
          marker: marker,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier,
          seen_event_ids: seen_event_ids,
          all_txs: txs
        )
        reject_cross_control_conflicts!(
          verified_existing.select { |tx| tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS },
          validated
        )
        nil
      end

      # Runs inside TransactionLog's exclusive lock against the same
      # verified snapshot the append commits on. Returns nil to proceed,
      # :idempotent for a committed replay, or raises. The whole existing
      # snapshot re-verifies BEFORE any idempotency short-circuit.
      def validate_checkpoint_snapshot!(records, candidate, checkpoint_id,
                                        authority_verifier, runtime_identity_verifier,
                                        lifecycle_verifier)
        txs = payloads(records)
        marker = ActiveRoot.marker_for(@active_root, code: "control_store_unpinned", label: "control_store")
        policy = resolve_active_policy(marker, authority_verifier)
        seen_event_ids = Set.new
        verified_existing = begin
          verify_all_transactions!(txs, marker, policy, authority_verifier,
            runtime_identity_verifier, lifecycle_verifier, seen_event_ids: seen_event_ids)
        rescue ContractError => error
          raise checkpoint_invalid(
            "existing snapshot does not fully re-verify: #{error.code}"
          )
        end
        existing = verified_existing.find do |tx|
          tx.is_a?(Hash) && [CHECKPOINT_PAYLOAD_KEYS, SESSION_CHECKPOINT_PAYLOAD_KEYS].include?(tx.keys.sort) &&
            tx.fetch("checkpoint").fetch("lead_checkpoint_id") == checkpoint_id
        end
        if existing
          return :idempotent if canonical_equal?(existing, candidate)

          raise ContractError.new(
            "control_store_reuse",
            "checkpoint #{checkpoint_id} already exists with different canonical content",
            path: "control_store.#{checkpoint_id}"
          )
        end
        validate_transaction!(
          candidate,
          policy: policy.fetch("active"),
          pinned_policies: policy.fetch("accepted"),
          accepted_assertions: policy.fetch("accepted_assertions"),
          marker: marker,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier,
          seen_event_ids: seen_event_ids,
          all_txs: txs
        )
        nil
      end

      def validate_dispatch_snapshot!(records, candidate, attempt_id,
                                      authority_verifier, runtime_identity_verifier,
                                      lifecycle_verifier)
        txs = payloads(records)
        marker = ActiveRoot.marker_for(@active_root, code: "control_store_unpinned", label: "control_store")
        policy = resolve_active_policy(marker, authority_verifier)
        seen_ids = Set.new
        verified_existing = begin
          verify_all_transactions!(txs, marker, policy, authority_verifier,
            runtime_identity_verifier, lifecycle_verifier, seen_event_ids: seen_ids)
        rescue ContractError => error
          raise dispatch_invalid("existing snapshot does not fully re-verify: #{error.code}")
        end
        existing = verified_existing.find do |tx|
          tx.is_a?(Hash) && tx.keys.sort == EXECUTION_PAYLOAD_KEYS &&
            tx.fetch("attempt").fetch("attempt_id") == attempt_id
        end
        if existing
          return :idempotent if canonical_equal?(existing, candidate)

          raise ContractError.new(
            "control_store_reuse",
            "attempt #{attempt_id} already exists with different canonical content",
            path: "control_store.#{attempt_id}"
          )
        end
        validate_transaction!(candidate,
          policy: policy.fetch("active"), pinned_policies: policy.fetch("accepted"),
          accepted_assertions: policy.fetch("accepted_assertions"), marker: marker,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_ids,
          all_txs: txs)
        nil
      end

      def validate_terminal_snapshot!(records, candidate, checkpoint_id,
                                      authority_verifier, runtime_identity_verifier,
                                      lifecycle_verifier)
        txs = payloads(records)
        marker = ActiveRoot.marker_for(@active_root, code: "control_store_unpinned", label: "control_store")
        policy = resolve_active_policy(marker, authority_verifier)
        seen_ids = Set.new
        verified_existing = begin
          verify_all_transactions!(txs, marker, policy, authority_verifier,
            runtime_identity_verifier, lifecycle_verifier, seen_event_ids: seen_ids)
        rescue ContractError => error
          raise terminal_invalid("existing snapshot does not fully re-verify: #{error.code}")
        end
        existing = verified_existing.find do |tx|
          tx.is_a?(Hash) && tx.keys.sort == TERMINAL_PAYLOAD_KEYS &&
            tx.fetch("checkpoint").fetch("lead_checkpoint_id") == checkpoint_id
        end
        if existing
          return :idempotent if canonical_equal?(existing, candidate)

          raise ContractError.new(
            "control_store_reuse",
            "terminal checkpoint #{checkpoint_id} already exists with different canonical content",
            path: "control_store.#{checkpoint_id}"
          )
        end
        validate_transaction!(candidate,
          policy: policy.fetch("active"), pinned_policies: policy.fetch("accepted"),
          accepted_assertions: policy.fetch("accepted_assertions"), marker: marker,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_ids,
          all_txs: txs)
        nil
      end

      def verify_all_transactions!(txs, marker, policy, authority_verifier,
                                   runtime_identity_verifier, lifecycle_verifier,
                                   seen_event_ids: Set.new)
        verified = []
        txs.each_with_index do |tx, index|
          begin
            # Historical replay is per transaction: each existing control
            # transaction is provider-reverified against an ancestor-prefix
            # policy snapshot whose ACTIVE revision is the exact
            # project_policy_revision_ref frozen by that transaction
            # (checkpoint/Attempt). Different historical transactions may
            # pin different accepted revisions; a later rotation never
            # reinterprets them with one global active. NEW writer
            # candidates are still validated against the current active
            # policy in the same locked window, so stale writes keep
            # failing closed.
            prefix, prefix_assertions = historical_policy_prefix(policy, tx)
            validated = validate_transaction!(
              tx,
              policy: nil,
              pinned_policies: prefix,
              accepted_assertions: prefix_assertions,
              marker: marker,
              authority_verifier: authority_verifier,
              runtime_identity_verifier: runtime_identity_verifier,
              lifecycle_verifier: lifecycle_verifier,
              seen_event_ids: seen_event_ids,
              all_txs: txs.first(index)
            )
            if validated.is_a?(Hash) && validated.keys.sort == PAYLOAD_KEYS
              reject_cross_control_conflicts!(
                verified.select { |existing| existing.is_a?(Hash) && existing.keys.sort == PAYLOAD_KEYS },
                validated
              )
            end
          rescue ContractError => e
            raise e if %w[
              control_store_lineage_invalid control_store_subject_conflict
              control_store_task_conflict control_store_unpinned
            ].include?(e.code)

            raise lineage_invalid("#{e.code}: #{e.message}", index)
          end
          verified << validated
        end
        verified
      end


      # The ancestor-prefix policy snapshot for one persisted transaction:
      # walk the accepted lineage from the transaction-owned policy pin
      # (checkpoint project_policy_revision_ref) back to genesis, so the
      # prefix tip IS the frozen revision and the transaction is never
      # reinterpreted by a later rotation.
      def historical_policy_prefix(policy, tx)
        accepted = policy.fetch("accepted")
        assertions = policy.fetch("accepted_assertions")
        pin = tx_policy_pin(tx)
        raise lineage_invalid("transaction has no frozen policy pin") unless pin
        return [accepted, assertions] if accepted.last &&
                                          accepted.last["policy_revision_id"] == pin["policy_revision_id"] &&
                                          accepted.last["content_digest"] == pin["content_digest"]

        by_id = accepted.to_h { |candidate| [candidate["policy_revision_id"], candidate] }
        chain = []
        cursor = by_id[pin["policy_revision_id"]]
        raise lineage_invalid("transaction pins a policy the store never accepted") unless cursor
        while cursor
          chain << cursor
          parent = cursor["parent_policy_revision_id"]
          cursor = parent && by_id[parent]
        end
        prefix = chain.reverse
        prefix_assertions = assertions.select do |assertion|
          prefix.any? { |candidate| candidate["authorization_source_ref"] == assertion["assertion_id"] }
        end
        [prefix, prefix_assertions]
      end

      def tx_policy_pin(tx)
        return nil unless tx.is_a?(Hash)

        checkpoint =
          case tx.keys.sort
          when PAYLOAD_KEYS, CHECKPOINT_PAYLOAD_KEYS, SESSION_CHECKPOINT_PAYLOAD_KEYS, TERMINAL_PAYLOAD_KEYS
            tx["checkpoint"]
          when EXECUTION_PAYLOAD_KEYS
            tx["dispatch_checkpoint"]
          end
        checkpoint && checkpoint["project_policy_revision_ref"]
      end
      # Dispatches on the closed transaction shape: the control-genesis
      # payload or the successor-checkpoint payload. Any other shape is
      # malformed persisted data and fails closed.
      def validate_transaction!(tx, policy:, pinned_policies:, accepted_assertions: [], marker:,
                                authority_verifier:, runtime_identity_verifier:,
                                lifecycle_verifier:, seen_event_ids:, all_txs: [])
        shape = tx.is_a?(Hash) ? tx.keys.sort : nil
        case shape
        when PAYLOAD_KEYS
          validate_genesis_transaction!(tx, policy: policy, pinned_policies: pinned_policies,
            marker: marker, authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids)
        when CHECKPOINT_PAYLOAD_KEYS
          if tx.dig("checkpoint", "reconcile_trigger", "event") == "task_revision_change"
            validate_task_revision_change_transaction!(tx, policy: policy,
              pinned_policies: pinned_policies, accepted_assertions: accepted_assertions,
              marker: marker, authority_verifier: authority_verifier,
              runtime_identity_verifier: runtime_identity_verifier,
              lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
              all_txs: all_txs)
          else
            validate_checkpoint_transaction!(tx, policy: policy, pinned_policies: pinned_policies,
              accepted_assertions: accepted_assertions,
              marker: marker, authority_verifier: authority_verifier,
              runtime_identity_verifier: runtime_identity_verifier,
              lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
              all_txs: all_txs)
          end
        when SESSION_CHECKPOINT_PAYLOAD_KEYS
          validate_checkpoint_transaction!(tx, policy: policy, pinned_policies: pinned_policies,
            accepted_assertions: accepted_assertions,
            marker: marker, authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
            all_txs: all_txs)
        when TERMINAL_PAYLOAD_KEYS
          validate_terminal_transaction!(tx, policy: policy,
            pinned_policies: pinned_policies, accepted_assertions: accepted_assertions,
            marker: marker, authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
            all_txs: all_txs)
        when EXECUTION_PAYLOAD_KEYS
          validate_execution_transaction!(tx, policy: policy,
            pinned_policies: pinned_policies, accepted_assertions: accepted_assertions,
            marker: marker, authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
            all_txs: all_txs)
        else
          raise lineage_invalid("transaction carries malformed component types or unknown fields")
        end
      end

      # Full final validation of one control-genesis transaction:
      # schemas/digests/epoch/project, control identity and cross-record
      # refs, the pinned policy authority, and the runtime-subject binding.
      def validate_genesis_transaction!(tx, policy:, pinned_policies:, marker:,
                                        authority_verifier:, runtime_identity_verifier:,
                                        lifecycle_verifier:, seen_event_ids:)
        unless tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS
          raise genesis_invalid("transaction carries fields outside the closed payload shape")
        end
        registry = tx.fetch("registry")
        session = tx.fetch("session")
        checkpoint = tx.fetch("checkpoint")
        agent = tx.fetch("agent")
        assertion = tx.fetch("assertion")
        control_id = registry["lead_control_id"]

        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("lead_control_registry", registry)
          validator.validate_document!("lead_session", session)
          validator.validate_document!("lead_checkpoint", checkpoint)
          validator.validate_document!("agent_instance", agent)
          validator.validate_document!("authority_assertion", assertion)
        rescue ValidationFailure
          raise genesis_invalid("records violate their contracts")
        end
        %w[registry checkpoint].each do |kind|
          record = tx.fetch(kind)
          unless CanonicalJSON.content_digest(record) == record["content_digest"]
            raise genesis_invalid("#{kind} content_digest is not self-consistent")
          end
        end

        project_id = policy ? policy["project_id"] : marker["project_id"]
        unless [registry, session, checkpoint, agent, assertion].all? do |record|
                 record["project_id"] == project_id
               end
          raise genesis_invalid("records do not all carry the marker project identity")
        end
        unless [session, checkpoint].all? { |record| record["lead_control_id"] == control_id }
          raise genesis_invalid("session and checkpoint must belong to the registry control")
        end
        register_id!(seen_event_ids, "lead_checkpoint", checkpoint.fetch("lead_checkpoint_id"))
        register_id!(seen_event_ids, "authority_assertion", assertion.fetch("assertion_id"))

        unless checkpoint["is_genesis"] == true && checkpoint["predecessor_lead_checkpoint_ref"].nil?
          raise genesis_invalid("control genesis requires a parentless genesis LeadCheckpoint")
        end
        unless registry["genesis_checkpoint_ref"] == {
          "lead_checkpoint_id" => checkpoint["lead_checkpoint_id"],
          "content_digest" => checkpoint["content_digest"]
        }
          raise genesis_invalid("registry genesis ref does not exact-pin the genesis checkpoint")
        end
        unless checkpoint["lead_agent_instance_ref"] == { "agent_instance_id" => agent["agent_instance_id"] }
          raise genesis_invalid("checkpoint agent ref does not exact-pin the AgentInstance")
        end
        unless checkpoint["active_lead_session_ref"] == {
          "lead_session_id" => session["lead_session_id"],
          "session_generation" => session["session_generation"]
        }
          raise genesis_invalid("checkpoint session ref does not exact-pin the LeadSession")
        end
        unless session["agent_instance_id"] == agent["agent_instance_id"]
          raise genesis_invalid("LeadSession does not bind the AgentInstance")
        end

        # The checkpoint pins the policy active at commit time. The writer
        # requires that pin to BE the currently resolved active policy; the
        # reader requires it to be an ACCEPTED revision of the store.
        pinned_ref = checkpoint["project_policy_revision_ref"]
        if policy
          unless pinned_ref == {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => policy["content_digest"]
          }
            raise genesis_invalid(
              "checkpoint does not pin the currently active policy (stale authority after rotation)"
            )
          end
          pinned_policy = policy
        else
          pinned_policy = pinned_policies.find do |candidate|
            candidate["policy_revision_id"] == pinned_ref["policy_revision_id"] &&
              candidate["content_digest"] == pinned_ref["content_digest"]
          end
          unless pinned_policy
            raise genesis_invalid("checkpoint pins a policy revision the store never accepted")
          end
        end

        # Writer authority: provider-verified control.genesis assertion
        # granted by the exact pinned policy, scoped to this control.
        begin
          authority_verifier.verify!(assertion)
        rescue ContractError => error
          raise genesis_invalid(
            "control.genesis assertion was not provider-verified: #{error.code}"
          )
        end
        grant = unique_policy_grant(pinned_policy, GENESIS_ACTION)
        provenance = registry["writer_authority_provenance"]
        checkpoint_provenance = checkpoint["writer_authority_provenance"]
        [provenance, checkpoint_provenance].each_with_index do |entry, index|
          ref = entry && entry["assertion_ref"]
          valid = entry.is_a?(Hash) &&
                  entry["action"] == GENESIS_ACTION &&
                  entry["policy_revision_ref"] == {
                    "policy_revision_id" => pinned_policy["policy_revision_id"],
                    "content_digest" => pinned_policy["content_digest"]
                  } &&
                  assertion["assertion_id"] == ref["assertion_id"] &&
                  assertion["assertion_digest"] == ref["assertion_digest"] &&
                  assertion["authority_scope_ref"] == control_id &&
                  %w[user control_plane].include?(assertion["issuer_kind"]) &&
                  grant.is_a?(Hash) &&
                  Array(assertion["grants"]).include?(grant["required_external_grant"])
          raise genesis_invalid(
            "writer authority provenance #{index.zero? ? 'registry' : 'checkpoint'} is not exact-bound"
          ) unless valid
        end

        # Lifecycle events: provider-verified event chains with exact
        # digest linkage, strict chronology, and a GLOBAL create-only event
        # id set shared across every Agent/LeadSession stream and every
        # control transaction (mirroring the Validator's
        # validate_event_chain + LifecycleVerifier semantics) before any
        # cross-stream check.
        verify_event_stream!(Array(session["lifecycle_events"]), stream: "lead_session",
          project_id: project_id, lifecycle_verifier: lifecycle_verifier,
          seen_event_ids: seen_event_ids)
        verify_event_stream!(Array(agent["lifecycle_events"]), stream: "agent",
          project_id: project_id, lifecycle_verifier: lifecycle_verifier,
          seen_event_ids: seen_event_ids)

        # Runtime identity: the AgentInstance is provider-verified and the
        # session/checkpoint subject pins exact-bind it.
        begin
          runtime_identity_verifier.verify!(agent)
        rescue ContractError => error
          raise genesis_invalid(
            "runtime identity was not provider-verified: #{error.code}"
          )
        end
        identity = agent.fetch("runtime_identity")
        unless session["lead_runtime_subject_ref"] == identity["runtime_subject_id"] &&
               session["lead_runtime_subject_assertion_digest"] ==
                 control_assertion_digest(identity["verification_receipt_ref"])
          raise genesis_invalid("LeadSession subject pins do not exact-bind the AgentInstance runtime identity")
        end
        unless checkpoint["lead_runtime_subject_ref"] == session["lead_runtime_subject_ref"] &&
               checkpoint["lead_runtime_subject_assertion_digest"] ==
                 session["lead_runtime_subject_assertion_digest"]
          raise genesis_invalid("checkpoint subject pins must equal the LeadSession subject pins")
        end
        unless session["logical_lead_id"] ==
               checkpoint.dig("logical_lead_refs", 0, "logical_lead_id")
          raise genesis_invalid("session and checkpoint logical-lead identities must agree")
        end

        validate_session_lifecycle!(session, agent)

        # The genesis checkpoint exact-pins the immutable registry claim:
        # its task queue is exactly the registry's owned task refs.
        unless canonical_equal?(
          checkpoint["task_queue"],
          registry["owned_task_refs"]
        )
          raise genesis_invalid("genesis task queue must exact-equal the registry owned task refs")
        end
        tx
      end

      # Full final validation of one successor LeadCheckpoint transaction
      # (selection/dispatch): exact prior-checkpoint extension, the
      # control's genesis session/agent/subject pins, owned task queue,
      # selection/dispatch closure, and a provider-verified
      # control.checkpoint writer assertion granted by the pinned policy.
      def validate_checkpoint_transaction!(tx, policy:, pinned_policies:, accepted_assertions:, marker:,
                                           authority_verifier:, runtime_identity_verifier:,
                                           lifecycle_verifier:, seen_event_ids:, all_txs:,
                                           allow_attempt_ref: false, skip_assembled: false,
                                           allow_dispatch: false)
        checkpoint = tx.fetch("checkpoint")
        assertion = tx.fetch("assertion")
        control_id = checkpoint["lead_control_id"]
        project_id = policy ? policy["project_id"] : marker["project_id"]

        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("lead_checkpoint", checkpoint)
          validator.validate_document!("authority_assertion", assertion)
        rescue ValidationFailure, ContractError
          raise checkpoint_invalid("records violate their contracts")
        end
        # A dispatch decision commits ONLY inside the atomic execution or
        # terminal composite transaction that carries the AttemptCreated and
        # its immediate observation; a standalone dispatch-authorizing
        # checkpoint is the exact half-state Inc6b closed and never commits.
        if checkpoint.dig("lead_decision", "action") == "dispatch" && !allow_dispatch
          raise checkpoint_invalid(
            "dispatch decisions are owned by the atomic execution/terminal composite transaction"
          )
        end
        unless CanonicalJSON.content_digest(checkpoint) == checkpoint["content_digest"]
          raise checkpoint_invalid("checkpoint content_digest is not self-consistent")
        end
        unless checkpoint["project_id"] == project_id && assertion["project_id"] == project_id
          raise checkpoint_invalid("records do not all carry the marker project identity")
        end
        register_id!(seen_event_ids, "lead_checkpoint", checkpoint.fetch("lead_checkpoint_id"), :checkpoint)
        register_id!(seen_event_ids, "authority_assertion", assertion.fetch("assertion_id"), :checkpoint)
        if checkpoint["is_genesis"] == true
          raise checkpoint_invalid("successor checkpoint transaction must be non-genesis")
        end

        genesis_tx = all_txs.reverse.find do |tx|
          tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS &&
            tx.fetch("registry").fetch("lead_control_id") == control_id
        end
        raise checkpoint_invalid("checkpoint must belong to an accepted control") unless genesis_tx

        registry = genesis_tx.fetch("registry")
        agent = genesis_tx.fetch("agent")
        genesis_checkpoint = genesis_tx.fetch("checkpoint")
        prior = all_txs.select do |candidate|
          checkpoint_entries(candidate).any? do |entry|
            entry.fetch("checkpoint").fetch("lead_control_id") == control_id
          end
        end
        prior_entries = prior.flat_map { |candidate| checkpoint_entries(candidate) }.select do |entry|
          entry.fetch("checkpoint").fetch("lead_control_id") == control_id
        end
        latest = prior_entries.empty? ? genesis_checkpoint : prior_entries.last.fetch("checkpoint")
        predecessor = checkpoint["predecessor_lead_checkpoint_ref"]
        unless predecessor == {
          "lead_checkpoint_id" => latest["lead_checkpoint_id"],
          "content_digest" => latest["content_digest"]
        }
          raise checkpoint_invalid(
            "checkpoint must extend the exact prior accepted checkpoint of the same control"
          )
        end
        current_session = genesis_tx.fetch("session")
        prior.each do |tx|
          if tx.keys.sort == SESSION_CHECKPOINT_PAYLOAD_KEYS
            current_session = tx.fetch("session")
            agent = tx.fetch("agent")
          end
        end
        session_form = tx.keys.sort == SESSION_CHECKPOINT_PAYLOAD_KEYS
        if session_form
          validate_session_transition!(tx, current_session, agent, project_id,
            authority_verifier, runtime_identity_verifier, lifecycle_verifier, seen_event_ids)
          session = tx.fetch("session")
          agent = tx.fetch("agent")
        else
          session = current_session
        end
        unless checkpoint["active_lead_session_ref"] == {
          "lead_session_id" => session["lead_session_id"],
          "session_generation" => session["session_generation"]
        }
          raise checkpoint_invalid("checkpoint must pin the control's active LeadSession generation")
        end
        unless checkpoint["lead_agent_instance_ref"] == { "agent_instance_id" => agent["agent_instance_id"] }
          raise checkpoint_invalid("checkpoint Lead AgentInstance must equal the bound session AgentInstance")
        end
        unless checkpoint["lead_runtime_subject_ref"] == session["lead_runtime_subject_ref"] &&
               checkpoint["lead_runtime_subject_assertion_digest"] ==
                 session["lead_runtime_subject_assertion_digest"]
          raise checkpoint_invalid("checkpoint subject pins must equal the bound LeadSession subject pins")
        end
        # The checkpoint resolves against the TaskStore's accepted
        # task-definition facts (LogicalLead/Task/WorkUnit), never against
        # the checkpoint's own text.
        task_facts = resolve_task_facts!(checkpoint, registry, authority_verifier)
        unless checkpoint["logical_lead_refs"] == [task_facts.fetch("logical_lead_ref")]
          raise checkpoint_invalid(
            "checkpoint logical lead refs must exact-match the accepted TaskStore LogicalLead"
          )
        end

        pinned_ref = checkpoint["project_policy_revision_ref"]
        if policy
          unless pinned_ref == {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => policy["content_digest"]
          }
            raise checkpoint_invalid(
              "checkpoint does not pin the currently active policy (stale authority after rotation)"
            )
          end
          pinned_policy = policy
        else
          pinned_policy = pinned_policies.find do |candidate|
            candidate["policy_revision_id"] == pinned_ref["policy_revision_id"] &&
              candidate["content_digest"] == pinned_ref["content_digest"]
          end
          raise checkpoint_invalid("checkpoint pins a policy the store never accepted") unless pinned_policy
        end

        # The queue derives from the accepted checkpoint lineage (the
        # unique current tip), never from the immutable genesis registry
        # claim: a TaskRevision activation advances the queue, and any
        # regression or fork fails closed (transfers deferred).
        current_queue = latest["task_queue"]
        unless canonical_equal?(checkpoint["task_queue"], current_queue)
          raise checkpoint_invalid(
            "checkpoint task queue must exact-match the current lineage tip queue"
          )
        end
        active_ref = checkpoint["active_task_ref"]
        if active_ref && active_ref != task_facts.fetch("task_ref")
          raise checkpoint_invalid("active task ref must exact-match the accepted TaskStore TaskRevision")
        end
        if checkpoint.dig("lead_decision", "action") == "dispatch"
          selected = checkpoint["selected_work_unit_ref"]
          unless active_ref && selected.is_a?(Hash) &&
                 task_facts.fetch("work_unit_refs").include?(selected)
            raise checkpoint_invalid(
              "dispatch requires the active task and a selected WorkUnit of the accepted TaskStore graph"
            )
          end
          resolved_unit = task_facts.fetch("work_units").find do |unit|
            unit["work_unit_id"] == selected["work_unit_id"] &&
              unit["content_digest"] == selected["content_digest"]
          end
          unless resolved_unit && resolved_unit["task_revision_id"] == active_ref["task_revision_id"]
            raise checkpoint_invalid(
              "selected WorkUnit must resolve under the active TaskRevision"
            )
          end
        end
        unless allow_attempt_ref || checkpoint["current_or_terminal_attempt_ref"].nil?
          raise checkpoint_invalid("attempt refs are deferred; no attempt pin is allowed")
        end

        begin
          authority_verifier.verify!(assertion)
        rescue ContractError => error
          raise checkpoint_invalid("control.checkpoint assertion was not provider-verified: #{error.code}")
        end
        provenance = checkpoint["writer_authority_provenance"]
        ref = provenance && provenance["assertion_ref"]
        grant = unique_policy_grant(pinned_policy, CHECKPOINT_ACTION)
        valid = provenance.is_a?(Hash) &&
                provenance["action"] == CHECKPOINT_ACTION &&
                provenance["policy_revision_ref"] == {
                  "policy_revision_id" => pinned_policy["policy_revision_id"],
                  "content_digest" => pinned_policy["content_digest"]
                } &&
                assertion["assertion_id"] == ref["assertion_id"] &&
                assertion["assertion_digest"] == ref["assertion_digest"] &&
                assertion["authority_scope_ref"] == control_id &&
                %w[user control_plane].include?(assertion["issuer_kind"]) &&
                grant.is_a?(Hash) &&
                Array(assertion["grants"]).include?(grant["required_external_grant"])
        raise checkpoint_invalid("checkpoint writer authority is not exact-bound") unless valid

        # Semantic closure: the complete relevant LeadControl/Validator
        # invariants run over the assembled provider-verified policy/task/
        # control snapshot (dispatch basis, budget/plan digests, decision,
        # lineage, queue, selection, session continuity), so schema-valid
        # semantic counterexamples are never accepted.
        validate_assembled_snapshot!(
          marker, pinned_policies, accepted_assertions, genesis_tx, prior, tx,
          task_facts.fetch("payload"), authority_verifier,
          runtime_identity_verifier, lifecycle_verifier
        ) unless skip_assembled
        tx
      end

      # Full final validation of one TaskRevision activation transaction:
      # an exact task_revision_change checkpoint that transitions the owned
      # task from the exact accepted parent revision (the current queue
      # revision) to the exact accepted child revision of the SAME task.
      # The child must be the immediate successor (no skipped revisions),
      # exact ID+digest pinned by the checkpoint queue and active task ref,
      # must pin the currently active policy, and the complete assembled
      # snapshot (parent + child task facts) runs through the public
      # Validator. Activation is rejected while any active/nonterminal
      # attempt exists on the control; the registry stays the immutable
      # genesis claim and the queue/task facts derive from the accepted
      # checkpoint lineage.
      def validate_task_revision_change_transaction!(tx, policy:, pinned_policies:, accepted_assertions:, marker:,
                                                     authority_verifier:, runtime_identity_verifier:,
                                                     lifecycle_verifier:, seen_event_ids:, all_txs:)
        checkpoint = tx.fetch("checkpoint")
        assertion = tx.fetch("assertion")
        control_id = checkpoint["lead_control_id"]
        project_id = policy ? policy["project_id"] : marker["project_id"]
        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("lead_checkpoint", checkpoint)
          validator.validate_document!("authority_assertion", assertion)
        rescue ValidationFailure, ContractError
          raise activation_invalid("records violate their contracts")
        end
        unless CanonicalJSON.content_digest(checkpoint) == checkpoint["content_digest"]
          raise activation_invalid("activation checkpoint content_digest is not self-consistent")
        end
        unless checkpoint["project_id"] == project_id && assertion["project_id"] == project_id
          raise activation_invalid("records do not all carry the marker project identity")
        end
        register_id!(seen_event_ids, "lead_checkpoint", checkpoint.fetch("lead_checkpoint_id"), :activation)
        register_id!(seen_event_ids, "authority_assertion", assertion.fetch("assertion_id"), :activation)
        if checkpoint["is_genesis"] == true
          raise activation_invalid("activation checkpoint must be non-genesis")
        end
        genesis_tx = all_txs.reverse.find do |candidate|
          candidate.is_a?(Hash) && candidate.keys.sort == PAYLOAD_KEYS &&
            candidate.fetch("registry").fetch("lead_control_id") == control_id
        end
        raise activation_invalid("activation must belong to an accepted control") unless genesis_tx
        registry = genesis_tx.fetch("registry")
        prior = all_txs.select do |candidate|
          checkpoint_entries(candidate).any? do |entry|
            entry.fetch("checkpoint").fetch("lead_control_id") == control_id
          end
        end
        prior_entries = prior.flat_map { |candidate| checkpoint_entries(candidate) }.select do |entry|
          entry.fetch("checkpoint").fetch("lead_control_id") == control_id
        end
        # The unique current tip includes the genesis checkpoint when no
        # successor exists: a fresh r1 control can directly activate an
        # accepted child revision.
        tip_entries = [{ "checkpoint" => genesis_tx.fetch("checkpoint"),
                         "assertion" => genesis_tx.fetch("assertion") }] + prior_entries
        tip = tip_entries.last
        tip_ref = {
          "lead_checkpoint_id" => tip.fetch("checkpoint").fetch("lead_checkpoint_id"),
          "content_digest" => tip.fetch("checkpoint").fetch("content_digest")
        }
        unless checkpoint["predecessor_lead_checkpoint_ref"] == tip_ref
          raise activation_invalid(
            "activation must exact-extend the unique current control tip"
          )
        end
        tip_checkpoint = tip.fetch("checkpoint")
        session = genesis_tx.fetch("session")
        agent = genesis_tx.fetch("agent")
        prior.each do |candidate|
          if candidate.keys.sort == SESSION_CHECKPOINT_PAYLOAD_KEYS
            session = candidate.fetch("session")
            agent = candidate.fetch("agent")
          end
        end
        unless checkpoint["active_lead_session_ref"] == {
                 "lead_session_id" => session["lead_session_id"],
                 "session_generation" => session["session_generation"]
               } &&
               checkpoint["lead_agent_instance_ref"] == { "agent_instance_id" => agent["agent_instance_id"] } &&
               checkpoint["lead_runtime_subject_ref"] == session["lead_runtime_subject_ref"] &&
               checkpoint["lead_runtime_subject_assertion_digest"] ==
                 session["lead_runtime_subject_assertion_digest"]
          raise activation_invalid("activation checkpoint pins must equal the bound LeadSession/AgentInstance")
        end
        # No active or nonterminal attempt may exist on the control: the
        # latest attempt representation per attempt id decides (a terminal
        # reconciliation supersedes the composite payload).
        latest = latest_attempt_map(all_txs)
        if latest.values.any? do |entry|
             entry.fetch("attempt")["lead_control_id"] == control_id &&
               !terminal_attempt?(entry.fetch("attempt"))
           end
          raise activation_invalid(
            "activation requires no active or nonterminal attempt on the control"
          )
        end
        pinned_ref = checkpoint["project_policy_revision_ref"]
        if policy
          unless pinned_ref == {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => policy["content_digest"]
          }
            raise activation_invalid(
              "activation does not pin the currently active policy (stale authority after rotation)"
            )
          end
          pinned_policy = policy
        else
          pinned_policy = pinned_policies.find do |candidate|
            candidate["policy_revision_id"] == pinned_ref["policy_revision_id"] &&
              candidate["content_digest"] == pinned_ref["content_digest"]
          end
          raise activation_invalid("activation pins a policy the store never accepted") unless pinned_policy
        end
        begin
          authority_verifier.verify!(assertion)
        rescue ContractError => error
          raise activation_invalid("activation assertion was not provider-verified: #{error.code}")
        end
        provenance = checkpoint["writer_authority_provenance"]
        ref = provenance && provenance["assertion_ref"]
        grant = unique_policy_grant(pinned_policy, CHECKPOINT_ACTION)
        valid = provenance.is_a?(Hash) &&
                provenance["action"] == CHECKPOINT_ACTION &&
                provenance["policy_revision_ref"] == {
                  "policy_revision_id" => pinned_policy["policy_revision_id"],
                  "content_digest" => pinned_policy["content_digest"]
                } &&
                assertion["assertion_id"] == ref["assertion_id"] &&
                assertion["assertion_digest"] == ref["assertion_digest"] &&
                assertion["authority_scope_ref"] == control_id &&
                %w[user control_plane].include?(assertion["issuer_kind"]) &&
                grant.is_a?(Hash) &&
                Array(assertion["grants"]).include?(grant["required_external_grant"])
        raise activation_invalid("activation writer authority is not exact-bound") unless valid

        # Parent facts: the control's current queue revision (the tip's
        # derived task facts, never the TaskStore proposal tip).
        parent_facts = resolve_task_facts!(tip_checkpoint, registry, authority_verifier)
        parent = parent_facts.fetch("payload").fetch("task")
        queue = Array(checkpoint["task_queue"])
        unless queue.length == 1
          raise activation_invalid("activation task queue must carry exactly one owned task")
        end
        queue_ref = queue.first
        child_store = TaskStore.new(active_root: @active_root)
        child_resolved = begin
          child_store.resolve(
            task_id: parent.fetch("task_id"),
            task_revision_id: queue_ref.fetch("task_revision_id"),
            authority_verifier: authority_verifier
          )
        rescue ContractError => error
          raise activation_invalid("child TaskRevision does not resolve: #{error.code}")
        end
        child_resolved = enriched_task_payload(
          child_resolved, { "task_id" => parent.fetch("task_id") }, child_store, authority_verifier
        )
        child = child_resolved.fetch("task")
        child_ref = {
          "task_id" => child.fetch("task_id"),
          "task_revision_id" => child.fetch("task_revision_id"),
          "content_digest" => child.fetch("content_digest")
        }
        unless queue_ref == child_ref && checkpoint["active_task_ref"] == child_ref
          raise activation_invalid(
            "activation queue and active task ref must exact-pin the accepted child TaskRevision"
          )
        end
        unless child["task_id"] == parent["task_id"] &&
               child["parent_task_revision_id"] == parent["task_revision_id"] &&
               child["revision_number"] == parent["revision_number"] + 1
          raise activation_invalid(
            "activation must transition one owned task to its exact immediate child revision"
          )
        end
        unless child["project_policy_revision_ref"] == checkpoint["project_policy_revision_ref"]
          raise activation_invalid("child TaskRevision must pin the checkpoint's active policy revision")
        end
        lead_ref = {
          "logical_lead_id" => child_resolved.fetch("logical_lead").fetch("logical_lead_id"),
          "content_digest" => child_resolved.fetch("logical_lead").fetch("content_digest")
        }
        unless checkpoint["logical_lead_refs"] == [lead_ref]
          raise activation_invalid(
            "activation logical lead refs must exact-match the accepted task LogicalLead"
          )
        end
        unless checkpoint.dig("lead_decision", "action") == "continue"
          raise activation_invalid("activation decision must be the deterministic continue outcome")
        end
        unless checkpoint.dig("next_trigger", "event") == "successor_before"
          raise activation_invalid("activation must await the successor boundary")
        end
        # Full semantic closure over parent + child task facts (the child
        # resolve carries the complete revision histories): queue
        # progression, selection, decisions, lineage, and writer authority.
        validate_assembled_snapshot!(
          marker, pinned_policies, accepted_assertions, genesis_tx, prior, tx,
          child_resolved, authority_verifier,
          runtime_identity_verifier, lifecycle_verifier
        )
        tx
      rescue ContractError => error
        raise error if error.code == "control_store_activation_invalid"

        raise activation_invalid("#{error.code}: #{error.message}")
      end

      # Shared closure for the successor binding carried by the atomic
      # execution composite AND the terminal reconciliation (where the
      # terminal checkpoint is the exact authorizing dispatch checkpoint):
      # content-addressed assigned rule (current canonical bytes for a new
      # writer), provider-verified worker, exactly one AttemptCreated with
      # receipt, byte-exact dispatch/observation pins, and byte-exact
      # proposal closure. The dispatch checkpoint never commits without its
      # AttemptCreated and immediate observation in the SAME transaction.
      def validate_successor_composite!(attempt:, worker:, rule:, dispatch:, observation:,
                                        dispatch_assertion:, observation_assertion:,
                                        policy:, pinned_policies:, accepted_assertions:, marker:,
                                        authority_verifier:, runtime_identity_verifier:,
                                        lifecycle_verifier:, seen_event_ids:, all_txs:,
                                        failure: :dispatch, dispatch_pins_nothing: true,
                                        chain_to: nil)
        invalid = failure == :terminal ? method(:terminal_invalid) : method(:dispatch_invalid)
        unless [attempt, worker, rule, dispatch, observation,
                dispatch_assertion, observation_assertion].all? { |record| record.is_a?(Hash) }
          raise invalid.call("successor composite components must all be canonical objects")
        end
        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("work_unit_attempt", attempt)
          validator.validate_document!("agent_instance", worker)
          RuleResolution.validate!(rule, project_root: File.dirname(@active_root))
          if policy
            current_identity = RuleResolution.canonical_identity(rule.fetch("identity"),
              project_root: File.dirname(@active_root), verify_files: true)
            unless canonical_equal?(current_identity, rule.fetch("identity"))
              raise invalid.call("new assigned rules do not match current project rule bytes")
            end
          end
        rescue ValidationFailure, ContractError => error
          raise invalid.call("successor composite components violate their contracts: #{error.message}")
        end
        attempt_id = attempt["attempt_id"]
        register_id!(seen_event_ids, "work_unit_attempt", attempt_id, failure)
        register_id!(seen_event_ids, "rule_resolution", rule.fetch("resolution_id"), failure)
        register_id!(seen_event_ids, "agent_instance", worker.fetch("agent_instance_id"), failure)
        if chain_to
          # RuntimeLifecycle: a non-empty predecessor must be the exact same
          # WorkUnit, while each new WorkUnit may start a first Attempt with
          # predecessor nil. The terminal composite therefore accepts a
          # same-unit exact chain (a) or a fresh different-WorkUnit first
          # Attempt (b); the assembled whole-snapshot Validator rejects a
          # second nil-first on the same unit.
          ref = attempt["predecessor_work_unit_attempt_ref"]
          unless ref.nil? || ref == chain_to
            raise invalid.call(
              "successor Attempt must exact-chain to the terminated attempt or start fresh"
            )
          end
        elsif attempt["predecessor_work_unit_attempt_ref"]
          raise invalid.call("first Attempt must carry no predecessor attempt ref")
        end
        events = Array(attempt["events"])
        unless events.length == 1 && events.first["event_type"] == "AttemptCreated" &&
               events.first["status"] == "active" &&
               events.first["started_at"] == events.first["recorded_at"]
          raise invalid.call("creation requires exactly one active AttemptCreated event")
        end
        event = events.first
        register_id!(seen_event_ids, "lifecycle event", event.fetch("event_id"), failure)
        begin
          lifecycle_verifier.verify!(event, project_id: marker.fetch("project_id"))
          verify_event_stream!(Array(worker["lifecycle_events"]), stream: "agent",
            project_id: marker.fetch("project_id"), lifecycle_verifier: lifecycle_verifier,
            seen_event_ids: seen_event_ids)
          runtime_identity_verifier.verify!(worker)
        rescue ContractError => error
          raise invalid.call("worker identity or AttemptCreated receipt was not provider-verified: #{error.code}")
        end

        control_id = dispatch["lead_control_id"]
        unless observation["lead_control_id"] == control_id && attempt["lead_control_id"] == control_id
          raise invalid.call("dispatch, observation, and attempt must belong to one control")
        end
        dispatch_tx = { "assertion" => dispatch_assertion, "checkpoint" => dispatch }
        observation_tx = { "assertion" => observation_assertion, "checkpoint" => observation }
        validate_checkpoint_transaction!(dispatch_tx, policy: policy,
          pinned_policies: pinned_policies, accepted_assertions: accepted_assertions,
          marker: marker, authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
          all_txs: all_txs, allow_attempt_ref: !dispatch_pins_nothing,
          skip_assembled: true, allow_dispatch: true)
        validate_checkpoint_transaction!(observation_tx, policy: policy,
          pinned_policies: pinned_policies, accepted_assertions: accepted_assertions,
          marker: marker, authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
          all_txs: all_txs + [dispatch_tx], allow_attempt_ref: true,
          skip_assembled: true)

        created_ref = {
          "attempt_id" => attempt_id,
          "event_id" => event.fetch("event_id"),
          "event_digest" => event.fetch("event_digest")
        }
        unless attempt["dispatch_lead_checkpoint_ref"] == {
                 "lead_checkpoint_id" => dispatch["lead_checkpoint_id"],
                 "content_digest" => dispatch["content_digest"]
               } &&
               observation["predecessor_lead_checkpoint_ref"] == attempt["dispatch_lead_checkpoint_ref"] &&
               observation["current_or_terminal_attempt_ref"] == created_ref &&
               observation.dig("reconcile_trigger", "event") == "attempt_created" &&
               dispatch.dig("lead_decision", "action") == "dispatch" &&
               (!dispatch_pins_nothing || dispatch["current_or_terminal_attempt_ref"].nil?)
          raise invalid.call("dispatch/AttemptCreated/observation refs are not exact-bound")
        end

        identity = rule.fetch("identity")
        assignment = event.fetch("assignment")
        exact_identity = {
          "project_id" => attempt["project_id"],
          "task_id" => attempt["task_id"],
          "task_revision_id" => attempt["task_revision_id"],
          "work_unit_id" => attempt["work_unit_id"],
          "attempt_id" => attempt_id,
          "agent_instance_id" => assignment["agent_instance_id"],
          "context_generation" => assignment["context_generation"],
          "resolved_role" => assignment["resolved_role"]
        }
        unless exact_identity.all? { |field, value| identity[field] == value } &&
               assignment["agent_instance_id"] == worker["agent_instance_id"] &&
               assignment["assigned_rule_resolution_id"] == rule["resolution_id"]
          raise invalid.call("assigned rule identity and AttemptCreated assignment do not exact-match")
        end
        # The dispatch-time basis is frozen AT the dispatch: exactly one
        # rule_resolution proposal exact-pinning the assigned artifact and
        # exactly one change_thesis proposal exact-pinning the assigned
        # thesis. A proposal whose id/digest does not resolve to the
        # transaction's own artifact/thesis would otherwise pass the
        # assembled Validator (unresolvable proposals skip basis matching),
        # so the store pins them byte-exact here.
        proposals = Orbit::V2::ProjectionPrimitives.checkpoint_exact_refs(dispatch)
        rule_proposals = proposals.select { |ref| ref.is_a?(Hash) && ref["kind"] == "rule_resolution" }
        thesis_proposals = proposals.select do |ref|
          ref.is_a?(Hash) && ref["kind"] == "change_thesis" && ref["event_id"].nil?
        end
        thesis_ref = assignment.fetch("change_thesis_ref")
        unless rule_proposals.length == 1 &&
               rule_proposals.first == {
                 "kind" => "rule_resolution",
                 "id" => rule.fetch("resolution_id"),
                 "digest" => rule.fetch("identity_sha256")
               } &&
               thesis_proposals.length == 1 &&
               thesis_proposals.first == {
                 "kind" => "change_thesis",
                 "id" => thesis_ref.fetch("change_thesis_id"),
                 "digest" => thesis_ref.fetch("content_digest")
               }
          raise invalid.call(
            "dispatch must propose exactly the assigned RuleResolution artifact and ChangeThesis"
          )
        end
        [control_id, event, attempt_id]
      end

      # Full final validation of one atomic execution composite: the
      # content-addressed assigned rule, the authorizing dispatch
      # checkpoint + assertion, the worker AgentInstance, one active
      # AttemptCreated, and the required immediate observation checkpoint +
      # assertion — all in one closed transaction.
      def validate_execution_transaction!(tx, policy:, pinned_policies:, accepted_assertions:, marker:,
                                          authority_verifier:, runtime_identity_verifier:,
                                          lifecycle_verifier:, seen_event_ids:, all_txs:)
        unless tx.is_a?(Hash) && tx.keys.sort == EXECUTION_PAYLOAD_KEYS
          raise dispatch_invalid("transaction carries fields outside the closed execution shape")
        end
        attempt = tx.fetch("attempt")
        rule = tx.fetch("rule_resolution")
        worker = tx.fetch("worker_agent")
        dispatch = tx.fetch("dispatch_checkpoint")
        observation = tx.fetch("observation_checkpoint")
        control_id, = validate_successor_composite!(
          attempt: attempt, worker: worker, rule: rule, dispatch: dispatch,
          observation: observation,
          dispatch_assertion: tx.fetch("dispatch_assertion"),
          observation_assertion: tx.fetch("observation_assertion"),
          policy: policy, pinned_policies: pinned_policies,
          accepted_assertions: accepted_assertions, marker: marker,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
          all_txs: all_txs, failure: :dispatch)
        reject_nonterminal_conflicts!(all_txs, control_id, attempt, worker, :dispatch)

        genesis_tx = all_txs.reverse.find do |candidate|
          candidate.is_a?(Hash) && candidate.keys.sort == PAYLOAD_KEYS &&
            candidate.fetch("registry").fetch("lead_control_id") == control_id
        end
        raise dispatch_invalid("execution must belong to an accepted control") unless genesis_tx
        task_facts = resolve_task_facts!(dispatch, genesis_tx.fetch("registry"), authority_verifier)
        control_txs = all_txs.select do |candidate|
          checkpoint_entries(candidate).any? do |entry|
            entry.fetch("checkpoint").fetch("lead_control_id") == control_id
          end
        end
        validate_assembled_snapshot!(marker, pinned_policies, accepted_assertions,
          genesis_tx, control_txs, tx,
          task_facts.fetch("payload"), authority_verifier,
          runtime_identity_verifier, lifecycle_verifier)
        tx
      rescue ContractError => error
        raise error if error.code == "control_store_dispatch_invalid"

        raise dispatch_invalid("#{error.code}: #{error.message}")
      end

      # Full final validation of one terminal reconciliation transaction:
      # the accepted composite Attempt extended by exactly one
      # provider-verified terminal event (byte-identical prefix) plus the
      # full successor composite — the terminal checkpoint IS the exact
      # authorizing dispatch checkpoint, with the successor's assigned rule,
      # worker, AttemptCreated, and immediate observation checkpoint all in
      # the SAME closed transaction. The terminal checkpoint must
      # exact-extend the unique current observation tip of the terminated
      # attempt, and the successor attempt must start after the terminal
      # event (single-active continuity), so no accepted dispatch/attempt
      # half-state can exist and a later dispatch always has exactly one
      # authorizing checkpoint.
      def validate_terminal_transaction!(tx, policy:, pinned_policies:, accepted_assertions:, marker:,
                                         authority_verifier:, runtime_identity_verifier:,
                                         lifecycle_verifier:, seen_event_ids:, all_txs:)
        unless tx.is_a?(Hash) && tx.keys.sort == TERMINAL_PAYLOAD_KEYS
          raise terminal_invalid("transaction carries fields outside the closed terminal shape")
        end
        attempt = tx.fetch("attempt")
        checkpoint = tx.fetch("checkpoint")
        assertion = tx.fetch("assertion")
        successor_attempt = tx.fetch("successor_attempt")
        worker = tx.fetch("worker_agent")
        rule = tx.fetch("rule_resolution")
        observation = tx.fetch("observation_checkpoint")
        observation_assertion = tx.fetch("observation_assertion")
        unless [attempt, checkpoint, assertion, successor_attempt, worker, rule,
                observation, observation_assertion].all? { |record| record.is_a?(Hash) }
          raise terminal_invalid("terminal components must all be canonical objects")
        end
        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("work_unit_attempt", attempt)
          validator.validate_document!("lead_checkpoint", checkpoint)
          validator.validate_document!("authority_assertion", assertion)
        rescue ValidationFailure, ContractError
          raise terminal_invalid("terminal records violate their contracts")
        end
        unless CanonicalJSON.content_digest(checkpoint) == checkpoint["content_digest"]
          raise terminal_invalid("terminal checkpoint content_digest is not self-consistent")
        end
        control_id = checkpoint["lead_control_id"]
        project_id = policy ? policy["project_id"] : marker["project_id"]
        unless checkpoint["project_id"] == project_id && attempt["project_id"] == project_id &&
               assertion["project_id"] == project_id
          raise terminal_invalid("records do not all carry the marker project identity")
        end
        attempt_id = attempt["attempt_id"]
        # The accepted immutable representation of the attempt being
        # terminated: its own dispatch composite (first dispatch) or the
        # successor slot of an accepted terminal reconciliation (later
        # dispatches) — exactly one source, byte-identical prefix.
        executions = all_txs.select do |candidate|
          next false unless candidate.is_a?(Hash)

          if candidate.keys.sort == EXECUTION_PAYLOAD_KEYS
            candidate.fetch("attempt").fetch("attempt_id") == attempt_id
          elsif candidate.keys.sort == TERMINAL_PAYLOAD_KEYS
            candidate.fetch("successor_attempt").fetch("attempt_id") == attempt_id
          else
            false
          end
        end
        unless executions.length == 1
          raise terminal_invalid("terminal reconciliation requires exactly one accepted composite for the attempt")
        end
        stored = executions.first.fetch("attempt")
        stored = executions.first.fetch("successor_attempt") if executions.first.keys.sort == TERMINAL_PAYLOAD_KEYS
        stored_events = Array(stored["events"])
        events = Array(attempt["events"])
        expected_attempt = JSON.parse(CanonicalJSON.dump(stored))
        expected_attempt["events"] = events
        unless canonical_equal?(events.first(stored_events.length), stored_events) &&
               events.length == stored_events.length + 1 &&
               canonical_equal?(attempt, expected_attempt)
          raise terminal_invalid(
            "terminal attempt must equal the accepted composite attempt plus exactly one terminal event"
          )
        end
        terminal_event = events.last
        unless TERMINAL_EVENT_TYPES.include?(terminal_event["event_type"])
          raise terminal_invalid("terminal event type is not allowed by the final schema")
        end
        status = {
          "AttemptCompleted" => "completed",
          "AttemptFailed" => "failed",
          "AttemptBlocked" => "blocked",
          "AttemptCancelled" => "cancelled"
        }.fetch(terminal_event["event_type"])
        unless terminal_event["status"] == status &&
               terminal_event["previous_event_digest"] == stored_events.last["event_digest"] &&
               terminal_event["ended_at"] == terminal_event["recorded_at"]
          raise terminal_invalid("terminal event must exact-extend the accepted attempt chain")
        end
        register_id!(seen_event_ids, "lifecycle event", terminal_event.fetch("event_id"), :terminal)
        begin
          lifecycle_verifier.verify!(terminal_event, project_id: project_id)
        rescue ContractError => error
          raise terminal_invalid("terminal event was not provider-verified: #{error.code}")
        end

        genesis_tx = all_txs.reverse.find do |candidate|
          candidate.is_a?(Hash) && candidate.keys.sort == PAYLOAD_KEYS &&
            candidate.fetch("registry").fetch("lead_control_id") == control_id
        end
        raise terminal_invalid("terminal checkpoint must belong to an accepted control") unless genesis_tx
        prior = all_txs.select do |candidate|
          checkpoint_entries(candidate).any? do |entry|
            entry.fetch("checkpoint").fetch("lead_control_id") == control_id
          end
        end
        prior_entries = prior.flat_map { |candidate| checkpoint_entries(candidate) }.select do |entry|
          entry.fetch("checkpoint").fetch("lead_control_id") == control_id
        end
        tip = prior_entries.last
        tip_ref = tip && {
          "lead_checkpoint_id" => tip.fetch("checkpoint").fetch("lead_checkpoint_id"),
          "content_digest" => tip.fetch("checkpoint").fetch("content_digest")
        }
        # The terminal checkpoint must exact-extend the unique current
        # observation tip of THIS attempt: the tip pins the attempt's
        # AttemptCreated event and no checkpoint may sit between it and the
        # terminal successor.
        unless tip &&
               tip.fetch("checkpoint").dig("current_or_terminal_attempt_ref") == {
                 "attempt_id" => attempt_id,
                 "event_id" => stored_events.first.fetch("event_id"),
                 "event_digest" => stored_events.first.fetch("event_digest")
               } &&
               checkpoint["predecessor_lead_checkpoint_ref"] == tip_ref &&
               checkpoint.dig("reconcile_trigger", "event") == "attempt_terminal"
          raise terminal_invalid(
            "terminal checkpoint must exact-extend the unique current observation tip of the attempt"
          )
        end

        _control, event, = validate_successor_composite!(
          attempt: successor_attempt, worker: worker, rule: rule, dispatch: checkpoint,
          observation: observation,
          dispatch_assertion: assertion,
          observation_assertion: observation_assertion,
          policy: policy, pinned_policies: pinned_policies,
          accepted_assertions: accepted_assertions, marker: marker,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids,
          all_txs: all_txs, failure: :terminal,
          dispatch_pins_nothing: false, chain_to: attempt_id)
        terminal_ref = {
          "attempt_id" => attempt_id,
          "event_id" => terminal_event.fetch("event_id"),
          "event_digest" => terminal_event.fetch("event_digest")
        }
        unless checkpoint["current_or_terminal_attempt_ref"] == terminal_ref
          raise terminal_invalid("terminal checkpoint must terminal-pin the exact terminal event")
        end
        successor_created_at = begin
          Time.iso8601(event.fetch("recorded_at"))
        rescue ArgumentError, KeyError, TypeError
          nil
        end
        terminated_at = begin
          Time.iso8601(terminal_event.fetch("recorded_at"))
        rescue ArgumentError, KeyError, TypeError
          nil
        end
        unless successor_created_at && terminated_at && successor_created_at > terminated_at
          raise terminal_invalid(
            "successor Attempt must start after the terminated attempt's terminal event"
          )
        end
        reject_nonterminal_conflicts!(all_txs, control_id, successor_attempt, worker, :terminal,
          terminal_overrides: { attempt_id => attempt })
        task_facts = resolve_task_facts!(checkpoint, genesis_tx.fetch("registry"), authority_verifier)
        control_txs = prior
        validate_assembled_snapshot!(marker, pinned_policies, accepted_assertions,
          genesis_tx, control_txs, tx,
          task_facts.fetch("payload"), authority_verifier,
          runtime_identity_verifier, lifecycle_verifier)
        tx
      rescue ContractError => error
        raise error if error.code == "control_store_terminal_invalid"

        raise terminal_invalid("#{error.code}: #{error.message}")
      end

      # Project-wide active backstop: the LATEST attempt representation per
      # attempt id (a terminal reconciliation supersedes the composite's
      # immutable AttemptCreated-only payload) is classified, and any
      # non-terminal attempt sharing control, task, work unit, or canonical
      # runtime subject with the candidate fails closed.
      # The LATEST attempt representation per attempt id across the accepted
      # execution and terminal transactions: a terminal reconciliation
      # supersedes the composite's immutable AttemptCreated-only payload.
      def latest_attempt_map(txs)
        latest = {}
        txs.each do |candidate|
          next unless candidate.is_a?(Hash)

          if candidate.keys.sort == EXECUTION_PAYLOAD_KEYS
            latest[candidate.fetch("attempt").fetch("attempt_id")] = {
              "attempt" => candidate.fetch("attempt"),
              "worker" => candidate.fetch("worker_agent")
            }
          elsif candidate.keys.sort == TERMINAL_PAYLOAD_KEYS
            attempt_id = candidate.fetch("attempt").fetch("attempt_id")
            latest[attempt_id]["attempt"] = candidate.fetch("attempt") if latest[attempt_id]
            successor = candidate.fetch("successor_attempt")
            latest[successor.fetch("attempt_id")] = {
              "attempt" => successor,
              "worker" => candidate.fetch("worker_agent")
            }
          end
        end
        latest
      end

      def reject_nonterminal_conflicts!(txs, control_id, attempt, worker, failure,
                                        terminal_overrides: {})
        invalid = failure == :terminal ? method(:terminal_invalid) : method(:dispatch_invalid)
        latest = latest_attempt_map(txs)
        terminal_overrides.each do |attempt_id, representation|
          latest[attempt_id]["attempt"] = representation if latest[attempt_id]
        end
        worker_key = RuntimeIdentityVerifier.identity_key(worker.fetch("runtime_identity"))
        conflict = latest.values.find do |entry|
          next false if terminal_attempt?(entry.fetch("attempt"))

          existing = entry.fetch("attempt")
          existing_worker_key = RuntimeIdentityVerifier.identity_key(
            entry.fetch("worker").fetch("runtime_identity")
          )
          existing["lead_control_id"] == control_id ||
            existing["task_id"] == attempt["task_id"] ||
            existing["work_unit_id"] == attempt["work_unit_id"] ||
            existing_worker_key == worker_key
        end
        return unless conflict

        raise invalid.call(
          "another non-terminal attempt conflicts by control, task, work unit, or runtime subject"
        )
      end
      def terminal_attempt?(attempt)
        Array(attempt["events"]).any? do |event|
          (TERMINAL_EVENT_TYPES + ["AttemptSuperseded"]).include?(event["event_type"])
        end
      end

      # Assembles the accepted policy/task/control snapshot into a
      # contract bundle and runs the PUBLIC Validator over it with the
      # configured verifiers. Any error fails the checkpoint closed.
      def validate_assembled_snapshot!(marker, pinned_policies, accepted_assertions, genesis_tx, prior,
                                       candidate, task_payload, authority_verifier,
                                       runtime_identity_verifier, lifecycle_verifier)
        bundle = assemble_bundle(marker, pinned_policies, accepted_assertions, genesis_tx,
          prior, candidate, task_payload)
        validator = Orbit::V2::Validator.new(
          project_root: @active_root,
          authority_verifier: authority_verifier,
          lifecycle_verifier: lifecycle_verifier,
          runtime_identity_verifier: runtime_identity_verifier
        )
        errors = validator.validate(bundle)
        return if errors.empty?

        raise checkpoint_invalid(
          "assembled snapshot fails the LeadControl/Validator invariants: " \
            "#{errors.map(&:code).uniq.join(', ')}"
        )
      end

      # The deterministic contract bundle for a control lineage: marker
      # protocol root, accepted policy revisions + issuance assertions,
      # accepted TaskStore payload, control genesis + successor checkpoints
      # (ordinary, session, execution, terminal) in accepted order, one
      # authoritative latest stream representation per session/agent id,
      # and one authoritative latest Attempt per attempt id (a terminal
      # reconciliation supersedes the composite's attempt in the bundle).
      def assemble_bundle(marker, pinned_policies, accepted_assertions, genesis_tx, prior,
                          candidate, task_payload)
        sessions = { genesis_tx.fetch("session").fetch("lead_session_id") => genesis_tx.fetch("session") }
        checkpoints = [genesis_tx.fetch("checkpoint")]
        assertions = [genesis_tx.fetch("assertion")]
        agents = { genesis_tx.fetch("agent").fetch("agent_instance_id") => genesis_tx.fetch("agent") }
        attempts = {}
        resolutions = {}
        prior.each do |tx|
          checkpoint_entries(tx).each do |entry|
            checkpoints << entry.fetch("checkpoint")
            assertions << entry.fetch("assertion")
          end
          if tx.keys.sort == SESSION_CHECKPOINT_PAYLOAD_KEYS
            sessions[tx.fetch("prior_session").fetch("lead_session_id")] = tx.fetch("prior_session")
            sessions[tx.fetch("session").fetch("lead_session_id")] = tx.fetch("session")
            agents[tx.fetch("agent").fetch("agent_instance_id")] = tx.fetch("agent")
          elsif tx.keys.sort == EXECUTION_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
            worker = tx.fetch("worker_agent")
            agents[worker.fetch("agent_instance_id")] = worker
          elsif tx.keys.sort == TERMINAL_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt if attempts.key?(attempt.fetch("attempt_id"))
            successor = tx.fetch("successor_attempt")
            attempts[successor.fetch("attempt_id")] = successor
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
            worker = tx.fetch("worker_agent")
            agents[worker.fetch("agent_instance_id")] = worker
          end
        end
        checkpoint_entries(candidate).each do |entry|
          checkpoints << entry.fetch("checkpoint")
          assertions << entry.fetch("assertion")
        end
        if candidate.keys.sort == SESSION_CHECKPOINT_PAYLOAD_KEYS
          sessions[candidate.fetch("prior_session").fetch("lead_session_id")] = candidate.fetch("prior_session")
          sessions[candidate.fetch("session").fetch("lead_session_id")] = candidate.fetch("session")
          agents[candidate.fetch("agent").fetch("agent_instance_id")] = candidate.fetch("agent")
        elsif candidate.keys.sort == EXECUTION_PAYLOAD_KEYS
          attempt = candidate.fetch("attempt")
          attempts[attempt.fetch("attempt_id")] = attempt
          rule = candidate.fetch("rule_resolution")
          resolutions[rule.fetch("resolution_id")] = rule
          worker = candidate.fetch("worker_agent")
          agents[worker.fetch("agent_instance_id")] = worker
        elsif candidate.keys.sort == TERMINAL_PAYLOAD_KEYS
          attempt = candidate.fetch("attempt")
          attempts[attempt.fetch("attempt_id")] = attempt if attempts.key?(attempt.fetch("attempt_id"))
          successor = candidate.fetch("successor_attempt")
          attempts[successor.fetch("attempt_id")] = successor
          rule = candidate.fetch("rule_resolution")
          resolutions[rule.fetch("resolution_id")] = rule
          worker = candidate.fetch("worker_agent")
          agents[worker.fetch("agent_instance_id")] = worker
        end
        snapshot = { "kind" => "git", "commit_sha" => "a" * 40, "tree_digest" => "sha256:#{'a' * 64}" }
        {
          "schema_version" => "orbit-v2-contract-bundle-v1",
          "protocol_epoch" => "orbit-v2",
          "protocol_root" => marker,
          "authority_assertions" => accepted_assertions + assertions + task_payload.fetch("all_authority_assertions"),
          "authorization_records" => task_payload.fetch("all_authorization_records"),
          "project_policy_revisions" => pinned_policies,
          "task_revisions" => task_payload.fetch("task_revisions"),
          "gate_requirements" => task_payload.fetch("all_gate_requirements"),
          "work_units" => task_payload.fetch("all_work_units"),
          "change_theses" => task_payload.fetch("all_change_theses"),
          "logical_leads" => [task_payload.fetch("logical_lead")],
          "lead_sessions" => sessions.values,
          "control_registries" => [genesis_tx.fetch("registry")],
          "lead_checkpoints" => checkpoints,
          "agent_instances" => agents.values,
          "work_unit_attempts" => attempts.values,
          "rule_resolution_artifacts" => resolutions.values,
          "evidence_records" => [],
          "gate_evaluations" => [],
          "findings" => [],
          "finding_resolutions" => [],
          "repository_snapshot" => snapshot,
          "code_surface" => {
            "kind" => "derived_code_surface",
            "derivation_version" => "orbit-code-surface-v1",
            "repository_tree_digest" => snapshot["tree_digest"],
            "code_surface_digest" => "sha256:#{'a' * 64}",
            "paths" => []
          }
        }
      end

      # Resolves the control's owned task (exactly one; transfers are
      # deferred) through the accepted TaskStore and returns the FULL
      # accepted task-definition payload the checkpoint must close against.
      # A task whose pinned policy does not match the checkpoint's pinned
      # policy is never an acceptable dispatch basis. The resolved revision
      # is the checkpoint's OWN task queue revision (the current queue
      # derived from the accepted checkpoint lineage, never the TaskStore
      # proposal tip), and its parent chain must reach the immutable
      # registry claim — so a proposal that is not yet activated never
      # reinterprets an r1 control, and an activation or dispatch can never
      # use a skipped, cross-task, unknown, or digest-forged revision.
      def resolve_task_facts!(checkpoint, registry, authority_verifier)
        owned = Array(registry["owned_task_refs"])
        raise checkpoint_invalid("checkpoint requires exactly one owned task (transfers deferred)") unless owned.length == 1

        claim = owned.first
        queue = Array(checkpoint["task_queue"])
        queue_ref = queue.length == 1 ? queue.first : nil
        unless queue_ref.is_a?(Hash) && queue_ref["task_id"] == claim["task_id"]
          raise checkpoint_invalid(
            "checkpoint task queue must pin the owned task identity (transfers deferred)"
          )
        end
        task_store = TaskStore.new(active_root: @active_root)
        resolved = begin
          task_store.resolve(
            task_id: claim.fetch("task_id"),
            task_revision_id: queue_ref.fetch("task_revision_id"),
            authority_verifier: authority_verifier
          )
        rescue ContractError => error
          raise checkpoint_invalid("owned task has no accepted definition at the queue revision: #{error.code}")
        end
        task = resolved.fetch("task")
        task_ref = {
          "task_id" => task.fetch("task_id"),
          "task_revision_id" => task.fetch("task_revision_id"),
          "content_digest" => task.fetch("content_digest")
        }
        unless queue_ref == task_ref
          raise checkpoint_invalid("checkpoint task queue ref must exact-match the accepted TaskRevision")
        end
        # The queue revision must descend from the immutable registry claim
        # (same task, exact revision lineage) — forged or unrelated
        # revisions never satisfy ownership.
        revisions = resolved.fetch("task_revisions")
        cursor = task
        claim_found = false
        while cursor
          if cursor["task_revision_id"] == claim["task_revision_id"]
            claim_found = cursor["content_digest"] == claim["content_digest"]
            break
          end
          parent_id = cursor["parent_task_revision_id"]
          cursor = parent_id && revisions.find { |revision| revision["task_revision_id"] == parent_id }
        end
        unless claim_found
          raise checkpoint_invalid(
            "queue revision must descend from the exact registry ownership claim"
          )
        end
        unless task["project_policy_revision_ref"] == checkpoint["project_policy_revision_ref"]
          raise checkpoint_invalid(
            "task facts must exact-match the checkpoint's pinned policy revision"
          )
        end
        lead = resolved.fetch("logical_lead")
        payload = enriched_task_payload(resolved, claim, task_store, authority_verifier)
        {
          "task_ref" => task_ref,
          "logical_lead_ref" => {
            "logical_lead_id" => lead.fetch("logical_lead_id"),
            "content_digest" => lead.fetch("content_digest")
          },
          "work_unit_refs" => resolved.fetch("work_units").map do |unit|
            {
              "work_unit_id" => unit.fetch("work_unit_id"),
              "content_digest" => unit.fetch("content_digest")
            }
          end,
          "work_units" => resolved.fetch("work_units"),
          "payload" => payload
        }
      end

      # Full accepted facts across every accepted revision of the owned
      # task (records + issuance assertions per revision), so assembled
      # snapshots that include historical checkpoints/attempts always
      # resolve their authority facts.
      def enriched_task_payload(resolved, claim, task_store, authority_verifier)
        all_authorization_records = resolved.fetch("task_revisions").flat_map do |revision|
          task_store.resolve(
            task_id: claim.fetch("task_id"),
            task_revision_id: revision.fetch("task_revision_id"),
            authority_verifier: authority_verifier
          ).fetch("authorization_records")
        end
        all_authority_assertions = resolved.fetch("task_revisions").flat_map do |revision|
          task_store.resolve(
            task_id: claim.fetch("task_id"),
            task_revision_id: revision.fetch("task_revision_id"),
            authority_verifier: authority_verifier
          ).fetch("authority_assertions")
        end
        resolved.merge("all_authorization_records" => all_authorization_records,
          "all_authority_assertions" => all_authority_assertions)
      end

      # The minimum session successor/termination form required for
      # checkpoint continuity: the prior active session gains exactly one
      # provider-verified LeadSessionEnded event, and the successor session
      # (generation + 1) exact-pins it via predecessor_lead_session_ref
      # with the same canonical subject, agent, control, task, and durable
      # context. Only the checkpoint transaction that transitions the
      # session carries this form.
      def validate_session_transition!(tx, current_session, agent, project_id,
                                        authority_verifier, runtime_identity_verifier,
                                        lifecycle_verifier, seen_event_ids)
        prior_session = tx.fetch("prior_session")
        successor = tx.fetch("session")
        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("lead_session", prior_session)
          validator.validate_document!("lead_session", successor)
        rescue ValidationFailure, ContractError
          raise checkpoint_invalid("session transition records violate their contracts")
        end
        unless prior_session["project_id"] == project_id && successor["project_id"] == project_id
          raise checkpoint_invalid("session transition records do not carry the marker project identity")
        end
        prior_events = Array(current_session["lifecycle_events"])
        unless prior_session["lead_session_id"] == current_session["lead_session_id"] &&
               prior_session["session_generation"] == current_session["session_generation"]
          raise checkpoint_invalid("prior session must be the control's current active session")
        end
        prior_session_events = Array(prior_session["lifecycle_events"])
        expected_prior_session = JSON.parse(CanonicalJSON.dump(current_session))
        expected_prior_session["lifecycle_events"] = prior_session_events
        unless canonical_equal?(prior_session_events.first(prior_events.length), prior_events) &&
               prior_session_events.length == prior_events.length + 1 &&
               canonical_equal?(prior_session, expected_prior_session)
          raise checkpoint_invalid("prior session must equal the active session plus exactly one terminal event")
        end
        ended = prior_session_events.last
        unless ended["event_type"] == "LeadSessionEnded" &&
               ended["previous_event_digest"] == prior_events.last["event_digest"] &&
               ended["ended_at"] == ended["recorded_at"]
          raise checkpoint_invalid("session termination requires one exact LeadSessionEnded on the active chain")
        end
        verify_event_stream!(prior_session_events, stream: "lead_session",
          project_id: project_id, lifecycle_verifier: lifecycle_verifier,
          seen_event_ids: seen_event_ids, known_prefix_length: prior_events.length)

        unless successor["session_generation"] == current_session["session_generation"] + 1 &&
               successor["predecessor_lead_session_ref"] == {
                 "lead_session_id" => current_session["lead_session_id"],
                 "session_generation" => current_session["session_generation"],
                 "event_id" => ended["event_id"],
                 "event_digest" => ended["event_digest"]
               }
          raise checkpoint_invalid("successor session must exact-pin the prior session generation and terminal event")
        end
        %w[agent_instance_id task_id task_revision_id logical_lead_id durable_context_ref
           lead_runtime_subject_ref lead_runtime_subject_assertion_digest lead_control_id].each do |field|
          unless successor[field] == current_session[field]
            raise checkpoint_invalid("successor session must preserve the #{field} of the prior session")
          end
        end
        verify_event_stream!(Array(successor["lifecycle_events"]), stream: "lead_session",
          project_id: project_id, lifecycle_verifier: lifecycle_verifier, seen_event_ids: seen_event_ids)

        # The successor session's context generation must exist in the
        # AgentInstance's context lineage: the transition carries the agent
        # with exactly one AgentContextAdvanced appended after the
        # termination, provider-verified and globally create-only.
        transitioned_agent = tx.fetch("agent")
        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("agent_instance", transitioned_agent)
        rescue ValidationFailure, ContractError
          raise checkpoint_invalid("transitioned agent violates its contract")
        end
        current_agent_events = Array(agent["lifecycle_events"])
        transitioned_events = Array(transitioned_agent["lifecycle_events"])
        expected_agent = JSON.parse(CanonicalJSON.dump(agent))
        expected_agent["lifecycle_events"] = transitioned_events
        unless canonical_equal?(transitioned_events.first(current_agent_events.length), current_agent_events) &&
               transitioned_events.length == current_agent_events.length + 1 &&
               canonical_equal?(transitioned_agent, expected_agent)
          raise checkpoint_invalid("transitioned agent must equal the bound agent plus exactly one context event")
        end
        advanced = transitioned_events.last
        successor_started = Array(successor["lifecycle_events"]).first
        unless advanced["event_type"] == "AgentContextAdvanced" &&
               advanced["context_generation"] == successor["session_generation"] &&
               advanced["previous_event_digest"] == current_agent_events.last["event_digest"] &&
               Time.iso8601(advanced["recorded_at"]) > Time.iso8601(ended["recorded_at"]) &&
               Time.iso8601(advanced["recorded_at"]) <= Time.iso8601(successor_started["recorded_at"])
          raise checkpoint_invalid("agent context advance must exact-pin the successor session generation")
        end
        verify_event_stream!(transitioned_events, stream: "agent",
          project_id: project_id, lifecycle_verifier: lifecycle_verifier,
          seen_event_ids: seen_event_ids, known_prefix_length: current_agent_events.length)
        begin
          runtime_identity_verifier.verify!(transitioned_agent)
        rescue ContractError => error
          raise checkpoint_invalid("transitioned agent was not runtime-verified: #{error.code}")
        end
      end

      def checkpoint_invalid(message, details = nil)
        ContractError.new(
          "control_store_checkpoint_invalid",
          "control checkpoint rejected: #{message}",
          path: "control_store",
          details: details
        )
      end

      def dispatch_invalid(message, details = nil)
        ContractError.new(
          "control_store_dispatch_invalid",
          "control dispatch rejected: #{message}",
          path: "control_store.dispatch",
          details: details
        )
      end

      def terminal_invalid(message, details = nil)
        ContractError.new(
          "control_store_terminal_invalid",
          "control terminal reconciliation rejected: #{message}",
          path: "control_store.terminal",
          details: details
        )
      end

      def recovery_invalid(message, details = nil)
        ContractError.new(
          "control_store_recovery_invalid",
          "control recovery rejected: #{message}",
          path: "control_store.recover",
          details: details
        )
      end

      def activation_invalid(message, details = nil)
        ContractError.new(
          "control_store_activation_invalid",
          "control activation rejected: #{message}",
          path: "control_store.activate",
          details: details
        )
      end

      def register_id!(seen_ids, kind, id, failure = :genesis)
        return if seen_ids.add?(id)

        if failure == :checkpoint
          raise checkpoint_invalid("#{kind} id #{id} is globally create-only and reused")
        elsif failure == :dispatch
          raise dispatch_invalid("#{kind} id #{id} is globally create-only and reused")
        elsif failure == :terminal
          raise terminal_invalid("#{kind} id #{id} is globally create-only and reused")
        elsif failure == :activation
          raise activation_invalid("#{kind} id #{id} is globally create-only and reused")
        end

        raise genesis_invalid("#{kind} id #{id} is globally create-only and reused")
      end

      def reject_cross_control_conflicts!(others, candidate)
        candidate_key = RuntimeIdentityVerifier.identity_key(
          candidate.fetch("agent").fetch("runtime_identity")
        )
        candidate_tasks = task_ids(candidate.fetch("registry"))
        others.each do |other|
          other_key = RuntimeIdentityVerifier.identity_key(
            other.fetch("agent").fetch("runtime_identity")
          )
          if other_key == candidate_key
            raise ContractError.new(
              "control_store_subject_conflict",
              "canonical runtime subject is already active in another control",
              path: "control_store.#{candidate.fetch("registry").fetch("lead_control_id")}",
              details: { "other_control" => other.fetch("registry").fetch("lead_control_id") }
            )
          end
          overlap = task_ids(other.fetch("registry")) & candidate_tasks
          unless overlap.empty?
            raise ContractError.new(
              "control_store_task_conflict",
              "owned task set overlaps another control",
              path: "control_store.#{candidate.fetch("registry").fetch("lead_control_id")}",
              details: { "other_control" => other.fetch("registry").fetch("lead_control_id"), "overlap" => overlap }
            )
          end
        end
      end

      def task_ids(registry)
        Array(registry["owned_task_refs"]).map { |ref| ref["task_id"] }.sort
      end

      # Provider-verified lifecycle event chain, mirroring the Validator's
      # validate_event_chain + LifecycleVerifier semantics: typed stream
      # contract (initial/terminal, allowed types), event ids globally
      # create-only across every Agent/LeadSession stream and every control
      # transaction (one shared set), exact previous-event digest linkage,
      # self-consistent event digest (excluding digest/receipt/envelope
      # fields), strictly increasing recorded_at, initial started_at ==
      # recorded_at, terminal ended_at == recorded_at, a provider-verified
      # writer receipt for every event, and contiguously advancing Agent
      # context generations.
      def verify_event_stream!(events, stream:, project_id:, lifecycle_verifier:,
                                seen_event_ids:, known_prefix_length: 0)
        contract = {
          "agent" => {
            "initial" => "AgentCreated",
            "allowed" => %w[AgentCreated AgentContextAdvanced AgentTerminated],
            "terminal" => %w[AgentTerminated]
          },
          "lead_session" => {
            "initial" => "LeadSessionStarted",
            "allowed" => %w[LeadSessionStarted LeadSessionEnded],
            "terminal" => %w[LeadSessionEnded]
          }
        }.fetch(stream)
        raise genesis_invalid("lifecycle event stream cannot be empty") if events.empty?

        previous_digest = nil
        previous_recorded_at = nil
        terminal_seen = false
        events.each_with_index do |event, index|
          unless event.is_a?(Hash) && Identifiers.valid?("event_id", event["event_id"])
            raise genesis_invalid("lifecycle event stream has an invalid event id")
          end
          if index < known_prefix_length
            unless seen_event_ids.include?(event["event_id"])
              raise genesis_invalid("lifecycle extension does not repeat a verified prefix")
            end
          else
            if seen_event_ids.include?(event["event_id"])
              raise genesis_invalid(
                "lifecycle event id #{event["event_id"]} is globally create-only and reused"
              )
            end
            seen_event_ids << event["event_id"]
          end
          event_type = event["event_type"]
          unless contract.fetch("allowed").include?(event_type)
            raise genesis_invalid("#{event_type.inspect} is not a typed #{stream} lifecycle event")
          end
          if (index.zero? && event_type != contract.fetch("initial")) ||
             (index.positive? && event_type == contract.fetch("initial"))
            raise genesis_invalid("#{stream} lifecycle stream violates its initial-event contract")
          end
          if terminal_seen
            raise genesis_invalid("no #{stream} lifecycle event may follow a terminal event")
          end
          terminal_seen = true if contract.fetch("terminal").include?(event_type)
          unless event["previous_event_digest"] == previous_digest
            raise genesis_invalid("#{stream} lifecycle event does not extend the previous digest")
          end
          expected_digest = CanonicalJSON.digest_excluding(
            event, "event_digest", "writer_receipt", "created_at", "accepted_at", "envelope"
          )
          unless event["event_digest"] == expected_digest
            raise genesis_invalid("#{stream} lifecycle event digest is not self-consistent")
          end
          chronology = begin
            recorded_at = Time.iso8601(event["recorded_at"])
            valid = previous_recorded_at.nil? || recorded_at > previous_recorded_at
            if index.zero?
              valid &&= event["started_at"].is_a?(String) &&
                       Time.iso8601(event["started_at"]) == recorded_at
            elsif contract.fetch("terminal").include?(event_type)
              valid &&= event["ended_at"].is_a?(String) &&
                       Time.iso8601(event["ended_at"]) == recorded_at
            end
            previous_recorded_at = recorded_at if valid
            valid
          rescue ArgumentError, KeyError, TypeError
            false
          end
          unless chronology
            raise genesis_invalid(
              "#{stream} lifecycle chronology is invalid " \
                "(recorded_at must strictly increase; initial started_at and " \
                "terminal ended_at must equal the trusted recorded_at)"
            )
          end
          begin
            lifecycle_verifier.verify!(event, project_id: project_id)
          rescue ContractError => error
            raise genesis_invalid(
              "#{stream} lifecycle event was not provider-verified: #{error.code}"
            )
          end
          previous_digest = event["event_digest"]
        end
        return unless stream == "agent"

        generations = events.each_with_object([]) do |event, list|
          if %w[AgentCreated AgentContextAdvanced].include?(event["event_type"])
            list << event["context_generation"]
          end
        end
        expected = (generations.first...(generations.first + generations.length)).to_a
        unless generations == expected
          raise genesis_invalid("Agent context generations must advance contiguously without overwrite")
        end
      end

      # LeadSession/AgentInstance lifecycle semantics mirroring the public
      # Validator's runtime_lifecycle.rb rules: the initial session is
      # exactly one LeadSessionStarted event that is active, whose context
      # generation exists in the AgentInstance's context lineage at the
      # start time, whose AgentInstance is active at that time, and whose
      # agent carries the lead orchestration capability/permission. A
      # provider-verified agent without the lead role (e.g. a reviewer)
      # can never be bound as the initial lead session.
      def validate_session_lifecycle!(session, agent)
        started = Array(session["lifecycle_events"])
        unless started.length == 1 &&
               started.first["event_type"] == "LeadSessionStarted" &&
               started.first["status"] == "active"
          raise genesis_invalid("initial LeadSession must be one active LeadSessionStarted event")
        end
        started_event = started.first
        agent_events = Array(agent["lifecycle_events"])
        context_generations = agent_events.each_with_object([]) do |event, generations|
          if %w[AgentCreated AgentContextAdvanced].include?(event["event_type"])
            generations << event["context_generation"]
          end
        end
        unless started_event["context_generation"] == session["session_generation"] &&
               context_generations.include?(started_event["context_generation"])
          raise genesis_invalid(
            "LeadSession start must bind its session generation to an existing Agent context"
          )
        end
        unless agent_events.first.is_a?(Hash) && agent_events.first["event_type"] == "AgentCreated"
          raise genesis_invalid("AgentInstance lifecycle must begin with AgentCreated")
        end
        active = begin
          started_at = Time.iso8601(started_event["recorded_at"])
          context_event = agent_events.find do |event|
            %w[AgentCreated AgentContextAdvanced].include?(event["event_type"]) &&
              event["context_generation"] == started_event["context_generation"]
          end
          terminated = agent_events.find { |event| event["event_type"] == "AgentTerminated" }
          context_event &&
            Time.iso8601(context_event["recorded_at"]) <= started_at &&
            (terminated.nil? || started_at < Time.iso8601(terminated["recorded_at"]))
        rescue ArgumentError, KeyError, TypeError
          false
        end
        unless active
          raise genesis_invalid(
            "LeadSessionStarted requires an active AgentInstance whose exact context " \
              "generation already exists at the trusted start time"
          )
        end
        capabilities = Array(agent.dig("capability_profile", "capabilities"))
        permissions = Array(agent.dig("permission_profile", "permissions"))
        unless capabilities.include?("task.orchestrate") &&
               permissions.include?("task_revision.propose")
          raise genesis_invalid(
            "LeadSession AgentInstance lacks the task.orchestrate capability or " \
              "task_revision.propose permission"
          )
        end
      end

      def unique_policy_grant(policy, action)
        matches = Array(policy["authority_grants"]).select do |grant|
          grant.is_a?(Hash) && grant["action"] == action
        end
        matches.length == 1 ? matches.first : nil
      end

      def control_assertion_digest(value)
        "sha256:#{Digest::SHA256.hexdigest(value.to_s)}"
      end
    end
  end
end
