# frozen_string_literal: true

require "json"
require "time"

require_relative "active_root"
require_relative "canonical_json"
require_relative "control_store"
require_relative "durable_file"
require_relative "errors"
require_relative "evaluation_subject"
require_relative "evidence_store"
require_relative "identifiers"
require_relative "policy_store"
require_relative "projection_primitives"
require_relative "schema_catalog"
require_relative "task_store"
require_relative "transaction_log"
require_relative "validator"

module Orbit
  module V2
    # Durable atomic acceptance boundary for GateEvaluation + Finding facts.
    #
    # One closed transaction commits one GateEvaluation together with its
    # create-only Findings (possibly none for a clean pass), all-or-nothing,
    # under the fixed global lock order policy -> task -> control -> evidence
    # -> gate. The exact active/accepted policy, TaskRevision/
    # GateRequirement, evaluator Attempt and accepted EvidenceStore evidence
    # are resolved and provider-reverified inside the SAME locked snapshot
    # the append commits on, and the complete assembled snapshot runs
    # through the PUBLIC Validator. Idempotent replay is accepted only after
    # the whole existing store re-verifies.
    #
    # Every payload carries a STORE-OWNED frozen `policy_pin` = the exact
    # active policy at acceptance. The policy-first lock prevents a
    # controlled write from racing a rotation; a new write must pin the
    # then-current active policy, and the reader reverifies the frozen pin
    # against the accepted policy lineage (ancestor policy set for
    # historical facts). The pin is part of the committed canonical payload
    # and is never caller-writable.
    #
    # TaskRevision unresolved_finding_refs are treated as genesis/legacy
    # seeds only: the current unresolved state of new Findings is derived
    # from the accepted GateFactStore facts and never written back into the
    # immutable TaskRevision. FindingResolution acceptance and the control
    # checkpoint observation/dispatch barrier are live (see
    # accept_resolution and ControlStore); gate-engine closure output
    # remains deferred.
    class GateFactStore
      GATE_FACTS_FILE = "gate-facts.json".freeze
      PAYLOAD_KEYS = %w[acceptance_recorded_at findings gate_evaluation policy_pin].freeze
      RESOLUTION_PAYLOAD_KEYS = %w[acceptance_recorded_at finding_resolution policy_pin].freeze
      STORE_OWNED_KEYS = %w[acceptance_recorded_at policy_pin].freeze

      def initialize(active_root:, clock: -> { Time.now.utc })
        unless clock.respond_to?(:call)
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "configured clock must respond to call",
            path: "gate_facts_store.clock"
          )
        end
        @clock = clock
        @active_root = File.expand_path(active_root)
        unless File.directory?(@active_root)
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "active root must be an existing directory",
            path: "gate_facts_store.active_root"
          )
        end
        @log = TransactionLog.new(path: File.join(@active_root, GATE_FACTS_FILE))
      end

      # Commits one GateEvaluation + its create-only Findings as ONE closed
      # transaction. Returns :appended or :idempotent (same evaluation id,
      # byte-identical canonical content, only after the whole existing
      # store re-verifies).
      def accept(evaluation:, findings:, authority_verifier:,
                 runtime_identity_verifier:, lifecycle_verifier:)
        validate_inputs!(evaluation, findings, authority_verifier,
          runtime_identity_verifier, lifecycle_verifier)
        # Frozen canonical snapshot BEFORE any lock: the transaction id and
        # the committed content derive from this copy, never from the
        # caller-owned mutable objects.
        frozen = JSON.parse(CanonicalJSON.dump(
          { "findings" => findings, "gate_evaluation" => evaluation }
        ))
        evaluation_id = frozen.dig("gate_evaluation", "gate_evaluation_id")
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@active_root, ControlStore::CONTROL_TRANSACTIONS_FILE)
        evidence_log = File.join(@active_root, EvidenceStore::EVIDENCE_TRANSACTIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
              DurableFile.with_exclusive_lock(evidence_log) do
                marker, policy = marker_and_policy(authority_verifier)
                pin = policy.fetch("active_policy").slice("policy_revision_id", "content_digest")
                accepted_at = clock_time!
                candidate = frozen.merge("policy_pin" => pin,
                  "acceptance_recorded_at" => accepted_at.utc.iso8601(6))
                @log.append_with(
                  transaction_id: evaluation_id,
                  payload: candidate,
                  validate: lambda do |records, _tip|
                    validate_acceptance_snapshot!(
                      records, candidate, evaluation_id,
                      authority_verifier, runtime_identity_verifier, lifecycle_verifier
                    )
                  end
                )
              end
            end
          end
        end
      rescue ContractError => error
        raise error unless error.code == "transaction_log_reuse"

        raise ContractError.new(
          "gate_facts_reuse",
          "GateEvaluation #{evaluation_id} already exists with different content",
          path: "gate_facts_store.#{evaluation_id}"
        )
      end

      def records
        @log.records.map { |record| deep_copy(record.fetch("payload")) }
      end

      # Exact reader by gate_evaluation_id — never a latest pointer.
      def resolve(gate_evaluation_id:, authority_verifier:,
                  runtime_identity_verifier:, lifecycle_verifier:)
        verified = verified_payloads!(gate_evaluation_id, authority_verifier,
          runtime_identity_verifier, lifecycle_verifier)
        found = verified.find do |payload|
          evaluation = payload["gate_evaluation"]
          evaluation.is_a?(Hash) && evaluation["gate_evaluation_id"] == gate_evaluation_id
        end
        unless found
          raise ContractError.new(
            "gate_facts_missing",
            "no accepted GateEvaluation exists for #{gate_evaluation_id}",
            path: "gate_facts_store.#{gate_evaluation_id}"
          )
        end
        deep_copy(found)
      end

      # Commits one FindingResolution as ONE closed transaction under the
      # same fixed locks and whole-history reverify rules as evaluations.
      # The resolution must exact-bind an accepted source Finding, the
      # issuer Attempt + evaluator submission + rule, the accepted
      # supporting EvidenceStore records, and the frozen acceptance-time
      # policy pin; resolution ids are globally create-only with a linear
      # per-finding lineage (supersedes the current tip).
      # The waived resolution transaction stays limited to the
      # FindingResolution + store-owned acceptance metadata/pin: its
      # finding.waive AuthorizationRecord and assertion are NOT
      # co-committed — they must already be ACCEPTED facts of the source
      # task's authoritative TaskStore revision, and the resolution
      # references the record by authorization_record_ref only.
      def accept_resolution(resolution:, authority_verifier:,
                            runtime_identity_verifier:, lifecycle_verifier:)
        unless resolution.is_a?(Hash) &&
               resolution["finding_resolution_id"].is_a?(String) &&
               Identifiers.valid?("finding_resolution_id", resolution["finding_resolution_id"]) &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "accept_resolution requires one FindingResolution and all three configured verifiers",
            path: "gate_facts_store.accept_resolution"
          )
        end
        frozen = JSON.parse(CanonicalJSON.dump({ "finding_resolution" => resolution }))
        resolution_id = frozen.dig("finding_resolution", "finding_resolution_id")
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@active_root, ControlStore::CONTROL_TRANSACTIONS_FILE)
        evidence_log = File.join(@active_root, EvidenceStore::EVIDENCE_TRANSACTIONS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
              DurableFile.with_exclusive_lock(evidence_log) do
                marker, policy = marker_and_policy(authority_verifier)
                pin = policy.fetch("active_policy").slice("policy_revision_id", "content_digest")
                accepted_at = clock_time!
                candidate = frozen.merge("policy_pin" => pin,
                  "acceptance_recorded_at" => accepted_at.utc.iso8601(6))
                @log.append_with(
                  transaction_id: resolution_id,
                  payload: candidate,
                  validate: lambda do |records, _tip|
                    validate_resolution_snapshot!(
                      records, candidate, resolution_id,
                      authority_verifier, runtime_identity_verifier, lifecycle_verifier
                    )
                  end
                )
              end
            end
          end
        end
      rescue ContractError => error
        raise error unless error.code == "transaction_log_reuse"

        raise ContractError.new(
          "gate_facts_reuse",
          "FindingResolution #{resolution_id} already exists with different content",
          path: "gate_facts_store.#{resolution_id}"
        )
      end

      # Exact reader by finding_resolution_id — never a latest pointer.
      def resolve_finding_resolution(finding_resolution_id:, authority_verifier:,
                                     runtime_identity_verifier:, lifecycle_verifier:)
        unless finding_resolution_id.is_a?(String) &&
               Identifiers.valid?("finding_resolution_id", finding_resolution_id)
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "finding_resolution_id must be a stable resolution identifier",
            path: "gate_facts_store.resolve_finding_resolution"
          )
        end
        verified = verified_payloads!(nil, authority_verifier,
          runtime_identity_verifier, lifecycle_verifier)
        found = verified.find do |payload|
          payload.key?("finding_resolution") &&
            payload.fetch("finding_resolution").fetch("finding_resolution_id") == finding_resolution_id
        end
        unless found
          raise ContractError.new(
            "gate_facts_missing",
            "no accepted FindingResolution exists for #{finding_resolution_id}",
            path: "gate_facts_store.#{finding_resolution_id}"
          )
        end
        deep_copy(found)
      end

      # DELIBERATE collaborator for the ControlStore cutoff seam: the one
      # internal no-lock snapshot reader, kept OUT of the public instance
      # surface so no caller can bypass verification via the store API. The
      # caller MUST already hold the full fixed lock chain (policy -> task
      # -> control -> evidence -> gate); the snapshot is verified
      # STRUCTURALLY (closed shape, transaction identity, schema, digest,
      # epoch, project, frozen policy pin accepted) — deliberately WITHOUT
      # the cross-store evaluation/resolution fact resolution, so the
      # ControlStore can freeze its cutoff inside its own validation window
      # without recursing into its own readers. The ControlStore assembled
      # public Validator closure re-validates the gate facts semantically in
      # the bundle.
      class Cutoff
        def initialize(active_root:)
          @store = GateFactStore.new(active_root: active_root)
        end

        def snapshot_locked(authority_verifier:, runtime_identity_verifier:,
                            lifecycle_verifier:)
          @store.send(:cutoff_snapshot_locked,
            authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier)
        end
      end

      # Exact reader by finding_id — never a latest pointer.
      def resolve_finding(finding_id:, authority_verifier:,
                          runtime_identity_verifier:, lifecycle_verifier:)
        unless finding_id.is_a?(String) && Identifiers.valid?("finding_id", finding_id)
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "finding_id must be a stable finding identifier",
            path: "gate_facts_store.resolve_finding.finding_id"
          )
        end
        verified = verified_payloads!(nil, authority_verifier,
          runtime_identity_verifier, lifecycle_verifier)
        found = verified.flat_map { |payload| payload.fetch("findings", []) }.find do |finding|
          finding.fetch("finding_id") == finding_id
        end
        unless found
          raise ContractError.new(
            "gate_facts_missing",
            "no accepted Finding exists for #{finding_id}",
            path: "gate_facts_store.findings.#{finding_id}"
          )
        end
        deep_copy(found)
      end

      private

      # INTERNAL no-lock cutoff verification for callers that ALREADY hold
      # the full fixed lock chain (policy -> task -> control -> evidence ->
      # gate): structurally verifies and returns the accepted gate facts
      # without any further lock acquisition, so the ControlStore can freeze
      # its cutoff inside its own operation window without nesting a
      # self-locking reader (no cross-process lock-order inversion). Only
      # reachable through the Cutoff collaborator.
      def cutoff_snapshot_locked(authority_verifier:, runtime_identity_verifier:,
                                 lifecycle_verifier:, include_operation_cache: false)
        marker, policy = marker_and_policy(authority_verifier)
        evaluations = []
        findings = []
        resolutions = []
        payloads = []
        transactions = []
        @log.records.each do |transaction|
          payload = transaction["payload"]
          shape = payload.is_a?(Hash) ? payload.keys.sort : nil
          bound_id = case shape
                     when PAYLOAD_KEYS
                       payload.dig("gate_evaluation", "gate_evaluation_id")
                     when RESOLUTION_PAYLOAD_KEYS
                       payload.dig("finding_resolution", "finding_resolution_id")
                     end
          unless shape && transaction["transaction_id"] == bound_id
            raise ContractError.new(
              "gate_facts_lineage_invalid",
              "transaction identity does not exact-binds its accepted gate fact",
              path: "gate_facts_store"
            )
          end
          verify_cutoff_shape!(payload, marker, policy)
          payloads << payload
          evaluations << payload["gate_evaluation"] if payload["gate_evaluation"]
          findings.concat(payload.fetch("findings", []))
          resolutions << payload["finding_resolution"] if payload["finding_resolution"]
          transactions << {
            "transaction_id" => transaction["transaction_id"],
            "content_digest" => transaction["content_digest"],
            "gate_evaluation_id" => payload.dig("gate_evaluation", "gate_evaluation_id"),
            "finding_resolution_id" => payload.dig("finding_resolution", "finding_resolution_id")
          }
        end
        # The dispatch barrier may treat a resolution tip as resolving ONLY
        # if the tip is fully verified: every persisted resolution runs the
        # complete acceptance validation against the same locked snapshot
        # (provider/authority/evidence closure, exact lineage), so a forged
        # digest-consistent resolution never lifts the complete-cutoff
        # barrier. The verification is STAGED over the already-locked
        # private seams: the ControlStore whole lineage re-verifies against
        # this STRUCTURAL cutoff (via ControlStore::Cutoff), then the
        # EvidenceStore whole store re-verifies with those verified control
        # transactions (via EvidenceStore::Cutoff), and only then are the
        # resolution payloads finalized prefix-scoped (each sees ONLY its
        # prior log prefix — never itself or future facts). Any stage
        # failure fails the whole operation, so the outcome stays atomic and
        # non-recursive — no public reader is ever entered inside the
        # window. Writers optionally retain this same verified operation
        # cache for their candidate/idempotency validation; they never open
        # a second EvidenceStore/ControlStore snapshot after the cutoff.
        structural = {
          "gate_evaluations" => evaluations,
          "findings" => findings,
          "finding_resolutions" => resolutions,
          "transactions" => transactions
        }
        cache = { control_records: nil, controls: {}, evidence: {}, tasks: {} }
        verified_control_txs = Orbit::V2::ControlStore::Cutoff.new(active_root: @active_root)
          .verified_records(gate_cutoff: structural,
            authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier)
        cache[:control_records] = verified_control_txs
        Orbit::V2::EvidenceStore::Cutoff.new(active_root: @active_root).verified_payloads(
          gate_cutoff: structural,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier,
          verified_control_txs: verified_control_txs
        ).each do |payload|
          entry = payload["evidence_record"]
          if entry.is_a?(Hash) && entry["evidence_record_id"].is_a?(String)
            cache[:evidence][entry.fetch("evidence_record_id")] = payload
          end
        end
        # FULL append-order replay through the same validate_payload! path
        # verify_existing! uses: EVERY gate payload (evaluations AND
        # resolutions) runs the complete acceptance validation
        # (provider/Attempt/evidence/subject/independence/chronology/lineage)
        # prefix-scoped — each payload sees ONLY its prior log prefix, never
        # itself or future facts. The returned facts are exactly the fully
        # verified replay, so a digest-consistent but provider/authority/
        # evidence-invalid GateEvaluation/Finding can never enter ControlStore
        # historical bundles or the dispatch barrier.
        seen = {}
        verified_evaluations = []
        verified_findings = []
        verified_resolutions = []
        payloads.each_with_index do |payload, index|
          validate_payload!(payload, marker, policy, authority_verifier,
            runtime_identity_verifier, lifecycle_verifier, seen,
            payloads[0...index], fresh: false, cache: cache)
          if payload["gate_evaluation"]
            verified_evaluations << payload["gate_evaluation"]
            payload.fetch("findings", []).each do |finding|
              seen[finding.fetch("finding_id")] = finding
              verified_findings << finding
            end
          elsif payload["finding_resolution"]
            verified_resolutions << payload["finding_resolution"]
          end
        end
        # STAGE 5: the ControlStore whole lineage re-verifies one final time
        # with the VERIFIED evidence cache and the FINAL (fully verified) gate
        # cutoff, so the returned control facts are only ever produced from
        # verified authority. The structural bootstrap below is never exposed
        # as verified authority.
        final_control = Orbit::V2::ControlStore::Cutoff.new(active_root: @active_root)
          .verified_records(
            gate_cutoff: {
              "gate_evaluations" => verified_evaluations,
              "findings" => verified_findings,
              "finding_resolutions" => verified_resolutions,
              "transactions" => transactions
            },
            evidence_payloads: cache[:evidence].values,
            authority_verifier: authority_verifier,
            runtime_identity_verifier: runtime_identity_verifier,
            lifecycle_verifier: lifecycle_verifier)
        cache[:control_records] = final_control
        snapshot = {
          "gate_evaluations" => verified_evaluations,
          "findings" => verified_findings,
          "finding_resolutions" => verified_resolutions,
          "transactions" => transactions
        }
        include_operation_cache ? [snapshot, cache] : snapshot
      end

      def verify_cutoff_shape!(payload, marker, policy)
        evaluation = payload["gate_evaluation"]
        resolution = payload["finding_resolution"]
        pin = payload["policy_pin"]
        accepted = policy.fetch("accepted_policies")
        unless pin.is_a?(Hash) &&
               accepted.any? do |candidate|
                 candidate["policy_revision_id"] == pin["policy_revision_id"] &&
                   candidate["content_digest"] == pin["content_digest"]
               end
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "accepted gate fact policy pin does not exact-bind an accepted revision",
            path: "gate_facts_store"
          )
        end
        if evaluation
          SchemaCatalog.check!("gate_evaluation", evaluation)
          unless evaluation["content_digest"] == CanonicalJSON.content_digest(evaluation) &&
                 evaluation["protocol_epoch"] == "orbit-v2" &&
                 evaluation["project_id"] == marker["project_id"]
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "accepted GateEvaluation digest, epoch, or project binding is invalid",
              path: "gate_facts_store"
            )
          end
        end
        if resolution
          SchemaCatalog.check!("finding_resolution", resolution)
          unless resolution["content_digest"] == CanonicalJSON.content_digest(resolution) &&
                 resolution["protocol_epoch"] == "orbit-v2" &&
                 resolution["project_id"] == marker["project_id"]
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "accepted FindingResolution digest, epoch, or project binding is invalid",
              path: "gate_facts_store"
            )
          end
        end
        payload.fetch("findings", []).each do |finding|
          SchemaCatalog.check!("finding", finding)
          unless finding["content_digest"] == CanonicalJSON.content_digest(finding) &&
                 finding["protocol_epoch"] == "orbit-v2" &&
                 finding["project_id"] == marker["project_id"]
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "accepted Finding digest, epoch, or project binding is invalid",
              path: "gate_facts_store"
            )
          end
        end
      end

      def validate_inputs!(evaluation, findings, authority, runtime, lifecycle)
        unless evaluation.is_a?(Hash) &&
               evaluation["gate_evaluation_id"].is_a?(String) &&
               Identifiers.valid?("gate_evaluation_id", evaluation["gate_evaluation_id"]) &&
               findings.is_a?(Array) &&
               findings.all? { |finding| finding.is_a?(Hash) } &&
               authority.respond_to?(:verify!) && runtime.respond_to?(:verify!) &&
               lifecycle.respond_to?(:verify!)
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "accept requires one GateEvaluation, its Findings array, and all three configured verifiers",
            path: "gate_facts_store.accept"
          )
        end
      end

      def validate_acceptance_snapshot!(records, candidate, evaluation_id,
                                        authority, runtime, lifecycle)
        marker, policy = marker_and_policy(authority)
        _cutoff, cache = cutoff_snapshot_locked(
          authority_verifier: authority,
          runtime_identity_verifier: runtime,
          lifecycle_verifier: lifecycle,
          include_operation_cache: true
        )
        verified = verify_existing!(records, marker, policy, authority, runtime, lifecycle,
          cache: cache)
        existing = verified.find do |payload|
          evaluation = payload["gate_evaluation"]
          evaluation.is_a?(Hash) && evaluation["gate_evaluation_id"] == evaluation_id
        end
        if existing
          return :idempotent if same_facts?(existing, candidate)

          raise ContractError.new(
            "gate_facts_reuse",
            "GateEvaluation #{evaluation_id} already exists with different content",
            path: "gate_facts_store.#{evaluation_id}"
          )
        end
        seen = verified.each_with_object({}) do |payload, ids|
          payload.fetch("findings", []).each { |finding| ids[finding.fetch("finding_id")] = finding }
        end
        validate_payload!(candidate, marker, policy, authority, runtime, lifecycle, seen,
          verified, fresh: true, cache: cache)
        nil
      rescue ContractError => error
        raise error if %w[gate_facts_reuse gate_facts_unpinned].include?(error.code)

        raise acceptance_invalid(error)
      end

      def verify_existing!(records, marker, policy, authority, runtime, lifecycle,
                           cache: operation_cache)
        seen = {}
        verified = []
        records.map.with_index do |transaction, index|
          payload = transaction["payload"]
          begin
            shape = payload.is_a?(Hash) ? payload.keys.sort : nil
            bound_id = case shape
                       when PAYLOAD_KEYS
                         payload.dig("gate_evaluation", "gate_evaluation_id")
                       when RESOLUTION_PAYLOAD_KEYS
                         payload.dig("finding_resolution", "finding_resolution_id")
                       end
            unless shape && transaction["transaction_id"] == bound_id
              raise ContractError.new(
                "gate_facts_lineage_invalid",
                "transaction identity does not exact-bind its accepted gate fact",
                path: "gate_facts_store"
              )
            end
            validate_payload!(
              payload, marker, policy, authority, runtime, lifecycle, seen,
              verified, fresh: false, cache: cache
            )
            payload.fetch("findings", []).each do |finding|
              seen[finding.fetch("finding_id")] = finding
            end
            if payload.key?("finding_resolution")
              resolution = payload.fetch("finding_resolution")
              seen[resolution.fetch("finding_resolution_id")] = resolution
            end
            verified << deep_copy(payload)
            verified.last
          rescue ContractError => error
            raise error if error.code == "gate_facts_unpinned"

            raise lineage_invalid("#{error.code}: #{error.message}", index)
          end
        end
      end

      def validate_payload!(payload, marker, policy, authority, runtime, lifecycle, seen,
                            existing, fresh:, cache:)
        if payload.is_a?(Hash) && payload.keys.sort == RESOLUTION_PAYLOAD_KEYS
          validate_resolution_payload!(payload, marker, policy, authority, runtime, lifecycle,
            seen, existing, fresh: fresh, cache: cache)
          return true
        end
        unless payload.is_a?(Hash) && payload.keys.sort == PAYLOAD_KEYS &&
               payload["gate_evaluation"].is_a?(Hash) &&
               payload["findings"].is_a?(Array) &&
               payload["findings"].all? { |finding| finding.is_a?(Hash) } &&
               payload["policy_pin"].is_a?(Hash) &&
               payload["acceptance_recorded_at"].is_a?(String)
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "transaction has malformed component types or unknown fields",
            path: "gate_facts_store"
          )
        end
        evaluation = payload.fetch("gate_evaluation")
        findings = payload.fetch("findings")
        pin = payload.fetch("policy_pin")
        SchemaCatalog.check!("gate_evaluation", evaluation)
        findings.each { |finding| SchemaCatalog.check!("finding", finding) }
        unless evaluation["content_digest"] == CanonicalJSON.content_digest(evaluation) &&
               findings.all? { |finding| finding["content_digest"] == CanonicalJSON.content_digest(finding) } &&
               evaluation["protocol_epoch"] == "orbit-v2" &&
               findings.all? { |finding| finding["protocol_epoch"] == "orbit-v2" } &&
               findings.all? { |finding| finding["project_id"] == marker["project_id"] } &&
               evaluation["project_id"] == marker["project_id"]
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "GateEvaluation/Finding digest, epoch, or project binding is invalid",
            path: "gate_facts_store"
          )
        end

        finding_ids = findings.map { |finding| finding.fetch("finding_id") }
        unless finding_ids.uniq.length == finding_ids.length &&
               evaluation.fetch("finding_refs").sort == finding_ids.sort &&
               findings.all? { |finding| finding["gate_evaluation_id"] == evaluation.fetch("gate_evaluation_id") }
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "GateEvaluation must report exactly its committed create-only Findings",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.finding_refs"
          )
        end
        findings.each do |finding|
          if seen.key?(finding.fetch("finding_id"))
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "finding id #{finding.fetch("finding_id")} is globally create-only and reused",
              path: "gate_facts_store.findings.#{finding["finding_id"]}"
            )
          end
          unless finding["supersedes_finding_id"].nil? &&
                 Array(finding["related_finding_refs"]).empty?
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "Finding supersession/related lineages are deferred; create-only Findings only",
              path: "gate_facts_store.findings.#{finding["finding_id"]}"
            )
          end
        end
        supersedes_id = evaluation["supersedes_gate_evaluation_id"]
        unless Array(evaluation["related_gate_evaluation_refs"]).empty?
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "GateEvaluation related lineages are deferred",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.related_gate_evaluation_refs"
          )
        end
        if supersedes_id
          # A follow-up GateEvaluation must exact-extend the accepted gate
          # lineage: the superseded evaluation exists, evaluates the SAME
          # gate requirement, and is the current tip of its chain (no other
          # accepted evaluation supersedes it), so a fork never commits and
          # the resolution's distinct descending evaluation is real.
          accepted_evaluations = existing.map { |entry| entry["gate_evaluation"] }.compact
          superseded = accepted_evaluations.find do |candidate|
            candidate["gate_evaluation_id"] == supersedes_id
          end
          forked = accepted_evaluations.any? do |candidate|
            candidate["supersedes_gate_evaluation_id"] == supersedes_id
          end
          unless superseded && !forked &&
                 superseded["gate_requirement_id"] == evaluation["gate_requirement_id"]
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "GateEvaluation supersession must exact-extend the current tip of its gate lineage",
              path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.supersedes_gate_evaluation_id"
            )
          end
        end

        # The frozen acceptance-time active-policy pin: it must exact-bind an
        # accepted policy revision, and a NEW write must pin the policy that
        # is active in the same locked snapshot (replay of a stored payload
        # proves its acceptance-time cutoff from the frozen pin alone — a
        # controlled post-rotation old-policy evaluation cannot pass the
        # write path, and the reader never reinterprets the pin).
        active = policy.fetch("active_policy")
        accepted = policy.fetch("accepted_policies")
        unless pin.keys.sort == %w[content_digest policy_revision_id] &&
               accepted.any? do |candidate|
                 candidate["policy_revision_id"] == pin["policy_revision_id"] &&
                   candidate["content_digest"] == pin["content_digest"]
               end
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "policy_pin must exact-bind an accepted policy revision",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.policy_pin"
          )
        end
        if fresh &&
           (pin["policy_revision_id"] != active["policy_revision_id"] ||
            pin["content_digest"] != active["content_digest"])
          raise ContractError.new(
            "gate_facts_authority_stale",
            "a new GateEvaluation must pin the currently active policy",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.policy_pin"
          )
        end

        task, submission, evidence_by_id, control =
          resolve_exact_facts!(evaluation, findings, marker, pin, policy, authority,
            runtime, lifecycle, cache)
        task_policy = task.fetch("task").fetch("project_policy_revision_ref")
        unless task_policy == pin
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluation task must exact-bind the frozen acceptance-time policy pin",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}"
          )
        end
        validate_acceptance_chronology!(payload, pin, policy, submission, fresh,
          authority, runtime, lifecycle, cache)
        validate_evidence_closure!(findings, evaluation, submission, evidence_by_id)

        # Each evaluation is first proven against ITS OWN frozen snapshot and
        # evidence set. The relation bundle below then carries the real,
        # byte-identical supersession ancestors and their Findings so every
        # checkpoint supporting ref resolves; its evidence union is never
        # allowed to redefine an already-proven evaluation subject.
        relation = evaluation_relation_payloads(existing, evaluation)
        own_evidence = evidence_by_id
        prove_evaluation_subject!(evaluation, findings, task, submission,
          own_evidence, cache)
        relation_evidence = relation.each_with_object(own_evidence.dup) do |ancestor, merged|
          ancestor_evaluation = ancestor.fetch("gate_evaluation")
          ancestor_findings = ancestor.fetch("findings", [])
          ancestor_submission = cached_evidence(cache,
            ancestor_evaluation.fetch("evaluator_submission_record_id"), authority,
            runtime, lifecycle)
          ancestor_evidence = evaluation_evidence_by_id(
            ancestor_evaluation, ancestor_findings, cache, authority, runtime, lifecycle
          )
          prove_evaluation_subject!(ancestor_evaluation, ancestor_findings, task,
            ancestor_submission, ancestor_evidence, cache)
          merged.merge!(ancestor_evidence)
        end
        relation_evaluations = relation.map { |ancestor| ancestor.fetch("gate_evaluation") }
        relation_findings = relation.flat_map { |ancestor| ancestor.fetch("findings", []) }
        bundle = assemble_bundle(marker, policy, task, submission,
          relation_evidence, payload, control, authority, runtime, lifecycle,
          relation_evaluations: relation_evaluations,
          relation_findings: relation_findings)
        validator = Orbit::V2::Validator.new(
          project_root: @active_root,
          authority_verifier: authority,
          lifecycle_verifier: lifecycle,
          runtime_identity_verifier: runtime
        )
        errors = validator.validate(bundle)
        # STAGED risk acceptance boundary: the GateFactStore may atomically
        # accept a newly discovered unadjudicated risk BEFORE its global
        # closure is closed by the later ControlStore finding_change
        # exact-pin; until then the complete bundle is still invalid and the
        # dispatch barrier applies. The ONLY tolerated public error is
        # finding_risk_unobserved at EXACTLY the current payload's own
        # finding path; any other code, any other finding's path, or an
        # error about a stale/foreign finding fails closed unchanged. The
        # resolution path is never relaxed: by resolution time the source
        # risk must already be closed by the control observation.
        proven_evaluation_ids = (relation_evaluations + [evaluation]).map do |candidate|
          candidate.fetch("gate_evaluation_id")
        end
        remaining = errors.reject do |error|
          staged = error.code == "finding_risk_unobserved" &&
            findings.any? { |finding| error.path == "findings.#{finding["finding_id"]}" }
          historical_subject = ProjectionPrimitives.historical_stale_evaluation_error?(error) &&
            proven_evaluation_ids.any? do |evaluation_id|
              error.path == "gate_evaluations.#{evaluation_id}.subject"
            end
          staged || historical_subject
        end
        unless remaining.empty?
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "assembled snapshot fails the Validator invariants: " \
              "#{remaining.map(&:code).uniq.join(', ')}",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}"
          )
        end
        true
      end

      # Exact same-snapshot fact resolution: the evaluator Attempt and its
      # control lineage, the exact TaskRevision/GateRequirement, and the
      # accepted EvidenceStore evidence. The control facts are read from the
      # accepted control records and verified by the FINAL assembled
      # snapshot through the PUBLIC Validator (checkpoint writer authority,
      # attempt dispatch refs, agent runtime identities, and lifecycle
      # receipts), filtered to the bundle policy set so a historical
      # evaluation (frozen pin) never drags in post-rotation checkpoints.
      # Any phantom/borrowed/cross-scope ref fails closed.

      # The latest accepted attempt representation per attempt id from the
      # control records (a terminal reconciliation supersedes the composite
      # payload).
      def latest_attempts(records)
        attempts = {}
        records.each do |tx|
          case tx.keys.sort
          when ControlStore::EXECUTION_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
          when ControlStore::TERMINAL_PAYLOAD_KEYS
            terminated = tx.fetch("attempt")
            attempts[terminated.fetch("attempt_id")] = terminated if attempts.key?(terminated.fetch("attempt_id"))
            successor = tx.fetch("successor_attempt")
            attempts[successor.fetch("attempt_id")] = successor
          end
        end
        attempts
      end

      # One operation holds the complete fixed lock chain, so exact reader
      # results are immutable for that window. Cache them only inside that
      # window: every referenced store still performs its full provider-
      # verified replay once, while repeated gate facts cannot multiply the
      # same ControlStore/EvidenceStore/TaskStore replay exponentially.
      def operation_cache
        { control_records: nil, controls: {}, evidence: {}, tasks: {} }
      end

      def cached_control_records(cache)
        cache[:control_records] ||= ControlStore.new(active_root: @active_root).records
      end

      def cached_task(cache, task_id, revision_id, authority)
        cache[:tasks][[task_id, revision_id]] ||= TaskStore.new(active_root: @active_root).resolve(
          task_id: task_id,
          task_revision_id: revision_id,
          authority_verifier: authority
        )
      end

      def cached_evidence(cache, record_id, authority, runtime, lifecycle)
        cache[:evidence][record_id] ||= EvidenceStore.new(active_root: @active_root).resolve(
          evidence_record_id: record_id,
          authority_verifier: authority,
          runtime_identity_verifier: runtime,
          lifecycle_verifier: lifecycle
        )
      end

      def resolve_exact_facts!(evaluation, findings, marker, pin, policy, authority,
                               runtime, lifecycle, cache)
        records = cached_control_records(cache)
        attempts = {}
        agents = {}
        resolutions = {}
        records.each do |tx|
          case tx.keys.sort
          when ControlStore::EXECUTION_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
            agents[tx.fetch("worker_agent").fetch("agent_instance_id")] = tx.fetch("worker_agent")
            resolutions[tx.fetch("rule_resolution").fetch("resolution_id")] = tx.fetch("rule_resolution")
          when ControlStore::TERMINAL_PAYLOAD_KEYS
            terminated = tx.fetch("attempt")
            attempts[terminated.fetch("attempt_id")] = terminated if attempts.key?(terminated.fetch("attempt_id"))
            successor = tx.fetch("successor_attempt")
            attempts[successor.fetch("attempt_id")] = successor
            agents[tx.fetch("worker_agent").fetch("agent_instance_id")] = tx.fetch("worker_agent")
            resolutions[tx.fetch("rule_resolution").fetch("resolution_id")] = tx.fetch("rule_resolution")
          end
        end
        attempt = attempts[evaluation.fetch("evaluator_attempt_id")]
        unless attempt
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluator Attempt does not exist in the accepted control lineage",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.evaluator_attempt_id"
          )
        end
        assignment = attempt.dig("events", 0, "assignment") || {}
        rule = resolutions[assignment["assigned_rule_resolution_id"]]
        agent = agents[assignment["agent_instance_id"]]
        unless rule && agent
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluator Attempt has no exact RuleResolution or worker AgentInstance",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.evaluator_attempt_id"
          )
        end
        control_id = attempt.fetch("lead_control_id")
        policies, = bundle_policy_set(policy, pin)
        control = control_facts(control_id, policies, authority, runtime, lifecycle, cache)
        unless control.fetch("registries").any? &&
               control.fetch("attempts").any? { |candidate| candidate["attempt_id"] == attempt["attempt_id"] }
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluator control facts must exact-resolve under the frozen pin policy set",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}"
          )
        end
        subject_ref = evaluation.dig("subject", "task_revision_ref") || {}
        task = cached_task(cache, attempt.fetch("task_id"),
          subject_ref.fetch("task_revision_id"), authority)
        task_record = task.fetch("task")
        unless subject_ref["content_digest"] == task_record["content_digest"] &&
               attempt["task_id"] == task_record["task_id"] &&
               attempt["task_revision_id"] == task_record["task_revision_id"]
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "GateEvaluation subject must exact-bind the evaluator Attempt task revision",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.subject"
          )
        end
        requirement = Array(task["gate_requirements"]).find do |candidate|
          candidate["gate_requirement_id"] == evaluation.fetch("gate_requirement_id")
        end
        unless requirement &&
               requirement["task_revision_id"] == task_record["task_revision_id"] &&
               requirement["content_digest"] == evaluation.fetch("gate_requirement_content_digest") &&
               Array(task_record["gate_requirement_refs"]).include?(requirement["gate_requirement_id"])
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "GateEvaluation must exact-pin an owned GateRequirement of the subject TaskRevision",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.gate_requirement_id"
          )
        end
        submission = cached_evidence(cache, evaluation.fetch("evaluator_submission_record_id"),
          authority, runtime, lifecycle)
        submission_record = submission.fetch("evidence_record")
        unless submission_record["attempt_id"] == attempt.fetch("attempt_id") &&
               submission_record["record_kind"] == "evaluator_submission" &&
               submission_record["task_id"] == task_record["task_id"] &&
               submission_record["task_revision_id"] == task_record["task_revision_id"]
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluator submission evidence must exact-bind the evaluator Attempt and task revision",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.evaluator_submission_record_id"
          )
        end
        evidence_by_id = { submission_record.fetch("evidence_record_id") => submission_record }
        all_refs = findings.flat_map { |finding| finding.fetch("source_evidence_record_refs") } +
          Array(evaluation.dig("subject", "evidence_record_refs")).map { |ref| ref["evidence_record_id"] } +
          Array(evaluation.dig("coverage", "evidence_record_refs")) +
          evaluation.fetch("quality_question_answers").flat_map { |answer| answer.fetch("evidence_record_refs") } +
          evaluation.fetch("acceptance_results").flat_map { |result| result.fetch("evidence_record_refs") }
        all_refs.uniq.each do |record_id|
          next if evidence_by_id.key?(record_id)

          resolved = cached_evidence(cache, record_id, authority, runtime, lifecycle)
            .fetch("evidence_record")
          unless resolved["task_id"] == task_record["task_id"] &&
                 resolved["task_revision_id"] == task_record["task_revision_id"]
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "evidence refs must stay within the exact subject task revision",
              path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}"
            )
          end
          evidence_by_id[record_id] = resolved
        end
        [task, submission, evidence_by_id, control]
      end

      # Every evaluation/finding evidence ref must resolve to an accepted
      # EvidenceStore record (already collected), and finding source refs
      # must stay inside the evaluation subject/submission evidence.
      def validate_evidence_closure!(findings, evaluation, submission, evidence_by_id)
        subject_ids = Array(evaluation.dig("subject", "evidence_record_refs")).map do |ref|
          ref["evidence_record_id"]
        end
        allowed = (subject_ids + [submission.fetch("evidence_record").fetch("evidence_record_id")]).uniq
        findings.each do |finding|
          source = Array(finding.fetch("source_evidence_record_refs"))
          unless source.any? && source.all? { |id| evidence_by_id.key?(id) } &&
                 source.all? { |id| allowed.include?(id) }
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "Finding source evidence must resolve through the evaluation subject or submission",
              path: "gate_facts_store.findings.#{finding["finding_id"]}"
            )
          end
        end
      end

      # The real supersession ancestors from the already-verified prefix.
      # Missing/cyclic ancestry cannot be repaired by a semantic projection.
      def evaluation_relation_payloads(existing, evaluation)
        by_id = existing.each_with_object({}) do |candidate, index|
          accepted = candidate["gate_evaluation"]
          index[accepted["gate_evaluation_id"]] = candidate if accepted.is_a?(Hash)
        end
        relation = []
        seen = []
        cursor = evaluation["supersedes_gate_evaluation_id"]
        while cursor
          ancestor = by_id[cursor]
          unless ancestor && !seen.include?(cursor)
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "GateEvaluation supersession ancestry is missing or cyclic",
              path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.supersedes_gate_evaluation_id"
            )
          end
          relation << ancestor
          seen << cursor
          cursor = ancestor.dig("gate_evaluation", "supersedes_gate_evaluation_id")
        end
        relation.reverse
      end

      def evaluation_evidence_ids(evaluation, findings)
        ([evaluation["evaluator_submission_record_id"]] +
          Array(evaluation.dig("subject", "evidence_record_refs")).map do |ref|
            ref.is_a?(Hash) ? ref["evidence_record_id"] : nil
          end + Array(evaluation.dig("coverage", "evidence_record_refs")) +
          Array(evaluation["quality_question_answers"]).flat_map do |answer|
            answer.fetch("evidence_record_refs")
          end + Array(evaluation["acceptance_results"]).flat_map do |result|
            result.fetch("evidence_record_refs")
          end + Array(findings).flat_map do |finding|
            Array(finding["source_evidence_record_refs"])
          end).compact.uniq
      end

      def evaluation_evidence_by_id(evaluation, findings, cache, authority, runtime, lifecycle)
        evaluation_evidence_ids(evaluation, findings).each_with_object({}) do |record_id, records|
          records[record_id] = cached_evidence(cache, record_id, authority, runtime, lifecycle)
            .fetch("evidence_record")
        end
      end

      # Exact own-snapshot proof shared by fresh acceptance and replay.
      # Relation-bundle subject_stale is tolerated only after this succeeds.
      def prove_evaluation_subject!(evaluation, findings, task, submission,
                                    evidence_by_id, cache)
        requirement = Array(task.fetch("all_gate_requirements")).find do |candidate|
          candidate["gate_requirement_id"] == evaluation["gate_requirement_id"] &&
            candidate["content_digest"] == evaluation["gate_requirement_content_digest"]
        end
        expected = requirement && EvaluationSubject.select(
          gate_requirement: requirement,
          task_revision: task.fetch("task"),
          work_units: task.fetch("all_work_units"),
          attempts: latest_attempts(cached_control_records(cache)).values,
          evidence_records: evidence_by_id.values,
          repository_snapshot: submission.fetch("repository_snapshot"),
          code_surface: submission.fetch("code_surface")
        )
        return if expected && EvaluationSubject.same?(expected, evaluation["subject"])

        raise ContractError.new(
          "gate_facts_acceptance_invalid",
          "GateEvaluation subject is not exact under its own frozen snapshot and evidence closure",
          path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.subject"
        )
      rescue ContractError => error
        raise error if error.code == "gate_facts_acceptance_invalid"

        raise ContractError.new(
          "gate_facts_acceptance_invalid",
          "GateEvaluation own-snapshot subject proof failed: #{error.message}",
          path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.subject"
        )
      end

      # The deterministic contract bundle: marker protocol root, the policy
      # set accepted at the evaluation's commit (the frozen pin's ancestor
      # chain for historical facts, the full accepted set for current
      # facts), the exact TaskRevision facts, the evaluator control lineage,
      # the accepted evidence, and the accepted gate facts.
      def assemble_bundle(marker, policy, task, submission, evidence_by_id,
                          payload, control, authority, runtime, lifecycle,
                          relation_evaluations: [], relation_findings: [])
        pin = payload.fetch("policy_pin")
        policies, policy_assertions = bundle_policy_set(policy, pin)
        snapshot = submission.fetch("repository_snapshot")
        enriched = enriched_task_facts(task, authority)
        bundle = {
          "schema_version" => "orbit-v2-contract-bundle-v1",
          "protocol_epoch" => "orbit-v2",
          "protocol_root" => marker,
          "authority_assertions" => policy_assertions + control.fetch("assertions") +
            enriched.fetch("all_authority_assertions"),
          "authorization_records" => enriched.fetch("all_authorization_records"),
          "project_policy_revisions" => policies,
          "task_revisions" => task.fetch("task_revisions"),
          "gate_requirements" => task.fetch("all_gate_requirements"),
          "work_units" => task.fetch("all_work_units"),
          "change_theses" => task.fetch("all_change_theses"),
          "logical_leads" => [task.fetch("logical_lead")],
          "lead_sessions" => control.fetch("sessions"),
          "control_registries" => control.fetch("registries"),
          "lead_checkpoints" => control.fetch("checkpoints"),
          "agent_instances" => control.fetch("agents"),
          "work_unit_attempts" => control.fetch("attempts"),
          "rule_resolution_artifacts" => control.fetch("resolutions"),
          "evidence_records" => evidence_by_id.values,
          "gate_evaluations" => relation_evaluations + [payload.fetch("gate_evaluation")],
          "findings" => relation_findings + payload.fetch("findings"),
          "finding_resolutions" => [],
          "repository_snapshot" => snapshot,
          "code_surface" => submission.fetch("code_surface")
        }
        bundle
      end

      # The bundle policy set for one evaluation: the full accepted set
      # when the frozen pin is the current active policy, else the frozen
      # pin ancestor chain (historical facts are never reinterpreted by a
      # later rotation).
      def bundle_policy_set(policy, pin)
        active = policy.fetch("active_policy")
        if pin["policy_revision_id"] == active["policy_revision_id"] &&
           pin["content_digest"] == active["content_digest"]
          [policy.fetch("accepted_policies"), policy.fetch("accepted_assertions")]
        else
          policies = ancestor_policies(policy.fetch("accepted_policies"), pin)
          assertions = policy.fetch("accepted_assertions").select do |assertion|
            policies.any? { |candidate| candidate["authorization_source_ref"] == assertion["assertion_id"] }
          end
          [policies, assertions]
        end
      end

      def ancestor_policies(accepted, pin)
        by_id = accepted.to_h { |policy| [policy["policy_revision_id"], policy] }
        chain = []
        cursor = by_id[pin["policy_revision_id"]]
        while cursor
          chain << cursor
          parent = cursor["parent_policy_revision_id"]
          cursor = parent && by_id[parent]
        end
        return [by_id[pin["policy_revision_id"]]] if chain.empty?

        chain.reverse
      end

      # Store-owned acceptance chronology, authoritative E2E order:
      # evaluator Attempt started -> submission evidence accepted ->
      # GateEvaluation accepted -> (later) terminal evaluator Attempt.
      # Replay requires started_at <= submission_at <= evaluation acceptance,
      # and when the evaluator attempt is already terminal the evaluation
      # acceptance must strictly precede the terminal event. A historical
      # (non-active pin) evaluation additionally requires the evaluator
      # Attempt to be TERMINAL and submission/evaluation/terminal ALL
      # strictly before the first successor policy issuance. This validates
      # the controlled store's declared chronology; the clock is not an
      # independent signature over arbitrary direct file rewrites.
      # Chronology inputs are store-stamped canonical timestamps; a
      # malformed value is a store-internal failure and must surface as a
      # gate ContractError, never a raw ArgumentError/TypeError leaking
      # from the caller-supplied bytes.
      def parse_gate_time!(value, path)
        Time.iso8601(value)
      rescue ArgumentError, TypeError
        raise ContractError.new(
          "gate_facts_acceptance_invalid",
          "chronology timestamp is not a valid ISO-8601 time",
          path: "gate_facts_store.#{path}"
        )
      end

      def validate_acceptance_chronology!(payload, pin, policy, submission, fresh,
                                   authority, runtime, lifecycle, cache)
        evaluation_id = payload.fetch("gate_evaluation").fetch("gate_evaluation_id")
        accepted_at = parse_gate_time!(payload.fetch("acceptance_recorded_at"),
          "#{evaluation_id}.acceptance_recorded_at")
        submission_at = parse_gate_time!(
          submission.fetch("evidence_record").fetch("acceptance_recorded_at"),
          "#{evaluation_id}.evaluator_submission_record_id")
        evaluation = payload.fetch("gate_evaluation")
        evaluator = latest_attempts(cached_control_records(cache))[
          evaluation.fetch("evaluator_attempt_id")
        ]
        unless evaluator
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluator Attempt does not exist in the accepted control lineage",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.evaluator_attempt_id"
          )
        end
        terminal = Array(evaluator["events"]).last
        terminal_at = terminal &&
          %w[AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled AttemptSuperseded]
            .include?(terminal["event_type"]) &&
          parse_gate_time!(terminal["ended_at"], "#{evaluation_id}.evaluator.terminal")
        started_at = parse_gate_time!(evaluator.dig("events", 0, "started_at"),
          "#{evaluation_id}.evaluator.started_at")
        unless started_at <= submission_at && submission_at <= accepted_at
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "GateEvaluation acceptance must follow the evaluator Attempt and its submission evidence",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.acceptance_recorded_at"
          )
        end
        if terminal_at
          # A NEW write is unconditionally rejected once the same-locked
          # ControlStore snapshot shows the evaluator Attempt terminal: a
          # back-dated or configured clock can never retro-fill a
          # GateEvaluation after the round closed. Only replay of a STORED
          # payload (fresh=false) may prove its frozen acceptance predates
          # the later terminal event.
          if fresh
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "a new GateEvaluation cannot be written after its evaluator Attempt terminalized",
              path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.acceptance_recorded_at"
            )
          end
          unless accepted_at < terminal_at
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "stored GateEvaluation acceptance must strictly precede the evaluator terminal",
              path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.acceptance_recorded_at"
            )
          end
        end
        return unless fresh == false

        active = policy.fetch("active_policy")
        historical = pin["policy_revision_id"] != active["policy_revision_id"] ||
          pin["content_digest"] != active["content_digest"]
        return unless historical

        successor = policy.fetch("accepted_policies").find do |candidate|
          candidate["parent_policy_revision_id"] == pin["policy_revision_id"]
        end
        assertion = successor && policy.fetch("accepted_assertions").find do |candidate|
          candidate["assertion_id"] == successor["authorization_source_ref"]
        end
        cutoff = assertion && parse_gate_time!(
          assertion.dig("policy_issuance_envelope", "issued_at"),
          "#{evaluation_id}.policy_issuance_cutoff")
        unless terminal_at && cutoff && accepted_at < cutoff &&
               submission_at < cutoff && terminal_at < cutoff
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "historical GateEvaluation must have been accepted strictly before its policy replacement",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}.acceptance_recorded_at"
          )
        end
      rescue ArgumentError, TypeError, NoMethodError
        raise ContractError.new(
          "gate_facts_acceptance_invalid",
          "GateEvaluation acceptance chronology is invalid",
          path: "gate_facts_store"
        )
      end

      def same_facts?(existing, candidate)
        stored = existing.reject { |key, _value| STORE_OWNED_KEYS.include?(key) }
        proposed = candidate.reject { |key, _value| STORE_OWNED_KEYS.include?(key) }
        canonical_equal?(stored, proposed)
      end

      def clock_time!
        value = @clock.call
        return value if value.is_a?(Time)

        raise ContractError.new(
          "gate_facts_argument_invalid",
          "configured clock must return Time",
          path: "gate_facts_store.clock"
        )
      rescue StandardError => error
        raise ContractError.new(
          "gate_facts_argument_invalid",
          "configured clock failed: #{error.message}",
          path: "gate_facts_store.clock",
          details: { "cause" => error.class.name }
        )
      end

      def validate_resolution_snapshot!(records, candidate, resolution_id,
                                        authority, runtime, lifecycle)
        marker, policy = marker_and_policy(authority)
        _cutoff, cache = cutoff_snapshot_locked(
          authority_verifier: authority,
          runtime_identity_verifier: runtime,
          lifecycle_verifier: lifecycle,
          include_operation_cache: true
        )
        verified = verify_existing!(records, marker, policy, authority, runtime, lifecycle,
          cache: cache)
        existing = verified.find do |payload|
          payload.key?("finding_resolution") &&
            payload.fetch("finding_resolution").fetch("finding_resolution_id") == resolution_id
        end
        if existing
          return :idempotent if same_facts?(existing, candidate)

          raise ContractError.new(
            "gate_facts_reuse",
            "FindingResolution #{resolution_id} already exists with different content",
            path: "gate_facts_store.#{resolution_id}"
          )
        end
        seen = verified.each_with_object({}) do |payload, ids|
          if payload.key?("finding_resolution")
            resolution = payload.fetch("finding_resolution")
            ids[resolution.fetch("finding_resolution_id")] = resolution
          end
          payload.fetch("findings", []).each do |finding|
            ids[finding.fetch("finding_id")] = finding
          end
        end
        validate_payload!(candidate, marker, policy, authority, runtime, lifecycle, seen,
          verified, fresh: true, cache: cache)
        nil
      rescue ContractError => error
        raise error if %w[gate_facts_reuse gate_facts_unpinned].include?(error.code)

        raise acceptance_invalid(error)
      end

      # Full validation of one FindingResolution transaction: exact source
      # Finding/evaluation, issuer Attempt + evaluator submission + rule,
      # accepted supporting EvidenceStore records, same task/gate/subject/
      # policy, globally create-only linear per-finding lineage extending
      # the current tip, the frozen acceptance-time policy pin, and the
      # PUBLIC Validator closure over the complete accepted gate facts.
      # addressed/disproved require exact authority and evidence closure;
      # waived requires an accepted active-policy finding.waive
      # AuthorizationRecord.
      def validate_resolution_payload!(payload, marker, policy, authority, runtime, lifecycle,
                                       seen, existing, fresh:, cache:)
        resolution = payload.fetch("finding_resolution")
        pin = payload.fetch("policy_pin")
        SchemaCatalog.check!("finding_resolution", resolution)
        unless resolution["content_digest"] == CanonicalJSON.content_digest(resolution) &&
               resolution["protocol_epoch"] == "orbit-v2" &&
               resolution["project_id"] == marker["project_id"] &&
               payload["acceptance_recorded_at"].is_a?(String) &&
               pin.keys.sort == %w[content_digest policy_revision_id]
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "FindingResolution digest, epoch, project, or pin binding is invalid",
            path: "gate_facts_store.#{resolution["finding_resolution_id"]}"
          )
        end
        active = policy.fetch("active_policy")
        accepted = policy.fetch("accepted_policies")
        unless accepted.any? do |candidate|
                 candidate["policy_revision_id"] == pin["policy_revision_id"] &&
                   candidate["content_digest"] == pin["content_digest"]
               end
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "policy_pin must exact-bind an accepted policy revision",
            path: "gate_facts_store.#{resolution["finding_resolution_id"]}.policy_pin"
          )
        end
        if fresh &&
           (pin["policy_revision_id"] != active["policy_revision_id"] ||
            pin["content_digest"] != active["content_digest"])
          raise ContractError.new(
            "gate_facts_authority_stale",
            "a new FindingResolution must pin the currently active policy",
            path: "gate_facts_store.#{resolution["finding_resolution_id"]}.policy_pin"
          )
        end

        # Typed same-snapshot indexes: resolutions and findings are kept
        # apart so lineage/tip derivation never confuses the two namespaces.
        resolutions = existing.each_with_object({}) do |entry, map|
          accepted_resolution = entry["finding_resolution"]
          if accepted_resolution
            map[accepted_resolution.fetch("finding_resolution_id")] = accepted_resolution
          end
        end
        findings = existing.flat_map { |entry| entry.fetch("findings", []) }
        evaluations = existing.map { |entry| entry["gate_evaluation"] }.compact
        acceptance_by_evaluation = existing.each_with_object({}) do |entry, map|
          evaluation = entry["gate_evaluation"]
          map[evaluation.fetch("gate_evaluation_id")] = entry.fetch("acceptance_recorded_at") if evaluation
        end

        resolution_id = resolution.fetch("finding_resolution_id")
        if resolutions.key?(resolution_id)
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "finding resolution id #{resolution_id} is globally create-only and reused",
            path: "gate_facts_store.#{resolution_id}"
          )
        end
        parent_id = resolution["supersedes_finding_resolution_id"]
        prior = resolutions.values.select { |r| r["finding_id"] == resolution.fetch("finding_id") }
        if prior.empty?
          unless parent_id.nil?
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "first FindingResolution of a Finding must carry no supersedes ref",
              path: "gate_facts_store.#{resolution_id}.supersedes_finding_resolution_id"
            )
          end
        elsif parent_id
          parent = resolutions[parent_id]
          tip = latest_resolution_tip(resolutions, resolution.fetch("finding_id"))
          unless parent && parent["finding_id"] == resolution["finding_id"] &&
                 parent_id != resolution_id && tip == parent_id
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "FindingResolution lineage must exact-extend the current tip of its Finding",
              path: "gate_facts_store.#{resolution_id}.supersedes_finding_resolution_id"
            )
          end
        else
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "FindingResolution lineage must exact-extend the current tip of its Finding",
            path: "gate_facts_store.#{resolution_id}.supersedes_finding_resolution_id"
          )
        end

        source = findings.find { |finding| finding["finding_id"] == resolution.fetch("finding_id") }
        source_evaluation = source &&
          evaluations.find { |evaluation| evaluation["gate_evaluation_id"] == source["gate_evaluation_id"] }
        unless source && source_evaluation
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "FindingResolution must exact-bind an accepted Finding and its GateEvaluation",
            path: "gate_facts_store.#{resolution_id}.finding_id"
          )
        end
        # The exact task/gate lineage derives from the source GateEvaluation:
        # evaluator Attempt (control records) -> task identity, subject
        # TaskRevision ref -> the exact accepted TaskRevision.
        records = cached_control_records(cache)
        latest = latest_attempts(records)
        evaluator = latest[source_evaluation.fetch("evaluator_attempt_id")]
        unless evaluator
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "source GateEvaluation evaluator Attempt does not resolve in the control lineage",
            path: "gate_facts_store.#{resolution_id}.finding_id"
          )
        end
        task = cached_task(cache, evaluator.fetch("task_id"),
          source_evaluation.dig("subject", "task_revision_ref", "task_revision_id"), authority)
        task_record = task.fetch("task")
        requirement = Array(task["gate_requirements"]).find do |candidate|
          candidate["gate_requirement_id"] == source_evaluation.fetch("gate_requirement_id")
        end
        unless requirement &&
               requirement["content_digest"] == source_evaluation.fetch("gate_requirement_content_digest")
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "source GateEvaluation must exact-pin an owned GateRequirement of its TaskRevision",
            path: "gate_facts_store.#{resolution_id}.finding_id"
          )
        end

        source_accepted_at = acceptance_by_evaluation[source_evaluation.fetch("gate_evaluation_id")]
        accepted_at = parse_gate_time!(payload.fetch("acceptance_recorded_at"),
          "#{resolution_id}.acceptance_recorded_at")
        unless source_accepted_at.is_a?(String) &&
               parse_gate_time!(source_accepted_at, "#{resolution_id}.source_acceptance") <= accepted_at
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "FindingResolution acceptance cannot precede its source Finding",
            path: "gate_facts_store.#{resolution_id}.acceptance_recorded_at"
          )
        end
        if %w[addressed disproved].include?(resolution["resolution"])
          resolving_at = acceptance_by_evaluation[
            resolution.dig("resolving_gate_evaluation_ref", "gate_evaluation_id")]
          unless resolving_at.is_a?(String) &&
                 parse_gate_time!(resolving_at, "#{resolution_id}.resolving_acceptance") <= accepted_at
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "FindingResolution acceptance cannot precede its resolving GateEvaluation",
              path: "gate_facts_store.#{resolution_id}.acceptance_recorded_at"
            )
          end
          submission = resolution["issuer_submission_record_id"] &&
            cached_evidence(cache, resolution["issuer_submission_record_id"], authority,
              runtime, lifecycle)
          submission_at = submission && submission.dig("evidence_record", "acceptance_recorded_at")
          unless submission_at.is_a?(String) &&
                 parse_gate_time!(submission_at, "#{resolution_id}.issuer_submission") <= accepted_at
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "FindingResolution acceptance cannot precede its issuer submission",
              path: "gate_facts_store.#{resolution_id}.acceptance_recorded_at"
            )
          end
        end
        if fresh == false
          active = policy.fetch("active_policy")
          historical = pin["policy_revision_id"] != active["policy_revision_id"] ||
            pin["content_digest"] != active["content_digest"]
          if historical
            # A directly written post-rotation old-pin resolution must fail:
            # replay of a STORED resolution proves its acceptance strictly
            # predates the first successor policy issuance of its frozen pin.
            successor = accepted.find do |candidate|
              candidate["parent_policy_revision_id"] == pin["policy_revision_id"]
            end
            successor_assertion = successor && policy.fetch("accepted_assertions").find do |candidate|
              candidate["assertion_id"] == successor["authorization_source_ref"]
            end
            cutoff = successor_assertion && parse_gate_time!(
              successor_assertion.dig("policy_issuance_envelope", "issued_at"),
              "#{resolution_id}.policy_issuance_cutoff")
            unless cutoff && accepted_at < cutoff
              raise ContractError.new(
                "gate_facts_acceptance_invalid",
                "historical FindingResolution must have been accepted strictly before its policy replacement",
                path: "gate_facts_store.#{resolution_id}.acceptance_recorded_at"
              )
            end
          end
        end

        issuer = latest[resolution["issuer_attempt_id"]]
        submission = resolution["issuer_submission_record_id"] &&
          cached_evidence(cache, resolution["issuer_submission_record_id"], authority,
            runtime, lifecycle).fetch("evidence_record")
        if %w[addressed disproved].include?(resolution["resolution"])
          unless issuer && submission &&
                 submission["attempt_id"] == issuer["attempt_id"] &&
                 submission["record_kind"] == "evaluator_submission" &&
                 issuer["task_id"] == task_record["task_id"] &&
                 issuer["task_revision_id"] == task_record["task_revision_id"] &&
                 %w[review test adjudication].include?(issuer.dig("events", 0, "assignment", "purpose")) &&
                 Array(resolution["supporting_record_refs"]).any?
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "addressed/disproved resolution requires an exact issuer Attempt, submission, and supporting evidence",
              path: "gate_facts_store.#{resolution_id}"
            )
          end
          Array(resolution["supporting_record_refs"]).each do |record_id|
            resolved = cached_evidence(cache, record_id, authority, runtime, lifecycle)
              .fetch("evidence_record")
            unless resolved["task_id"] == task_record["task_id"] &&
                   resolved["task_revision_id"] == task_record["task_revision_id"]
              raise ContractError.new(
                "gate_facts_acceptance_invalid",
                "resolution supporting evidence must stay within the source task revision",
                path: "gate_facts_store.#{resolution_id}.supporting_record_refs"
              )
            end
          end
        elsif resolution["resolution"] == "waived"
          # The authorization is ALREADY an accepted fact of the source
          # task's authoritative TaskStore revision: the resolution only
          # references the accepted record by id, and the record plus its
          # assertion must exact-bind (canonical equality) the accepted
          # revision facts, with the active-policy finding.waive grant.
          record_id = resolution["authorization_record_ref"]
          unless Array(resolution["supporting_record_refs"]).empty?
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "waived resolution must carry no supporting evidence",
              path: "gate_facts_store.#{resolution_id}"
            )
          end
          # The authorization is an ALREADY accepted append-only
          # TaskRevision-scoped record (TaskStore authorize seam, provider-
          # verified under policy -> task locks, exact-binding the Finding);
          # the resolution only references it and never co-commits authority.
          accepted_authorizations = begin
            TaskStore.new(active_root: @active_root).authorizations(
              task_id: task_record.fetch("task_id"),
              task_revision_id: task_record.fetch("task_revision_id"),
              authority_verifier: authority
            )
          rescue ContractError
            []
          end
          entry = record_id && accepted_authorizations.find do |candidate|
            candidate["authorization"]["authorization_record_id"] == record_id
          end
          waiver = entry && entry["authorization"]
          waiver_assertion = entry && entry["assertion"]
          unless waiver
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "waived resolution must reference an accepted finding.waive AuthorizationRecord",
              path: "gate_facts_store.#{resolution_id}.authorization_record_ref"
            )
          end

          # Historical replay is pinned: the finding.waive grant and the
          # record's policy binding are evaluated against the payload's own
          # frozen policy_pin revision (accepted), never the current active
          # policy, so an accepted waived resolution stays exact-readable
          # after a rotation; fresh writes already require pin == active.
          pinned_revision = accepted.find do |candidate|
            candidate["policy_revision_id"] == pin["policy_revision_id"] &&
              candidate["content_digest"] == pin["content_digest"]
          end
          grant = unique_policy_grant(pinned_revision, "finding.waive")
          begin
            authority.verify!(waiver_assertion)
          rescue ContractError => error
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "finding.waive assertion was not provider-verified: #{error.code}",
              path: "gate_facts_store.#{resolution_id}.authorization_assertion"
            )
          end
          unless waiver["action"] == "finding.waive" &&
                 waiver["project_policy_revision_id"] == pinned_revision["policy_revision_id"] &&
                 waiver["subject_ref"] == source.fetch("finding_id") &&
                 waiver_assertion.is_a?(Hash) &&
                 waiver["authorization_source_ref"] == waiver_assertion["assertion_id"] &&
                 waiver["authorization_assertion_digest"] == waiver_assertion["assertion_digest"] &&
                 waiver_assertion["authority_scope_ref"] == source.fetch("finding_id") &&
                 %w[user control_plane].include?(waiver_assertion["issuer_kind"]) &&
                 Array(waiver_assertion["grants"]).include?("finding.waive") &&
                 grant.is_a?(Hash) &&
                 Array(waiver_assertion["grants"]).include?(grant["required_external_grant"])
            raise ContractError.new(
              "gate_facts_acceptance_invalid",
              "waived resolution must exact-bind the accepted active-policy finding.waive AuthorizationRecord",
              path: "gate_facts_store.#{resolution_id}.authorization_record_ref"
            )
          end
        else
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "FindingResolution type is not allowed",
            path: "gate_facts_store.#{resolution_id}.resolution"
          )
        end

        # The exact causal resolution lineage only: source + resolving
        # evaluations and their supersession ancestors, the Findings they
        # own, and this Finding's resolution ancestors. Unrelated gate facts
        # of the same task never enter or reinterpret this bundle.
        control_id = evaluator.fetch("lead_control_id")
        evaluation_by_id = evaluations.to_h do |accepted_evaluation|
          [accepted_evaluation.fetch("gate_evaluation_id"), accepted_evaluation]
        end
        wanted_evaluation_ids = [
          resolution.dig("source_gate_evaluation_ref", "gate_evaluation_id"),
          resolution.dig("resolving_gate_evaluation_ref", "gate_evaluation_id")
        ].compact
        bundle_resolutions = resolutions.values.select do |existing_resolution|
          existing_resolution["finding_id"] == resolution["finding_id"]
        end
        bundle_resolutions.each do |existing_resolution|
          wanted_evaluation_ids << existing_resolution.dig(
            "source_gate_evaluation_ref", "gate_evaluation_id"
          )
          wanted_evaluation_ids << existing_resolution.dig(
            "resolving_gate_evaluation_ref", "gate_evaluation_id"
          )
        end
        wanted_evaluation_ids.compact!
        wanted_evaluation_ids.uniq!
        if wanted_evaluation_ids.empty?
          # waived carries no caller-supplied source refs by schema: seed
          # the causal slice from the accepted source Finding and its owning
          # GateEvaluation (plus ancestors) so the public Validator can
          # resolve the named finding without any co-committed authority.
          source_for_waiver = findings.find do |finding|
            finding["finding_id"] == resolution.fetch("finding_id")
          end
          if source_for_waiver
            wanted_evaluation_ids << source_for_waiver["gate_evaluation_id"]
          end
        end
        cursor = 0
        while cursor < wanted_evaluation_ids.length
          accepted_evaluation = evaluation_by_id[wanted_evaluation_ids[cursor]]
          parent_id = accepted_evaluation && accepted_evaluation["supersedes_gate_evaluation_id"]
          wanted_evaluation_ids << parent_id if parent_id && !wanted_evaluation_ids.include?(parent_id)
          cursor += 1
        end
        evaluations_for_bundle = evaluations.select do |accepted_evaluation|
          wanted_evaluation_ids.include?(accepted_evaluation["gate_evaluation_id"])
        end
        evaluation_ids = evaluations_for_bundle.map { |accepted_evaluation| accepted_evaluation.fetch("gate_evaluation_id") }
        finding_ids = evaluations_for_bundle.flat_map { |accepted_evaluation| Array(accepted_evaluation["finding_refs"]) }
        bundle_findings = findings.select do |finding|
          evaluation_ids.include?(finding["gate_evaluation_id"]) && finding_ids.include?(finding["finding_id"])
        end
        policies, policy_assertions = bundle_policy_set(policy, pin)
        control_facts = control_facts(control_id, policies, authority, runtime, lifecycle, cache)
        # verify_existing! already replayed every accepted evaluation through
        # the shared own-snapshot subject proof and its real relation bundle
        # in this same operation. The resolution bundle below therefore needs
        # no second, subtly different per-evaluation validation loop.
        validator = Orbit::V2::Validator.new(
          project_root: @active_root,
          authority_verifier: authority,
          lifecycle_verifier: lifecycle,
          runtime_identity_verifier: runtime
        )
        bundle = assemble_resolution_bundle(marker, policies, policy_assertions, control_facts,
          task, bundle_findings, evaluations_for_bundle, bundle_resolutions, resolution,
          issuer, authority, runtime, lifecycle, cache, waiver_entry: entry)
        validator = Orbit::V2::Validator.new(
          project_root: @active_root,
          authority_verifier: authority,
          lifecycle_verifier: lifecycle,
          runtime_identity_verifier: runtime
        )
        errors = validator.validate(bundle)
        # The relation bundle anchors ONE frozen repository snapshot; a
        # lineage evaluation whose subject is current under ITS OWN frozen
        # closure (already proven per-evaluation above) may legitimately be
        # subject-stale under the bundle anchor. The exact
        # ProjectionPrimitives predicate tolerates ONLY that
        # gate_evaluations.<id>.subject currentness — never stale gate
        # digest/policy, shape, authority, provenance, independence, or
        # resolution errors. No evaluation/ref/digest is ever mutated.
        unless errors.all? { |error| Orbit::V2::ProjectionPrimitives.historical_stale_evaluation_error?(error) }
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "assembled snapshot fails the Validator invariants: " \
              "#{errors.map(&:code).uniq.join(', ')}",
            path: "gate_facts_store.#{resolution_id}"
          )
        end
        true
      end

      def latest_resolution_tip(resolutions, finding_id)
        by_id = resolutions
        tips = by_id.values.select do |resolution|
          !by_id.values.any? do |candidate|
            candidate["supersedes_finding_resolution_id"] == resolution["finding_resolution_id"]
          end
        end
        candidates = tips.select { |resolution| resolution["finding_id"] == finding_id }
        candidates.length == 1 ? candidates.first["finding_resolution_id"] : nil
      end

      def assemble_resolution_bundle(marker, policies, policy_assertions, control,
                                     task, findings, evaluations, resolutions, resolution,
                                     issuer, authority, runtime, lifecycle, cache,
                                     waiver_entry: nil)
        submission = resolution["issuer_submission_record_id"] &&
          cached_evidence(cache, resolution["issuer_submission_record_id"], authority,
            runtime, lifecycle)
        # The public bundle carries the complete resolution lineage, so its
        # evidence closure must do the same. A waived successor has no own
        # evidence refs but must not make its addressed/disproved ancestor's
        # immutable proposal, support, or issuer submission disappear.
        refs = (resolutions + [resolution]).flat_map do |accepted_resolution|
          Array(accepted_resolution["supporting_record_refs"]) +
            [accepted_resolution["proposal_evidence_record_id"],
             accepted_resolution["issuer_submission_record_id"]]
        end
        refs.concat(evaluations.flat_map do |evaluation|
          [evaluation["evaluator_submission_record_id"]] +
            Array(evaluation.dig("subject", "evidence_record_refs")).map { |ref| ref["evidence_record_id"] } +
            Array(evaluation.dig("coverage", "evidence_record_refs")) +
            Array(evaluation["quality_question_answers"]).flat_map { |answer| answer.fetch("evidence_record_refs") } +
            Array(evaluation["acceptance_results"]).flat_map { |result| result.fetch("evidence_record_refs") }
        end)
        refs.concat(findings.flat_map { |finding| Array(finding["source_evidence_record_refs"]) })
        evidence_by_id = {}
        refs.compact.uniq.each do |record_id|
          next if evidence_by_id.key?(record_id)

          evidence_by_id[record_id] = cached_evidence(cache, record_id, authority,
            runtime, lifecycle).fetch("evidence_record")
        end
        enriched = enriched_task_facts(task, authority)
        # One public bundle models ONE repository snapshot: the historical
        # SOURCE evaluation keeps its own frozen closure (snapshot, code
        # surface, evidence), and the RESOLVING evaluation is projected onto
        # the same frozen state (its semantics were already re-verified
        # against its own closure above), so no union snapshot ever
        # reinterprets the historical evaluation.
        source_ref = resolution["source_gate_evaluation_ref"]
        source_evaluation = if source_ref.is_a?(Hash)
                              evaluations.find do |accepted_evaluation|
                                accepted_evaluation["gate_evaluation_id"] == source_ref["gate_evaluation_id"] &&
                                  accepted_evaluation["content_digest"] == source_ref["content_digest"]
                              end
                            else
                              # waived schema forbids source refs: the anchor
                              # is the accepted Finding's owning evaluation.
                              owning = findings.find do |finding|
                                finding["finding_id"] == resolution.fetch("finding_id")
                              end
                              owning && evaluations.find do |accepted_evaluation|
                                accepted_evaluation["gate_evaluation_id"] == owning["gate_evaluation_id"]
                              end
                            end
        source_submission = source_evaluation && cached_evidence(cache,
          source_evaluation["evaluator_submission_record_id"], authority,
          runtime, lifecycle)
        snapshot = source_submission ? source_submission.fetch("repository_snapshot") :
          { "kind" => "git", "commit_sha" => "a" * 40, "tree_digest" => "sha256:#{'a' * 64}" }
        code_surface = source_submission ? source_submission.fetch("code_surface") :
          { "kind" => "derived_code_surface", "derivation_version" => "orbit-code-surface-v1",
            "repository_tree_digest" => snapshot["tree_digest"],
            "code_surface_digest" => "sha256:#{'a' * 64}", "paths" => [] }
        {
          "schema_version" => "orbit-v2-contract-bundle-v1",
          "protocol_epoch" => "orbit-v2",
          "protocol_root" => marker,
          "authority_assertions" => policy_assertions + control.fetch("assertions") +
            enriched.fetch("all_authority_assertions") +
            (waiver_entry ? [waiver_entry.fetch("assertion")] : []),
          "authorization_records" => enriched.fetch("all_authorization_records") +
            (waiver_entry ? [waiver_entry.fetch("authorization")] : []),
          "project_policy_revisions" => policies,
          "task_revisions" => task.fetch("task_revisions"),
          "gate_requirements" => task.fetch("all_gate_requirements"),
          "work_units" => task.fetch("all_work_units"),
          "change_theses" => task.fetch("all_change_theses"),
          "logical_leads" => [task.fetch("logical_lead")],
          "lead_sessions" => control.fetch("sessions"),
          "control_registries" => control.fetch("registries"),
          "lead_checkpoints" => control.fetch("checkpoints"),
          "agent_instances" => control.fetch("agents"),
          "work_unit_attempts" => control.fetch("attempts"),
          "rule_resolution_artifacts" => control.fetch("resolutions"),
          "evidence_records" => evidence_by_id.values,
          "gate_evaluations" => evaluations,
          "findings" => findings,
          "finding_resolutions" => resolutions + [resolution],
          "repository_snapshot" => snapshot,
          "code_surface" => code_surface
        }
      end

      # The unique policy grant for one action (same rule as the
      # ControlStore/PolicyStore writer paths): an action with anything
      # other than exactly one grant can never authorize a writer.
      def unique_policy_grant(policy, action)
        matches = Array(policy["authority_grants"]).select do |grant|
          grant.is_a?(Hash) && grant["action"] == action
        end
        matches.length == 1 ? matches.first : nil
      end

      def enriched_task_facts(task, authority)
        task_store = TaskStore.new(active_root: @active_root)
        resolved = task_store.resolve(
          task_id: task.fetch("task").fetch("task_id"),
          authority_verifier: authority
        ).fetch("task_revisions").flat_map do |revision|
          task_store.resolve(
            task_id: task.fetch("task").fetch("task_id"),
            task_revision_id: revision.fetch("task_revision_id"),
            authority_verifier: authority
          )
        end
        {
          "all_authorization_records" =>
            resolved.flat_map { |entry| entry.fetch("authorization_records") },
          "all_authority_assertions" =>
            resolved.flat_map { |entry| entry.fetch("authority_assertions") }
        }
      end

      # The control facts included in the bundle are filtered to the
      # checkpoint transactions whose checkpoint pins a policy revision of
      # the bundle policy set: a historical evaluation (frozen pin ancestor
      # chain) never drags in post-rotation control checkpoints, and a
      # current evaluation keeps the full lineage.
      def control_facts(control_id, policies, authority, runtime, lifecycle, cache)
        policy_ids = policies.map { |policy| policy["policy_revision_id"] }
        key = [control_id, policy_ids]
        return cache[:controls][key] if cache[:controls].key?(key)

        records = cached_control_records(cache)
        registries = []
        sessions = {}
        checkpoints = []
        assertions = []
        agents = {}
        attempts = {}
        resolutions = {}
        records.each do |tx|
          case tx.keys.sort
          when ControlStore::PAYLOAD_KEYS
            next unless tx.fetch("registry").fetch("lead_control_id") == control_id
            next unless policy_ids.include?(tx.dig("checkpoint", "project_policy_revision_ref", "policy_revision_id"))

            registries << tx.fetch("registry")
            session = tx.fetch("session")
            sessions[session.fetch("lead_session_id")] = session
            checkpoints << tx.fetch("checkpoint")
            assertions << tx.fetch("assertion")
            agent = tx.fetch("agent")
            agents[agent.fetch("agent_instance_id")] = agent
          when ControlStore::CHECKPOINT_PAYLOAD_KEYS
            next unless tx.fetch("checkpoint").fetch("lead_control_id") == control_id
            next unless policy_ids.include?(tx.dig("checkpoint", "project_policy_revision_ref", "policy_revision_id"))

            checkpoints << tx.fetch("checkpoint")
            assertions << tx.fetch("assertion")
          when ControlStore::SESSION_CHECKPOINT_PAYLOAD_KEYS
            next unless tx.fetch("checkpoint").fetch("lead_control_id") == control_id
            next unless policy_ids.include?(tx.dig("checkpoint", "project_policy_revision_ref", "policy_revision_id"))

            prior = tx.fetch("prior_session")
            session = tx.fetch("session")
            sessions[prior.fetch("lead_session_id")] = prior
            sessions[session.fetch("lead_session_id")] = session
            checkpoints << tx.fetch("checkpoint")
            assertions << tx.fetch("assertion")
            agent = tx.fetch("agent")
            agents[agent.fetch("agent_instance_id")] = agent
          when ControlStore::EXECUTION_PAYLOAD_KEYS
            next unless tx.fetch("dispatch_checkpoint").fetch("lead_control_id") == control_id
            next unless policy_ids.include?(tx.dig("dispatch_checkpoint", "project_policy_revision_ref", "policy_revision_id"))

            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
            checkpoints << tx.fetch("dispatch_checkpoint")
            checkpoints << tx.fetch("observation_checkpoint")
            assertions << tx.fetch("dispatch_assertion")
            assertions << tx.fetch("observation_assertion")
            worker = tx.fetch("worker_agent")
            agents[worker.fetch("agent_instance_id")] = worker
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
          when ControlStore::TERMINAL_PAYLOAD_KEYS
            next unless tx.fetch("checkpoint").fetch("lead_control_id") == control_id
            next unless policy_ids.include?(tx.dig("checkpoint", "project_policy_revision_ref", "policy_revision_id"))

            terminated = tx.fetch("attempt")
            attempts[terminated.fetch("attempt_id")] = terminated if attempts.key?(terminated.fetch("attempt_id"))
            successor = tx.fetch("successor_attempt")
            attempts[successor.fetch("attempt_id")] = successor
            checkpoints << tx.fetch("checkpoint")
            checkpoints << tx.fetch("observation_checkpoint")
            assertions << tx.fetch("assertion")
            assertions << tx.fetch("observation_assertion")
            worker = tx.fetch("worker_agent")
            agents[worker.fetch("agent_instance_id")] = worker
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
          end
        end
        cache[:controls][key] = {
          "registries" => registries,
          "sessions" => sessions.values,
          "checkpoints" => checkpoints,
          "assertions" => assertions,
          "agents" => agents.values,
          "attempts" => attempts.values,
          "resolutions" => resolutions.values
        }
      end

      def marker_and_policy(authority)
        marker = ActiveRoot.marker_for(
          @active_root,
          code: "gate_facts_unpinned",
          label: "gate_facts_store"
        )
        resolved = PolicyStore.new(active_root: @active_root).resolve(
          pinned_genesis_ref: marker.fetch("project_policy_genesis_ref"),
          authority_verifier: authority
        )
        unless resolved.dig("genesis_policy", "project_id") == marker["project_id"]
          raise ContractError.new(
            "gate_facts_unpinned",
            "policy lineage project does not match ProtocolRoot",
            path: "gate_facts_store"
          )
        end
        [marker, resolved]
      rescue ContractError => error
        raise error if error.code == "gate_facts_unpinned"

        raise ContractError.new(
          "gate_facts_unpinned",
          "pinned policy lineage does not resolve",
          path: "gate_facts_store",
          details: { "cause" => error.code, "message" => error.message }
        )
      end

      def verified_payloads!(evaluation_id, authority, runtime, lifecycle)
        unless evaluation_id.nil? || (evaluation_id.is_a?(String) &&
                                      Identifiers.valid?("gate_evaluation_id", evaluation_id))
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "gate_evaluation_id must be a stable evaluation identifier",
            path: "gate_facts_store.resolve"
          )
        end
        unless authority.respond_to?(:verify!) && runtime.respond_to?(:verify!) &&
               lifecycle.respond_to?(:verify!)
          raise ContractError.new(
            "gate_facts_argument_invalid",
            "resolve requires configured authority, runtime identity, and lifecycle verifiers",
            path: "gate_facts_store.resolve"
          )
        end
        policy_log = File.join(@active_root, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@active_root, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@active_root, ControlStore::CONTROL_TRANSACTIONS_FILE)
        evidence_log = File.join(@active_root, EvidenceStore::EVIDENCE_TRANSACTIONS_FILE)
        gate_log = File.join(@active_root, GATE_FACTS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
              DurableFile.with_exclusive_lock(evidence_log) do
                DurableFile.with_exclusive_lock(gate_log) do
                  marker, policy = marker_and_policy(authority)
                  verify_existing!(@log.records, marker, policy, authority, runtime, lifecycle)
                end
              end
            end
          end
        end
      end

      def acceptance_invalid(error)
        ContractError.new(
          "gate_facts_acceptance_invalid",
          "gate facts acceptance rejected: #{error.message}",
          path: "gate_facts_store",
          details: { "cause" => error.code }
        )
      end

      def lineage_invalid(message, index = nil)
        ContractError.new(
          "gate_facts_lineage_invalid",
          "gate facts store lineage is invalid: #{message}",
          path: "gate_facts_store",
          details: index.nil? ? nil : { "transaction_index" => index }
        )
      end

      def canonical_equal?(left, right)
        CanonicalJSON.dump(left) == CanonicalJSON.dump(right)
      end

      def deep_copy(value)
        JSON.parse(CanonicalJSON.dump(value))
      end
    end
  end
end
