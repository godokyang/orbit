# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "shellwords"
require_relative "task_record"
require_relative "workspace_snapshot"
require_relative "codex_connection"

module Orbit
  class TaskRuntime
    TERMINAL = %w[complete paused needs_user failed stop_unconfirmed].freeze

    def initialize(record:, connection:, checker:)
      @record, @connection, @checker = record, connection, checker
      @state = record.state
      @state["findings"] ||= {}
      @state["sent_message_ids"] ||= []
      @state["members"] ||= []
      @member_connections = {}
      @state["last_user_message_id"] ||= @state.dig("instruction_source", "id")
      @interval = @state.fetch("review").fetch("interval_seconds", 300)
      @next_check = Time.now.to_f + @interval
      @running_check = nil
      @last_delivery_checked = nil
      @first_change_checked = false
      @stop_requested = false
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
          rescue CodexConnection::Error
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

      consume_commands
      return if TERMINAL.include?(@state["status"])

      host = @connection.state
      if host["status"] == "idle" && host["last_turn_status"] == "interrupted"
        stop("The user interrupted the Root turn")
        return
      end
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
      changed = !@first_change_checked && WorkspaceSnapshot.fingerprint(
        project_root: @state.fetch("project_root")
      ) != @initial_digest
      return unless now >= @next_check || changed || (delivery && host["last_turn_id"] != @last_delivery_checked)

      start_check(host, now)
      @first_change_checked = true
      @last_delivery_checked = host["last_turn_id"] if delivery
    rescue WorkspaceSnapshot::UnstableError => error
      @state["observation_pending"] = { "reason" => error.message, "paths" => error.paths }
      save
    end

    private

    def save
      @state["next_check_at"] = Time.at(@next_check).utc.iso8601
      @record.save(@state)
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
          delegate(command)
        when "check"
          @next_check = 0
        when "dispute"
          @state["dispute"] = command.fetch("reason")
          @next_check = 0
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
      @next_check = 0
    end

    def delegate(command)
      instructions = "You are an execution member for an Orbit task. Work only on the delegated scope in this project. " \
                     "Follow project rules. Do not start Orbit, create other agents, commit, or push. " \
                     "Report concrete results and verification to the Root. Stop your background commands before finishing.\n\n" \
                     "Original task inputs:\n#{JSON.pretty_generate(@record.inputs(@state))}\n\n" \
                     "Delegated scope:\n#{command.fetch('text')}"
      if command["member"]
        member = @state["members"].find { |entry| entry["thread_id"] == command["member"] }
        raise ArgumentError, "member is not owned by this task" unless member
        member["status"] = "working"
        save
        member_connection(member).send_message(instructions)
      else
        model = command["model"] || @state.dig("review", "model")
        id = @connection.create_member(model: model)
        member = { "thread_id" => id, "model" => model, "status" => "starting" }
        @state["members"] << member
        # Persist ownership before this member can start any model/tool work.
        save
        @connection.start_member(id, instructions)
        member["status"] = "working"
      end
      @record.event("member_delegated", "thread_id" => member["thread_id"], "scope" => command.fetch("text"))
      save
    end

    def member_connection(member)
      id = member.fetch("thread_id")
      @member_connections[id] ||= @connection.member_connection(id)
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
        unless @state["sent_message_ids"].include?(message.fetch("id"))
          add_amendment(message.fetch("text"), { "kind" => "codex_user_message", "id" => message.fetch("id") })
        end
        @state["last_user_message_id"] = message.fetch("id")
      end
      save
      true
    end

    def start_check(host, now)
      number = @state.fetch("checks").length + 1
      directory = File.join(@record.path, "checks", number.to_s)
      snapshot = WorkspaceSnapshot.capture(
        project_root: @state.fetch("project_root"), destination: File.join(directory, "workspace")
      )
      role = @state["dispute"] ? "adjudicator" : "reviewer"
      scope = {
        "number" => number, "role" => role, "snapshot" => snapshot,
        "input_digest" => @record.input_digest(@state), "host_digest" => host_digest(host),
        "dispute" => @state["dispute"],
        "started_at" => Time.at(now).utc.iso8601
      }
      @record.write("checks/#{number}/scope.json", JSON.pretty_generate(scope))
      @checker.start(
        directory: snapshot.fetch("snapshot_path"), inputs: @record.inputs(@state),
        context: {
          "root" => host, "findings" => @state.fetch("findings"),
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
      stale = current_digest != scope.dig("snapshot", "digest") ||
              @record.input_digest(@state) != scope["input_digest"] || host_digest(host) != scope["host_digest"] ||
              @state["dispute"] != scope["dispute"]
      @state["checks"] << scope.slice("number", "role", "started_at").merge(
        "result" => result, "stale" => stale, "finished_at" => Time.at(now).utc.iso8601,
        "usage" => @checker.respond_to?(:usage) ? @checker.usage : nil
      )
      @record.event("check_finished", "number" => scope["number"], "stale" => stale, "verdict" => result.fetch("verdict"))
      @next_check = now + result.fetch("next_check_seconds")
      if stale
        # A moving workspace cannot be approved or interrupted using an old
        # finding. Observe its next agreed version; an idle delivery gets a
        # prompt fresh check without asking Root to request one.
        @next_check = now if host["status"] == "idle" || @state["dispute"]
        save
        return
      end

      result.fetch("resolved_ids").each do |id|
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
        if host["status"] == "idle" && host["last_turn_status"] == "completed" &&
           members_settled? &&
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
            @next_check = now
          end
        else
          @state["observation_pending"] = { "reason" => "Completion needs an idle Root, settled execution members and all delivery findings resolved" }
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
      @state["member_stop_results"] = members
      raise ArgumentError, failures.join("; ") unless failures.empty?
      confirmation["members"] = members unless members.empty?
      confirmation
    end
  end
end
