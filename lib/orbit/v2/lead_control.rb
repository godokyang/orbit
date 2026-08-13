# frozen_string_literal: true

require_relative "control_authority"

module Orbit
  module V2
    # Minimal deep module for the serialized lead control loop (Slice 2
    # increment 2). The public core seam is fixed by ADR-006:
    #
    #   reconcile(authoritative_facts, trigger) -> LeadDecision
    #
    # authoritative_facts carries the validated contract bundle, the exact
    # lead_control_id, and the exact accepted lead_checkpoint_ref being
    # replayed. Reconcile reads ONLY facts pinned by that checkpoint at the
    # time it was accepted: the pinned attempt event decides active/terminal/
    # failure state, and zero-delivery rounds walk the checkpoint lineage.
    # It never reads an Attempt's current latest event or any future fact.
    #
    # The Validator replays every accepted checkpoint through this seam and
    # requires the stored lead_decision to be byte-equal to the deterministic
    # result, so a self-reported checkpoint decision fails closed.
    #
    # LeadDecision separates the control action from the four mutually
    # exclusive runner stop states: state is the runner stop state AFTER the
    # action executes (completed/blocked/frozen/needs_user; no fifth state).
    # Recovery returns the same schema-valid LeadDecision shape by re-running
    # the unique tip's own stored-trigger pipeline, so stop-loss/dependency/
    # fuse outcomes are recomputed exactly and frozen decisions never thaw.
    #
    # This module proves model-level decision semantics only. Real
    # compare-and-append/crash/concurrency atomicity closes at Slice 6
    # activation; nothing here simulates a transaction.
    module LeadControl
      module_function

      STATES = %w[completed blocked frozen needs_user].freeze
      ACTIONS = %w[
        establish continue dispatch replan switch freeze escalate release suspend acquire
      ].freeze
      TERMINAL_ATTEMPT_EVENTS = %w[
        AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled AttemptSuperseded
      ].freeze
      FAILURE_ATTEMPT_EVENTS = %w[AttemptFailed AttemptBlocked].freeze

      def reconcile(authoritative_facts, trigger)
        facts = if trigger == "recovery"
                  Facts.new(authoritative_facts.merge("recovery" => true))
                else
                  Facts.new(authoritative_facts)
                end
        return frozen_decision("authoritative facts missing or checkpoint not accepted") unless facts.coherent?
        trigger = facts.reconcile_trigger if trigger == "recovery"

        # Hard user-boundary precedence: a checkpoint that introduces an
        # unadjudicated newly_discovered_risk escalates to the user regardless
        # of ordinary warning/blocked assessment layers or stop-loss; those
        # cannot mask the mandatory escalation.
        if trigger == "finding_change" && facts.introduced_risk_needs_adjudication?
          return decision("needs_user", "escalate", "newly discovered risk requires risk-owner/user adjudication")
        end
        # A needs_user risk stop accepts no successor trigger except an
        # authority_change checkpoint with complete exact resolution
        # coverage; ordinary triggers cannot wash the stop out.
        if facts.needs_user_risk_predecessor? && trigger != "authority_change"
          return frozen_decision("a needs_user risk stop can only be succeeded by an authority_change checkpoint with complete exact resolution coverage")
        end
        if facts.rejected_budget_review?
          return frozen_decision("independent budget review rejected: replan required")
        end
        unless facts.warning_assessment_layers.empty?
          return frozen_decision("control anomaly in assessment layers: #{facts.warning_assessment_layers.join(",")}")
        end
        unless facts.blocked_assessment_layers.empty?
          return blocked_decision("external blockage in assessment layers: #{facts.blocked_assessment_layers.join(",")}")
        end

        case trigger
        when "genesis"
          decision("blocked", "establish", "control anchored")
        # Dispatch-authorized triggers: dispatch_before (first attempt),
        # attempt_terminal/successor_before (successor authorization), and
        # checkpoint_due (the wall-clock timer only ever wakes reconcile; it
        # never selects, terminates, or dispatches by itself).
        when "dispatch_before", "attempt_terminal", "successor_before", "checkpoint_due"
          return frozen_decision("pinned attempt still active blocks a new dispatch") if facts.pinned_attempt_active?
          return frozen_decision("no selected WorkUnit to dispatch") if facts.selected_work_unit_ref.nil?
          return blocked_decision("dependency readiness not satisfied") unless facts.dependencies_ready?

          dispatch_fuse(facts) || decision("blocked", "dispatch", "dispatch authorized")
        when "attempt_created"
          decision("blocked", "continue", "attempt creation observed")
        # Task ownership events (increment 3): the decision is a direct
        # function of the typed trigger; stop-loss still guards a release/
        # suspend/acquire checkpoint that also observes a measured terminal
        # round, so ownership bookkeeping never bypasses the round fuses.
        when "task_release"
          stop_loss(facts) || decision("blocked", "release", "task ownership released")
        when "task_suspend"
          stop_loss(facts) || decision("blocked", "suspend", "task ownership suspended")
        when "task_acquire"
          stop_loss(facts) || decision("blocked", "acquire", "task ownership acquired")
        when "session_change"
          stop_loss(facts) || decision("blocked", "continue", "same-lineage session binding accepted")
        when "authority_change"
          # Route by the immediate predecessor's stop cause FIRST: a
          # needs_user risk stop resumes only through complete exact
          # resolution coverage; policy deltas, retry overrides, unrelated
          # resolutions, or mixed payloads cannot bypass that boundary.
          if facts.needs_user_risk_predecessor?
            unless facts.resolution_driven_authority_change? &&
                   facts.resume_coverage_complete? &&
                   !facts.policy_changed? &&
                   !facts.retry_override_ref.is_a?(Hash)
              return frozen_decision("a needs_user risk stop resumes only through complete exact resolution coverage")
            end
            return stop_loss(facts) || decision("blocked", "continue", "authoritative change observed")
          end
          # A needs_user stop resumes only when new user/control-plane
          # authority facts arrive: the checkpoint consumes the exact
          # task.retry.override ref, so the dispatch authorization path
          # re-runs (the record validity itself is the Validator's proof).
          if facts.retry_override_ref.is_a?(Hash)
            return frozen_decision("pinned attempt still active blocks a new dispatch") if facts.pinned_attempt_active?
            return frozen_decision("no selected WorkUnit to dispatch") if facts.selected_work_unit_ref.nil?
            return blocked_decision("dependency readiness not satisfied") unless facts.dependencies_ready?

            dispatch_fuse(facts) || decision("blocked", "dispatch", "dispatch authorized")
          elsif facts.resolution_driven_authority_change?
            return frozen_decision("authority_change resolution resume requires an exact needs_user risk predecessor")
          else
            stop_loss(facts) || decision("blocked", "continue", "authoritative change observed")
          end
        when "finding_change"
          stop = stop_loss(facts)
          return stop if stop

          if facts.introduced_hardening_only?
            unless facts.hardening_selection_continuous?
              return frozen_decision("a hardening observation must preserve the predecessor active mainline selection projection")
            end
            decision("blocked", "continue", "authoritative change observed")
          elsif facts.introduced_ambiguous_finding_mix?
            frozen_decision("mixed hardening and ordinary finding introduction is ambiguous")
          else
            decision("blocked", "continue", "authoritative change observed")
          end

        when "gate_change"
          # The narrowed Slice 4 typed exception: an exact accepted
          # budget-review consumption (current->inherited source flip at the
          # consuming checkpoint) is the eligible dispatch authorization; an
          # arbitrary gate_change never dispatches.
          if facts.accepted_budget_review_consumption?
            return frozen_decision("pinned attempt still active blocks a new dispatch") if facts.pinned_attempt_active?
            return frozen_decision("no selected WorkUnit to dispatch") if facts.selected_work_unit_ref.nil?
            return blocked_decision("dependency readiness not satisfied") unless facts.dependencies_ready?

            dispatch_fuse(facts) || decision("blocked", "dispatch", "dispatch authorized")
          else
            stop_loss(facts) || decision("blocked", "continue", "authoritative change observed")
          end
        when "budget_change"
          # A typed budget adjustment proposal: the checkpoint carries the
          # exact test_budget_adjust payload with its deterministic derived
          # binding (delta-proven by the Validator) and stays blocked
          # awaiting the independent gate review of the exact proposal.
          stop_loss(facts) || decision("blocked", "continue", "budget adjustment proposed pending independent review")
        when "thesis_change", "scope_change",
             "task_revision_change", "context_change", "dependency_change"
          stop_loss(facts) || decision("blocked", "continue", "authoritative change observed")
        else
          frozen_decision("unknown trigger")
        end
      end

      def decision(state, action, reason)
        { "state" => state, "action" => action, "reason" => reason }
      end
      private_class_method :decision

      def frozen_decision(reason)
        decision("frozen", "freeze", reason)
      end
      private_class_method :frozen_decision

      def blocked_decision(reason)
        decision("blocked", "continue", reason)
      end
      private_class_method :blocked_decision

      # Private seam: projection of the validated authoritative facts for one
      # control lineage at one accepted checkpoint. The replay point is the
      # exact passed lead_checkpoint_ref (never latest-wins); the recovery
      # trigger additionally requires it to be the unique lineage tip.
      class Facts
        def initialize(authoritative_facts)
          @bundle = authoritative_facts["bundle"] || {}
          @control_id = authoritative_facts["lead_control_id"]
          @checkpoint_ref = authoritative_facts["lead_checkpoint_ref"] || {}
          @recovery = authoritative_facts["recovery"] == true
          @registries = index(@bundle["control_registries"], "lead_control_id")
          @checkpoints = index(@bundle["lead_checkpoints"], "lead_checkpoint_id")
          @attempts = index(@bundle["work_unit_attempts"], "attempt_id")
          @units = index(@bundle["work_units"], "work_unit_id")
          @policies = index(@bundle["project_policy_revisions"], "policy_revision_id")
          @findings = index(@bundle["findings"], "finding_id")
          @resolutions = index(@bundle["finding_resolutions"], "finding_resolution_id")
        end

        def coherent?
          registry &&
            replay_point &&
            (!@recovery || unique_tip?) &&
            selection_consistent? &&
            attempt_ref_resolves?
        end

        def queue
          replay_point["task_queue"]
        end

        def active_task_ref
          replay_point["active_task_ref"]
        end

        def selected_work_unit_ref
          replay_point["selected_work_unit_ref"]
        end

        def selected_unit
          ref = selected_work_unit_ref
          ref && @units[ref["work_unit_id"]]
        end

        # The exact trigger the accepted tip checkpoint reconciled on; part of
        # its content digest, so recovery can re-run the same pipeline without
        # trusting any mutable state.
        def reconcile_trigger
          replay_point.dig("reconcile_trigger", "event")
        end

        def attempt_ref
          replay_point["current_or_terminal_attempt_ref"]
        end

        # Replay reads the pinned event only: the Attempt's current latest
        # event is a future fact and must never influence a historical
        # checkpoint decision.
        def pinned_event
          ref = attempt_ref
          attempt = ref && @attempts[ref["attempt_id"]]
          attempt && Array(attempt["events"]).find do |event|
            event["event_id"] == ref["event_id"] &&
              event["event_digest"] == ref["event_digest"]
          end
        end

        def pinned_attempt_active?
          event = pinned_event
          event && event["event_type"] == "AttemptCreated"
        end

        # Increment 4 authority facts pinned by the replay point: the
        # canonical fingerprint identity basis, its derived fingerprint, the
        # separate supporting provenance (never hashed), the consumed
        # task.retry.override ref, and the two canonical effective budget
        # bindings.
        def fingerprint_identity_basis
          replay_point["fingerprint_identity_basis"]
        end

        def fingerprint
          replay_point["fingerprint"]
        end

        def fingerprint_provenance
          replay_point["fingerprint_supporting_provenance"]
        end

        def retry_override_ref
          replay_point["retry_override_ref"]
        end

        def bindings
          Array(replay_point["effective_budget_bindings"])
        end

        # The active policy for a replay is the exact policy revision pinned
        # by the replay point, never the bundle's current tip: a rotation
        # cannot rewrite the derivation of an already accepted checkpoint.
        def active_policy
          pinned_policy(replay_point)
        end

        def pinned_policy(checkpoint)
          ref = checkpoint.is_a?(Hash) && checkpoint["project_policy_revision_ref"]
          ref && @policies[ref["policy_revision_id"]]
        end

        def finding_disposition(finding_ref, checkpoint = replay_point)
          finding = finding_ref.is_a?(Hash) && @findings[finding_ref["id"]]
          policy = pinned_policy(checkpoint)
          mapping = policy && policy["finding_disposition"]
          return nil unless finding.is_a?(Hash) && mapping.is_a?(Hash)

          mapping[finding["basis"]]
        end

        def finding_refs(checkpoint)
          supporting_refs(checkpoint).select { |ref| ref.is_a?(Hash) && ref["kind"] == "finding" }
        end

        def finding_resolution_refs(checkpoint)
          supporting_refs(checkpoint)
            .select { |ref| ref.is_a?(Hash) && ref["kind"] == "finding_resolution" }
        end

        def introduced_finding_refs(checkpoint = replay_point)
          finding_refs(checkpoint) - finding_refs(predecessor_of(checkpoint))
        end

        # A replay may consume only an exact FindingResolution ref (id +
        # content_digest) pinned by the replay checkpoint itself; future
        # resolutions appended to the bundle can never rewrite the history of
        # an already accepted checkpoint.
        def pinned_finding_resolutions(checkpoint)
          finding_resolution_refs(checkpoint).map do |ref|
            resolution = @resolutions[ref["id"]]
            resolution if resolution && resolution["content_digest"] == ref["digest"]
          end.compact
        end

        # A newly introduced risk finding escalates to the user unless an
        # exact pinned FindingResolution for it adjudicates the risk at this
        # checkpoint (resolution authority itself remains the Validator's
        # proof; the resolution ref must resolve exactly).
        def introduced_risk_needs_adjudication?
          unadjudicated_introduced_risks(replay_point).any?
        end

        # The risks a checkpoint introduced (delta vs its predecessor) that
        # its own pinned resolutions do not adjudicate.
        def unadjudicated_introduced_risks(checkpoint)
          introduced_finding_refs(checkpoint).select do |ref|
            finding_disposition(ref, checkpoint) == "adjudication_required" &&
              pinned_finding_resolutions(checkpoint).none? do |resolution|
                resolution["finding_id"] == ref["id"]
              end
          end
        end
        def needs_user_risk_predecessor?
          decision = predecessor_checkpoint && predecessor_checkpoint["lead_decision"]
          decision.is_a?(Hash) &&
            decision["state"] == "needs_user" &&
            decision["action"] == "escalate" &&
            predecessor_checkpoint.dig("reconcile_trigger", "event") == "finding_change"
        end

        def policy_changed?
          current = replay_point && replay_point["project_policy_revision_ref"]
          prior = predecessor_checkpoint && predecessor_checkpoint["project_policy_revision_ref"]
          current && prior && current != prior
        end

        def introduced_hardening_only?
          introduced = introduced_finding_refs
          introduced.any? && introduced.all? { |ref| finding_disposition(ref) == "nonblocking" }
        end

        def introduced_ambiguous_finding_mix?
          dispositions = introduced_finding_refs.map { |ref| finding_disposition(ref) }
          dispositions.include?("nonblocking") &&
            dispositions.any? { |value| value && value != "nonblocking" }
        end
        def hardening_selection_continuous?
          predecessor = predecessor_checkpoint
          predecessor.is_a?(Hash) &&
            replay_point["active_task_ref"] == predecessor["active_task_ref"] &&
            replay_point["selected_work_unit_ref"] == predecessor["selected_work_unit_ref"] &&
            replay_point["current_or_terminal_attempt_ref"] == predecessor["current_or_terminal_attempt_ref"]
        end

        # The narrowed Slice 4 typed exception: a gate_change checkpoint may
        # replay as an eligible dispatch ONLY when it is the exact accepted
        # budget-review consumption — its adjusted-scope binding flips the
        # source from current to inherited (ref exact-equal to its own
        # predecessor) and its measurements consume an accepted review whose
        # gate evaluation this checkpoint itself pins. An arbitrary
        # gate_change never dispatches.
        def accepted_budget_review_consumption?
          return false unless reconcile_trigger == "gate_change"

          ref = replay_point["predecessor_lead_checkpoint_ref"]
          predecessor_bindings =
            Array(predecessor_checkpoint && predecessor_checkpoint["effective_budget_bindings"])
          bindings.each_with_index.any? do |binding, index|
            next false unless ControlAuthority.exact_budget_review_transition?(
              binding, predecessor_bindings[index], ref
            )

            measurements = binding.is_a?(Hash) ? binding["measurements"] : nil
            statuses, refs = ControlAuthority.accepted_unverified_review_consumption(measurements)
            statuses && own_gate_evaluation_ref?(refs.first)
          end
        end

        def own_gate_evaluation_ref?(candidate)
          candidate.is_a?(Hash) &&
            supporting_refs(replay_point).any? do |ref|
              ref.is_a?(Hash) && ref["kind"] == "gate_evaluation" &&
                ref["id"] == candidate["gate_evaluation_id"] &&
                ref["digest"] == candidate["content_digest"]
            end
        end
        def rejected_budget_review?
          Array(replay_point && replay_point["effective_budget_bindings"]).any? do |binding|
            measurements = binding.is_a?(Hash) ? binding["measurements"] : nil
            measurements.is_a?(Hash) && measurements.values.any? do |measurement|
              measurement.is_a?(Hash) &&
                measurement.dig("unverified_assessment", "review_status") == "rejected"
            end
          end
        end

        def resolution_driven_authority_change?
          finding_resolution_refs(replay_point) -
            finding_resolution_refs(predecessor_checkpoint) != []
        end

        def resume_coverage_complete?
          risks = unadjudicated_introduced_risks(predecessor_checkpoint)
          return false if risks.empty?

          new_refs = finding_resolution_refs(replay_point) -
            finding_resolution_refs(predecessor_checkpoint)
          risks.all? do |risk_ref|
            new_refs.any? do |ref|
              resolution = @resolutions[ref["id"]]
              resolution && resolution["content_digest"] == ref["digest"] &&
                resolution["finding_id"] == risk_ref["id"]
            end
          end
        end

        def supporting_refs(checkpoint)
          return [] unless checkpoint.is_a?(Hash)

          ASSESSMENT_LAYERS.flat_map do |layer|
            Array(checkpoint.dig("assessments", layer, "supporting_refs"))
          end +
            %w[delivery_progress assurance_progress].flat_map do |source|
              Array(checkpoint.dig(source, "supporting_refs"))
            end
        end

        # Identity is provable only from the recorded canonical basis: known
        # canonicalization version, byte-recomputable digest, and a supporting
        # provenance. Any gap freezes (ADR-006: identity cannot be proven is
        # not a new failure).
        def fingerprint_provable?
          basis = fingerprint_identity_basis
          basis.is_a?(Hash) &&
            basis["canonicalization_version"] ==
              ControlAuthority::FINGERPRINT_CANONICALIZATION_VERSION &&
            fingerprint == ControlAuthority.fingerprint_digest(basis) &&
            fingerprint_provenance.is_a?(Hash)
        end

        # Prior same-fingerprint occurrences recorded in the supporting
        # provenance; used only for occurrence counting and retry
        # authorization scope, never to change the fingerprint itself.
        def prior_occurrence_count
          Array(fingerprint_provenance && fingerprint_provenance["prior_attempt_chain"]).length
        end

        # Mechanical budget derivation only for verified measurements; an
        # unverified pending measurement never derives within/over budget.
        def verified_budget_overrun?
          bindings.any? do |binding|
            next false unless binding.is_a?(Hash)

            overrun_for?(binding, "test_count", "effective_test_count") ||
              overrun_for?(binding, "test_code_lines", "effective_test_code_lines")
          end
        end

        def overrun_for?(binding, measurement_key, ceiling_key)
          measurement = binding.dig("measurements", measurement_key)
          usage = measurement && measurement["usage"]
          ceiling = binding[ceiling_key]
          measurement.is_a?(Hash) &&
            measurement["status"] == "verified" &&
            usage.is_a?(Integer) &&
            ceiling.is_a?(Integer) &&
            usage > ceiling
        end
        private :overrun_for?

        # Dependency readiness is proven only from terminal Attempt events
        # pinned by checkpoints already accepted in this lineage (including
        # the replay point itself); the AttemptCreated validator is a backstop,
        # never the first line of defense. Future/latest attempt state is
        # never consulted.
        def dependencies_ready?
          unit = selected_unit
          return false unless unit

          Array(unit["depends_on_work_unit_refs"]).all? do |dependency_id|
            dependency_terminal_proven_in_lineage?(dependency_id)
          end
        end

        def dependency_terminal_proven_in_lineage?(dependency_id)
          cursor = replay_point
          while cursor
            ref = cursor["current_or_terminal_attempt_ref"]
            if ref
              attempt = @attempts[ref["attempt_id"]]
              event = attempt && Array(attempt["events"]).find do |candidate|
                candidate["event_id"] == ref["event_id"] &&
                  candidate["event_digest"] == ref["event_digest"]
              end
              if attempt &&
                 attempt["work_unit_id"] == dependency_id &&
                 event &&
                 TERMINAL_ATTEMPT_EVENTS.include?(event["event_type"])
                return true
              end
            end
            predecessor_ref = cursor["predecessor_lead_checkpoint_ref"]
            cursor = predecessor_ref && @checkpoints[predecessor_ref["lead_checkpoint_id"]]
          end
          false
        end

        def attempt_chain_length
          attempt = attempt_ref && @attempts[attempt_ref["attempt_id"]]
          return 0 unless attempt

          length = 1
          cursor = attempt
          while cursor["predecessor_work_unit_attempt_ref"]
            cursor = @attempts[cursor["predecessor_work_unit_attempt_ref"]]
            break unless cursor

            length += 1
          end
          length
        end

        ASSESSMENT_LAYERS = %w[task_queue active_mainline work_graph_branches current_attempt].freeze

        def warning_assessment_layers
          ASSESSMENT_LAYERS.select { |layer| replay_point.dig("assessments", layer, "status") == "warning" }
        end

        def blocked_assessment_layers
          ASSESSMENT_LAYERS.select { |layer| replay_point.dig("assessments", layer, "status") == "blocked" }
        end

        def delivery_change
          replay_point.dig("delivery_progress", "change")
        end

        def assurance_change
          replay_point.dig("assurance_progress", "change")
        end

        def measured_terminal_attempt_ref
          replay_point.dig("delivery_progress", "measured_terminal_attempt_ref")
        end

        def substantive_change_kinds
          Array(replay_point.dig("delivery_progress", "substantive_change_kinds"))
        end

        # The previous zero-delivery round is the nearest round observation
        # for a DIFFERENT terminal Attempt; active/recovery/session
        # checkpoints of the same Attempt never count as a second round.
        def previous_round_delivery_change
          current_measured = measured_terminal_attempt_ref
          cursor = predecessor_checkpoint
          while cursor
            measured = cursor.dig("delivery_progress", "measured_terminal_attempt_ref")
            if measured && measured != current_measured
              return cursor.dig("delivery_progress", "change")
            end
            ref = cursor["predecessor_lead_checkpoint_ref"]
            cursor = ref && @checkpoints[ref["lead_checkpoint_id"]]
          end
          nil
        end

        private

        def registry
          @registries[@control_id]
        end

        def replay_point
          @replay_point ||= begin
            checkpoint = @checkpoints[@checkpoint_ref["lead_checkpoint_id"]]
            if checkpoint &&
               checkpoint["lead_control_id"] == @control_id &&
               checkpoint["content_digest"] == @checkpoint_ref["content_digest"]
              checkpoint
            end
          end
        end

        def predecessor_checkpoint
          predecessor_of(replay_point)
        end

        def predecessor_of(checkpoint)
          ref = checkpoint.is_a?(Hash) && checkpoint["predecessor_lead_checkpoint_ref"]
          ref && @checkpoints[ref["lead_checkpoint_id"]]
        end

        def unique_tip?
          candidates = @checkpoints.values.select { |checkpoint| checkpoint["lead_control_id"] == @control_id }
          tips = candidates.reject do |checkpoint|
            candidates.any? do |other|
              other["predecessor_lead_checkpoint_ref"].is_a?(Hash) &&
                other["predecessor_lead_checkpoint_ref"]["lead_checkpoint_id"] ==
                  checkpoint["lead_checkpoint_id"]
            end
          end
          tips.length == 1 && tips.first["lead_checkpoint_id"] == replay_point["lead_checkpoint_id"]
        end

        def selection_consistent?
          ref = active_task_ref
          return true unless ref

          queue.any? { |task_ref| task_ref["task_revision_id"] == ref["task_revision_id"] }
        end

        def attempt_ref_resolves?
          ref = attempt_ref
          ref.nil? || @attempts.key?(ref["attempt_id"])
        end

        def index(records, key)
          Array(records).each_with_object({}) do |record, memo|
            memo[record[key]] = record if record.is_a?(Hash)
          end
        end
      end

      private_constant :Facts

      # Increment 4 continuation envelope: the hard-overrun fuses that need
      # user authority (verified budget overrun, third same-fingerprint
      # retry without a provider-verified task.retry.override) dominate the
      # Lead-replannable stop-loss fuses, so every reconcile reports exactly
      # one mutually exclusive stop state.
      def dispatch_fuse(facts)
        retry_decision = retry_fuse(facts)
        return retry_decision if retry_decision

        budget_decision = budget_fuse(facts)
        return budget_decision if budget_decision

        stop_loss(facts)
      end
      private_class_method :dispatch_fuse

      # The same-failure fuse applies only to failed/blocked terminal rounds
      # with a prior same-fingerprint occurrence (the successor would be the
      # third Attempt). The fingerprint must be provable from the canonical
      # identity basis recorded in the checkpoint itself; identity or
      # provenance gaps freeze instead of pretending the failure is new. With
      # a proven same fingerprint and no provider-verified override, the
      # runner stops at needs_user — never frozen, never an automatic
      # continue. completed/cancelled attempts never trigger the fuse.
      def retry_fuse(facts)
        event = facts.pinned_event
        return nil unless event && FAILURE_ATTEMPT_EVENTS.include?(event["event_type"])
        return nil unless facts.attempt_chain_length >= 2

        unless facts.fingerprint_provable?
          return frozen_decision("fingerprint identity not provable: stable identity or supporting provenance missing")
        end
        return nil unless facts.prior_occurrence_count >= 1

        if facts.retry_override_ref.is_a?(Hash)
          nil
        else
          decision(
            "needs_user",
            "escalate",
            "third same-fingerprint Attempt requires a provider-verified task.retry.override"
          )
        end
      end
      private_class_method :retry_fuse

      # Mechanical budget overrun is derived ONLY from verified measurements
      # (usage >= 0 with an exact provider/snapshot ref): unverified pending
      # measurements never derive within/over budget (Slice 2 forward
      # contract). An overrun of any effective ceiling is a hard boundary:
      # the runner stops at needs_user.
      def budget_fuse(facts)
        if facts.verified_budget_overrun?
          decision(
            "needs_user",
            "escalate",
            "verified test budget usage exceeds the effective ceiling without user authority"
          )
        end
      end
      private_class_method :budget_fuse

      # Basic stop-loss evaluated only on terminal-round observations
      # (progress.measured_terminal_attempt_ref non-null): a first
      # zero-delivery round without substantive change evidence freezes, two
      # consecutive zero-delivery rounds freeze, and assurance-only progress
      # freezes. No arbitrary scores or adjacent-checkpoint counts.
      def stop_loss(facts)
        measured = facts.measured_terminal_attempt_ref
        return nil if measured.nil?

        delivery_unchanged = facts.delivery_change == "unchanged"
        assurance_changed = facts.assurance_change == "changed"
        if delivery_unchanged && assurance_changed
          return frozen_decision("assurance-only progress: delivery frozen")
        end
        if delivery_unchanged && facts.previous_round_delivery_change == "unchanged"
          return frozen_decision("two consecutive zero-delivery rounds")
        end
        if delivery_unchanged && facts.substantive_change_kinds.empty?
          return frozen_decision("first zero-delivery round without substantive change evidence")
        end

        nil
      end
      private_class_method :stop_loss
    end
  end
end
