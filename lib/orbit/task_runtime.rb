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
require_relative "model_candidate_pool"
require_relative "checker_model_selector"
require_relative "check_runner"
require_relative "git_remote_evidence"
require_relative "task_git_evidence"
require_relative "observation_key"
require_relative "resource_call_ledger"
require_relative "route_cost_inputs"
require_relative "work_unit"
require_relative "requirement_coverage"
require_relative "member_model_selector"

module Orbit
  class TaskRuntime
    TERMINAL = %w[complete paused needs_user failed stop_unconfirmed].freeze

    # Settled member vocabulary. `rejected` is a business rejection backed by
    # real native output — never a native failure; see the task-runtime
    # contract section 成员结算 for the ranked settlement sources.
    MEMBER_SETTLED = %w[completed failed refused rejected].freeze

    # Bounded program-computed check history handed to an independent check.
    # The checker sees check IDENTITY (number/role/kind/root/input/artifact
    # digests, start/finish, terminal outcome, stale reasons, failure kind) for
    # the anchor — the earliest valid artifact review of the current input on the
    # real artifact root, whatever its historical artifact digest — plus a
    # bounded recent window. Omissions stay visible as counts, and these are history facts:
    # they never grant current completion eligibility and no old finding is
    # imported into the pending clues.
    CHECK_HISTORY_RECENT = 6
    CHECK_HISTORY_OMITTED_LIMIT = 20
    CHECK_HISTORY_AMENDMENT_LIMIT = 5
    REVIEW_FOCUS_STATUSES = %w[added modified deleted].freeze
    REVIEW_FOCUS_LIMIT = 200
    # A queued completion stop waits for the Root's delivery turn to finish;
    # beyond this cap it stops immediately rather than waiting forever.
    COMPLETION_STOP_TIMEOUT_SECONDS = 600
    # The same open finding reported by this many consecutive effective,
    # current-input checks without any binding change (proposal 2026-09-26
    # item 2) means the delivered correction is not moving Root: the finding
    # is escalated once in the durable record with an action prompt --
    # fix and re-check, dispute with evidence, or hand the product call to
    # the user. Count alone never closes a finding or stops a task.
    REPEAT_FINDING_ESCALATION_REPORTS = 2
    # The one next action per refusal code, shared by the CLI receipt and the
    # runtime wake-up: a missing notice is fixed by a final check, while a
    # failing precondition must be resolved first (a clean-up that cannot be
    # verified or an unsettled member never qualifies by re-checking alone).
    RUNTIME_UNAVAILABLE_REASON = "runtime_unavailable"
    COMPLETION_NEXT_ACTIONS = {
      "no_current_finalization_notice" => "当前文件或要求还没有通过对应的最终检查。请当前助手请求一次最终检查，结束本轮并等待结果；确认通过后再申请完成。",
      "open_findings" => "检查还有未解决的问题。请当前助手修正后重新请求最终检查，收到通过通知再申请完成。",
      "pending_clue_recheck" => "有之前发现的问题尚待重新核对。请当前助手等核对结果，再对最终交付版本请求检查；通过后再申请完成。",
      "members_not_settled" => "还有协作成员在工作或结果未收齐。请当前助手先完成成员收尾，再请求最终检查和申请完成。",
      "requirement_coverage_unverified" => "仍有要求未核验或覆盖记录不可用。请当前助手补齐实际证据，对当前版本请求一次完整独立终检；不能凭无 finding 申请完成。",
      "checker_cleanup_unverified" => "上一次检查进程是否退出还无法确认。先核实并清理；本任务只能按普通停止收尾，若仍需交付，请另建任务检查。",
      "root_bridge_unavailable" => "当前助手的会话暂时无法核实，本次申请未生效。连接恢复后重新申请完成；如文件或要求有变化，先重新检查。",
      "members_unreadable" => "协作成员名单暂时读不到。请先恢复名单，再申请完成；若只能普通停止，之后需要另建任务检查才能交付。",
      "members_registered_during_stop" => "结束过程中又出现协作成员，还无法确认全部停止。先重试普通停止并确认成员已退出；要交付需另建任务检查。",
      "preconditions_unverifiable" => "当前文件或任务记录暂时无法读取，Orbit 不能确认完成。请恢复读取后重试，必要时申请普通停止。",
      "runtime_unavailable" => "任务运行进程已不可用。若要清理，请申请普通停止；不能将本任务标为完成，也无需新建任务来清理。"
    }.freeze
    COMPLETION_REFUSAL_NEXT_ACTION = COMPLETION_NEXT_ACTIONS.fetch("no_current_finalization_notice")
    # A version-bound pending finalization notice waits for the Root turn when
    # that happens sooner, but must still be delivered within this bound even
    # if Root stays active/waiting (see contracts/task-runtime.md).
    FINALIZATION_NOTICE_MAX_WAIT_SECONDS = 60
    OMP_NATIVE_ADAPTER = "omp_native_task"
    def initialize(record:, connection:, checker:, advisor: nil, evidence_cache: nil, candidate_pool: nil,
                   checker_selector: nil, member_selector: nil)
      @record, @connection, @checker = record, connection, checker
      @advisor = advisor
      @evidence_cache = evidence_cache
      @candidate_pool = candidate_pool
      @checker_selector = checker_selector
      @member_selector = member_selector
      @state = record.state
      @state["findings"] ||= {}
      @state["sent_message_ids"] ||= []
      @state["delegation_hints"] ||= {}
      @state["delegation_assessments"] ||= {}
      @state["member_selections"] ||= {}
      @state["evidence_requests"] ||= {}
      @state["evidence_gaps"] ||= {}
      @state["members"] ||= []
      @state["unknown_candidates"] ||= {}
      @state["check_observations"] ||= {}
      @state["finalization_notices"] ||= {}
      @state["completion_readiness"] ||= { "status" => "waiting", "reason" => "尚无当前版本的有效终检" }
      @state["usage"] ||= { "tokens" => nil }
      @state["usage"]["jev_entry"] ||= @state.dig("entry", "trace", "usage") if @state["entry"]
      initial_selection = @state.dig("review", "selection")
      if initial_selection.is_a?(Hash) && initial_selection["judgment_provider"]
        @state["usage"]["jev_checker_selection"] ||= initial_selection["usage"]
      end
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
      capture_startup_judgments
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
          if host["session_file"].is_a?(String) && !host["session_file"].empty?
            @state["root_session_file"] = host["session_file"]
          end
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
          capture_interrupted_check(@running_check) if @running_check
          @connection.close
        end
        @state["finished_at"] = Time.now.utc.iso8601
        @state["elapsed_seconds"] = Time.now - Time.parse(@state.fetch("created_at"))
        check_usage = @state.fetch("checks").map { |check| check["usage"] }
        measured = check_usage.select do |usage|
          usage.is_a?(Hash) && usage["incomplete"] != true &&
            %w[input_tokens output_tokens].all? { |field| usage[field].is_a?(Integer) && usage[field] >= 0 }
        end
        subtotal = measured.empty? ? nil : measured.sum { |usage| usage["input_tokens"] + usage["output_tokens"] }
        interrupted = @state.dig("usage", "interrupted_checks") || {}
        @state["usage"]["check_tokens"] = measured.length == check_usage.length && interrupted.empty? ? subtotal : nil
        @state["usage"]["check_tokens_reported_subtotal"] = subtotal
        @state["usage"]["check_usage_missing_attempts"] = check_usage.length - measured.length + interrupted.length
        estimate = @state.dig("estimate", "seconds")
        @state["comparison"] = {
          "time_variance_seconds" => estimate ? @state["elapsed_seconds"] - estimate : nil,
          "task_token_variance" => nil,
          "stale_checks" => @state.fetch("checks").count { |check| check["stale"] },
          "correction_messages" => @state.fetch("sent_message_ids").length,
          "note" => "Check usage is measured separately. Root session totals can include earlier work; task-wide tokens remain unknown without a baseline."
        }
        mark_terminal_ask_interrupts!
        @state.delete("runtime_pid")
        save
      end
      @state
    end

    def request_stop
      @stop_requested = true
    end

    # Completion hand-off preconditions on durable state alone. The CLI runs in
    # its own process and can only read the record, so it refuses a completion
    # request before queueing anything with this same predicate; the runtime
    # re-evaluates it before tearing a task down. Returns [notice_key, nil, nil]
    # when the hand-off may proceed, [nil, code, detail] when it must be refused.
    def completion_gate
      cleanup = @state["cleanup_error"].to_s.strip
      unless cleanup.empty?
        return [nil, "checker_cleanup_unverified",
                "an unverified checker cleanup is recorded: #{cleanup}"]
      end

      open = @state["findings"].values.select { |finding| finding["status"] == "open" }.map { |finding| finding["id"] }
      return [nil, "open_findings", "open findings remain: #{open.join(', ')}"] unless open.empty?
      unless @state["recheck"].nil?
        return [nil, "pending_clue_recheck", "an independent recheck of a pending clue is still outstanding"]
      end
      return [nil, "members_not_settled", "registered members are not settled yet"] unless members_settled?

      # Blockers outrank the missing notice: a task with an open finding and no
      # current notice must be told to fix first, not to re-check an unchanged
      # version (contracts/task-runtime.md: the refusal names the reason and its
      # own next action). The version key is computed last, after the cheap
      # blockers, because it walks the artifact workspace.
      key = completion_notice_key
      readiness = @state["completion_readiness"]
      unless @state["finalization_notices"][key] && readiness.is_a?(Hash) &&
             %w[ready queued].include?(readiness["status"]) && readiness["notice_key"] == key
        return [nil, "no_current_finalization_notice",
                "no delivery-ready finalization notice exists for the current artifact and input version"]
      end

      coverage = requirement_coverage_status if @state["coverage_required"]
      if coverage && !coverage["ready"]
        return [nil, "requirement_coverage_unverified", coverage["gap"]]
      end

      [key, nil, nil]
    rescue StandardError => error
      [nil, "preconditions_unverifiable",
       "the completion preconditions could not be verified (#{error.class}: #{error.message})"]
    end

    # Synchronous CLI gate: [code, detail] when a completion request must be
    # refused, nil when it may proceed. Never inspects the bridge, so a refusal
    # is decided from the durable record the Root's own stop call reads.
    def self.completion_refusal(record)
      _key, code, detail = new(record: record, connection: nil, checker: nil).completion_gate
      code ? [code, detail] : nil
    end

    # The refusal's next action for a code, shared by the CLI receipt and the
    # runtime wake-up; unknown codes fall back to the final-check guidance.
    def self.completion_next_action(code)
      COMPLETION_NEXT_ACTIONS.fetch(code.to_s, COMPLETION_REFUSAL_NEXT_ACTION)
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
          # Re-read the session and roster state first: the record must show
          # what was already stopped before this retry (an already-confirmed
          # member or an idle Root is not re-interrupted), and an unreachable
          # bridge is recorded as a fact instead of surfacing only as a stop
          # failure string.
          refresh_stop_retry_probe
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
          # The delivery turn finished; `stop` adjudicates the hand-off once
          # more before teardown and records a refusal (keeping the task
          # running) when the notice no longer matches the delivered version.
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
      if host["session_file"].is_a?(String) && !host["session_file"].empty? &&
         @state["root_session_file"] != host["session_file"]
        @state["root_session_file"] = host["session_file"]
        @record.event("root_session_located", "thread_id" => host["thread_id"],
                      "session_file" => host["session_file"])
        save
      end
      if host["interrupted"] || (host["status"] == "idle" && host["last_turn_status"] == "interrupted")
        stop("The user interrupted the Root turn")
        return
      end
      consume_commands
      return if TERMINAL.include?(@state["status"])
      capture_native_calls
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
      refresh_completion_readiness!(now)
      if @running_check
        begin
          @check_result ||= @checker.poll
        rescue CheckRunner::Error => error
          # A failed check is recorded, then another unused OMP model may
          # check the same input and artifact. Program errors remain fatal.
          handle_check_failure(error, now)
          return
        end
        finish_check(@check_result, host, now) if @check_result
        return
      end
      deliver_pending_ask_reminders(host, now)
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
      record_task_delivery(host) if delivery
      delivery_due = delivery && task_turn_attributed?(host) && host["last_turn_id"] != @last_delivery_checked
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
          @record.event("correction_redelivery_stale", "check" => pending["check"],
                        "finding_ids" => pending["finding_ids"], "artifact_digest" => pending["artifact_digest"],
                        "input_digest" => pending["input_digest"])
          save
        else
          deliver_correction_text(pending.fetch("text"), pending)
        end
      end
      if now >= @next_check || delivery_due
        if !delivery_due && @state["next_check_manual"] != true &&
           %w[timer checker_interval finalization_wait].include?(@state["next_check_trigger"]) &&
           host["status"] != "idle"
          schedule_check(now + @interval, "Root 工作中，纯定时检查延后", trigger: "timer")
          save
          return
        end
        # A manual final check must see the Root's completed delivery, not a
        # snapshot taken mid-reply with an empty agent_message. Keep the
        # request queued until that turn finishes; automatic observations may
        # still run while Root works.
        if @state["next_check_trigger"] == "manual_check" && !delivery
          schedule_check(now + 1, "等待 Root 实际交付后终检", trigger: "manual_check", manual: true)
          save
          return
        end
        scheduled = now >= @next_check || (delivery_due && @state["next_check_manual"] == true)
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
        stage_delegation(artifact_digest, now, host: host) if decision.nil? && @pending_hint.nil?
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
        # A selection is advisory and stays bound to the actual unit and input.
        # Checks take precedence; a changed observation defers delivery without
        # reusing a recommendation for another user turn or work unit.
        if @pending_hint
          consume_commands
          return if TERMINAL.include?(@state["status"])
          return unless collect_amendments
          latest_host = @connection.state
          latest_digest = fingerprint_artifact
          if observation_stale?(host, artifact_digest, latest_host, latest_digest, now)
            @jev_next_at = [@jev_next_at, now + 20].max
            @pending_hint = nil
          else
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

    # The runtime, not the UI, owns version binding. A reviewer that overturns
    # an obsolete not_ready reason still cannot issue completion: the new
    # review_needed state waits for a qualified manual final check.
    def refresh_completion_readiness!(now)
      ready = @state["completion_readiness"]
      return unless ready.is_a?(Hash) && %w[waiting ready review_needed].include?(ready["status"])
      return unless ready["artifact_digest"]

      input_changed = ready["input_digest"] != @record.input_digest(@state)
      workspace_changed = ready["artifact_root"] != artifact_root
      artifact_changed = !workspace_changed && ready["artifact_digest"] != probe_artifact(now)
      notice_missing = ready["status"] == "ready" && !@state["finalization_notices"].key?(ready["notice_key"])
      return unless input_changed || workspace_changed || artifact_changed || notice_missing

      reason = if input_changed then "任务要求已修订"
               elsif workspace_changed then "产物工作区已改变"
               elsif artifact_changed then ready["status"] == "review_needed" ? "待终检的产物已改变" : "终检后的产物已改变"
               else "当前检查通知已失效"
               end
      @state["completion_readiness"] = { "status" => "invalidated", "reason" => reason }
      if (pending = @state.delete("pending_finalization"))
        @record.event("finalization_pending_stale", "check" => pending["check"], "reason" => reason)
      end
      schedule_check(now, "完成核对前版本变化，立即重新核对", trigger: "version_change")
      @record.event(ready["status"] == "review_needed" ? "review_readiness_invalidated" : "finalization_notice_invalidated",
                    "reason" => reason)
      save
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
      @state["completion_readiness"] = { "status" => "invalidated", "reason" => "产物工作区已重新绑定" }
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

    # Bounded, program-computed check history for the independent checker: the
    # anchor is the EARLIEST valid independent artifact review of the current
    # INPUT on the real artifact ROOT, keeping its own historical
    # artifact_digest (so a checked-then-edited artifact never evicts the
    # pre-implementation check), plus a bounded recent window. Everything
    # omitted is counted and listed, so absence is never silently claimed.
    def check_history_for(snapshot)
      checks = Array(@state["checks"])
      input_digest = @record.input_digest(@state)
      artifact_digest = snapshot.fetch("digest")
      anchor = checks.find { |entry| history_anchor?(entry, input_digest) }
      recent = checks.last(CHECK_HISTORY_RECENT)
      kept = ([anchor] + recent).compact.uniq { |entry| entry["number"] }
      omitted = checks.reject { |entry| kept.any? { |entry_kept| entry_kept["number"] == entry["number"] } }
      {
        "eligibility" => "history facts only; not current completion eligibility",
        "current_input_digest" => input_digest, "current_artifact_digest" => artifact_digest,
        "total_checks" => checks.length,
        "anchor" => anchor && projected_check(anchor).merge(
          "anchor_basis" => "earliest valid artifact review of the current input on the real artifact root; " \
                            "its own artifact_digest is historical and grants no current completion eligibility"
        ),
        "recent" => recent.map { |entry| projected_check(entry) },
        "omitted_count" => omitted.length,
        "omitted_numbers" => omitted.last(CHECK_HISTORY_OMITTED_LIMIT).map { |entry| entry["number"] },
        # The per-check input_digest above IS the version timeline; the amendment
        # entry itself is part of Record#inputs, so embedding a digest inside it
        # would be self-referential.
        "amendments" => Array(@state["amendments"]).last(CHECK_HISTORY_AMENDMENT_LIMIT).map do |amendment|
          { "at" => amendment["at"], "path" => amendment["path"], "source" => amendment["source"] }
        end
      }
    end

    # The anchor is the EARLIEST valid independent artifact review of the CURRENT
    # input on the REAL artifact root, regardless of how many later checks
    # changed the artifact digest: a fix (or any edit) always changes the digest,
    # so matching the current digest would drop the pre-implementation check the
    # checker needs. The anchor keeps its OWN historical artifact_digest as a
    # historical fact — it never grants current completion eligibility — and a
    # failed or stale check is never promoted to anchor.
    def history_anchor?(entry, input_digest)
      return false unless entry.is_a?(Hash)
      return false unless entry["role"] == "reviewer" && entry["kind"] == "artifact"
      return false if entry["failed"] == true || entry["stale"] == true

      identity = check_identity(entry)
      identity["input_digest"] == input_digest && identity["artifact_root"] == artifact_root
    end

    # One check's durable identity, falling back to its own checks/<n>/scope.json
    # when it was recorded before the identity slice existed.
    def check_identity(entry)
      identity = entry.slice("artifact_root", "input_digest", "artifact_digest")
      return identity if identity.values_at("artifact_root", "input_digest", "artifact_digest").none?(&:nil?)

      check_scope_identity(entry["number"]).merge(identity) { |_key, fallback, value| value || fallback }
    end

    # One check's identity/outcome facts. Failed checks recorded before the
    # identity slice existed fall back to their own checks/<n>/scope.json.
    def projected_check(entry)
      identity = check_identity(entry)
      {
        "number" => entry["number"], "role" => entry["role"], "kind" => entry["kind"],
        "artifact_root" => identity["artifact_root"], "input_digest" => identity["input_digest"],
        "artifact_digest" => identity["artifact_digest"],
        "started_at" => entry["started_at"], "finished_at" => entry["finished_at"],
        "stale" => entry["stale"], "stale_reasons" => Array(entry["stale_reasons"]),
        "terminal" => entry["failed"] ? "failed" : entry["stale"] ? "stale" : entry.dig("result", "verdict"),
        "failure_kind" => entry.dig("result", "failure_kind")
      }
    end

    def check_scope_identity(number)
      return {} if number.nil?

      path = File.join(@record.path, "checks", number.to_s, "scope.json")
      return {} unless File.file?(path)

      scope = JSON.parse(File.read(path))
      { "artifact_root" => scope["artifact_root"], "input_digest" => scope["input_digest"],
        "artifact_digest" => scope.dig("snapshot", "digest") }
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def assess_jev(host, artifact_digest, now)
      signature = Digest::SHA256.hexdigest(JSON.generate([
        host.slice("status", "turn_id", "last_turn_id", "last_turn_status", "active_tools"),
        artifact_digest, @record.input_digest(@state), @state["members"].map { |member| member.slice("thread_id", "status") }
      ]))
      # Time and noisy progress counters do not constitute a new observation.
      # Preserve the cooldown for actual changes, but never pay twice for an
      # unchanged observation (including after an unavailable judgment).
      return nil if now < @jev_next_at || signature == @jev_signature
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
      judgment = result.slice("provider", "model", "question_set_version", "usage", "call_id", "requested_model", "status")
      @record.event("jev_assessed", judgment.merge("scores" => scores))
      @state["jev"] = (@state["jev"].is_a?(Hash) ? @state["jev"] : {}).merge(
        judgment.merge("status" => "assessed", "scores" => scores, "assessed_at" => Time.at(now).utc.iso8601)
      )
      accumulate_jev_usage("jev_stage1", result["usage"], receipt: result)
      save

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
      judgment = consume_jev_failure(error, "jev_stage1")
      @record.event("jev_unavailable", judgment.merge("reason" => error.message))
      @state["jev"] = (@state["jev"].is_a?(Hash) ? @state["jev"] : {}).merge(
        judgment.merge("status" => "unavailable", "unavailable" => error.message, "at" => Time.at(now).utc.iso8601)
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
    def accumulate_jev_usage(bucket, usage, receipt: nil)
      return if receipt && capture_judgment_call(receipt, phase: bucket) == :duplicate

      aggregate = ((@state["usage"] ||= {})[bucket] ||= { "input_tokens" => nil, "output_tokens" => nil, "incomplete" => false })
      input = usage.is_a?(Hash) ? usage["input_tokens"] : nil
      output = usage.is_a?(Hash) ? usage["output_tokens"] : nil
      aggregate["input_tokens"] = (aggregate["input_tokens"] || 0) + input if input.is_a?(Integer)
      aggregate["output_tokens"] = (aggregate["output_tokens"] || 0) + output if output.is_a?(Integer)
      aggregate["incomplete"] = true unless input.is_a?(Integer) && output.is_a?(Integer)
    end

    def consume_jev_failure(error, bucket)
      judgment = error.judgment
      accumulate_jev_usage(bucket, judgment["usage"], receipt: judgment)
      judgment
    end

    def resource_call_ledger
      @resource_call_ledger ||= ResourceCallLedger.new(task_path: @record.path, task_id: @state.fetch("id"))
    end

    def capture_judgment_call(receipt, phase:)
      unless receipt["call_id"]
        gaps = (@state["usage"]["resource_call_gaps"] ||= {})
        gaps[phase] = "judgment call id missing; historical usage is not a uniquely attributed call"
        return :unattributed
      end

      added = resource_call_ledger.record_judgment(receipt, phase: phase)
      @state["usage"]["resource_calls"] = resource_call_ledger.summary
      added ? :recorded : :duplicate
    rescue ResourceCallLedger::Error => error
      @state["usage"]["resource_call_gaps"] ||= {}
      @state["usage"]["resource_call_gaps"][phase] = error.message
      @record.event("resource_call_accounting_failed", "phase" => phase, "reason" => error.message)
      :unavailable
    end

    def checker_judgment_receipt(selection)
      {
        "call_id" => selection["judgment_call_id"], "provider" => selection["judgment_provider"],
        "model" => selection["judgment_model"], "requested_model" => selection["judgment_requested_model"],
        "status" => selection["judgment_status"], "question_set_version" => selection["question_set_version"],
        "usage" => selection["usage"], "error" => selection["judgment_error"]
      }
    end

    def capture_startup_judgments
      entry = @state.dig("entry", "trace")
      if entry.is_a?(Hash) && entry["provider"]
        capture_judgment_call(entry.merge("status" => entry["judgment_status"]), phase: "jev_entry")
      end
      selection = @state.dig("review", "selection")
      if selection.is_a?(Hash) && selection["judgment_provider"]
        capture_judgment_call(checker_judgment_receipt(selection), phase: "jev_checker_selection")
      end
    end

    def capture_check_calls(scope, failed: false)
      phase = scope.fetch("role")
      role = phase == "adjudicator" ? "arbiter" : "checker"
      evidence = @checker.respond_to?(:evidence) ? @checker.evidence : nil
      usage = @checker.respond_to?(:usage) ? @checker.usage : nil
      calls = evidence.is_a?(Hash) && evidence["usage"].is_a?(Array) ? evidence["usage"] : (usage.is_a?(Hash) ? usage["calls"] : nil)
      calls = [] unless calls.is_a?(Array)
      key = "check_#{scope.fetch('number')}"
      gaps = @checker.respond_to?(:usage_gaps) ? Array(@checker.usage_gaps) : []
      gaps << "no individually attributed model call receipts" if calls.empty?
      calls.each do |call|
        next unless call.is_a?(Hash)
        if call["usage_status"] == "pending" &&
           (!@checker.respond_to?(:receipts_finalized?) || !@checker.receipts_finalized?)
          gaps << "#{call['call_id']}: receipt is pending while checker exit is unconfirmed"
          next
        end
        unless call["call_id"]
          gaps << "model call id missing; reported usage remains unassigned"
          next
        end

        # These are the native receipt fields, never the old derived totals
        # (input_tokens and total_tokens) for a whole check attempt.
        reported = call.slice("input", "output", "cacheRead", "cacheWrite", "reasoningTokens", "totalTokens")
                       .select { |_field, value| value.is_a?(Numeric) && value.finite? && value >= 0 }
        reported = nil if reported.empty?
        status = if %w[error aborted].include?(call["stop_reason"])
                   "failed"
                 elsif call["stop_reason"]
                   "completed"
                 else
                   failed ? "failed" : "unknown"
                 end
        begin
          resource_call_ledger.record_check(
            call.merge("actual_model" => call["model"], "usage" => reported, "status" => status,
                       "usage_source" => "native_message",
                       "attempt_id" => @checker.respond_to?(:attempt_id) ? @checker.attempt_id : nil),
            phase: phase, role: role
          )
        rescue ResourceCallLedger::Error => error
          gaps << "#{call['call_id']}: #{error.message}"
        end
      end
      @state["usage"]["resource_calls"] = resource_call_ledger.summary
      @state["usage"]["resource_call_gaps"] ||= {}
      @state["usage"]["resource_call_gaps"][key] = gaps.uniq.join("; ").slice(0, 1000) if gaps.any?
    rescue ResourceCallLedger::Error => error
      @state["usage"]["resource_call_gaps"] ||= {}
      @state["usage"]["resource_call_gaps"][key || "check"] = error.message
      @record.event("resource_call_accounting_failed", "phase" => phase, "reason" => error.message)
    end

    # One finalized native response per observed invocation. Pending boundaries
    # stay mutable in the host sidecar, including after stop. The observer also
    # persists final receipts directly, so late usage survives runtime exit.
    # An unresolved boundary is a coverage gap, never an immutable zero/unknown
    # receipt that would prevent its later final usage from being recorded.
    def capture_native_calls
      file = File.join(@record.path, "native-model-calls.json")
      failure_file = File.join(@record.path, "native-model-call-gaps.jsonl")
      failures = File.file?(failure_file) ? File.readlines(failure_file).map do |line|
        entry = JSON.parse(line)
        unless entry.is_a?(Hash) && entry["reason"].is_a?(String)
          raise ResourceCallLedger::Error, "native receipt persistence gap is malformed"
        end
        entry["reason"]
      end : []
      unless File.file?(file)
        @state["usage"]["resource_call_gaps"] ||= {}
        @state["usage"]["resource_call_gaps"]["native_execution"] = failures.uniq.join("; ").slice(0, 1000) unless failures.empty?
        return
      end

      document = JSON.parse(File.read(file))
      unless document.is_a?(Hash) && document["schema_version"] == "orbit-native-model-calls-v1" &&
             document["task_id"] == @state["id"] && document["calls"].is_a?(Hash) && document["gaps"].is_a?(Array)
        raise ResourceCallLedger::Error, "native model observations are corrupt or foreign"
      end
      gaps = document["gaps"].map(&:to_s) + failures
      document["calls"].each do |id, observed|
        unless observed.is_a?(Hash) && observed.dig("receipt", "call_id") == id && observed["meta"].is_a?(Hash)
          gaps << "#{id}: malformed native invocation observation"
          next
        end
        meta = observed["meta"]
        unless %w[root member].include?(meta["role"])
          gaps << "#{id}: native invocation has no verified execution role"
          next
        end
        if observed["finalized"] == true
          receipt = observed["ledger_receipt"]
        else
          gaps << "#{id}: provider boundary observed but final usage is pending"
          next
        end
        begin
          # The recorder's ledger_receipt already carries the final phase: the
          # Root-declared phase for a root-model switch's next call, or
          # role_execution otherwise. Trust it; fall back only if absent.
          resource_call_ledger.record_check(receipt, phase: receipt["phase"] || "#{meta['role']}_execution", role: meta["role"])
        rescue ResourceCallLedger::Error => error
          gaps << "#{id}: #{error.message}"
        end
      end
      @state["usage"]["resource_calls"] = resource_call_ledger.summary
      @state["usage"]["resource_call_gaps"] ||= {}
      @state["usage"]["resource_call_gaps"]["native_execution"] = gaps.uniq.join("; ").slice(0, 1000)
    rescue JSON::ParserError, SystemCallError, ResourceCallLedger::Error => error
      @state["usage"]["resource_call_gaps"] ||= {}
      @state["usage"]["resource_call_gaps"]["native_execution"] = error.message
    end

    def capture_interrupted_check(scope)
      capture_check_calls(scope, failed: true)
      attempts = (@state["usage"]["interrupted_checks"] ||= {})
      attempts[scope.fetch("number").to_s] = {
        "role" => scope.fetch("role"), "status" => "interrupted",
        "attempt_id" => @checker.respond_to?(:attempt_id) ? @checker.attempt_id : nil,
        "note" => "interrupted check attempt; recorded call receipts retain their own usage and completion status"
      }
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
                   when "takeover_scope" then %w[prior_scope]
                   when "dispute" then %w[reason]
                   when "review_model" then %w[model]
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
          if command["complete"] == true
            if completion_notice_current?
              # Deferred completion: aborting the Root turn now could cut the
              # user's final summary. Queue the stop; the tick performs it once
              # the current turn completed normally (bounded wait below),
              # re-verifying the hand-off version at that point.
              @state["completion_stop_pending"] = { "reason" => reason, "at" => Time.now.utc.iso8601 }
              @state["completion_readiness"] = @state.fetch("completion_readiness").merge(
                "status" => "queued", "reason" => "完成申请已入队，等待当前回复结束"
              )
              @record.event("completion_stop_queued", "reason" => reason)
            else
              # The CLI gate accepted this hand-off; the record stopped
              # qualifying before the runtime consumed it (version, clue,
              # finding or member change). Keep the task running and report the
              # refusal -- never record an ordinary pause in its place.
              reject_completion_handoff(reason)
            end
          else
            # Plain stops without the explicit completion intent take the
            # ordinary path.
            stop(reason)
          end
        when "amend"
          add_amendment(command.fetch("text"), command.fetch("source"))
          @state.delete("unassigned_user_message_id")
          sent = @connection.send_message("Orbit: the task input was explicitly amended:\n\n" + command.fetch("text"))
          @state["sent_message_ids"] << sent.fetch("id")
        when "check"
          schedule_check(0, "用户请求的检查", trigger: "manual_check", manual: true)
        when "rebind_workspace"
          rebind_workspace(command)
        when "takeover_scope"
          apply_takeover_scope_declaration(command)
        when "model_evidence"
          apply_model_evidence(command, now: Time.now.to_f)
        when "review_model"
          apply_review_model(command, Time.now.to_f)
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
      @state["completion_readiness"] = { "status" => "invalidated", "reason" => "任务要求已显式修订" }
      @state["members"].each do |member|
        next unless %w[working registered].include?(member["status"])
        deliver_native_amendment(member, text, source) if member["adapter"] == OMP_NATIVE_ADAPTER
      end
      schedule_check(0, "用户修改后重新核对", trigger: "amendment")
    end

    # Appends a later prior_scope declaration submitted for an existing
    # takeover boundary. Append-only: the created prior_scope, snapshot,
    # digest, native message and supervision start stay byte-identical, and
    # the declaration is recorded as the submitter's statement — the source is
    # stamped here, never copied from the command (so it can never be dressed
    # up as a native user observation or a program observation). Same content
    # retried is ignored; a task without a takeover boundary or a malformed
    # payload is rejected explicitly.
    def apply_takeover_scope_declaration(command)
      takeover = @state["takeover"]
      unless takeover.is_a?(Hash)
        @record.event("command_rejected", "command_type" => "takeover_scope",
                      "reason" => "task has no takeover boundary")
        return
      end
      unknown = command.keys - %w[type prior_scope reason source]
      scope = command["prior_scope"]
      reason = command["reason"]
      valid = unknown.empty? && scope.is_a?(String) && !scope.strip.empty? &&
              (reason.nil? || reason.is_a?(String))
      unless valid
        @record.event("command_rejected", "command_type" => "takeover_scope",
                      "reason" => "declaration payload is invalid")
        return
      end
      reason_value = reason.nil? || reason.strip.empty? ? nil : reason
      declarations = (takeover["prior_scope_declarations"] ||= [])
      if declarations.any? do |entry|
           entry.is_a?(Hash) && entry["prior_scope"] == scope && entry["reason"] == reason_value
         end
        @record.event("takeover_scope_duplicate_ignored",
                      "prior_scope_sha256" => Digest::SHA256.hexdigest(scope))
        return
      end
      declarations << {
        "prior_scope" => scope, "reason" => reason_value,
        "declared_at" => Time.now.utc.iso8601,
        "source" => { "kind" => "submitter_declaration" }
      }
      @record.event("takeover_scope_declared",
                    "prior_scope_sha256" => Digest::SHA256.hexdigest(scope),
                    "declarations" => declarations.length)
    end

    # Bounded projection of the takeover boundary for the independent checker:
    # the ORIGINAL prior_scope (possibly unknown) and the RECENT FIVE later
    # submitted declarations side by side, plus the program-captured boundary
    # facts. Never rewritten to make unknown look declared; declarations
    # remain submitter statements (not observations), and no old checks or
    # usage are imported. Omissions are counted (never silently dropped) and
    # the existing 64KiB compression bounds the rest.
    def takeover_context_projection
      takeover = @state["takeover"]
      return nil unless takeover.is_a?(Hash)

      declarations = Array(takeover["prior_scope_declarations"])
      projection = {
        "prior_scope" => takeover["prior_scope"],
        "prior_scope_declarations" => declarations.last(5),
        "reason" => takeover["reason"],
        "requested_at" => takeover["requested_at"],
        "requirement" => takeover["requirement"],
        "artifact" => takeover["artifact"],
        "supervision" => takeover["supervision"],
        "prior_execution" => takeover["prior_execution"]
      }
      projection["prior_scope_declarations_omitted"] = declarations.length - 5 if declarations.length > 5
      projection
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
        if (existing = @state["members"].find { |member| member["thread_id"] == id })
          changed = true if absorb_member_model_drift(existing, entry["model_drift"])
          changed = true if ensure_drift_notified(existing)
          next
        end

        member = {
          "kind" => "omp", "adapter" => OMP_NATIVE_ADAPTER, "thread_id" => id,
          "requested_name" => entry["requested_name"], "status" => entry.fetch("status"),
          "registered_at" => entry["registered_at"]
        }
        member["model"] = entry["model"] if entry["model"]
        member["tool_call_id"] = entry["tool_call_id"] if entry["tool_call_id"]
        member["reason"] = entry["reason"] if entry["reason"]
        drift = entry["model_drift"]
        if drift
          # A dispatch that never ran the authorized model never earns the
          # hint basis, even when drift is already on disk at first sight.
          member["delegation_basis"] = "root_without_hint"
        elsif member["status"] == "registered"
          hint = current_delegation_hint
          member["delegation_basis"] = delegation_basis(member, hint: hint)
          mark_delegation_hint_followed(member) if member["delegation_basis"] == "orbit_hint"
        end
        @state["members"] << member
        @record.event("native_member_reconciled", "thread_id" => id, "status" => member["status"],
                      "requested_name" => member["requested_name"], "tool_call_id" => member["tool_call_id"],
                      "model" => member["model"], "basis" => member["delegation_basis"])
        changed = true if absorb_member_model_drift(member, drift)
      end
      save if changed
    end

    # ADR-009 model drift, shape as written to members.json
    # ({expected, actual, recorded_at, abort_attempted?, abort_confirmed?};
    # extra OMP fields are preserved as-is because the final schema is not
    # settled): the member's final model differs from the resolved
    # candidate, so the dispatch never ran the authorized model. The member
    # is failed, its result can never complete or count as success, the
    # stale hint is invalidated, and Root must explicitly re-select; Orbit
    # never switches models automatically. One handling per member: later
    # drift rewrites on disk do not re-notify or re-stop.
    def absorb_member_model_drift(member, drift)
      return false unless drift.is_a?(Hash)
      return false if member["model_drift"]

      member["model_drift"] = drift
      member["status"] = "failed"
      member["error"] = "model drift: expected #{drift['expected']}, actual #{drift['actual']}"
      member["result_delivery"] = "refused_model_drift"
      hint = @state["delegation_hint"]
      if hint.is_a?(Hash) && hint["invalid_reason"].nil?
        hint["invalid_reason"] = "model_drift"
        hint["invalidated_at"] = Time.now.utc.iso8601
      end
      outcome = attempt_drifted_member_stop(member)
      member["drift_stop"] = outcome
      notify_model_drift(member, outcome)
      @record.event("member_model_drift_absorbed", "thread_id" => member["thread_id"],
                    "expected" => drift["expected"], "actual" => drift["actual"],
                    "abort_attempted" => drift["abort_attempted"], "abort_confirmed" => drift["abort_confirmed"],
                    "stop" => outcome)
      true
    end

    # Stop the drifted session before more unauthorized model work happens.
    # The outcome is recorded honestly; an unconfirmed stop never fails the
    # observer and is surfaced to Root in the drift notice.
    def attempt_drifted_member_stop(member)
      return "not_attempted" unless @connection.respond_to?(:stop_member)

      failures = []
      stop_omp_native_member(member, failures)
      failures.empty? ? "confirmed" : "unconfirmed: #{failures.join('; ')}"
    rescue StandardError => error
      "unconfirmed: #{error.class}: #{error.message}"
    end

    def notify_model_drift(member, stop_outcome)
      text = "Orbit model drift (not a new user instruction): member #{member['thread_id']} was expected to run " \
             "#{member.dig('model_drift', 'expected')} but members.json records #{member.dig('model_drift', 'actual')}. " \
             "Its result will not be accepted and the previous delegation hint is invalidated. " \
             "Explicitly re-select or re-dispatch the member model; Orbit does not switch models automatically. " \
             "Drifted member stop: #{stop_outcome}."
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      member["drift_notified"] = true
    rescue StandardError => error
      @record.event("member_model_drift_notify_failed", "thread_id" => member["thread_id"], "error" => error.message)
    end

    # A notification that failed to deliver retries on later reconciles; a
    # delivered one never repeats.
    def ensure_drift_notified(member)
      return false unless member["model_drift"] && !member["drift_notified"]

      notify_model_drift(member, member["drift_stop"] || "not_attempted")
      member["drift_notified"] == true
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
      @connection.send_member(member["thread_id"], "The task input was explicitly amended. Apply only changes relevant to your delegated scope:\n\n#{item['text']}")
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

    # The member selector owns the current task-fit questions, exact identity
    # facts and reviewed release. Root declares the bounded work unit and keeps
    # dispatch authority; a Jev hint never starts an agent itself.
    def member_selector
      @member_selector ||= MemberModelSelector.new(
        connection: @connection, project_root: @state.fetch("project_root"),
        pool: candidate_pool, evidence_cache: evidence_cache, advisor: @advisor,
        route_cost_inputs: route_cost_inputs
      )
    end

    # One task-scoped builder shared by both selectors. It reads only this
    # task's inputs file and prices candidates from the project route store,
    # so a whole-project or other-task prediction can never stand in for this
    # unit's future calls.
    def route_cost_inputs
      @route_cost_inputs ||= RouteCostInputs.new(
        record: @record, store: RouteResourceStore.new(project_root: @state.fetch("project_root"))
      )
    end

    def candidate_pool
      @candidate_pool ||= ModelCandidatePool.new
    end

    def evidence_cache
      @evidence_cache ||= ModelEvidenceCache.new
    end

    def work_units
      WorkUnitStore.new(@record)
    end

    def ready_work_unit
      units = work_units.list
      input = @record.input_digest(@state)
      units.find do |unit|
        %w[declared rejected failed].include?(unit["status"]) &&
          unit["input_digest"] == input && unit["artifact_root"] == artifact_root &&
          Array(unit["dependencies"]).all? { |id| units.any? { |dep| dep["id"] == id && dep["status"] == "accepted" } }
      end
    end

    def member_selection_state(artifact_digest, host)
      @record.inputs(@state).merge(
        "workspace" => @state["workspace"], "input_digest" => @record.input_digest(@state),
        "artifact_digest" => artifact_digest,
        "user_boundary" => @state["last_user_message_id"],
        "user_message_id" => host["last_turn_user_message_id"] || @state["last_user_message_id"]
      )
    end

    def stage_delegation(artifact_digest, now, host:)
      return if @state["members"].any? { |member| member["model_drift"] }

      unit = ready_work_unit
      return unless unit

      id = unit.fetch("id")
      selection = member_selector.assess(
        state: member_selection_state(artifact_digest, host), work_unit: unit,
        previous: @state["member_selections"][id]
      )
      signature = selection.fetch("signature")
      unless selection["reused"] == true
        Array(selection["judgments"]).each do |receipt|
          accumulate_jev_usage("jev_member_#{receipt['phase']}", receipt["usage"], receipt: receipt)
        end
        selection = selection.merge(
          "work_unit_id" => id, "input_digest" => unit["input_digest"],
          "artifact_root" => unit["artifact_root"], "at" => Time.at(now).utc.iso8601,
          "user_boundary" => @state["last_user_message_id"],
          "user_message_id" => host["last_turn_user_message_id"] || @state["last_user_message_id"]
        )
        @state["member_selections"][id] = selection
        @state["delegation_assessments"][signature] = selection
        @state["jev"] = (@state["jev"] || {}).merge("delegation" => selection)
        @record.event("member_selection_assessed", selection.slice(
          "version", "signature", "work_unit_id", "decision", "reason", "recommendation", "judgments"
        ))
        save
      end
      return unless selection["decision"] == "recommended" && selection.dig("recommendation", "first")
      return if @state.dig("delegation_hints", signature)

      first = selection["candidates"].find { |candidate| candidate["agent"] == selection.dig("recommendation", "first") }
      return unless first && first["recommendation_hold"] != true

      backups = selection["candidates"].select { |candidate| Array(selection.dig("recommendation", "backups")).include?(candidate["agent"]) }
      @pending_hint = selection.slice("version", "signature", "work_unit_id", "input_digest", "artifact_root", "at",
                                      "user_boundary", "user_message_id").merge(
        "decision_version" => ModelQualityPolicy::DECISION_VERSION,
        "input_version" => ModelQualityPolicy::INPUT_VERSION,
        "dispatch_attempt" => Array(unit["dispatches"]).length + 1,
        "recommendation" => { "first" => first, "backups" => backups },
        "work_unit" => unit.slice("id", "objective", "scope", "acceptance", "escalation"),
        "judgments" => selection["judgments"], "order" => selection["order"]
      )
    rescue WorkUnitStore::Error, ModelCandidatePool::Error => error
      @record.event("member_selection_unavailable", "reason" => error.message)
    end

    # Supplementary model evidence is optional and keyed by its own exact
    # identity. CLI validation/cache writes happen before this command arrives;
    # a submission changes the selector signature, never an OMP billing route.
    # There is no Root/all-candidate proof prerequisite and no time-field ask.
    def apply_model_evidence(command, now:)
      entries = Array(command["entries"]).select { |entry| entry.is_a?(Hash) }
      @record.event("model_evidence_submitted", "entries" => entries.length)
      @state["model_evidence_updated_at"] = Time.at(now).utc.iso8601
      @pending_hint = nil
      hint = @state["delegation_hint"]
      if hint.is_a?(Hash) && hint["followed"] != true
        hint["invalid_reason"] = "model_evidence_changed"
      end
      save
    end

    def observation_stale?(host, artifact_digest, latest_host, latest_digest, now)
      latest_host["interrupted"] || latest_host["status"] != host["status"] ||
        host_digest(latest_host) != host_digest(host) || latest_digest != artifact_digest || now >= @next_check
    end

    def hint_work_unit(hint)
      unit = work_units.read(hint["work_unit_id"])
      return nil unless unit && unit["input_digest"] == @record.input_digest(@state) &&
                        unit["artifact_root"] == artifact_root && hint["input_digest"] == unit["input_digest"] &&
                        hint["artifact_root"] == unit["artifact_root"]

      unit
    rescue WorkUnitStore::Error
      nil
    end

    def candidate_recommendation_text(hint)
      first = hint.fetch("recommendation").fetch("first")
      unit = hint.fetch("work_unit")
      lines = +"Orbit model recommendation (not a new user instruction).\n"
      lines << "Work unit #{unit['id']}: #{unit['objective']}\n"
      lines << "First choice: #{first['agent']} (model #{first['model']}; task-fit heuristic, #{first['quality_basis']}).\n"
      backups = hint.dig("recommendation", "backups")
      lines << "Backups: #{backups.map { |candidate| "#{candidate['agent']} (#{candidate['model']})" }.join('; ')}\n" unless backups.empty?
      lines << "This is a reviewed task-fit judgment, not a reliability guarantee. Unknown token cost is unknown. "
      lines << "Use this unit's declared context, scope and acceptance. To dispatch, select the named native task agent "                "and include orbit-unit: #{unit['id']} in its task. The host must bind the actual member and model to this unit. "                "Collect with hub, verify the result, record acceptance or rejection, and integrate it. "                "Root may decline or choose another authorized agent; that is Root's choice."
      lines
    end

    def deliver_pending_hint
      hint = @pending_hint
      @pending_hint = nil
      unit = hint && hint_work_unit(hint)
      return unless unit
      return if @state.dig("delegation_hints", hint.fetch("signature"))
      return unless %w[declared rejected failed].include?(unit["status"]) &&
                    unit["dispatches"].length + 1 == hint["dispatch_attempt"]

      sent = @connection.send_message(candidate_recommendation_text(hint))
      delivered = hint.merge("message_id" => sent.fetch("id"))
      @state["sent_message_ids"] << sent.fetch("id")
      @state["delegation_hints"][hint.fetch("signature")] = delivered
      @state["delegation_hint"] = delivered
      @record.event("delegation_recommendation_delivered", "signature" => hint["signature"],
                    "work_unit_id" => hint["work_unit_id"], "first" => hint.dig("recommendation", "first"),
                    "backups" => hint.dig("recommendation", "backups"))
      save
    rescue StandardError => error
      @record.event("delegation_hint_failed", "error" => error.message)
      save
    end

    def current_delegation_hint
      hint = @state["delegation_hint"]
      return nil unless hint.is_a?(Hash) && hint["version"] == MemberModelSelector::VERSION &&
                        hint["followed"] != true && !hint["invalid_reason"]
      return nil unless hint["user_boundary"] == @state["last_user_message_id"] && hint_work_unit(hint)

      hint
    end

    # Actual unit binding, member id, call id and model must all match. A model
    # match or temporal proximity alone never proves a hint was followed.
    def delegation_basis(member = nil, hint: current_delegation_hint)
      return "root_without_hint" unless member.is_a?(Hash) && hint

      unit = hint_work_unit(hint)
      return "root_without_hint" unless unit && hint["dispatch_attempt"].is_a?(Integer) &&
        unit["dispatches"].length == hint["dispatch_attempt"] &&
        unit["dispatches"].last["hint_signature"] == hint["signature"] &&
        unit["dispatches"].last["hint_message_id"] == hint["message_id"] &&
        unit["member_id"] == member["thread_id"] &&
        unit["tool_call_id"] == member["tool_call_id"] && unit["model"] == member["model"] &&
        !member["model_drift"]

      recommendation = hint["recommendation"]
      candidates = [recommendation["first"], *Array(recommendation["backups"])]
      candidates.any? { |candidate| candidate["model"] == member["model"] } ? "orbit_hint" : "root_without_hint"
    end

    def confirm_pending_member_hint(member)
      return false if member["delegation_basis"] == "orbit_hint"
      return false unless delegation_basis(member) == "orbit_hint"

      member["delegation_basis"] = "orbit_hint"
      mark_delegation_hint_followed(member)
      true
    end

    def mark_delegation_hint_followed(member)
      hint = current_delegation_hint
      return unless hint && delegation_basis(member, hint: hint) == "orbit_hint"

      hint["followed"] = true
      hint["followed_member_id"] = member["thread_id"]
      hint["followed_tool_call_id"] = member["tool_call_id"]
      member["work_unit_id"] = hint["work_unit_id"]
      @record.event("delegation_hint_followed", "work_unit_id" => hint["work_unit_id"],
                    "thread_id" => member["thread_id"], "tool_call_id" => member["tool_call_id"], "model" => member["model"])
    end

    # OMP 18.2.8 AgentRegistry.register defaults to running. idle is also the
    # live-but-not-running state, so idle alone is not a finished task.
    # markResultAccepted stamps lifecycle.acceptedAt; history.outputPath is the
    # durable artifact. parked can be a later release of a finished ref.
    def observe_omp_native_member(member)
      return unless @connection.respond_to?(:member_state) && @connection.respond_to?(:member_result)
      return if member["status"] == "refused"
      # Model drift is a hard veto (ADR-009): a drifted member is never
      # observed into a result or a completion transition.
      return if member["model_drift"]

      observed = @connection.member_state(member["thread_id"])
      if observed.is_a?(Hash) && observed["model"].is_a?(String) && !observed["model"].empty?
        member["model"] = observed["model"]
      end
      registry_status = observed.is_a?(Hash) ? observed["registry_status"] : nil
      result = @connection.member_result(member["thread_id"])
      observed_change = apply_native_member_observation!(member, registry_status, result, observed)
      hint_change = confirm_pending_member_hint(member)
      save if observed_change || hint_change
    rescue StandardError => error
      member["bridge_error"] = error.message
      @record.event("native_member_bridge_failed", "thread_id" => member["thread_id"], "error" => error.message)
      save
    end

    def apply_native_member_observation!(member, registry_status, result, observed = nil)
      # The drift veto lives here too, not only in the caller: whatever
      # later feeds this method, a drifted member can never become completed
      # or record a success delivery.
      return false if member["model_drift"]

      previous = member.slice("model", "result", "output_path", "session_file",
                              "registry_status", "accepted_at", "status", "result_delivery",
                              "last_turn_error", "settlement_basis", "settlement_history", "error")
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
      if observed.is_a?(Hash) && observed["session_file"].is_a?(String) && !observed["session_file"].empty?
        member["session_file"] = observed["session_file"]
      end
      if observed.is_a?(Hash) && observed.key?("last_turn_error")
        # Observed state, not a partial report: an explicit null means the
        # branch's latest assistant turn is NOT an error, so the stale fact
        # must be cleared. Only a missing key means unknown (keep old).
        fresh_error = observed["last_turn_error"]
        member["last_turn_error"] = fresh_error.is_a?(Hash) ? fresh_error : nil
      end
      # A settled member that shows a real new turn, a re-bound dispatch or a
      # newer turn error loses its settlement first: settlement is always
      # current, and a re-dispatch or new turn never borrows an old verdict.
      invalidate_member_settlement!(member, observed)
      if member["registry_status"] == "aborted"
        member["status"] = "failed"
      elsif native_result_accepted?(member, observed)
        member["status"] = "completed"
      else
        settle_member_from_current_dispatch(member, observed, result)
      end
      accepted_changed = member["accepted_at"] != previous_accepted
      became_completed = member["status"] == "completed" && previous_status != "completed"
      if became_completed || (member["status"] == "completed" && accepted_changed)
        member["result_delivery"] ||= "native_task"
        @record.event("member_result_recorded", "thread_id" => member["thread_id"],
                      "status" => member["status"], "delivery" => member["result_delivery"],
                      "accepted_at" => member["accepted_at"])
      end
      %w[model result output_path session_file registry_status accepted_at status result_delivery
         last_turn_error settlement_basis settlement_history error].any? { |key| member[key] != previous[key] }
    end

    # acceptedAt is stamped only when the driver accepts the run. A later
    # running/streaming ref has not accepted this observation. An acceptedAt
    # identical to an already invalidated settlement is that same stale native
    # fact (detached snapshot / stored lifecycle), never a new acceptance.
    def native_result_accepted?(member, observed)
      return false unless member["accepted_at"]
      return false if member["registry_status"] == "running"
      return false if observed.is_a?(Hash) && observed["streaming"] == true
      return false if Array(member["settlement_history"]).any? do |entry|
        entry.is_a?(Hash) && entry["accepted_at"] == member["accepted_at"]
      end

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
      # An unresolved drift blocks new automatic hints: Root must explicitly
      # re-select; Orbit neither switches models nor re-hints on its own.
      return true if member["model_drift"]
      return true if %w[starting working].include?(member["status"])
      return false unless member["adapter"] == OMP_NATIVE_ADAPTER
      return false if MEMBER_SETTLED.include?(member["status"])

      true
    end

    # Settlement invalidation: an already settled member that shows a real new
    # turn (running/streaming/in-flight tools), a newer native turn error, or
    # whose bound dispatch identity changed (re-bind) is no longer settled.
    # The old settlement moves to settlement_history; native accepted_at is
    # kept there as history because the SDK clears lifecycle per run.
    def invalidate_member_settlement!(member, observed)
      return false unless MEMBER_SETTLED.include?(member["status"])

      reasons = []
      if member["registry_status"] == "running" ||
         (observed.is_a?(Hash) && (observed["streaming"] == true ||
          (observed["active_tools"].is_a?(Integer) && observed["active_tools"] > 0)))
        reasons << "new_turn_observed"
      end
      basis = member["settlement_basis"]
      settled_at = basis.is_a?(Hash) ? basis["settled_at"] : member["accepted_at"]
      error = current_native_turn_error(member)
      error_at = time_value(error.is_a?(Hash) ? error["at"] : nil)
      settled_epoch = time_value(settled_at)
      # Only a DIFFERENT native error is newer evidence. The same error this
      # settlement already recorded must not look like a fresh one just
      # because its stamp sits after the settlement moment — compared by the
      # FULL native structure (message id, provider/model, stop reason,
      # status, message), never by text+time alone.
      same_settled_error = basis.is_a?(Hash) && basis["error"] == error
      if error_at && settled_epoch && error_at > settled_epoch && !same_settled_error
        reasons << "newer_turn_error"
      end
      if basis.is_a?(Hash) && basis["tool_call_id"]
        # Invalidation compares the REAL dispatch identity only: an input or
        # artifact-root version move is evidence-eligibility, not a new
        # execution, so it never revokes a finished execution fact. A truly
        # re-bound/changed attempt (different latest dispatch) still does.
        dispatch = current_member_dispatch(member, require_current_binding: false)
        if dispatch.nil? || dispatch["tool_call_id"] != basis["tool_call_id"] ||
           dispatch["finished_at"] != basis["finished_at"]
          reasons << "dispatch_changed"
        end
      end
      return false if reasons.empty?

      (member["settlement_history"] ||= []) << {
        "source" => basis.is_a?(Hash) ? basis["source"] : (member["accepted_at"] ? "native_accepted_at" : member["result_delivery"]),
        "tool_call_id" => basis.is_a?(Hash) ? basis["tool_call_id"] : member["tool_call_id"],
        "finished_at" => basis.is_a?(Hash) ? basis["finished_at"] : nil,
        "accepted_at" => member["accepted_at"], "result_delivery" => member["result_delivery"],
        "invalidated_at" => Time.now.utc.iso8601, "reasons" => reasons
      }
      member["settlement_basis"] = nil
      member["accepted_at"] = nil
      member["result_delivery"] = nil
      member["status"] = "registered"
      @record.event("member_settlement_invalidated", "thread_id" => member["thread_id"], "reasons" => reasons)
      true
    end

    # Cross-source time ordering. SDK registry milestones are milliseconds
    # since epoch (Date.now()); ISO 8601 strings may or may not carry
    # fractional seconds, so string forms never compare lexicographically.
    # Unparseable values return nil — callers must treat unknown as "cannot
    # affirm current", never as passing.
    def time_value(value)
      case value
      when Numeric then value / 1000.0
      when String then Time.parse(value).to_f unless value.empty?
      end
    rescue ArgumentError
      nil
    end

    # Restores the member's current unit association from the durable
    # work-unit records when the member record never carried one: Root
    # self-selected dispatches are not hint-followed, so nothing ever syncs
    # `work_unit_id` (real 02a5eda7 Zenmux member). Exact identity only — the
    # same actual member id AND tool call as the unit's LATEST dispatch. A
    # dispatch/member model mismatch inside that identity is drift, and an
    # ambiguous match (more than one unit) stays unresolved; never attributed
    # by similar model, time proximity or adjacent events. `require_current_binding`
    # separates the real dispatch identity from current input/artifact
    # eligibility: identity consumers pass false, evidence consumers keep the
    # default.
    def resolve_member_unit_id(member, require_current_binding: true)
      return nil if member["model_drift"]
      thread = member["thread_id"].to_s
      call = member["tool_call_id"].to_s
      return nil if thread.empty? || call.empty?

      current_input = @record.input_digest(@state) if require_current_binding
      matches = work_units.list.select do |unit|
        next false unless unit.is_a?(Hash)
        if require_current_binding
          next false unless unit["input_digest"] == current_input && unit["artifact_root"] == artifact_root
        end
        latest = Array(unit["dispatches"]).last
        next false unless latest.is_a?(Hash) && latest["member_id"] == thread && latest["tool_call_id"] == call
        dispatch_model = latest["model"].to_s
        member_model = member["model"].to_s
        next false if !dispatch_model.empty? && !member_model.empty? && dispatch_model != member_model

        true
      end
      matches.length == 1 ? matches.first["id"] : nil
    rescue WorkUnitStore::Error
      nil
    end

    # The member's current dispatch attempt: the latest dispatch of its bound
    # work unit, matched by actual member id and tool call. An older attempt
    # (re-bound unit) or another member's attempt is never current. With the
    # default `require_current_binding` the unit must also still sit on the
    # current input version and artifact root — that half is the CURRENT
    # EVIDENCE ELIGIBILITY, not the execution identity; a version move alone
    # never invents a new execution.
    def current_member_dispatch(member, require_current_binding: true)
      unit_id = member["work_unit_id"].to_s
      unit_id = resolve_member_unit_id(member, require_current_binding: require_current_binding).to_s if unit_id.empty?
      call = member["tool_call_id"].to_s
      return nil if unit_id.empty? || call.empty?

      unit = work_units.read(unit_id)
      return nil unless unit.is_a?(Hash)
      if require_current_binding
        return nil unless unit["input_digest"] == @record.input_digest(@state)
        return nil unless unit["artifact_root"] == artifact_root
      end

      latest = Array(unit["dispatches"]).last
      return nil unless latest.is_a?(Hash) && latest["member_id"] == member["thread_id"] &&
                        latest["tool_call_id"] == call

      latest
    rescue WorkUnitStore::Error
      nil
    end

    # Execution-settled means no real work in flight: not running, not
    # streaming, no observed tools. A live session with an unknown tool count
    # is not provably settled; a detached ref has no in-flight tools to wait
    # on (the stop barrier remains the async-job authority).
    def member_execution_settled?(member, observed)
      return false if member["registry_status"] == "running"

      observed = {} unless observed.is_a?(Hash)
      return false if observed["streaming"] == true
      tools = observed["active_tools"]
      return false if tools.is_a?(Integer) && tools > 0
      return false if tools.nil? && observed["session_attached"] == true

      true
    end

    # Owner-scoped async jobs must be PROVABLY empty. The SDK snapshot shape is
    # {running, recent, delivery}; a missing getter, a null snapshot (manager
    # absent) or any unknown shape never proves "nothing in flight", so the
    # caller keeps the manual path instead of unlocking a retry.
    def async_jobs_settled?(observed)
      jobs = observed.is_a?(Hash) ? observed["async_jobs"] : nil
      return false unless jobs.is_a?(Hash)

      running = jobs["running"]
      running.is_a?(Array) && running.empty?
    end

    # The same-unit auto-release demands ACTUAL values, not tolerated
    # unknowns: the settlement helper (member_execution_settled?) may accept a
    # null streaming flag or an absent active_tools count for history reasons,
    # but unlocking a retry never rests on an unknown. The registry status
    # must be the KNOWN idle observation (SDK AgentStatus; null, parked or any
    # other unknown keeps the manual Root finish), streaming must be
    # literally false, active_tools must be literally 0, and the owner-scoped
    # async snapshot must carry a real empty running list.
    def provably_idle_for_auto_release?(member, observed)
      return false unless member["registry_status"] == "idle"
      return false unless observed.is_a?(Hash)
      return false unless observed["streaming"] == false
      return false unless observed["active_tools"] == 0

      async_jobs_settled?(observed)
    end

    # Atomic exact-dispatch failure fact. All ownership checks (unit still
    # bound, latest dispatch member+tool call exactly matching this member's
    # current attempt, no Root verdict overwritten) live inside the store's
    # lock; this method only supplies the identity and the real native error.
    def record_program_execution_failure(member, identity, error)
      call = identity["tool_call_id"].to_s
      return nil if call.empty?

      work_units.record_execution_failure(member_id: member["thread_id"], tool_call_id: call,
                                          error: error, model: member["model"])
    rescue WorkUnitStore::Error => failure
      @record.event("work_unit_execution_failure_rejected", "thread_id" => member["thread_id"],
                    "tool_call_id" => call, "reason" => failure.message.to_s[0, 200])
      nil
    end

    # A real native error fact for the member's current turn: the bridge's
    # structured last_turn_error whose turn is not older than the dispatch
    # binding (or the member registration when no dispatch exists).
    def current_native_turn_error(member, dispatch = nil)
      error = member["last_turn_error"]
      return nil unless error.is_a?(Hash) && error["stop_reason"] == "error"

      at = error["at"]
      floor = dispatch.is_a?(Hash) ? dispatch["bound_at"] : member["registered_at"]
      at_epoch = time_value(at)
      floor_epoch = time_value(floor)
      # Unknown or malformed time evidence never affirms a current turn:
      # only two parseable stamps ordered as current qualify.
      return nil unless at_epoch && floor_epoch
      return nil if at_epoch < floor_epoch

      error
    end

    # Real native delivery for THIS dispatch: the member's persisted task
    # output, keyed to the dispatch by the file's real mtime. Result text is
    # read from that same file by the bridge, so the freshness rule is
    # uniform; without a fresh file there is no provable delivery.
    def current_dispatch_delivery(result, dispatch)
      return nil unless result.is_a?(Hash) && dispatch.is_a?(Hash)

      path = result["output_path"]
      mtime = result["output_mtime"]
      size = result["output_size"]
      text = result["output_text"]
      return nil unless path.is_a?(String) && !path.empty? && mtime.is_a?(String) && !mtime.empty?
      bound = dispatch["bound_at"]
      bound_epoch = time_value(bound)
      mtime_epoch = time_value(mtime)
      # Freshness must be provable: a missing or malformed stamp cannot
      # affirm that the persisted output belongs to this dispatch.
      return nil unless bound_epoch && mtime_epoch
      return nil if mtime_epoch < bound_epoch
      return nil unless (size.is_a?(Integer) && size > 0) || (text.is_a?(String) && !text.empty?)

      { "output_path" => path, "output_mtime" => mtime }
    end

    # Ranked settlement (contract 成员结算), layered by evidence class.
    # EXECUTION FACT: a real native turn error on the member's actual dispatch
    # identity (actual member id + tool call + latest attempt) settles failed
    # even when the input/artifact version later moved — the execution ended,
    # and that fact keeps its own source. A real CURRENT native acceptance
    # (SDK lifecycle acceptedAt) is likewise an execution-acceptance fact and
    # settles through its own path in apply_native_member_observation!
    # WITHOUT this binding requirement. EVIDENCE ELIGIBILITY: this method's
    # business path (Root accepted/rejected for the first time from the
    # dispatch fallback) settles only against the CURRENT input/artifact
    # binding with real delivery; a version move alone never invents a new
    # execution, and neither an old business verdict nor a bare acceptance
    # grants current-version coverage or ready. Anything unprovable stays
    # registered.
    def settle_member_from_current_dispatch(member, observed, result)
      return false unless member["status"] == "registered"

      identity = current_member_dispatch(member, require_current_binding: false)
      return false unless identity.is_a?(Hash)
      return false unless member_execution_settled?(member, observed)

      error = current_native_turn_error(member, identity)
      if error
        detail = ["native turn error"]
        detail << "HTTP #{error['error_status']}" if error["error_status"].is_a?(Integer)
        detail << error["error_message"].to_s
        member["status"] = "failed"
        member["error"] = detail.join(": ").strip[0, 300]
        member["result_delivery"] = "native_turn_error"
        member["settlement_basis"] = { "source" => "native_turn_error",
                                       "tool_call_id" => identity["tool_call_id"],
                                       "finished_at" => identity["finished_at"],
                                       "settled_at" => Time.now.utc.iso8601, "error" => error }
        @record.event("member_settled", "thread_id" => member["thread_id"], "status" => "failed",
                      "source" => "native_turn_error", "tool_call_id" => identity["tool_call_id"])
        # A program-observed EXECUTION failure may also release the SAME unit
        # for a new attempt — but only with provably idle evidence: an actual
        # non-streaming turn, an actual zero active-tool count, a non-running
        # registry and a real owner-scoped async snapshot whose running list
        # is empty. Any unknown keeps the unit bound and the manual Root
        # finish path.
        record_program_execution_failure(member, identity, error) if provably_idle_for_auto_release?(member, observed)
        return true
      end

      # Business verdicts require the current evidence binding.
      dispatch = current_member_dispatch(member)
      return false unless dispatch.is_a?(Hash)
      return false unless WorkUnitStore::FINISH_STATUSES.include?(dispatch["status"])

      # A settlement invalidated by a real new turn must not be reborn from
      # the same finished dispatch: without a NEW Root finish or a new native
      # acceptance, the old verdict cannot settle the member's current turn.
      return false if Array(member["settlement_history"]).any? do |entry|
        entry.is_a?(Hash) && entry["tool_call_id"] == dispatch["tool_call_id"] &&
          entry["finished_at"] == dispatch["finished_at"] &&
          Array(entry["reasons"]).include?("new_turn_observed")
      end

      delivery = current_dispatch_delivery(result, dispatch)
      return false unless delivery

      member["status"] = dispatch["status"] == "accepted" ? "completed" : "rejected"
      member["result_delivery"] = dispatch["status"] == "accepted" ? "work_unit_acceptance" : "work_unit_rejected"
      member["settlement_basis"] = { "source" => member["result_delivery"],
                                     "tool_call_id" => dispatch["tool_call_id"],
                                     "finished_at" => dispatch["finished_at"],
                                     "settled_at" => Time.now.utc.iso8601, "delivery" => delivery }
      @record.event("member_settled", "thread_id" => member["thread_id"], "status" => member["status"],
                    "source" => member["result_delivery"], "tool_call_id" => dispatch["tool_call_id"])
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
        case event["kind"]
        when "ask_interrupted"
          changed = true if record_ask_interrupt(event)
        when "ask_resolved"
          changed = true if resolve_ask_interrupts(event)
        else
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

      @state["members"].all? { |member| MEMBER_SETTLED.include?(member["status"]) }
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
        # Only a real user message moves the user boundary. Messages Orbit
        # itself delivered (initial instruction, hints, steers) are precisely
        # recorded in sent_message_ids or flagged internal by the host; moving
        # the boundary past them would invalidate the very hint whose delivery
        # caused the scan. Skipped messages are re-seen by later scans and
        # skipped again, so no separate scan cursor is needed.
        internal = message["internal"] || @state["sent_message_ids"].include?(message.fetch("id"))
        next if internal
        # A new question is not an amendment. Only the explicit amend
        # command changes the checked input; leave the native message in
        # the Root session for it to assign to this task or handle separately.
        @state["unassigned_user_message_id"] = message.fetch("id")
        @record.event("user_message_unassigned", "message_id" => message.fetch("id"))
        @state["last_user_message_id"] = message.fetch("id")
      end
      save unless messages.empty?
      true
    end

    # A native reply to another user question does not become this task's
    # delivery. Older host doubles omit the origin field; the installed OMP
    # bridge supplies it, and an unprovable origin is never auto-attributed.
    def task_turn_attributed?(host)
      return true unless host.key?("last_turn_user_message_id")

      id = host["last_turn_user_message_id"]
      return false if id.nil?

      id == @state.dig("instruction_source", "id") ||
        @state.fetch("sent_message_ids").include?(id) ||
        @state.fetch("amendments").any? { |amendment| amendment.dig("source", "id") == id }
    end

    def record_task_delivery(host)
      return unless task_turn_attributed?(host) && host["last_turn_id"]
      return if @state.dig("task_delivery", "turn_id") == host["last_turn_id"]

      text = Array(host["observations"]).reverse.find { |entry| entry.is_a?(Hash) && entry["kind"] == "agent_message" }
      answer = text && text["text"].to_s
      input_digest = @record.input_digest(@state)
      digest = fingerprint_artifact
      previous = @state["task_delivery"]
      prior_turns = if previous.is_a?(Hash) && previous["input_digest"] == input_digest &&
                       previous["artifact_root"] == artifact_root && previous["artifact_digest"] == digest
                      (Array(previous["prior_turns"]) + [previous.slice("turn_id", "text")]).last(3)
                    else
                      []
                    end
      @state["task_delivery"] = {
        "turn_id" => host["last_turn_id"], "input_digest" => input_digest,
        "artifact_root" => artifact_root, "artifact_digest" => digest,
        "observation" => ObservationKey.host_material(host), "prior_turns" => prior_turns,
        "text" => answer && "#{answer[0, 4000]}#{answer.length > 4000 ? "…[#{answer.length}:#{Digest::SHA256.hexdigest(answer)}]" : ""}"
      }
      save
    end

    def task_observation_host(host, input_digest)
      delivery = @state["task_delivery"]
      return host unless delivery.is_a?(Hash) && delivery["input_digest"] == input_digest &&
                         delivery["artifact_root"] == artifact_root &&
                         delivery["observation"].is_a?(Hash)

      observed = delivery["observation"]
      { "status" => host["status"], "last_turn_id" => observed["last_turn_id"],
        "last_turn_status" => observed["last_turn_status"], "observations" => observed["observations"] }
    end

    def task_delivery_for(snapshot, input_digest)
      delivery = @state["task_delivery"]
      return nil unless delivery.is_a?(Hash) && delivery["input_digest"] == input_digest &&
                        delivery["artifact_root"] == artifact_root &&
                        delivery["artifact_digest"] == snapshot["digest"]

      delivery.slice("turn_id", "text", "prior_turns", "input_digest", "artifact_digest")
    end

    def start_check(host, now, kind: "artifact", trigger:, manual: false)
      role = @state["dispute"] ? "adjudicator" : kind == "process" ? "process_reviewer" : "reviewer"
      digest = fingerprint_artifact
      input_digest = @record.input_digest(@state)
      failed = @state.dig("review", "failed_models")
      if failed && (failed["artifact_digest"] != digest || failed["input_digest"] != input_digest)
        @state["review"].delete("failed_models")
        @state["review"].delete("blocked")
      end
      if (block = @state.dig("review", "blocked"))
        if block["type"] == "selection_undecided" && block_signature_changed?(block)
          @state["review"].delete("blocked")
          @record.event("checker_model_block_cleared", "reason" => "selection inputs changed")
        else
          @record.event("check_request_blocked", "type" => block["type"], "manual" => manual) if manual
          @state["next_check_manual"] = false
          schedule_check(now + @interval, "检查模型不可用：等待 OMP 模型状态变化或 Root 重选", trigger: "timer")
          return false
        end
      end
      if @checker.respond_to?(:select_model!)
        return false unless apply_checker_selection!(role, now)
      end
      key = ObservationKey.build(
        input_digest: input_digest, artifact_root: artifact_root, artifact_digest: digest,
        host: kind == "artifact" ? task_observation_host(host, input_digest) : host,
        findings: @state.fetch("findings"), dispute: @state["dispute"],
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
      if !manual && trigger != "model_fallback" && prior
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
      task_git = kind == "artifact" ? TaskGitEvidence.capture(
        workspace: artifact_root, baseline_head: @state.dig("workspace", "artifact", "head"),
        snapshot_head: snapshot["git_head"]
      ) : nil
      scope = {
        "number" => number, "role" => role, "kind" => kind, "artifact_root" => artifact_root,
        "observation_key" => key, "trigger_cause" => trigger, "manual" => manual,
        "snapshot" => snapshot, "input_digest" => input_digest, "host_digest" => host_digest(host),
        "dispute" => @state["dispute"],
        "started_at" => Time.at(now).utc.iso8601
      }
      @record.write("checks/#{number}/scope.json", JSON.pretty_generate(scope))
      @checker.start(
        directory: snapshot.fetch("snapshot_path"), inputs: @record.inputs(@state),
        context: {
          "root" => host.reject { |key, _| key == "root_verifications" }
                        .merge("last_turn_task_attributed" => task_turn_attributed?(host)),
          "task_delivery" => task_delivery_for(snapshot, input_digest),
          "root_verifications" => root_verifications_for(host, snapshot, input_digest),
          "task_git" => task_git, "findings" => @state.fetch("findings"),
          "recent_events" => recent_events, "check_history" => check_history_for(snapshot), "recheck" => clues,
          "execution_members" => @state["members"],
          "takeover" => takeover_context_projection,
          "decisions" => @state.fetch("decisions"), "dispute" => @state["dispute"],
          "model_selection" => @state.dig("jev", "delegation"),
          "work_units" => work_units.list,
          "estimate" => @state.fetch("estimate"), "hard_deadline" => @state["hard_deadline"],
          "elapsed_seconds" => now - Time.parse(@state.fetch("created_at")).to_f,
          "project_rules" => snapshot.fetch("project_rules"),
          "git_remote" => GitRemoteEvidence.capture(workspace: artifact_root,
                                                      instruction: effective_checker_instruction),
          "review_focus" => review_focus(snapshot.fetch("manifest")),
          "uncopied_entries" => snapshot.fetch("manifest").select do |entry|
            %w[gitlink other].include?(entry["kind"]) || entry["materialized"] == false
          end
        }, output_dir: directory, role: role
      )
      @running_check = scope
      # Resumed historical tasks adopt the new gate only when they actually
      # run a current check; old completed records are not retroactively passed.
      @state["coverage_required"] = true
      @state["next_check_manual"] = false
      @state["check_observations"][key] = {
        "status" => "in_flight", "check" => number, "stale" => nil,
        "trigger_cause" => trigger, "manual" => manual, "started_at" => Time.at(now).utc.iso8601
      }
      @last_full_check_digest = snapshot.fetch("digest") if kind == "artifact"
      @state.delete("observation_pending")
      @record.event("check_started", "number" => number, "role" => role, "kind" => kind,
                    "trigger" => trigger, "manual" => manual, "model" => @state.dig("review", "model"),
                    "artifact_root" => artifact_root, "artifact_digest" => snapshot.fetch("digest"),
                    "input_digest" => scope["input_digest"])
      save
      true
    end

    # Tests inject a stub; production builds the real selector on first use.
    def checker_selector
      @checker_selector ||= CheckerModelSelector.new(
        connection: @connection, project_root: @state.fetch("project_root"),
        pool: candidate_pool, evidence_cache: evidence_cache, advisor: @advisor,
        route_cost_inputs: route_cost_inputs
      )
    end

    # Before each new independent check, prefer the runnable pool intersection
    # and fall back to the OMP session catalog when needed. An in-flight check
    # never switches models; the selector signature reuses unchanged judgments.
    def checker_selection_state(role)
      inputs = @record.inputs(@state)
      current = @record.input_digest(@state)
      units = WorkUnitStore.new(@record).list.select do |unit|
        unit["input_digest"] == current && unit["artifact_root"] == artifact_root
      end
      needs = units.map { |unit| unit["model_requirements"] }.select { |item| item.is_a?(Hash) }
      requirements = {}
      %w[relevant_indices required_input_modalities required_output_modalities required_parameters].each do |key|
        values = needs.flat_map { |item| Array(item[key]) }.uniq
        requirements[key] = values unless values.empty?
      end
      contexts = needs.filter_map { |item| item["required_context_tokens"] }
      requirements["required_context_tokens"] = contexts.max unless contexts.empty?
      requirements["require_measurement_date"] = true if needs.any? { |item| item["require_measurement_date"] == true }
      inputs.merge("workspace" => @state["workspace"], "review_role" => role,
                   "acceptance" => units.empty? ? inputs.fetch("instruction") : units.map { |unit| unit["acceptance"] },
                   "acceptance_source" => units.empty? ? "task_instruction" : "work_units",
                   "model_requirements" => requirements,
                   "work_units" => units.map { |unit| unit.slice("id", "objective", "requirements", "acceptance", "status", "result", "verification") })
    rescue WorkUnitStore::Error => error
      raise CheckerModelSelector::Error, "work-unit selection context is unreadable: #{error.message}"
    end

    def apply_checker_selection!(role, now)
      previous = @state.dig("review", "selection")
      model, selection = checker_selector.select(
        explicit: @state.dig("review", "explicit_model"),
        instruction: effective_checker_instruction,
        state: checker_selection_state(role),
        previous: previous,
        selected_for: role,
        excluded: Array(@state.dig("review", "failed_models", "models"))
      )
      # A fresh judgment can select the same model with the same facts. Its
      # invocation is still possible consumption; accounting uses the call id,
      # independently of whether the visible selection changed.
      if selection["judgment_call_id"]
        accumulate_jev_usage("jev_checker_selection", selection["usage"],
                             receipt: checker_judgment_receipt(selection))
      end
      if previous.nil? || previous["model"] != model || previous["signature"] != selection["signature"] ||
         previous["version"] != selection["version"] || previous["source"] != selection["source"] ||
         previous["judgment_call_id"] != selection["judgment_call_id"]
        @state["review"]["selection"] = selection
        @state["review"]["model"] = model if model && !model.to_s.empty?
        @record.event("checker_model_selected", "model" => model, "source" => selection["source"],
                      "selected_for" => role, "selection" => selection)
        if !selection["judgment_call_id"] && (selection["judgment_provider"] || selection["usage"].is_a?(Hash))
          accumulate_jev_usage("jev_checker_selection", selection["usage"],
                               receipt: checker_judgment_receipt(selection))
        end
      end
      @checker.select_model!(model) if model && !model.to_s.empty?
      save
      true
    rescue CheckerModelSelector::Error => error
      # No OMP model remains after availability and failed-attempt checks.
      @state["review"]["blocked"] = { "type" => "selection_undecided", "reason" => error.message,
                                     "signature" => checker_selection_snapshot,
                                     "at" => Time.at(now).utc.iso8601 }
      @record.event("checker_model_blocked", "type" => "selection_undecided", "reason" => error.message)
      notify_checker_block(error.message)
      save
      false
    end

    # Q20: the checker selection judges the currently effective task, so the
    # original instruction and every recorded amendment pass complete with
    # explicit separators (never compressed); a revision changes the selector
    # signature and therefore the next selection.
    def effective_checker_instruction
      inputs = @record.inputs(@state)
      parts = [inputs.fetch("instruction")]
      inputs.fetch("amendments", []).each { |amendment| parts << amendment.fetch("text") }
      parts.join("\n\n--- amendment ---\n\n")
    end

    # A real check failure remains visible. Only the next unused, runnable
    # model may retry this input and artifact; exhausted candidates block.
    def handle_check_failure(error, now)
      scope = @running_check
      capture_check_calls(scope, failed: true)
      @running_check = nil
      @check_result = nil
      kind = @checker.respond_to?(:failure_kind) ? @checker.failure_kind : "unavailable"
      basis = @checker.respond_to?(:failure_basis) ? @checker.failure_basis : "unknown"
      @state.fetch("checks") << scope.slice("number", "role", "kind", "started_at", "observation_key",
                                            "trigger_cause", "manual", "artifact_root", "input_digest").merge(
        "artifact_digest" => scope.dig("snapshot", "digest"),
        "result" => { "verdict" => "check_failed", "error" => error.message,
                      "failure_kind" => kind, "failure_basis" => basis },
        "failed" => true, "stale" => false,
        "finished_at" => Time.at(now).utc.iso8601,
        "usage" => @checker.respond_to?(:usage) ? @checker.usage : nil
      )
      observation = @state.fetch("check_observations")[scope["observation_key"]]
      if observation
        observation["status"] = "failed"
        observation["finished_at"] = Time.at(now).utc.iso8601
      end
      failed = @state["review"]["failed_models"] ||= {
        "input_digest" => scope.fetch("input_digest"),
        "artifact_digest" => scope.dig("snapshot", "digest"), "models" => []
      }
      failed["models"] << @state.dig("review", "model") unless failed["models"].include?(@state.dig("review", "model"))
      @record.event("check_failed", "number" => scope["number"], "model" => @state.dig("review", "model"),
                    "error" => error.message, "failure_kind" => kind, "failure_basis" => basis)
      schedule_check(now, "检查失败后尝试其他 OMP 型号", trigger: "model_fallback", manual: scope["manual"])
      save
    end

    def notify_checker_block(reason)
      text = "Orbit independent checker has no remaining runnable OMP model (not a new user instruction): #{reason}. " \
             "The task stays running and no failed check counts as a final review. " \
             "Root can inspect OMP model availability and use orbit review-model #{@record.path} --model provider/id " \
             "after credentials or models change; otherwise report the blockage."
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
    rescue StandardError => error
      @record.event("checker_block_notify_failed", "error" => error.message)
    end

    # A Root-selected OMP model is checked again by the runtime before it
    # replaces a blocked model; an in-flight checker is never switched.
    def apply_review_model(command, now)
      model = command.fetch("model").to_s.strip
      unless model.match?(%r{\A[^\s/]+/[^\s]+\z})
        @record.event("review_model_rejected", "reason" => "model must be provider/id")
        return
      end
      begin
        _, selection = checker_selector.select(explicit: model,
          instruction: effective_checker_instruction, state: checker_selection_state("reviewer"),
          selected_for: "review_model")
      rescue CheckerModelSelector::Error => error
        @record.event("review_model_rejected", "model" => model, "reason" => error.message)
        return
      end
      @state["review"]["explicit_model"] = model
      @state["review"]["model"] = model
      @state["review"].delete("failed_models")
      if @state.dig("review", "blocked")
        @state["review"].delete("blocked")
        @record.event("checker_model_block_cleared", "reason" => "Root selected an available OMP model")
      end
      @record.event("review_model_recorded", "model" => model, "reason" => command["reason"].to_s,
                    "in_pool" => selection["in_pool"])
      schedule_check(now, "Root 重选 OMP 检查模型", trigger: "review_model", manual: true)
      save
    end

    # A JEV-free signature over pool, OMP catalog, evidence and instruction.
    # Selection blocks only reopen when inputs change, not on a timer.
    def checker_selection_snapshot
      selector = checker_selector
      return selector.snapshot(instruction: effective_checker_instruction) if selector.respond_to?(:snapshot)

      prepared = selector.send(:prepare, effective_checker_instruction)
      prepared.is_a?(Hash) ? prepared["signature"] : nil
    rescue StandardError
      nil
    end

    # An undecided block is reconsidered only when a selection input changes.
    def block_signature_changed?(block)
      current = checker_selection_snapshot
      current.is_a?(String) && block["signature"].is_a?(String) && current != block["signature"]
    end

    def host_digest(host)
      Digest::SHA256.hexdigest(JSON.generate(host.slice("last_turn_id", "last_turn_status", "observations")))
    end

    # Artifact reviews judge the fixed snapshot. A host-only digest change does
    # not expire them or block completion. Process reviews still do.
    def host_digest_stale?(scope, host)
      scope["kind"] != "artifact" && host_digest(host) != scope["host_digest"]
    end

    # Git working-tree added/modified/deleted statuses in the fixed snapshot,
    # not differences from task start: pre-existing untracked files are "added".
    # Tracked and present entries are not a review focus. Each list is capped.
    def review_focus(manifest)
      groups = REVIEW_FOCUS_STATUSES.to_h { |status| [status, []] }
      Array(manifest).each do |entry|
        next unless entry.is_a?(Hash) && groups.key?(entry["status"]) && entry["path"].is_a?(String)
        next if entry["path"].empty?

        groups[entry["status"]] << entry["path"]
      end
      groups.transform_values { |paths| paths.uniq.sort.first(REVIEW_FOCUS_LIMIT) }
    end

    def requirement_coverage_status
      return { "ready" => false, "gap" => @state["requirement_coverage_error"] } if @state["requirement_coverage_error"]

      RequirementCoverage.new(record: @record).status(input_digest: @record.input_digest(@state),
        artifact_digest: fingerprint_artifact, artifact_root: artifact_root)
    end

    # These facts come from the owning native session's tool callbacks, not
    # from a Root-authored proof file. Keep the original binding even after
    # amendments; the current review compares relevance without rewriting it.
    def root_verifications_for(host, snapshot, input_digest)
      Array(host["root_verifications"]).last(32).filter_map do |receipt|
        next unless receipt.is_a?(Hash) && receipt["source"] == "omp_native_tool_result" &&
          receipt["task_directory"] == @record.path &&
          receipt["root_session_id"] == @state.dig("connection", "thread_id")

        cwd_matches = begin
          File.realpath(receipt["execution_cwd"].to_s) == artifact_root
        rescue SystemCallError
          false
        end
        receipt.merge(
          "artifact_matches" => cwd_matches && receipt["artifact_root"] == artifact_root &&
            receipt["artifact_root_at_completion"] == artifact_root && receipt["fingerprint_status"] == "ok" &&
            receipt["artifact_digest"] == snapshot.fetch("digest"),
          "input_matches" => receipt["input_digest"] == input_digest
        )
      end
    end

    def record_requirement_coverage(scope, result, stale)
      coverage = result["coverage"] || { "complete" => false, "items" => [
        { "requirement" => "Original instruction and effective amendments", "status" => "unverified",
          "evidence" => "The checker did not report requirement coverage." }
      ] }
      RequirementCoverage.new(record: @record).record(check_id: scope["number"].to_s,
        role: scope["role"], kind: scope["kind"], coverage: coverage, stale: stale,
        input_digest: scope["input_digest"], artifact_digest: scope.dig("snapshot", "digest"),
        artifact_root: scope["artifact_root"])
      if scope["kind"] == "artifact" && scope["role"] == "reviewer" && !stale
        @state.delete("requirement_coverage_error")
        @state["requirement_coverage"] = requirement_coverage_status
      end
    rescue RequirementCoverage::Error, SystemCallError => error
      @state["requirement_coverage_error"] = error.message if scope["kind"] == "artifact" && scope["role"] == "reviewer"
      @record.event("requirement_coverage_write_failed", "check" => scope["number"], "reason" => error.message)
    end

    def finish_check(result, host, now)
      scope = @running_check
      capture_check_calls(scope)
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
        "artifact_root" => scope["artifact_root"], "artifact_digest" => scope.dig("snapshot", "digest"),
        "input_digest" => scope["input_digest"],
        "finished_at" => Time.at(now).utc.iso8601,
        "usage" => @checker.respond_to?(:usage) ? @checker.usage : nil
      )
      record_requirement_coverage(scope, result, stale)
      observation = @state.fetch("check_observations")[scope["observation_key"]]
      if observation
        observation["status"] = "finished"
        observation["stale"] = stale
        observation["check"] = scope["number"]
        observation["finished_at"] = Time.at(now).utc.iso8601
      end
      @record.event("check_finished", "number" => scope["number"], "stale" => stale,
                    "stale_reasons" => stale_reasons, "verdict" => result.fetch("verdict"),
                    "reason" => result.fetch("reason"), "finding_ids" => result.fetch("findings").map { |finding| finding.fetch("id") },
                    "resolved_ids" => result.fetch("resolved_ids"), "artifact_digest" => scope.dig("snapshot", "digest"),
                    "input_digest" => scope["input_digest"])
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
        @record.event("finding_resolved", "id" => id, "check" => scope["number"],
                      "reason" => result.fetch("reason"), "artifact_digest" => current_digest,
                      "input_digest" => scope["input_digest"])
      end
      accepted_findings = []
      result.fetch("findings").each do |finding|
        previous = @state["findings"][finding.fetch("id")]
        if previous && previous["status"] == "open" &&
           previous["observed_root"] == scope["artifact_root"] &&
           previous["observed_version"] == current_digest &&
           previous["observed_input"] == scope["input_digest"] &&
           %w[requirement evidence action].all? { |field| previous[field] == finding[field] }
          reports = previous["current_reports"].to_i + 1
          previous["current_reports"] = reports
          @record.event("finding_repeat_ignored", "id" => finding.fetch("id"),
                        "reason" => "Already open on the same root, artifact, input, and finding text")
          escalate_repeated_finding(previous, reports, scope, now) if reports >= REPEAT_FINDING_ESCALATION_REPORTS
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
          "observed_input" => scope["input_digest"],
          # A changed binding is a new report cycle: the correction is
          # re-delivered and the repeat counter starts over, so an escalation
          # may only follow after the changed evidence again fails to move.
          "current_reports" => 1
        )
        accepted_findings << finding
        @record.event("finding_recorded", "check" => scope["number"], "finding" => finding,
                      "artifact_digest" => current_digest, "input_digest" => scope["input_digest"])
      end
      notify_finalization_ready(scope, result, host, current_digest, now)
      remind_manual_final_check(scope, result, host, current_digest, now)
      retire_overturned_readiness(scope, result, current_digest)
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

    # The current fixed artifact can disprove an older manual not_ready
    # conclusion. Retire that reason in durable state, but never grant a
    # finalization notice from an adjudicator or an automatic reviewer.
    def retire_overturned_readiness(scope, result, current_digest)
      ready = @state["completion_readiness"]
      return unless ready.is_a?(Hash) && ready["status"] == "not_ready"
      return if ready["check"] == scope["number"]
      return unless scope["kind"] == "artifact" && ready["input_digest"] == scope["input_digest"] &&
                    ready["artifact_root"] == scope["artifact_root"] &&
                    ready["artifact_digest"] == current_digest
      return unless %w[complete continue].include?(result.fetch("verdict")) &&
                    result.fetch("delivery").fetch("ready") && result.fetch("findings").empty? &&
                    @state["recheck"].nil? &&
                    @state["findings"].values.none? { |finding| finding["status"] == "open" }

      origin = scope["role"] == "adjudicator" ? "争议裁定" : "后续独立检查"
      @state["completion_readiness"] = {
        "status" => "review_needed", "reason" => "#{origin}确认交付已存在；仍须当前版本的有效手动终检",
        "artifact_root" => scope["artifact_root"], "artifact_digest" => current_digest,
        "input_digest" => scope["input_digest"]
      }
      @record.event("delivery_not_ready_overturned", "check" => scope["number"],
                    "role" => scope["role"], "artifact_digest" => current_digest,
                    "input_digest" => scope["input_digest"])
    end

    # A clean automatic review can confirm the current delivery is inspectable,
    # but never grants completion. Wake an idle Root once per version to request
    # the required manual final check instead of leaving a delivered task
    # running indefinitely. Findings and unfinished member work take priority.
    def remind_manual_final_check(scope, result, host, current_digest, now)
      return unless scope["kind"] == "artifact" && scope["role"] == "reviewer" && !scope["manual"]
      return unless %w[continue complete].include?(result.fetch("verdict"))
      return unless result.fetch("findings").empty? && result.fetch("delivery").fetch("ready")
      return unless @state["recheck"].nil? && @state["findings"].values.none? { |finding| finding["status"] == "open" }
      return unless members_settled? && host["status"] == "idle" && host["last_turn_status"] == "completed"
      return if @state["next_check_manual"] || @state["pending_finalization"]

      delivery = @state["task_delivery"]
      return unless delivery.is_a?(Hash) && delivery["input_digest"] == scope["input_digest"] &&
                    delivery["artifact_root"] == scope["artifact_root"] &&
                    delivery["artifact_digest"] == current_digest

      key = Digest::SHA256.hexdigest(JSON.generate([scope["artifact_root"], scope["input_digest"], current_digest]))
      @state["manual_check_reminders"] ||= {}
      return if @state["manual_check_reminders"][key]

      # Persist the clean check, resolved findings and matching delivery BEFORE
      # the wake send so the host can verify durable provenance at send time
      # (the outer save happens after this method returns — too late).
      save
      # The integration_check tag marks this single program-purpose send; the
      # host re-verifies every durable fact itself and the tag alone grants no
      # selection authority. The reminder/message_id is recorded only AFTER the
      # real delivery ACK below — never pre-written.
      # Every valid manual-ready reminder carries the same integration
      # responsibility, decoupled from whether a model selection happens: the
      # Root must first re-verify the delivery against the ORIGINAL
      # requirement and spec, run risk-appropriate executable verification for
      # missing evidence or real risks, and fix what it finds — only then
      # request the independent manual final check.
      sent = @connection.send_message("Orbit 过程检查未发现当前交付缺口，但这不是手动终检，也不是任务完成。" \
                                      "请先主动按本任务的原始要求与规格核对当前交付，对照既有验证，对缺证或真实风险做必要可执行验证并修复；" \
                                      "完成后再调用 Orbit action=check, task=<当前任务目录>，结束本轮等待独立终检；" \
                                      "收到有效通知后再申请停止。无需用户重复催办。",
                                      integration_check: scope["number"])
      @state["sent_message_ids"] << sent.fetch("id")
      @state["manual_check_reminders"][key] = { "check" => scope["number"], "message_id" => sent.fetch("id"),
                                                "at" => Time.at(now).utc.iso8601 }
      @record.event("manual_final_check_reminded", "check" => scope["number"], "version" => current_digest)
    end

    # A valid manual reviewer conclusion (`continue`, `correct`, or `complete`
    # with no current findings) cannot itself declare the product task complete.
    # Delivery readiness is a separate, explicit checker decision. A clean
    # finding list must never validate a response that is still to be written.
    def notify_finalization_ready(scope, result, host, current_digest, now)
      return unless scope["kind"] == "artifact" && scope["role"] == "reviewer" && scope["manual"]
      return unless %w[continue correct complete].include?(result.fetch("verdict"))
      return unless result.fetch("findings").empty? && @state["recheck"].nil?
      delivery = result.fetch("delivery")
      unless delivery.fetch("ready")
        reason = delivery.fetch("reason")
        @state["completion_readiness"] = { "status" => "not_ready", "reason" => reason, "check" => scope["number"],
                                           "input_digest" => scope["input_digest"],
                                           "artifact_root" => scope["artifact_root"],
                                           "artifact_digest" => current_digest }
        @record.event("delivery_not_ready", "check" => scope["number"], "reason" => reason)
        sent = @connection.send_message("Orbit 独立检查尚未确认可交付（不是用户新要求）：#{reason}。请先完成实际答复或产物，然后对最终版本重新请求检查；不要申请完成。")
        @state["sent_message_ids"] << sent.fetch("id")
        return
      end
      coverage = requirement_coverage_status if @state["coverage_required"]
      if coverage && !coverage["ready"]
        @state["completion_readiness"] = { "status" => "not_ready", "reason" => coverage["gap"], "check" => scope["number"],
          "input_digest" => scope["input_digest"], "artifact_root" => scope["artifact_root"],
          "artifact_digest" => current_digest, "coverage" => coverage }
        @record.event("requirement_coverage_unverified", "check" => scope["number"], "reason" => coverage["gap"])
        sent = @connection.send_message("Orbit 逐要求覆盖尚未确认（不是用户新要求）：#{coverage['gap']}。请补齐实际证据并重新请求完整终检；不要申请完成。")
        @state["sent_message_ids"] << sent.fetch("id")
        return
      end
      return unless @state["findings"].values.none? { |finding| finding["status"] == "open" }
      unless members_settled? && host["status"] == "idle" && host["last_turn_status"] == "completed"
        queue_finalization_handoff(scope, current_digest, now)
        return
      end

      send_finalization_notice(scope, current_digest, now)
    end

    # Sends one version-keyed finalization notice. The notice itself never
    # completes the task; an explicit Root stop still waits for its final turn
    # and rechecks artifact, input and members at stop time.
    def send_finalization_notice(scope, current_digest, now)
      return if @state["coverage_required"] && !requirement_coverage_status["ready"]
      key = Digest::SHA256.hexdigest(JSON.generate([
        scope["artifact_root"], current_digest, scope["input_digest"]
      ]))
      @state["completion_readiness"] = {
        "status" => "ready", "reason" => "当前版本可申请完成",
        "artifact_root" => scope["artifact_root"], "artifact_digest" => current_digest,
        "input_digest" => scope["input_digest"], "notice_key" => key
      }
      @state.delete("pending_finalization")
      unless @state["finalization_notices"][key]
        text = "Orbit 最终检查通知（不是用户的新要求）：这次检查没有发现待解决的问题，但任务尚未完成。" \
               "如果实现和本地验证已经完成，当前助手请调用本会话的 Orbit 工具 action=stop, intent=complete, task=<当前任务目录>，再正常结束本轮回复。" \
               "不要运行 shell/CLI 的 orbit stop：它只会暂停任务，已暂停任务不能再申请完成。" \
               "Orbit 会在回复结束后核对当前文件、要求和协作成员，确认停止后才记录完成；" \
               "若检查后又有改动，先重新检查。不要只凭这条通知宣称任务完成。"
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
      @state["completion_readiness"] = {
        "status" => "waiting", "reason" => "最终检查已就绪，等待通知送达",
        "artifact_root" => scope["artifact_root"], "artifact_digest" => current_digest,
        "input_digest" => scope["input_digest"]
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
      unless members_settled? && @state["recheck"].nil?
        remind_finalization_wrapup(pending, now) if finalization_wait_expired?(pending, now)
        return false
      end
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

    # One explicit Root wrap-up notice per valid pending version when member
    # settlement stays unprovable past the wait limit. This never marks the
    # task complete, never infers failure from time, never stops anything and
    # never turns into needs_user/stop_unconfirmed on its own; it names the
    # unsettled members and the exact missing facts so Root can close out
    # explicitly. A stale pending version is left to the normal version-change
    # recheck path above.
    def remind_finalization_wrapup(pending, now)
      current_digest = fingerprint_artifact
      return unless pending["artifact_root"] == artifact_root &&
                    pending["artifact_digest"] == current_digest &&
                    pending["input_digest"] == @record.input_digest(@state)

      key = Digest::SHA256.hexdigest(JSON.generate([pending["artifact_root"], current_digest, pending["input_digest"]]))
      notices = @state["finalization_wrapup_notices"] ||= {}
      return if notices[key]

      unsettled = @state["members"].reject { |member| MEMBER_SETTLED.include?(member["status"]) }
      return if unsettled.empty?

      details = unsettled.map do |member|
        missing = []
        missing << "原生接受(acceptedAt)" unless member["accepted_at"]
        missing << "当前派发终裁" unless current_member_dispatch(member)&.dig("status")
        missing << "可归因原生交付或错误事实" unless member["last_turn_error"].is_a?(Hash) || member["output_path"]
        "#{member['thread_id']}(status=#{member['status']}, 缺: #{missing.join('/')})"
      end
      sent = @connection.send_message(
        "Orbit 当前版本终检已就绪，但成员结算无法证实：#{details.join('；')}。" \
        "这不是任务完成，也不是失败判定。请显式结束相关成员/工作单元（或修正后重新终检）再申请完成；" \
        "程序不会据此自动判失败、降级或停止任何成员。")
      @state["sent_message_ids"] << sent.fetch("id")
      notices[key] = { "at" => Time.at(now).utc.iso8601, "check" => pending["check"],
                       "members" => unsettled.map { |member| member["thread_id"] } }
      @record.event("finalization_wrapup_reminded", "check" => pending["check"],
                    "members" => notices[key]["members"])
      save
    end

    def send_correction(result, scope:, current_digest:)
      findings = result.fetch("findings")
      lines = ["Orbit 独立检查：发现 #{findings.length} 个待处理问题。任务尚未完成；这不是用户的新要求。"]
      findings.each_with_index do |finding, index|
        lines << "问题 #{index + 1}（编号 #{finding.fetch('id')}）：#{finding.fetch('requirement')}"
        lines << "依据：#{finding.fetch('evidence')}"
        lines << "建议处理：#{finding.fetch('action')}"
      end
      lines << "请当前助手按原要求处理后重新检查；若检查结论有误，用 Orbit dispute 提交具体反证。"
      text = lines.join("\n")
      deliver_correction_text(text,
                              "check" => scope["number"], "finding_ids" => findings.map { |finding| finding.fetch("id") },
                              "artifact_root" => scope["artifact_root"],
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
      @record.event("correction_sent", { "id" => sent.fetch("id") }.merge(versions || {}))
    rescue Connection::Error => error
      @state["pending_correction"] = (versions || {}).merge("text" => text)
      @record.event("correction_delivery_failed", { "error" => error.message }.merge(versions || {}))
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
    # requires the connection to still be readable. `completion_gate` holds the
    # durable half so the CLI refuses with the same verdict before queueing;
    # a queued hand-off that no longer qualifies is reported, never paused.
    # Interrupts (@stop_requested) and post-crash stop retries (retry_stop)
    # never take this path: they stay paused or stop_unconfirmed.
    def completion_notice_key
      Digest::SHA256.hexdigest(JSON.generate([
        artifact_root, fingerprint_artifact, @record.input_digest(@state)
      ]))
    end

    def completion_notice_current?
      key, = completion_gate
      return nil unless key

      @connection.state # liveness only: the stop turn itself makes Root busy
      @state["finalization_notices"][key]
    rescue Connection::Error
      nil
    end

    # A queued completion hand-off no longer qualifies: the delivery version,
    # the clue/finding memory or the member roster changed while the delivery
    # turn finished. Keep the task running, record the refusal, and wake Root
    # with the next action when the bridge is up -- never record an ordinary
    # pause in place of the completion the user asked for.
    def reject_completion_handoff(reason, code: nil, detail: nil)
      if code.nil?
        key, code, detail = completion_gate
        if key
          code = "root_bridge_unavailable"
          detail = "the Root connection was not readable when the hand-off was adjudicated"
        end
      end
      @state.delete("completion_stop_pending")
      if code == "root_bridge_unavailable"
        @state["completion_readiness"] = @state.fetch("completion_readiness").merge(
          "status" => "ready", "reason" => self.class.completion_next_action(code)
        )
      else
        @state["completion_readiness"] = {
          "status" => "invalidated", "reason" => "#{code}：#{self.class.completion_next_action(code)}"
        }
      end
      recent = Array(@state["completion_rejections"])
      @state["completion_rejections"] = (recent + [{
        "reason" => code, "detail" => detail, "stop_reason" => reason, "at" => Time.now.utc.iso8601
      }]).last(5)
      @record.event("completion_stop_rejected", "source" => "runtime", "reason" => code, "detail" => detail)
      begin
        sent = @connection.send_message("Orbit 还不能确认任务完成。#{self.class.completion_next_action(code)}" \
                                        "当前任务仍需处理，不要按已完成交付。")
        @state["sent_message_ids"] << sent.fetch("id")
        @record.event("completion_rejection_delivered", "id" => sent.fetch("id"))
      rescue Connection::Error => error
        @record.event("completion_rejection_undelivered", "error" => error.message)
      end
      save
      nil
    end

    # Thread ids in the authoritative roster that the stop never accounted for:
    # registrations that landed while the task was being torn down, so
    # confirmed_stop (which stops the roster reconciled at stop entry) never
    # stopped them. Refused registrations never did model work and do not
    # count. Returns nil when the roster cannot be read.
    def members_unaccounted_after_teardown
      known = @state["members"].map { |member| member["thread_id"] }
      @record.members.reject { |entry| entry["status"] == "refused" }
             .map { |entry| entry["thread_id"] } - known
    rescue StandardError
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
      # A completion hand-off is adjudicated on the refreshed roster and before
      # anything is torn down. `reconcile_registered_members!` above is the
      # authority: a member registered after the final check would otherwise
      # still pass `members_settled?` against the stale state roster and be
      # recorded complete. An unreadable roster cannot qualify either. Both
      # keep the task running and report the refusal instead of pausing it.
      notice = nil
      if allow_complete && status == "paused"
        if roster_error
          return reject_completion_handoff(reason, code: "members_unreadable",
                                                   detail: "the member roster could not be read: #{roster_error}")
        end

        notice = completion_notice_current?
        return reject_completion_handoff(reason) if notice.nil?
      end

      checker_error = @state["cleanup_error"]
      begin
        @checker.stop! if @running_check
      rescue StandardError => error
        checker_error = error.message
        record_cleanup_error(error)
      ensure
        capture_interrupted_check(@running_check) if @running_check
      end
      @running_check = nil
      # Structured stop diagnostics: every phase records what it actually
      # observed, so an unconfirmed stop names the phase that failed with its
      # own evidence instead of only a joined error string.
      diagnostics = stop_diagnostics_frame(reason)
      diagnostics["roster_error"] = roster_error
      diagnostics["checker_cleanup_error"] = checker_error
      confirmation = nil
      begin
        confirmation = confirmed_stop(diagnostics)
        raise ArgumentError, "Checker stop unconfirmed: #{checker_error}" if checker_error
        raise ArgumentError, "members.json is not a reliable roster: #{roster_error}" if roster_error

        @state["execution_stop_confirmation"] = confirmation if checker_error
        @state["stop_confirmation"] = confirmation
        capture_native_calls
        final_status = status
        if notice
          # Teardown can outlive the hand-off check above (member stops wait for
          # in-flight work), so version and roster are checked once more. This
          # recheck is deliberately bridge-free: the resources are already
          # stopped, so asking the stopped Root's bridge could turn a valid
          # completion into a pause on a transient failure. Only durable state
          # (version, clues, findings, member roster) can invalidate the
          # hand-off here; the stop evidence is the recorded confirmation. A
          # hand-off that no longer matches is recorded as an ordinary stop with
          # an explicit reason -- never as completion, and never as if the task
          # were still running.
          key, code, detail = completion_gate
          unaccounted = nil
          if key
            unaccounted = members_unaccounted_after_teardown
            if unaccounted.nil?
              key = nil
              code = "members_unreadable"
              detail = "the member roster could not be re-read after teardown"
            elsif !unaccounted.empty?
              key = nil
              code = "members_registered_during_stop"
              detail = "members registered while the task stopped were never stopped: #{unaccounted.join(', ')}"
            end
          end
          if key
            @state.delete("completion_invalidation")
            final_status = "complete"
            @state["delivery_digest"] = fingerprint_artifact
            @record.event("completed_via_finalized_stop", "check" => @state.dig("finalization_notices", key, "check"))
          else
            # An unaccounted member was never stopped, so the stop itself is not
            # confirmed: that records an unconfirmed stop, not a confirmed pause.
            if %w[members_unreadable members_registered_during_stop].include?(code)
              final_status = "stop_unconfirmed"
              # Overall confirmation must not stay true while a member is
              # unaccounted for; keep the verified parts (Root plus the members
              # the stop actually covered) as the execution-scope evidence.
              partial = @state["stop_confirmation"] || {}
              @state["execution_stop_confirmation"] = partial
              @state["stop_confirmation"] = partial.merge("confirmed" => false, "reason" => code,
                                                          "unaccounted_members" => Array(unaccounted))
              # The stop attempt itself succeeded; the unconfirmed verdict comes
              # from the post-teardown roster check. Keep that distinction in
              # the diagnostics (root ok, stop not confirmed overall).
              diagnostics["confirmed"] = false
              diagnostics["reason_code"] = code
              diagnostics["unaccounted_members"] = Array(unaccounted)
              @state["stop_diagnostics"] = diagnostics
            end
            @state["completion_invalidation"] = { "reason" => code, "detail" => detail,
                                                  "at" => Time.now.utc.iso8601 }
            @record.event("completion_invalidated_after_stop", "reason" => code, "detail" => detail)
          end
        end
        @state["status"] = final_status
        @state["stop_reason"] = reason
        # A confirmed stop leaves no stale failure diagnostics behind; the
        # invalidation path above keeps its frame (final_status is
        # stop_unconfirmed there).
        @state.delete("stop_diagnostics") unless final_status == "stop_unconfirmed"
        mark_terminal_ask_interrupts!
        if final_status == "stop_unconfirmed" && @state["completion_invalidation"]
          # The Root turn itself was verified, but the stop as a whole is not:
          # the event must not carry a false overall confirmation.
          @record.event("stop_unconfirmed", "reason" => reason,
                        "error" => @state.dig("completion_invalidation", "reason"),
                        "detail" => @state.dig("completion_invalidation", "detail"),
                        "unaccounted_members" => Array(@state.dig("stop_confirmation", "unaccounted_members")),
                        "verified_root_confirmation" => @state["execution_stop_confirmation"])
        else
          @record.event("stopped", "reason" => reason, "confirmation" => confirmation)
        end
        save
      rescue StandardError => error
        detail = error.message
        if roster_error && !detail.include?("not a reliable roster")
          detail = "members.json is not a reliable roster: #{roster_error}; #{detail}"
        end
        finalize_unconfirmed_stop_diagnostics(diagnostics, detail)
        @state["status"] = "stop_unconfirmed"
        @state["stop_reason"] = reason
        @state["error"] = detail
        @record.event("stop_unconfirmed", "reason" => reason, "error" => detail)
        mark_terminal_ask_interrupts!
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

    def confirmed_stop(diagnostics)
      failures = []
      # Root abort can drop the OMP registry session. Confirm native members
      # from the live bridge first, then stop Root so a later retry is not the
      # only chance to observe them.
      native, others = @state["members"].partition { |member| member["adapter"] == OMP_NATIVE_ADAPTER }
      native_results = native.map do |member|
        if member.dig("stop_confirmation", "confirmed") == true
          # Already verified by an earlier stop (a drift stop or a previous
          # attempt): re-requesting could only re-interrupt an already stopped
          # member, and a bridge that lost its registry state (host restart)
          # can no longer re-confirm it. Reuse the recorded evidence.
          result = { "thread_id" => member["thread_id"], "confirmation" => member["stop_confirmation"],
                     "reused_prior_confirmation" => true }
          diagnostics["members"] << { "thread_id" => member["thread_id"], "ok" => true,
                                      "reused_prior_confirmation" => true }
        else
          result = stop_omp_native_member(member, failures)
          error = result["error"]
          entry = { "thread_id" => result["thread_id"], "ok" => error.nil? }
          entry["error"] = error if error
          entry["registration_status"] = result["registration_status"] if result["registration_status"]
          diagnostics["members"] << entry
        end
        result
      end
      other_results = others.map do |member|
        failures << "Member #{member['thread_id']}: legacy member record has no migration path and was not stopped"
        diagnostics["members"] << { "thread_id" => member["thread_id"], "ok" => false,
                                    "error" => "legacy member record rejected",
                                    "registration_status" => member["status"] }
        { "thread_id" => member["thread_id"], "error" => "legacy member record rejected", "registration_status" => member["status"] }
      end
      begin
        confirmation = @connection.stop!
        diagnostics["root"] = { "ok" => confirmation["confirmed"] == true, "confirmation" => confirmation }
        failures << "Root did not confirm actual stop" unless confirmation["confirmed"] == true
      rescue StandardError => error
        failures << "Root: #{error.message}"
        confirmation = nil
        diagnostics["root"] = { "ok" => false, "error" => error.message }
      end
      members = native_results + other_results
      @state["member_stop_results"] = members
      raise ArgumentError, failures.join("; ") unless failures.empty?

      confirmation["members"] = members unless members.empty?
      confirmation
    end

    # A fresh structured frame per stop attempt. `members` and `root` are
    # filled by the stop itself; the frame is persisted when the stop stays
    # unconfirmed and deleted when a later attempt confirms.
    def stop_diagnostics_frame(reason)
      { "at" => Time.now.utc.iso8601, "reason" => reason.to_s, "members" => [], "root" => {} }
    end

    # The attempt raised: persist the frame with the failure detail and keep
    # whatever evidence the phases did observe. A Root turn that the bridge
    # actually confirmed stays visible as execution-scope evidence, but the
    # overall stop_confirmation is never true when the stop as a whole failed.
    def finalize_unconfirmed_stop_diagnostics(diagnostics, detail)
      diagnostics["confirmed"] = false
      diagnostics["failures"] = detail
      root = diagnostics["root"] || {}
      if root["ok"] && root["confirmation"].is_a?(Hash)
        @state["execution_stop_confirmation"] = root["confirmation"]
        @state["stop_confirmation"] = root["confirmation"].merge("confirmed" => false,
                                                                "reason" => "stop_failed", "failures" => detail)
      else
        @state["stop_confirmation"] = { "confirmed" => false, "reason" => "stop_failed", "failures" => detail }
      end
      @state["stop_diagnostics"] = diagnostics
    end

    # The explicit stop retry re-reads the live session and roster state
    # before touching anything: the durable record then shows what was
    # already stopped before the retry, and an unreachable bridge is a
    # recorded fact instead of only a stop failure string.
    def refresh_stop_retry_probe
      probe = { "at" => Time.now.utc.iso8601 }
      begin
        # Prefer the connect handshake's own observation: it is the fresh
        # pre-stop session read without a second round-trip between connect
        # and stop. Doubles without the memo fall back to a direct read.
        host = @connection.connect_state if @connection.respond_to?(:connect_state)
        host = @connection.state if host.nil?
        probe["root"] = if host.is_a?(Hash)
                          { "reachable" => true, "status" => host["status"],
                            "active_tools" => host["active_tools"], "interrupted" => host["interrupted"] }
                        else
                          { "reachable" => true, "status" => nil }
                        end
      rescue StandardError => error
        probe["root"] = { "reachable" => false, "error" => "#{error.class}: #{error.message}" }
      end
      probe["members"] = @state["members"].map do |member|
        entry = { "thread_id" => member["thread_id"] }
        if member.dig("stop_confirmation", "confirmed") == true
          entry["already_confirmed"] = true
        elsif @connection.respond_to?(:member_state)
          begin
            state = @connection.member_state(member["thread_id"])
            if state.is_a?(Hash)
              entry["registry_status"] = state["registry_status"]
              entry["active_tools"] = state["active_tools"]
              entry["session_attached"] = state["session_attached"]
            end
          rescue StandardError => error
            entry["error"] = error.message
          end
        end
        entry
      end
      @state["stop_retry_probe"] = probe
    end

    # A native `ask` call the host skipped before the user could answer
    # (interrupt_skipped). Recorded once per call id; the reminder asks Root
    # to re-issue the ask itself -- Orbit never answers for the user and
    # never resends the question.
    def record_ask_interrupt(event)
      call_id = event["tool_call_id"].to_s
      return false if call_id.empty?

      seen_at = ask_event_time(event)
      interrupts = @state["ask_interrupts"] ||= {}
      if (existing = interrupts[call_id])
        return false if existing["last_seen_at"] == seen_at

        existing["last_seen_at"] = seen_at
        return true
      end
      interrupts[call_id] = {
        "tool_call_id" => call_id,
        "agent_id" => event["agent_id"],
        "session_id" => event["session_id"],
        "question" => event["question"].to_s[0, 200],
        "skipped_source" => event["skipped_source"],
        "started" => event["started"] == true,
        "at" => seen_at,
        "last_seen_at" => seen_at
      }
      @record.event("ask_interrupt_recorded", "tool_call_id" => call_id,
                    "agent_id" => event["agent_id"], "skipped_source" => event["skipped_source"])
      true
    end

    # The plugin reports JS epoch milliseconds; the durable record keeps
    # ISO-8601 UTC like the rest of the task state.
    def ask_event_time(event)
      at = event["at"]
      return Time.at(at / 1000.0).utc.iso8601 if at.is_a?(Numeric)

      at.is_a?(String) && !at.empty? ? at : Time.now.utc.iso8601
    end

    # A later non-synthetic, non-error `ask` result from the same agent: the
    # question was re-issued and answered, so that agent's pending interrupts
    # are resolved. A new ask carries a new call id, so by-agent is the finest
    # observable granularity; partial re-asks are not distinguishable.
    def resolve_ask_interrupts(event)
      agent_id = event["agent_id"]
      return false unless agent_id.is_a?(String) && !agent_id.empty?

      pending = (@state["ask_interrupts"] || {}).values
                     .select { |entry| entry["cleared_at"].nil? && entry["agent_id"] == agent_id }
      return false if pending.empty?

      at = ask_event_time(event)
      pending.each do |entry|
        entry["cleared_at"] = at
        entry["cleared_by"] = "ask_succeeded"
      end
      @record.event("ask_interrupt_cleared", "agent_id" => agent_id,
                    "resolved_tool_call_id" => event["tool_call_id"], "count" => pending.length)
      true
    end

    # One bounded reminder for recorded ask interrupts, delivered only when
    # the Root turn is observably safe (idle, no active tools, not
    # interrupted): a steer message arriving while an exclusive `ask` is
    # pending is exactly what skipped the original question, so the reminder
    # itself must never interrupt a new one.
    def deliver_pending_ask_reminders(host, now)
      pending = (@state["ask_interrupts"] || {}).values
                    .select { |entry| entry["cleared_at"].nil? && entry["reminded_at"].nil? }
      return false if pending.empty?
      return false unless host.is_a?(Hash) && host["status"] == "idle" &&
                          host["active_tools"].to_i.zero? && !host["interrupted"]

      calls = pending.first(3).map do |entry|
        owner = entry["agent_id"] ? " (agent #{entry['agent_id']})" : ""
        question = entry["question"].to_s.empty? ? "question not captured" : "\"#{entry['question']}\""
        "ask #{entry['tool_call_id']}#{owner}: #{question} (skipped due to #{entry['skipped_source'] || 'an interrupt'})"
      end
      more = pending.length > 3 ? " ... and #{pending.length - 3} more" : ""
      text = "Orbit ask-interrupt notice (not a new user instruction): #{pending.length} native ask call(s) " \
             "were skipped by the host before the user could answer: #{calls.join('; ')}#{more}. " \
             "If a question is still needed, re-issue the native ask when idle; Orbit does not answer for " \
             "the user and does not resend the question."
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      at = Time.at(now).utc.iso8601
      pending.each do |entry|
        entry["reminded_at"] = at
        entry["reminder_message_id"] = sent.fetch("id")
      end
      @record.event("ask_reminder_delivered", "count" => pending.length, "id" => sent.fetch("id"))
      save
      true
    rescue Connection::Error => error
      @record.event("ask_reminder_undelivered", "error" => error.message)
      false
    end

    # Terminal task states close every still-pending ask interrupt: the
    # reminder is only actionable while the task can still steer Root.
    def mark_terminal_ask_interrupts!
      interrupts = @state["ask_interrupts"]
      return unless interrupts.is_a?(Hash)

      at = Time.now.utc.iso8601
      interrupts.each_value do |entry|
        next unless entry.is_a?(Hash) && entry["cleared_at"].nil?

        entry["cleared_at"] = at
        entry["cleared_by"] = "task_terminal"
      end
    end

    # Two effective, current-input checks reported the same open finding
    # without any binding change: the suppressed repeat is escalated once
    # with a bounded action prompt. It names the finding and the concrete
    # next actions -- fix and re-check, dispute with evidence, or hand the
    # product decision to the user -- and never re-sends the correction.
    # A delivery failure leaves escalated_at unset so the next effective
    # report retries the prompt.
    def escalate_repeated_finding(finding, reports, scope, now)
      return if finding["escalated_at"]
      return unless deliver_repeated_finding_prompt(finding, reports)

      finding["escalated_at"] = Time.at(now).utc.iso8601
      finding["escalated_reports"] = reports
      finding["escalated_check"] = scope["number"]
      @record.event("finding_repeat_escalated", "id" => finding.fetch("id"),
                    "reports" => reports, "check" => scope["number"])
    end

    def deliver_repeated_finding_prompt(finding, reports)
      evidence = finding["evidence"].to_s
      excerpt = evidence.length > 120 ? "#{evidence[0, 120]}..." : evidence
      text = "Orbit repeated-finding notice (not a new user instruction): finding #{finding.fetch('id')} is " \
             "still open after #{reports} effective checks on the same artifact, input and evidence " \
             "(latest evidence: #{excerpt}); the original correction is not re-sent. Next action: fix it " \
             "and request a check, or dispute with concrete evidence, or hand the underlying product " \
             "decision to the user. Orbit does not close findings by count."
      sent = @connection.send_message(text)
      @state["sent_message_ids"] << sent.fetch("id")
      true
    rescue Connection::Error => error
      @record.event("finding_escalation_notify_failed", "id" => finding.fetch("id"), "error" => error.message)
      false
    end
  end
end
