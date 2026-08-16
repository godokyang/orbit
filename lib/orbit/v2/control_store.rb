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
      GENESIS_ACTION = "control.genesis".freeze

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
        # Root-level shared serialization with a FIXED lock order: the
        # policy log's exclusive lock is acquired BEFORE the control log's,
        # so the policy resolution inside the control snapshot and the
        # control append are atomic with respect to policy rotations — a
        # rotation can never commit between the resolve and the append,
        # and an old active policy can never authorize a new control
        # append. PolicyStore.rotate takes only the policy lock, so no
        # cycle exists.
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
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
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "control_store_reuse",
          "control #{registry.fetch("lead_control_id")} already exists with different canonical content",
          path: "control_store.#{registry.fetch("lead_control_id")}"
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
          tx.fetch("registry").fetch("lead_control_id") == control_id
        end
        unless target
          raise ContractError.new(
            "control_store_missing",
            "no accepted genesis exists for control #{control_id}",
            path: "control_store.#{control_id}"
          )
        end
        {
          "registry" => target.fetch("registry"),
          "session" => target.fetch("session"),
          "checkpoint" => target.fetch("checkpoint"),
          "agent" => target.fetch("agent"),
          "assertion" => target.fetch("assertion")
        }
      end

      private

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
          # Accepted revisions come from the SAME provider-verified
          # PolicyStore snapshot as the resolved lineage.
          "accepted" => resolved.fetch("accepted_policies")
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
        verified_existing = txs.map do |tx|
          validate_transaction!(
            tx,
            policy: nil,
            pinned_policies: policy.fetch("accepted"),
            marker: marker,
            authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier,
            seen_event_ids: seen_event_ids
          )
        end
        existing = verified_existing.find do |tx|
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
          seen_event_ids: seen_event_ids
        )
        reject_cross_control_conflicts!(verified_existing, validated)
        nil
      end

      def verify_all_transactions!(txs, marker, policy, authority_verifier,
                                   runtime_identity_verifier, lifecycle_verifier)
        verified = []
        seen_event_ids = Set.new
        txs.each_with_index do |tx, index|
          begin
            validated = validate_transaction!(
              tx,
              policy: nil,
              pinned_policies: policy.fetch("accepted"),
              marker: marker,
              authority_verifier: authority_verifier,
              runtime_identity_verifier: runtime_identity_verifier,
              lifecycle_verifier: lifecycle_verifier,
              seen_event_ids: seen_event_ids
            )
            reject_cross_control_conflicts!(verified, validated)
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

      # Full final validation of one control-genesis transaction:
      # schemas/digests/epoch/project, control identity and cross-record
      # refs, the pinned policy authority, and the runtime-subject binding.
      def validate_transaction!(tx, policy:, pinned_policies:, marker:,
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
                                seen_event_ids:)
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
          if seen_event_ids.include?(event["event_id"])
            raise genesis_invalid(
              "lifecycle event id #{event["event_id"]} is globally create-only and reused"
            )
          end
          seen_event_ids << event["event_id"]
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
