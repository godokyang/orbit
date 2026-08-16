# frozen_string_literal: true

require "json"
require "time"

require_relative "active_root"
require_relative "canonical_json"
require_relative "control_store"
require_relative "durable_file"
require_relative "errors"
require_relative "evidence_store"
require_relative "identifiers"
require_relative "policy_store"
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
    # immutable TaskRevision. FindingResolution and the control
    # checkpoint observation/dispatch barrier remain deferred.
    class GateFactStore
      GATE_FACTS_FILE = "gate-facts.json".freeze
      PAYLOAD_KEYS = %w[acceptance_recorded_at findings gate_evaluation policy_pin].freeze
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
          payload.fetch("gate_evaluation").fetch("gate_evaluation_id") == gate_evaluation_id
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
        found = verified.flat_map { |payload| payload.fetch("findings") }.find do |finding|
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
        verified = verify_existing!(records, marker, policy, authority, runtime, lifecycle)
        existing = verified.find do |payload|
          payload.fetch("gate_evaluation").fetch("gate_evaluation_id") == evaluation_id
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
          payload.fetch("findings").each { |finding| ids[finding.fetch("finding_id")] = finding }
        end
        validate_payload!(candidate, marker, policy, authority, runtime, lifecycle, seen,
          verified, fresh: true)
        nil
      rescue ContractError => error
        raise error if %w[gate_facts_reuse gate_facts_unpinned].include?(error.code)

        raise acceptance_invalid(error)
      end

      def verify_existing!(records, marker, policy, authority, runtime, lifecycle)
        seen = {}
        verified = []
        records.map.with_index do |transaction, index|
          payload = transaction["payload"]
          begin
            unless payload.is_a?(Hash) &&
                   transaction["transaction_id"] == payload.dig("gate_evaluation", "gate_evaluation_id")
              raise ContractError.new(
                "gate_facts_lineage_invalid",
                "transaction identity does not exact-bind its GateEvaluation",
                path: "gate_facts_store"
              )
            end
            validate_payload!(
              payload, marker, policy, authority, runtime, lifecycle, seen,
              verified, fresh: false
            )
            payload.fetch("findings").each do |finding|
              seen[finding.fetch("finding_id")] = finding
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
                            existing, fresh:)
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
        unless evaluation["supersedes_gate_evaluation_id"].nil? &&
               Array(evaluation["related_gate_evaluation_refs"]).empty?
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "GateEvaluation supersession/related lineages are deferred",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}"
          )
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
            runtime, lifecycle)
        task_policy = task.fetch("task").fetch("project_policy_revision_ref")
        unless task_policy == pin
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluation task must exact-bind the frozen acceptance-time policy pin",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}"
          )
        end
        validate_acceptance_chronology!(payload, pin, policy, submission, fresh,
          authority, runtime, lifecycle)
        validate_evidence_closure!(findings, evaluation, submission, evidence_by_id)

        bundle = assemble_bundle(marker, policy, task, submission,
          evidence_by_id, payload, control, authority, runtime, lifecycle)
        validator = Orbit::V2::Validator.new(
          project_root: @active_root,
          authority_verifier: authority,
          lifecycle_verifier: lifecycle,
          runtime_identity_verifier: runtime
        )
        errors = validator.validate(bundle)
        unless errors.empty?
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "assembled snapshot fails the Validator invariants: " \
              "#{errors.map(&:code).uniq.join(', ')}",
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

      def resolve_exact_facts!(evaluation, findings, marker, pin, policy, authority,
                               runtime, lifecycle)
        records = ControlStore.new(active_root: @active_root).records
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
        control = control_facts(control_id, policies, authority, runtime, lifecycle)
        unless control.fetch("registries").any? &&
               control.fetch("attempts").any? { |candidate| candidate["attempt_id"] == attempt["attempt_id"] }
          raise ContractError.new(
            "gate_facts_acceptance_invalid",
            "evaluator control facts must exact-resolve under the frozen pin policy set",
            path: "gate_facts_store.#{evaluation["gate_evaluation_id"]}"
          )
        end
        subject_ref = evaluation.dig("subject", "task_revision_ref") || {}
        task = TaskStore.new(active_root: @active_root).resolve(
          task_id: attempt.fetch("task_id"),
          task_revision_id: subject_ref.fetch("task_revision_id"),
          authority_verifier: authority
        )
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
        evidence_store = EvidenceStore.new(active_root: @active_root)
        submission = evidence_store.resolve(
          evidence_record_id: evaluation.fetch("evaluator_submission_record_id"),
          authority_verifier: authority,
          runtime_identity_verifier: runtime,
          lifecycle_verifier: lifecycle
        )
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

          resolved = evidence_store.resolve(
            evidence_record_id: record_id,
            authority_verifier: authority,
            runtime_identity_verifier: runtime,
            lifecycle_verifier: lifecycle
          ).fetch("evidence_record")
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

      # The deterministic contract bundle: marker protocol root, the policy
      # set accepted at the evaluation's commit (the frozen pin's ancestor
      # chain for historical facts, the full accepted set for current
      # facts), the exact TaskRevision facts, the evaluator control lineage,
      # the accepted evidence, and the accepted gate facts.
      def assemble_bundle(marker, policy, task, submission, evidence_by_id,
                          payload, control, authority, runtime, lifecycle)
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
          "gate_evaluations" => [payload.fetch("gate_evaluation")],
          "findings" => payload.fetch("findings"),
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
      def validate_acceptance_chronology!(payload, pin, policy, submission, fresh,
                                   authority, runtime, lifecycle)
        accepted_at = Time.iso8601(payload.fetch("acceptance_recorded_at"))
        submission_at = Time.iso8601(
          submission.fetch("evidence_record").fetch("acceptance_recorded_at")
        )
        evaluation = payload.fetch("gate_evaluation")
        evaluator = latest_attempts(ControlStore.new(active_root: @active_root).records)[
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
          Time.iso8601(terminal["ended_at"])
        started_at = Time.iso8601(evaluator.dig("events", 0, "started_at"))
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
        cutoff = assertion && Time.iso8601(assertion.dig("policy_issuance_envelope", "issued_at"))
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
      def control_facts(control_id, policies, authority, runtime, lifecycle)
        policy_ids = policies.map { |policy| policy["policy_revision_id"] }
        records = ControlStore.new(active_root: @active_root).records
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
        {
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
