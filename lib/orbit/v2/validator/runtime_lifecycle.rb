# frozen_string_literal: true

unless defined?(Orbit::V2::Validator)
  raise LoadError, "load Validator internals through orbit/v2/validator"
end

module Orbit
  module V2
    class Validator
      module RuntimeLifecycle
        private

        def agent_context_generations(agent)
          Array(agent && agent["lifecycle_events"]).each_with_object([]) do |event, generations|
            if %w[AgentCreated AgentContextAdvanced].include?(event["event_type"])
              generations << event["context_generation"]
            end
          end
        end

        def assignment_binding_valid?(assignment, unit, agent)
          binding = ASSIGNMENT_BINDINGS[assignment && assignment["purpose"]]
          created = Array(agent && agent["lifecycle_events"]).first
          return false unless binding && unit && agent && created

          assignment["resolved_role"] == binding["resolved_role"] &&
            created["role"] == binding["resolved_role"] &&
            WorkAuthority.purpose_allowed_for_kind?(
              assignment["purpose"],
              unit["work_unit_kind"]
            ) &&
            agent_context_generations(agent).include?(assignment["context_generation"]) &&
            Array(agent.dig("capability_profile", "capabilities")).include?(
              binding["capability"]
            ) &&
            Array(agent.dig("permission_profile", "permissions")).include?(
              binding["permission"]
            ) &&
            Array(unit.dig("authority_scope", "allowed_actions")).include?(
              binding["authority_action"]
            )
        end

        def validate_assignment_binding(assignment, unit, agent, path)
          return if assignment_binding_valid?(assignment, unit, agent)

          binding = ASSIGNMENT_BINDINGS[assignment && assignment["purpose"]]
          expected = if binding
                       binding.values_at(
                         "resolved_role",
                         "capability",
                         "permission",
                         "authority_action"
                       ).join("/")
                     else
                       "known purpose binding"
                     end
          add(
            "attempt_assignment_invalid",
            "Assignment purpose must bind the WorkUnit kind plus authoritative AgentInstance " \
              "role/context, capability, permission, and action (#{expected})",
            path
          )
        end

        def validate_agent_context_lineage(agent, path)
          generations = agent_context_generations(agent)
          return if generations.empty?

          expected = (generations.first...(generations.first + generations.length)).to_a
          unless generations == expected
            add(
              "agent_lifecycle_invalid",
              "Agent context generations must advance contiguously without overwrite",
              "#{path}.lifecycle_events"
            )
          end
        end

        def validate_attempt_agent_chronology(agent, created, assignment, path)
          return unless agent && created.is_a?(Hash) && assignment.is_a?(Hash)

          attempt_created_at = Time.iso8601(created.fetch("recorded_at"))
          agent_events = Array(agent["lifecycle_events"])
          agent_created = agent_events.first
          context_event = agent_events.find do |event|
            %w[AgentCreated AgentContextAdvanced].include?(event["event_type"]) &&
              event["context_generation"] == assignment["context_generation"]
          end
          terminated = agent_events.find do |event|
            event["event_type"] == "AgentTerminated"
          end
          active = agent_created &&
            Time.iso8601(agent_created.fetch("recorded_at")) <= attempt_created_at &&
            context_event &&
            Time.iso8601(context_event.fetch("recorded_at")) <= attempt_created_at &&
            (
              terminated.nil? ||
              attempt_created_at < Time.iso8601(terminated.fetch("recorded_at"))
            )
          return if active

          add(
            "attempt_agent_lifecycle_invalid",
            "AttemptCreated requires an active AgentInstance whose exact context generation " \
              "already exists at the trusted creation time",
            path
          )
        rescue ArgumentError, KeyError, TypeError
          add(
            "attempt_agent_lifecycle_invalid",
            "Attempt/Agent cross-stream chronology must use parseable trusted timestamps",
            path
          )
        end

        def validate_lead_session_agent_chronology(session, agent, started, path)
          return unless agent && started.is_a?(Hash)

          session_started_at = Time.iso8601(started.fetch("recorded_at"))
          agent_events = Array(agent["lifecycle_events"])
          context_event = agent_events.find do |event|
            %w[AgentCreated AgentContextAdvanced].include?(event["event_type"]) &&
              event["context_generation"] == session["session_generation"]
          end
          terminated = agent_events.find do |event|
            event["event_type"] == "AgentTerminated"
          end
          active = context_event &&
            Time.iso8601(context_event.fetch("recorded_at")) <= session_started_at &&
            (
              terminated.nil? ||
              session_started_at < Time.iso8601(terminated.fetch("recorded_at"))
            )
          return if active

          add(
            "lead_session_invalid",
            "LeadSessionStarted requires an active AgentInstance whose exact session generation " \
              "context already exists at the trusted start time",
            path
          )
        rescue ArgumentError, KeyError, TypeError
          add(
            "lead_session_invalid",
            "LeadSession/Agent cross-stream chronology must use parseable trusted timestamps",
            path
          )
        end

        def validate_agents(bundle)
          Array(bundle["agent_instances"]).each do |agent|
            next unless agent.is_a?(Hash)

            path = "agent_instances.#{agent["agent_instance_id"]}"
            unless agent["object_type"] == "agent_instance"
              add("agent_runtime_invalid", "AgentInstance object_type is required", "#{path}.object_type")
            end
            validate_event_chain(
              agent["lifecycle_events"],
              path,
              stream: "agent",
              field: "lifecycle_events",
              project_id: agent["project_id"]
            )
            validate_agent_context_lineage(agent, path)
            check("#{path}.runtime_identity") do
              identity_key = @runtime_identity_verifier.verify!(agent)
              existing_agent_id = @verified_runtime_identities[identity_key]
              if existing_agent_id &&
                 existing_agent_id != agent["agent_instance_id"]
                add(
                  "runtime_identity_duplicate",
                  "one verified provider runtime subject cannot back multiple AgentInstance IDs",
                  "#{path}.runtime_identity",
                  "existing_agent_instance_id" => existing_agent_id
                )
              else
                @verified_runtime_identities[identity_key] =
                  agent["agent_instance_id"]
              end
            end
          end
        end

        def validate_logical_leads(bundle)
          task_ids = @indexes.fetch("task_revisions", {}).values.map { |task| task["task_id"] }.uniq
          Array(bundle["logical_leads"]).each do |lead|
            next unless lead.is_a?(Hash)

            path = "logical_leads.#{lead["logical_lead_id"]}"
            unless lead["object_type"] == "logical_lead" && task_ids.include?(lead["task_id"])
              add(
                "logical_lead_invalid",
                "LogicalLead must bind an existing task orchestration identity",
                path
              )
            end
          end
        end

        def validate_lead_sessions(bundle)
          leads = @indexes.fetch("logical_leads", {})
          agents = @indexes.fetch("agent_instances", {})
          tasks = @indexes.fetch("task_revisions", {})
          Array(bundle["lead_sessions"]).each do |session|
            next unless session.is_a?(Hash)

            path = "lead_sessions.#{session["lead_session_id"]}"
            lead = leads[session["logical_lead_id"]]
            agent = agents[session["agent_instance_id"]]
            task = tasks[session["task_revision_id"]]
            unless session["object_type"] == "lead_session" &&
                   lead &&
                   agent &&
                   task &&
                   lead["task_id"] == session["task_id"] &&
                   task["task_id"] == session["task_id"]
              add(
                "lead_session_invalid",
                "LeadSession must bind one LogicalLead, AgentInstance, task, and revision",
                path
              )
            end
            unless lead && lead["durable_context_ref"] == session["durable_context_ref"]
              add(
                "lead_session_invalid",
                "LeadSession recovery context must match its LogicalLead durable context",
                "#{path}.durable_context_ref"
              )
            end
            capabilities = Array(agent&.dig("capability_profile", "capabilities"))
            permissions = Array(agent&.dig("permission_profile", "permissions"))
            unless capabilities.include?("task.orchestrate") &&
                   permissions.include?("task_revision.propose")
              add(
                "lead_session_invalid",
                "LeadSession AgentInstance lacks orchestration capability or permission",
                "#{path}.agent_instance_id"
              )
            end
            validate_event_chain(
              session["lifecycle_events"],
              path,
              stream: "lead_session",
              field: "lifecycle_events",
              project_id: session["project_id"]
            )
            started = Array(session["lifecycle_events"]).first
            unless started &&
                   started["context_generation"] == session["session_generation"] &&
                   agent_context_generations(agent).include?(started["context_generation"])
              add(
                "lead_session_invalid",
                "LeadSession start must bind its session generation to an existing Agent context",
                "#{path}.lifecycle_events[0].context_generation"
              )
            end
            validate_lead_session_agent_chronology(
              session,
              agent,
              started,
              "#{path}.lifecycle_events[0].recorded_at"
            )
            unless @indexes.fetch("control_registries", {}).key?(session["lead_control_id"])
              add(
                "lead_session_invalid",
                "LeadSession must bind an accepted control registry",
                "#{path}.lead_control_id"
              )
            end
            runtime_identity = agent && agent["runtime_identity"]
            if runtime_identity
              unless session["lead_runtime_subject_ref"] ==
                     runtime_identity["runtime_subject_id"]
                add(
                  "lead_session_invalid",
                  "LeadSession subject ref must equal its AgentInstance runtime subject",
                  "#{path}.lead_runtime_subject_ref"
                )
              end
              unless session["lead_runtime_subject_assertion_digest"] ==
                     control_assertion_digest(runtime_identity["verification_receipt_ref"])
                add(
                  "lead_session_invalid",
                  "LeadSession assertion digest must pin the provider-verified AgentInstance receipt",
                  "#{path}.lead_runtime_subject_assertion_digest"
                )
              end
            end
          end
        end

        def validate_attempts(bundle, active_policy)
          units = @indexes.fetch("work_units", {})
          agents = @indexes.fetch("agent_instances", {})
          rules = @indexes.fetch("rule_resolution_artifacts", {})
          tasks = @indexes.fetch("task_revisions", {})
          Array(bundle["work_unit_attempts"]).each do |attempt|
            next unless attempt.is_a?(Hash)

            path = "work_unit_attempts.#{attempt["attempt_id"]}"
            unless attempt["object_type"] == "work_unit_attempt"
              add("attempt_lifecycle_invalid", "WorkUnitAttempt object_type is required", "#{path}.object_type")
            end
            %w[assignment agent_instance_id context_generation started_at ended_at status].each do |field|
              if attempt.key?(field)
                add("attempt_lifecycle_invalid", "Attempt #{field} must derive from append-only events", "#{path}.#{field}")
              end
            end
            validate_identifier(
              "lead_control_id",
              attempt["lead_control_id"],
              "#{path}.lead_control_id"
            )
            dispatch_ref = attempt["dispatch_lead_checkpoint_ref"]
            if dispatch_ref.is_a?(Hash)
              validate_identifier(
                "lead_checkpoint_id",
                dispatch_ref["lead_checkpoint_id"],
                "#{path}.dispatch_lead_checkpoint_ref.lead_checkpoint_id"
              )
            end
            checkpoints = @indexes.fetch("lead_checkpoints", {})
            checkpoint = dispatch_ref.is_a?(Hash) &&
              checkpoints[dispatch_ref["lead_checkpoint_id"]]
            unless checkpoint &&
                   checkpoint["content_digest"] == dispatch_ref["content_digest"] &&
                   checkpoint["lead_control_id"] == attempt["lead_control_id"] &&
                   checkpoint.dig("active_task_ref", "task_revision_id") ==
                     attempt["task_revision_id"] &&
                   checkpoint.dig("selected_work_unit_ref", "work_unit_id") ==
                     attempt["work_unit_id"]
              add(
                "attempt_dispatch_invalid",
                "dispatch LeadCheckpoint must exist with exact digest in the same control lineage " \
                  "and its selection must exactly match this Attempt",
                "#{path}.dispatch_lead_checkpoint_ref"
              )
            end
            unless attempt["predecessor_work_unit_attempt_ref"].nil? ||
                   Identifiers.valid?("attempt_id", attempt["predecessor_work_unit_attempt_ref"])
              add(
                "attempt_successor_invalid",
                "predecessor_work_unit_attempt_ref must be an exact stable Attempt ref or null",
                "#{path}.predecessor_work_unit_attempt_ref"
              )
            end
            validate_event_chain(
              attempt["events"],
              path,
              stream: "attempt",
              field: "events",
              project_id: attempt["project_id"]
            )
            created = Array(attempt["events"]).first
            next unless created.is_a?(Hash)

            assignment = created["assignment"]
            unless assignment.is_a?(Hash)
              add("attempt_lifecycle_invalid", "AttemptCreated requires immutable assignment", "#{path}.events[0].assignment")
              next
            end
            unless created["started_at"].is_a?(String) && created["status"] == "active"
              add(
                "attempt_lifecycle_invalid",
                "AttemptCreated is the only started_at source and must establish active status",
                "#{path}.events[0]"
              )
            end
            unit = units[attempt["work_unit_id"]]
            unless unit &&
                   unit["project_id"] == attempt["project_id"] &&
                   unit["task_id"] == attempt["task_id"] &&
                   unit["task_revision_id"] == attempt["task_revision_id"]
              add(
                "attempt_lineage_invalid",
                "Attempt and WorkUnit must share exact project/task/revision identity",
                path
              )
            end
            agent = agents[assignment["agent_instance_id"]]
            add("reference_not_found", "Attempt AgentInstance does not exist", "#{path}.events[0].assignment.agent_instance_id") unless agent
            thesis_ref = assignment["change_thesis_ref"]
            validate_attempt_thesis_ref(
              attempt,
              unit,
              thesis_ref,
              "#{path}.events[0].assignment.change_thesis_ref"
            )
            rule = rules[assignment["assigned_rule_resolution_id"]]
            add("reference_not_found", "Attempt assigned RuleResolution does not exist", "#{path}.events[0].assignment.assigned_rule_resolution_id") unless rule
            validate_assignment_binding(
              assignment,
              unit,
              agent,
              "#{path}.events[0].assignment"
            )
            validate_attempt_agent_chronology(
              agent,
              created,
              assignment,
              "#{path}.events[0].assignment"
            )
            authority = assignment["authority_snapshot"]
            policy_ref = authority.is_a?(Hash) && authority["project_policy_revision_ref"]
            policy = policy_ref.is_a?(Hash) &&
              @indexes["project_policy_revisions"][policy_ref["policy_revision_id"]]
            task = tasks[attempt["task_revision_id"]]
            task_policy_ref = task && task["project_policy_revision_ref"]
            unless policy && policy["content_digest"] == policy_ref["content_digest"]
              add(
                "attempt_authority_invalid",
                "Attempt assignment must pin an immutable ProjectPolicyRevision ID/digest",
                "#{path}.events[0].assignment.authority_snapshot"
              )
            end
            unless task_policy_ref.is_a?(Hash) &&
                   policy_ref.is_a?(Hash) &&
                   CanonicalJSON.dump(task_policy_ref) == CanonicalJSON.dump(policy_ref)
              add(
                "attempt_authority_invalid",
                "Attempt authority snapshot must exactly equal its TaskRevision policy ref",
                "#{path}.events[0].assignment.authority_snapshot.project_policy_revision_ref"
              )
            end
            if active_policy &&
               task_policy_ref&.dig("policy_revision_id") != active_policy["policy_revision_id"] &&
               !historical_attempt_before_policy_replacement?(attempt, task_policy_ref)
              add(
                "attempt_authority_stale",
                "an active or post-rotation Attempt cannot continue under a stale TaskRevision policy",
                path
              )
            end
            actual_attempt_refs =
              Array(authority && authority["authorization_record_refs"])
            actual_attempt_refs.each do |record_id|
              record = @indexes["authorization_records"][record_id]
              action = WorkAuthority.action_for_purpose(assignment["purpose"])
              unless record &&
                     valid_work_authorization?(
                       record,
                       task: task,
                       unit: unit,
                       action: action
                     )
                add(
                  "attempt_authority_invalid",
                  "Attempt authority refs require the assignment action and exact canonical WorkUnit scope",
                  "#{path}.events[0].assignment.authority_snapshot.authorization_record_refs"
                )
              end
            end
            expected_attempt_refs = Array(unit&.dig("authority_scope", "authorization_record_refs"))
              .select do |record_id|
                @indexes.dig("authorization_records", record_id, "action") ==
                  WorkAuthority.action_for_purpose(assignment["purpose"])
              end
              .sort
            if expected_attempt_refs.empty? || actual_attempt_refs.empty?
              add(
                "attempt_authority_missing",
                "AttemptCreated must pin at least one exact AuthorizationRecord for its purpose",
                "#{path}.events[0].assignment.authority_snapshot.authorization_record_refs"
              )
            end
            actual_attempt_refs = actual_attempt_refs.sort
            unless actual_attempt_refs == expected_attempt_refs
              add(
                "attempt_authority_invalid",
                "Attempt authority snapshot must pin exactly the WorkUnit records for its assignment purpose",
                "#{path}.events[0].assignment.authority_snapshot.authorization_record_refs"
              )
            end
          end
          validate_attempt_succession(bundle)
          validate_dispatch_ref_uniqueness(bundle)
          validate_single_active_attempts(bundle)
        end

        def validate_dispatch_ref_uniqueness(bundle)
          attempts = Array(bundle["work_unit_attempts"]).select { |attempt| attempt.is_a?(Hash) }
          attempts.group_by do |attempt|
            [
              attempt["project_id"],
              attempt["lead_control_id"],
              attempt["dispatch_lead_checkpoint_ref"]
            ]
          end.each do |(project_id, control_id, ref), scoped|
            next if ref.nil? || scoped.length <= 1

            add(
              "attempt_dispatch_invalid",
              "one accepted LeadCheckpoint authorizes exactly one dispatch within its " \
                "control lineage; dispatch_lead_checkpoint_ref cannot be shared",
              "work_unit_attempts.#{control_id}.dispatch_lead_checkpoint_ref",
              "project_id" => project_id,
              "lead_control_id" => control_id,
              "dispatch_lead_checkpoint_ref" => ref,
              "attempt_ids" => scoped.map { |attempt| attempt["attempt_id"] }.sort
            )
          end
        end

        def validate_attempt_succession(bundle)
          attempts = Array(bundle["work_unit_attempts"]).select { |attempt| attempt.is_a?(Hash) }
          by_id = attempts.to_h { |attempt| [attempt["attempt_id"], attempt] }
          successors = Hash.new { |hash, key| hash[key] = [] }
          attempts.each do |attempt|
            path = "work_unit_attempts.#{attempt["attempt_id"]}"
            predecessor_ref = attempt["predecessor_work_unit_attempt_ref"]
            next if predecessor_ref.nil?

            predecessor = by_id[predecessor_ref]
            if predecessor.nil?
              add(
                "attempt_successor_invalid",
                "predecessor_work_unit_attempt_ref must resolve to an existing WorkUnitAttempt",
                "#{path}.predecessor_work_unit_attempt_ref"
              )
              next
            end
            unless predecessor["project_id"] == attempt["project_id"] &&
                   predecessor["task_id"] == attempt["task_id"] &&
                   predecessor["task_revision_id"] == attempt["task_revision_id"] &&
                   predecessor["work_unit_id"] == attempt["work_unit_id"]
              add(
                "attempt_successor_invalid",
                "a successor Attempt must share exact project/task/revision/WorkUnit identity with its predecessor",
                "#{path}.predecessor_work_unit_attempt_ref"
              )
            end
            unless predecessor["lead_control_id"] == attempt["lead_control_id"]
              add(
                "attempt_successor_invalid",
                "a successor Attempt must pin the same lead_control_id as its predecessor",
                "#{path}.lead_control_id"
              )
            end
            unless attempt_terminal?(predecessor)
              add(
                "attempt_successor_invalid",
                "a successor Attempt requires a terminal predecessor",
                "#{path}.predecessor_work_unit_attempt_ref"
              )
            end
            created_at = parse_attempt_created_at(attempt)
            predecessor_ended_at = parse_attempt_ended_at(predecessor)
            if created_at && predecessor_ended_at && predecessor_ended_at >= created_at
              add(
                "attempt_successor_invalid",
                "a successor Attempt must be created after its predecessor terminal event",
                "#{path}.events[0].started_at"
              )
            end
            successors[predecessor_ref] << attempt["attempt_id"]
          end
          successors.each do |predecessor_ref, successor_ids|
            next if successor_ids.length <= 1

            add(
              "attempt_successor_invalid",
              "the WorkUnitAttempt lineage is linear; #{predecessor_ref} has multiple successors",
              "work_unit_attempts.#{predecessor_ref}.predecessor_work_unit_attempt_ref",
              "successor_attempt_ids" => successor_ids.sort
            )
          end
          firsts = Hash.new { |hash, key| hash[key] = [] }
          attempts.each do |attempt|
            next unless attempt["predecessor_work_unit_attempt_ref"].nil?

            firsts[attempt["work_unit_id"]] << attempt["attempt_id"]
          end
          firsts.each do |work_unit_id, attempt_ids|
            next if attempt_ids.length <= 1

            add(
              "attempt_successor_invalid",
              "a WorkUnit can have only one first Attempt with a null predecessor",
              "work_unit_attempts.#{work_unit_id}.predecessor_work_unit_attempt_ref",
              "first_attempt_ids" => attempt_ids.sort
            )
          end
          attempts.each do |attempt|
            seen = Set.new
            cursor = attempt
            cycled = false
            while cursor
              unless seen.add?(cursor["attempt_id"])
                cycled = true
                break
              end

              predecessor_ref = cursor["predecessor_work_unit_attempt_ref"]
              break if predecessor_ref.nil?

              cursor = by_id[predecessor_ref]
            end
            if cycled
              add(
                "attempt_successor_invalid",
                "the WorkUnitAttempt lineage contains a cycle",
                "work_unit_attempts.#{attempt["attempt_id"]}.predecessor_work_unit_attempt_ref"
              )
            end
          end
        end

        def validate_single_active_attempts(bundle)
          attempts = Array(bundle["work_unit_attempts"]).select { |attempt| attempt.is_a?(Hash) }
          {
            %w[project_id lead_control_id] => "control",
            %w[project_id task_id] => "task",
            %w[project_id work_unit_id] => "work_unit"
          }.each do |scope_fields, scope|
            attempts.group_by do |attempt|
              scope_fields.map { |field| attempt[field] }
            end.each do |scope_key, scoped|
              next if scoped.length <= 1

              by_id = scoped.to_h { |attempt| [attempt["attempt_id"], attempt] }
              intervals = scoped.map do |attempt|
                created = parse_attempt_created_at(attempt)
                [attempt["attempt_id"], created] if created
              end.compact
              intervals.sort_by! { |(_id, created)| created }
              latest_end = nil
              overlapping = []
              intervals.each do |attempt_id, created|
                if latest_end && (latest_end == :open || created < latest_end)
                  overlapping << attempt_id
                end
                ended = parse_attempt_ended_at(by_id.fetch(attempt_id))
                candidate = ended.nil? ? :open : ended
                if latest_end.nil? || candidate == :open
                  latest_end = candidate
                elsif latest_end != :open && candidate > latest_end
                  latest_end = candidate
                end
              end
              next if overlapping.empty?

              add(
                "single_active_violation",
                "strict serialization forbids overlapping WorkUnitAttempt intervals " \
                  "per #{scope} at any moment",
                "work_unit_attempts.#{scope_key.join(".")}",
                "scope" => scope,
                "overlapping_attempt_ids" => overlapping.sort
              )
            end
          end
        end

        def validate_event_chain(events, path, stream:, field:, project_id:)
          unless events.is_a?(Array) && !events.empty?
            add("append_only_chain_invalid", "event stream cannot be empty", "#{path}.#{field}")
            return
          end
          contract = EVENT_STREAMS.fetch(stream)
          seen = Set.new
          previous_digest = nil
          previous_recorded_at = nil
          terminal_seen = false
          events.each_with_index do |event, index|
            event_path = "#{path}.#{field}[#{index}]"
            unless event.is_a?(Hash)
              add("append_only_chain_invalid", "event must be an object", event_path)
              next
            end
            validate_identifier("event_id", event["event_id"], "#{event_path}.event_id")
            add("append_only_chain_invalid", "event ID is reused", "#{event_path}.event_id") unless seen.add?(event["event_id"])
            event_id = event["event_id"]
            if @event_ids.key?(event_id)
              code = CanonicalJSON.dump(@event_ids[event_id]) == CanonicalJSON.dump(event) ?
                "duplicate_identity" : "append_only_event_reuse"
              add(
                code,
                "event ID is globally create-only and cannot be reused across lifecycle streams",
                "#{event_path}.event_id"
              )
            else
              @event_ids[event_id] = event
            end
            event_type = event["event_type"]
            unless contract["allowed"].include?(event_type)
              add(
                "append_only_chain_invalid",
                "#{event_type.inspect} is not a typed #{stream} lifecycle event",
                "#{event_path}.event_type"
              )
            end
            if index.zero? && event_type != contract["initial"]
              add(
                "append_only_chain_invalid",
                "first event must be #{contract["initial"]}",
                "#{event_path}.event_type"
              )
            elsif index.positive? && event_type == contract["initial"]
              add(
                "append_only_chain_invalid",
                "#{contract["initial"]} can occur only once",
                "#{event_path}.event_type"
              )
            end
            if terminal_seen
              add(
                "append_only_chain_invalid",
                "no lifecycle event may follow a terminal event",
                event_path
              )
            end
            if contract["terminal"].include?(event_type)
              if terminal_seen
                add(
                  "append_only_chain_invalid",
                  "event stream may contain only one terminal event",
                  "#{event_path}.event_type"
                )
              end
              terminal_seen = true
            end
            unless event["previous_event_digest"] == previous_digest
              add("append_only_chain_invalid", "event does not extend previous digest", "#{event_path}.previous_event_digest")
            end
            expected = CanonicalJSON.digest_excluding(
              event,
              "event_digest",
              "writer_receipt",
              "created_at",
              "accepted_at",
              "envelope"
            )
            unless event["event_digest"] == expected
              add("digest_mismatch", "event digest does not match canonical content", "#{event_path}.event_digest")
            end
            recorded_at = parse_lifecycle_time(
              event["recorded_at"],
              "#{event_path}.recorded_at"
            )
            if recorded_at && previous_recorded_at && recorded_at <= previous_recorded_at
              add(
                "lifecycle_chronology_invalid",
                "lifecycle recorded_at values must increase strictly in append order",
                "#{event_path}.recorded_at"
              )
            end
            if index.zero?
              started_at = parse_lifecycle_time(
                event["started_at"],
                "#{event_path}.started_at"
              )
              if started_at && recorded_at && started_at != recorded_at
                add(
                  "lifecycle_chronology_invalid",
                  "initial started_at must equal the trusted writer recorded_at",
                  "#{event_path}.started_at"
                )
              end
            elsif contract["terminal"].include?(event_type)
              ended_at = parse_lifecycle_time(
                event["ended_at"],
                "#{event_path}.ended_at"
              )
              if ended_at && recorded_at && ended_at != recorded_at
                add(
                  "lifecycle_chronology_invalid",
                  "terminal ended_at must equal the trusted writer recorded_at",
                  "#{event_path}.ended_at"
                )
              end
            end
            begin
              @lifecycle_verifier.verify!(event, project_id: project_id)
            rescue ContractError => e
              add(e.code, e.message, "#{event_path}.writer_receipt", e.details)
            end
            previous_recorded_at = recorded_at if recorded_at
            previous_digest = event["event_digest"]
          end
        end

        def parse_lifecycle_time(value, path)
          Time.iso8601(value)
        rescue ArgumentError, TypeError
          add(
            "lifecycle_chronology_invalid",
            "lifecycle timestamps must be parseable ISO-8601 values",
            path
          )
          nil
        end

        def attempt_terminal?(attempt)
          last_event = Array(attempt && attempt["events"]).last
          last_event.is_a?(Hash) &&
            EVENT_STREAMS.fetch("attempt").fetch("terminal").include?(last_event["event_type"])
        end

        def historical_attempt_before_policy_replacement?(attempt, policy_ref)
          return false unless attempt_terminal?(attempt)

          created = Array(attempt["events"]).first
          terminal = Array(attempt["events"]).last
          cutoff = policy_replacement_cutoff(policy_ref && policy_ref["policy_revision_id"])
          started_at = Time.iso8601(created["started_at"])
          ended_at = Time.iso8601(terminal["ended_at"])
          cutoff &&
            started_at <= ended_at &&
            started_at < cutoff &&
            ended_at < cutoff
        rescue ArgumentError, TypeError
          false
        end

        def historical_evidence_before_policy_replacement?(record, attempt, policy_ref)
          return false unless historical_attempt_before_policy_replacement?(attempt, policy_ref)

          started_at = Time.iso8601(attempt.dig("events", 0, "started_at"))
          accepted_at = Time.iso8601(record["acceptance_recorded_at"])
          cutoff = policy_replacement_cutoff(policy_ref && policy_ref["policy_revision_id"])
          cutoff && accepted_at >= started_at && accepted_at < cutoff
        rescue ArgumentError, TypeError
          false
        end

        def runtime_identity_key_for_agent_id(agent_instance_id)
          agent = @indexes.fetch("agent_instances", {})[agent_instance_id]
          agent && RuntimeIdentityVerifier.identity_key(agent.fetch("runtime_identity"))
        rescue KeyError, TypeError
          nil
        end
      end

      include RuntimeLifecycle
      private_constant :RuntimeLifecycle
    end
  end
end
