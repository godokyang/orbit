# frozen_string_literal: true

require "json"
require "time"

require_relative "active_root"
require_relative "canonical_json"
require_relative "code_surface"
require_relative "control_store"
require_relative "durable_file"
require_relative "errors"
require_relative "evidence_contract"
require_relative "identifiers"
require_relative "policy_store"
require_relative "rule_resolution"
require_relative "schema_catalog"
require_relative "task_store"
require_relative "transaction_log"

module Orbit
  module V2
    # Durable acceptance boundary for EvidenceRecord facts.
    #
    # The caller proposes evidence content but never owns acceptance truth:
    # this store writes `accepted`, obtains `acceptance_recorded_at` from its
    # configured clock, and computes the content digest inside the fixed
    # policy -> task -> control -> evidence lock window. The exact Task,
    # WorkUnit, Attempt, RuleResolution and worker identity are resolved
    # through provider-reverified public store seams before the one atomic
    # append commits.
    class EvidenceStore
      EVIDENCE_TRANSACTIONS_FILE = "evidence-transactions.json".freeze
      PAYLOAD_KEYS = %w[code_surface evidence_record repository_snapshot].freeze
      STORE_OWNED_KEYS = %w[acceptance_recorded_at accepted content_digest].freeze

      def initialize(active_root:, clock: -> { Time.now.utc })
        @active_root = File.expand_path(active_root)
        unless File.directory?(@active_root) && clock.respond_to?(:call)
          raise ContractError.new(
            "evidence_store_argument_invalid",
            "active root and configured clock are required",
            path: "evidence_store"
          )
        end
        @clock = clock
        @log = TransactionLog.new(
          path: File.join(@active_root, EVIDENCE_TRANSACTIONS_FILE)
        )
      end

      def accept(proposal:, repository_snapshot:, code_surface_paths:,
                 authority_verifier:, runtime_identity_verifier:, lifecycle_verifier:)
        validate_inputs!(
          proposal,
          repository_snapshot,
          code_surface_paths,
          authority_verifier,
          runtime_identity_verifier,
          lifecycle_verifier
        )
        evidence_id = proposal.fetch("evidence_record_id")
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@active_root, ControlStore::CONTROL_TRANSACTIONS_FILE)

        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
              accepted_at = clock_time!
              record = deep_copy(proposal).merge(
                "accepted" => true,
                "acceptance_recorded_at" => accepted_at.utc.iso8601(6)
              )
              record["content_digest"] = CanonicalJSON.content_digest(record)
              candidate = {
                "code_surface" => CodeSurface.derive(
                  repository_snapshot: repository_snapshot,
                  paths: code_surface_paths
                ),
                "evidence_record" => record,
                "repository_snapshot" => deep_copy(repository_snapshot)
              }
              @log.append_with(
                transaction_id: evidence_id,
                payload: candidate,
                validate: lambda do |records, _tip|
                  validate_acceptance_snapshot!(
                    records,
                    candidate,
                    proposal,
                    authority_verifier,
                    runtime_identity_verifier,
                    lifecycle_verifier
                  )
                end
              )
            end
          end
        end
      rescue ContractError => error
        raise error unless error.code == "transaction_log_reuse"

        raise ContractError.new(
          "evidence_store_reuse",
          "evidence #{proposal["evidence_record_id"]} already exists with different content",
          path: "evidence_store.#{proposal["evidence_record_id"]}"
        )
      end

      def records
        @log.records.map { |record| deep_copy(record.fetch("payload")) }
      end

      def resolve(evidence_record_id:, authority_verifier:,
                  runtime_identity_verifier:, lifecycle_verifier:)
        unless evidence_record_id.is_a?(String) &&
               Identifiers.valid?("evidence_record_id", evidence_record_id) &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "evidence_store_argument_invalid",
            "resolve requires a stable evidence id and all three configured verifiers",
            path: "evidence_store.resolve"
          )
        end

        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@active_root, ControlStore::CONTROL_TRANSACTIONS_FILE)
        evidence_log = File.join(@active_root, EVIDENCE_TRANSACTIONS_FILE)
        result = DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
              DurableFile.with_exclusive_lock(evidence_log) do
                marker, policy = marker_and_policy(authority_verifier)
                verified = verify_existing!(
                  @log.records,
                  marker,
                  policy,
                  authority_verifier,
                  runtime_identity_verifier,
                  lifecycle_verifier
                )
                found = verified.find do |payload|
                  payload.dig("evidence_record", "evidence_record_id") == evidence_record_id
                end
                unless found
                  raise ContractError.new(
                    "evidence_store_missing",
                    "no accepted EvidenceRecord exists for #{evidence_record_id}",
                    path: "evidence_store.#{evidence_record_id}"
                  )
                end
                deep_copy(found)
              end
            end
          end
        end
        result
      end

      private

      def validate_inputs!(proposal, snapshot, paths, authority, runtime, lifecycle)
        valid = proposal.is_a?(Hash) &&
          proposal["evidence_record_id"].is_a?(String) &&
          Identifiers.valid?("evidence_record_id", proposal["evidence_record_id"]) &&
          (proposal.keys & STORE_OWNED_KEYS).empty? &&
          snapshot.is_a?(Hash) && paths.is_a?(Array) &&
          authority.respond_to?(:verify!) && runtime.respond_to?(:verify!) &&
          lifecycle.respond_to?(:verify!)
        return if valid

        raise ContractError.new(
          "evidence_store_argument_invalid",
          "proposal without store-owned fields, snapshot, paths, and all verifiers are required",
          path: "evidence_store.accept"
        )
      end

      def clock_time!
        value = @clock.call
        return value if value.is_a?(Time)

        raise ContractError.new(
          "evidence_store_argument_invalid",
          "configured clock must return Time",
          path: "evidence_store.clock"
        )
      rescue ContractError
        raise
      rescue StandardError => error
        raise ContractError.new(
          "evidence_store_argument_invalid",
          "configured clock failed: #{error.message}",
          path: "evidence_store.clock"
        )
      end

      def validate_acceptance_snapshot!(records, candidate, proposal, authority, runtime, lifecycle)
        marker, policy = marker_and_policy(authority)
        verified = verify_existing!(records, marker, policy, authority, runtime, lifecycle)
        existing = verified.find do |payload|
          payload.dig("evidence_record", "evidence_record_id") == proposal["evidence_record_id"]
        end
        if existing
          return :idempotent if same_submission?(existing, candidate, proposal)

          raise ContractError.new(
            "evidence_store_reuse",
            "evidence #{proposal["evidence_record_id"]} already exists with different content",
            path: "evidence_store.#{proposal["evidence_record_id"]}"
          )
        end

        seen = verified.to_h do |payload|
          record = payload.fetch("evidence_record")
          [record.fetch("evidence_record_id"), record]
        end
        validate_payload!(
          candidate,
          marker,
          policy,
          authority,
          runtime,
          lifecycle,
          seen,
          fresh: true
        )
        nil
      rescue ContractError => error
        raise error if %w[evidence_store_reuse evidence_store_unpinned].include?(error.code)

        raise acceptance_invalid(error)
      end

      def verify_existing!(records, marker, policy, authority, runtime, lifecycle)
        seen = {}
        records.map.with_index do |transaction, index|
          payload = transaction["payload"]
          begin
            unless payload.is_a?(Hash) &&
                   transaction["transaction_id"] == payload.dig("evidence_record", "evidence_record_id")
              raise ContractError.new(
                "evidence_store_lineage_invalid",
                "transaction identity does not exact-bind its EvidenceRecord",
                path: "evidence_store"
              )
            end
            validate_payload!(
              payload,
              marker,
              policy,
              authority,
              runtime,
              lifecycle,
              seen,
              fresh: false
            )
            record = payload.fetch("evidence_record")
            seen[record.fetch("evidence_record_id")] = record
            deep_copy(payload)
          rescue ContractError => error
            raise error if error.code == "evidence_store_unpinned"

            raise lineage_invalid("#{error.code}: #{error.message}", index)
          end
        end
      end

      def validate_payload!(payload, marker, policy, authority, runtime, lifecycle, seen, fresh:)
        unless payload.is_a?(Hash) && payload.keys.sort == PAYLOAD_KEYS &&
               payload["evidence_record"].is_a?(Hash) &&
               payload["repository_snapshot"].is_a?(Hash) &&
               payload["code_surface"].is_a?(Hash)
          raise ContractError.new(
            "evidence_store_acceptance_invalid",
            "transaction has malformed component types or unknown fields",
            path: "evidence_store"
          )
        end
        record = payload.fetch("evidence_record")
        SchemaCatalog.check!("evidence_record", record)
        structural = SchemaCatalog.structure_errors("evidence_record", record)
        raise structural.first unless structural.empty?
        unless record["content_digest"] == CanonicalJSON.content_digest(record) &&
               record["protocol_epoch"] == "orbit-v2" &&
               record["project_id"] == marker["project_id"]
          raise ContractError.new(
            "evidence_store_acceptance_invalid",
            "EvidenceRecord digest, epoch, or project binding is invalid",
            path: "evidence_store.#{record["evidence_record_id"]}"
          )
        end

        expected_surface = CodeSurface.derive(
          repository_snapshot: payload.fetch("repository_snapshot"),
          paths: payload.fetch("code_surface").fetch("paths")
        )
        unless canonical_equal?(expected_surface, payload.fetch("code_surface"))
          raise ContractError.new(
            "evidence_store_acceptance_invalid",
            "stored CodeSurface is not the exact deterministic snapshot projection",
            path: "evidence_store.code_surface"
          )
        end

        task = TaskStore.new(active_root: @active_root).resolve(
          task_id: record.fetch("task_id"),
          task_revision_id: record.fetch("task_revision_id"),
          authority_verifier: authority
        )
        execution = ControlStore.new(active_root: @active_root).resolve_attempt(
          attempt_id: record.fetch("attempt_id"),
          authority_verifier: authority,
          runtime_identity_verifier: runtime,
          lifecycle_verifier: lifecycle
        )
        validate_evidence_fact!(record, task, execution, payload.fetch("code_surface"), policy, fresh)
        validate_lineage!(record, seen)
        true
      end

      def validate_evidence_fact!(record, task_payload, execution, code_surface, policy, fresh)
        task = task_payload.fetch("task")
        attempt = execution.fetch("attempt")
        assignment = attempt.dig("events", 0, "assignment") || {}
        rule = execution.fetch("rule_resolution")
        unit = Array(task_payload["work_units"]).find do |candidate|
          candidate["work_unit_id"] == record["work_unit_id"]
        end
        unless unit &&
               %w[project_id task_id task_revision_id work_unit_id].all? do |field|
                 record[field] == attempt[field] && record[field] == unit[field]
               end
          raise ContractError.new(
            "evidence_record_invalid",
            "EvidenceRecord must exact-bind one accepted Attempt and WorkUnit lineage",
            path: "evidence_store.#{record["evidence_record_id"]}"
          )
        end
        assigned_id = assignment["assigned_rule_resolution_id"]
        unless record["submitted_rule_resolution_id"] == assigned_id &&
               rule["resolution_id"] == assigned_id &&
               rule_matches_attempt?(rule, attempt, assignment)
          raise ContractError.new(
            "rule_resolution_identity_mismatch",
            "submitted RuleResolution must exact-match the Attempt assignment",
            path: "evidence_store.#{record["evidence_record_id"]}.submitted_rule_resolution_id"
          )
        end
        RuleResolution.validate!(rule, project_root: @active_root)

        accepted_at = Time.iso8601(record.fetch("acceptance_recorded_at"))
        started_at = Time.iso8601(attempt.dig("events", 0, "started_at"))
        if accepted_at < started_at
          raise ContractError.new(
            "evidence_chronology_invalid",
            "EvidenceRecord acceptance cannot precede its Attempt start",
            path: "evidence_store.#{record["evidence_record_id"]}.acceptance_recorded_at"
          )
        end

        task_policy = task.fetch("project_policy_revision_ref")
        active = policy.fetch("active_policy")
        active_match = task_policy["policy_revision_id"] == active["policy_revision_id"] &&
          task_policy["content_digest"] == active["content_digest"]
        unless active_match || (!fresh && historical_evidence?(record, attempt, task_policy, policy))
          raise ContractError.new(
            "evidence_authority_stale",
            "new evidence requires the active policy; history must predate its replacement",
            path: "evidence_store.#{record["evidence_record_id"]}"
          )
        end

        errors = EvidenceContract.validate(
          record: record,
          work_unit: unit,
          task_revision: task,
          assignment: assignment,
          code_surface: code_surface
        )
        raise errors.first unless errors.empty?
      rescue ArgumentError, TypeError => error
        raise ContractError.new(
          "evidence_store_acceptance_invalid",
          "EvidenceRecord chronology is invalid: #{error.message}",
          path: "evidence_store.#{record["evidence_record_id"]}"
        )
      end

      def validate_lineage!(record, seen)
        parent_id = record["supersedes_evidence_record_id"]
        if parent_id
          parent = seen[parent_id]
          unless parent && parent_id != record["evidence_record_id"] &&
                 %w[project_id task_id task_revision_id work_unit_id record_kind].all? do |field|
                   parent[field] == record[field]
                 end
            raise ContractError.new(
              "evidence_lineage_invalid",
              "supersedes evidence must be an earlier record in the same exact lineage",
              path: "evidence_store.#{record["evidence_record_id"]}.supersedes_evidence_record_id"
            )
          end
        end
        Array(record["related_evidence_record_refs"]).each do |related_id|
          related = seen[related_id]
          unless related && related_id != record["evidence_record_id"] &&
                 %w[project_id task_id task_revision_id].all? { |field| related[field] == record[field] }
            raise ContractError.new(
              "evidence_lineage_invalid",
              "related evidence must be an earlier record in the same task revision",
              path: "evidence_store.#{record["evidence_record_id"]}.related_evidence_record_refs"
            )
          end
        end
      end

      def marker_and_policy(authority)
        marker = ActiveRoot.marker_for(
          @active_root,
          code: "evidence_store_unpinned",
          label: "evidence_store"
        )
        resolved = PolicyStore.new(active_root: @active_root).resolve(
          pinned_genesis_ref: marker.fetch("project_policy_genesis_ref"),
          authority_verifier: authority
        )
        unless resolved.dig("genesis_policy", "project_id") == marker["project_id"]
          raise ContractError.new(
            "evidence_store_unpinned",
            "policy lineage project does not match ProtocolRoot",
            path: "evidence_store"
          )
        end
        [marker, resolved]
      rescue ContractError => error
        raise error if error.code == "evidence_store_unpinned"

        raise ContractError.new(
          "evidence_store_unpinned",
          "pinned policy lineage does not resolve",
          path: "evidence_store",
          details: { "cause" => error.code, "message" => error.message }
        )
      end

      def historical_evidence?(record, attempt, task_policy, policy)
        terminal = Array(attempt["events"]).last
        return false unless %w[
          AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled AttemptSuperseded
        ].include?(terminal && terminal["event_type"])

        successor = policy.fetch("accepted_policies").find do |candidate|
          candidate["parent_policy_revision_id"] == task_policy["policy_revision_id"]
        end
        assertion = successor && policy.fetch("accepted_assertions").find do |candidate|
          candidate["assertion_id"] == successor["authorization_source_ref"]
        end
        cutoff = Time.iso8601(assertion.dig("policy_issuance_envelope", "issued_at"))
        started_at = Time.iso8601(attempt.dig("events", 0, "started_at"))
        ended_at = Time.iso8601(terminal["ended_at"])
        accepted_at = Time.iso8601(record["acceptance_recorded_at"])
        started_at <= ended_at && started_at < cutoff && ended_at < cutoff &&
          accepted_at >= started_at && accepted_at < cutoff
      rescue ArgumentError, TypeError, NoMethodError
        false
      end

      def rule_matches_attempt?(rule, attempt, assignment)
        identity = rule["identity"]
        identity.is_a?(Hash) && {
          "protocol_epoch" => "orbit-v2",
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

      def same_submission?(existing, candidate, proposal)
        stored = existing.fetch("evidence_record").reject do |key, _value|
          STORE_OWNED_KEYS.include?(key)
        end
        canonical_equal?(stored, proposal) &&
          canonical_equal?(existing["repository_snapshot"], candidate["repository_snapshot"]) &&
          canonical_equal?(existing["code_surface"], candidate["code_surface"])
      end

      def canonical_equal?(left, right)
        CanonicalJSON.dump(left) == CanonicalJSON.dump(right)
      end

      def acceptance_invalid(error)
        ContractError.new(
          "evidence_store_acceptance_invalid",
          "evidence acceptance rejected: #{error.message}",
          path: "evidence_store",
          details: { "cause" => error.code }
        )
      end

      def lineage_invalid(message, index = nil)
        ContractError.new(
          "evidence_store_lineage_invalid",
          "evidence store lineage is invalid: #{message}",
          path: "evidence_store",
          details: index.nil? ? nil : { "transaction_index" => index }
        )
      end

      def deep_copy(value)
        JSON.parse(CanonicalJSON.dump(value))
      end
    end
  end
end
