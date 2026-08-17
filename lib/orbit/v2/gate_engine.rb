# frozen_string_literal: true

require_relative "active_root"
require_relative "aggregate_outcome"
require_relative "canonical_json"
require_relative "control_store"
require_relative "durable_file"
require_relative "errors"
require_relative "evidence_store"
require_relative "gate_fact_store"
require_relative "policy_store"
require_relative "task_store"
require_relative "validator"

require "set"
require "time"

module Orbit
  module V2
    # READ-ONLY Gate Engine: derives the deterministic AggregateOutcome for
    # one exact accepted TaskRevision inside the SAME fixed
    # policy -> task -> control -> evidence -> gate lock window the writers
    # use. It consumes ONLY already-verified facts through the existing
    # seams (PolicyStore, TaskStore, ControlStore::Cutoff,
    # EvidenceStore::Cutoff, GateFactStore::Cutoff) and delegates every gate
    # decision to AggregateOutcome.derive — no gate judgment logic is copied
    # here. The assembled manifest is task-scoped: the target revision's
    # parent history, the accepted policy ancestors, the target revision's
    # accepted evidence (the LATEST accepted snapshot/code surface anchors
    # the bundle so older evaluations go stale correctly), the target
    # revision's gate facts plus their full ancestor/related
    # control/evidence/evaluation closure, and the TaskStore authorizations.
    # Unrelated task facts never enter the source manifest. The engine is
    # pure read: it never writes files, never caches, never invents a latest
    # pointer, and never accepts a caller-supplied bundle. Every failure
    # fails closed as a gate_engine contract error.
    class GateEngine
      def initialize(active_root:, task_id:)
        unless task_id.is_a?(String) && Identifiers.valid?("task_id", task_id)
          raise ContractError.new(
            "gate_engine_task_scope_invalid",
            "gate engine requires a canonical task_id scope",
            path: "gate_engine.task_id"
          )
        end
        @task_id = task_id
        @active_root = File.expand_path(active_root)
        unless File.directory?(@active_root)
          raise ContractError.new(
            "gate_engine_argument_invalid",
            "active root must be an existing directory",
            path: "gate_engine.active_root"
          )
        end
        # Canonical-by-construction task scope (design §4a).
        @canonical_orbit = File.realpath(@active_root)
        @task_dir = File.join(@canonical_orbit, V2::TASK_SCOPES_SEGMENT, @task_id)
        unless File.directory?(@task_dir)
          raise ContractError.new(
            "gate_engine_argument_invalid",
            "task scope directory must exist under the canonical active root",
            path: "gate_engine.task_dir"
          )
        end
      end

      # Public instance surface: ONLY derive.
      def derive(task_id:, task_revision_id:, authority_verifier:,
                 runtime_identity_verifier:, lifecycle_verifier:)
        unless task_id.is_a?(String) && Identifiers.valid?("task_id", task_id) &&
               task_revision_id.is_a?(String) &&
               Identifiers.valid?("task_revision_id", task_revision_id) &&
               authority_verifier.respond_to?(:verify!) &&
               runtime_identity_verifier.respond_to?(:verify!) &&
               lifecycle_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "gate_engine_argument_invalid",
            "derive requires an exact task/revision identity and three configured verifiers",
            path: "gate_engine.derive"
          )
        end

        ensure_scope!(task_id)
        policy_log = File.join(@canonical_orbit, PolicyStore::POLICY_TRANSACTIONS_FILE)
        task_log = File.join(@task_dir, TaskStore::TASK_DEFINITIONS_FILE)
        control_log = File.join(@task_dir, ControlStore::CONTROL_TRANSACTIONS_FILE)
        evidence_log = File.join(@task_dir, EvidenceStore::EVIDENCE_TRANSACTIONS_FILE)
        gate_log = File.join(@task_dir, GateFactStore::GATE_FACTS_FILE)
        DurableFile.with_exclusive_lock(policy_log) do
          DurableFile.with_exclusive_lock(task_log) do
            DurableFile.with_exclusive_lock(control_log) do
              DurableFile.with_exclusive_lock(evidence_log) do
                DurableFile.with_exclusive_lock(gate_log) do
                  derive_locked(task_id, task_revision_id, authority_verifier,
                    runtime_identity_verifier, lifecycle_verifier)
                end
              end
            end
          end
        end
      rescue ContractError => error
        raise error if error.code.to_s.start_with?("gate_engine")

        raise ContractError.new(
          "gate_engine_invalid",
          "gate engine derive failed closed: #{error.code}: #{error.message}",
          path: "gate_engine.derive",
          details: error.details
        )
      rescue StandardError => error
        raise ContractError.new(
          "gate_engine_invalid",
          "gate engine derive failed closed: #{error.class}: #{error.message}",
          path: "gate_engine.derive"
        )
      end

      private

      def derive_locked(task_id, task_revision_id, authority_verifier,
                        runtime_identity_verifier, lifecycle_verifier)
        marker = task_scope!
        policy = resolve_policy(marker, authority_verifier)
        task_facts = task_facts_for_revision(task_id, task_revision_id, authority_verifier)
        task_revision = task_facts.fetch("task")
        # Staged verified facts inside the same locked window: the gate
        # cutoff (full replay incl. the internal control/evidence staging),
        # then the EvidenceStore whole-store re-verify against the verified
        # control transactions, then the final ControlStore re-verify with
        # the VERIFIED evidence. No public reader is entered mid-window.
        gate_facts = GateFactStore::Cutoff.new(active_root: @active_root, task_id: @task_id).snapshot_locked(
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier)
        evidence_payloads = EvidenceStore::Cutoff.new(active_root: @active_root, task_id: @task_id).verified_payloads(
          gate_cutoff: gate_facts,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier)
        control_txs = ControlStore::Cutoff.new(active_root: @active_root, task_id: @task_id).verified_records(
          gate_cutoff: gate_facts, evidence_payloads: evidence_payloads,
          authority_verifier: authority_verifier,
          runtime_identity_verifier: runtime_identity_verifier,
          lifecycle_verifier: lifecycle_verifier)
        policies, policy_assertions = pinned_policy_chain(policy, task_revision)
        # Monotonic source closure: the selected control causal prefix may
        # itself exact-reference ancestor gate evaluation/finding/resolution/
        # evidence facts outside the initial target gate closure. Seed the
        # gate/evidence closure from the selected checkpoints' exact typed
        # refs, recompute the evidence dependencies and the referenced
        # Attempt control prefixes, and repeat until the source ID sets stop
        # growing — so the public Validator never sees a valid checkpoint
        # prefix with missing typed sources. Any exact id+digest mismatch or
        # missing source fails closed as gate_engine_invalid.
        evaluations = []
        findings = []
        resolutions = []
        evidence_records = []
        control_facts = {
          sessions: [], registries: [], checkpoints: [], assertions: [],
          agents: [], attempts: [], resolutions: []
        }
        snapshot = nil
        code_surface = nil
        loop do
          checkpoint_seeds = control_facts.fetch(:checkpoints).flat_map do |checkpoint|
            Orbit::V2::ProjectionPrimitives.checkpoint_exact_refs(checkpoint)
          end
          next_evaluations, next_findings, next_resolutions = gate_closure(
            gate_facts, task_revision, checkpoint_seeds)
          next_evidence, next_snapshot, next_code_surface = evidence_for_revision(
            evidence_payloads, task_revision, next_evaluations, next_findings,
            next_resolutions, checkpoint_seeds)
          next_control = control_facts_for_task(
            control_txs, task_facts, next_evidence, next_evaluations, next_resolutions)
          break if next_evaluations.length == evaluations.length &&
                   next_findings.length == findings.length &&
                   next_resolutions.length == resolutions.length &&
                   next_evidence.length == evidence_records.length &&
                   next_control.fetch(:checkpoints).length == control_facts.fetch(:checkpoints).length

          evaluations, findings, resolutions = next_evaluations, next_findings, next_resolutions
          evidence_records = next_evidence
          control_facts = next_control
          snapshot = next_snapshot
          code_surface = next_code_surface
        end
        bundle = {
          "schema_version" => "orbit-v2-contract-bundle-v1",
          "protocol_epoch" => "orbit-v2",
          "protocol_root" => marker,
          "authority_assertions" => policy_assertions + control_facts.fetch(:assertions) +
            task_facts.fetch("authority_assertions"),
          "authorization_records" => task_facts.fetch("authorization_records"),
          "project_policy_revisions" => policies,
          "task_revisions" => task_facts.fetch("task_revisions"),
          "gate_requirements" => task_facts.fetch("gate_requirements"),
          "work_units" => task_facts.fetch("work_units"),
          "change_theses" => task_facts.fetch("change_theses"),
          "logical_leads" => [task_facts.fetch("logical_lead")],
          "lead_sessions" => control_facts.fetch(:sessions),
          "control_registries" => control_facts.fetch(:registries),
          "lead_checkpoints" => control_facts.fetch(:checkpoints),
          "agent_instances" => control_facts.fetch(:agents),
          "work_unit_attempts" => control_facts.fetch(:attempts),
          "rule_resolution_artifacts" => control_facts.fetch(:resolutions),
          "evidence_records" => evidence_records,
          "gate_evaluations" => evaluations,
          "findings" => findings,
          "finding_resolutions" => resolutions,
          "repository_snapshot" => snapshot,
          "code_surface" => code_surface
        }
        AggregateOutcome.derive(bundle, task_revision_id,
          validator: Orbit::V2::Validator.new(
            project_root: @canonical_orbit,
            authority_verifier: authority_verifier,
            lifecycle_verifier: lifecycle_verifier,
            runtime_identity_verifier: runtime_identity_verifier
          ))
      end

      # Task-scoped trust-boundary proof (design §2.1) with the
      # constructed-value binding.
      def task_scope!
        marker, canonical_orbit, task_dir = ActiveRoot.task_scope(
          @active_root, @task_id,
          code: "gate_engine_unpinned", label: "gate_engine"
        )
        unless canonical_orbit == @canonical_orbit && task_dir == @task_dir
          raise ContractError.new(
            "gate_engine_unpinned",
            "gate_engine task scope no longer resolves to its constructed canonical directories",
            path: "gate_engine",
            details: {
              "constructed_task_dir" => @task_dir,
              "resolved_task_dir" => task_dir
            }
          )
        end
        marker
      end

      # Cross-task derive fails closed at the storage seam.
      def ensure_scope!(task_id)
        return if task_id == @task_id

        raise ContractError.new(
          "gate_engine_task_scope_invalid",
          "gate engine is scoped to task #{@task_id} and cannot derive #{task_id.inspect}",
          path: "gate_engine.task_scope"
        )
      end


      # The target revision's EXACT ancestor chain: each revision is
      # resolved independently (so a later successor revision never leaks
      # into the manifest) and the per-revision authority
      # assertions/authorization records, gate requirements, work units and
      # theses are unioned in genesis->target order.
      def task_facts_for_revision(task_id, task_revision_id, authority_verifier)
        task_store = TaskStore.new(active_root: @active_root, task_id: @task_id)
        target = task_store.resolve(task_id: task_id, task_revision_id: task_revision_id,
          authority_verifier: authority_verifier)
        resolved_chain = []
        cursor = target
        seen = Set.new
        loop do
          task = cursor.fetch("task")
          revision_id = task.fetch("task_revision_id")
          unless seen.add?(revision_id) && task.fetch("task_id") == task_id
            raise ContractError.new(
              "gate_engine_invalid",
              "target TaskRevision ancestry is cyclic or crosses task identity",
              path: "gate_engine.derive"
            )
          end
          resolved_chain << cursor
          parent_id = task["parent_task_revision_id"]
          break unless parent_id.is_a?(String)

          cursor = task_store.resolve(task_id: task_id, task_revision_id: parent_id,
            authority_verifier: authority_verifier)
        end
        resolved_chain.reverse!
        appended_authorizations = resolved_chain.to_h do |resolved|
          revision_id = resolved.dig("task", "task_revision_id")
          pairs = task_store.authorizations(
            task_id: task_id,
            task_revision_id: revision_id,
            authority_verifier: authority_verifier
          )
          [revision_id, pairs]
        end
        authority_assertions = resolved_chain.flat_map do |resolved|
          revision = resolved.fetch("task")
          Array(resolved.fetch("authority_assertions")) +
            appended_authorizations.fetch(revision.fetch("task_revision_id")).map do |pair|
              pair.fetch("assertion")
            end
        end
        authorization_records = resolved_chain.flat_map do |resolved|
          revision = resolved.fetch("task")
          Array(resolved.fetch("authorization_records")) +
            appended_authorizations.fetch(revision.fetch("task_revision_id")).map do |pair|
              pair.fetch("authorization")
            end
        end
        {
          "task" => target.fetch("task"),
          "task_revisions" => resolved_chain.map { |resolved| resolved.fetch("task") },
          "gate_requirements" => resolved_chain.flat_map do |resolved|
            Array(resolved.fetch("gate_requirements"))
          end,
          "work_units" => resolved_chain.flat_map { |resolved| Array(resolved.fetch("work_units")) },
          "change_theses" => resolved_chain.flat_map do |resolved|
            Array(resolved.fetch("change_theses"))
          end,
          "authority_assertions" => authority_assertions,
          "authorization_records" => authorization_records,
          "logical_lead" => target.fetch("logical_lead")
        }
      end

      def resolve_policy(marker, authority_verifier)
        resolved = PolicyStore.new(active_root: @canonical_orbit).resolve(
          pinned_genesis_ref: marker.fetch("project_policy_genesis_ref"),
          authority_verifier: authority_verifier
        )
        {
          "active" => resolved.fetch("active_policy"),
          "accepted" => resolved.fetch("accepted_policies"),
          "accepted_assertions" => resolved.fetch("accepted_assertions")
        }
      end

      # The accepted policy ancestor chain of the exact task revision pin:
      # historical revisions replay under their own frozen pin, never a
      # later rotation.
      def pinned_policy_chain(policy, task_revision)
        accepted = policy.fetch("accepted")
        assertions = policy.fetch("accepted_assertions")
        pin = task_revision["project_policy_revision_ref"]
        unless pin.is_a?(Hash) && pin["policy_revision_id"].is_a?(String)
          raise ContractError.new(
            "gate_engine_invalid",
            "task revision carries no exact frozen policy pin",
            path: "gate_engine.derive"
          )
        end
        return [accepted, assertions] if accepted.last &&
                                         accepted.last["policy_revision_id"] == pin["policy_revision_id"] &&
                                         accepted.last["content_digest"] == pin["content_digest"]

        by_id = accepted.to_h { |candidate| [candidate["policy_revision_id"], candidate] }
        chain = []
        cursor = by_id[pin["policy_revision_id"]]
        unless cursor
          raise ContractError.new(
            "gate_engine_invalid",
            "task revision pins a policy the store never accepted",
            path: "gate_engine.derive"
          )
        end
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

      # The exact per-control causal prefixes that can influence the target
      # revision: start with a control that claimed the task, acquired it,
      # selected the exact revision, or owns an Attempt referenced by the
      # selected evidence/gate closure; then retain that control's verified
      # prefix through its last relevant transaction. This preserves every
      # predecessor/session/Attempt representation needed by the public
      # Validator while excluding later transactions after the control
      # switched to a successor revision.
      def control_facts_for_task(control_txs, task_facts, evidence_records, evaluations, resolutions)
        task_revision = task_facts.fetch("task")
        target_task_id = task_revision.fetch("task_id")
        required_attempt_ids = Set.new(
          evidence_records.map { |record| record["attempt_id"] } +
          evaluations.map { |evaluation| evaluation["evaluator_attempt_id"] } +
          resolutions.map { |resolution| resolution["issuer_attempt_id"] }
        ).delete(nil)
        indexed = Hash.new { |hash, key| hash[key] = [] }
        checkpoint_locations = {}
        last_relevant = {}
        control_txs.each_with_index do |tx, index|
          entries = checkpoint_entries(tx)
          control_id = if tx.is_a?(Hash) && tx.keys.sort == ControlStore::PAYLOAD_KEYS
                         tx.dig("registry", "lead_control_id")
                       else
                         entries.first&.dig("checkpoint", "lead_control_id")
                       end
          next unless control_id.is_a?(String)

          indexed[control_id] << [index, tx]
          entries.each do |entry|
            checkpoint = entry.fetch("checkpoint")
            checkpoint_locations[checkpoint.fetch("lead_checkpoint_id")] = [control_id, index]
          end
          claimed = tx.keys.sort == ControlStore::PAYLOAD_KEYS &&
            Array(tx.dig("registry", "owned_task_refs")).any? do |ref|
              ref.is_a?(Hash) && ref["task_id"] == target_task_id
            end
          touches_target = entries.any? do |entry|
            checkpoint = entry.fetch("checkpoint")
            active = checkpoint["active_task_ref"]
            transfer = checkpoint.dig("task_transfer_acquire", "task_ref")
            (active.is_a?(Hash) &&
              active["task_revision_id"] == task_revision["task_revision_id"] &&
              active["content_digest"] == task_revision["content_digest"]) ||
              (transfer.is_a?(Hash) && transfer["task_id"] == target_task_id)
          end
          carries_attempt = [tx["attempt"], tx["successor_attempt"]].compact.any? do |attempt|
            required_attempt_ids.include?(attempt["attempt_id"])
          end
          last_relevant[control_id] = index if claimed || touches_target || carries_attempt
        end
        # A transfer acquire is not self-contained without the exact release
        # checkpoint from the old control. Close those cross-control jumps to
        # a fixed point before projecting the selected prefixes.
        changed = true
        while changed
          changed = false
          last_relevant.to_a.each do |control_id, cutoff|
            indexed.fetch(control_id, []).each do |index, tx|
              next if index > cutoff

              checkpoint_entries(tx).each do |entry|
                release_ref = entry.dig("checkpoint", "task_transfer_acquire", "released_checkpoint_ref")
                location = release_ref.is_a?(Hash) &&
                  checkpoint_locations[release_ref["lead_checkpoint_id"]]
                next unless location

                released_control, released_index = location
                next if last_relevant.fetch(released_control, -1) >= released_index

                last_relevant[released_control] = released_index
                changed = true
              end
            end
          end
        end
        selected = control_txs.each_with_index.map do |tx, index|
          entries = checkpoint_entries(tx)
          control_id = if tx.is_a?(Hash) && tx.keys.sort == ControlStore::PAYLOAD_KEYS
                         tx.dig("registry", "lead_control_id")
                       else
                         entries.first&.dig("checkpoint", "lead_control_id")
                       end
          tx if control_id && index <= last_relevant.fetch(control_id, -1)
        end.compact
        sessions = {}
        checkpoints = []
        assertions = []
        agents = {}
        attempts = {}
        resolutions = {}
        registries = []
        selected.each do |tx|
          checkpoint_entries(tx).each do |entry|
            checkpoints << entry.fetch("checkpoint")
            assertions << entry.fetch("assertion")
          end
          case tx.keys.sort
          when ControlStore::PAYLOAD_KEYS
            registries << tx.fetch("registry")
            sessions[tx.fetch("session").fetch("lead_session_id")] = tx.fetch("session")
            agents[tx.fetch("agent").fetch("agent_instance_id")] = tx.fetch("agent")
          when ControlStore::SESSION_CHECKPOINT_PAYLOAD_KEYS
            sessions[tx.fetch("prior_session").fetch("lead_session_id")] = tx.fetch("prior_session")
            sessions[tx.fetch("session").fetch("lead_session_id")] = tx.fetch("session")
            agents[tx.fetch("agent").fetch("agent_instance_id")] = tx.fetch("agent")
          when ControlStore::EXECUTION_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
            worker = tx.fetch("worker_agent")
            agents[worker.fetch("agent_instance_id")] = worker
          when ControlStore::TERMINAL_PAYLOAD_KEYS
            attempt = tx.fetch("attempt")
            attempts[attempt.fetch("attempt_id")] = attempt
            successor = tx.fetch("successor_attempt")
            attempts[successor.fetch("attempt_id")] = successor
            rule = tx.fetch("rule_resolution")
            resolutions[rule.fetch("resolution_id")] = rule
            worker = tx.fetch("worker_agent")
            agents[worker.fetch("agent_instance_id")] = worker
          end
        end
        if registries.empty?
          raise ContractError.new(
            "gate_engine_invalid",
            "target revision has no accepted control lineage",
            path: "gate_engine.derive"
          )
        end
        {
          sessions: sessions.values,
          registries: registries,
          checkpoints: checkpoints,
          assertions: assertions,
          agents: agents.values,
          attempts: attempts.values,
          resolutions: resolutions.values
        }
      end

      # ALL accepted evidence of the target revision, plus every exact
      # evidence dependency of its selected evaluation/finding/resolution
      # closure and of the selected checkpoints' exact evidence refs.
      # Supersedes/related evidence is ancestor-closed. The latest
      # target-revision acceptance (timestamp, then append order) supplies
      # the one current snapshot/code-surface projection anchor.
      def evidence_for_revision(evidence_payloads, task_revision, evaluations, findings,
                                resolutions, checkpoint_evidence_refs = [])
        by_id = {}
        wanted = Set.new
        target_payloads = []
        evidence_payloads.each_with_index do |payload, index|
          record = payload.is_a?(Hash) && payload["evidence_record"]
          next unless record.is_a?(Hash)

          by_id[record.fetch("evidence_record_id")] = payload
          if record["task_revision_id"] == task_revision["task_revision_id"]
            wanted << record.fetch("evidence_record_id")
            target_payloads << [index, payload]
          end
        end
        Array(checkpoint_evidence_refs).each do |ref|
          next unless ref.is_a?(Hash) && ref["kind"] == "evidence_record" && ref["id"].is_a?(String)

          payload = by_id[ref["id"]]
          unless payload && payload.fetch("evidence_record")["content_digest"] == ref["digest"]
            raise ContractError.new(
              "gate_engine_invalid",
              "checkpoint references missing or digest-mismatched evidence #{ref["id"]}",
              path: "gate_engine.derive"
            )
          end
          wanted << ref["id"]
        end
        evaluations.each do |evaluation|
          wanted << evaluation["evaluator_submission_record_id"]
          Array(evaluation.dig("subject", "evidence_record_refs")).each do |ref|
            wanted << ref["evidence_record_id"] if ref.is_a?(Hash)
          end
        end
        findings.each do |finding|
          Array(finding["source_evidence_record_refs"]).each { |id| wanted << id }
        end
        resolutions.each do |resolution|
          wanted << resolution["issuer_submission_record_id"]
          wanted << resolution["proposal_evidence_record_id"]
          Array(resolution["supporting_record_refs"]).each { |id| wanted << id }
        end
        wanted.delete(nil)
        queue = wanted.to_a
        until queue.empty?
          record_id = queue.shift
          payload = by_id[record_id]
          unless payload
            raise ContractError.new(
              "gate_engine_invalid",
              "gate closure references missing accepted evidence #{record_id}",
              path: "gate_engine.derive"
            )
          end
          record = payload.fetch("evidence_record")
          dependencies = [record["supersedes_evidence_record_id"]] +
            Array(record["related_evidence_record_refs"])
          dependencies.compact.each do |dependency|
            next unless wanted.add?(dependency)

            queue << dependency
          end
        end
        latest_entry = target_payloads.max_by do |index, payload|
          [Time.iso8601(payload.dig("evidence_record", "acceptance_recorded_at")).to_r, index]
        end
        latest = latest_entry && latest_entry.last
        snapshot = latest && latest["repository_snapshot"]
        code_surface = latest && latest["code_surface"]
        unless snapshot.is_a?(Hash) && code_surface.is_a?(Hash)
          # The projection anchor must be an ACCEPTED source: a synthetic
          # snapshot/code surface would pollute the complete manifest, so a
          # target revision without accepted evidence fails closed.
          raise ContractError.new(
            "gate_engine_invalid",
            "target revision has no accepted evidence to anchor the projection snapshot",
            path: "gate_engine.derive"
          )
        end
        records = evidence_payloads.map do |payload|
          record = payload.is_a?(Hash) && payload["evidence_record"]
          record if record.is_a?(Hash) && wanted.include?(record["evidence_record_id"])
        end.compact
        [records, snapshot, code_surface]
      end

      # The target revision's gate facts plus their FULL ancestor/related
      # closure: supersession ancestors, owned Findings, every Finding
      # resolution (the tip lineage), and the resolutions' source/resolving
      # evaluations — fixed-point closed so the public Validator and the
      # projection see one internally consistent slice. The selected
      # checkpoints' exact gate typed refs seed additional source facts
      # (verified id+digest; any missing or mismatched source fails closed).
      def gate_closure(gate_facts, task_revision, checkpoint_refs = [])
        all_evaluations = Array(gate_facts["gate_evaluations"])
        all_findings = Array(gate_facts["findings"])
        all_resolutions = Array(gate_facts["finding_resolutions"])
        evaluations_by_id = all_evaluations.to_h do |evaluation|
          [evaluation.fetch("gate_evaluation_id"), evaluation]
        end
        findings_by_id = all_findings.to_h do |finding|
          [finding.fetch("finding_id"), finding]
        end
        resolutions_by_id = all_resolutions.to_h do |resolution|
          [resolution.fetch("finding_resolution_id"), resolution]
        end
        wanted_evaluations = Set.new
        wanted_findings = Set.new(Array(task_revision["unresolved_finding_refs"]))
        wanted_resolutions = Set.new
        Array(checkpoint_refs).each do |ref|
          next unless ref.is_a?(Hash) && ref["kind"].is_a?(String) && ref["id"].is_a?(String)

          case ref["kind"]
          when "gate_evaluation"
            evaluation = evaluations_by_id[ref["id"]]
            unless evaluation && evaluation["content_digest"] == ref["digest"]
              raise ContractError.new(
                "gate_engine_invalid",
                "checkpoint references missing or digest-mismatched GateEvaluation #{ref["id"]}",
                path: "gate_engine.derive"
              )
            end
            wanted_evaluations << ref["id"]
          when "finding"
            finding = findings_by_id[ref["id"]]
            unless finding && finding["content_digest"] == ref["digest"]
              raise ContractError.new(
                "gate_engine_invalid",
                "checkpoint references missing or digest-mismatched Finding #{ref["id"]}",
                path: "gate_engine.derive"
              )
            end
            wanted_findings << ref["id"]
          when "finding_resolution"
            resolution = resolutions_by_id[ref["id"]]
            unless resolution && resolution["content_digest"] == ref["digest"]
              raise ContractError.new(
                "gate_engine_invalid",
                "checkpoint references missing or digest-mismatched FindingResolution #{ref["id"]}",
                path: "gate_engine.derive"
              )
            end
            wanted_resolutions << ref["id"]
          end
        end
        all_evaluations.each do |evaluation|
          subject = evaluation["subject"]
          ref = subject.is_a?(Hash) && subject["task_revision_ref"]
          if ref.is_a?(Hash) &&
             ref["task_revision_id"] == task_revision["task_revision_id"] &&
             ref["content_digest"] == task_revision["content_digest"]
            wanted_evaluations << evaluation.fetch("gate_evaluation_id")
          end
        end
        changed = true
        while changed
          changed = false
          wanted_evaluations.to_a.each do |evaluation_id|
            evaluation = evaluations_by_id[evaluation_id]
            next unless evaluation

            parent_id = evaluation["supersedes_gate_evaluation_id"]
            changed = true if parent_id && evaluations_by_id[parent_id] &&
              wanted_evaluations.add?(parent_id)
          end
          all_findings.each do |finding|
            changed = true if wanted_evaluations.include?(finding["gate_evaluation_id"]) &&
              wanted_findings.add?(finding.fetch("finding_id"))
          end
          wanted_findings.to_a.each do |finding_id|
            finding = findings_by_id[finding_id]
            unless finding
              raise ContractError.new(
                "gate_engine_invalid",
                "target revision carries missing Finding #{finding_id}",
                path: "gate_engine.derive"
              )
            end
            changed = true if wanted_evaluations.add?(finding.fetch("gate_evaluation_id"))
            ([finding["supersedes_finding_id"]] +
              Array(finding["related_finding_refs"])).compact.each do |related_id|
              changed = true if wanted_findings.add?(related_id)
            end
          end
          all_resolutions.each do |resolution|
            next unless wanted_findings.include?(resolution["finding_id"])

            changed = true if wanted_resolutions.add?(resolution.fetch("finding_resolution_id"))
            [resolution["source_gate_evaluation_ref"],
             resolution["resolving_gate_evaluation_ref"]].each do |ref|
              next unless ref.is_a?(Hash)

              evaluation_id = ref["gate_evaluation_id"]
              changed = true if evaluations_by_id[evaluation_id] &&
                wanted_evaluations.add?(evaluation_id)
            end
          end
        end
        [
          all_evaluations.select do |evaluation|
            wanted_evaluations.include?(evaluation["gate_evaluation_id"])
          end,
          all_findings.select { |finding| wanted_findings.include?(finding["finding_id"]) },
          all_resolutions.select do |resolution|
            wanted_resolutions.include?(resolution["finding_resolution_id"])
          end
        ]
      end

      def checkpoint_entries(tx)
        payload = tx
        checkpoint = payload["checkpoint"] || payload["dispatch_checkpoint"]
        return [] unless checkpoint.is_a?(Hash)

        assertion = payload["assertion"] || payload["dispatch_assertion"]
        entries = [{ "checkpoint" => checkpoint, "assertion" => assertion }]
        observation = payload["observation_checkpoint"]
        observation_assertion = payload["observation_assertion"]
        if observation.is_a?(Hash)
          entries << { "checkpoint" => observation, "assertion" => observation_assertion }
        end
        entries
      end
    end
  end
end
