# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "shellwords"
require_relative "task_record"
require_relative "workspace_snapshot"
require_relative "workspace_binding"
require_relative "connection"
require_relative "jev_advisor"
require_relative "codex_member_host"
require_relative "member_policy"
require_relative "model_evidence_cache"
require_relative "observation_key"

module Orbit
  class TaskRuntime
    TERMINAL = %w[complete paused needs_user failed stop_unconfirmed].freeze
    # The first real positive/negative calibration (2026-09-22) placed a
    # clearly separable two-surface task at 0.64 and a one-file task at
    # 0.18-0.35. This gate only opens evidence gathering; the second-stage
    # member_fit and parallel_gain gates still decide whether to hint.
    DELEGATION_HINT_THRESHOLD = 0.6
    # Same-identity real runs separated substantive work (0.58) from the
    # small handoff-negative fixtures (0.42-0.45).
    MEMBER_FIT_THRESHOLD = 0.55
    # Real Jev calibration separated small handoff-negative fixtures
    # (0.45-0.48) from a substantive disjoint-module fixture (0.53).
    PARALLEL_GAIN_THRESHOLD = 0.50
    REVIEW_FOCUS_STATUSES = %w[added modified deleted].freeze
    REVIEW_FOCUS_LIMIT = 200

    def initialize(record:, connection:, checker:, advisor: nil, member_host: nil, member_policy: nil, evidence_cache: nil)
      @record, @connection, @checker = record, connection, checker
      @advisor = advisor
      @member_host = member_host
      @member_policy = member_policy
      @evidence_cache = evidence_cache
      @state = record.state
      @state["findings"] ||= {}
      @state["sent_message_ids"] ||= []
      @state["delegation_hints"] ||= {}
      @state["delegation_assessments"] ||= {}
      @state["evidence_requests"] ||= {}
      @state["evidence_gaps"] ||= {}
      @state["members"] ||= []
      @state["member_hosts"] ||= {}
      @state["unknown_candidates"] ||= {}
      @state["check_observations"] ||= {}
      @state["finalization_notices"] ||= {}
      @member_connections = {}
      @state["last_user_message_id"] ||= @state.dig("instruction_source", "id")
      @interval = @state.fetch("review").fetch("interval_seconds", 300)
      @next_check = Time.now.to_f + @interval
      @state["next_check_basis"] ||= "约定检查间隔"
      # A queued manual/rebind trigger must survive a runtime restart: these
      # default only when absent, never overwriting persisted schedule state.
      @state["next_check_trigger"] ||= "timer"
      @state["next_check_manual"] ||= false
      @running_check = nil
      @last_delivery_checked = nil
      @first_change_checked = false
      @stop_requested = false
      @artifact_digest = nil
      @last_artifact_probe_at = 0
      @last_full_check_digest = nil
      @jev_last_at = Time.now.to_f - 15
      @jev_next_at = Time.now.to_f + 5
      @jev_signature = nil
      @jev_process_streak = 0
      @jev_last_process_trigger = nil
      @jev_unavailable = false
      @pending_hint = nil
      @pending_evidence = nil
    end

    def run
      @record.with_runtime_lock do
        @record.with_root_lock(@state.dig("connection", "thread_id")) do
          @connection.connect!
          host = @connection.state
          unless File.realpath(host.fetch("cwd")) == @state.fetch("project_root")
            raise ArgumentError, "Root session belongs to a different project"
          end
          @attached = true
          @initial_digest = fingerprint_artifact
          @artifact_digest = @initial_digest
          @state["status"] = "running"
          @state["runtime_pid"] = Process.pid
          @record.event("attached", "thread_id" => host.fetch("thread_id"))
          if @state.delete("needs_initial_delivery")
            sent = @connection.send_message("Orbit task: execute the following user-provided original instruction.\n\n" + @record.inputs(@state).fetch("instruction"))
            @state["sent_message_ids"] << sent.fetch("id")
            @state["last_user_message_id"] = sent.fetch("id")
          end
          save
          until TERMINAL.include?(@state["status"])
            tick
            sleep 1 unless TERMINAL.include?(@state["status"])
          end
        rescue StandardError => error
          # Still inside the Root lock: a failed observer must attempt member
          # cleanup before another task can acquire ownership of this Root.
          @state["error"] = "#{error.class}: #{error.message}"
          @record.event("runtime_error", "error" => @state["error"])
          if @attached
            stop("Orbit runtime failed: #{@state['error']}", status: "failed")
          else
            @state["status"] = "failed"
            save
          end
        end
      rescue StandardError => error
        @state["status"] = "failed"
        @state["error"] = "#{error.class}: #{error.message}"
        @record.event("runtime_error", "error" => @state["error"])
        save
      ensure
        begin
          @checker.stop! if @running_check
        rescue StandardError => error
          record_cleanup_error(error)
        ensure
          @connection.close
          @member_connections.each_value(&:close)
        end
        if %w[complete paused needs_user].include?(@state["status"])
          begin
            shutdown_member_hosts([])
          rescue StandardError => error
            @record.event("member_host_shutdown_error", "error" => error.message)
          end
        end
        @state["finished_at"] = Time.now.utc.iso8601
        @state["elapsed_seconds"] = Time.now - Time.parse(@state.fetch("created_at"))
        measured = @state.fetch("checks").filter_map { |check| check["usage"] }
        @state["usage"]["check_tokens"] = measured.empty? ? nil : measured.sum { |usage| usage.fetch("input_tokens", 0) + usage.fetch("output_tokens", 0) }
        estimate = @state.dig("estimate", "seconds")
        @state["comparison"] = {
          "time_variance_seconds" => estimate ? @state["elapsed_seconds"] - estimate : nil,
          "task_token_variance" => nil,
          "stale_checks" => @state.fetch("checks").count { |check| check["stale"] },
          "correction_messages" => @state.fetch("sent_message_ids").length,
          "note" => "Check usage is measured separately. Root session totals can include earlier work; task-wide tokens remain unknown without a baseline."
        }
        @state.delete("runtime_pid")
        save
      end
      @state
    end

    def request_stop
      @stop_requested = true
    end

    # Explicit cleanup after the observer has exited; never resumes execution.
    # Locks prevent an old record from stopping a newer task on the same Root.
    def retry_stop(reason)
      @record.with_runtime_lock do
        @record.with_root_lock(@state.dig("connection", "thread_id")) do
          begin
            @connection.connect!
          rescue Connection::Error
            # confirmed_stop must still attempt every registered member.
          end
          verify_prior_check_exit
          stop(reason)
        ensure
          @connection.close
          @member_connections.each_value(&:close)
        end
      end
      @state
    end

    # A single event-loop step is also the deterministic test seam. Host and
    # checker doubles cannot turn these tests into real-model acceptance.
    def tick(now: Time.now.to_f)
      return if TERMINAL.include?(@state["status"])
      if @stop_requested
        stop("Runtime received an explicit stop request")
        return
      end
      deadline = @state["hard_deadline"]
      if deadline && now >= Time.parse(deadline).to_f
        stop("The user's explicit hard deadline was reached")
        return
      end

      host = @connection.state
      if host["interrupted"] || (host["status"] == "idle" && host["last_turn_status"] == "interrupted")
        stop("The user interrupted the Root turn")
        return
      end
      consume_commands
      return if TERMINAL.include?(@state["status"])
      collect_member_results
      host = @connection.state
      @connection.events.each do |event|
        next unless event["method"] == "thread/tokenUsage/updated"

        @state["usage"]["root_session_cumulative"] = event.dig("params", "tokenUsage", "total")
      end
      return unless collect_amendments
      if @running_check
        @check_result ||= @checker.poll
        finish_check(@check_result, host, now) if @check_result
        return
      end
      if %w[notLoaded systemError].include?(host["status"])
        raise ArgumentError, "Root is unavailable: #{host['status']}; no automatic replacement"
      end
      delivery = host["status"] == "idle" && host["last_turn_status"] == "completed"
      artifact_digest = @advisor ? probe_artifact(now) : nil
      @initial_digest ||= artifact_digest if @advisor
      changed = if @advisor
                  !@first_change_checked && artifact_digest != @initial_digest
                else
                  !@first_change_checked && fingerprint_artifact != @initial_digest
                end
      delivery_due = delivery && host["last_turn_id"] != @last_delivery_checked
      if now >= @next_check || delivery_due
        scheduled = now >= @next_check
        cause = scheduled ? (@state["next_check_trigger"] || "timer") : "delivery"
        manual = scheduled && @state["next_check_manual"] == true
        @first_change_checked = true if start_check(host, now, trigger: cause, manual: manual)
        # A skipped duplicate delivery still consumes the turn: otherwise the
        # same delivery would be retried every tick.
        @last_delivery_checked = host["last_turn_id"] if delivery
        return
      end

      if @advisor
        decision = assess_jev(host, artifact_digest, now)
        if @stop_requested
          stop("Runtime received an explicit stop request")
          return
        end
        if decision
          # The check this assessment asked for wins over an advisory hint:
          # a hint must never delay or interrupt it.
          @pending_hint = nil
          @pending_evidence = nil
          consume_commands
          return if TERMINAL.include?(@state["status"])
          return unless collect_amendments
          latest_host = @connection.state
          latest_digest = fingerprint_artifact
          if observation_stale?(host, artifact_digest, latest_host, latest_digest, now)
            @jev_next_at = [@jev_next_at, now + 20].max
            return
          end
        end
        case decision
        when :artifact
          @first_change_checked = true if start_check(host, now, trigger: "jev_artifact")
        when :process
          start_check(host, now, kind: "process", trigger: "jev_process")
        when :unavailable
          if changed
            @first_change_checked = true if start_check(host, now, trigger: "change")
          end
        when nil
          if @jev_unavailable && changed
            @first_change_checked = true if start_check(host, now, trigger: "change")
          end
        end
        # Hints use the same freshness re-check as check decisions; a hint
        # that failed it is dropped rather than sent against an old state.
        if @pending_hint || @pending_evidence
          consume_commands
          return if TERMINAL.include?(@state["status"])
          return unless collect_amendments
          latest_host = @connection.state
          latest_digest = fingerprint_artifact
          if observation_stale?(host, artifact_digest, latest_host, latest_digest, now)
            @jev_next_at = [@jev_next_at, now + 20].max
            @pending_hint = nil
            @pending_evidence = nil
          else
            deliver_pending_evidence
            deliver_pending_hint
          end
          return
        end
      elsif changed
        @first_change_checked = true if start_check(host, now, trigger: "change")
      end
    rescue WorkspaceSnapshot::UnstableError => error
      @state["observation_pending"] = { "reason" => error.message, "paths" => error.paths }
      save
    end

    private

    def probe_artifact(now)
      if @artifact_digest.nil? || now - @last_artifact_probe_at >= 5
        @artifact_digest = fingerprint_artifact
        @last_artifact_probe_at = now
      end
      @artifact_digest
    end

    # Checks, fingerprints and new members read the artifact workspace.
    # project_root remains the authorization and task-record directory.
    def artifact_root
      root = @state.dig("workspace", "artifact_root")
      return root if root.is_a?(String) && !root.empty?

      @state.fetch("project_root")
    end

    def fingerprint_artifact
      WorkspaceSnapshot.fingerprint(project_root: artifact_root)
    end

    def reset_artifact_observation!
      @artifact_digest = nil
      @last_artifact_probe_at = 0
      @last_full_check_digest = nil
    end

    def current_workspace
      workspace = @state["workspace"]
      if workspace.is_a?(Hash) && workspace["project_root"].is_a?(String) && workspace["artifact_root"].is_a?(String)
        return workspace
      end

      WorkspaceBinding.bind(project_root: @state.fetch("project_root")).merge("history" => [])
    end

    def rebind_workspace(command)
      path = command.fetch("path")
      reason = command["reason"].to_s.strip
      reason = "explicit workspace rebind" if reason.empty?
      source = command["source"].is_a?(Hash) ? command["source"] : { "kind" => "command", "command" => "rebind_workspace" }
      current = current_workspace
      updated = WorkspaceBinding.rebind(current, artifact_root: path)
      entry = {
        "source" => source, "reason" => reason,
        "from" => current.fetch("artifact_root"), "to" => updated.fetch("artifact_root"),
        "at" => updated.fetch("bound_at")
      }
      @state["workspace"] = updated.merge("history" => Array(current["history"]) + [entry])
      @record.event("workspace_rebound", "source" => source, "reason" => reason,
                    "from" => entry["from"], "to" => entry["to"])
      reset_artifact_observation!
      schedule_check(0, "工作区重新绑定", trigger: "rebind")
    rescue WorkspaceBinding::Error => error
      @record.event("workspace_rebind_rejected", "path" => command["path"], "reason" => error.message)
      sent = @connection.send_message("Orbit workspace rebind was rejected (not a new user instruction): #{error.message}")
      @state["sent_message_ids"] << sent.fetch("id")
    end

    def recent_events
      path = File.join(@record.path, "events.jsonl")
      return [] unless File.file?(path)

      bytes = File.open(path, "rb") do |file|
        file.seek(-[file.size, 16_384].min, IO::SEEK_END)
        file.read
      end
      bytes.lines.last(12).filter_map do |line|
        event = JSON.parse(line)
        event.slice("at", "type", "status", "verdict", "stale", "role")
      rescue JSON::ParserError
        nil
      end
    end

    def assess_jev(host, artifact_digest, now)
      signature = Digest::SHA256.hexdigest(JSON.generate([
        host.slice("status", "turn_id", "last_turn_id", "last_turn_status", "observations", "active_tools"),
        artifact_digest, @record.input_digest(@state), @state["members"].map { |member| member.slice("thread_id", "status") }
      ]))
      # Honor the scheduled cooldown even when ordinary host observations
      # change. Scope/member commands explicitly pull @jev_next_at forward;
      # status, sleep and other progress noise must not cause a full Jev call
      # every ~20 seconds.
      return nil if now < @jev_next_at

      observation = JevAdvisor.observation(
        inputs: @record.inputs(@state), host: host, members: @state["members"],
        project_root: artifact_root, artifact_digest: artifact_digest,
        elapsed_seconds: now - Time.parse(@state.fetch("created_at")).to_f,
        member_options: delegation_options
      )
      result = @advisor.assess(state: observation)
      @jev_unavailable = false
      @jev_last_at = now
      @jev_next_at = now + 60
      @jev_signature = signature
      scores = result.fetch("scores")
      @record.event("jev_assessed", "model" => result["model"], "scores" => scores, "usage" => result["usage"])
      @state["jev"] = (@state["jev"].is_a?(Hash) ? @state["jev"] : {}).merge(
        "status" => "assessed", "model" => result["model"], "scores" => scores, "usage" => result["usage"],
        "assessed_at" => Time.at(now).utc.iso8601
      )
      accumulate_jev_usage("jev_stage1", result["usage"])
      save
      stage_delegation(scores, artifact_digest, now)

      process_score = [scores.fetch("stuck"), scores.fetch("off_track")].max
      @jev_process_streak = process_score >= 0.65 ? @jev_process_streak + 1 : 0
      if scores.fetch("artifact_ready") >= 0.8 && artifact_digest != @initial_digest &&
         artifact_digest != @last_full_check_digest
        return :artifact
      end
      if (process_score >= 0.85 || @jev_process_streak >= 2) && signature != @jev_last_process_trigger
        @jev_last_process_trigger = signature
        return :process
      end
      nil
    rescue JevAdvisor::Error => error
      @jev_unavailable = true
      @jev_last_at = now
      @jev_next_at = now + 60
      @jev_signature = signature
      @jev_process_streak = 0
      @record.event("jev_unavailable", "reason" => error.message)
      @state["jev"] = (@state["jev"].is_a?(Hash) ? @state["jev"] : {}).merge(
        "status" => "unavailable", "unavailable" => error.message, "at" => Time.at(now).utc.iso8601
      )
      save
      :unavailable
    end

    def save
      @state["next_check_at"] = Time.at(@next_check).utc.iso8601
      @record.save(@state)
    end

    # Stage 1/2 can each run several times in one task; the status view reads
    # these aggregates instead of latest-only usage. A call without integer
    # token usage never contributes fabricated zeros: the bucket is flagged
    # incomplete and keeps whatever was actually measured.
    def accumulate_jev_usage(bucket, usage)
      aggregate = ((@state["usage"] ||= {})[bucket] ||= { "input_tokens" => nil, "output_tokens" => nil, "incomplete" => false })
      input = usage.is_a?(Hash) ? usage["input_tokens"] : nil
      output = usage.is_a?(Hash) ? usage["output_tokens"] : nil
      aggregate["input_tokens"] = (aggregate["input_tokens"] || 0) + input if input.is_a?(Integer)
      aggregate["output_tokens"] = (aggregate["output_tokens"] || 0) + output if output.is_a?(Integer)
      aggregate["incomplete"] = true unless input.is_a?(Integer) && output.is_a?(Integer)
    end

    def schedule_check(at, basis, trigger:, manual: false)
      # A user-requested check still queued is never replaced by an automatic
      # interval; it runs as soon as the in-flight check finishes.
      return if !manual && @state["next_check_manual"] == true

      @next_check = at
      @state["next_check_basis"] = basis
      @state["next_check_trigger"] = trigger
      @state["next_check_manual"] = manual
    end

    def consume_commands
      @record.commands do |command|
        if TERMINAL.include?(@state["status"])
          @record.event("command_rejected", "command_type" => command["type"], "reason" => "Task execution has stopped")
          next
        end
        case command.fetch("type")
        when "stop"
          stop(command.fetch("reason", "User requested stop"))
        when "amend"
          add_amendment(command.fetch("text"), command.fetch("source"))
          sent = @connection.send_message("Orbit: the user explicitly amended this task:\n\n" + command.fetch("text"))
          @state["sent_message_ids"] << sent.fetch("id")
        when "delegate"
          begin
            delegate(command)
          rescue MemberPolicy::Error => error
            @record.event("member_rejected", "kind" => command["kind"], "reason" => error.message)
            sent = @connection.send_message("Orbit member delegation was rejected (not a new user instruction): #{error.message}")
            @state["sent_message_ids"] << sent.fetch("id")
          end
        when "check"
          schedule_check(0, "用户请求的检查", trigger: "manual_check", manual: true)
        when "rebind_workspace"
          rebind_workspace(command)
        when "model_evidence"
          apply_model_evidence(command, now: Time.now.to_f)
        when "dispute"
          @state["dispute"] = command.fetch("reason")
          schedule_check(0, "用户请求的裁定", trigger: "manual_dispute", manual: true)
        else
          @record.event("command_rejected", "reason" => "Unknown command #{command['type']}")
        end
      end
      save
    end

    def add_amendment(text, source)
      relative = "amendments/#{@state.fetch('amendments').length + 1}.txt"
      @record.write(relative, text)
      @state["amendments"] << { "path" => relative, "source" => source, "at" => Time.now.utc.iso8601 }
      @record.event("instruction_amended", "source" => source)
      @state["members"].each do |member|
        next unless member["status"] == "working"
        member_connection(member).send_message("The user amended the original task. Apply only changes relevant to your delegated scope:\n\n" + text)
      end
      schedule_check(0, "用户修改后重新核对", trigger: "amendment")
    end

    # The allowlist and adapter checks run before any host or member is
    # created. Reusing an already-registered member is not new creation and
    # stays available even if the list changed.
    def delegate(command)
      instructions = member_instructions(command.fetch("text"))
      basis = delegation_basis
      member = if command["member"]
                 attach_member(command.fetch("member"), instructions)
               else
                 provider = @state.dig("connection", "provider")
                 kind = member_policy.resolve_kind(command.fetch("kind", "native"), provider)
                 member_policy.check!(kind)
                 adapter = MemberAdapters.require!(kind, provider)
                 if adapter["adapter"] == "codex_host"
                   start_codex_member(command, instructions)
                 else
                   start_native_member(command, instructions, kind)
                 end
               end
      member["delegation_basis"] = basis
      @record.event("member_delegated", "thread_id" => member["thread_id"], "kind" => member["kind"],
                    "scope" => command.fetch("text"), "basis" => basis)
      if basis == "orbit_hint"
        mark_delegation_hint_followed(member)
      else
        @record.event("delegation_without_hint", "thread_id" => member["thread_id"], "kind" => member["kind"])
      end
      save
    end

    def attach_member(thread_id, instructions)
      member = @state["members"].find { |entry| entry["thread_id"] == thread_id }
      raise ArgumentError, "member is not owned by this task" unless member

      member["status"] = "working"
      save
      member_connection(member).send_message(instructions)
      member
    end

    def start_native_member(command, instructions, kind)
      model = command["model"] || (@connection.default_member_model if @connection.respond_to?(:default_member_model)) || @state.dig("review", "model")
      id = @connection.create_member(model: model, cwd: artifact_root)
      member = { "kind" => kind, "adapter" => "same_host", "thread_id" => id, "model" => model, "status" => "starting" }
      @state["members"] << member
      # Persist ownership before this member can start any model/tool work.
      save
      @connection.start_member(id, instructions)
      member["status"] = "working"
      member
    end

    # Cross-host path: this task process owns the Codex member app-server.
    # The host record and the member identity are persisted before turn/start
    # so an explicit stop retry can reconnect from the task record.
    def start_codex_member(command, instructions)
      host = codex_member_host
      host_record = @state.fetch("member_hosts")["codex"]
      unless host_record
        host_record = host.start
        @state["member_hosts"]["codex"] = host_record
        @record.event("member_host_started", "kind" => "codex", "socket" => host_record["socket"],
                      "pid" => host_record["pid"], "pgid" => host_record["pgid"])
        save
      end
      created = host.create_member(host_record, model: command["model"], cwd: artifact_root)
      member = {
        "kind" => "codex", "thread_id" => created.fetch("thread_id"), "model" => created.fetch("model"),
        "socket" => host_record.fetch("socket"), "host" => "codex", "status" => "starting",
        "registered_at" => Time.now.utc.iso8601
      }
      @state["members"] << member
      @record.event("member_registered", "kind" => "codex", "thread_id" => member["thread_id"],
                    "socket" => member["socket"], "model" => member["model"])
      save
      host.start_member(host_record, member["thread_id"], instructions)
      member["status"] = "working"
      member
    end

    def member_instructions(scope)
      "You are an execution member for an Orbit task. Work only on the delegated scope in this project. " \
        "Follow project rules. Do not start Orbit, create other agents, commit, or push. " \
        "Report concrete results and verification to the Root. Stop your background commands before finishing.\n\n" \
        "Original task inputs:\n#{JSON.pretty_generate(@record.inputs(@state))}\n\n" \
        "Delegated scope:\n#{scope}"
    end

    def member_connection(member)
      id = member.fetch("thread_id")
      @member_connections[id] ||= if member["host"] == "codex"
                                    codex_member_host.connection_for({ "socket" => member.fetch("socket") }, id)
                                  else
                                    @connection.member_connection(id)
                                  end
    end

    def codex_member_host
      @member_host ||= CodexMemberHost.new(cwd: artifact_root)
    end

    # The list is an authorization input that may change while a task runs;
    # every dispatch re-reads it. An injected policy (tests) stays fixed.
    def member_policy
      @member_policy || MemberPolicy.load
    end

    def delegation_options
      provider = @state.dig("connection", "provider")
      allowed = member_policy.allowed_kinds
      callable = MemberAdapters.callable_kinds(provider).select { |kind| allowed.include?(kind) }
      { "allowed_kinds" => allowed, "callable_kinds" => callable,
        "hint_sent" => !@state["delegation_hint"].nil? }
    rescue MemberPolicy::Error => error
      { "allowed_kinds" => nil, "callable_kinds" => [], "error" => error.message,
        "hint_sent" => !@state["delegation_hint"].nil? }
    end

    # First stage (JEV delegation plan): the structural `delegatable` score
    # only decides whether the comparison needs model evidence. It never
    # prepares a hint; a hint requires cached `evidence` for every compared
    # identity plus the second-stage judgment.
    def stage_delegation(scores, artifact_digest, now)
      return unless scores.fetch("delegatable", 0) >= DELEGATION_HINT_THRESHOLD
      return if @state["members"].any? { |member| %w[starting working].include?(member["status"]) }

      options = delegation_options
      return if options["callable_kinds"].empty?

      signature = delegation_signature(artifact_digest, options)
      return if @state.dig("delegation_hints", signature)
      if (assessment = @state.dig("delegation_assessments", signature))
        scores = assessment["scores"]
        if scores.is_a?(Hash) && scores.fetch("member_fit", 0) >= MEMBER_FIT_THRESHOLD &&
           scores.fetch("parallel_gain", 0) >= PARALLEL_GAIN_THRESHOLD
          prepare_delegation_hint(scores, signature, now)
          @record.event("delegation_hint_recovered", "signature" => signature)
        end
        return
      end
      return if @state.dig("evidence_requests", signature)

      identities = evidence_identities(options)
      if identities.nil?
        record_evidence_gap(signature, options)
        return
      end

      entries = evidence_states(identities)
      if entries.nil?
        @pending_evidence = { "signature" => signature, "identities" => identities,
                              "needed" => %w[speed quality cost local_samples],
                              "at" => Time.at(now).utc.iso8601 }
      elsif evidence_complete?(entries)
        run_delegation_assessment(identities, entries, signature, artifact_digest, now)
      else
        record_evidence_unavailable(signature, now)
      end
    end

    # Input, artifact or candidate changes create a new signature and allow a
    # new hint; transient host noise does not.
    def delegation_signature(artifact_digest, options)
      Digest::SHA256.hexdigest(JSON.generate([
        @record.input_digest(@state), artifact_digest,
        @state["members"].map { |member| member.slice("thread_id", "status") },
        options["callable_kinds"]
      ]))
    end

    # Every compared identity must be reliable. Reasoning effort and variants
    # are never guessed (the host does not expose them here), and cross-host
    # member models are not probed. Only a same-host native candidate is taken
    # into the automatic comparison; other callable kinds are recorded as
    # unknown candidates without blocking it.
    def evidence_identities(options)
      provider = @state.dig("connection", "provider").to_s
      root = split_model_identity(root_model, provider)
      return nil unless identity_usable?(root)

      candidates = []
      options.fetch("callable_kinds").each do |kind|
        if kind.to_s == provider
          # A same-host native candidate follows the connection's member
          # default, which is the Root's configured model for same-host
          # members. The kind stays on the identity for the Root message; the
          # cache API only receives provider, model and reasoning.
          identity = split_model_identity(native_member_model, provider)
          return nil unless identity_usable?(identity)

          candidates << identity.merge("kind" => kind)
        else
          # No host is probed to discover a cross-host model identity. The
          # kind stays visible as an unknown candidate and never blocks the
          # same-host comparison.
          @state["unknown_candidates"][kind.to_s] = {
            "reason" => "cross-host model identity unknown", "at" => Time.now.utc.iso8601
          }
        end
      end
      return nil if candidates.empty?

      { "root" => root, "candidates" => candidates }
    end

    def root_model
      @connection.configured_model if @connection.respond_to?(:configured_model)
    rescue StandardError => error
      @root_model_error = "#{error.class}: #{error.message}"
      nil
    end

    def native_member_model
      if @connection.respond_to?(:default_member_model)
        @connection.default_member_model
      else
        @state.dig("review", "model")
      end
    rescue StandardError => error
      @native_model_error = "#{error.class}: #{error.message}"
      nil
    end

    # "provider/model" is the only reliable split; a bare model id belongs to
    # the connection provider. Reasoning effort stays "unknown": hosts do not
    # expose it and model names are not evidence.
    def split_model_identity(value, default_provider)
      text = value.to_s.strip
      return nil if text.empty?

      provider, model = text.include?("/") ? text.split("/", 2) : [default_provider.to_s, text]
      provider = provider.to_s.strip
      model = model.to_s.strip
      return nil if provider.empty? || model.empty?

      { "provider" => provider, "model" => model, "reasoning" => "unknown" }
    end

    def identity_usable?(identity)
      return false unless identity.is_a?(Hash)

      evidence_cache.identity(provider: identity["provider"], model: identity["model"], reasoning: identity["reasoning"])
      true
    rescue ModelEvidenceCache::Error
      false
    end

    # Re-reads the user-level cache. A missing or expired lookup needs a
    # request; an unexpired `unavailable` entry is a real answer and must not
    # be re-requested. Only valid `evidence` for every compared identity
    # reaches the second stage.
    def evidence_states(identities)
      root = lookup_evidence(identities.fetch("root"))
      return nil unless root

      candidates = identities.fetch("candidates").map { |identity| lookup_evidence(identity) }
      return nil if candidates.any?(&:nil?)

      { "root" => root, "candidates" => candidates }
    rescue ModelEvidenceCache::Error => error
      @record.event("model_evidence_cache_error", "reason" => error.message)
      nil
    end

    def evidence_statuses(states)
      [states.fetch("root"), *states.fetch("candidates")]
    end

    def evidence_complete?(states)
      evidence_statuses(states).all? { |entry| entry["status"] == "evidence" }
    end

    def lookup_evidence(identity)
      evidence_cache.lookup(provider: identity["provider"], model: identity["model"], reasoning: identity["reasoning"])
    end

    # Tests inject a temporary cache; production builds the user-level cache
    # on first use so an advisor-less task never touches the cache file.
    def evidence_cache
      @evidence_cache ||= ModelEvidenceCache.new
    end

    # Root submitted model facts through the dedicated CLI command; the CLI
    # already validated and cached them. Entries are normalized with the same
    # identity rules as the request, so a submission can carry a status but
    # never change which identity it applies to; an invalid entry matches
    # nothing.
    def submitted_evidence(command)
      Array(command["entries"]).map do |entry|
        next nil unless entry.is_a?(Hash)

        identity = evidence_cache.identity(provider: entry["provider"], model: entry["model"], reasoning: entry["reasoning"])
        status = entry["status"].to_s
        next nil unless ModelEvidenceCache::STATUSES.include?(status)

        identity.merge("status" => status)
      rescue ModelEvidenceCache::Error
        nil
      end
    end

    def evidence_identity_key(identity)
      [identity["provider"], identity["model"], identity["reasoning"]]
    end

    # Root and a same-host candidate can share one identity; the CLI and the
    # cache store it once, so coverage is an identity set, not a multiset.
    def requested_evidence_keys(identities)
      [identities.fetch("root"), *identities.fetch("candidates")].map { |identity| evidence_identity_key(identity) }.uniq
    end

    # Coverage and extras are compared as identity sets: the CLI dedupes one
    # identity submitted twice, and a same-host candidate can share the Root's
    # identity.
    def evidence_set_matches?(submitted, identities)
      submitted.map { |entry| evidence_identity_key(entry) }.uniq.sort == requested_evidence_keys(identities).sort
    end

    # Root submitted model facts through the dedicated CLI command; the CLI
    # already validated and cached them. The submitted set must cover exactly
    # the pending comparison — no missing identity, no extras. Then the cache
    # is re-read: `unavailable` is a real answer, missing or expired facts
    # stay incomplete, and only valid `evidence` for every compared identity
    # reaches the second stage. None of the other outcomes call JEV, hint
    # automatically or trigger another request loop.
    def apply_model_evidence(command, now:)
      @record.event("model_evidence_submitted", "entries" => Array(command["entries"]).length)
      request = @state["evidence_request"]
      unless request.is_a?(Hash)
        @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "unrequested")
        @record.event("model_evidence_ignored", "reason" => "no pending evidence request")
        save
        return
      end

      identities = request.fetch("identities")
      submitted = submitted_evidence(command)
      unless submitted && evidence_set_matches?(submitted, identities)
        request["resolved"] = "mismatch"
        @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "unknown")
        @record.event("model_evidence_mismatch", "expected" => requested_evidence_keys(identities),
                      "submitted" => Array(submitted).map { |entry| evidence_identity_key(entry) })
        save
        return
      end

      states = evidence_states(identities)
      if submitted.any? { |entry| entry["status"] == "unavailable" } ||
         (states && evidence_statuses(states).any? { |entry| entry["status"] == "unavailable" })
        request["resolved"] = "unavailable"
        @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "unavailable")
        @record.event("model_evidence_unavailable", "reason" => "a compared identity records unavailable")
        save
        return
      end

      unless states && evidence_complete?(states)
        request["resolved"] = "incomplete"
        @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "incomplete")
        @record.event("model_evidence_incomplete", "identities" => identities)
        save
        return
      end

      request["resolved"] = "used"
      @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "used")
      @state["jev"]["evidence"] = { "identities" => identities, "at" => Time.at(now).utc.iso8601 }
      @record.event("model_evidence_used", "identities" => identities, "valid_until" => states.dig("root", "valid_until"))
      save
      artifact_digest = probe_artifact(now)
      signature = delegation_signature(artifact_digest, delegation_options)
      run_delegation_assessment(identities, states, signature, artifact_digest, now)
    end

    # Second stage: consumes only validated cache facts and the bounded task
    # observation, and is asked at most once per observation signature.
    def run_delegation_assessment(identities, entries, signature, artifact_digest, now)
      return unless @advisor
      return if @state.dig("delegation_assessments", signature)

      summary = delegation_evidence_summary(identities, entries)
      observation = JevAdvisor.observation(
        inputs: @record.inputs(@state), host: @connection.state, members: @state["members"],
        project_root: artifact_root, artifact_digest: artifact_digest,
        elapsed_seconds: now - Time.parse(@state.fetch("created_at")).to_f,
        member_options: delegation_options
      ).merge("model_evidence" => summary)
      result = @advisor.assess_delegation(state: observation)
      scores = result.fetch("scores")
      decision = if scores.fetch("member_fit", 0) >= MEMBER_FIT_THRESHOLD &&
                    scores.fetch("parallel_gain", 0) >= PARALLEL_GAIN_THRESHOLD
                   "recommended"
                 else
                   "declined"
                 end
      @state["delegation_assessments"][signature] = {
        "scores" => scores, "model" => result["model"], "decision" => decision,
        "at" => Time.at(now).utc.iso8601
      }
      @state["jev"] = (@state["jev"] || {}).merge(
        "delegation" => { "status" => "assessed", "decision" => decision, "scores" => scores,
                          "usage" => result["usage"], "at" => Time.at(now).utc.iso8601 }
      )
      accumulate_jev_usage("jev_stage2", result["usage"])
      @record.event("delegation_assessed", "model" => result["model"], "scores" => scores,
                    "usage" => result["usage"], "decision" => decision)
      if decision == "recommended"
        prepare_delegation_hint(scores, signature, now)
      else
        @record.event("delegation_declined", "scores" => scores, "decision" => decision)
      end
      save
    rescue JevAdvisor::Error => error
      # The second stage is attempted at most once per observation signature,
      # including failures, so a service error cannot become a tick loop.
      @state["delegation_assessments"][signature] = {
        "error" => error.message, "decision" => "unavailable", "at" => Time.at(now).utc.iso8601
      }
      @state["jev"] = (@state["jev"] || {}).merge(
        "delegation" => { "status" => "unavailable", "decision" => "unavailable", "reason" => error.message,
                          "at" => Time.at(now).utc.iso8601 }
      )
      @record.event("delegation_unavailable", "reason" => error.message)
      save
    end

    # Bounded, JSON-safe summary of validated cache facts. Values keep their
    # submitted unit and basis; different units are never merged into a single
    # pseudo-precise score, and no web page text can reach this structure.
    def delegation_evidence_summary(identities, entries)
      entry_summary = lambda do |identity, entry|
        {
          "provider" => identity["provider"], "model" => identity["model"], "reasoning" => identity["reasoning"],
          "status" => entry["status"], "retrieved_at" => entry["retrieved_at"], "valid_until" => entry["valid_until"],
          "sources" => Array(entry["sources"]), "metrics" => entry["metrics"]
        }
      end
      {
        "root" => entry_summary.call(identities.fetch("root"), entries.fetch("root")),
        "candidates" => identities.fetch("candidates").each_with_index.map do |identity, index|
          entry_summary.call(identity, entries.fetch("candidates").fetch(index))
        end,
        "note" => "Validated cache facts only; unit and basis are preserved and no cross-unit score is fabricated."
      }
    end

    # The automatic chain stops when an identity cannot be established. Root
    # may still delegate manually; Orbit does not guess or probe hosts.
    def record_evidence_gap(signature, options)
      return if @state.dig("evidence_gaps", signature)

      reason = if @root_model_error
                 "root model unavailable (#{@root_model_error})"
               elsif options.fetch("callable_kinds").none? { |kind| kind.to_s == @state.dig("connection", "provider").to_s }
                 "no same-host candidate model identity is establishable"
               else
                 "at least one compared identity is unknown"
               end
      @state["evidence_gaps"][signature] = { "reason" => reason, "callable_kinds" => options["callable_kinds"],
                                             "at" => Time.now.utc.iso8601 }
      @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "unknown", "evidence_note" => reason)
      @record.event("model_evidence_unknown", "reason" => reason, "callable_kinds" => options["callable_kinds"])
      save
    end

    # An unexpired `unavailable` entry means Root already tried and found no
    # comparable facts: no second stage, no automatic hint, no new request.
    def record_evidence_unavailable(signature, now)
      return if @state.dig("evidence_gaps", signature)

      @state["evidence_gaps"][signature] = { "reason" => "cached evidence is unavailable",
                                             "at" => Time.at(now).utc.iso8601 }
      @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "unavailable")
      @record.event("model_evidence_unavailable", "reason" => "a compared identity records unavailable")
      save
    end

    # One bounded request per observation signature; repeated ticks do not
    # loop, and Orbit never browses for evidence itself.
    def deliver_pending_evidence
      pending = @pending_evidence
      @pending_evidence = nil
      return unless pending
      return if @state.dig("evidence_requests", pending.fetch("signature"))

      text = +"Orbit model evidence request (not a new user instruction): before judging delegation, Jev needs public model facts.\n"
      text << "Compare:\n- root: #{format_identity(pending.dig('identities', 'root'))}\n"
      pending.dig("identities", "candidates").each do |identity|
        text << "- candidate (#{identity['kind']}): #{format_identity(identity)}\n"
      end
      text << "Needed per identity: speed, quality, cost and local samples, each with source URL, retrieved_at and validity.\n"
      text << "Submit one JSON object or an array with: orbit model-evidence #{@record.path} --file -\n"
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      @state["evidence_requests"][pending.fetch("signature")] = {
        "identities" => pending.fetch("identities"), "needed" => pending.fetch("needed"),
        "at" => pending.fetch("at"), "message_id" => sent.fetch("id")
      }
      @state["evidence_request"] = @state["evidence_requests"][pending.fetch("signature")]
      @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "requested")
      @record.event("model_evidence_needed", "identities" => pending.fetch("identities"), "needed" => pending.fetch("needed"))
      save
    rescue StandardError => error
      @record.event("model_evidence_request_failed", "error" => error.message)
      save
    end

    def format_identity(identity)
      return "unknown" unless identity.is_a?(Hash)

      "#{identity['provider']}/#{identity['model']} (reasoning: #{identity['reasoning']})"
    end

    def prepare_delegation_hint(scores, signature, now)
      return if @state.dig("delegation_hints", signature)

      options = delegation_options
      return if options["callable_kinds"].empty?

      @pending_hint = {
        "signature" => signature, "score" => @state.dig("jev", "scores", "delegatable"),
        "member_fit" => scores.fetch("member_fit"), "parallel_gain" => scores.fetch("parallel_gain"),
        "callable_kinds" => options["callable_kinds"], "at" => Time.at(now).utc.iso8601
      }
    end

    def observation_stale?(host, artifact_digest, latest_host, latest_digest, now)
      latest_host["interrupted"] || latest_host["status"] != host["status"] ||
        host_digest(latest_host) != host_digest(host) || latest_digest != artifact_digest || now >= @next_check
    end

    def deliver_pending_hint
      hint = @pending_hint
      @pending_hint = nil
      return unless hint
      return if @state.dig("delegation_hints", hint.fetch("signature"))

      text = "Orbit delegation hint (not a new user instruction): Jev judged that a bounded subtask could be delegated now " \
             "(delegatable #{hint['score']}, member_fit #{hint['member_fit']}, parallel_gain #{hint['parallel_gain']}; " \
             "callable kinds: #{hint['callable_kinds'].join('、')}). If you agree, form the full execution ticket and call " \
             "delegate explicitly; Orbit does not dispatch."
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      @state["delegation_hints"][hint.fetch("signature")] = hint.merge("message_id" => sent.fetch("id"))
      @state["delegation_hint"] = hint.merge("message_id" => sent.fetch("id"))
      @record.event("delegation_hint", "score" => hint["score"], "member_fit" => hint["member_fit"],
                    "parallel_gain" => hint["parallel_gain"], "callable_kinds" => hint["callable_kinds"])
      save
    rescue StandardError => error
      # A hint is advisory: delivery failure must not fail the task or
      # interrupt any check decision.
      @record.event("delegation_hint_failed", "error" => error.message)
      save
    end

    # A persisted, not-yet-followed hint for the current input, artifact and
    # member candidates is the only Orbit basis. An old hint must not label a
    # later explicit dispatch after those facts changed.
    def delegation_basis
      hint = @state["delegation_hint"]
      return "root_without_hint" unless hint.is_a?(Hash) && !hint.empty? && hint["followed"] != true

      signature = delegation_signature(fingerprint_artifact, delegation_options)
      hint["signature"] == signature ? "orbit_hint" : "root_without_hint"
    rescue WorkspaceSnapshot::Error, MemberPolicy::Error
      "root_without_hint"
    end

    def mark_delegation_hint_followed(member)
      hint = @state["delegation_hint"]
      return unless hint && !hint["followed"]

      hint["followed"] = true
      hint["followed_kind"] = member["kind"]
      @record.event("delegation_hint_followed", "kind" => member["kind"], "thread_id" => member["thread_id"])
    end

    def collect_member_results
      @state["members"].each do |member|
        next unless member["status"] == "working"
        connection = member_connection(member)
        state = connection.state
        next unless state["status"] == "idle" && state["last_turn_id"] && state["last_turn_id"] != member["reported_turn"]

        confirmation = connection.stop!
        raise ArgumentError, "member did not confirm background execution stopped" unless confirmation["confirmed"]
        member["status"] = state["last_turn_status"] == "completed" ? "completed" : "failed"
        member["reported_turn"] = state["last_turn_id"]
        member["result"] = state["observations"]
        member["stop_confirmation"] = confirmation
        sent = @connection.send_message("Orbit execution member result (not a new user requirement). " \
          "Review and integrate against the original task; continue in this same Root session.\n\n" + JSON.pretty_generate(member))
        @state["sent_message_ids"] << sent.fetch("id")
        @record.event("member_result", "thread_id" => member["thread_id"], "status" => member["status"])
        save
      end
    end

    def members_settled?
      @state["members"].all? { |member| %w[completed failed].include?(member["status"]) }
    end

    def collect_amendments
      previous = @state["last_user_message_id"]
      return true unless previous

      messages = @connection.user_messages(after_id: previous)
      if @connection.respond_to?(:observation_gap) && (gap = @connection.observation_gap)
        @state["observation_pending"] = gap
        save
        return false if gap["reason"] == "pending_delivery"

        stop("Cannot observe user changes: #{gap['detail']}", status: "needs_user")
        return false
      end
      messages.each do |message|
        unless message["internal"] || @state["sent_message_ids"].include?(message.fetch("id"))
          kind = @connection.respond_to?(:instruction_source_kind) ? @connection.instruction_source_kind : "codex_user_message"
          add_amendment(message.fetch("text"), { "kind" => kind, "id" => message.fetch("id") })
        end
        @state["last_user_message_id"] = message.fetch("id")
      end
      save
      true
    end

    def start_check(host, now, kind: "artifact", trigger:, manual: false)
      role = @state["dispute"] ? "adjudicator" : kind == "process" ? "process_reviewer" : "reviewer"
      digest = fingerprint_artifact
      key = ObservationKey.build(
        input_digest: @record.input_digest(@state), artifact_root: artifact_root, artifact_digest: digest,
        host: host, findings: @state.fetch("findings"), dispute: @state["dispute"],
        trigger: { "kind" => kind, "role" => role }
      )
      prior = @state.fetch("check_observations")[key]
      if prior && prior["status"] == "in_flight" && @running_check.nil?
        # A newly started runtime cannot own the checker process recorded by
        # an older crashed runtime. Treat that persisted in-flight marker as
        # abandoned and retry once; live checks in this runtime never reach
        # start_check because tick polls @running_check first.
        prior["status"] = "abandoned"
        prior["abandoned_at"] = Time.at(now).utc.iso8601
        @record.event("check_abandoned_recovered", "key" => key, "check" => prior["check"])
        prior = nil
      end
      if !manual && prior
        # The same observation was already checked or is being checked: do not
        # pay for another model call. The agreed interval replaces the due
        # timer so an unchanged observation cannot retry every tick.
        @last_full_check_digest = digest if kind == "artifact"
        @record.event("check_duplicate_skipped", "key" => key, "trigger" => trigger,
                      "previous_check" => prior["check"], "previous_status" => prior["status"],
                      "previous_stale" => prior["stale"])
        schedule_check(now + @interval, "相同观察已检查，跳过重复自动检查", trigger: "timer")
        save
        return false
      end
      used_numbers = @state.fetch("checks").filter_map { |check| check["number"] } +
                     @state.fetch("check_observations").values.filter_map { |entry| entry["check"] }
      number = used_numbers.max.to_i + 1
      directory = File.join(@record.path, "checks", number.to_s)
      snapshot = WorkspaceSnapshot.capture(
        project_root: artifact_root, destination: File.join(directory, "workspace")
      )
      clues = role == "reviewer" ? @state["recheck"] : nil
      scope = {
        "number" => number, "role" => role, "kind" => kind, "artifact_root" => artifact_root,
        "observation_key" => key, "trigger_cause" => trigger, "manual" => manual,
        "snapshot" => snapshot,
        "input_digest" => @record.input_digest(@state), "host_digest" => host_digest(host),
        "dispute" => @state["dispute"],
        "started_at" => Time.at(now).utc.iso8601
      }
      @record.write("checks/#{number}/scope.json", JSON.pretty_generate(scope))
      @checker.start(
        directory: snapshot.fetch("snapshot_path"), inputs: @record.inputs(@state),
        context: {
          "root" => host, "findings" => @state.fetch("findings"),
          "recent_events" => recent_events, "recheck" => clues,
          "execution_members" => @state["members"],
          "decisions" => @state.fetch("decisions"), "dispute" => @state["dispute"],
          "estimate" => @state.fetch("estimate"), "hard_deadline" => @state["hard_deadline"],
          "elapsed_seconds" => now - Time.parse(@state.fetch("created_at")).to_f,
          "project_rules" => snapshot.fetch("project_rules"),
          "review_focus" => review_focus(snapshot.fetch("manifest")),
          "uncopied_entries" => snapshot.fetch("manifest").select do |entry|
            %w[gitlink other].include?(entry["kind"]) || entry["materialized"] == false
          end
        }, output_dir: directory, role: role
      )
      @running_check = scope
      @state["next_check_manual"] = false
      @state["check_observations"][key] = {
        "status" => "in_flight", "check" => number, "stale" => nil,
        "trigger_cause" => trigger, "manual" => manual, "started_at" => Time.at(now).utc.iso8601
      }
      @last_full_check_digest = snapshot.fetch("digest") if kind == "artifact"
      @state.delete("observation_pending")
      @record.event("check_started", "number" => number, "role" => role, "digest" => snapshot.fetch("digest"))
      save
      true
    end

    def host_digest(host)
      Digest::SHA256.hexdigest(JSON.generate(host.slice("last_turn_id", "last_turn_status", "observations")))
    end

    # Artifact reviews judge the fixed snapshot. A host-only digest change does
    # not expire them or block completion. Process reviews still do.
    def host_digest_stale?(scope, host)
      scope["kind"] != "artifact" && host_digest(host) != scope["host_digest"]
    end

    # Added, modified and deleted paths from the fixed snapshot. Tracked and
    # present entries are not a review focus. Each list is capped and sorted.
    def review_focus(manifest)
      groups = REVIEW_FOCUS_STATUSES.to_h { |status| [status, []] }
      Array(manifest).each do |entry|
        next unless entry.is_a?(Hash) && groups.key?(entry["status"]) && entry["path"].is_a?(String)
        next if entry["path"].empty?

        groups[entry["status"]] << entry["path"]
      end
      groups.transform_values { |paths| paths.uniq.sort.first(REVIEW_FOCUS_LIMIT) }
    end

    def finish_check(result, host, now)
      scope = @running_check
      current_digest = fingerprint_artifact
      @running_check = nil
      @check_result = nil
      stale_reasons = []
      stale_reasons << "workspace" if scope["artifact_root"] != artifact_root
      stale_reasons << "artifact" if current_digest != scope.dig("snapshot", "digest")
      stale_reasons << "input" if @record.input_digest(@state) != scope["input_digest"]
      stale_reasons << "host" if host_digest_stale?(scope, host)
      stale_reasons << "dispute" if @state["dispute"] != scope["dispute"]
      stale = !stale_reasons.empty?
      @state["checks"] << scope.slice("number", "role", "kind", "started_at", "observation_key", "trigger_cause", "manual").merge(
        "result" => result, "stale" => stale, "stale_reasons" => stale_reasons,
        "finished_at" => Time.at(now).utc.iso8601,
        "usage" => @checker.respond_to?(:usage) ? @checker.usage : nil
      )
      observation = @state.fetch("check_observations")[scope["observation_key"]]
      if observation
        observation["status"] = "finished"
        observation["stale"] = stale
        observation["check"] = scope["number"]
        observation["finished_at"] = Time.at(now).utc.iso8601
      end
      @record.event("check_finished", "number" => scope["number"], "stale" => stale,
                    "stale_reasons" => stale_reasons, "verdict" => result.fetch("verdict"))
      if scope["kind"] == "artifact"
        if host["status"] == "idle"
          schedule_check(now + result.fetch("next_check_seconds"), "检查者建议的下次观察",
                         trigger: "checker_interval")
        else
          # A checker-suggested short restart plus continuous editing produced
          # repeated stale full checks. The agreed interval is the floor while
          # Root is executing; idle delivery still gets a fresh check.
          schedule_check(now + [result.fetch("next_check_seconds"), @interval].max,
                         "Root 执行中，完整检查间隔以约定时间为下限", trigger: "checker_interval")
        end
      end
      if stale
        # A moving workspace cannot be approved or interrupted using an old
        # finding. Keep actionable stale findings as reconciliation clues; the
        # next applicable check re-verifies them and corrections then reach
        # Root without Root polling the task record. Findings from the wrong
        # workspace are binding-invalid and never migrate as clues.
        if scope["role"] != "adjudicator" && !stale_reasons.include?("workspace") &&
           %w[correct continue].include?(result.fetch("verdict")) &&
           !result.fetch("findings").empty?
          clues = @state.dig("recheck", "findings") || []
          known = clues.map { |finding| finding["id"] }
          added = result.fetch("findings").reject { |finding| known.include?(finding["id"]) }
          @state["recheck"] = {
            "check" => scope["number"], "at" => Time.at(now).utc.iso8601,
            "findings" => clues + added.map { |finding| finding.slice("id", "requirement", "evidence", "action") }
          }
          @record.event("recheck_pending", "check" => scope["number"], "count" => added.length,
                        "open_clues" => @state.dig("recheck", "findings").length)
        end
        # Only a workspace rebind rechecks immediately: the old snapshot cannot
        # answer for the new root. Any other stale line waits for the normal
        # timer, the next delivery or an explicit manual check.
        schedule_check(now, "工作区重新绑定", trigger: "rebind") if stale_reasons.include?("workspace")
        save
        return
      end

      # A clue survives until a reviewer that judges the artifact explicitly
      # reports it again (now a normal finding, delivered by the normal path)
      # or withdraws it. Otherwise an unreported clue is not silently lost.
      # Process checks do not judge artifact findings, so they never reconcile.
      if @state["recheck"] && scope["role"] == "reviewer"
        mentioned = result.fetch("resolved_ids") + result.fetch("findings").map { |finding| finding.fetch("id") }
        remaining = @state["recheck"].fetch("findings", []).reject { |clue| mentioned.include?(clue["id"]) }
        if remaining.empty?
          @state.delete("recheck")
        else
          @state["recheck"]["findings"] = remaining
          @state["recheck"]["at"] = Time.at(now).utc.iso8601
          @record.event("recheck_kept", "check" => scope["number"], "count" => remaining.length,
                        "ids" => remaining.map { |clue| clue["id"] })
        end
      end
      (scope["kind"] == "process" ? [] : result.fetch("resolved_ids")).each do |id|
        finding = @state["findings"][id]
        next unless finding

        finding["status"] = "resolved"
        finding["resolution"] = result.fetch("reason")
        finding["resolution_role"] = scope["role"]
        finding["resolution_check"] = scope["number"]
        finding["resolution_root"] = scope["artifact_root"]
        finding["resolution_version"] = current_digest
        finding["resolution_input"] = scope["input_digest"]
      end
      accepted_findings = []
      result.fetch("findings").each do |finding|
        previous = @state["findings"][finding.fetch("id")]
        if previous && previous["status"] == "open" &&
           previous["observed_root"] == scope["artifact_root"] &&
           previous["observed_version"] == current_digest &&
           previous["observed_input"] == scope["input_digest"] &&
           %w[requirement evidence action].all? { |field| previous[field] == finding[field] }
          @record.event("finding_repeat_ignored", "id" => finding.fetch("id"),
                        "reason" => "Already open on the same root, artifact, input, and finding text")
          next
        end
        # A resolved finding may only be reopened by new evidence: the task
        # inputs, the artifact root, the artifact bytes, or the finding's own
        # requirement/evidence/action text must actually differ. Same versions
        # re-raised (including as recheck clues confirmed again) are the same
        # decision, not a new one.
        if previous && previous["status"] == "resolved" &&
           previous["resolution_root"] == artifact_root &&
           previous["resolution_version"] == current_digest &&
           previous["resolution_input"] == scope["input_digest"] &&
           %w[requirement evidence action].all? { |field| previous[field] == finding[field] }
          @record.event("finding_reopen_ignored", "id" => finding.fetch("id"),
                        "reason" => "No changed root, artifact, input, or finding text")
          next
        end
        @state["findings"][finding.fetch("id")] = finding.merge(
          "status" => "open", "check" => scope["number"],
          "observed_root" => scope["artifact_root"], "observed_version" => current_digest,
          "observed_input" => scope["input_digest"]
        )
        accepted_findings << finding
      end
      notify_finalization_ready(scope, result, host, current_digest, now)
      if scope["role"] == "adjudicator"
        # The decision binds the exact versions it judged so later checks can
        # tell reopened evidence from re-raised wording; `result` stays for
        # existing consumers.
        @state["decisions"] << {
          "dispute" => @state.delete("dispute"), "check" => scope["number"], "result" => result,
          "input_digest" => scope["input_digest"], "artifact_root" => scope["artifact_root"],
          "artifact_digest" => scope.dig("snapshot", "digest"),
          "resolved_ids" => result.fetch("resolved_ids"),
          "finding_ids" => result.fetch("findings").map { |finding| finding.fetch("id") },
          "reason" => result.fetch("reason"), "decided_at" => Time.at(now).utc.iso8601
        }
      end
      case result.fetch("verdict")
      when "complete"
        if scope["kind"] == "process"
          @record.event("process_check_complete_ignored", "number" => scope["number"])
        elsif host["status"] == "idle" && host["last_turn_status"] == "completed" &&
           members_settled? && @state["recheck"].nil? &&
           @state["findings"].values.none? { |finding| finding["status"] == "open" }
          confirmation = confirmed_stop
          @state["stop_confirmation"] = confirmation
          return unless collect_amendments
          final_host = @connection.state
          final_digest = fingerprint_artifact
          host_stable = scope["kind"] == "artifact" || host_digest(final_host) == scope["host_digest"]
          if final_digest == current_digest && @record.input_digest(@state) == scope["input_digest"] && host_stable
            @state["status"] = "complete"
            @state["delivery_digest"] = current_digest
          else
            schedule_check(now, "完成核对前版本变化，立即重新核对", trigger: "version_change")
          end
        else
          @state["observation_pending"] = {
            "reason" => "Completion needs an idle Root, settled execution members, " \
                        "all delivery findings resolved and pending clues reconciled"
          }
        end
      when "correct"
        send_correction(result.merge("findings" => accepted_findings)) unless accepted_findings.empty?
      when "pause"
        stop(result.fetch("reason"))
      when "needs_user"
        stop(result.fetch("reason"), status: "needs_user")
      when "continue"
        send_correction(result.merge("findings" => accepted_findings)) if host["status"] == "idle" && !accepted_findings.empty?
      end
      save
    end

    # A manual final review may legitimately return `continue`: the checker
    # cannot declare the product task complete. Wake an idle Root once for the
    # exact reviewed version so it can call stop, and prevent a one-second
    # checker loop while that hand-off is pending.
    def notify_finalization_ready(scope, result, host, current_digest, now)
      return unless scope["kind"] == "artifact" && scope["role"] == "reviewer" && scope["manual"]
      return unless %w[continue correct].include?(result.fetch("verdict"))
      return unless result.fetch("findings").empty? && @state["recheck"].nil?
      return unless @state["findings"].values.none? { |finding| finding["status"] == "open" }
      return unless members_settled?
      return unless host["status"] == "idle" && host["last_turn_status"] == "completed"

      key = Digest::SHA256.hexdigest(JSON.generate([
        scope["artifact_root"], current_digest, scope["input_digest"]
      ]))
      unless @state["finalization_notices"][key]
        text = "Orbit final-check notice (not a new user instruction): the manual review of the current " \
               "artifact and task input is valid and no current findings remain. If implementation and local " \
               "verification are complete, call Orbit stop now; Orbit does not infer task completion from the " \
               "checker's verdict alone."
        sent = @connection.send_message(text)
        @state["sent_message_ids"] << sent.fetch("id")
        @state["finalization_notices"][key] = {
          "check" => scope["number"], "message_id" => sent.fetch("id"),
          "at" => Time.at(now).utc.iso8601
        }
        @record.event("finalization_notice", "check" => scope["number"], "version" => current_digest)
      end
      schedule_check(now + @interval, "等待 Root 根据有效终检收尾", trigger: "finalization_wait")
    end

    def send_correction(result)
      entry = File.expand_path("../../scripts/orbit", __dir__)
      dispute = [entry, "dispute", @record.path, "--reason"].shelljoin
      text = "Orbit independent check (not a new user instruction):\n" + JSON.pretty_generate(result) +
             "\nWork against the original request. Correct relevant findings. For a real dispute, provide concrete contrary evidence using: #{dispute} 'reason and evidence'."
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      @record.event("correction_sent", "id" => sent.fetch("id"))
    end

    def stop(reason, status: "paused")
      checker_error = @state["cleanup_error"]
      begin
        @checker.stop! if @running_check
      rescue StandardError => error
        checker_error = error.message
        record_cleanup_error(error)
      end
      @running_check = nil
      confirmation = confirmed_stop
      @state["execution_stop_confirmation"] = confirmation if checker_error
      raise ArgumentError, "Checker stop unconfirmed: #{checker_error}" if checker_error
      @state["stop_confirmation"] = confirmation
      @state["status"] = status
      @state["stop_reason"] = reason
      @record.event("stopped", "reason" => reason, "confirmation" => confirmation)
      save
    rescue StandardError => error
      @state["status"] = "stop_unconfirmed"
      @state["stop_reason"] = reason
      @state["error"] = error.message
      @record.event("stop_unconfirmed", "reason" => reason, "error" => error.message)
      save
    end

    def record_cleanup_error(error)
      @state["cleanup_error"] = error.message
      @state["unconfirmed_check_run"] = "checks/#{@running_check.fetch('number')}/run.json" if @running_check
    end

    def verify_prior_check_exit
      return unless @state["cleanup_error"] && @state["unconfirmed_check_run"]
      run = JSON.parse(File.read(File.join(@record.path, @state["unconfirmed_check_run"])))
      pgid = Integer(run.fetch("pgid"))
      return unless pgid.positive?
      Process.kill(0, -pgid)
    rescue Errno::ESRCH
      @state.delete("cleanup_error")
      @state.delete("unconfirmed_check_run")
      @record.event("checker_stop_verified", "pgid" => pgid, "reason" => "Recorded process group no longer exists")
    rescue SystemCallError, JSON::ParserError, KeyError, ArgumentError
      # Missing evidence or a still-existing group cannot be relabeled stopped.
      nil
    end

    def confirmed_stop
      failures = []
      begin
        confirmation = @connection.stop!
        failures << "Root did not confirm actual stop" unless confirmation["confirmed"] == true
      rescue StandardError => error
        failures << "Root: #{error.message}"
      end
      members = @state["members"].map do |member|
        if member["host"] == "codex"
          stop_codex_member(member, failures)
        else
          begin
            result = member_connection(member).stop!
            failures << "Member #{member['thread_id']} did not confirm actual stop" unless result["confirmed"] == true
            member["stop_confirmation"] = result
            { "thread_id" => member["thread_id"], "confirmation" => result }
          rescue StandardError => error
            failures << "Member #{member['thread_id']}: #{error.message}"
            { "thread_id" => member["thread_id"], "error" => error.message }
          end
        end
      end
      @state["member_stop_results"] = members
      # The member host is closed only after every stop was confirmed; an
      # unconfirmed stop keeps the recorded address for an explicit retry
      # instead of inferring member exit from a missing socket.
      @state["member_host_shutdown"] = shutdown_member_hosts(failures) if failures.empty?
      raise ArgumentError, failures.join("; ") unless failures.empty?

      confirmation["members"] = members unless members.empty?
      confirmation
    end

    # A missing socket is not stop evidence; the recorded host process group
    # no longer existing is.
    def stop_codex_member(member, failures)
      result = member_connection(member).stop!
      failures << "Member #{member['thread_id']} did not confirm actual stop" unless result["confirmed"] == true
      member["stop_confirmation"] = result
      { "thread_id" => member["thread_id"], "confirmation" => result }
    rescue CodexConnection::UnmaterializedThread
      evidence = {
        "confirmed" => true, "no_materialized_turn" => true,
        "scope" => "member thread has no user turn yet on the member host; no registered execution to interrupt"
      }
      member["stop_confirmation"] = evidence
      { "thread_id" => member["thread_id"], "confirmation" => evidence }
    rescue StandardError => error
      if member_host_exited?(member)
        evidence = {
          "confirmed" => true, "host_exit_verified" => true,
          "scope" => "recorded member app-server process group no longer exists; registered member execution cannot remain"
        }
        member["stop_confirmation"] = evidence
        { "thread_id" => member["thread_id"], "confirmation" => evidence }
      else
        failures << "Member #{member['thread_id']}: #{error.message}; member host still present"
        { "thread_id" => member["thread_id"], "error" => error.message }
      end
    end

    def member_host_exited?(member)
      host_record = @state.dig("member_hosts", member["host"]) || @state.dig("member_hosts", "codex")
      return false unless host_record

      !codex_member_host.alive?(host_record)
    rescue StandardError
      false
    end

    def shutdown_member_hosts(failures)
      @state.fetch("member_hosts", {}).map do |kind, host_record|
        outcome = codex_member_host.shutdown(host_record)
        failures << "Member host #{kind} did not confirm process exit" unless outcome["confirmed"] == true
        outcome.merge("kind" => kind)
      end
    end
  end
end
