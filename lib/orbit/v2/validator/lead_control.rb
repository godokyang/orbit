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
        FAILURE_ATTEMPT_EVENTS = %w[AttemptFailed AttemptBlocked].freeze

        private

        # Model-level accepted final-state closure for the control identity
        # anchor. Real compare-and-append/store atomicity is a Slice 6
        # activation closure; this validator only proves that an invalid
        # bundle is not accepted and that accepted final states satisfy the
        # increment-1 invariants.
        def validate_control_registries(bundle, active_policy)
          registries = @indexes.fetch("control_registries", {})
          return if registries.empty?

          # Increment 3 accepts multiple open control lineages; the
          # cross-lineage closure (pairwise disjoint tip task sets and active
          # canonical runtime subjects, release/acquire transfer provenance)
          # is validated in validate_multi_lineage_closure and
          # validate_task_transfer_provenance.

          registries.each_value do |registry|
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
            validate_checkpoint_fallback(checkpoint, policies, checkpoints, path)
            validate_checkpoint_fingerprint(checkpoint, checkpoints, path)
            validate_retry_override(checkpoint, checkpoints, path)
            validate_checkpoint_budget(checkpoint, predecessor, policies, checkpoints, path)
            validate_checkpoint_digests(checkpoint, tasks, attempts, path)

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

        # Increment 3 cross-lineage closure: multiple open control lineages
        # are accepted only while their derived tip task ownership sets and
        # active canonical runtime-subject sets are pairwise disjoint, and
        # every canonical subject reuse across controls carries an exact
        # terminal/release -> successor/bind transfer chain. AgentInstance
        # IDs or aliases never stand in for the canonical runtime subject.
        # Different projects remain independent (a bundle pins one project).
        def validate_multi_lineage_closure(bundle)
          registries = @indexes.fetch("control_registries", {})
          checkpoints = @indexes.fetch("lead_checkpoints", {})
          leads = @indexes.fetch("logical_leads", {})
          sessions = @indexes.fetch("lead_sessions", {})
          return if registries.length < 2

          successors = Hash.new { |hash, key| hash[key] = [] }
          checkpoints.each_value do |checkpoint|
            ref = checkpoint["predecessor_lead_checkpoint_ref"]
            successors[ref["lead_checkpoint_id"]] << checkpoint["lead_checkpoint_id"] if ref.is_a?(Hash)
          end

          tip_by_control = {}
          registries.each_key do |control_id|
            tips = checkpoints.values.select do |checkpoint|
              checkpoint["lead_control_id"] == control_id &&
                successors[checkpoint["lead_checkpoint_id"]].empty?
            end
            tip_by_control[control_id] = tips.first if tips.length == 1
          end

          tip_by_control.each do |control_id, tip|
            owned = Array(tip["task_queue"]).map { |ref| ref["task_id"] }
            other_owned = tip_by_control.reject { |id, _| id == control_id }
              .values.flat_map { |other_tip| Array(other_tip["task_queue"]).map { |ref| ref["task_id"] } }
            overlap = owned & other_owned
            unless overlap.empty?
              add(
                "control_task_ownership_conflict",
                "open control lineages must own pairwise disjoint task sets; " \
                  "#{control_id} overlaps on #{overlap.sort.join(",")}",
                "control_registries.#{control_id}.owned_task_refs"
              )
            end
            # One LogicalLead/Task belongs to at most one open queue, and its
            # tip selection is unique: a tip can claim only leads whose task
            # its own queue owns.
            Array(tip["logical_lead_refs"]).each do |lead_ref|
              lead = leads[lead_ref["logical_lead_id"]]
              next unless lead
              next if owned.include?(lead["task_id"])

              add(
                "checkpoint_pin_invalid",
                "lineage tip logical leads must own tasks in the tip queue",
                "lead_checkpoints.#{tip["lead_checkpoint_id"]}.logical_lead_refs"
              )
            end
          end

          validate_canonical_subject_closure(sessions)
        end

        # Project-wide canonical runtime-subject closure (provider_id +
        # runtime_subject_id from the verified AgentInstance identity): one
        # active LeadSession per subject, and each subject's control-lineage
        # chain has exactly one origin lineage with all later lineages entered
        # through an exact cross-control transfer predecessor. A root session
        # whose subject exists in another control is a transfer without
        # provenance and fails closed.
        def validate_canonical_subject_closure(sessions)
          active_by_subject = Hash.new { |hash, key| hash[key] = [] }
          chains = {}
          sessions.each_value do |session|
            key = canonical_subject_key(session)
            next unless key

            control_id = session["lead_control_id"]
            active_by_subject[key] << session["lead_session_id"] if session_active?(session)
            chain = (chains[key] ||= {
              "controls" => Set.new,
              "origins" => Set.new,
              "incoming" => {}
            })
            chain["controls"] << control_id

            # The lineage head is the session whose own predecessor is null
            # (origin) or resolves to another control (transfer successor);
            # only heads place a subject into a lineage.
            ref = session["predecessor_lead_session_ref"]
            is_head =
              ref.nil? ||
              (ref.is_a?(Hash) &&
                (head_predecessor = sessions[ref["lead_session_id"]]) &&
                head_predecessor["lead_control_id"] != control_id)
            next unless is_head

            if ref.nil?
              chain["origins"] << control_id
            elsif ref.is_a?(Hash)
              predecessor = sessions[ref["lead_session_id"]]
              if predecessor && canonical_subject_key(predecessor) == key
                chain["incoming"][control_id] = predecessor["lead_control_id"]
              end
            end
          end

          active_by_subject.each do |key, holder_ids|
            next if holder_ids.length <= 1

            add(
              "runtime_subject_active_conflict",
              "one canonical runtime subject cannot bind more than one active LeadSession",
              "lead_sessions",
              "runtime_subject" => key.join("/"),
              "active_lead_session_ids" => holder_ids.sort
            )
          end

          chains.each do |key, chain|
            controls = chain["controls"]
            next if controls.length <= 1

            origins = chain["origins"]
            unless origins.length == 1 && (controls - chain["incoming"].keys) == origins
              add(
                "session_binding_invalid",
                "runtime subject #{key.join("/")} reuse across controls requires exactly one " \
                  "origin lineage and exact terminal/release -> successor/bind transfer provenance",
                "lead_sessions"
              )
            end
          end
        end

        def canonical_subject_key(session)
          agent = session && @indexes.fetch("agent_instances", {})[session["agent_instance_id"]]
          identity = agent && agent["runtime_identity"]
          identity && RuntimeIdentityVerifier.identity_key(identity)
        rescue KeyError, TypeError
          nil
        end

        # Increment 3 release/acquire transfer provenance closure: the
        # acquire checkpoint pins the exact old accepted release/suspend
        # checkpoint of a different control and the exact released Task ref;
        # every release/suspend checkpoint is matched by exactly one acquire;
        # the released task has no non-terminal Attempt in the releasing
        # control. Accepted-final-state model only; Slice 6 owns physical
        # compare-and-append atomicity.
        def validate_task_transfer_provenance(bundle)
          checkpoints = @indexes.fetch("lead_checkpoints", {})
          attempts = @indexes.fetch("work_unit_attempts", {})
          acquires = []
          checkpoints.each_value do |checkpoint|
            payload = checkpoint["task_transfer_acquire"]
            next unless payload.is_a?(Hash)

            path = "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}.task_transfer_acquire"
            unless checkpoint.dig("lead_decision", "action") == "acquire"
              add("task_transfer_invalid", "task_transfer_acquire requires the acquire decision", path)
            end
            release_ref = payload["released_checkpoint_ref"]
            release = release_ref && checkpoints[release_ref["lead_checkpoint_id"]]
            unless release && release["content_digest"] == release_ref["content_digest"]
              add(
                "task_transfer_invalid",
                "acquire must pin an exact accepted release/suspend checkpoint ref",
                "#{path}.released_checkpoint_ref"
              )
              next
            end
            unless release["lead_control_id"] == payload["released_lead_control_id"]
              add(
                "task_transfer_invalid",
                "released_lead_control_id must equal the release checkpoint control",
                "#{path}.released_lead_control_id"
              )
            end
            if release["lead_control_id"] == checkpoint["lead_control_id"]
              add(
                "task_transfer_invalid",
                "acquire must come from a different control lineage",
                "#{path}.released_lead_control_id"
              )
            end
            unless %w[release suspend].include?(release.dig("lead_decision", "action"))
              add(
                "task_transfer_invalid",
                "acquire must reference an accepted release or relinquishing suspend checkpoint",
                "#{path}.released_checkpoint_ref"
              )
            end
            released_ref = released_task_ref(release, checkpoints)
            unless released_ref && released_ref == payload["task_ref"]
              add(
                "task_transfer_invalid",
                "acquire task ref must exact match the released task ref",
                "#{path}.task_ref"
              )
            end
            if released_ref
              non_terminal = attempts.values.select do |attempt|
                attempt["task_id"] == released_ref["task_id"] &&
                  attempt["lead_control_id"] == release["lead_control_id"] &&
                  !attempt_terminal?(attempt)
              end
              unless non_terminal.empty?
                add(
                  "task_transfer_invalid",
                  "release requires no non-terminal Task/WorkUnit Attempt in the releasing control",
                  "#{path}.released_checkpoint_ref",
                  "non_terminal_attempt_ids" => non_terminal.map { |attempt| attempt["attempt_id"] }.sort
                )
              end
            end
            acquires << [payload, checkpoint["lead_control_id"]]
          end

          checkpoints.each_value do |checkpoint|
            next unless %w[release suspend].include?(checkpoint.dig("lead_decision", "action"))

            released_ref = released_task_ref(checkpoint, checkpoints)
            next unless released_ref

            matching = acquires.select do |payload, _control_id|
              payload["released_checkpoint_ref"]["lead_checkpoint_id"] == checkpoint["lead_checkpoint_id"] &&
                payload["released_checkpoint_ref"]["content_digest"] == checkpoint["content_digest"] &&
                payload["released_lead_control_id"] == checkpoint["lead_control_id"] &&
                payload["task_ref"] == released_ref
            end
            unless matching.length == 1
              add(
                "task_transfer_invalid",
                "every release/suspend checkpoint requires exactly one matching acquire",
                "lead_checkpoints.#{checkpoint["lead_checkpoint_id"]}"
              )
            end
          end
        end

        # The task an accepted release/suspend checkpoint relinquished: the
        # single element its queue removed from the exact lineage
        # predecessor. This derived ref is the exact binding the acquiring
        # checkpoint must reproduce.
        def released_task_ref(checkpoint, checkpoints)
          return nil if checkpoint["is_genesis"] == true

          ref = checkpoint["predecessor_lead_checkpoint_ref"]
          predecessor = ref && checkpoints[ref["lead_checkpoint_id"]]
          return nil unless predecessor

          removed = Array(predecessor["task_queue"]) - Array(checkpoint["task_queue"])
          removed.length == 1 ? removed.first : nil
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
              next false unless checkpoint.dig("reconcile_trigger", "event") == "attempt_created"

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
        # claim and never mutates: genesis exact-pins the claim, and every
        # later queue is a derived projection that evolves only through exact
        # release/suspend removal or acquire append provenance. The registry
        # stays genesis claim/history, never mutable latest truth.
        def validate_checkpoint_queue_projection(checkpoint, predecessor, registry, tasks, path)
          claim = Array(registry["owned_task_refs"])
          queue = Array(checkpoint["task_queue"])
          action = checkpoint.dig("lead_decision", "action")

          if checkpoint["is_genesis"] == true
            unless queue == claim
              add(
                "checkpoint_queue_projection_invalid",
                "genesis task queue must exact match the registry ownership claim",
                "#{path}.task_queue"
              )
            end
          elsif %w[release suspend].include?(action)
            prior = Array(predecessor && predecessor["task_queue"])
            removed = prior - queue
            unless removed.length == 1 &&
                   queue.length == prior.length - 1 &&
                   queue == prior.reject { |ref| ref == removed.first }
              add(
                "task_transfer_invalid",
                "release checkpoint queue must remove exactly one owned task",
                "#{path}.task_queue"
              )
            end
            unless checkpoint["active_task_ref"].nil? ||
                   checkpoint.dig("active_task_ref", "task_id") != removed.first["task_id"]
              add(
                "task_transfer_invalid",
                "release checkpoint must remove the released task from active selection",
                "#{path}.active_task_ref"
              )
            end
            validate_queue_revision_progression(queue, prior, tasks, path)
          elsif action == "acquire"
            payload = checkpoint["task_transfer_acquire"]
            prior = Array(predecessor && predecessor["task_queue"])
            unless payload.is_a?(Hash) &&
                   queue == prior + [payload["task_ref"]]
              add(
                "task_transfer_invalid",
                "acquire checkpoint queue must append exactly the acquired task ref",
                "#{path}.task_queue"
              )
            end
            validate_queue_revision_progression(queue, prior, tasks, path)
          else
            prior = Array(predecessor && predecessor["task_queue"])
            unless queue.map { |ref| ref["task_id"] } == prior.map { |ref| ref["task_id"] }
              add(
                "checkpoint_queue_projection_invalid",
                "checkpoint task queue must keep the ordered task ownership projection",
                "#{path}.task_queue"
              )
            end
            validate_queue_revision_progression(queue, prior, tasks, path)
          end
          validate_owned_task_refs(queue, tasks, "#{path}.task_queue")
        end

        # Revision consistency of the queue projection: every kept element
        # advances only along the verified TaskRevision descendant lineage of
        # the predecessor element with the same task identity.
        def validate_queue_revision_progression(queue, prior, tasks, path)
          prior_by_id = {}
          Array(prior).each do |ref|
            prior_by_id[ref["task_id"]] = ref if ref.is_a?(Hash)
          end
          Array(queue).each do |ref|
            next unless ref.is_a?(Hash)

            prior_ref = prior_by_id[ref["task_id"]]
            next unless prior_ref

            next if task_revision_descendant_or_same?(
              tasks,
              prior_ref["task_revision_id"],
              ref["task_revision_id"]
            )

            add(
              "checkpoint_queue_projection_invalid",
              "queue revision must not regress or jump without lineage",
              "#{path}.task_queue"
            )
          end
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
          budget_change
        ].freeze
        DISPATCH_TRIGGERS = %w[
          dispatch_before attempt_terminal successor_before checkpoint_due
        ].freeze
        CHANGE_TRIGGERS = %w[
          thesis_change scope_change finding_change gate_change task_revision_change
          session_change context_change authority_change dependency_change
          budget_change
        ].freeze
        # reconcile_trigger names the event that produced this decision;
        # next_trigger names the awaited event AFTER this checkpoint. A change
        # trigger is never accepted from the enum alone: the exact
        # authoritative projection must differ from the exact lineage
        # predecessor, or the checkpoint fails closed. The four runner stop
        # states stay mutually exclusive per checkpoint: dispatch-authorized
        # triggers may end in dispatch, frozen (Lead-replannable control
        # anomaly), needs_user (hard overrun awaiting user authority), or
        # blocked (external non-user facts), and each maps to one awaited
        # event; a frozen or needs_user decision never thaws implicitly.
        def validate_checkpoint_triggers(checkpoint, predecessor, path)
          reconcile_event = checkpoint.dig("reconcile_trigger", "event")
          next_event = checkpoint.dig("next_trigger", "event")
          action = checkpoint.dig("lead_decision", "action")
          if risk_needs_user_predecessor?(predecessor) && reconcile_event != "authority_change"
            add(
              "checkpoint_trigger_invalid",
              "a needs_user risk stop can only be succeeded by an authority_change checkpoint with complete exact resolution coverage",
              "#{path}.reconcile_trigger"
            )
          end
          if reconcile_event == "finding_change" &&
             introduced_hardening_only?(checkpoint, predecessor) &&
             !hardening_selection_continuous?(checkpoint, predecessor)
            add(
              "checkpoint_selection_invalid",
              "a hardening-only finding_change observation must preserve the predecessor active mainline selection projection",
              "#{path}.selected_work_unit_ref"
            )
          end
          if checkpoint["is_genesis"] == true
            unless reconcile_event == "genesis" && next_event == "dispatch_before"
              add(
                "checkpoint_trigger_invalid",
                "genesis must reconcile on genesis and await dispatch_before",
                "#{path}.reconcile_trigger"
              )
            end
          elsif DISPATCH_TRIGGERS.include?(reconcile_event)
            # Dispatch-authorized triggers: dispatch_before (first attempt),
            # attempt_terminal/successor_before (successor authorization),
            # and checkpoint_due (the timer only ever wakes reconcile).
            unless dispatch_trigger_outcome_valid?(action, next_event)
              add(
                "checkpoint_trigger_invalid",
                "dispatch-authorized checkpoint outcome/awaited-event combination is invalid",
                "#{path}.reconcile_trigger"
              )
            end
            if reconcile_event == "checkpoint_due"
              unless predecessor && predecessor.dig("next_trigger", "event") == "checkpoint_due"
                add(
                  "checkpoint_trigger_invalid",
                  "checkpoint_due can only be produced by an exact scheduled wall-clock fallback of the lineage predecessor",
                  "#{path}.reconcile_trigger"
                )
              end
              # The timer occurrence is proven only by a provider-verified
              # AuthorityAssertion with the typed control.checkpoint_due.observe
              # grant whose canonical scope exact binds project, active
              # policy, control, the scheduled checkpoint ref+digest, the
              # derived deadline and observed_at; asserted_at and the receipt
              # issued_at must equal observed_at >= deadline, and the active
              # policy must trust the grant. An ordinary lifecycle event
              # proves nothing about the timer.
              deadline = predecessor && predecessor.dig("wall_clock_fallback", "deadline")
              scheduled = deadline && parse_time(deadline)
              unless checkpoint_due_observation_valid?(checkpoint, predecessor, deadline, scheduled)
                add(
                  "checkpoint_trigger_invalid",
                  "checkpoint_due requires a provider-verified observation assertion bound to the exact schedule, deadline, and observed_at",
                  "#{path}.reconcile_trigger"
                )
              end
            end
          elsif %w[release suspend].include?(action)
            expected_trigger = action == "release" ? "task_release" : "task_suspend"
            unless reconcile_event == expected_trigger && next_event == "successor_before"
              add(
                "checkpoint_trigger_invalid",
                "#{action} checkpoint must reconcile on #{expected_trigger} and await successor_before",
                "#{path}.reconcile_trigger"
              )
            end
          elsif action == "acquire"
            unless reconcile_event == "task_acquire" && next_event == "dispatch_before"
              add(
                "checkpoint_trigger_invalid",
                "acquire checkpoint must reconcile on task_acquire and await dispatch_before",
                "#{path}.reconcile_trigger"
              )
            end
          else
            unless observe_trigger_outcome_valid?(reconcile_event, action, next_event)
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

        def dispatch_trigger_outcome_valid?(action, next_event)
          case action
          when "dispatch"
            next_event == "attempt_created"
          when "freeze"
            # A control anomaly is Lead-replannable: the next decision point
            # is the successor boundary after replan/split/switch.
            next_event == "successor_before"
          when "escalate"
            # Hard overruns await new user/control-plane authority facts.
            next_event == "authority_change"
          when "continue"
            # Blocked on external non-user facts; the awaited event names the
            # fact class that can resume reconcile.
            %w[successor_before dependency_change authority_change].include?(next_event)
          else
            false
          end
        end

        def observe_trigger_outcome_valid?(reconcile_event, action, next_event)
          return false unless OBSERVE_TRIGGERS.include?(reconcile_event)

          case action
          when "continue"
            expected_next =
              if reconcile_event == "attempt_created"
                "attempt_terminal"
              elsif reconcile_event == "session_change"
                nil
              elsif reconcile_event == "budget_change"
                # The proposal awaits the exact independent gate review.
                "gate_change"
              elsif CHANGE_TRIGGERS.include?(reconcile_event)
                "successor_before"
              end
            # The wall-clock fallback timer may substitute for the awaited
            # event: checkpoint_due wakes reconcile when no event arrives.
            expected_next.nil? || next_event == expected_next || next_event == "checkpoint_due"
          when "freeze"
            next_event == "successor_before"
          when "escalate"
            next_event == "authority_change"
          when "dispatch"
            # A needs_user stop resumes only when new user/control-plane
            # authority facts arrive; the narrowed Slice 4 exception lets the
            # exact accepted budget-review gate_change dispatch (the trigger
            # proof enforces the exactness).
            (reconcile_event == "authority_change" && next_event == "attempt_created") ||
              (reconcile_event == "gate_change" && next_event == "attempt_created")

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
          when "budget_change"
            budget_change_delta_proven?(checkpoint, predecessor)
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
            added = current - prior.to_a
            if checkpoint.dig("lead_decision", "action") == "dispatch"
              added.any? && budget_review_dispatch_proven?(checkpoint, predecessor)
            else
              added.any?
            end
          when "context_change"
            current = pinned_session_context_generation(checkpoint)
            prior = predecessor && pinned_session_context_generation(predecessor)
            current && current != prior
          when "authority_change"
            if risk_needs_user_predecessor?(predecessor)
              # A needs_user risk stop resumes only through complete exact
              # resolution coverage; policy/override deltas never bypass it.
              resolution_resume_proven?(checkpoint, predecessor)
            else
              current = checkpoint["project_policy_revision_ref"]
              prior = predecessor && predecessor["project_policy_revision_ref"]
              policy_delta = current && prior && current != prior
              override_delta = checkpoint["retry_override_ref"].is_a?(Hash) &&
                !(predecessor && predecessor["retry_override_ref"].is_a?(Hash))
              policy_delta || override_delta
            end
          when "dependency_change"
            current = selected_unit_dependencies(checkpoint)
            prior = predecessor && selected_unit_dependencies(predecessor)
            current != prior
          else
            false
          end
        end
        # The budget_change trigger proves one deterministic delta: the exact
        # test_budget_adjust payload canonicalizes to budget_adjustment_digest,
        # binds the exact lineage predecessor checkpoint+binding with the
        # predecessor's old effective ceilings, and requests different
        # ceilings — a bare or forged trigger proves nothing.
        def budget_change_delta_proven?(checkpoint, predecessor)
          payload = checkpoint["test_budget_adjust"]
          return false unless payload.is_a?(Hash) && predecessor.is_a?(Hash)
          return false unless checkpoint["budget_adjustment_digest"] ==
                              Orbit::V2::ControlAuthority.budget_adjustment_digest(payload)
          return false unless payload["predecessor_lead_checkpoint_ref"] ==
                              {
                                "lead_checkpoint_id" => predecessor["lead_checkpoint_id"],
                                "content_digest" => predecessor["content_digest"]
                              }

          predecessor_binding = Array(predecessor["effective_budget_bindings"]).find do |binding|
            binding.is_a?(Hash) && binding["budget_scope_type"] == payload["budget_scope_type"]
          end
          return false unless predecessor_binding
          return false unless payload["predecessor_binding_digest"] ==
                              Orbit::V2::ControlAuthority.binding_digest(predecessor_binding)
          return false unless payload["old_effective_budget"] ==
                              Orbit::V2::ControlAuthority.effective_ceiling(predecessor_binding)
          payload["new_effective_budget"].is_a?(Hash) &&
            payload["new_effective_budget"] != payload["old_effective_budget"]
        end
        # A gate_change may replay as dispatch ONLY for the exact accepted
        # budget-review consumption: the shared typed current->inherited
        # transition holds for the adjusted-scope binding and its
        # measurements carry the exact accepted review basis. An arbitrary
        # gate_change never dispatches.
        def budget_review_dispatch_proven?(checkpoint, predecessor)
          ref = checkpoint["predecessor_lead_checkpoint_ref"]
          predecessor_bindings = Array(predecessor && predecessor["effective_budget_bindings"])
          Array(checkpoint["effective_budget_bindings"]).each_with_index.any? do |binding, index|
            next false unless Orbit::V2::ControlAuthority.exact_budget_review_transition?(
              binding, predecessor_bindings[index], ref
            )

            measurements = binding.is_a?(Hash) ? binding["measurements"] : nil
            !Orbit::V2::ControlAuthority.accepted_unverified_review_consumption(measurements).nil?
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
          ProjectionPrimitives.proposed_thesis_basis(checkpoint, change_thesis_digests)
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
          ProjectionPrimitives.proposed_plan_basis(
            checkpoint,
            @indexes.fetch("rule_resolution_artifacts", {})
          )
        end

        # The checkpoint's full exact supporting provenance (four assessment
        # layers plus both progress fields): the only Inc2 authority that can
        # evidence Finding/GateEvaluation record changes. GateRequirement
        # record changes have no exact ref kind in Inc2 checkpoint
        # provenance, so that subtype fails closed rather than inventing a
        # latest-wins projection; FindingResolution refs are exact kinds.
        def checkpoint_exact_refs(checkpoint)
          ProjectionPrimitives.checkpoint_exact_refs(checkpoint)
        end

        def exact_refs_of_kind(checkpoint, kind)
          checkpoint_exact_refs(checkpoint).select { |ref| ref.is_a?(Hash) && ref["kind"] == kind }
        end

        def risk_needs_user_predecessor?(predecessor)
          decision = predecessor.is_a?(Hash) && predecessor["lead_decision"]
          decision.is_a?(Hash) &&
            decision["state"] == "needs_user" &&
            decision["action"] == "escalate" &&
            predecessor.dig("reconcile_trigger", "event") == "finding_change"
        end

        # The resolution-driven authority_change subtype: resuming a
        # needs_user risk stop requires the exact needs_user/escalate
        # finding_change predecessor and newly pinned resolution refs
        # covering every risk that predecessor introduced left
        # unadjudicated. Unrelated, partial, or stale pins prove nothing:
        # a ref must name the Finding's UNIQUE CURRENT tip of the verified
        # resolution lineage (a superseded resolution never resumes).
        def resolution_resume_proven?(checkpoint, predecessor)
          return false unless risk_needs_user_predecessor?(predecessor)

          risks = unadjudicated_introduced_risks(predecessor)
          return false if risks.empty?

          new_refs = exact_refs_of_kind(checkpoint, "finding_resolution") -
            exact_refs_of_kind(predecessor, "finding_resolution")
          resolutions = @indexes.fetch("finding_resolutions", {})
          risks.all? do |risk_ref|
            new_refs.any? do |ref|
              resolution = resolutions[ref["id"]]
              resolution && resolution["content_digest"] == ref["digest"] &&
                resolution["finding_id"] == risk_ref["id"] &&
                current_resolution_tip?(resolutions, resolution)
            end
          end
        end

        # The unique current tip: no accepted resolution in the verified
        # lineage supersedes it.
        def current_resolution_tip?(resolutions, resolution)
          resolutions.values.none? do |candidate|
            candidate["supersedes_finding_resolution_id"] == resolution["finding_resolution_id"]
          end
        end

        def unadjudicated_introduced_risks(checkpoint)
          predecessor = @indexes.fetch("lead_checkpoints", {})[
            checkpoint.dig("predecessor_lead_checkpoint_ref", "lead_checkpoint_id")
          ]
          introduced = exact_refs_of_kind(checkpoint, "finding") -
            (predecessor ? exact_refs_of_kind(predecessor, "finding") : [])
          policy = @indexes.fetch("project_policy_revisions", {})[
            checkpoint.dig("project_policy_revision_ref", "policy_revision_id")
          ]
          findings = @indexes.fetch("findings", {})
          resolutions = @indexes.fetch("finding_resolutions", {})
          own_refs = exact_refs_of_kind(checkpoint, "finding_resolution")
          introduced.select do |ref|
            finding = findings[ref["id"]]
            next false unless finding && finding["content_digest"] == ref["digest"] &&
                              finding_disposition(finding, policy) == "adjudication_required"

            own_refs.none? do |resolution_ref|
              resolution = resolutions[resolution_ref["id"]]
              resolution && resolution["content_digest"] == resolution_ref["digest"] &&
                resolution["finding_id"] == ref["id"]
            end
          end
        end
        def introduced_hardening_only?(checkpoint, predecessor)
          introduced = exact_refs_of_kind(checkpoint, "finding") -
            (predecessor ? exact_refs_of_kind(predecessor, "finding") : [])
          policy = @indexes.fetch("project_policy_revisions", {})[
            checkpoint.dig("project_policy_revision_ref", "policy_revision_id")
          ]
          findings = @indexes.fetch("findings", {})
          introduced.any? && introduced.all? do |ref|
            finding = findings[ref["id"]]
            finding && finding["content_digest"] == ref["digest"] &&
              finding_disposition(finding, policy) == "nonblocking"
          end
        end

        def hardening_selection_continuous?(checkpoint, predecessor)
          predecessor.is_a?(Hash) &&
            checkpoint["active_task_ref"] == predecessor["active_task_ref"] &&
            checkpoint["selected_work_unit_ref"] == predecessor["selected_work_unit_ref"] &&
            checkpoint["current_or_terminal_attempt_ref"] == predecessor["current_or_terminal_attempt_ref"]
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
          dispatch = checkpoint.dig("lead_decision", "action") == "dispatch"
          %w[change_thesis rule_resolution].each do |kind|
            count = checkpoint_exact_refs(checkpoint).count { |ref| ref["kind"] == kind }
            if count > 1
              add(
                "checkpoint_proposal_ambiguous",
                "checkpoint must carry at most one exact proposed #{kind} basis ref",
                path
              )
            elsif dispatch && count.zero?
              # The closure basis is frozen AT the dispatch: the successor's
              # ChangeThesis and RuleResolution are exactly proposed here,
              # never chosen later by the Attempt. A generic nil basis is not
              # a legal dispatch.
              add(
                "checkpoint_proposal_missing",
                "dispatch checkpoint must pin exactly one exact proposed #{kind} successor basis ref",
                path
              )
            end
          end
        end

        # Wall-clock fallback (ADR-006): the finite non-zero interval and
        # upper bound come only from the exact active ProjectPolicyRevision
        # orchestration policy or a policy-authorized create-only immutable
        # AuthorizationRecord; the checkpoint pins the exact source ID+digest.
        # The timer itself can only produce the checkpoint_due trigger: a
        # checkpoint awaiting checkpoint_due must pin the fallback, and a
        # pinned fallback is only valid while awaiting checkpoint_due. Mutable
        # config, self-reported intervals, stale digests and non-active
        # policies fail closed.
        def validate_checkpoint_fallback(checkpoint, policies, checkpoints, path)
          fallback = checkpoint["wall_clock_fallback"]
          next_event = checkpoint.dig("next_trigger", "event")
          if next_event == "checkpoint_due" && !fallback.is_a?(Hash)
            add(
              "checkpoint_fallback_invalid",
              "a checkpoint awaiting checkpoint_due must pin an exact wall-clock fallback source",
              "#{path}.wall_clock_fallback"
            )
            return
          end
          if fallback.is_a?(Hash) && next_event != "checkpoint_due"
            add(
              "checkpoint_fallback_invalid",
              "a wall-clock fallback pin is valid only while awaiting checkpoint_due",
              "#{path}.wall_clock_fallback"
            )
            return
          end
          return unless fallback.is_a?(Hash)

          source = fallback["source_ref"] || {}
          case fallback["source_kind"]
          when "policy"
            policy = policies[source["id"]]
            unless policy &&
                   policy["content_digest"] == source["content_digest"] &&
                   policy["policy_revision_id"] ==
                     checkpoint.dig("project_policy_revision_ref", "policy_revision_id") &&
                   policy["content_digest"] ==
                     checkpoint.dig("project_policy_revision_ref", "content_digest")
              add(
                "checkpoint_fallback_invalid",
                "fallback must pin the exact active policy the checkpoint was written under",
                "#{path}.wall_clock_fallback.source_ref"
              )
              return
            end
            interval = policy.dig("orchestration_policy", "wall_clock_fallback", "interval_seconds")
            upper = policy.dig("orchestration_policy", "wall_clock_fallback", "upper_bound_seconds")
            unless interval.is_a?(Integer) && interval >= 1 &&
                   upper.is_a?(Integer) && upper >= interval
              add(
                "checkpoint_fallback_invalid",
                "fallback requires a finite non-zero interval and upper bound from the exact orchestration policy",
                "#{path}.wall_clock_fallback.source_ref"
              )
              return
            end
          when "authorization_record"
            record = @indexes.fetch("authorization_records", {})[source["id"]]
            envelope = record && record["fallback_envelope"]
            expected_scope = envelope && ControlAuthority.fallback_scope_digest(
              project_id: record["project_id"],
              policy_ref: checkpoint["project_policy_revision_ref"],
              lead_control_id: checkpoint["lead_control_id"],
              interval_seconds: envelope["interval_seconds"],
              upper_bound_seconds: envelope["upper_bound_seconds"]
            )
            unless record &&
                   record["content_digest"] == source["content_digest"] &&
                   record["action"] == ControlAuthority::FALLBACK_AUTHORIZE_ACTION &&
                   record["project_policy_revision_id"] ==
                     checkpoint.dig("project_policy_revision_ref", "policy_revision_id") &&
                   envelope.is_a?(Hash) &&
                   record["subject_ref"] == expected_scope &&
                   envelope["scope_digest"] == expected_scope
              add(
                "checkpoint_fallback_invalid",
                "fallback authorization record must exact bind project/policy/control and the finite interval",
                "#{path}.wall_clock_fallback.source_ref"
              )
              return
            end
            interval = envelope["interval_seconds"]
            upper = envelope["upper_bound_seconds"]
            unless interval.is_a?(Integer) && interval >= 1 &&
                   upper.is_a?(Integer) && upper >= interval
              add(
                "checkpoint_fallback_invalid",
                "fallback requires a finite non-zero interval and upper bound from the authorization record",
                "#{path}.wall_clock_fallback.source_ref"
              )
              return
            end
          else
            add(
              "checkpoint_fallback_invalid",
              "fallback source_kind must be policy or authorization_record",
              "#{path}.wall_clock_fallback.source_kind"
            )
            return
          end

          # The deadline is never free text: it must be deterministically
          # derived from the exact trusted schedule basis event (a
          # provider-recorded lifecycle event) plus the exact source
          # interval. A self-reported or drifted deadline fails closed.
          basis = fallback["schedule_basis_ref"] || {}
          basis_event = resolve_exact_event(basis)
          unless basis_event
            add(
              "checkpoint_fallback_invalid",
              "fallback schedule basis must resolve to an exact trusted lifecycle event",
              "#{path}.wall_clock_fallback.schedule_basis_ref"
            )
            return
          end
          # The schedule basis is only the Attempt event already observed by
          # this checkpoint or a strict same-control lineage ancestor: a
          # future, side, or never-observed event cannot anchor the deadline.
          unless schedule_basis_observed_in_lineage?(checkpoint, basis, checkpoints)
            add(
              "checkpoint_fallback_invalid",
              "fallback schedule basis must be an attempt event already pinned by the schedule checkpoint or a strict same-control lineage ancestor",
              "#{path}.wall_clock_fallback.schedule_basis_ref"
            )
            return
          end
          expected_deadline = begin
            ControlAuthority.fallback_deadline(
              recorded_at: basis_event["recorded_at"],
              interval_seconds: interval
            )
          rescue ArgumentError => error
            add("checkpoint_fallback_invalid", error.message, "#{path}.wall_clock_fallback.deadline")
            return
          end
          unless fallback["deadline"] == expected_deadline
            add(
              "checkpoint_fallback_invalid",
              "fallback deadline must equal the trusted schedule basis recorded_at plus the exact source interval",
              "#{path}.wall_clock_fallback.deadline"
            )
          end
        end

        # Resolve a typed exact attempt lifecycle event ref against its
        # authority index with exact event digest. Only attempt events anchor
        # control deadlines; agent events are not generalized into the
        # schedule basis.
        def resolve_exact_event(ref)
          return nil unless ref.is_a?(Hash) && ref["kind"] == "attempt_event"

          attempt = @indexes.fetch("work_unit_attempts", {})[ref["id"]]
          event = attempt && Array(attempt["events"]).find do |candidate|
            candidate["event_id"] == ref["event_id"]
          end
          event && event["event_digest"] == ref["digest"] ? event : nil
        end

        # The schedule basis must have been observed by the control lineage
        # BEFORE this checkpoint: the exact event ref must equal the
        # current_or_terminal_attempt_ref of the checkpoint itself or of a
        # strict same-control lineage ancestor.
        def schedule_basis_observed_in_lineage?(checkpoint, basis_ref, checkpoints)
          cursor = checkpoint
          visited = Set.new
          while cursor
            id = cursor["lead_checkpoint_id"]
            break if visited.include?(id)

            visited << id
            pinned = cursor["current_or_terminal_attempt_ref"]
            if pinned.is_a?(Hash) &&
               basis_ref["id"] == pinned["attempt_id"] &&
               basis_ref["event_id"] == pinned["event_id"] &&
               basis_ref["digest"] == pinned["event_digest"]
              return true
            end
            predecessor_ref = cursor["predecessor_lead_checkpoint_ref"]
            cursor = predecessor_ref && checkpoints[predecessor_ref["lead_checkpoint_id"]]
          end
          false
        end

        # Failure/finding fingerprint authority (ADR-005/006): the only hash
        # input is the canonical fingerprint_identity_basis (versioned scope,
        # typed category/code, stable Finding identity OR stable
        # test/rule/check identity + signal subject + normalized failure
        # code). The supporting provenance never enters the hash; it must
        # support the basis and its ordered prior attempt chain must byte-equal
        # the same-fingerprint occurrences walked across the accepted
        # checkpoint lineage (including exact transfer jumps). Missing stable
        # identity, unknown version, non-recomputable digest, provenance gaps
        # or an inconsistent chain all fail closed.
        def validate_checkpoint_fingerprint(checkpoint, checkpoints, path)
          pinned = pinned_attempt(checkpoint)
          event = pinned && pinned_event(checkpoint)
          failure = event && FAILURE_ATTEMPT_EVENTS.include?(event["event_type"])
          basis = checkpoint["fingerprint_identity_basis"]
          fingerprint = checkpoint["fingerprint"]
          provenance = checkpoint["fingerprint_supporting_provenance"]

          if failure
            unless basis.is_a?(Hash) && fingerprint.is_a?(String) && provenance.is_a?(Hash)
              add(
                "checkpoint_fingerprint_invalid",
                "a failed terminal round requires a provable fingerprint identity, digest, and supporting provenance",
                path
              )
              return
            end
          elsif basis || fingerprint || provenance
            add(
              "checkpoint_fingerprint_invalid",
              "fingerprint fields are allowed only when the pinned attempt event is a failure",
              path
            )
            return
          end
          return unless failure

          unless basis["canonicalization_version"] == ControlAuthority::FINGERPRINT_CANONICALIZATION_VERSION
            add(
              "checkpoint_fingerprint_invalid",
              "unknown fingerprint canonicalization version fails closed",
              "#{path}.fingerprint_identity_basis.canonicalization_version"
            )
          end
          unless fingerprint == ControlAuthority.fingerprint_digest(basis)
            add(
              "checkpoint_fingerprint_invalid",
              "fingerprint must be deterministically recomputable from the identity basis",
              "#{path}.fingerprint"
            )
          end

          scope = basis["scope"] || {}
          task_ref = scope["task_revision_ref"] || {}
          unit_ref = scope["work_unit_ref"] || {}
          task = task_ref["task_revision_id"] &&
            @indexes.fetch("task_revisions", {})[task_ref["task_revision_id"]]
          unit = unit_ref["work_unit_id"] &&
            @indexes.fetch("work_units", {})[unit_ref["work_unit_id"]]
          unless pinned &&
                 task &&
                 task["task_id"] == task_ref["task_id"] &&
                 task["content_digest"] == task_ref["content_digest"] &&
                 unit &&
                 unit["work_unit_id"] == unit_ref["work_unit_id"] &&
                 unit["content_digest"] == unit_ref["content_digest"] &&
                 unit["task_revision_id"] == pinned["task_revision_id"]
            add(
              "checkpoint_fingerprint_invalid",
              "fingerprint identity scope must exact resolve to the pinned failure attempt task/work-unit digests",
              "#{path}.fingerprint_identity_basis.scope"
            )
          end

          category = basis["category"]
          finding_ref = basis["finding_ref"]
          signal = basis["stable_signal_identity"]
          event_signal = pinned_event(checkpoint) && pinned_event(checkpoint)["failure_signal"]
          # The typed failure code is never independently mutable: it must
          # byte-equal the trusted terminal failure signal's normalized code.
          # Without this binding, changing only failure_code would mint a new
          # fingerprint for the SAME real failure and bypass the retry fuse.
          unless event_signal.is_a?(Hash) &&
                 basis["failure_code"] == event_signal["normalized_failure_code"]
            add(
              "checkpoint_fingerprint_invalid",
              "fingerprint failure_code must exact match the trusted terminal failure signal normalized code",
              "#{path}.fingerprint_identity_basis.failure_code"
            )
          end
          if category == "finding"
            unless finding_ref.is_a?(Hash) && signal.nil?
              add(
                "checkpoint_fingerprint_invalid",
                "finding category requires the stable Finding identity and no signal identity",
                "#{path}.fingerprint_identity_basis"
              )
            end
            finding = finding_ref && @indexes.fetch("findings", {})[finding_ref["finding_id"]]
            unless finding && finding["content_digest"] == finding_ref["content_digest"]
              add(
                "checkpoint_fingerprint_invalid",
                "the stable Finding identity must resolve exactly and never be replaced by an outcome record identity",
                "#{path}.fingerprint_identity_basis.finding_ref"
              )
            end
          elsif %w[test rule check].include?(category)
            unless finding_ref.nil? &&
                   signal.is_a?(Hash) &&
                   signal["test_or_check_id"].to_s.length >= 1 &&
                   signal["signal_subject_id"].to_s.length >= 1 &&
                   signal["normalized_failure_code"].to_s.length >= 1
              add(
                "checkpoint_fingerprint_invalid",
                "non-Finding failure requires a stable test/rule/check identity, stable signal subject, and normalized failure code",
                "#{path}.fingerprint_identity_basis"
              )
            end
            # The basis is never free text: it must byte-equal the trusted
            # failure signal recorded on the pinned AttemptFailed/AttemptBlocked
            # terminal event itself (provider-verified lifecycle receipt).
            # Changing the strings of a real signal fails closed.
            unless signal.is_a?(Hash) && event_signal == signal
              add(
                "checkpoint_fingerprint_invalid",
                "fingerprint stable signal identity must exact match the trusted terminal failure signal",
                "#{path}.fingerprint_identity_basis.stable_signal_identity"
              )
            end
          else
            add(
              "checkpoint_fingerprint_invalid",
              "fingerprint category must be finding, test, rule, or check",
              "#{path}.fingerprint_identity_basis.category"
            )
          end
          unless basis["failure_code"].to_s.length >= 1
            add(
              "checkpoint_fingerprint_invalid",
              "fingerprint identity requires a typed normalized failure code",
              "#{path}.fingerprint_identity_basis.failure_code"
            )
          end

          terminal = provenance["terminal_attempt_ref"] || {}
          attempt_ref = checkpoint["current_or_terminal_attempt_ref"] || {}
          unless terminal == attempt_ref
            add(
              "checkpoint_fingerprint_invalid",
              "provenance terminal attempt ref must pin the exact pinned failure event",
              "#{path}.fingerprint_supporting_provenance.terminal_attempt_ref"
            )
          end
          # The authoring checkpoint is the accepted checkpoint that
          # dispatched the failed Attempt (its exact dispatch ref): the
          # fingerprint occurrence is authored for that dispatch. A
          # self-referential pin to the fingerprint-bearing checkpoint would
          # make its own content digest circular, so the authoring ref is
          # always an exact non-circular lineage ancestor.
          authoring = provenance["authoring_checkpoint_ref"] || {}
          dispatch_ref = pinned && pinned["dispatch_lead_checkpoint_ref"]
          unless dispatch_ref.is_a?(Hash) &&
                 authoring["lead_checkpoint_id"] == dispatch_ref["lead_checkpoint_id"] &&
                 authoring["content_digest"] == dispatch_ref["content_digest"]
            add(
              "checkpoint_fingerprint_invalid",
              "provenance authoring checkpoint ref must exact pin the failed Attempt dispatch checkpoint",
              "#{path}.fingerprint_supporting_provenance.authoring_checkpoint_ref"
            )
          end
          outcomes = Array(provenance["outcome_refs"])
          if outcomes.empty?
            add(
              "checkpoint_fingerprint_invalid",
              "provenance requires exact outcome refs supporting the identity basis",
              "#{path}.fingerprint_supporting_provenance.outcome_refs"
            )
          end
          outcomes.each do |outcome|
            next if outcome.is_a?(Hash)

            add(
              "checkpoint_fingerprint_invalid",
              "outcome refs must be typed exact refs",
              "#{path}.fingerprint_supporting_provenance.outcome_refs"
            )
          end
          validate_supporting_refs(outcomes, path, "fingerprint_supporting_provenance")
          if category == "finding" && finding_ref.is_a?(Hash) &&
             !outcomes.any? do |outcome|
               outcome.is_a?(Hash) &&
                 outcome["kind"] == "finding" &&
                 outcome["id"] == finding_ref["finding_id"] &&
                 outcome["digest"] == finding_ref["content_digest"]
             end
            add(
              "checkpoint_fingerprint_invalid",
              "finding occurrence provenance must include the stable Finding ref",
              "#{path}.fingerprint_supporting_provenance.outcome_refs"
            )
          end

          expected_chain = fingerprint_occurrence_chain(checkpoint, fingerprint, checkpoints)
          unless Array(provenance["prior_attempt_chain"]) == expected_chain
            add(
              "checkpoint_fingerprint_invalid",
              "prior attempt chain must byte-equal the same-fingerprint occurrences across the accepted checkpoint lineage",
              "#{path}.fingerprint_supporting_provenance.prior_attempt_chain"
            )
          end
          attempts = @indexes.fetch("work_unit_attempts", {})
          Array(provenance["prior_attempt_chain"]).each do |prior_ref|
            prior = prior_ref && attempts[prior_ref["attempt_id"]]
            prior_event = prior && Array(prior["events"]).find do |candidate|
              candidate["event_id"] == prior_ref["event_id"]
            end
            unless prior &&
                   prior_event &&
                   prior_event["event_digest"] == prior_ref["event_digest"] &&
                   prior["work_unit_id"] == pinned["work_unit_id"] &&
                   FAILURE_ATTEMPT_EVENTS.include?(prior_event["event_type"])
              add(
                "checkpoint_fingerprint_invalid",
                "prior chain entries must resolve to exact same-scope failure events",
                "#{path}.fingerprint_supporting_provenance.prior_attempt_chain"
              )
            end
          end
        end

        # Ordered same-fingerprint occurrences across the accepted lineage:
        # walk the exact predecessor chain of the same control and, at an
        # accepted task acquire checkpoint, jump into the released control's
        # lineage through the exact release/suspend checkpoint ref, so the
        # chain stays continuous across Task transfers. The chain serves
        # occurrence counting and retry-authorization scope only.
        def fingerprint_occurrence_chain(checkpoint, fingerprint, checkpoints)
          chain = []
          visited = Set.new
          counted_events = Set.new
          current_ref = checkpoint["current_or_terminal_attempt_ref"]
          cursor = checkpoint["predecessor_lead_checkpoint_ref"] &&
            checkpoints[checkpoint["predecessor_lead_checkpoint_ref"]["lead_checkpoint_id"]]
          while cursor
            id = cursor["lead_checkpoint_id"]
            break if visited.include?(id)

            visited << id
            if cursor["fingerprint"] == fingerprint
              ref = cursor["current_or_terminal_attempt_ref"]
              if ref.is_a?(Hash) && ref != current_ref
                # One failure OCCURRENCE is counted exactly once by its exact
                # terminal event identity, no matter how many intermediate
                # checkpoints re-pin the same historical event; the chain
                # stays in stable lineage order.
                key = [ref["attempt_id"], ref["event_id"], ref["event_digest"]]
                if counted_events.add?(key)
                  chain.unshift(ref)
                end
              end
            end
            acquire = cursor["task_transfer_acquire"]
            if acquire.is_a?(Hash)
              released = acquire["released_checkpoint_ref"] &&
                checkpoints[acquire["released_checkpoint_ref"]["lead_checkpoint_id"]]
              cursor = released
            else
              predecessor_ref = cursor["predecessor_lead_checkpoint_ref"]
              cursor = predecessor_ref && checkpoints[predecessor_ref["lead_checkpoint_id"]]
            end
          end
          chain
        end

        # The third same-fingerprint Attempt may be dispatched only against a
        # provider-verified create-only immutable task.retry.override
        # AuthorizationRecord whose canonical scope exact binds project,
        # TaskRevision ref, WorkUnit ref, the normalized fingerprint, the
        # ordered prior Attempt chain, the authorizing checkpoint ref and the
        # lead_control_id. The record must be pre-existing (create-only) and
        # consumed by exactly one checkpoint; absent, self-reported, opaque,
        # mismatched, replayable or cross-scope refs fail closed.
        def validate_retry_override(checkpoint, checkpoints, path)
          pinned = pinned_attempt(checkpoint)
          event = pinned && pinned_event(checkpoint)
          failure = event && FAILURE_ATTEMPT_EVENTS.include?(event["event_type"])
          override_ref = checkpoint["retry_override_ref"]
          # The override binds only the checkpoint that AUTHORIZES the third
          # dispatch. A needs_user checkpoint (the terminal observation of the
          # second failure) proves the absence of authority and carries no
          # override ref.
          third_pending =
            failure &&
            checkpoint.dig("lead_decision", "action") == "dispatch" &&
            fingerprint_occurrence_chain(checkpoint, checkpoint["fingerprint"], checkpoints).length >= 1

          unless third_pending
            if override_ref
              add(
                "checkpoint_retry_override_invalid",
                "retry_override_ref is allowed only when the third same-fingerprint dispatch is pending",
                "#{path}.retry_override_ref"
              )
            end
            return
          end

          unless override_ref.is_a?(Hash)
            add(
              "checkpoint_retry_override_invalid",
              "the third same-fingerprint dispatch requires an exact provider-verified task.retry.override ref",
              "#{path}.retry_override_ref"
            )
            return
          end
          record = @indexes.fetch("authorization_records", {})[override_ref["authorization_record_id"]]
          unless record && record["content_digest"] == override_ref["content_digest"] &&
                 record["action"] == ControlAuthority::RETRY_OVERRIDE_ACTION
            add(
              "checkpoint_retry_override_invalid",
              "retry_override_ref must resolve to an exact task.retry.override AuthorizationRecord",
              "#{path}.retry_override_ref"
            )
            return
          end

          envelope = record["retry_override_envelope"] || {}
          task_ref = checkpoint["active_task_ref"]
          unit_ref = checkpoint["selected_work_unit_ref"]
          fingerprint = checkpoint["fingerprint"]
          prior_chain = Array(checkpoint.dig("fingerprint_supporting_provenance", "prior_attempt_chain")) +
            [checkpoint["current_or_terminal_attempt_ref"]]
          # The authorizing checkpoint is the accepted checkpoint that
          # recorded the second same-fingerprint occurrence (where the third
          # dispatch became pending): the record is authorized against that
          # fixed ancestor, and the consuming dispatch checkpoint only
          # references the pre-existing record. This keeps every content
          # digest non-circular.
          authorizing_ref = envelope["authorizing_checkpoint_ref"]
          authorizing = authorizing_ref &&
            checkpoints[authorizing_ref["lead_checkpoint_id"]]
          expected_scope = ControlAuthority.retry_override_scope_digest(
            project_id: checkpoint["project_id"],
            task_ref: task_ref,
            work_unit_ref: unit_ref,
            fingerprint: fingerprint,
            prior_attempt_chain: prior_chain,
            authorizing_checkpoint_ref: authorizing_ref,
            lead_control_id: checkpoint["lead_control_id"]
          )
          authorizing_valid =
            authorizing.is_a?(Hash) &&
            authorizing["content_digest"] == authorizing_ref["content_digest"] &&
            authorizing["lead_control_id"] == checkpoint["lead_control_id"] &&
            authorizing["fingerprint"] == fingerprint &&
            authorizing["current_or_terminal_attempt_ref"] == prior_chain.last &&
            lineage_ancestor?(checkpoint, authorizing_ref["lead_checkpoint_id"], checkpoints)
          unless authorizing_valid &&
                 envelope["scope_digest"] == expected_scope &&
                 record["subject_ref"] == expected_scope &&
                 envelope["project_id"] == checkpoint["project_id"] &&
                 envelope["task_ref"] == task_ref &&
                 envelope["work_unit_ref"] == unit_ref &&
                 envelope["fingerprint"] == fingerprint &&
                 envelope["prior_attempt_chain"] == prior_chain &&
                 envelope["authorizing_checkpoint_ref"] == authorizing_ref &&
                 envelope["lead_control_id"] == checkpoint["lead_control_id"]
            add(
              "checkpoint_retry_override_invalid",
              "task.retry.override scope must exact bind project/TaskRevision/WorkUnit/fingerprint/prior chain/authorizing checkpoint/control",
              "#{path}.retry_override_ref"
            )
          end
          consumers = checkpoints.values.select do |candidate|
            ref = candidate["retry_override_ref"]
            ref.is_a?(Hash) &&
              ref["authorization_record_id"] == record["authorization_record_id"]
          end
          unless consumers.length == 1 && consumers.first["lead_checkpoint_id"] == checkpoint["lead_checkpoint_id"]
            add(
              "checkpoint_retry_override_invalid",
              "a task.retry.override record can be consumed by exactly one accepted checkpoint",
              "#{path}.retry_override_ref"
            )
          end
          # Consumption binds the exact active policy the consuming
          # checkpoint was written under: a record issued under an old or
          # revoked policy can never be consumed after rotation.
          active_policy = @indexes.fetch("project_policy_revisions", {})[
            checkpoint.dig("project_policy_revision_ref", "policy_revision_id")
          ]
          grant = unique_policy_grant(active_policy, ControlAuthority::RETRY_OVERRIDE_ACTION)
          issuer = @verified_authority_assertions[record["authorization_source_ref"]]
          unless record["project_policy_revision_id"] ==
                   checkpoint.dig("project_policy_revision_ref", "policy_revision_id") &&
                 grant.is_a?(Hash) &&
                 issuer.is_a?(Hash) &&
                 Array(issuer["grants"]).include?(grant["required_external_grant"])
            add(
              "checkpoint_retry_override_invalid",
              "the retry override must be granted by the exact active policy trusted at consumption",
              "#{path}.retry_override_ref"
            )
          end
        end

        # Canonical two-layer effective budget bindings (ADR-004/006): exactly
        # two entries in fixed work_unit_lineage/task_lineage order, each
        # deterministically derivable from the authoritative facts (policy
        # defaults, in-ceiling lead adjustment with its independent digest,
        # pre-existing user override consumed once or inherited along the
        # continuous lineage). Measurements are the binding's own current
        # observation: verified requires usage >= 0 with an exact
        # provider/snapshot ref; unverified requires canonical nulls plus the
        # typed unverified_assessment with the exact pending mapping. Slice 2
        # supports unverified pending/default dispatch only: accepted/rejected
        # review states depend on the Slice 4 independent budget assessment
        # consumer and fail closed here.
        def validate_checkpoint_budget(checkpoint, predecessor, policies, checkpoints, path)
          bindings = Array(checkpoint["effective_budget_bindings"])
          unless bindings.length == 2 &&
                 bindings.map { |binding| binding["budget_scope_type"] } == ControlAuthority::BUDGET_SCOPES
            add(
              "checkpoint_budget_invalid",
              "effective_budget_bindings must be exactly two entries in fixed work_unit_lineage/task_lineage order",
              "#{path}.effective_budget_bindings"
            )
            return
          end
          policy = policies[checkpoint.dig("project_policy_revision_ref", "policy_revision_id")]
          unless policy.is_a?(Hash) &&
                 policy["content_digest"] == checkpoint.dig("project_policy_revision_ref", "content_digest")
            return
          end

          payload = checkpoint["test_budget_adjust"]
          adjustment_digest = checkpoint["budget_adjustment_digest"]
          if payload.is_a?(Hash)
            unless adjustment_digest == ControlAuthority.budget_adjustment_digest(payload)
              add(
                "checkpoint_budget_invalid",
                "budget_adjustment_digest must equal the canonical digest of the typed adjust payload",
                "#{path}.budget_adjustment_digest"
              )
            end
            # The typed adjust payload's supporting refs are schema-authorized
            # source inputs; they resolve exactly through the same typed
            # exact-ref seam as checkpoint provenance, so forged, missing, or
            # digest-mismatched refs fail closed here.
            validate_supporting_refs(Array(payload["supporting_refs"]), path, "budget adjustment")
          elsif adjustment_digest
            add(
              "checkpoint_budget_invalid",
              "budget_adjustment_digest must be explicitly absent when no adjustment exists",
              "#{path}.budget_adjustment_digest"
            )
          end

          bindings.each_with_index do |binding, index|
            scope = ControlAuthority::BUDGET_SCOPES[index]
            bp = "#{path}.effective_budget_bindings[#{index}]"
            unless binding["project_policy_revision_ref"] == checkpoint["project_policy_revision_ref"]
              add(
                "checkpoint_budget_invalid",
                "binding policy ref must equal the exact active policy pin",
                "#{bp}.project_policy_revision_ref"
              )
            end
            validate_budget_measurements(
              binding["measurements"],
              bp,
              scope: scope,
              project_id: checkpoint["project_id"],
              policy_ref: checkpoint["project_policy_revision_ref"],
              task_ref: checkpoint["active_task_ref"],
              work_unit_ref:
                scope == "work_unit_lineage" ? checkpoint["selected_work_unit_ref"] : nil
            )

            predecessor_binding =
              predecessor &&
              Array(predecessor["effective_budget_bindings"])[index]
            predecessor_ref = checkpoint["predecessor_lead_checkpoint_ref"]
            payload_for_scope =
              payload.is_a?(Hash) && payload["budget_scope_type"] == scope ? payload : nil
            override_source = binding["user_override_source"]
            override_record = override_source.is_a?(Hash) &&
              (ref = override_source["authorization_record_ref"]) &&
              @indexes.fetch("authorization_records", {})[ref["authorization_record_id"]]
            begin
              expected = ControlAuthority.derive_binding(
                scope: scope,
                project_id: checkpoint["project_id"],
                control_id: checkpoint["lead_control_id"],
                policy: policy,
                policy_ref: checkpoint["project_policy_revision_ref"],
                predecessor_binding: predecessor_binding,
                predecessor_checkpoint_ref: predecessor_ref,
                adjustment_payload: payload_for_scope,
                adjustment_digest: adjustment_digest,
                override_record: override_record,
                override_mode: override_source.is_a?(Hash) ? override_source["mode"] : nil,
                origin_consuming_checkpoint_ref:
                  override_source.is_a?(Hash) ? override_source["origin_consuming_checkpoint_ref"] : nil,
                active_task_ref: checkpoint["active_task_ref"],
                # The WorkUnit ref binds ONLY the work_unit_lineage scope;
                # task_lineage overrides carry the canonical null (ADR-006).
                work_unit_ref:
                  scope == "work_unit_lineage" ? checkpoint["selected_work_unit_ref"] : nil,
                predecessor_work_unit_ref:
                  scope == "work_unit_lineage" ?
                    (predecessor && predecessor["selected_work_unit_ref"]) : nil,
                measurements: binding["measurements"]
              )
            rescue ArgumentError => error
              add("checkpoint_budget_invalid", error.message, bp)
              next
            end
            unless expected == binding
              add(
                "checkpoint_budget_invalid",
                "effective budget binding must be deterministically derivable from the authoritative facts",
                bp
              )
            end
            # Slice 4 semantics: a lead_adjustment may rest on
            # provider-attested verified measurements OR on an unverified
            # metric whose exact independent budget review was accepted;
            # pending unverified never authorizes dispatch/closure for the
            # adjustment, but a non-dispatch review-bound proposal may carry
            # pending measurements awaiting that exact review. Rejected
            # replays frozen via the deterministic guard.
            if binding["source_kind"] == "lead_adjustment" &&
               checkpoint.dig("lead_decision", "action") == "dispatch"
              %w[test_count test_code_lines].each do |key|
                metric = binding.dig("measurements", key)
                accepted = metric.is_a?(Hash) &&
                  metric.dig("unverified_assessment", "review_status") == "accepted" &&
                  metric.dig("unverified_assessment", "review_gate_evaluation_ref").is_a?(Hash)
                unless metric.is_a?(Hash) && (metric["status"] == "verified" || accepted)
                  add(
                    "checkpoint_budget_invalid",
                    "lead_adjustment requires provider-attested verified measurements or an exact accepted independent budget review",
                    "#{bp}.measurements.#{key}"
                  )
                end
              end
            end
          end
          validate_budget_review_consumption(checkpoint, predecessor, bindings, path)
          validate_override_consumption(checkpoint, checkpoints, path)
        end

        # Slice 4 increment 2: the one-way C_pending -> independent
        # GateEvaluation -> immediate successor C_reviewed consumption. The
        # consuming binding's accepted/rejected review must resolve to an
        # exact budget-assessment GateEvaluation whose result binds the exact
        # immediate predecessor checkpoint/binding and whose subject
        # projection is byte-identical (fresh) — the complete binding digest
        # is never a freshness basis.
        def validate_budget_review_consumption(checkpoint, predecessor, bindings, path)
          bindings.each_with_index do |binding, index|
            measurements = binding.is_a?(Hash) ? binding["measurements"] : nil
            next unless measurements.is_a?(Hash)

            unverified_metrics = %w[test_count test_code_lines].select do |key|
              measurements.dig(key, "status") == "unverified"
            end
            next if unverified_metrics.empty?

            statuses = unverified_metrics.map do |key|
              measurements.dig(key, "unverified_assessment", "review_status")
            end
            next unless statuses.any? { |status| %w[accepted rejected].include?(status) }

            scope = ControlAuthority::BUDGET_SCOPES[index]
            bp = "#{path}.effective_budget_bindings[#{index}]"
            refs = unverified_metrics.map do |key|
              measurements.dig(key, "unverified_assessment", "review_gate_evaluation_ref")
            end
            unless statuses.all? { |status| %w[accepted rejected].include?(status) } &&
                   statuses.uniq.length == 1 && refs.uniq.length == 1 &&
                   refs.first.is_a?(Hash)
              add(
                "checkpoint_budget_invalid",
                "every unverified metric must consume the same exact accepted/rejected review ref",
                bp
              )
              next
            end
            # A review already consumed by the immediate predecessor is
            # inherited. Inheritance is never an early skip: the current
            # projection must stay byte-identical to the predecessor
            # projection, so no successor can reuse a stale assessment after
            # changing source, ceilings, reason codes, or any other
            # non-review field.
            if predecessor.is_a?(Hash)
              previous_binding = Array(predecessor["effective_budget_bindings"])[index]
              if previous_binding
                previous_unverified = %w[test_count test_code_lines].select do |key|
                  previous_binding.dig("measurements", key, "status") == "unverified"
                end
                previous_refs = previous_unverified.map do |key|
                  previous_binding.dig("measurements", key, "unverified_assessment", "review_gate_evaluation_ref")
                end
                if previous_refs.any? && previous_refs.first == refs.first
                  previous_projection =
                    Orbit::V2::ControlAuthority.budget_review_subject_projection_digest(previous_binding)
                  current_projection =
                    Orbit::V2::ControlAuthority.budget_review_subject_projection_digest(binding)
                  unless current_projection == previous_projection
                    add(
                      "budget_assessment_invalid",
                      "an inherited accepted review must preserve the assessed projection byte-for-byte",
                      bp
                    )
                  end
                  next
                end
              end
            end
            evaluation = @indexes.fetch("gate_evaluations", {})[refs.first["gate_evaluation_id"]]
            unless evaluation && evaluation["content_digest"] == refs.first["content_digest"]
              add(
                "checkpoint_budget_invalid",
                "review gate evaluation ref must resolve to an exact GateEvaluation",
                "#{bp}.measurements"
              )
              next
            end
            result = evaluation["budget_assessment_result"]
            unless result.is_a?(Hash)
              add(
                "budget_assessment_invalid",
                "an ordinary GateEvaluation cannot close an unverified budget review",
                "#{bp}.measurements"
              )
              next
            end
            unless result["outcome"] == statuses.first
              add(
                "budget_assessment_invalid",
                "budget assessment outcome must equal the consumed review status",
                "#{bp}.measurements"
              )
            end
            unless result["scope"] == scope &&
                   result["lead_control_id"] == checkpoint["lead_control_id"]
              add(
                "budget_assessment_invalid",
                "consumed assessment scope and lead_control must match the consuming binding",
                "#{bp}.measurements"
              )
            end
            assessed_ref = result["assessed_checkpoint_ref"]
            predecessor_ref = checkpoint["predecessor_lead_checkpoint_ref"]
            unless predecessor.is_a?(Hash) &&
                   assessed_ref == {
                     "lead_checkpoint_id" => predecessor["lead_checkpoint_id"],
                     "content_digest" => predecessor["content_digest"]
                   }
              add(
                "budget_assessment_invalid",
                "the assessed checkpoint must be the exact immediate lineage predecessor (never self or non-predecessor)",
                "#{bp}.measurements"
              )
              next
            end
            predecessor_binding = Array(predecessor["effective_budget_bindings"])[index]
            projection = Orbit::V2::ControlAuthority.budget_review_subject_projection_digest(
              predecessor_binding
            )
            unless result["assessed_effective_budget_binding_digest"] ==
                   Orbit::V2::ControlAuthority.binding_digest(predecessor_binding)
              add(
                "budget_assessment_invalid",
                "assessed binding digest must equal the complete assessed predecessor binding digest",
                "#{bp}.measurements"
              )
            end

            unless evaluation.dig("subject", "budget_review_subject_projection") == projection
              add(
                "budget_assessment_invalid",
                "subject projection must equal the canonical predecessor binding projection",
                "#{bp}.measurements"
              )
            end
            current_projection =
              Orbit::V2::ControlAuthority.budget_review_subject_projection_digest(binding)
            unless current_projection == projection ||
                   Orbit::V2::ControlAuthority.exact_budget_review_transition?(binding, predecessor_binding, predecessor_ref)
              add(
                "budget_assessment_invalid",
                "the consuming binding must be byte-identical to the assessed binding excluding only the review result fields, or make exactly one deterministic current-to-inherited adjustment-source transition",
                "#{bp}.measurements"
              )
            end
          end
        end
        def validate_budget_measurements(measurements, path, scope:, project_id:, policy_ref:, task_ref:, work_unit_ref:)
          unless measurements.is_a?(Hash) &&
                 measurements.keys.sort == %w[test_code_lines test_count]
            add(
              "checkpoint_budget_invalid",
              "measurements require exactly the canonical test_count and test_code_lines metrics",
              "#{path}.measurements"
            )
            return
          end
          %w[test_count test_code_lines].each do |key|
            measurement = measurements[key]
            mp = "#{path}.measurements.#{key}"
            unless measurement.is_a?(Hash) &&
                   %w[verified unverified].include?(measurement["status"])
              add(
                "checkpoint_budget_invalid",
                "measurement status must be verified or unverified",
                mp
              )
              next
            end
            if measurement["status"] == "verified"
              usage = measurement["usage"]
              source = measurement["source_ref"]
              unless usage.is_a?(Integer) && usage >= 0 &&
                     source.is_a?(Hash) &&
                     measurement["unverified_assessment"].nil?
                add(
                  "checkpoint_budget_invalid",
                  "verified measurement requires usage >= 0, an exact attestation ref, and no assessment",
                  mp
                )
                next
              end
              unless verified_measurement_source_resolves?(
                source,
                usage: usage,
                metric_identity: key,
                scope: scope,
                project_id: project_id,
                policy_ref: policy_ref,
                task_ref: task_ref,
                work_unit_ref: work_unit_ref
              )
                add(
                  "checkpoint_budget_invalid",
                  "verified measurement source must resolve to an exact provider-verified measurement attestation bound to metric/usage/scope/snapshot",
                  "#{mp}.source_ref"
                )
              end
            else
              usage = measurement["usage"]
              source = measurement["source_ref"]
              assessment = measurement["unverified_assessment"]
              unless usage.nil? && source.nil? && assessment.is_a?(Hash)
                add(
                  "checkpoint_budget_invalid",
                  "unverified measurement requires canonical null usage/source and a typed unverified assessment",
                  mp
                )
                next
              end
              unless assessment.keys.sort == %w[
                lead_disposition lead_reason_code lead_supporting_refs
                review_gate_evaluation_ref review_status
              ]
                add(
                  "checkpoint_budget_invalid",
                  "unverified_assessment requires the fixed field set",
                  "#{mp}.unverified_assessment"
                )
                next
              end
              review_status = assessment["review_status"]
              expected_disposition = {
                "pending" => "proceed_pending_independent_review",
                "accepted" => "proceed_after_independent_review",
                "rejected" => "replan_after_independent_rejection"
              }[review_status]
              unless expected_disposition && assessment["lead_disposition"] == expected_disposition
                add(
                  "checkpoint_budget_invalid",
                  "lead_disposition and review_status must exact match",
                  "#{mp}.unverified_assessment"
                )
                next
              end
              if review_status == "pending"
                unless assessment["review_gate_evaluation_ref"].nil?
                  add(
                    "checkpoint_budget_invalid",
                    "pending review requires a canonical null review gate evaluation ref",
                    "#{mp}.unverified_assessment"
                  )
                end
              else
                ref = assessment["review_gate_evaluation_ref"]
                unless ref.is_a?(Hash) &&
                       Identifiers.valid?("gate_evaluation_id", ref["gate_evaluation_id"]) &&
                       Identifiers.digest?(ref["content_digest"])
                  add(
                    "checkpoint_budget_invalid",
                    "accepted/rejected review requires an exact review gate evaluation ref",
                    "#{mp}.unverified_assessment.review_gate_evaluation_ref"
                  )
                end
              end
              unless assessment["lead_reason_code"].to_s.length >= 1
                add(
                  "checkpoint_budget_invalid",
                  "unverified_assessment requires a lead reason code",
                  "#{mp}.unverified_assessment"
                )
              end
              refs = assessment["lead_supporting_refs"]
              unless refs.is_a?(Array) &&
                     refs == refs.uniq &&
                     refs == refs.sort_by { |ref| [ref["kind"], ref["id"], ref["digest"]].join("\u0000") }
                add(
                  "checkpoint_budget_invalid",
                  "lead_supporting_refs must be sorted unique exact refs",
                  "#{mp}.unverified_assessment.lead_supporting_refs"
                )
              end
              validate_supporting_refs(refs, path, "assessment")
            end
          end
        end

        # Verified usage is never self-reported and never a bare snapshot
        # reference: each metric resolves to its own provider-verified
        # test.measurement.attest assertion whose canonical scope exact binds
        # project, active policy, TaskRevision, the scope-appropriate WorkUnit
        # ref (exact for work_unit_lineage, canonical null for task_lineage),
        # the metric identity, the usage and the repository snapshot
        # ref+digest. Without a real scanner adapter a bare snapshot cannot
        # claim verified.
        def verified_measurement_source_resolves?(
          source, usage:, metric_identity:, scope:, project_id:, policy_ref:,
          task_ref:, work_unit_ref:
        )
          return false unless source.is_a?(Hash) && source["kind"] == "measurement_attestation"

          assertion = @verified_authority_assertions[source["id"]]
          envelope = assertion && assertion["measurement_attestation_envelope"]
          policy = @indexes.fetch("project_policy_revisions", {})[policy_ref["policy_revision_id"]]
          grant = unique_policy_grant(policy, ControlAuthority::MEASUREMENT_ATTEST_ACTION)
          return false unless assertion &&
                              assertion["assertion_digest"] == source["digest"] &&
                              envelope.is_a?(Hash) &&
                              assertion["checkpoint_due_observation_envelope"].nil? &&
                              %w[user control_plane].include?(assertion["issuer_kind"]) &&
                              grant.is_a?(Hash) &&
                              Array(assertion["grants"]).include?(grant["required_external_grant"])

          expected_scope = ControlAuthority.measurement_scope_digest(
            project_id: assertion["project_id"],
            policy_ref: policy_ref,
            task_ref: task_ref,
            work_unit_ref: work_unit_ref,
            metric_identity: metric_identity,
            usage: usage,
            snapshot_ref: envelope["repository_snapshot_ref"]
          )
          snapshot = @bundle_snapshot
          envelope["scope_digest"] == expected_scope &&
            assertion["authority_scope_ref"] == expected_scope &&
            envelope["project_id"] == project_id &&
            envelope["project_policy_revision_ref"] == policy_ref &&
            envelope["task_revision_ref"] == task_ref &&
            envelope["work_unit_ref"] == work_unit_ref &&
            envelope["metric_identity"] == metric_identity &&
            envelope["usage"] == usage &&
            envelope["repository_snapshot_ref"] ==
              { "id" => "repository-snapshot", "digest" => snapshot && snapshot["tree_digest"] }
        end

        # user_override consumption: a record is consumed by exactly one
        # origin checkpoint; every later binding inherits only along the
        # continuous accepted lineage of the same project/policy/TaskRevision/
        # scope/control with the exact origin ref at every step. A second
        # consume, a skipped origin, a cross-lineage/scope inherit or a
        # ceiling change fails closed. Work-unit-level overrides never relax
        # the task-level budget: the two bindings derive independently and
        # each carries its own exact scope.
        def validate_override_consumption(checkpoint, checkpoints, path)
          Array(checkpoint["effective_budget_bindings"]).each do |binding|
            source = binding["user_override_source"]
            next unless source.is_a?(Hash)

            record_id = source.dig("authorization_record_ref", "authorization_record_id")
            if source["mode"] == "consume"
              consumers = checkpoints.values.select do |candidate|
                Array(candidate["effective_budget_bindings"]).any? do |candidate_binding|
                  candidate_source = candidate_binding["user_override_source"]
                  candidate_source.is_a?(Hash) &&
                    candidate_source["mode"] == "consume" &&
                    candidate_source.dig("authorization_record_ref", "authorization_record_id") == record_id
                end
              end
              unless consumers.length == 1 &&
                     consumers.first["lead_checkpoint_id"] == checkpoint["lead_checkpoint_id"]
                add(
                  "checkpoint_budget_invalid",
                  "a test.budget.override record can be consumed by exactly one origin checkpoint",
                  "#{path}.effective_budget_bindings"
                )
              end
            elsif source["mode"] == "inherit"
              origin_ref = source["origin_consuming_checkpoint_ref"]
              origin = origin_ref && checkpoints[origin_ref["lead_checkpoint_id"]]
              unless origin &&
                     origin_ref["content_digest"] == origin["content_digest"] &&
                     origin["lead_control_id"] == checkpoint["lead_control_id"]
                add(
                  "checkpoint_budget_invalid",
                  "override inherit must bind the exact origin consuming checkpoint of the same control",
                  "#{path}.effective_budget_bindings"
                )
                next
              end
              origin_consume = Array(origin["effective_budget_bindings"]).find do |candidate|
                candidate["budget_scope_type"] == binding["budget_scope_type"]
              end
              origin_source = origin_consume && origin_consume["user_override_source"]
              unless origin_source.is_a?(Hash) &&
                     origin_source["mode"] == "consume" &&
                     origin_source.dig("authorization_record_ref", "authorization_record_id") == record_id
                add(
                  "checkpoint_budget_invalid",
                  "override inherit must reach an origin checkpoint that consumed the same record for the same scope",
                  "#{path}.effective_budget_bindings"
                )
                next
              end
              unless override_lineage_continuous?(checkpoint, origin, record_id, binding["budget_scope_type"], checkpoints)
                add(
                  "checkpoint_budget_invalid",
                  "override inherit requires a continuous accepted lineage with no superseding source and no skipped origin",
                  "#{path}.effective_budget_bindings"
                )
              end
            end
          end
        end

        def override_lineage_continuous?(checkpoint, origin, record_id, scope, checkpoints)
          cursor = checkpoint["predecessor_lead_checkpoint_ref"] &&
            checkpoints[checkpoint["predecessor_lead_checkpoint_ref"]["lead_checkpoint_id"]]
          while cursor && cursor["lead_checkpoint_id"] != origin["lead_checkpoint_id"]
            binding = Array(cursor["effective_budget_bindings"]).find do |candidate|
              candidate["budget_scope_type"] == scope
            end
            source = binding && binding["user_override_source"]
            unless source.is_a?(Hash) &&
                   source["mode"] == "inherit" &&
                   source.dig("authorization_record_ref", "authorization_record_id") == record_id
              return false
            end
            ref = cursor["predecessor_lead_checkpoint_ref"]
            cursor = ref && checkpoints[ref["lead_checkpoint_id"]]
          end
          cursor.is_a?(Hash)
        end

        # The one-way digest chain recomputed byte-identical from the exact
        # authoritative inputs: complete ordered effective_budget_bindings ->
        # effective_verification_plan_digest -> closure_basis_digest. The
        # enclosing checkpoint identity never enters any preimage (no
        # self-reference) and no plan truth object exists; a stored digest
        # that cannot be recomputed fails closed.
        def validate_checkpoint_digests(checkpoint, tasks, attempts, path)
          bindings = Array(checkpoint["effective_budget_bindings"])
          policy_ref = checkpoint["project_policy_revision_ref"]
          task_ref = checkpoint["active_task_ref"]
          task_ref ||= Array(checkpoint["task_queue"]).first
          rule_ref = basis_rule_ref(checkpoint)
          plan = ControlAuthority.effective_verification_plan_digest(
            policy_ref: policy_ref,
            task_revision_ref: task_ref,
            assigned_rule_resolution_ref: rule_ref,
            effective_budget_bindings: bindings
          )
          unless checkpoint["effective_verification_plan_digest"] == plan
            add(
              "checkpoint_digest_invalid",
              "effective_verification_plan_digest must be recomputable byte-identical from the ordered bindings and authoritative inputs",
              "#{path}.effective_verification_plan_digest"
            )
          end
          thesis_ref = basis_thesis_ref(checkpoint)
          basis = ControlAuthority.closure_basis_digest(
            task_revision_ref: task_ref,
            work_unit_ref: checkpoint["selected_work_unit_ref"],
            change_thesis_ref: thesis_ref,
            assigned_rule_resolution_ref: rule_ref,
            effective_verification_plan_digest: plan
          )
          unless checkpoint["closure_basis_digest"] == basis
            add(
              "checkpoint_digest_invalid",
              "closure_basis_digest must be recomputable byte-identical from the frozen dispatch-time refs",
              "#{path}.closure_basis_digest"
            )
          end
        end

        # The dispatch-time basis: the single exact proposed successor ref of
        # the authorizing checkpoint, else — only for an observation
        # checkpoint (reconcile on attempt_created, which pins the created
        # Attempt itself) — the pinned Attempt's actual assignment. A
        # terminal-dispatch checkpoint pins the PREVIOUS Attempt's terminal
        # event, so its basis is the proposal (canonical null when none was
        # authorized), never the previous Attempt's assignment.
        def basis_rule_ref(checkpoint)
          ProjectionPrimitives.basis_rule_ref(
            checkpoint,
            @indexes.fetch("rule_resolution_artifacts", {}),
            @indexes.fetch("work_unit_attempts", {})
          )
        end

        def basis_thesis_ref(checkpoint)
          ProjectionPrimitives.basis_thesis_ref(
            checkpoint,
            @indexes.fetch("work_unit_attempts", {}),
            change_thesis_digests
          )
        end

        def pinned_event(checkpoint)
          ref = checkpoint["current_or_terminal_attempt_ref"]
          return nil unless ref.is_a?(Hash)

          attempt = @indexes.fetch("work_unit_attempts", {})[ref["attempt_id"]]
          event = attempt && Array(attempt["events"]).find do |candidate|
            candidate["event_id"] == ref["event_id"]
          end
          event && event["event_digest"] == ref["event_digest"] ? event : nil
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
          ProjectionPrimitives.pinned_attempt(
            checkpoint,
            @indexes.fetch("work_unit_attempts", {})
          )
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
            when "finding_resolution"
              resolve_typed_ref(ref, @indexes.fetch("finding_resolutions", {}), "finding_resolution_id", "content_digest", path, field)
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
          all_sessions = Array(bundle["lead_sessions"]).select { |session| session.is_a?(Hash) }
          sessions_by_control = all_sessions.group_by { |session| session["lead_control_id"] }
          global_by_id = all_sessions.to_h { |session| [session["lead_session_id"], session] }

          # Session lineage closure across controls: a session can have at
          # most one cross-control successor (a same-lineage replacement may
          # coexist with one executor transfer, but two lineages cannot both
          # claim the same transfer source), and cross-control predecessor
          # chains cannot cycle.
          cross_successors = Hash.new { |hash, key| hash[key] = [] }
          all_sessions.each do |session|
            ref = session["predecessor_lead_session_ref"]
            next unless ref.is_a?(Hash)

            predecessor = global_by_id[ref["lead_session_id"]]
            next unless predecessor
            next if predecessor["lead_control_id"] == session["lead_control_id"]

            cross_successors[ref["lead_session_id"]] << session["lead_session_id"]
          end
          cross_successors.each do |predecessor_id, child_ids|
            next if child_ids.length <= 1

            add(
              "session_binding_invalid",
              "session lineage forks across controls: a session has multiple transfer successors",
              "lead_sessions"
            )
          end
          reported_cycles = Set.new
          all_sessions.each do |start|
            cursor = start
            seen = Set.new
            while cursor
              id = cursor["lead_session_id"]
              if seen.include?(id)
                if reported_cycles.add?(seen.to_a.sort.join(":"))
                  add(
                    "session_binding_invalid",
                    "session lineage contains a cycle across controls",
                    "lead_sessions"
                  )
                end
                break
              end
              seen << id
              ref = cursor["predecessor_lead_session_ref"]
              cursor = ref && global_by_id[ref["lead_session_id"]]
            end
          end

          sessions_by_control.each do |control_id, sessions|
            by_id = sessions.to_h { |session| [session["lead_session_id"], session] }
            roots = sessions.select { |session| session["predecessor_lead_session_ref"].nil? }
            cross_heads = sessions.select do |session|
              ref = session["predecessor_lead_session_ref"]
              predecessor = ref && global_by_id[ref["lead_session_id"]]
              predecessor && predecessor["lead_control_id"] != control_id
            end
            unless roots.length == 1 || (roots.empty? && cross_heads.length == 1)
              add(
                "session_binding_invalid",
                "control #{control_id} session lineage requires exactly one head: " \
                  "a root or one cross-control transfer successor",
                "lead_sessions"
              )
            end

            successors = Hash.new { |hash, key| hash[key] = [] }
            sessions.each do |session|
              ref = session["predecessor_lead_session_ref"]
              next unless ref

              predecessor = by_id[ref["lead_session_id"]]
              unless predecessor
                predecessor = global_by_id[ref["lead_session_id"]]
                unless predecessor
                  add(
                    "session_binding_invalid",
                    "session predecessor must resolve to an existing session",
                    "lead_sessions.#{session["lead_session_id"]}.predecessor_lead_session_ref"
                  )
                  next
                end
                # Cross-control executor transfer: the old session
                # terminal/release comes first, the new session binds as the
                # first generation of its own lineage with the exact terminal
                # event pin and the same canonical runtime subject; alias
                # AgentInstance IDs never bypass the subject identity.
                unless predecessor["lead_control_id"] != control_id &&
                       session["session_generation"] == 1
                  add(
                    "session_binding_invalid",
                    "cross-control session successor must be the first generation of its lineage",
                    "lead_sessions.#{session["lead_session_id"]}.predecessor_lead_session_ref"
                  )
                end
                terminal_event = Array(predecessor["lifecycle_events"]).last
                unless terminal_event &&
                       terminal_event["event_id"] == ref["event_id"] &&
                       terminal_event["event_digest"] == ref["event_digest"] &&
                       terminal_event["event_type"] == "LeadSessionEnded"
                  add(
                    "session_binding_invalid",
                    "cross-control successor must pin the prior session terminal/release event",
                    "lead_sessions.#{session["lead_session_id"]}.predecessor_lead_session_ref"
                  )
                end
                unless canonical_subject_key(session).is_a?(Array) &&
                       canonical_subject_key(session) == canonical_subject_key(predecessor)
                  add(
                    "session_binding_invalid",
                    "executor transfer must keep the same canonical runtime subject",
                    "lead_sessions.#{session["lead_session_id"]}.predecessor_lead_session_ref"
                  )
                end
                successor_start = Array(session["lifecycle_events"]).first
                if terminal_event &&
                   terminal_event["event_type"] == "LeadSessionEnded" &&
                   successor_start &&
                   session_time(successor_start["recorded_at"]) &&
                   session_time(terminal_event["recorded_at"]) &&
                   session_time(successor_start["recorded_at"]) <
                     session_time(terminal_event["recorded_at"])
                  add(
                    "session_binding_invalid",
                    "successor session must start at or after the prior session terminal/release",
                    "lead_sessions.#{session["lead_session_id"]}.lifecycle_events[0].recorded_at"
                  )
                end
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

        def parse_time(value)
          Time.iso8601(value)
        rescue ArgumentError, TypeError
          nil
        end

        def checkpoint_due_observation_valid?(checkpoint, predecessor, deadline, scheduled)
          ref = checkpoint["checkpoint_due_observation_ref"] || {}
          assertion = ref["assertion_id"] && @verified_authority_assertions[ref["assertion_id"]]
          envelope = assertion && assertion["checkpoint_due_observation_envelope"]
          policy = @indexes.fetch("project_policy_revisions", {})[
            checkpoint.dig("project_policy_revision_ref", "policy_revision_id")
          ]
          grant = unique_policy_grant(policy, ControlAuthority::CHECKPOINT_DUE_OBSERVE_ACTION)
          return false unless assertion &&
                               assertion["assertion_digest"] == ref["assertion_digest"] &&
                               envelope.is_a?(Hash) &&
                               assertion["measurement_attestation_envelope"].nil? &&
                               %w[user control_plane].include?(assertion["issuer_kind"]) &&
                               grant.is_a?(Hash) &&
                               Array(assertion["grants"]).include?(grant["required_external_grant"])

          expected_scope = ControlAuthority.checkpoint_due_scope_digest(
            project_id: assertion["project_id"],
            policy_ref: checkpoint["project_policy_revision_ref"],
            lead_control_id: checkpoint["lead_control_id"],
            scheduled_checkpoint_ref: envelope["scheduled_checkpoint_ref"],
            deadline: envelope["deadline"],
            observed_at: envelope["observed_at"]
          )
          observed_at = parse_time(envelope["observed_at"])
          envelope["scope_digest"] == expected_scope &&
            assertion["authority_scope_ref"] == expected_scope &&
            envelope["project_id"] == checkpoint["project_id"] &&
            envelope["project_policy_revision_ref"] == checkpoint["project_policy_revision_ref"] &&
            envelope["lead_control_id"] == checkpoint["lead_control_id"] &&
            envelope["scheduled_checkpoint_ref"] ==
              (predecessor && {
                "lead_checkpoint_id" => predecessor["lead_checkpoint_id"],
                "content_digest" => predecessor["content_digest"]
              }) &&
            envelope["deadline"] == deadline &&
            assertion["asserted_at"] == envelope["observed_at"] &&
            assertion.dig("verification_receipt", "issued_at") == envelope["observed_at"] &&
            observed_at && scheduled && observed_at >= scheduled
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
