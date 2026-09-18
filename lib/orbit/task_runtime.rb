# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "shellwords"
require_relative "task_record"
require_relative "workspace_snapshot"
require_relative "connection"
require_relative "jev_advisor"
require_relative "codex_member_host"
require_relative "member_policy"

module Orbit
  class TaskRuntime
    TERMINAL = %w[complete paused needs_user failed stop_unconfirmed].freeze
    DELEGATION_HINT_THRESHOLD = 0.8

    def initialize(record:, connection:, checker:, advisor: nil, member_host: nil, member_policy: nil)
      @record, @connection, @checker = record, connection, checker
      @advisor = advisor
      @member_host = member_host
      @member_policy = member_policy
      @state = record.state
      @state["findings"] ||= {}
      @state["sent_message_ids"] ||= []
      @state["members"] ||= []
      @state["member_hosts"] ||= {}
      @member_connections = {}
      @state["last_user_message_id"] ||= @state.dig("instruction_source", "id")
      @interval = @state.fetch("review").fetch("interval_seconds", 300)
      @next_check = Time.now.to_f + @interval
      @state["next_check_basis"] ||= "约定检查间隔"
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
          @initial_digest = WorkspaceSnapshot.fingerprint(project_root: @state.fetch("project_root"))
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
                  !@first_change_checked && WorkspaceSnapshot.fingerprint(project_root: @state.fetch("project_root")) != @initial_digest
                end
      delivery_due = delivery && host["last_turn_id"] != @last_delivery_checked
      if now >= @next_check || delivery_due
        start_check(host, now)
        @first_change_checked = true
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
          consume_commands
          return if TERMINAL.include?(@state["status"])
          return unless collect_amendments
          latest_host = @connection.state
          latest_digest = WorkspaceSnapshot.fingerprint(project_root: @state.fetch("project_root"))
          if observation_stale?(host, artifact_digest, latest_host, latest_digest, now)
            @jev_next_at = now + 20
            return
          end
        end
        case decision
        when :artifact
          start_check(host, now)
          @first_change_checked = true
        when :process
          start_check(host, now, kind: "process")
        when :unavailable
          if changed
            start_check(host, now)
            @first_change_checked = true
          end
        when nil
          if @jev_unavailable && changed
            start_check(host, now)
            @first_change_checked = true
          end
        end
        # Hints use the same freshness re-check as check decisions; a hint
        # that failed it is dropped rather than sent against an old state.
        if @pending_hint
          consume_commands
          return if TERMINAL.include?(@state["status"])
          return unless collect_amendments
          latest_host = @connection.state
          latest_digest = WorkspaceSnapshot.fingerprint(project_root: @state.fetch("project_root"))
          if observation_stale?(host, artifact_digest, latest_host, latest_digest, now)
            @jev_next_at = now + 20
            @pending_hint = nil
          else
            deliver_pending_hint
          end
          return
        end
      elsif changed
        start_check(host, now)
        @first_change_checked = true
      end
    rescue WorkspaceSnapshot::UnstableError => error
      @state["observation_pending"] = { "reason" => error.message, "paths" => error.paths }
      save
    end

    private

    def probe_artifact(now)
      if @artifact_digest.nil? || now - @last_artifact_probe_at >= 5
        @artifact_digest = WorkspaceSnapshot.fingerprint(project_root: @state.fetch("project_root"))
        @last_artifact_probe_at = now
      end
      @artifact_digest
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
      return nil if now < @jev_next_at && (signature == @jev_signature || now - @jev_last_at < 20)

      observation = JevAdvisor.observation(
        inputs: @record.inputs(@state), host: host, members: @state["members"],
        project_root: @state.fetch("project_root"), artifact_digest: artifact_digest,
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
      @state["jev"] = { "model" => result["model"], "scores" => scores, "usage" => result["usage"],
                         "assessed_at" => Time.at(now).utc.iso8601 }
      save
      prepare_hint(scores, now)

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
      @state["jev"] = { "unavailable" => error.message, "at" => Time.at(now).utc.iso8601 }
      save
      :unavailable
    end

    def save
      @state["next_check_at"] = Time.at(@next_check).utc.iso8601
      @record.save(@state)
    end

    def schedule_check(at, basis)
      @next_check = at
      @state["next_check_basis"] = basis
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
          schedule_check(0, "用户请求的检查")
        when "dispute"
          @state["dispute"] = command.fetch("reason")
          schedule_check(0, "用户请求的裁定")
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
      schedule_check(0, "用户修改后重新核对")
    end

    # The allowlist and adapter checks run before any host or member is
    # created. Reusing an already-registered member is not new creation and
    # stays available even if the list changed.
    def delegate(command)
      instructions = member_instructions(command.fetch("text"))
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
      @record.event("member_delegated", "thread_id" => member["thread_id"], "kind" => member["kind"],
                    "scope" => command.fetch("text"))
      mark_delegation_hint_followed(member)
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
      id = @connection.create_member(model: model)
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
      created = host.create_member(host_record, model: command["model"])
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
      @member_host ||= CodexMemberHost.new(project_root: @state.fetch("project_root"))
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

    # Jev hints are bounded to one per task, only when an allowed and
    # actually callable member exists, and they are delivered only after the
    # same freshness re-check used for check decisions. They never dispatch
    # and never choose a kind; the Root decides.
    def prepare_hint(scores, now)
      return if @state["delegation_hint"]
      return unless scores.fetch("delegatable", 0) >= DELEGATION_HINT_THRESHOLD

      options = delegation_options
      return if options["callable_kinds"].empty?

      @pending_hint = {
        "score" => scores.fetch("delegatable"), "callable_kinds" => options["callable_kinds"],
        "at" => Time.at(now).utc.iso8601
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

      text = "Orbit delegation hint (not a new user instruction): Jev estimates this task may contain a bounded " \
             "subtask suitable for an execution member (score #{hint['score']}). Callable kinds here: " \
             "#{hint['callable_kinds'].join('、')}. You decide the subtask and whether to delegate; Orbit does not dispatch."
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      @state["delegation_hint"] = hint.merge("message_id" => sent.fetch("id"))
      @record.event("delegation_hint", "score" => hint["score"], "callable_kinds" => hint["callable_kinds"])
      save
    rescue StandardError => error
      # A hint is advisory: delivery failure must not fail the task or
      # interrupt any check decision.
      @record.event("delegation_hint_failed", "error" => error.message)
      save
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

    def start_check(host, now, kind: "artifact")
      number = @state.fetch("checks").length + 1
      directory = File.join(@record.path, "checks", number.to_s)
      snapshot = WorkspaceSnapshot.capture(
        project_root: @state.fetch("project_root"), destination: File.join(directory, "workspace")
      )
      role = @state["dispute"] ? "adjudicator" : kind == "process" ? "process_reviewer" : "reviewer"
      clues = role == "reviewer" ? @state["recheck"] : nil
      scope = {
        "number" => number, "role" => role, "kind" => kind, "snapshot" => snapshot,
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
          "uncopied_entries" => snapshot.fetch("manifest").select do |entry|
            %w[gitlink other].include?(entry["kind"]) || entry["materialized"] == false
          end
        }, output_dir: directory, role: role
      )
      @running_check = scope
      @last_full_check_digest = snapshot.fetch("digest") if kind == "artifact"
      @state.delete("observation_pending")
      @record.event("check_started", "number" => number, "role" => role, "digest" => snapshot.fetch("digest"))
      save
    end

    def host_digest(host)
      Digest::SHA256.hexdigest(JSON.generate(host.slice("last_turn_id", "last_turn_status", "observations")))
    end

    def finish_check(result, host, now)
      scope = @running_check
      current_digest = WorkspaceSnapshot.fingerprint(project_root: @state.fetch("project_root"))
      @running_check = nil
      @check_result = nil
      stale_reasons = []
      stale_reasons << "artifact" if current_digest != scope.dig("snapshot", "digest")
      stale_reasons << "input" if @record.input_digest(@state) != scope["input_digest"]
      stale_reasons << "host" if host_digest(host) != scope["host_digest"]
      stale_reasons << "dispute" if @state["dispute"] != scope["dispute"]
      stale = !stale_reasons.empty?
      @state["checks"] << scope.slice("number", "role", "kind", "started_at").merge(
        "result" => result, "stale" => stale, "stale_reasons" => stale_reasons,
        "finished_at" => Time.at(now).utc.iso8601,
        "usage" => @checker.respond_to?(:usage) ? @checker.usage : nil
      )
      @record.event("check_finished", "number" => scope["number"], "stale" => stale,
                    "stale_reasons" => stale_reasons, "verdict" => result.fetch("verdict"))
      if scope["kind"] == "artifact"
        if host["status"] == "idle"
          schedule_check(now + result.fetch("next_check_seconds"), "检查者建议的下次观察")
        else
          # A checker-suggested short restart plus continuous editing produced
          # repeated stale full checks. The agreed interval is the floor while
          # Root is executing; idle delivery still gets a fresh check.
          schedule_check(now + [result.fetch("next_check_seconds"), @interval].max,
                         "Root 执行中，完整检查间隔以约定时间为下限")
        end
      end
      if stale
        # A moving workspace cannot be approved or interrupted using an old
        # finding. Keep actionable stale findings as reconciliation clues; the
        # next applicable check re-verifies them and corrections then reach
        # Root without Root polling the task record.
        if scope["role"] != "adjudicator" && %w[correct continue].include?(result.fetch("verdict")) &&
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
        schedule_check(now, "过期结论待新版本核对") if host["status"] == "idle" || @state["dispute"]
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
        finding["resolution_version"] = current_digest
        finding["resolution_input"] = scope["input_digest"]
      end
      result.fetch("findings").each do |finding|
        previous = @state["findings"][finding.fetch("id")]
        if previous && previous["status"] == "resolved" && previous["resolution_version"] == current_digest &&
           previous["resolution_input"] == scope["input_digest"] && previous["evidence"] == finding["evidence"]
          @record.event("finding_reopen_ignored", "id" => finding.fetch("id"), "reason" => "No changed artifact, input, or evidence")
          next
        end
        @state["findings"][finding.fetch("id")] = finding.merge("status" => "open", "check" => scope["number"])
      end
      if scope["role"] == "adjudicator"
        @state["decisions"] << { "dispute" => @state.delete("dispute"), "check" => scope["number"], "result" => result }
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
          final_digest = WorkspaceSnapshot.fingerprint(project_root: @state.fetch("project_root"))
          if final_digest == current_digest && @record.input_digest(@state) == scope["input_digest"] &&
             host_digest(final_host) == scope["host_digest"]
            @state["status"] = "complete"
            @state["delivery_digest"] = current_digest
          else
            schedule_check(now, "完成核对前版本变化，立即重新核对")
          end
        else
          @state["observation_pending"] = {
            "reason" => "Completion needs an idle Root, settled execution members, " \
                        "all delivery findings resolved and pending clues reconciled"
          }
        end
      when "correct"
        send_correction(result)
      when "pause"
        stop(result.fetch("reason"))
      when "needs_user"
        stop(result.fetch("reason"), status: "needs_user")
      when "continue"
        send_correction(result) if host["status"] == "idle" && !result.fetch("findings").empty?
      end
      save
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
