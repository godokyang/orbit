# frozen_string_literal: true

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
      ACTIONS = %w[establish continue dispatch replan switch freeze escalate].freeze
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
        unless facts.warning_assessment_layers.empty?
          return frozen_decision("control anomaly in assessment layers: #{facts.warning_assessment_layers.join(",")}")
        end
        unless facts.blocked_assessment_layers.empty?
          return blocked_decision("external blockage in assessment layers: #{facts.blocked_assessment_layers.join(",")}")
        end

        # Recovery recomputes the unique tip's own deterministic pipeline: the
        # stored reconcile trigger is part of the accepted checkpoint content,
        # so stop-loss/dependency/fuse outcomes are recomputed exactly and a
        # frozen decision is never thawed. A missing/unknown tip trigger fails
        # closed.
        trigger = facts.reconcile_trigger if trigger == "recovery"

        case trigger
        when "genesis"
          decision("blocked", "establish", "control anchored")
        when "dispatch_before"
          return frozen_decision("pinned attempt still active blocks a new dispatch") if facts.pinned_attempt_active?
          return frozen_decision("no selected WorkUnit to dispatch") if facts.selected_work_unit_ref.nil?
          return blocked_decision("dependency readiness not satisfied") unless facts.dependencies_ready?

          stop_loss(facts) || decision("blocked", "dispatch", "dispatch authorized")
        when "attempt_created"
          decision("blocked", "continue", "attempt creation observed")
        when "attempt_terminal", "successor_before"
          if facts.third_failure_pending?
            return frozen_decision("third failed Attempt requires fingerprint identity proof, which is not yet provable")
          end
          return frozen_decision("no selected WorkUnit to dispatch") if facts.selected_work_unit_ref.nil?
          return blocked_decision("dependency readiness not satisfied") unless facts.dependencies_ready?

          stop_loss(facts) || decision("blocked", "dispatch", "dispatch authorized")
        when "session_change"
          stop_loss(facts) || decision("blocked", "continue", "same-lineage session binding accepted")
        when "thesis_change", "scope_change", "finding_change", "gate_change",
             "task_revision_change", "context_change", "authority_change", "dependency_change"
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

        # The same-failure fuse applies only when the pinned event is a
        # failed/blocked terminal and the predecessor chain already holds a
        # prior attempt: a successor would be the third attempt and the first
        # two failures' identity must be provable, which fingerprint
        # machinery (increment 4) cannot yet do. completed/cancelled never
        # trigger the fuse.
        def third_failure_pending?
          event = pinned_event
          event && FAILURE_ATTEMPT_EVENTS.include?(event["event_type"]) &&
            attempt_chain_length >= 2
        end

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
          ref = replay_point && replay_point["predecessor_lead_checkpoint_ref"]
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
