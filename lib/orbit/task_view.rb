# frozen_string_literal: true

require_relative "task_record"

module Orbit
  # Read-only project selection and presentation; the runtime remains the writer.
  module TaskView
    SETTLED = %w[complete paused needs_user].freeze
    STALE_REASONS = {
      "artifact" => "产物变化", "workspace" => "工作区切换", "input" => "输入变化",
      "host" => "Root 执行状态变化", "dispute" => "争议状态变化"
    }.freeze
    LABELS = {
      "starting" => "正在接入", "running" => "执行中，尚未完成验收",
      "complete" => "独立检查及收尾通过", "paused" => "已暂停并确认停止",
      "needs_user" => "需要用户处理，已确认停止", "failed" => "运行失败，停止情况需核实",
      "stop_unconfirmed" => "停止尚未确认"
    }.freeze
    module_function

    def project(cwd = Dir.pwd)
      directory = File.realpath(cwd)
      loop do
        return directory if File.directory?(File.join(directory, ".orbit"))
        return nil if File.exist?(File.join(directory, ".git"))
        parent = File.dirname(directory)
        return nil if parent == directory
        directory = parent
      end
    end

    def records
      root = project
      return [] unless root
      Dir.glob(File.join(root, ".orbit/tasks/*/state.json")).map do |path|
        record = TaskRecord.new(File.dirname(path))
        state = record.state
        unless state["format"] == "orbit-task-1" && state["project_root"] == root
          raise ArgumentError, "任务记录不属于当前项目或格式不支持：#{record.path}"
        end
        record
      end.sort_by { |record| [record.state.fetch("created_at"), record.state.fetch("id")] }.reverse
    end

    def select(argument = nil, settled: false)
      return [TaskRecord.new(argument)] if argument && File.directory?(argument)
      all = records
      if argument
        matches = all.select { |record| record.state.fetch("id").start_with?(argument) }
        raise ArgumentError, "找不到任务 #{argument}；在项目中运行 orbit status 查看任务。" if matches.empty?
        return matches
      end
      pending = all.reject { |record| SETTLED.include?(record.state["status"]) }
      if pending.empty? && settled
        latest = all.max_by { |record| record.state["finished_at"] || record.state.fetch("created_at") }
        latest ? [latest] : []
      else
        pending
      end
    end

    def single!(argument = nil)
      candidates = select(argument)
      raise ArgumentError, "当前项目没有需要停止或清理的任务。" if candidates.empty?
      if candidates.length > 1
        raise ArgumentError, "存在多个任务，请指定任务 ID 或目录：\n#{list(candidates)}"
      end
      candidates.first
    end

    def summary(record)
      File.read(File.join(record.path, "instruction.txt")).gsub(/\s+/, " ").strip[0, 120]
    end

    def stop_confirmed?(state)
      state.dig("stop_confirmation", "confirmed") == true
    end

    # A failed run may still have confirmed that execution stopped. That is a
    # different user action from a failure whose stop result is unknown.
    def label(state)
      status = state.fetch("status")
      return "运行失败，停止已确认" if status == "failed" && stop_confirmed?(state)

      LABELS.fetch(status, status)
    end

    # A starting/running record whose recorded runtime process is gone cannot
    # consume queued commands; stop treats it like an exited runtime. An
    # abnormal exit records finished_at and removes runtime_pid, so a recorded
    # finish without a pid is also an exited runtime; without a recorded finish
    # a missing pid may only mean the runtime is still starting.
    def runtime_abandoned?(state)
      return false unless %w[starting running].include?(state["status"])

      pid = state["runtime_pid"]
      return !state["finished_at"].to_s.empty? unless pid.is_a?(Integer) && pid.positive?

      Process.kill(0, pid)
      false
    rescue Errno::ESRCH
      true
    rescue SystemCallError
      false
    end

    def list(records)
      records.map do |record|
        state = record.state
        "#{state.fetch('id')}  #{label(state)}  #{summary(record)}"
      end.join("\n")
    end

    def artifact_root(state)
      root = state.dig("workspace", "artifact_root")
      root.is_a?(String) && !root.empty? ? root : state.fetch("project_root")
    end

    def latest_rebind(state)
      entry = Array(state.dig("workspace", "history")).reverse.find { |item| item.is_a?(Hash) }
      return "无" unless entry

      "#{entry['from']} → #{entry['to']}（#{entry['at']}，#{entry['reason']}）"
    end

    def jev_status(state)
      jev = state["jev"]
      text = if jev.nil?
               "未启用"
             elsif jev["status"] == "unavailable"
               "不可用（#{jev['unavailable'] || jev['reason']}）"
             elsif jev["status"] == "assessed"
               "已判断（#{jev['assessed_at']}）"
             else
               "未启用"
             end
      evidence = {
        "requested" => "等待 Root 提交模型证据",
        "used" => "已使用模型证据",
        "incomplete" => "证据不完整，未自动提示",
        "unavailable" => "模型证据不可用，未自动提示",
        "mismatch" => "提交的证据与待比较身份不一致，未自动提示",
        "unknown" => "身份未知，自动链已停止",
        "unrequested" => "证据已缓存，但本任务没有待处理的证据请求"
      }[jev && jev["evidence_status"]]
      text += "；#{evidence}" if evidence
      # Only the typed mismatch status surfaces its bounded correction note;
      # other evidence statuses keep their generic label.
      if jev.is_a?(Hash) && jev["evidence_status"] == "mismatch"
        note = jev["evidence_note"].to_s.strip
        unless note.empty?
          note = "#{note[0, 200]}…[truncated]" if note.length > 200
          text += "；#{note}"
        end
      end
      candidate = stage_one_candidate(jev)
      text += "；#{candidate}" if candidate
      outcome = delegation_outcome(state)
      text += "；#{outcome}" if outcome
      text
    end

    # Stage-one `delegatable` is only a candidate score. It is never labeled
    # as Orbit's delegation recommendation.
    def stage_one_candidate(jev)
      return nil unless jev.is_a?(Hash)

      score = format_score(jev.dig("scores", "delegatable"))
      return nil unless score

      "第一阶段候选分 delegatable #{score}（不是委派建议）"
    end

    # `decision` is the runtime's final stage-two result. Records written
    # before that field existed stay conservative: a persisted hint can be
    # named, but scores alone are not a recommendation.
    def delegation_outcome(state)
      jev = state["jev"]
      delegation = jev.is_a?(Hash) ? jev["delegation"] : nil
      hint = delegation_hint(state)
      return nil unless delegation.is_a?(Hash) || hint

      scores = delegation_score_text(delegation, hint)
      case delegation.is_a?(Hash) ? delegation["decision"] : nil
      when "recommended"
        if hint
          "最终建议委派#{scores}"
        else
          "第二阶段达到建议门槛，但 delegation_hint 尚未持久化，不能视为可执行建议#{scores}"
        end
      when "declined"
        "最终不建议委派#{scores}"
      when "unavailable"
        "最终建议不可用#{scores}"
      else
        if hint
          "旧记录没有 decision；持久 delegation_hint 才是当时的最终建议#{scores}"
        else
          "旧记录没有 decision，不能从分数视为最终建议#{scores}"
        end
      end
    end

    def delegation_hint(state)
      hint = state["delegation_hint"]
      hint.is_a?(Hash) && !hint.empty? ? hint : nil
    end

    def delegation_score_text(delegation, hint)
      fit = format_score(delegation_score(delegation, hint, "member_fit"))
      gain = format_score(delegation_score(delegation, hint, "parallel_gain"))
      parts = []
      parts << "member_fit #{fit}" if fit
      parts << "parallel_gain #{gain}" if gain
      parts.empty? ? "" : "（#{parts.join('，')}）"
    end

    def delegation_score(delegation, hint, key)
      value = delegation.is_a?(Hash) ? delegation.dig("scores", key) || delegation[key] : nil
      value.nil? && hint.is_a?(Hash) ? hint[key] : value
    end

    def format_score(value)
      return nil unless value.is_a?(Numeric) && value.finite?

      Kernel.sprintf("%.2f", value)
    end

    def execution_status(state)
      members = Array(state["members"])
      return "当前仅独立检查；执行成员 0 个" if members.empty?

      origin = member_origin(state)
      base = "已委派 #{members.length} 个执行成员；多 Agent 执行协作已启动"
      origin ? "#{base}；#{origin}" : "#{base}；现有记录无法判断委派来源"
    end

    # Only a persisted hint follow-up, or the absence of any hint, is enough
    # to name the source. A hint that was not followed stays unlabeled.
    def member_origin(state)
      members = Array(state["members"])
      bases = members.filter_map { |member| member["delegation_basis"] }.uniq
      return "执行成员由 Orbit hint 后产生" if bases == ["orbit_hint"]
      return "Root 在无 hint 时显式委派" if bases == ["root_without_hint"]
      return "既有 Orbit hint 委派，也有 Root 无 hint 委派" if bases.sort == %w[orbit_hint root_without_hint]

      hint = state["delegation_hint"]
      return "Root 在无 hint 时显式委派" if hint.nil? || (hint.is_a?(Hash) && hint.empty?)
      return "执行成员由 Orbit hint 后产生" if hint.is_a?(Hash) && hint["followed"] == true

      nil
    end

    def recent_delegation_event(state)
      return nil if Array(state["members"]).empty?

      "最近事件：#{member_origin(state) || '现有记录无法判断委派来源'}"
    end

    CHECK_USAGE_ROLES = %w[reviewer process_reviewer adjudicator].freeze

    # Sums only recorded integer input/output pairs. A missing field stays
    # unknown; Root's session cumulative is never treated as this task's usage.
    def usage_lines(state)
      lines = []
      missing = []
      input_total = 0
      output_total = 0
      complete = true
      CHECK_USAGE_ROLES.each do |role|
        label = "独立检查 #{role}"
        pair = check_role_usage(state, role)
        if pair
          input_total += pair[0]
          output_total += pair[1]
          lines << "#{label}：#{usage_amount(pair)}"
        else
          complete = false
          missing << label
          lines << "#{label}：未知"
        end
      end
      if unassigned_checks?(state)
        complete = false
        missing << "独立检查未标注角色"
        lines << "独立检查未标注角色：未知"
      end
      [
        ["JEV 第一阶段", jev_stage_usage(state, "jev_stage1", state.dig("jev", "usage"))],
        ["JEV 委派第二阶段", jev_stage_usage(state, "jev_stage2", state.dig("jev", "delegation", "usage"))]
      ].each do |label, pair|
        if pair
          input_total += pair[0]
          output_total += pair[1]
          lines << "#{label}：#{usage_amount(pair)}"
        else
          complete = false
          missing << label
          lines << "#{label}：未知"
        end
      end
      lines << "Root 会话累计：#{root_session_cumulative(state)}（非任务增量）"
      lines << if complete
                 "可核算总计：#{usage_amount([input_total, output_total])}（不含 Root 会话累计）"
               else
                 "可核算总计：未知（缺少 #{missing.join('、')}）"
               end
      lines
    end

    def check_role_usage(state, role)
      matched = recorded_checks(state).select { |check| check["role"] == role }
      return [0, 0] if matched.empty?

      pairs = matched.map { |check| token_pair(check["usage"]) }
      return nil if pairs.any?(&:nil?)

      [pairs.sum(&:first), pairs.sum(&:last)]
    end

    def unassigned_checks?(state)
      recorded_checks(state).any? { |check| !CHECK_USAGE_ROLES.include?(check["role"]) }
    end

    def recorded_checks(state)
      checks = state["checks"]
      checks.is_a?(Array) ? checks.select { |check| check.is_a?(Hash) } : []
    end

    def token_pair(usage)
      return nil unless usage.is_a?(Hash)
      return nil if usage["incomplete"] == true || usage["status"] == "incomplete"

      input = usage["input_tokens"]
      output = usage["output_tokens"]
      return nil unless input.is_a?(Integer) && output.is_a?(Integer) && input >= 0 && output >= 0

      [input, output]
    end

    # Prefer the runtime aggregate. A present but incomplete aggregate stays
    # unknown; the latest single assessment is only for records without one.
    def jev_stage_usage(state, aggregate_key, fallback)
      usage = state["usage"]
      return token_pair(usage[aggregate_key]) if usage.is_a?(Hash) && usage.key?(aggregate_key)

      token_pair(fallback)
    end

    def usage_amount(pair)
      "输入 #{pair[0]}，输出 #{pair[1]}，合计 #{pair[0] + pair[1]}"
    end

    def root_session_cumulative(state)
      value = state.dig("usage", "root_session_cumulative")
      value.is_a?(Integer) && value >= 0 ? value.to_s : "未知"
    end

    def check_activity(state)
      return "running" if check_in_flight?(state)
      return "queued" if review_queued?(state)

      check = recorded_checks(state).last
      return "idle" unless check
      return "failed" if check["status"] == "failed"
      return "stale" if check["stale"] == true

      verdict = check.dig("result", "verdict")
      verdict.is_a?(String) && !verdict.empty? ? "verdict(#{verdict})" : "idle"
    end

    def check_activity_line(state)
      activity = check_activity(state)
      note = if activity == "queued"
               "（检查已排队，不是任务完成）"
             elsif activity == "verdict(complete)"
               "（检查结论，不是任务完成）"
             elsif activity == "failed"
               "（检查失败，未采纳；任务保持运行，等待显式指定检查模型后重试）"
             else
               ""
             end
      "检查状态：#{activity}#{note}"
    end

    # The model actually used for checks, from the recorded selection when
    # present, else the frozen review.model.
    def checker_model_line(state)
      review = state["review"]
      model = review.is_a?(Hash) ? (review.dig("selection", "model") || review["model"]) : nil
      model.to_s.empty? ? nil : "检查模型：#{model}"
    end

    # ADR-009: after a real auth/quota failure the task stays alive but blocked
    # until Root explicitly picks the next model. Failures never auto-retry or
    # switch silently, so this is the line that says what action is needed.
    def review_blocked_line(state)
      review = state["review"]
      blocked = review.is_a?(Hash) ? review["blocked"] : nil
      return nil unless blocked.is_a?(Hash)

      kind = blocked["failure_kind"] || blocked["kind"] || "unknown"
      model = blocked["model"].to_s
      model = "未知" if model.empty?
      reason = blocked["reason"].to_s.strip
      text = "检查阻塞：模型 #{model}（#{kind}）"
      text += " — #{reason}" unless reason.empty?
      "#{text}；用 orbit review-model 显式指定模型后重试"
    end

    def next_action_line(state)
      "下一动作：#{next_action(state)}"
    end

    # A completion hand-off that failed its post-teardown check leaves an
    # ordinary stop whose stop_reason may still claim the delivery completed.
    # Name the invalidation explicitly so the record can never be read as an
    # accepted completion (contracts/task-runtime.md, 2026-09-25).
    def completion_invalidation_line(state)
      invalidation = state["completion_invalidation"]
      return nil unless invalidation.is_a?(Hash)

      if state["status"] == "stop_unconfirmed" || !stop_confirmed?(state)
        "完成核对未通过：任务是否已停止还无法确认，也不能当作已完成。" \
          "请先重试停止；若仍需交付，请创建新任务重新检查。"
      else
        "完成核对未通过：这次只确认任务停止，不能确认交付已完成。" \
          "若仍需交付，请创建新任务，对最终版本重新检查。"
      end
    end

    def next_action(state)
      status = state["status"]
      if status == "stop_unconfirmed"
        return "用 orbit stop <任务> 显式重试停止收尾：重试前会重新读取会话与任务状态，" \
               "已确认停止的资源不重复打断；证据不足时保持停止未确认，不当作已停止"
      end
      return "需要用户处理" if status == "needs_user"
      if status == "failed"
        return stop_confirmed?(state) ? "运行失败，停止已确认" : "运行失败，需核实停止：用 orbit stop <任务> 显式重试收尾"
      end
      if %w[starting running].include?(status) && state["completion_stop_pending"]
        return "等待当前助手结束回复，Orbit 随后核对是否完成"
      end
      return "重新绑定工作区" if rebind_action?(state)
      return "手动检查已排队" if manual_check_queued?(state)
      notices = state["finalization_notices"]
      if %w[starting running].include?(status) && notices.is_a?(Hash) && !notices.empty?
        findings = state["findings"]
        open = findings.is_a?(Hash) && findings.each_value.any? { |finding| finding.is_a?(Hash) && finding["status"] == "open" }
        clues = state.dig("recheck", "findings")
        unless open || (clues.is_a?(Array) && !clues.empty?)
          return "当前助手核对检查后是否有新改动；无改动时申请完成，否则重新检查"
        end
      end
      return "等待 Root" if waiting_for_root?(state)
      return "检查已安排" if review_queued?(state)

      "无"
    end

    def check_in_flight?(state)
      observations = state["check_observations"]
      return false unless observations.is_a?(Hash)

      observations.each_value.any? { |entry| entry.is_a?(Hash) && entry["status"] == "in_flight" }
    end

    def review_queued?(state)
      return false unless %w[starting running].include?(state["status"])

      at = state["next_check_at"]
      trigger = state["next_check_trigger"]
      (at.is_a?(String) && !at.empty?) || (trigger.is_a?(String) && !trigger.empty?)
    end

    def rebind_action?(state)
      return false unless %w[starting running].include?(state["status"])

      state["next_check_trigger"] == "rebind" || state["next_check_basis"] == "工作区重新绑定" ||
        Array(recorded_checks(state).last&.[]("stale_reasons")).include?("workspace")
    end

    def manual_check_queued?(state)
      %w[starting running].include?(state["status"]) && state["next_check_manual"] == true
    end

    def waiting_for_root?(state)
      return false unless %w[starting running].include?(state["status"])

      findings = state["findings"]
      open = findings.is_a?(Hash) && findings.each_value.any? { |finding| finding.is_a?(Hash) && finding["status"] == "open" }
      clues = state.dig("recheck", "findings")
      open || (clues.is_a?(Array) && !clues.empty?) || !review_queued?(state)
    end

    # Open findings whose repeat was escalated: after two effective,
    # current-input checks without a binding change the status names the
    # finding, its latest evidence and the concrete next actions instead of
    # only a count (proposal 2026-09-26 item 2).
    def escalated_finding_lines(state)
      findings = state["findings"]
      return [] unless findings.is_a?(Hash)

      findings.values.filter_map do |finding|
        next unless finding.is_a?(Hash) && finding["status"] == "open" && finding["escalated_at"]

        evidence = finding["evidence"].to_s
        evidence = evidence.length > 120 ? "#{evidence[0, 120]}…" : evidence
        reports = finding["current_reports"] || finding["escalated_reports"]
        "开放问题升级：#{finding['id']} 已连续 #{reports} 次有效检查仍开放" \
          "（最近检查 ##{finding['escalated_check']}，证据：#{evidence}）——下一动作：修复后重检；" \
          "或按现有 dispute 流程附证据反驳；属于产品口径的交给用户。Orbit 不按次数自动关闭或停止任务。"
      end
    end

    # Native ask calls the host skipped before the user could answer. Pending
    # means recorded and not cleared; reminded_at only says the one-shot
    # reminder went out. Orbit never answers for the user and never resends
    # the question.
    def pending_ask_interrupt_lines(state)
      interrupts = state["ask_interrupts"]
      return [] unless interrupts.is_a?(Hash) && %w[starting running].include?(state["status"])

      pending = interrupts.values.select { |entry| entry.is_a?(Hash) && entry["cleared_at"].nil? }
      return [] if pending.empty?

      detail = pending.first(2).map do |entry|
        owner = entry["agent_id"] ? "成员 #{entry['agent_id']}" : "Root"
        state_note = entry["reminded_at"] ? "已提醒补问" : "待安全回合提醒"
        "#{owner} 的 ask #{entry['tool_call_id']}（被 #{entry['skipped_source'] || '中断'} 打断，#{state_note}）"
      end
      more = pending.length > 2 ? "；另有 #{pending.length - 2} 条" : ""
      ["待补问：#{pending.length} 条原生提问被打断未获答复——#{detail.join('；')}#{more}。" \
        "Orbit 不代答、不重发提问；问题仍需要时由 Root 在空闲回合重新发起原生 Ask。"]
    end

    # Structured per-phase stop diagnostics for an unconfirmed stop: which
    # phase failed (roster read, checker cleanup, member stops, Root stop),
    # what the retry probe saw, and what remains unaccounted. Never reads a
    # partial confirmation as a confirmed stop.
    def stop_diagnostics_lines(state)
      diagnostics = state["stop_diagnostics"]
      return [] unless diagnostics.is_a?(Hash)

      phases = []
      phases << "成员名单不可读（#{diagnostics['roster_error']}）" if diagnostics["roster_error"]
      phases << "检查进程清理未核实（#{diagnostics['checker_cleanup_error']}）" if diagnostics["checker_cleanup_error"]
      failed_members = Array(diagnostics["members"]).select { |entry| entry.is_a?(Hash) && entry["ok"] == false }
      unless failed_members.empty?
        phases << "成员停止未确认 #{failed_members.length} 个（#{failed_members.map { |entry| entry['thread_id'] }.join('、')}）"
      end
      root = diagnostics["root"].is_a?(Hash) ? diagnostics["root"] : {}
      phases << if root["error"]
                  "Root 停止请求失败（#{root['error']}）"
                elsif root["ok"] != true
                  "Root 未确认停止"
                else
                  "Root 已确认停止（整体停止仍未确认）"
                end
      lines = ["停止诊断（#{diagnostics['at']}）：#{phases.join('；')}"]
      lines << "停止失败明细：#{diagnostics['failures']}" if diagnostics["failures"]
      unaccounted = Array(diagnostics["unaccounted_members"])
      lines << "停止未覆盖成员：#{unaccounted.join('、')}" unless unaccounted.empty?
      probe = state["stop_retry_probe"]
      if probe.is_a?(Hash) && (root_probe = probe["root"].is_a?(Hash) ? probe["root"] : nil)
        if root_probe["reachable"] == false
          lines << "上次停止重试时 Root 桥接不可达（#{root_probe['error']}）：无法取得停止证据，保持停止未确认。"
        elsif root_probe["status"] == "idle"
          lines << "上次停止重试前 Root 已空闲：重试只做确认收尾，未重复打断。"
        end
      end
      lines
    end

    def format(record)
      state = record.state
      status = state.fetch("status")
      lines = ["任务：#{summary(record)}", "状态：#{label(state)}（#{status}）",
               *([completion_invalidation_line(state)].compact),
               "产物目录：#{artifact_root(state)}",
               "绑定时间：#{state.dig('workspace', 'bound_at') || '未单独记录'}",
               "最近重新绑定：#{latest_rebind(state)}",
               "执行协作：#{execution_status(state)}",
               *([recent_delegation_event(state)].compact),
               "JEV：#{jev_status(state)}",
               check_activity_line(state),
               *([checker_model_line(state)].compact),
               *([review_blocked_line(state)].compact),
               next_action_line(state),
               *usage_lines(state)]
      check = state.fetch("checks", []).last
      if check && check["status"] == "failed"
        lines << "最近检查：失败 — #{check['error']}（检查模型失败，未采纳；产物快照与成员保留）"
      elsif check
        qualifier = if check["stale"]
                      "已过期，未采纳"
                    elsif check["kind"] == "process"
                      "过程检查，不代表交付通过"
                    else
                      "最近检查记录，不代表当前产物已通过"
                    end
        reasons = Array(check["stale_reasons"]).map { |reason| STALE_REASONS.fetch(reason, reason) }
        qualifier = "#{qualifier}；原因：#{reasons.join('、')}" if check["stale"] && !reasons.empty?
        lines << "最近检查：#{check.dig('result', 'verdict')} — #{check.dig('result', 'reason')}（#{qualifier}）"
      else
        lines << "最近检查：尚无检查结果"
      end
      open_findings = state.fetch("findings", {}).values.count { |finding| finding["status"] == "open" }
      recheck = state["recheck"]
      pending = []
      pending << "开放问题 #{open_findings} 条" if open_findings.positive?
      if recheck
        pending << "过期检查待重新核对 #{Array(recheck['findings']).length} 条（检查 ##{recheck['check']}）"
      end
      lines << "待处理问题：#{pending.empty? ? '无' : pending.join('；')}"
      lines.concat(escalated_finding_lines(state))
      lines.concat(pending_ask_interrupt_lines(state))
      decisions = Array(state["decisions"]).count { |decision| decision.is_a?(Hash) }
      lines << "裁定记录：#{decisions} 条"
      next_check = %w[starting running].include?(status) ? state["next_check_at"] : nil
      basis = state["next_check_basis"]
      lines << "下次检查：#{next_check || '未安排'}#{basis ? "（依据：#{basis}）" : ''}"
      attention = case status
                  when "failed"
                    stop_confirmed?(state) ? "运行失败，停止已确认；请查看运行错误。" : "运行失败，停止情况需核实。"
                  when "needs_user", "stop_unconfirmed"
                    state["stop_reason"] || state["error"] || "请核对任务错误及停止结果。"
                  when "paused"
                    if state["completion_invalidation"].is_a?(Hash)
                      "本次只确认停止，不代表任务完成；若仍需交付，请创建新任务重新检查。"
                    else
                      "当前记录未要求用户处理"
                    end
                  else
                    "当前记录未要求用户处理"
                  end
      lines << "用户处理：#{attention}"
      lines << "运行错误：#{state['error']}" if state["error"]
      lines << "停止错误：#{state['cleanup_error']}" if state["cleanup_error"]
      lines.concat(stop_diagnostics_lines(state))
      lines << "观察说明：#{state.dig('observation_pending', 'reason')}" if state["observation_pending"]
      lines << "任务 ID：#{state.fetch('id')}"
      lines.join("\n")
    end
  end
end
