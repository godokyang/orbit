# frozen_string_literal: true

require "digest"

unless defined?(Orbit::V2::Validator)
  raise LoadError, "load Validator internals through orbit/v2/validator"
end

module Orbit
  module V2
    class Validator
      module LeadControl
        GENESIS_WRITER_ACTION = "control.genesis"
        SUCCESSOR_WRITER_ACTION = "control.checkpoint"
        TERMINAL_ATTEMPT_EVENTS = %w[
          AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled AttemptSuperseded
        ].freeze

        private

        # Model-level accepted final-state closure for the control identity
        # anchor. Real compare-and-append/store atomicity is a Slice 6
        # activation closure; this validator only proves that an invalid
        # bundle is not accepted and that accepted final states satisfy the
        # increment-1 invariants.
        def validate_control_registries(bundle, active_policy)
          registries = @indexes.fetch("control_registries", {})
          return if registries.empty?

          if registries.length > 1
            add(
              "unsupported_multi_lineage",
              "Slice 2 increment 1 accepts at most one open control lineage per bundle",
              "control_registries"
            )
            return
          end

          registry = registries.values.first
          path = "control_registries.#{registry["lead_control_id"]}"
          checkpoints = @indexes.fetch("lead_checkpoints", {})
          tasks = @indexes.fetch("task_revisions", {})

          genesis_ref = registry["genesis_checkpoint_ref"]
          genesis = genesis_ref && checkpoints[genesis_ref["lead_checkpoint_id"]]
          unless genesis &&
                 genesis["is_genesis"] == true &&
                 genesis["lead_control_id"] == registry["lead_control_id"] &&
                 genesis["content_digest"] == genesis_ref["content_digest"]
            add(
              "control_genesis_invalid",
              "registry must pin the accepted genesis LeadCheckpoint of the same control",
              "#{path}.genesis_checkpoint_ref"
            )
          end
          # The registry is create-only and carries no active-session pointer:
          # the genesis checkpoint exact-pins the initial session, and the
          # current active session is derived from the unique lineage tip plus
          # the session lineage (see validate_lead_checkpoints and
          # validate_active_session_cardinality).

          writer = registry["writer_authority_provenance"] || {}
          policies = @indexes.fetch("project_policy_revisions", {})
          pinned_policy = policies[writer.dig("policy_revision_ref", "policy_revision_id")]
          unless writer_authority_valid?(
            pinned_policy,
            writer,
            GENESIS_WRITER_ACTION,
            registry["lead_control_id"]
          )
            add(
              "control_writer_authority_invalid",
              "registry genesis requires a provider-verified #{GENESIS_WRITER_ACTION} assertion " \
                "scoped to the exact lead_control_id and pinned to its genesis policy revision",
              "#{path}.writer_authority_provenance"
            )
          end

          validate_owned_task_refs(registry["owned_task_refs"], tasks, "#{path}.owned_task_refs")
        end

        def validate_lead_checkpoints(bundle, active_policy)
          checkpoints = @indexes.fetch("lead_checkpoints", {})
          return if checkpoints.empty?

          registries = @indexes.fetch("control_registries", {})
          sessions = @indexes.fetch("lead_sessions", {})
          agents = @indexes.fetch("agent_instances", {})
          leads = @indexes.fetch("logical_leads", {})
          tasks = @indexes.fetch("task_revisions", {})
          units = @indexes.fetch("work_units", {})
          attempts = @indexes.fetch("work_unit_attempts", {})
          policies = @indexes.fetch("project_policy_revisions", {})

          by_control = checkpoints.values.group_by { |checkpoint| checkpoint["lead_control_id"] }
          by_control.each do |control_id, lineage|
            genesis_count = lineage.count { |checkpoint| checkpoint["is_genesis"] == true }
            if genesis_count > 1
              add(
                "control_genesis_duplicate",
                "control lineage requires exactly one genesis LeadCheckpoint",
                "lead_checkpoints.#{control_id}"
              )
            end
          end

          successors = Hash.new { |hash, key| hash[key] = [] }
          checkpoints.each_value do |checkpoint|
            predecessor_ref = checkpoint["predecessor_lead_checkpoint_ref"]
            if predecessor_ref.is_a?(Hash)
              successors[predecessor_ref["lead_checkpoint_id"]] <<
                checkpoint["lead_checkpoint_id"]
            end
          end

          checkpoints.each_value do |checkpoint|
            path = "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
            control_id = checkpoint["lead_control_id"]

            if checkpoint["is_genesis"] == true
              unless checkpoint["predecessor_lead_checkpoint_ref"].nil?
                add(
                  "checkpoint_lineage_invalid",
                  "genesis LeadCheckpoint must not carry a predecessor ref",
                  "#{path}.predecessor_lead_checkpoint_ref"
                )
              end
            else
              predecessor_ref = checkpoint["predecessor_lead_checkpoint_ref"]
              predecessor = predecessor_ref && checkpoints[predecessor_ref["lead_checkpoint_id"]]
              unless predecessor
                add(
                  "checkpoint_lineage_invalid",
                  "non-genesis LeadCheckpoint requires an exact existing predecessor",
                  "#{path}.predecessor_lead_checkpoint_ref"
                )
              end
              if predecessor &&
                 (predecessor["lead_control_id"] != control_id ||
                  predecessor["content_digest"] != predecessor_ref["content_digest"])
                add(
                  "checkpoint_lineage_invalid",
                  "predecessor must resolve to the exact prior checkpoint of the same control lineage",
                  "#{path}.predecessor_lead_checkpoint_ref"
                )
              end
            end

            if successors[checkpoint["lead_checkpoint_id"]].length > 1
              add(
                "checkpoint_lineage_invalid",
                "checkpoint lineage forks: a checkpoint has multiple successors",
                "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
              )
            end
          end

          detect_checkpoint_cycles(checkpoints)

          checkpoints.each_value do |checkpoint|
            path = "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
            control_id = checkpoint["lead_control_id"]
            registry = registries[control_id]
            unless registry
              add(
                "checkpoint_control_invalid",
                "checkpoint must belong to an accepted control registry",
                "#{path}.lead_control_id"
              )
              next
            end

            pinned_policy = policies[checkpoint.dig("project_policy_revision_ref", "policy_revision_id")]
            unless pinned_policy &&
                   pinned_policy["content_digest"] ==
                     checkpoint.dig("project_policy_revision_ref", "content_digest")
              add(
                "checkpoint_pin_invalid",
                "checkpoint must pin an exact existing ProjectPolicyRevision ref and digest",
                "#{path}.project_policy_revision_ref"
              )
            end

            session_ref = checkpoint["active_lead_session_ref"]
            session = session_ref && sessions[session_ref["lead_session_id"]]
            unless session &&
                   session["lead_control_id"] == control_id &&
                   session["session_generation"] == session_ref["session_generation"]
              add(
                "checkpoint_pin_invalid",
                "checkpoint must pin the exact LeadSession generation of the same control",
                "#{path}.active_lead_session_ref"
              )
            end
            # Session transition: a successor session pinned by this
            # checkpoint must exact-pin the prior checkpoint's session; a
            # historical checkpoint never needs the session to still be
            # active, so replacement cannot retroactively stale it.
            predecessor_checkpoint = checkpoint["predecessor_lead_checkpoint_ref"] &&
              checkpoints[checkpoint["predecessor_lead_checkpoint_ref"]["lead_checkpoint_id"]]
            prior_session_ref = predecessor_checkpoint && predecessor_checkpoint["active_lead_session_ref"]
            if prior_session_ref && session_ref != prior_session_ref
              prior_pin = session && session["predecessor_lead_session_ref"]
              unless prior_pin.is_a?(Hash) &&
                     prior_pin["lead_session_id"] == prior_session_ref["lead_session_id"] &&
                     prior_pin["session_generation"] == prior_session_ref["session_generation"]
                add(
                  "checkpoint_pin_invalid",
                  "checkpoint session transition must exact-pin the prior session generation",
                  "#{path}.active_lead_session_ref"
                )
              end
            end

            agent_ref = checkpoint["lead_agent_instance_ref"]
            agent = agent_ref && agents[agent_ref["agent_instance_id"]]
            unless agent
              add(
                "checkpoint_pin_invalid",
                "checkpoint must pin an existing Lead AgentInstance",
                "#{path}.lead_agent_instance_ref"
              )
            end
            if session && agent_ref && agent_ref["agent_instance_id"] != session["agent_instance_id"]
              add(
                "checkpoint_pin_invalid",
                "checkpoint Lead AgentInstance must equal the bound session AgentInstance",
                "#{path}.lead_agent_instance_ref"
              )
            end

            if session && agent
              unless session["lead_runtime_subject_ref"] == checkpoint["lead_runtime_subject_ref"] &&
                     session["lead_runtime_subject_assertion_digest"] ==
                       checkpoint["lead_runtime_subject_assertion_digest"]
                add(
                  "checkpoint_pin_invalid",
                  "checkpoint subject pins must equal the bound LeadSession subject pins",
                  "#{path}.lead_runtime_subject_ref"
                )
              end
              unless session["lead_runtime_subject_ref"] ==
                     agent.dig("runtime_identity", "runtime_subject_id")
                add(
                  "checkpoint_pin_invalid",
                  "checkpoint subject pin must equal the AgentInstance runtime subject",
                  "#{path}.lead_runtime_subject_ref"
                )
              end
            end

            Array(checkpoint["logical_lead_refs"]).each do |lead_ref|
              lead = lead_ref && leads[lead_ref["logical_lead_id"]]
              unless lead && lead["content_digest"] == lead_ref["content_digest"]
                add(
                  "checkpoint_pin_invalid",
                  "checkpoint logical lead refs must resolve exactly",
                  "#{path}.logical_lead_refs"
                )
              end
            end

            predecessor =
              if checkpoint["is_genesis"] == true
                nil
              else
                ref = checkpoint["predecessor_lead_checkpoint_ref"]
                ref && checkpoints[ref["lead_checkpoint_id"]]
              end
            validate_checkpoint_queue_projection(
              checkpoint,
              predecessor,
              registry,
              tasks,
              path
            )
            validate_checkpoint_selection(
              checkpoint,
              predecessor,
              tasks,
              units,
              attempts,
              checkpoints,
              path
            )
            validate_checkpoint_assessments(checkpoint, path)
            validate_checkpoint_progress(checkpoint, predecessor, path)
            validate_proposal_cardinality(checkpoint, path)

            if checkpoint["is_genesis"] == true &&
               checkpoint.dig("lead_decision", "action") != "establish"
              add(
                "checkpoint_decision_invalid",
                "genesis LeadCheckpoint decision action must be establish",
                "#{path}.lead_decision"
              )
            end
            validate_checkpoint_triggers(checkpoint, predecessor, path)

            expected_decision = Orbit::V2::LeadControl.reconcile(
              {
                "bundle" => bundle,
                "lead_control_id" => control_id,
                "lead_checkpoint_ref" => {
                  "lead_checkpoint_id" => checkpoint["lead_checkpoint_id"],
                  "content_digest" => checkpoint["content_digest"]
                }
              },
              checkpoint.dig("reconcile_trigger", "event")
            )
            unless expected_decision == checkpoint["lead_decision"]
              add(
                "checkpoint_decision_replay_invalid",
                "stored lead_decision must equal the deterministic reconcile result",
                "#{path}.lead_decision"
              )
            end

            expected_action =
              checkpoint["is_genesis"] == true ? GENESIS_WRITER_ACTION : SUCCESSOR_WRITER_ACTION
            writer = checkpoint["writer_authority_provenance"] || {}
            unless writer_authority_valid?(pinned_policy, writer, expected_action, control_id)
              add(
                "control_writer_authority_invalid",
                "checkpoint writer provenance requires a provider-verified #{expected_action} " \
                  "assertion scoped to the exact lead_control_id and pinned to its writing policy revision",
                "#{path}.writer_authority_provenance"
              )
            end
          end

          # The unique lineage tip of an open control must rebind the active
          # policy and pin the active LeadSession; continuing after rotation
          # or replacement requires a new checkpoint.
          checkpoints.each_value do |checkpoint|
            next unless successors[checkpoint["lead_checkpoint_id"]].empty?
            next unless registries.key?(checkpoint["lead_control_id"])

            unless policy_ref_matches?(active_policy, checkpoint["project_policy_revision_ref"])
              add(
                "checkpoint_pin_invalid",
                "lineage tip of an open control must pin the exact active ProjectPolicyRevision",
                "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}.project_policy_revision_ref"
              )
            end
            tip_session_ref = checkpoint["active_lead_session_ref"]
            tip_session = tip_session_ref && sessions[tip_session_ref["lead_session_id"]]
            unless tip_session && session_active?(tip_session)
              add(
                "checkpoint_pin_invalid",
                "lineage tip of an open control must pin the active LeadSession",
                "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}.active_lead_session_ref"
              )
            end
          end

          validate_dispatch_observation(attempts, checkpoints)
        end

        # Constructive dispatch proof: the exact AttemptCreated observation
        # checkpoint must be the immediate accepted successor of the
        # Attempt's dispatch checkpoint, reconcile on attempt_created, and pin
        # that exact AttemptCreated event. An intervening checkpoint or a
        # non-tip dispatch ref fails closed; dispatch authority is never
        # inferred from a bare historical ref.
        def validate_dispatch_observation(attempts, checkpoints)
          attempts.each_value do |attempt|
            dispatch_ref = attempt["dispatch_lead_checkpoint_ref"]
            next unless dispatch_ref.is_a?(Hash)

            created = Array(attempt["events"]).first
            next unless created

            observers = checkpoints.values.select do |checkpoint|
              ref = checkpoint["current_or_terminal_attempt_ref"]
              ref.is_a?(Hash) &&
                ref["attempt_id"] == attempt["attempt_id"] &&
                ref["event_id"] == created["event_id"] &&
                ref["event_digest"] == created["event_digest"]
            end
            unless observers.length == 1 &&
                   observers.first.dig("reconcile_trigger", "event") == "attempt_created" &&
                   observers.first["predecessor_lead_checkpoint_ref"].is_a?(Hash) &&
                   observers.first["predecessor_lead_checkpoint_ref"]["lead_checkpoint_id"] ==
                     dispatch_ref["lead_checkpoint_id"] &&
                   observers.first["predecessor_lead_checkpoint_ref"]["content_digest"] ==
                     dispatch_ref["content_digest"]
              add(
                "checkpoint_dispatch_observation_invalid",
                "AttemptCreated observation checkpoint must immediately follow the exact dispatch checkpoint",
                "work_unit_attempts.#{attempt["attempt_id"]}.dispatch_lead_checkpoint_ref"
              )
            end
            dispatch_checkpoint = checkpoints[dispatch_ref["lead_checkpoint_id"]]
            validate_dispatch_basis_match(attempt, dispatch_checkpoint) if dispatch_checkpoint
          end
        end

        # Where the dispatch checkpoint authorized a single proposed successor
        # thesis/verification-plan basis, the later AttemptCreated assignment
        # must match it exactly; a diverging assignment fails closed.
        def validate_dispatch_basis_match(attempt, dispatch_checkpoint)
          assignment = attempt.dig("events", 0, "assignment")
          return unless assignment

          thesis = proposed_thesis_basis(dispatch_checkpoint)
          if thesis
            pinned = assignment["change_thesis_ref"] || {}
            unless pinned["change_thesis_id"] == thesis["change_thesis_id"] &&
                   pinned["content_digest"] == thesis["content_digest"]
              add(
                "checkpoint_dispatch_observation_invalid",
                "AttemptCreated assignment must match the authorized proposed thesis basis",
                "work_unit_attempts.#{attempt["attempt_id"]}.dispatch_lead_checkpoint_ref"
              )
            end
          end
          plan = proposed_plan_basis(dispatch_checkpoint)
          if plan
            rule = @indexes.fetch("rule_resolution_artifacts", {})[
              assignment["assigned_rule_resolution_id"]
            ]
            unless rule && rule["identity_sha256"] == plan["identity_sha256"]
              add(
                "checkpoint_dispatch_observation_invalid",
                "AttemptCreated assignment must match the authorized proposed verification-plan basis",
                "work_unit_attempts.#{attempt["attempt_id"]}.dispatch_lead_checkpoint_ref"
              )
            end
          end
        end

        # The registry owns the stable ordered Task identities of the initial
        # claim; checkpoints keep that ordered ownership but may advance each
        # task's revision monotonically along the verified TaskRevision
        # descendant lineage (exact ref/digest). No regression, no jump
        # without lineage, no task swap, no reorder; cross-control
        # release/acquire remains increment 3.
        def validate_checkpoint_queue_projection(checkpoint, predecessor, registry, tasks, path)
          registry_ids = Array(registry["owned_task_refs"]).map { |ref| ref["task_id"] }
          queue = Array(checkpoint["task_queue"])
          unless queue.map { |ref| ref["task_id"] } == registry_ids
            add(
              "checkpoint_queue_projection_invalid",
              "checkpoint task queue must keep the registry ordered task ownership",
              "#{path}.task_queue"
            )
          end
          queue.each_with_index do |ref, index|
            claim = Array(registry["owned_task_refs"])[index]
            unless task_revision_descendant_or_same?(
              tasks,
              claim["task_revision_id"],
              ref["task_revision_id"]
            )
              add(
                "checkpoint_queue_projection_invalid",
                "queue revision must follow the verified TaskRevision descendant lineage",
                "#{path}.task_queue"
              )
            end
            next unless predecessor

            prior = Array(predecessor["task_queue"])[index]
            next if prior && task_revision_descendant_or_same?(
              tasks,
              prior["task_revision_id"],
              ref["task_revision_id"]
            )

            add(
              "checkpoint_queue_projection_invalid",
              "queue revision must not regress",
              "#{path}.task_queue"
            )
          end
          validate_owned_task_refs(queue, tasks, "#{path}.task_queue")
        end

        def task_revision_descendant_or_same?(tasks, ancestor_id, candidate_id)
          cursor = tasks[candidate_id]
          while cursor
            return true if cursor["task_revision_id"] == ancestor_id

            parent = cursor["parent_task_revision_id"]
            cursor = parent && tasks[parent]
          end
          false
        end

        def validate_checkpoint_selection(checkpoint, predecessor, tasks, units, attempts, checkpoints, path)
          active_task_ref = checkpoint["active_task_ref"]
          selected_ref = checkpoint["selected_work_unit_ref"]
          attempt_ref = checkpoint["current_or_terminal_attempt_ref"]
          queue_revisions = Array(checkpoint["task_queue"]).map { |ref| ref["task_revision_id"] }

          if active_task_ref
            task = tasks[active_task_ref["task_revision_id"]]
            unless task &&
                   task["task_id"] == active_task_ref["task_id"] &&
                   task["content_digest"] == active_task_ref["content_digest"] &&
                   queue_revisions.include?(active_task_ref["task_revision_id"])
              add(
                "checkpoint_selection_invalid",
                "active task ref must resolve exactly and appear in the task queue",
                "#{path}.active_task_ref"
              )
            end
          end
          if selected_ref
            unit = units[selected_ref["work_unit_id"]]
            unless unit &&
                   unit["content_digest"] == selected_ref["content_digest"] &&
                   active_task_ref &&
                   unit["task_revision_id"] == active_task_ref["task_revision_id"]
              add(
                "checkpoint_selection_invalid",
                "selected work unit must resolve exactly under the active task revision",
                "#{path}.selected_work_unit_ref"
              )
            end
          end

          attempt = attempt_ref && attempts[attempt_ref["attempt_id"]]
          if attempt_ref
            unless attempt && attempt["lead_control_id"] == checkpoint["lead_control_id"]
              add(
                "checkpoint_selection_invalid",
                "current attempt ref must resolve to an attempt of the same control",
                "#{path}.current_or_terminal_attempt_ref"
              )
            end
            events = Array(attempt && attempt["events"])
            pinned_event = events.find { |event| event["event_id"] == attempt_ref["event_id"] }
            unless pinned_event && pinned_event["event_digest"] == attempt_ref["event_digest"]
              add(
                "checkpoint_selection_invalid",
                "attempt ref must pin an exact event of the referenced attempt",
                "#{path}.current_or_terminal_attempt_ref"
              )
            end
            # Causality boundary: the pinned Attempt's own dispatch checkpoint
            # must be a strict lineage ancestor of this checkpoint; future or
            # unrelated checkpoint refs fail closed (this also rejects pinning
            # the Attempt this checkpoint authorizes).
            pinned_dispatch_ref = attempt && attempt["dispatch_lead_checkpoint_ref"]
            if pinned_dispatch_ref.is_a?(Hash) &&
               !lineage_ancestor?(checkpoint, pinned_dispatch_ref["lead_checkpoint_id"], checkpoints)
              add(
                "checkpoint_selection_invalid",
                "pinned attempt dispatch checkpoint must be a strict lineage ancestor",
                "#{path}.current_or_terminal_attempt_ref"
              )
            end

            switched = predecessor && selection_changed?(checkpoint, predecessor)
            if switched
              # Switch checkpoint: the pinned Attempt must belong to the
              # predecessor checkpoint selection and its PINNED event (never
              # the attempt's current latest) must be terminal; the new
              # selection is what this checkpoint authorizes.
              prior_selected = predecessor["selected_work_unit_ref"]
              prior_task = predecessor["active_task_ref"]
              prior_event = attempt && Array(attempt["events"]).find do |event|
                event["event_id"] == attempt_ref["event_id"] &&
                  event["event_digest"] == attempt_ref["event_digest"]
              end
              unless prior_selected && prior_task &&
                     attempt &&
                     attempt["work_unit_id"] == prior_selected["work_unit_id"] &&
                     attempt["task_revision_id"] == prior_task["task_revision_id"] &&
                     prior_event &&
                     TERMINAL_ATTEMPT_EVENTS.include?(prior_event["event_type"])
                add(
                  "checkpoint_selection_invalid",
                  "switch checkpoint must pin a terminal Attempt event of the prior selection",
                  "#{path}.current_or_terminal_attempt_ref"
                )
              end
            elsif attempt && active_task_ref && selected_ref
              # Non-switch observation: the pinned Attempt matches the
              # current selection.
              unless attempt["task_revision_id"] == active_task_ref["task_revision_id"] &&
                     attempt["work_unit_id"] == selected_ref["work_unit_id"]
                add(
                  "checkpoint_selection_invalid",
                  "observation attempt ref must match the current selection",
                  "#{path}.current_or_terminal_attempt_ref"
                )
              end
            end
          end
        end

        def selection_changed?(checkpoint, predecessor)
          checkpoint["active_task_ref"] != predecessor["active_task_ref"] ||
            checkpoint["selected_work_unit_ref"] != predecessor["selected_work_unit_ref"]
        end

        def lineage_ancestor?(checkpoint, ancestor_id, checkpoints)
          cursor = checkpoint["predecessor_lead_checkpoint_ref"] &&
            checkpoints[checkpoint["predecessor_lead_checkpoint_ref"]["lead_checkpoint_id"]]
          while cursor
            return true if cursor["lead_checkpoint_id"] == ancestor_id

            ref = cursor["predecessor_lead_checkpoint_ref"]
            cursor = ref && checkpoints[ref["lead_checkpoint_id"]]
          end
          false
        end

        ASSESSMENT_BASIS = {
          "task_queue" => "task_queue",
          "active_mainline" => "active_task_ref",
          "work_graph_branches" => "selected_work_unit_ref",
          "current_attempt" => "current_or_terminal_attempt_ref"
        }.freeze

        def validate_checkpoint_assessments(checkpoint, path)
          basis_present = {
            "task_queue" => true,
            "active_mainline" => !checkpoint["active_task_ref"].nil?,
            "work_graph_branches" => !checkpoint["selected_work_unit_ref"].nil?,
            "current_attempt" => !checkpoint["current_or_terminal_attempt_ref"].nil?
          }
          ASSESSMENT_BASIS.each do |layer, expected_basis|
            actual_basis = checkpoint.dig("assessments", layer, "basis_projection")
            status = checkpoint.dig("assessments", layer, "status")
            unless actual_basis == expected_basis
              add(
                "checkpoint_assessment_invalid",
                "#{layer} basis_projection must be #{expected_basis}",
                "#{path}.assessments.#{layer}.basis_projection"
              )
            end
            if basis_present[layer] && status == "none"
              add(
                "checkpoint_assessment_invalid",
                "#{layer} status none requires its basis projection null",
                "#{path}.assessments.#{layer}.status"
              )
            elsif !basis_present[layer] && status != "none"
              add(
                "checkpoint_assessment_invalid",
                "#{layer} must be none when its basis projection is null",
                "#{path}.assessments.#{layer}.status"
              )
            end
            if %w[warning blocked].include?(status) &&
               Array(checkpoint.dig("assessments", layer, "supporting_refs")).empty?
              add(
                "checkpoint_assessment_invalid",
                "#{layer} #{status} requires exact supporting provenance",
                "#{path}.assessments.#{layer}.supporting_refs"
              )
            end
            validate_supporting_refs(
              checkpoint.dig("assessments", layer, "supporting_refs"),
              path,
              "assessment"
            )
          end
        end

        SUBSTANTIVE_REF_KINDS = {
          "thesis" => ["change_thesis"],
          "agent_context" => ["agent_event"],
          "scope" => ["task_revision", "work_unit"],
          "verification_plan" => ["rule_resolution"]
        }.freeze
        OBSERVE_TRIGGERS = %w[
          attempt_created session_change thesis_change scope_change finding_change
          gate_change task_revision_change context_change authority_change dependency_change
        ].freeze
        DISPATCH_TRIGGERS = %w[dispatch_before attempt_terminal successor_before].freeze
        CHANGE_TRIGGERS = %w[
          thesis_change scope_change finding_change gate_change task_revision_change
          session_change context_change authority_change dependency_change
        ].freeze

        # reconcile_trigger names the event that produced this decision;
        # next_trigger names the awaited event AFTER this checkpoint. A change
        # trigger is never accepted from the enum alone: the exact
        # authoritative projection must differ from the exact lineage
        # predecessor, or the checkpoint fails closed.
        def validate_checkpoint_triggers(checkpoint, predecessor, path)
          reconcile_event = checkpoint.dig("reconcile_trigger", "event")
          next_event = checkpoint.dig("next_trigger", "event")
          action = checkpoint.dig("lead_decision", "action")
          if checkpoint["is_genesis"] == true
            unless reconcile_event == "genesis" && next_event == "dispatch_before"
              add(
                "checkpoint_trigger_invalid",
                "genesis must reconcile on genesis and await dispatch_before",
                "#{path}.reconcile_trigger"
              )
            end
          elsif action == "dispatch"
            # A dispatch checkpoint reconciles on dispatch_before (first
            # attempt) or on attempt_terminal/successor_before (successor
            # authorization) and awaits attempt_created.
            unless DISPATCH_TRIGGERS.include?(reconcile_event) && next_event == "attempt_created"
              add(
                "checkpoint_trigger_invalid",
                "dispatch checkpoint must reconcile on a dispatch-authorized trigger and await attempt_created",
                "#{path}.reconcile_trigger"
              )
            end
          else
            expected_next =
              if reconcile_event == "attempt_created"
                "attempt_terminal"
              elsif reconcile_event == "session_change"
                nil
              elsif CHANGE_TRIGGERS.include?(reconcile_event)
                "successor_before"
              end
            unless OBSERVE_TRIGGERS.include?(reconcile_event) &&
                   (expected_next.nil? || next_event == expected_next)
              add(
                "checkpoint_trigger_invalid",
                "observation checkpoint trigger/lifecycle combination is invalid",
                "#{path}.reconcile_trigger"
              )
            end
          end
          return unless CHANGE_TRIGGERS.include?(reconcile_event)

          unless change_trigger_delta_proven?(reconcile_event, checkpoint, predecessor)
            add(
              "checkpoint_trigger_invalid",
              "change trigger requires an exact authoritative projection delta from the lineage predecessor",
              "#{path}.reconcile_trigger"
            )
          end
        end

        # Each change trigger has one deterministic authoritative projection
        # compared against the exact lineage predecessor; there is no enum
        # placeholder path.
        def change_trigger_delta_proven?(trigger, checkpoint, predecessor)
          case trigger
          when "session_change"
            current = checkpoint["active_lead_session_ref"]
            prior = predecessor && predecessor["active_lead_session_ref"]
            current && current != prior
          when "task_revision_change"
            current = checkpoint["task_queue"]
            prior = predecessor && predecessor["task_queue"]
            current && prior && current != prior
          when "scope_change"
            checkpoint["selected_work_unit_ref"] != predecessor["selected_work_unit_ref"] ||
              checkpoint["active_task_ref"] != predecessor["active_task_ref"]
          when "thesis_change"
            current = proposed_thesis_basis(checkpoint)
            prior = predecessor && pinned_assignment_thesis(predecessor)
            current && !thesis_basis_equal?(current, prior)
          when "finding_change"
            current = checkpoint_exact_refs(checkpoint).select { |ref| ref["kind"] == "finding" }
            prior = predecessor && checkpoint_exact_refs(predecessor).select { |ref| ref["kind"] == "finding" }
            (current - prior.to_a).any?
          when "gate_change"
            current = checkpoint_exact_refs(checkpoint).select { |ref| ref["kind"] == "gate_evaluation" }
            prior = predecessor && checkpoint_exact_refs(predecessor).select { |ref| ref["kind"] == "gate_evaluation" }
            (current - prior.to_a).any?
          when "context_change"
            current = pinned_session_context_generation(checkpoint)
            prior = predecessor && pinned_session_context_generation(predecessor)
            current && current != prior
          when "authority_change"
            current = checkpoint["project_policy_revision_ref"]
            prior = predecessor && predecessor["project_policy_revision_ref"]
            current && current != prior
          when "dependency_change"
            current = selected_unit_dependencies(checkpoint)
            prior = predecessor && selected_unit_dependencies(predecessor)
            current != prior
          else
            false
          end
        end

        def selected_unit_dependencies(checkpoint)
          ref = checkpoint["selected_work_unit_ref"]
          unit = ref && @indexes.fetch("work_units", {})[ref["work_unit_id"]]
          unit && unit["depends_on_work_unit_refs"]
        end

        # The proposed successor thesis basis: exactly one exact change_thesis
        # ref in the authorizing checkpoint's supporting provenance. The
        # successor Attempt does not exist yet (checkpoint-before-dispatch,
        # ADR-006), so the proposal is the only constructible current basis
        # for thesis redirection; zero or multiple proposals fail closed, and
        # the later AttemptCreated assignment must match it.
        def proposed_thesis_basis(checkpoint)
          refs = checkpoint_exact_refs(checkpoint).select { |ref| ref["kind"] == "change_thesis" }
          return nil unless refs.length == 1

          ref = refs.first
          return nil unless ref["event_id"].nil? &&
                            change_thesis_digests[ref["id"]]&.include?(ref["digest"])

          { "change_thesis_id" => ref["id"], "content_digest" => ref["digest"] }
        end

        # Basis equality is id + digest (the pinned assignment thesis also
        # carries a revision key, so full-hash comparison would never match).
        def thesis_basis_equal?(left, right)
          left && right &&
            left["change_thesis_id"] == right["change_thesis_id"] &&
            left["content_digest"] == right["content_digest"]
        end

        # The proposed successor verification-plan basis: exactly one exact
        # rule_resolution ref (identity_sha256 authority), compared to the
        # predecessor's effective plan; ambiguous proposals fail closed.
        def proposed_plan_basis(checkpoint)
          refs = checkpoint_exact_refs(checkpoint).select { |ref| ref["kind"] == "rule_resolution" }
          return nil unless refs.length == 1

          ref = refs.first
          rule = @indexes.fetch("rule_resolution_artifacts", {})[ref["id"]]
          return nil unless rule && rule["identity_sha256"] == ref["digest"]

          { "resolution_id" => ref["id"], "identity_sha256" => ref["digest"] }
        end

        # The checkpoint's full exact supporting provenance (four assessment
        # layers plus both progress fields): the only Inc2 authority that can
        # evidence Finding/GateEvaluation record changes. FindingResolution
        # and GateRequirement-record changes have no exact ref kind in Inc2
        # checkpoint provenance, so those subtypes fail closed rather than
        # inventing a latest-wins projection.
        def checkpoint_exact_refs(checkpoint)
          ASSESSMENT_BASIS.keys.flat_map do |layer|
            Array(checkpoint.dig("assessments", layer, "supporting_refs"))
          end + Array(checkpoint.dig("delivery_progress", "supporting_refs")) +
            Array(checkpoint.dig("assurance_progress", "supporting_refs"))
        end

        def validate_checkpoint_progress(checkpoint, predecessor, path)
          attempts = @indexes.fetch("work_unit_attempts", {})
          delivery_measured = checkpoint.dig("delivery_progress", "measured_terminal_attempt_ref")
          assurance_measured = checkpoint.dig("assurance_progress", "measured_terminal_attempt_ref")
          unless delivery_measured == assurance_measured
            add(
              "checkpoint_progress_invalid",
              "delivery and assurance measured terminal refs must agree",
              "#{path}.delivery_progress.measured_terminal_attempt_ref"
            )
          end
          %w[delivery_progress assurance_progress].each do |field|
            validate_supporting_refs(checkpoint.dig(field, "supporting_refs"), path, field)
            # Delta judgment: progress compares against the exact lineage
            # predecessor checkpoint, never a score or a latest-wins value.
            expected_predecessor = checkpoint["predecessor_lead_checkpoint_ref"]
            actual_predecessor = checkpoint.dig(field, "predecessor_lead_checkpoint_ref")
            if actual_predecessor != expected_predecessor
              add(
                "checkpoint_progress_invalid",
                "#{field} predecessor comparison must pin the exact lineage predecessor checkpoint",
                "#{path}.#{field}.predecessor_lead_checkpoint_ref"
              )
            end
            refs = Array(checkpoint.dig(field, "supporting_refs"))
            measured = checkpoint.dig(field, "measured_terminal_attempt_ref")
            change = checkpoint.dig(field, "change")
            if measured.nil? && change != "not_assessed"
              add(
                "checkpoint_progress_invalid",
                "#{field} must be not_assessed without a measured terminal attempt",
                "#{path}.#{field}.change"
              )
            end
            if measured && change == "not_assessed"
              add(
                "checkpoint_progress_invalid",
                "#{field} measured round must record changed or unchanged",
                "#{path}.#{field}.change"
              )
            end
            if measured && refs.empty?
              add(
                "checkpoint_progress_invalid",
                "#{field} measured round requires exact supporting refs",
                "#{path}.#{field}.supporting_refs"
              )
            end
            if measured
              attempt = attempts[measured["attempt_id"]]
              event = attempt && Array(attempt["events"]).find do |candidate|
                candidate["event_id"] == measured["event_id"]
              end
              unless event &&
                     event["event_digest"] == measured["event_digest"] &&
                     TERMINAL_ATTEMPT_EVENTS.include?(event["event_type"])
                add(
                  "checkpoint_progress_invalid",
                  "#{field} measured terminal attempt ref must pin an exact terminal event",
                  "#{path}.#{field}.measured_terminal_attempt_ref"
                )
              end
            end
            substantive = Array(checkpoint.dig(field, "substantive_change_kinds"))
            unless substantive.empty? || !refs.empty?
              add(
                "checkpoint_progress_invalid",
                "#{field} substantive change kinds require exact supporting refs",
                "#{path}.#{field}.substantive_change_kinds"
              )
            end
            substantive.each do |kind|
              allowed = SUBSTANTIVE_REF_KINDS[kind]
              ref_ok = allowed && refs.any? { |ref| allowed.include?(ref["kind"]) }
              unless ref_ok
                add(
                  "checkpoint_progress_invalid",
                  "#{field} substantive kind #{kind} requires a matching exact supporting ref",
                  "#{path}.#{field}.substantive_change_kinds"
                )
                next
              end
              next if substantive_delta_proven?(checkpoint, predecessor, kind, refs)

              add(
                "checkpoint_progress_invalid",
                "#{field} substantive kind #{kind} must prove an exact delta against the predecessor projection",
                "#{path}.#{field}.substantive_change_kinds"
              )
            end
          end
        end

        # A proposed successor basis is a single exact ref: a checkpoint that
        # carries more than one change_thesis or more than one rule_resolution
        # ref in its supporting provenance is always ambiguous and fails
        # closed, regardless of trigger/progress/action. Repeated identical
        # refs count too (supporting refs have no canonical uniqueness rule),
        # so duplicate exact proposals are rejected as well.
        def validate_proposal_cardinality(checkpoint, path)
          %w[change_thesis rule_resolution].each do |kind|
            next unless checkpoint_exact_refs(checkpoint).count { |ref| ref["kind"] == kind } > 1

            add(
              "checkpoint_proposal_ambiguous",
              "checkpoint must carry at most one exact proposed #{kind} basis ref",
              path
            )
          end
        end

        # A claimed substantive delta must be provable against the exact
        # lineage predecessor projection; merely resolving a supporting ref is
        # never evidence of a change at this checkpoint. Each kind has one
        # deterministic authoritative basis; a kind without one fails closed.
        def substantive_delta_proven?(checkpoint, predecessor, kind, refs)
          case kind
          when "scope"
            current = checkpoint["selected_work_unit_ref"]
            prior = predecessor && predecessor["selected_work_unit_ref"]
            current && current != prior && refs.any? do |ref|
              ref["kind"] == "work_unit" &&
                ref["id"] == current["work_unit_id"] &&
                ref["digest"] == current["content_digest"]
            end
          when "thesis"
            current = proposed_thesis_basis(checkpoint)
            prior = predecessor && pinned_assignment_thesis(predecessor)
            current && !thesis_basis_equal?(current, prior) && refs.any? do |ref|
              ref["kind"] == "change_thesis" &&
                ref["id"] == current["change_thesis_id"] &&
                ref["digest"] == current["content_digest"]
            end
          when "agent_context"
            current = pinned_session_context_generation(checkpoint)
            prior = predecessor && pinned_session_context_generation(predecessor)
            current && current != prior && refs.any? do |ref|
              ref["kind"] == "agent_event" && context_advancing_event?(ref, checkpoint)
            end
          when "verification_plan"
            current = proposed_plan_basis(checkpoint)
            prior = predecessor && pinned_rule_resolution_ref(predecessor)
            current && current != prior && refs.any? do |ref|
              ref["kind"] == "rule_resolution" &&
                ref["id"] == current["resolution_id"] &&
                ref["digest"] == current["identity_sha256"]
            end
          else
            false
          end
        end

        def pinned_attempt(checkpoint)
          ref = checkpoint["current_or_terminal_attempt_ref"]
          ref && @indexes.fetch("work_unit_attempts", {})[ref["attempt_id"]]
        end

        def pinned_assignment_thesis(checkpoint)
          attempt = pinned_attempt(checkpoint)
          attempt && attempt.dig("events", 0, "assignment", "change_thesis_ref")
        end

        def pinned_session_context_generation(checkpoint)
          ref = checkpoint["active_lead_session_ref"]
          session = ref && @indexes.fetch("lead_sessions", {})[ref["lead_session_id"]]
          started = session && Array(session["lifecycle_events"]).find do |event|
            event["event_type"] == "LeadSessionStarted"
          end
          started && started["context_generation"]
        end

        def context_advancing_event?(ref, checkpoint)
          agent_ref = checkpoint["lead_agent_instance_ref"]
          agent = agent_ref && @indexes.fetch("agent_instances", {})[agent_ref["agent_instance_id"]]
          generation = pinned_session_context_generation(checkpoint)
          event = agent && Array(agent["lifecycle_events"]).find do |candidate|
            candidate["event_id"] == ref["event_id"] &&
              candidate["event_digest"] == ref["digest"]
          end
          event && event["event_type"] == "AgentContextAdvanced" &&
            event["context_generation"] == generation
        end

        def pinned_rule_resolution_ref(checkpoint)
          attempt = pinned_attempt(checkpoint)
          rule_id = attempt && attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
          rule = rule_id && @indexes.fetch("rule_resolution_artifacts", {})[rule_id]
          # RuleResolutionArtifact authority is identity_sha256 (content
          # digest is not part of the artifact), matching supporting-ref
          # resolution below.
          rule && { "resolution_id" => rule["resolution_id"], "identity_sha256" => rule["identity_sha256"] }
        end

        # Single typed exact-ref seam for assessment/progress supporting
        # provenance: kind + id + digest (attempt events pin event_id +
        # event_digest). No generic platform; each kind resolves against its
        # authority index.
        def validate_supporting_refs(refs, path, field)
          Array(refs).each do |ref|
            next unless ref.is_a?(Hash)

            case ref["kind"]
            when "work_unit"
              resolve_typed_ref(ref, @indexes.fetch("work_units", {}), "work_unit_id", "content_digest", path, field)
            when "task_revision"
              resolve_typed_ref(ref, @indexes.fetch("task_revisions", {}), "task_revision_id", "content_digest", path, field)
            when "evidence_record"
              resolve_typed_ref(ref, @indexes.fetch("evidence_records", {}), "evidence_record_id", "content_digest", path, field)
            when "finding"
              resolve_typed_ref(ref, @indexes.fetch("findings", {}), "finding_id", "content_digest", path, field)
            when "gate_evaluation"
              resolve_typed_ref(ref, @indexes.fetch("gate_evaluations", {}), "gate_evaluation_id", "content_digest", path, field)
            when "lead_checkpoint"
              resolve_typed_ref(ref, @indexes.fetch("lead_checkpoints", {}), "lead_checkpoint_id", "content_digest", path, field)
            when "change_thesis"
              digests = change_thesis_digests[ref["id"]]
              unless digests && digests.include?(ref["digest"]) && ref["event_id"].nil?
                add("checkpoint_supporting_ref_invalid", "#{field} supporting ref must resolve exactly", path)
              end
            when "attempt_event"
              attempt = @indexes.fetch("work_unit_attempts", {})[ref["id"]]
              event = attempt && Array(attempt["events"]).find do |candidate|
                candidate["event_id"] == ref["event_id"]
              end
              unless event && event["event_digest"] == ref["digest"]
                add("checkpoint_supporting_ref_invalid", "#{field} supporting ref must resolve exactly", path)
              end
            when "agent_event"
              agent = @indexes.fetch("agent_instances", {})[ref["id"]]
              event = agent && Array(agent["lifecycle_events"]).find do |candidate|
                candidate["event_id"] == ref["event_id"]
              end
              unless event && event["event_digest"] == ref["digest"]
                add("checkpoint_supporting_ref_invalid", "#{field} supporting ref must resolve exactly", path)
              end
            when "rule_resolution"
              resolution = @indexes.fetch("rule_resolution_artifacts", {})[ref["id"]]
              unless resolution && resolution["identity_sha256"] == ref["digest"]
                add("checkpoint_supporting_ref_invalid", "#{field} supporting ref must resolve exactly", path)
              end
            else
              add("checkpoint_supporting_ref_invalid", "#{field} supporting ref kind is unknown", path)
            end
          end
        end

        def resolve_typed_ref(ref, index, id_key, digest_key, path, field)
          record = index[ref["id"]]
          unless record &&
                 record[digest_key] == ref["digest"] &&
                 ref["event_id"].nil?
            add("checkpoint_supporting_ref_invalid", "#{field} supporting ref must resolve exactly", path)
          end
        end

        def change_thesis_digests
          @change_thesis_digests ||= begin
            digests = {}
            @indexes.fetch("change_theses", {}).each_value do |thesis|
              (digests[thesis["change_thesis_id"]] ||= Set.new) << thesis["content_digest"]
            end
            digests
          end
        end

        def attempt_terminal?(attempt)
          events = Array(attempt && attempt["events"])
          events.any? && TERMINAL_ATTEMPT_EVENTS.include?(events.last["event_type"])
        end

        def validate_owned_task_refs(task_refs, tasks, path)
          seen_task_ids = Set.new
          Array(task_refs).each do |task_ref|
            task = task_ref && tasks[task_ref["task_revision_id"]]
            unless task &&
                   task["task_id"] == task_ref["task_id"] &&
                   task["content_digest"] == task_ref["content_digest"]
              add(
                "control_task_ownership_invalid",
                "task ref must resolve to an exact TaskRevision of the same task",
                path
              )
            end
            if task_ref.is_a?(Hash) && task_ref["task_id"] &&
               seen_task_ids.include?(task_ref["task_id"])
              add(
                "control_task_ownership_invalid",
                "task refs must be unique per task identity",
                path
              )
            end
            seen_task_ids << task_ref["task_id"] if task_ref.is_a?(Hash)
          end
        end

        def validate_active_session_cardinality(bundle)
          sessions_by_control = Array(bundle["lead_sessions"]).select { |session| session.is_a?(Hash) }
            .group_by { |session| session["lead_control_id"] }
          sessions_by_control.each do |control_id, sessions|
            by_id = sessions.to_h { |session| [session["lead_session_id"], session] }
            roots = sessions.select { |session| session["predecessor_lead_session_ref"].nil? }
            unless roots.length == 1
              add(
                "session_binding_invalid",
                "control #{control_id} session lineage requires exactly one root without predecessor",
                "lead_sessions"
              )
            end

            successors = Hash.new { |hash, key| hash[key] = [] }
            sessions.each do |session|
              ref = session["predecessor_lead_session_ref"]
              next unless ref

              predecessor = by_id[ref["lead_session_id"]]
              unless predecessor
                add(
                  "session_binding_invalid",
                  "session predecessor must resolve to an existing session of the same control",
                  "lead_sessions.#{session["lead_session_id"]}.predecessor_lead_session_ref"
                )
                next
              end
              successors[predecessor["lead_session_id"]] << session["lead_session_id"]

              predecessor_events = Array(predecessor["lifecycle_events"])
              terminal_event = predecessor_events.last
              unless predecessor["session_generation"] == ref["session_generation"] &&
                     session["session_generation"] == predecessor["session_generation"] + 1 &&
                     terminal_event &&
                     terminal_event["event_id"] == ref["event_id"] &&
                     terminal_event["event_digest"] == ref["event_digest"] &&
                     terminal_event["event_type"] == "LeadSessionEnded"
                add(
                  "session_binding_invalid",
                  "session replacement must pin the prior generation terminal event and advance generation by exactly one",
                  "lead_sessions.#{session["lead_session_id"]}.predecessor_lead_session_ref"
                )
              end
              successor_start = Array(session["lifecycle_events"]).first
              if terminal_event &&
                 terminal_event["event_type"] == "LeadSessionEnded" &&
                 successor_start &&
                 session_time(successor_start["recorded_at"]) &&
                 session_time(terminal_event["recorded_at"]) &&
                 session_time(successor_start["recorded_at"]) < session_time(terminal_event["recorded_at"])
                add(
                  "session_binding_invalid",
                  "successor session must start at or after the prior generation terminal",
                  "lead_sessions.#{session["lead_session_id"]}.lifecycle_events[0].recorded_at"
                )
              end
            end

            successors.each do |predecessor_id, child_ids|
              next if child_ids.length <= 1

              add(
                "session_binding_invalid",
                "control #{control_id} session lineage forks: a session has multiple successors",
                "lead_sessions"
              )
            end

            reported_cycles = Set.new
            sessions.each do |start|
              cursor = start
              seen = Set.new
              while cursor
                id = cursor["lead_session_id"]
                if seen.include?(id)
                  if reported_cycles.add?(seen.to_a.sort.join(":"))
                    add(
                      "session_binding_invalid",
                      "control #{control_id} session lineage contains a cycle",
                      "lead_sessions"
                    )
                  end
                  break
                end
                seen << id
                ref = cursor["predecessor_lead_session_ref"]
                cursor = ref && by_id[ref["lead_session_id"]]
              end
            end

            active = sessions.select do |session|
              events = Array(session["lifecycle_events"])
              events.any? && events.last["event_type"] == "LeadSessionStarted"
            end
            if active.length > 1
              add(
                "session_binding_invalid",
                "control #{control_id} has more than one active LeadSession",
                "lead_sessions"
              )
            end
            tips = sessions.reject do |session|
              successors.key?(session["lead_session_id"]) &&
                !successors[session["lead_session_id"]].empty?
            end
            if active.length == 1
              unless tips.length == 1 &&
                     active.first["lead_session_id"] == tips.first["lead_session_id"]
                add(
                  "session_binding_invalid",
                  "the unique active LeadSession must be the lineage tip",
                  "lead_sessions"
                )
              end
            elsif tips.length != 1
              add(
                "session_binding_invalid",
                "control #{control_id} session lineage must have a unique tip",
                "lead_sessions"
              )
            end
          end
        end

        def session_time(value)
          Time.iso8601(value)
        rescue ArgumentError, TypeError
          nil
        end

        def detect_checkpoint_cycles(checkpoints)
          checkpoints.each_value do |start|
            visited = Set.new
            cursor = start
            while cursor
              id = cursor["lead_checkpoint_id"]
              if visited.include?(id)
                add(
                  "checkpoint_lineage_invalid",
                  "checkpoint lineage contains a cycle",
                  "lead_checkpoints.#{start["lead_checkpoint_id"]}"
                )
                break
              end
              visited << id
              predecessor_ref = cursor["predecessor_lead_checkpoint_ref"]
              cursor = predecessor_ref && checkpoints[predecessor_ref["lead_checkpoint_id"]]
            end
          end
        end

        # Writer authority must come from a provider-verified AuthorityAssertion
        # granted by the exact policy revision the checkpoint was written
        # under; the payload can never self-report writer authority
        # (ADR-006 writer authority provenance).
        def writer_authority_valid?(pinned_policy, provenance, action, lead_control_id)
          ref = provenance && provenance["assertion_ref"]
          assertion = ref && @verified_authority_assertions[ref["assertion_id"]]
          grant = unique_policy_grant(pinned_policy, action)
          provenance.is_a?(Hash) &&
            provenance["action"] == action &&
            pinned_policy.is_a?(Hash) &&
            provenance["policy_revision_ref"] == {
              "policy_revision_id" => pinned_policy["policy_revision_id"],
              "content_digest" => pinned_policy["content_digest"]
            } &&
            assertion.is_a?(Hash) &&
            assertion["assertion_digest"] == ref["assertion_digest"] &&
            assertion["authority_scope_ref"] == lead_control_id &&
            %w[user control_plane].include?(assertion["issuer_kind"]) &&
            grant.is_a?(Hash) &&
            Array(assertion["grants"]).include?(grant["required_external_grant"])
        end

        def session_active?(session)
          events = Array(session && session["lifecycle_events"])
          events.any? && events.last["event_type"] == "LeadSessionStarted"
        end

        def policy_ref_matches?(policy, ref)
          policy.is_a?(Hash) &&
            ref.is_a?(Hash) &&
            ref["policy_revision_id"] == policy["policy_revision_id"] &&
            ref["content_digest"] == policy["content_digest"]
        end

        def control_assertion_digest(value)
          "sha256:#{Digest::SHA256.hexdigest(value.to_s)}"
        end
      end

      include LeadControl
      private_constant :LeadControl
    end
  end
end
