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
          sessions = @indexes.fetch("lead_sessions", {})
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

          session_ref = registry["active_lead_session_ref"]
          session = session_ref && sessions[session_ref["lead_session_id"]]
          unless session &&
                 session["lead_control_id"] == registry["lead_control_id"] &&
                 session["session_generation"] == session_ref["session_generation"] &&
                 session_active?(session)
            add(
              "control_genesis_invalid",
              "registry must bind the exact active LeadSession generation of the same control",
              "#{path}.active_lead_session_ref"
            )
          end

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
                   session["session_generation"] == session_ref["session_generation"] &&
                   session_active?(session)
              add(
                "checkpoint_pin_invalid",
                "checkpoint must pin the exact active LeadSession generation of the same control",
                "#{path}.active_lead_session_ref"
              )
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

            unless checkpoint["task_queue"] == registry["owned_task_refs"]
              add(
                "checkpoint_queue_projection_invalid",
                "checkpoint task queue must exactly match the registry owned task refs",
                "#{path}.task_queue"
              )
            end
            validate_owned_task_refs(checkpoint["task_queue"], tasks, "#{path}.task_queue")

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
          # policy; continuing after rotation requires a new checkpoint.
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
          end
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
          active_by_control = Hash.new { |hash, key| hash[key] = [] }
          Array(bundle["lead_sessions"]).each do |session|
            next unless session.is_a?(Hash)

            events = Array(session["lifecycle_events"])
            next if events.empty?

            if events.last["event_type"] == "LeadSessionStarted"
              active_by_control[session["lead_control_id"]] << session["lead_session_id"]
            end
          end
          active_by_control.each do |control_id, session_ids|
            next if session_ids.length <= 1

            add(
              "session_binding_invalid",
              "control #{control_id} has more than one active LeadSession",
              "lead_sessions"
            )
          end
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
