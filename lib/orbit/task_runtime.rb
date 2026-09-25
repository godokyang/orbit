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
    # Cost joins the second stage only behind the fail-closed route/price gate.
    # 0.50 is the minimal agreed threshold (no calibration evidence yet); the
    # hard requirement is that an unknown route or price can never hint.
    COST_APPROPRIATE_THRESHOLD = 0.50
    REVIEW_FOCUS_STATUSES = %w[added modified deleted].freeze
    REVIEW_FOCUS_LIMIT = 200
    # A queued completion stop waits for the Root's delivery turn to finish;
    # beyond this cap it stops immediately rather than waiting forever.
    COMPLETION_STOP_TIMEOUT_SECONDS = 600
    # A version-bound pending finalization notice waits for the Root turn when
    # that happens sooner, but must still be delivered within this bound even
    # if Root stays active/waiting (see contracts/task-runtime.md).
    FINALIZATION_NOTICE_MAX_WAIT_SECONDS = 60
    OMP_NATIVE_ADAPTER = "omp_native_task"

    def initialize(record:, connection:, checker:, advisor: nil, evidence_cache: nil)
      @record, @connection, @checker = record, connection, checker
      @advisor = advisor
      @evidence_cache = evidence_cache
      @state = record.state
      @state["findings"] ||= {}
      @state["sent_message_ids"] ||= []
      @state["delegation_hints"] ||= {}
      @state["delegation_assessments"] ||= {}
      @state["evidence_requests"] ||= {}
      @state["evidence_gaps"] ||= {}
      @state["members"] ||= []
      @state["unknown_candidates"] ||= {}
      @state["check_observations"] ||= {}
      @state["finalization_notices"] ||= {}
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
        end
      end
      @state
    end

    # A single event-loop step is also the deterministic test seam. Host and
    # checker doubles cannot turn these tests into real-model acceptance.
    def tick(now: Time.now.to_f)
      return if TERMINAL.include?(@state["status"])
      reconcile_registered_members!
      reject_legacy_members!
      return if TERMINAL.include?(@state["status"])
      if @stop_requested
        stop("Runtime received an explicit stop request")
        return
      end
      deadline = @state["hard_deadline"]
      if deadline && now >= Time.parse(deadline).to_f
        # An explicit user hard deadline always wins over a queued completion
        # wait: it stops immediately and never records completion.
        @state.delete("completion_stop_pending")
        stop("The user's explicit hard deadline was reached")
        return
      end
      if (pending = @state["completion_stop_pending"])
        host = begin
          @connection.state
        rescue Connection::Error
          nil
        end
        idle_done = host && host["status"] == "idle" && host["last_turn_status"] == "completed"
        interrupted = host && (host["interrupted"] ||
                     (host["status"] == "idle" && host["last_turn_status"] == "interrupted"))
        expired = now - Time.parse(pending.fetch("at")).to_f > COMPLETION_STOP_TIMEOUT_SECONDS
        @state.delete("completion_stop_pending")
        if idle_done
          stop(pending.fetch("reason"), allow_complete: true)
        elsif interrupted || expired
          # The delivery turn aborted or the wait outlived its bound: this is
          # an ordinary stop now, never a completion.
          stop(pending.fetch("reason"))
        else
          @state["completion_stop_pending"] = pending
          save # hold other observation until the delivery turn finishes
        end
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
      consume_hub_events
      retry_native_amendments
      return if TERMINAL.include?(@state["status"])
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
      if deliver_pending_finalization(host, now)
        @last_delivery_checked = host["last_turn_id"]
        save
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
      if delivery && (pending = @state["pending_correction"])
        # A correction whose first delivery failed is retried exactly when the
        # Root is observed idle again — but only while it still describes the
        # current version; otherwise it is dropped and the next normal check
        # speaks for the new version.
        stale = pending["artifact_digest"] &&
                (pending["artifact_root"] != artifact_root ||
                 pending["artifact_digest"] != fingerprint_artifact ||
                 pending["input_digest"] != @record.input_digest(@state))
        if stale
          @state.delete("pending_correction")
          @record.event("correction_redelivery_stale", "check" => pending["check"])
          save
        else
          deliver_correction_text(pending.fetch("text"), pending)
        end
      end
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
      # Root's OMP session cwd does not move with the artifact root: say so
      # explicitly (never as a new user instruction). A failed notice must not
      # lose the persisted rebind or fail the task.
      cwd = begin
        @connection.state.fetch("cwd", nil)
      rescue Connection::Error
        nil
      end
      notice = "Orbit workspace notice (not a new user instruction): the artifact root moved to #{entry['to']}. " \
               "Your OMP session cwd has not moved#{cwd ? " (still #{cwd})" : ''}; " \
               "all further task artifacts must be written under the new root."
      begin
        sent = @connection.send_message(notice)
        @state["sent_message_ids"] << sent.fetch("id")
      rescue Connection::Error => error
        @record.event("workspace_rebind_notice_failed", "error" => error.message)
      end
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
        # Payload validation happens before dispatch so a malformed but typed
        # command is rejected explicitly; internal KeyErrors from the handlers
        # stay visible instead of being relabeled as command errors.
        required = case command["type"]
                   when "amend" then %w[text source]
                   when "rebind_workspace" then %w[path]
                   when "dispute" then %w[reason]
                   else []
                   end
        missing = required.reject { |key| command.key?(key) && !command[key].nil? }
        unless missing.empty?
          @record.event("command_rejected", "command_type" => command["type"],
                        "reason" => "Command is missing required fields: #{missing.join(', ')}")
          next
        end
        case command["type"]
        when "stop"
          reason = command.fetch("reason", "User requested stop")
          if command["complete"] == true && completion_notice_current?
            # Deferred completion: aborting the Root turn now could cut the
            # user's final summary. Queue the stop; the tick performs it once
            # the current turn completed normally (bounded wait below),
            # re-verifying the hand-off version at that point. Plain stops
            # without the explicit completion intent take the ordinary path.
            @state["completion_stop_pending"] = { "reason" => reason, "at" => Time.now.utc.iso8601 }
            @record.event("completion_stop_queued", "reason" => reason)
          else
            stop(reason)
          end
        when "amend"
          add_amendment(command.fetch("text"), command.fetch("source"))
          sent = @connection.send_message("Orbit: the user explicitly amended this task:\n\n" + command.fetch("text"))
          @state["sent_message_ids"] << sent.fetch("id")
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
        next unless %w[working registered].include?(member["status"])
        deliver_native_amendment(member, text, source) if member["adapter"] == OMP_NATIVE_ADAPTER
      end
      schedule_check(0, "用户修改后重新核对", trigger: "amendment")
    end

    def omp_task?
      @state.dig("connection", "provider") == "omp"
    end

    # Rediscover native task ids from the registration gate's members.json.
    # This does not call the member bridge. A corrupt list is not treated as empty.
    def reconcile_registered_members!
      return unless omp_task?

      listed = @record.members
      validate_member_roster!(listed)
      @state["members"] ||= []
      changed = false
      listed.each do |entry|
        id = entry.fetch("thread_id")
        next if @state["members"].any? { |member| member["thread_id"] == id }

        member = {
          "kind" => "omp", "adapter" => OMP_NATIVE_ADAPTER, "thread_id" => id,
          "requested_name" => entry["requested_name"], "status" => entry.fetch("status"),
          "registered_at" => entry["registered_at"]
        }
        member["model"] = entry["model"] if entry["model"]
        member["tool_call_id"] = entry["tool_call_id"] if entry["tool_call_id"]
        member["reason"] = entry["reason"] if entry["reason"]
        if member["status"] == "registered"
          member["delegation_basis"] = delegation_basis
          mark_delegation_hint_followed(member) if member["delegation_basis"] == "orbit_hint"
        end
        @state["members"] << member
        @record.event("native_member_reconciled", "thread_id" => id, "status" => member["status"],
                      "basis" => member["delegation_basis"])
        changed = true
      end
      save if changed
    end

    def deliver_native_amendment(member, text, source)
      item = enqueue_native_amendment(member, text, source, nil)
      send_queued_amendment(member, item)
    end

    def enqueue_native_amendment(member, text, source, error)
      source_id = source.is_a?(Hash) ? source["id"].to_s : ""
      source_id = "amendment-#{@state.fetch('amendments').length}" if source_id.empty?
      queue = (@state["amendment_delivery_queue"] ||= [])
      item = queue.find { |entry| entry["thread_id"] == member["thread_id"] && entry["source_id"] == source_id }
      unless item
        item = { "thread_id" => member["thread_id"], "source_id" => source_id, "text" => text, "attempts" => 0 }
        queue << item
      end
      item["text"] = text
      item["error"] = error if error
      item
    end

    def retry_native_amendments
      queue = @state["amendment_delivery_queue"]
      return unless queue.is_a?(Array) && queue.any?

      queue.dup.each do |item|
        return if TERMINAL.include?(@state["status"])
        member = @state["members"].find { |entry| entry["thread_id"] == item["thread_id"] }
        unless member && %w[registered working starting].include?(member["status"])
          stop("member #{item['thread_id']} ended before receiving amendment #{item['source_id']}", status: "needs_user")
          return
        end
        send_queued_amendment(member, item)
      end
    end

    def send_queued_amendment(member, item)
      unless @connection.respond_to?(:send_member)
        record_native_amendment_failure(member, item, "send_member unreachable")
        return
      end
      @connection.send_member(member["thread_id"], "The user amended the original task. Apply only changes relevant to your delegated scope:\n\n#{item['text']}")
      (@state["amendment_delivery_queue"] || []).delete(item)
      member["amendment_delivery"] = "sent"
      member.delete("amendment_error")
      clear_amendment_error(item)
      @record.event("member_amendment_sent", "thread_id" => member["thread_id"], "source_id" => item["source_id"])
      save
    rescue StandardError => error
      record_native_amendment_failure(member, item, error.message)
    end

    def amendment_error_text(item, error)
      "member #{item['thread_id']} did not receive the amendment #{item['source_id']}: #{error}"
    end

    def clear_amendment_error(item)
      text = @state["error"].to_s
      return unless text.include?(item["thread_id"].to_s) && text.include?("did not receive the amendment #{item['source_id']}")

      remaining = Array(@state["amendment_delivery_queue"])
      if remaining.empty?
        @state.delete("error")
      else
        other = remaining.last
        @state["error"] = amendment_error_text(other, other["error"])
      end
    end

    def record_native_amendment_failure(member, item, error)
      changed = item["error"] != error || member["amendment_delivery"] != "pending"
      item["error"] = error
      member["amendment_delivery"] = "pending"
      member["amendment_error"] = error
      @state["error"] = amendment_error_text(item, error)
      save
      return unless changed

      @record.event("member_amendment_failed", "thread_id" => member["thread_id"], "source_id" => item["source_id"], "error" => error)
      return unless @connection.respond_to?(:send_message)

      begin
        @connection.send_message("Orbit could not deliver the user amendment to member #{member['thread_id']}: #{error}")
      rescue StandardError => notify_error
        @record.event("member_amendment_notify_failed", "thread_id" => member["thread_id"], "source_id" => item["source_id"], "error" => notify_error.message)
      end
    end

    def stop_omp_native_member(member, failures)
      id = member["thread_id"]
      unless @connection.respond_to?(:stop_member)
        failures << "Member #{id}: native member stop bridge is unreachable"
        return { "thread_id" => id, "error" => "native member stop bridge is unreachable", "registration_status" => member["status"] }
      end
      begin
        result = @connection.stop_member(id)
      rescue StandardError => error
        failures << "Member #{id}: #{error.message}"
        return { "thread_id" => id, "error" => error.message, "registration_status" => member["status"] }
      end
      confirmed = result.is_a?(Hash) && result["confirmed"] == true && result["active_tools_after"] == 0 && result["async_jobs_settled"] == true
      unless confirmed
        failures << "Member #{id}: stop_member did not confirm idle tools and reaped background work"
        return { "thread_id" => id, "error" => "stop_member unconfirmed", "confirmation" => result, "registration_status" => member["status"] }
      end
      member["stop_confirmation"] = result
      { "thread_id" => id, "confirmation" => result }
    end

    def delegation_options
      { "allowed_kinds" => ["omp"], "callable_kinds" => ["omp"],
        "hint_sent" => !@state["delegation_hint"].nil? }
    end

    # First stage (JEV delegation plan): the structural `delegatable` score
    # only decides whether the comparison needs model evidence. It never
    # prepares a hint; a hint requires cached `evidence` for every compared
    # identity plus the second-stage judgment.
    def stage_delegation(scores, artifact_digest, now)
      return unless scores.fetch("delegatable", 0) >= DELEGATION_HINT_THRESHOLD
      return if @state["members"].any? { |member| member_blocks_new_hint?(member) }

      options = delegation_options
      return if options["callable_kinds"].empty?

      signature = delegation_signature(artifact_digest, options)
      return if @state.dig("delegation_hints", signature)
      if (assessment = @state.dig("delegation_assessments", signature))
        scores = assessment["scores"]
        # Recover only with fresh evidence: the lookup filters expired entries
        # and route mismatches, so a stale, route-less or fact-less cache
        # cannot resurrect a recommended assessment.
        identities = evidence_identities(delegation_options)
        entries = identities && evidence_states(identities)
        if scores.is_a?(Hash) && scores.fetch("member_fit", 0) >= MEMBER_FIT_THRESHOLD &&
           scores.fetch("parallel_gain", 0) >= PARALLEL_GAIN_THRESHOLD &&
           scores.fetch("cost_appropriate", 0) >= COST_APPROPRIATE_THRESHOLD &&
           entries && evidence_complete?(entries) && cost_route_verified?(entries)
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
        unless cost_route_verified?(entries)
          record_cost_route_gap(signature, entries)
          return
        end
        run_delegation_assessment(identities, entries, signature, artifact_digest, now)
      else
        record_evidence_unavailable(signature, now)
      end
    end

    # Input, artifact, candidate identity/route or candidate changes create a
    # new signature and allow a new hint; transient host noise does not. The
    # resolved @task model and billing route are part of the signature so a
    # changed role, model or route cannot reuse an old assessment or hint.
    def delegation_signature(artifact_digest, options)
      Digest::SHA256.hexdigest(JSON.generate([
        @record.input_digest(@state), artifact_digest,
        @state["members"].map { |member| member.slice("thread_id", "status") },
        options["callable_kinds"],
        { "model" => native_member_model, "billing_route" => native_member_route }
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
          # default, which is the OMP `@task` role resolution, not the Root
          # session model. The kind stays on the identity for the Root message;
          # the cache API only receives provider, model and reasoning.
          identity = split_model_identity(native_member_model, provider)
          return nil unless identity_usable?(identity)

          candidates << identity.merge("kind" => kind, "billing_route" => native_member_route)
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

    # Sanitized typed billing route resolved by the host for the native task
    # model. An older host without the field, an unexpected value or a host
    # error all stay `unknown`; the cost gate then fails closed.
    def native_member_route
      return "unknown" unless @connection.respond_to?(:default_member_route)

      route = @connection.default_member_route.to_s.strip
      ModelEvidenceCache::BILLING_ROUTES.include?(route) ? route : "unknown"
    rescue StandardError => error
      @native_route_error = "#{error.class}: #{error.message}"
      "unknown"
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

      evidence_cache.identity(provider: identity["provider"], model: identity["model"], reasoning: identity["reasoning"],
                              billing_route: identity["billing_route"])
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

    # A cost judgment needs the host to have resolved the candidate to a
    # verified route AND the stored candidate entry to carry the same typed
    # route plus that route's numeric fact namespace: `cost.*` on direct_api,
    # `quota.*` on subscription_quota. Other routes, route mismatches,
    # route-less (older) entries and entries without the required namespace
    # all stay fail-closed: no second stage and no hint.
    def cost_route_verified?(states)
      route = native_member_route
      prefix = ModelEvidenceCache.route_metric_prefix(route)
      return false unless prefix

      states.fetch("candidates").all? do |entry|
        entry["status"] == "evidence" && entry["billing_route"] == route &&
          ModelEvidenceCache.numeric_metric?(entry, prefix)
      end
    end

    def lookup_evidence(identity)
      evidence_cache.lookup(provider: identity["provider"], model: identity["model"], reasoning: identity["reasoning"],
                            billing_route: identity["billing_route"])
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

        identity = evidence_cache.identity(provider: entry["provider"], model: entry["model"],
                                            reasoning: entry["reasoning"], billing_route: entry["billing_route"])
        status = entry["status"].to_s
        next nil unless ModelEvidenceCache::STATUSES.include?(status)

        identity.merge("status" => status)
      rescue ModelEvidenceCache::Error
        nil
      end
    end

    def evidence_identity_key(identity)
      normalized = evidence_cache.identity(
        provider: identity["provider"], model: identity["model"],
        reasoning: identity["reasoning"], billing_route: identity["billing_route"]
      )
      normalized.values_at("provider", "model", "reasoning", "billing_route")
    end

    # A mismatch stays fail-closed: the note only tells the submitter which
    # candidate route the pending request expects and what was submitted. It
    # never relaxes identity matching and never sends an unsolicited message.
    def evidence_mismatch_note(identities, submitted_keys)
      details = identities.fetch("candidates").map do |identity|
        expected = ModelEvidenceCache.billing_route(identity["billing_route"])
        actual = submitted_keys.find do |key|
          key[0] == identity["provider"] && key[1] == identity["model"] && key[2] == identity["reasoning"]
        end
        "#{identity['provider']}/#{identity['model']} billing_route must be #{expected}, " \
          "submitted #{actual ? actual[3] : 'missing'}"
      end
      "evidence identities did not match the pending request; #{details.join('; ')}. " \
        "Resubmit with the route shown in the Orbit request (omitted counts as unknown)."
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
        submitted_keys = Array(submitted).map { |entry| evidence_identity_key(entry) }
        expected_keys = requested_evidence_keys(identities)
        request["resolved"] = "mismatch"
        @state["jev"] = (@state["jev"] || {}).merge(
          "evidence_status" => "mismatch",
          "evidence_note" => evidence_mismatch_note(identities, submitted_keys)
        )
        @record.event("model_evidence_mismatch", "expected" => expected_keys, "submitted" => submitted_keys)
        save
        return
      end

      # The pending request may predate a @task change. Re-resolve now: a
      # changed candidate identity, model or billing route makes the pending
      # evidence stale for this assessment. Cache entries stay reusable under
      # their own identity/route, and the next stage-one signature requests
      # current evidence.
      current = evidence_identities(delegation_options)
      if current.nil? || requested_evidence_keys(current) != requested_evidence_keys(identities)
        request["resolved"] = "stale"
        @state["jev"] = (@state["jev"] || {}).merge(
          "evidence_status" => "unknown",
          "evidence_note" => "the resolved candidate identity or billing route changed while evidence was pending"
        )
        @record.event("model_evidence_stale",
                      "requested" => requested_evidence_keys(identities),
                      "current" => current ? requested_evidence_keys(current) : nil)
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
      save
      artifact_digest = probe_artifact(now)
      signature = delegation_signature(artifact_digest, delegation_options)
      unless cost_route_verified?(states)
        request["resolved"] = "cost_unverified"
        save
        record_cost_route_gap(signature, states)
        return
      end
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
      persist_delegation_evidence!(observation.fetch("model_evidence"), signature)
      result = @advisor.assess_delegation(state: observation)
      scores = result.fetch("scores")
      decision = if scores.fetch("member_fit", 0) >= MEMBER_FIT_THRESHOLD &&
                    scores.fetch("parallel_gain", 0) >= PARALLEL_GAIN_THRESHOLD &&
                    scores.fetch("cost_appropriate", 0) >= COST_APPROPRIATE_THRESHOLD
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
    # Persist the exact summary embedded in the completed observation before
    # JEV is called. A write failure raises and must not be turned into a
    # second-stage attempt.
    def persist_delegation_evidence!(summary, signature)
      unless @state.dig("delegation_evidence", signature)
        @record.event("model_evidence_used", "signature" => signature, "summary" => summary)
        traced = { "signature" => signature, "summary" => summary, "at" => Time.now.utc.iso8601 }
        (@state["delegation_evidence"] ||= {})[signature] = traced
        @state["jev"] = (@state["jev"] || {}).merge("evidence_status" => "used", "evidence" => traced)
      end
      save
    end

    def delegation_evidence_summary(identities, entries)
      entry_summary = lambda do |identity, entry|
        metrics = entry["metrics"]
        if metrics.is_a?(Hash)
          # Legacy cache entries may still carry cross-identity comparison
          # claims written before submission rejected them; never feed those
          # into the second-stage judgment.
          metrics = metrics.reject { |name, _| ModelEvidenceCache.comparison_metric?(name) }
        end
        {
          "provider" => identity["provider"], "model" => identity["model"], "reasoning" => identity["reasoning"],
          "billing_route" => identity["billing_route"] || "unknown",
          "status" => entry["status"], "retrieved_at" => entry["retrieved_at"], "valid_until" => entry["valid_until"],
          "sources" => Array(entry["sources"]), "metrics" => metrics
        }
      end
      {
        "root" => entry_summary.call(identities.fetch("root"), entries.fetch("root")),
        "candidates" => identities.fetch("candidates").each_with_index.map do |identity, index|
          entry_summary.call(identity, entries.fetch("candidates").fetch(index))
        end,
        "note" => "Structure-validated cache entries only; metric values, units and basis are submitter-provided " \
                  "and not semantically verified; cross-identity comparison metrics are omitted."
      }
    end

    # The automatic chain stops when an identity cannot be established.
    # Orbit does not guess or probe hosts.
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

    # The evidence set is complete, but it cannot authorize a cost judgment.
    # This is terminal for the signature: no stage two and no hint. Structured
    # per-candidate facts keep the reason auditable, including which numeric
    # fact namespace the resolved route required.
    def record_cost_route_gap(signature, states)
      return if @state.dig("evidence_gaps", signature)

      expected = ModelEvidenceCache.route_metric_prefix(native_member_route)
      candidates = states.fetch("candidates").map do |entry|
        {
          "provider" => entry["provider"], "model" => entry["model"],
          "billing_route" => entry["billing_route"] || "unknown",
          "fact_present" => expected ? ModelEvidenceCache.numeric_metric?(entry, expected) : false
        }
      end
      @state["evidence_gaps"][signature] = {
        "reason" => "cost route or required fact is not verified for every compared candidate",
        "host_billing_route" => native_member_route,
        "expected_metric" => expected || "none",
        "candidates" => candidates, "at" => Time.now.utc.iso8601
      }
      @state["jev"] = (@state["jev"] || {}).merge(
        "evidence_status" => "incomplete",
        "evidence_note" => "cost route or required fact is not verified; no automatic delegation hint"
      )
      @record.event("delegation_cost_unverified", "signature" => signature,
                    "host_billing_route" => native_member_route, "expected_metric" => expected || "none",
                    "candidates" => candidates)
      save
    end

    # Bounded, non-secret view of the pending Orbit evidence request for the
    # independent checkers: which model facts Orbit asked Root to research and
    # how far that request got. It never includes submitted pages, URLs or
    # credentials.
    def pending_evidence_request_context
      request = @state["evidence_request"]
      return nil unless request.is_a?(Hash)

      {
        "identities" => request["identities"],
        "needed" => request["needed"],
        "at" => request["at"],
        "resolved" => request["resolved"]
      }
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
      text << "For cost, include the typed billing_route from the resolved model endpoint (direct_api, subscription_quota or unknown) and that route's numeric facts: cost.* per-token prices for a verified direct_api route, quota.* plan/quota band facts for a verified subscription_quota route. The namespaces never substitute for each other, and a route-less entry cannot authorize a cost judgment.\n"
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

      text = "#{identity['provider']}/#{identity['model']} (reasoning: #{identity['reasoning']})"
      route = identity["billing_route"].to_s
      route.empty? ? text : "#{text} [billing_route: #{route}]"
    end

    def prepare_delegation_hint(scores, signature, now)
      return if @state.dig("delegation_hints", signature)

      options = delegation_options
      return if options["callable_kinds"].empty?

      @pending_hint = {
        "signature" => signature, "score" => @state.dig("jev", "scores", "delegatable"),
        "member_fit" => scores.fetch("member_fit"), "parallel_gain" => scores.fetch("parallel_gain"),
        "cost_appropriate" => scores.fetch("cost_appropriate"),
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
      return if @state["members"].any? { |member| member_blocks_new_hint?(member) }
      return if @state.dig("delegation_hints", hint.fetch("signature"))

      text = delegation_hint_text(hint)
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      @state["delegation_hints"][hint.fetch("signature")] = hint.merge("message_id" => sent.fetch("id"))
      @state["delegation_hint"] = hint.merge("message_id" => sent.fetch("id"))
      @record.event("delegation_hint", "score" => hint["score"], "member_fit" => hint["member_fit"],
                    "parallel_gain" => hint["parallel_gain"], "cost_appropriate" => hint["cost_appropriate"],
                    "callable_kinds" => hint["callable_kinds"])
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
    def delegation_hint_text(hint)
      kinds = Array(hint["callable_kinds"]).join("、")
      score = "Orbit delegation hint (not a new user instruction): Jev judged that a bounded subtask could be delegated now " \
              "(delegatable #{hint['score']}, member_fit #{hint['member_fit']}, parallel_gain #{hint['parallel_gain']}, " \
              "cost_appropriate #{hint['cost_appropriate']}; callable kinds: #{kinds}). "
      score + "Dispatch one layer with native task; the registration gate records the actual id."
    end

    def delegation_basis
      hint = @state["delegation_hint"]
      return "root_without_hint" unless hint.is_a?(Hash) && !hint.empty? && hint["followed"] != true

      signature = delegation_signature(fingerprint_artifact, delegation_options)
      hint["signature"] == signature ? "orbit_hint" : "root_without_hint"
    rescue WorkspaceSnapshot::Error
      "root_without_hint"
    end

    def mark_delegation_hint_followed(member)
      hint = @state["delegation_hint"]
      return unless hint && !hint["followed"]

      hint["followed"] = true
      hint["followed_kind"] = member["kind"]
      @record.event("delegation_hint_followed", "kind" => member["kind"], "thread_id" => member["thread_id"])
    end

    # OMP 18.2.8 AgentRegistry.register defaults to running. idle is also the
    # live-but-not-running state, so idle alone is not a finished task.
    # markResultAccepted stamps lifecycle.acceptedAt; history.outputPath is the
    # durable artifact. parked can be a later release of a finished ref.
    def observe_omp_native_member(member)
      return unless @connection.respond_to?(:member_state) && @connection.respond_to?(:member_result)
      return if member["status"] == "refused"

      observed = @connection.member_state(member["thread_id"])
      if observed.is_a?(Hash) && observed["model"].is_a?(String) && !observed["model"].empty?
        member["model"] = observed["model"]
      end
      registry_status = observed.is_a?(Hash) ? observed["registry_status"] : nil
      result = @connection.member_result(member["thread_id"])
      save if apply_native_member_observation!(member, registry_status, result, observed)
    rescue StandardError => error
      member["bridge_error"] = error.message
      @record.event("native_member_bridge_failed", "thread_id" => member["thread_id"], "error" => error.message)
      save
    end

    def apply_native_member_observation!(member, registry_status, result, observed = nil)
      previous = member.slice("model", "result", "output_path", "registry_status", "accepted_at", "status", "result_delivery")
      previous_status = member["status"]
      previous_accepted = member["accepted_at"]
      member["registry_status"] = registry_status if registry_status.is_a?(String) && !registry_status.empty?
      accepted_at = native_accepted_at(observed) || native_accepted_at(result)
      member["accepted_at"] = accepted_at if accepted_at
      if result.is_a?(Hash)
        if result["output_text"].is_a?(String) && !result["output_text"].empty?
          member["result"] = result["output_text"]
        end
        copy_output_path(member, result["output_path"])
      end
      copy_output_path(member, observed["output_path"]) if observed.is_a?(Hash)
      if member["registry_status"] == "aborted"
        member["status"] = "failed"
      elsif native_result_accepted?(member, observed)
        member["status"] = "completed"
      end
      accepted_changed = member["accepted_at"] != previous_accepted
      became_completed = member["status"] == "completed" && previous_status != "completed"
      if became_completed || (member["status"] == "completed" && accepted_changed)
        member["result_delivery"] = "native_task"
        @record.event("member_result_recorded", "thread_id" => member["thread_id"],
                      "status" => member["status"], "delivery" => "native_task",
                      "accepted_at" => member["accepted_at"])
      end
      %w[model result output_path registry_status accepted_at status result_delivery].any? { |key| member[key] != previous[key] }
    end

    # acceptedAt is stamped only when the driver accepts the run. A later
    # running/streaming ref has not accepted this observation.
    def native_result_accepted?(member, observed)
      return false unless member["accepted_at"]
      return false if member["registry_status"] == "running"
      return false if observed.is_a?(Hash) && observed["streaming"] == true

      true
    end

    def native_accepted_at(source)
      return nil unless source.is_a?(Hash)

      lifecycle = source["lifecycle"]
      value = lifecycle["acceptedAt"] || lifecycle["accepted_at"] if lifecycle.is_a?(Hash)
      value ||= source["accepted_at"] || source["acceptedAt"]
      value if value.is_a?(Numeric) || value.is_a?(String) && !value.empty?
    end

    def copy_output_path(member, path)
      member["output_path"] = path if path.is_a?(String) && !path.empty?
    end

    def member_blocks_new_hint?(member)
      return true if %w[starting working].include?(member["status"])
      return false unless member["adapter"] == OMP_NATIVE_ADAPTER
      return false if %w[completed failed refused].include?(member["status"])

      true
    end

    def consume_hub_events
      return unless omp_task? && @connection.respond_to?(:hub_events)

      payload = @connection.hub_events
      events = payload.is_a?(Hash) ? payload["events"] : nil
      return unless events.is_a?(Array)

      seen = @state["hub_seen_ids"] ||= []
      changed = false
      events.each do |event|
        next unless event.is_a?(Hash)
        id = event["id"].to_s
        id = "seq-#{event['seq']}" if id.empty? && event["seq"]
        next if id.empty? || seen.include?(id)

        seen << id
        summary = {
          "id" => event["id"], "seq" => event["seq"], "kind" => event["kind"], "op" => event["op"],
          "from" => event["from"], "to" => event["to"], "agent_id" => event["agent_id"],
          "session_id" => event["session_id"], "await_reply" => event["await_reply"],
          "message" => event["message"], "text" => event["text"], "ok" => event["ok"]
        }
        (@state["native_collaboration"] ||= []) << summary
        @state["native_collaboration"] = @state["native_collaboration"].last(50)
        @record.event("native_collaboration", summary)
        changed = true
      end
      seen.shift while seen.length > 500
      seqs = events.filter_map { |event| event["seq"] if event.is_a?(Hash) && event["seq"].is_a?(Integer) }
      last = @state["hub_last_seq"]
      gap = native_collaboration_observation_gap(last, seqs, payload["dropped_oldest"], payload["next_seq"])
      if gap && @state["native_collaboration_observation_gap"] != gap
        @state["native_collaboration_observation_gap"] = gap
        @record.event("native_collaboration_observation_gap", gap)
        changed = true
      end
      next_seq = payload["next_seq"]
      unless next_seq.is_a?(Integer) && last && next_seq <= last
        newest = seqs.max
        @state["hub_last_seq"] = [last, newest].compact.max if newest && newest != last
        changed = true if @state["hub_last_seq"] != last
      end
      save if changed
    end

    def native_collaboration_observation_gap(last, seqs, dropped, next_seq)
      if last.nil?
        first = seqs.first
        return nil unless (first && first > 1) || dropped.to_i > 0

        return { "status" => "possible_loss", "first_seq" => first, "dropped_oldest" => dropped.to_i }
      end
      if next_seq.is_a?(Integer) && next_seq <= last
        return { "status" => "reset_unconfirmed", "last_seq" => last, "next_seq" => next_seq }
      end
      newer = seqs.find { |seq| seq > last }
      return nil unless newer && newer > last + 1

      { "status" => "confirmed_gap", "last_seq" => last, "first_new_seq" => newer, "next_seq" => next_seq }
    end

    def collect_member_results
      @state["members"].each do |member|
        observe_omp_native_member(member) if member["adapter"] == OMP_NATIVE_ADAPTER
      end
    end

    def reject_legacy_members!
      legacy = @state["members"].reject { |member| member["adapter"] == OMP_NATIVE_ADAPTER }
      return if legacy.empty? || TERMINAL.include?(@state["status"])

      ids = legacy.map { |member| member["thread_id"] }
      @record.event("legacy_member_rejected", "thread_ids" => ids, "reason" => "no migration path")
      stop("legacy member records have no migration path: #{ids.join(', ')}", status: "needs_user")
    end

    def members_settled?
      return false if Array(@state["amendment_delivery_queue"]).any?

      @state["members"].all? { |member| %w[completed failed refused].include?(member["status"]) }
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
          unless @connection.respond_to?(:instruction_source_kind)
            stop("Cannot record a user amendment: instruction source kind is unavailable", status: "needs_user")
            return false
          end
          add_amendment(message.fetch("text"), { "kind" => @connection.instruction_source_kind, "id" => message.fetch("id") })
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
          "model_evidence_request" => pending_evidence_request_context,
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
        # A checker verdict is not completion. Process and automatic checks
        # are ignored. A qualified manual artifact review only wakes Root;
        # complete is recorded later, after Root's explicit stop turn finishes.
        if scope["kind"] == "process"
          @record.event("process_check_complete_ignored", "number" => scope["number"])
        elsif scope["manual"] != true
          @record.event("automatic_check_complete_ignored", "number" => scope["number"], "kind" => scope["kind"])
        elsif !(host["status"] == "idle" && host["last_turn_status"] == "completed" &&
                members_settled? && @state["recheck"].nil? &&
                @state["findings"].values.none? { |finding| finding["status"] == "open" })
          @state["observation_pending"] = {
            "reason" => "Completion needs an idle Root, settled execution members, " \
                        "all delivery findings resolved and pending clues reconciled"
          }
        end
      when "correct"
        send_correction(result.merge("findings" => accepted_findings), scope: scope, current_digest: current_digest) unless accepted_findings.empty?
      when "pause"
        stop(result.fetch("reason"))
      when "needs_user"
        stop(result.fetch("reason"), status: "needs_user")
      when "continue"
        send_correction(result.merge("findings" => accepted_findings), scope: scope, current_digest: current_digest) if host["status"] == "idle" && !accepted_findings.empty?
      end
      save
    end

    # A valid manual reviewer conclusion (`continue`, `correct`, or `complete`
    # with no current findings) cannot itself declare the product task complete.
    # Wake an idle Root once for the exact reviewed version so it can call stop,
    # and prevent a one-second checker loop while that hand-off is pending.
    def notify_finalization_ready(scope, result, host, current_digest, now)
      return unless scope["kind"] == "artifact" && scope["role"] == "reviewer" && scope["manual"]
      return unless %w[continue correct complete].include?(result.fetch("verdict"))
      return unless result.fetch("findings").empty? && @state["recheck"].nil?
      return unless @state["findings"].values.none? { |finding| finding["status"] == "open" }
      return unless members_settled?
      unless host["status"] == "idle" && host["last_turn_status"] == "completed"
        queue_finalization_handoff(scope, current_digest, now)
        return
      end

      send_finalization_notice(scope, current_digest, now)
    end

    # Sends one version-keyed finalization notice. The notice itself never
    # completes the task; an explicit Root stop still waits for its final turn
    # and rechecks artifact, input and members at stop time.
    def send_finalization_notice(scope, current_digest, now)
      key = Digest::SHA256.hexdigest(JSON.generate([
        scope["artifact_root"], current_digest, scope["input_digest"]
      ]))
      @state.delete("pending_finalization")
      unless @state["finalization_notices"][key]
        text = "Orbit final-check notice (not a new user instruction): the manual review of the current " \
               "artifact and task input is valid and no current findings remain. If implementation and local " \
               "verification are complete, call Orbit stop and finish your turn normally: Orbit queues the " \
               "stop, lets this turn complete so your final summary to the user is fully delivered, then stops " \
               "execution and records completion. Orbit does not infer task completion from the checker's " \
               "verdict alone."
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

    # The reviewed version is fixed here. A later tick may deliver it once;
    # a changed artifact, input, or workspace must not receive this notice.
    # Repeated hand-offs for the SAME version keep the original timer so the
    # bounded wait cannot be reset by another fresh manual check.
    def queue_finalization_handoff(scope, current_digest, now)
      existing = @state["pending_finalization"]
      at = if existing.is_a?(Hash) &&
             existing["artifact_root"] == scope["artifact_root"] &&
             existing["artifact_digest"] == current_digest &&
             existing["input_digest"] == scope["input_digest"]
             existing["at"]
           end
      pending = {
        "check" => scope["number"], "artifact_root" => scope["artifact_root"],
        "artifact_digest" => current_digest, "input_digest" => scope["input_digest"],
        "at" => at || Time.at(now).utc.iso8601
      }
      return if existing == pending

      @state["pending_finalization"] = pending
      @record.event("finalization_pending", "check" => scope["number"], "version" => current_digest)
    end

    def deliver_pending_finalization(host, now)
      pending = @state["pending_finalization"]
      return false unless pending.is_a?(Hash)
      ready = host["status"] == "idle" && host["last_turn_status"] == "completed"
      return false unless ready || finalization_wait_expired?(pending, now)
      return false unless members_settled? && @state["recheck"].nil?
      return false if @state["findings"].values.any? { |finding| finding["status"] == "open" }

      current_digest = fingerprint_artifact
      unless pending["artifact_root"] == artifact_root &&
             pending["artifact_digest"] == current_digest &&
             pending["input_digest"] == @record.input_digest(@state)
        @state.delete("pending_finalization")
        @record.event("finalization_pending_stale", "check" => pending["check"])
        schedule_check(now, "完成核对前版本变化，立即重新核对", trigger: "version_change")
        save
        return false
      end

      scope = {
        "kind" => "artifact", "role" => "reviewer", "manual" => true,
        "number" => pending["check"], "artifact_root" => pending["artifact_root"],
        "input_digest" => pending["input_digest"]
      }
      send_finalization_notice(scope, current_digest, now)
      save
      true
    end

    def finalization_wait_expired?(pending, now)
      at = pending["at"].to_s
      return true if at.empty?

      now - Time.parse(at).to_f >= FINALIZATION_NOTICE_MAX_WAIT_SECONDS
    rescue ArgumentError
      true
    end

    def send_correction(result, scope:, current_digest:)
      entry = File.expand_path("../../scripts/orbit", __dir__)
      dispute = [entry, "dispute", @record.path, "--reason"].shelljoin
      text = "Orbit independent check (not a new user instruction):\n" + JSON.pretty_generate(result) +
             "\nWork against the original request. Correct relevant findings. For a real dispute, provide concrete contrary evidence using: #{dispute} 'reason and evidence'."
      deliver_correction_text(text,
                              "check" => scope["number"], "artifact_root" => scope["artifact_root"],
                              "artifact_digest" => current_digest, "input_digest" => scope["input_digest"])
    end

    # A transient delivery failure (bridge hiccup, Root busy past the RPC
    # window) must not fail the task: record it, keep the finding open, and
    # redeliver when the Root is next observed idle — but only if the pending
    # correction still describes the CURRENT version; a newer correction
    # simply overwrites the pending entry.
    def deliver_correction_text(text, versions = nil)
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      @state.delete("pending_correction")
      @record.event("correction_sent", "id" => sent.fetch("id"))
    rescue Connection::Error => error
      @state["pending_correction"] = (versions || {}).merge("text" => text)
      @record.event("correction_delivery_failed", "error" => error.message)
      save
    end

    def validate_member_roster!(listed)
      raise ArgumentError, "members.json must be an array" unless listed.is_a?(Array)

      seen = {}
      listed.each_with_index do |entry, index|
        unless entry.is_a?(Hash)
          raise ArgumentError, "members.json entry #{index} is not an object"
        end
        id = entry["thread_id"]
        unless id.is_a?(String) && !id.empty?
          raise ArgumentError, "members.json entry #{index} is missing a thread_id"
        end
        raise ArgumentError, "members.json entry #{index} repeats thread_id #{id}" if seen[id]

        seen[id] = true
        name = entry["requested_name"]
        unless name.is_a?(String) && !name.strip.empty?
          raise ArgumentError, "members.json entry #{index} is missing requested_name"
        end
        unless %w[registered refused].include?(entry["status"])
          raise ArgumentError, "members.json entry #{index} has an unknown status"
        end
      end
    end

    # An explicit Root stop COMMAND records complete instead of paused only when
    # the hand-off version is still fully qualified: a finalization notice for
    # the exact current artifact+input version exists, no open findings or
    # pending clues remain, and members are settled. The notice itself was
    # gated on an idle, completed Root; at stop time the Root is normally
    # mid-turn because its own stop call is a turn, so the predicate only
    # requires the connection to still be readable. Interrupts
    # (@stop_requested) and post-crash stop retries (retry_stop) never take
    # this path: they stay paused or stop_unconfirmed.
    def completion_notice_current?
      key = Digest::SHA256.hexdigest(JSON.generate([
        artifact_root, fingerprint_artifact, @record.input_digest(@state)
      ]))
      notice = @state["finalization_notices"][key]
      return nil unless notice
      return nil unless @state["recheck"].nil?
      return nil if @state["findings"].values.any? { |finding| finding["status"] == "open" }
      return nil unless members_settled?

      @connection.state # liveness only: the stop turn itself makes Root busy
      notice
    rescue Connection::Error
      nil
    end

    def stop(reason, status: "paused", allow_complete: false)
      roster_error = nil
      begin
        reconcile_registered_members!
      rescue StandardError => error
        roster_error = "#{error.class}: #{error.message}"
        @record.event("members_unreadable", "error" => roster_error)
      end
      checker_error = @state["cleanup_error"]
      begin
        @checker.stop! if @running_check
      rescue StandardError => error
        checker_error = error.message
        record_cleanup_error(error)
      end
      @running_check = nil
      confirmation = nil
      begin
        confirmation = confirmed_stop
        raise ArgumentError, "Checker stop unconfirmed: #{checker_error}" if checker_error
        raise ArgumentError, "members.json is not a reliable roster: #{roster_error}" if roster_error

        @state["execution_stop_confirmation"] = confirmation if checker_error
        @state["stop_confirmation"] = confirmation
        final_status = status
        notice = allow_complete && status == "paused" ? completion_notice_current? : nil
        if notice
          final_status = "complete"
          @state["delivery_digest"] = fingerprint_artifact
          @record.event("completed_via_finalized_stop", "check" => notice["check"])
        end
        @state["status"] = final_status
        @state["stop_reason"] = reason
        @record.event("stopped", "reason" => reason, "confirmation" => confirmation)
        save
      rescue StandardError => error
        detail = error.message
        if roster_error && !detail.include?("not a reliable roster")
          detail = "members.json is not a reliable roster: #{roster_error}; #{detail}"
        end
        @state["status"] = "stop_unconfirmed"
        @state["stop_reason"] = reason
        @state["error"] = detail
        @record.event("stop_unconfirmed", "reason" => reason, "error" => detail)
        save
      end
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
      # Root abort can drop the OMP registry session. Confirm native members
      # from the live bridge first, then stop Root so a later retry is not the
      # only chance to observe them.
      native, others = @state["members"].partition { |member| member["adapter"] == OMP_NATIVE_ADAPTER }
      native_results = native.map { |member| stop_omp_native_member(member, failures) }
      other_results = others.map do |member|
        failures << "Member #{member['thread_id']}: legacy member record has no migration path and was not stopped"
        { "thread_id" => member["thread_id"], "error" => "legacy member record rejected", "registration_status" => member["status"] }
      end
      begin
        confirmation = @connection.stop!
        failures << "Root did not confirm actual stop" unless confirmation["confirmed"] == true
      rescue StandardError => error
        failures << "Root: #{error.message}"
        confirmation = nil
      end
      members = native_results + other_results
      @state["member_stop_results"] = members
      raise ArgumentError, failures.join("; ") unless failures.empty?

      confirmation["members"] = members unless members.empty?
      confirmation
    end
  end
end
