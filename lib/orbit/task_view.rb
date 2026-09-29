# frozen_string_literal: true

require_relative "task_record"
require_relative "resource_call_ledger"
require_relative "requirement_coverage"
require_relative "workspace_snapshot"

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

    # Read the finalized ledger at display time: its last receipt may arrive
    # after the execution runtime exits. This detached projection never writes
    # task state or changes completion/stop facts.
    def current_state(record)
      state = record.state
      if state["coverage_required"] && (state["requirement_coverage"] || File.file?(File.join(record.path, RequirementCoverage::FILE_NAME)))
        state["requirement_coverage"] = begin
          if state["requirement_coverage_error"]
            { "ready" => false, "current" => false, "gap" => state["requirement_coverage_error"] }
          else
            RequirementCoverage.new(record: record).status(input_digest: record.input_digest(state),
              artifact_digest: WorkspaceSnapshot.fingerprint(project_root: artifact_root(state)), artifact_root: artifact_root(state))
          end
        rescue WorkspaceSnapshot::Error, SystemCallError => error
          { "ready" => false, "current" => false, "gap" => error.message }
        end
      end
      ledger = ResourceCallLedger.new(task_path: record.path, task_id: state.fetch("id"))
      native_files = %w[native-model-calls.json native-model-call-gaps.jsonl].any? do |name|
        File.file?(File.join(record.path, name))
      end
      return state unless File.file?(ledger.path) || native_files || state.dig("usage", "resource_calls")

      state["usage"] ||= {}
      raise ResourceCallLedger::Error, "recorded call ledger is missing; cached totals cannot be verified" if
        !File.file?(ledger.path) && state.dig("usage", "resource_calls") &&
        state.dig("usage", "resource_calls", "call_count") != 0

      state["usage"]["resource_calls"] = ledger.summary
      coverage = ledger.native_coverage
      state["usage"]["native_call_observations"] = coverage
      gaps = (state["usage"]["resource_call_gaps"] ||= {})
      notes = coverage["gaps"].dup
      notes << "#{coverage['pending_calls']} native calls have no final usage receipt" if coverage["pending_calls"].positive?
      gaps.delete("native_execution")
      gaps["native_execution"] = notes.uniq.join("; ").slice(0, 1000) unless notes.empty?
      state
    rescue ResourceCallLedger::Error, SystemCallError => error
      state["usage"] ||= {}
      state["usage"]["resource_calls"] = {
        "schema_version" => ResourceCallLedger::SCHEMA_VERSION, "coverage" => "unreadable",
        "call_count" => nil, "unknown_usage_calls" => nil, "partial_usage_calls" => nil, "groups" => []
      }
      (state["usage"]["resource_call_gaps"] ||= {})["resource_ledger"] = error.message
      state
    end

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
        "deferred" => "模型事实已缓存；执行成员已开始工作，不再对本轮分工评分或生成新建议",
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

      "历史第一阶段候选分 delegatable #{score}（不是委派建议，不用于新版推荐）"
    end

    # `decision` is the runtime's final stage-two result. Records written
    # before that field existed stay conservative: a persisted hint can be
    # named, but scores alone are not a recommendation.
    def delegation_outcome(state)
      jev = state["jev"]
      delegation = jev.is_a?(Hash) ? jev["delegation"] : nil
      hint = delegation_hint(state)
      return nil unless delegation.is_a?(Hash) || hint

      version = delegation&.[]("question_set_version") || hint&.[]("question_set_version")
      if %w[jev-delegation-1 jev-candidates-1].include?(version) ||
         (version.nil? && (delegation_score(delegation, hint, "parallel_gain") ||
                          delegation_score(delegation, hint, "member_fit")))
        return "历史委派判断（#{version || '未注明版本'}）：#{delegation&.[]('decision') || '未记录决定'}；不用于新版自动推荐"
      end

      scores = delegation_score_text(delegation, hint)
      case delegation.is_a?(Hash) ? delegation["decision"] : nil
      when "recommended"
        if hint && !hint["invalid_reason"]
          unit = hint["work_unit_id"]
          "最终建议委派#{unit ? "（工作单元 #{unit}）" : ""}#{scores}"
        elsif hint && hint["invalid_reason"]
          "此前推荐已失效（#{hint['invalid_reason']}），不能用于当前派发"
        else
          "第二阶段达到建议门槛，但 delegation_hint 尚未持久化，不能视为可执行建议#{scores}"
        end
      when "pending_candidates"
        "候选任务质量依据尚未支持正向推荐；缺事实者未评分，Root 可自主选择"
      when "facts_only"
        "仅显示候选事实（#{delegation['reason'].to_s[0, 180]}）；Root 可自主选择"
      when "uncalibrated"
        "新质量判断尚未校准放行；已显示事实，Root 可自主选择"
      when "conflict_review"
        "候选质量事实存在待复核冲突；Root 核对来源后决定"
      when "no_candidates"
        "候选池不可用或本会话没有可用成员，暂无委派建议"
      when "not_recommended", "declined"
        "最终不建议委派#{scores}"
      when "unavailable"
        "最终建议不可用#{scores}"
      when "stale"
        "工作单元已不对应当前要求，不能复用推荐"
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
      quality = format_score(delegation_score(delegation, hint, "quality"))
      quality ? "（任务质量判断 #{quality}）" : ""
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
      calls = state.dig("usage", "resource_calls")
      return resource_usage_lines(state, calls) if calls.is_a?(Hash)

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
        ["入口 JEV", state["entry"] ? jev_stage_usage(state, "jev_entry", state.dig("entry", "trace", "usage")) : [0, 0]],
        ["检查选模 JEV", state.dig("review", "selection", "source") == "candidate_pool" ||
          state.dig("usage", "jev_checker_selection") ? jev_stage_usage(state, "jev_checker_selection", state.dig("review", "selection", "usage")) : [0, 0]],
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
      lines << "Root 本任务：未知（会话累计不能归属本次任务）"
      lines << "OMP 执行成员：#{Array(state['members']).empty? ? '无（0 tokens）' : '未知（未取得成员任务级 tokens）'}"
      lines << "Root 会话累计：#{root_session_cumulative(state)}（非任务增量）"
      lines << if complete
                 "可核算总计：#{usage_amount([input_total, output_total])}（不含 Root 会话累计）"
               else
                 "可核算总计：未知（缺少 #{missing.join('、')}）"
               end
      lines
    end

    def resource_usage_lines(state, calls)
      lines = ["已记录调用：#{calls['call_count'] || '未知'}；缺用量回执：#{calls['unknown_usage_calls'] || '未知'}；部分用量：#{calls.fetch('partial_usage_calls', 0) || '未知'}"]
      pending = state.dig("usage", "native_call_observations", "pending_calls")
      lines << "原生调用尚无最终用量：#{pending}；消耗未知，未计为零" if pending.to_i.positive?
      roles = { "root" => "Root", "member" => "执行成员", "judgment" => "JEV 判断",
                "checker" => "独立检查", "arbiter" => "裁定" }
      groups = Array(calls["groups"])
      groups.first(30).each do |group|
        identity = group["actual_identity"] || {}
        model = identity["model"] || "实际型号未知"
        fields = (group["usage_fields"] || {}).first(8).map do |name, field|
          amount = field["reported_sum"].nil? ? "未知" : field["reported_sum"]
          missing = field["missing_calls"].to_i
          "#{name} #{amount} #{field['unit']}#{missing.positive? ? "（#{missing} 次缺失）" : ''}"
        end
        lines << "#{roles.fetch(group['role'], group['role'])} #{group['phase']} #{model}：#{fields.empty? ? '未知' : fields.join('，')}"
      end
      lines << "其余 #{groups.length - 30} 组用量见详细记录" if groups.length > 30
      lines << "仅展示已有调用回执；输入、输出、缓存和推理分类保持原定义，不合成未知总量"
      gaps = state.dig("usage", "resource_call_gaps")
      lines << "部分调用归属或记录缺失，未计为零" if gaps.is_a?(Hash) && gaps.any?
      %w[root member checker arbiter].each do |role|
        next if groups.any? { |group| group["role"] == role }
        next if role == "member" && Array(state["members"]).empty?

        lines << "#{roles.fetch(role)} 本任务用量：未知（尚无可归属调用回执）"
      end
      lines << "本次费用／额度消耗：未知（尚无可核验结算）"
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

    # User-readable check scope (kickoff ⑤): what the check activity is, and
    # whether the user must do anything. Internal verdict tokens stay only as
    # the verdict value itself, never as the state name.
    def check_activity_line(state)
      activity = check_activity(state)
      case activity
      when "running"
        "检查状态：独立检查进行中（等待结果即可，无需重复请求检查）"
      when "queued"
        if %w[starting running].include?(state["status"]) && state["next_check_manual"] == true
          "检查状态：手动终检已排队（不是任务完成）"
        else
          "检查状态：自动检查已安排（尚未开始，任务未完成）"
        end
      when "failed"
        "检查状态：最近检查失败（未采纳；任务保持运行，等待显式指定检查模型后重试）"
      when "stale"
        "检查状态：最近检查已过期（未采纳）"
      when "idle"
        "检查状态：尚无检查结果"
      else
        verdict = activity[/\Averdict\((.*)\)\z/, 1]
        "检查状态：最近检查结论 #{verdict}（检查结论，不是任务完成）"
      end
    end

    # The chosen checker is visible even when selection had to fall back to a
    # runnable pool model without a positive task-fit signal.
    def checker_model_line(state)
      review = state["review"]
      selection = review.is_a?(Hash) ? review["selection"] : nil
      model = selection.is_a?(Hash) ? (selection["model"] || review["model"]) : review&.[]("model")
      return nil if model.to_s.empty?

      text = "检查模型：#{model}"
      if selection.is_a?(Hash) && selection["selection_tier"] == "fallback"
        text += "；降级选择（检查质量未经证实；#{selection['basis']}）"
      end
      if selection.is_a?(Hash) && selection["quality_basis"] == "model_overview_prior"
        text += "；模型级质量先验（不证明当前路由与推理变体适配）"
      end
      text
    end

    # A failed checker remains visible; exhausted models block completion.
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
      "#{text}；Root 可核对 OMP 可用型号并用 orbit review-model 重选；未取得有效独立检查不得申请完成"
    end

    def completion_readiness_line(state)
      return "完成状态：已完成并确认停止" if state["status"] == "complete"
      return "完成状态：停止确认中，不得称为完成" if state["status"] == "stop_unconfirmed"
      return nil unless %w[starting running].include?(state["status"])

      if state["completion_stop_pending"]
        return "完成状态：完成申请已入队；当前助手结束本轮后才核实停止"
      end
      ready = state["completion_readiness"]
      status = ready.is_a?(Hash) ? ready["status"] : "waiting"
      reason = ready.is_a?(Hash) ? ready["reason"].to_s : ""
      case status
      when "ready"
        "完成状态：当前版本可申请完成；当前助手调用 Orbit 工具 action=stop, intent=complete, task=<任务目录>；普通 CLI orbit stop 仅暂停"
      when "invalidated"
        "完成状态：此前的检查通知已失效（#{reason}）；自动检查通过不能替代，仍需当前版本的有效手动终检"
      when "review_needed"
        "完成状态：#{reason}；裁定或自动检查结论不代替手动终检"
      when "not_ready"
        "完成状态：尚不可交付（#{reason}）；补齐实际答复或产物后，仍需当前版本的有效手动终检（自动检查通过不替代终检）"
      else
        "完成状态：等待检查或有效通知，尚未完成"
      end
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
      # Terminal precedence (kickoff ④): a stopped task is never asked to
      # re-check, deliver artifacts, or apply completion. Leftover readiness
      # reasons and open findings on a settled record describe history, not
      # next actions; a paused record cannot consume a check request. An
      # adjudicator or auto `complete` check never becomes a finalization
      # notice, so it can never flip these into completion advice either.
      return "无" if status == "complete"
      return "已暂停：不能对已停止任务重检或申请完成；若仍需交付，请创建新任务" if status == "paused"
      if state["completion_stop_pending"]
        return "等待当前助手结束回复，Orbit 随后核对是否完成"
      end
      return "重新绑定工作区" if rebind_action?(state)
      return "手动检查已排队" if manual_check_queued?(state)
      findings = state["findings"]
      open = findings.is_a?(Hash) && findings.each_value.any? { |finding| finding.is_a?(Hash) && finding["status"] == "open" }
      clues = state.dig("recheck", "findings")
      return "先处理检查问题，再请求终检" if open || (clues.is_a?(Array) && !clues.empty?)
      ready = state["completion_readiness"]
      if ready.is_a?(Hash)
        return "当前助手调用 Orbit stop(intent=complete) 并结束本轮" if ready["status"] == "ready"
        return "通知失效：#{ready['reason']}；仍需当前版本的有效手动终检" if ready["status"] == "invalidated"
        return "由当前助手在最终版本上申请手动终检；先前不可交付理由已被新证据推翻" if ready["status"] == "review_needed"
        return "补齐实际交付：#{ready['reason']}；再请求一次有效手动终检（自动检查通过不替代终检）" if ready["status"] == "not_ready"
      end
      return "等待当前助手（Root）继续执行" if waiting_for_root?(state)
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

    # The user-facing triad (kickoff ⑤): current state, why, and whether the
    # user must act now. Work the assistant can do itself (requesting checks,
    # handling findings, supplying model evidence) is labeled "由助手继续处理"
    # instead of handing the user an internal command; operator commands stay
    # in next_action and the expanded diagnostics below.
    def user_attention(state)
      status = state["status"]
      case status
      when "complete"
        "任务已完成：独立检查与停止确认均通过；无需用户操作。"
      when "paused"
        if state["completion_invalidation"].is_a?(Hash)
          "任务已停止：本次停止只确认收尾，不能确认交付已完成；无需用户操作。若仍需该交付，请创建新任务重新检查。"
        else
          "任务已停止并确认停止；无需用户操作。已停止的任务不能重检或申请完成；若仍需该交付，请创建新任务。"
        end
      when "needs_user"
        reason = attention_reason(state)
        "需要用户处理：#{reason}。该任务已停止；按上述原因处理后，若仍需交付请创建新任务。"
      when "stop_unconfirmed"
        reason = attention_reason(state)
        "停止尚未确认：#{reason}。需要重试停止收尾（orbit stop <任务>）后任务才算干净停止。"
      when "failed"
        if stop_confirmed?(state)
          "运行失败，停止已确认；无需用户操作。请查看下方运行错误，若仍需交付请创建新任务。"
        else
          "运行失败，且停止情况需核实：需要重试停止收尾（orbit stop <任务>）。"
        end
      else
        running_user_attention(state)
      end
    end

    def attention_reason(state)
      reason = [state["stop_reason"], state["error"]].find { |value| value.is_a?(String) && !value.strip.empty? }
      reason || "记录未写明具体原因，请查看任务记录"
    end

    def running_user_attention(state)
      ready = state["completion_readiness"]
      if state["completion_stop_pending"]
        "任务执行中：完成申请已入队，Orbit 正在核对停止；等待结果，无需用户操作。"
      elsif ready.is_a?(Hash) && ready["status"] == "ready"
        "当前版本可申请完成：停止收尾由助手完成；无需用户操作。"
      elsif check_in_flight?(state) || manual_check_queued?(state)
        "任务执行中：独立检查进行中或已排队，等待结果即可；无需用户操作。"
      else
        "任务执行中：执行、检查与修复由助手继续处理；需要你提供材料或做决定时，任务会明确停为「需要用户处理」。"
      end
    end

    def requirement_coverage_line(state)
      coverage = state["requirement_coverage"]
      return "要求覆盖：历史记录未提供逐项覆盖" unless state["coverage_required"] || coverage
      return "要求覆盖：尚未取得完整逐项证据" unless coverage.is_a?(Hash)
      return "要求覆盖：当前版本 #{coverage['verified']} 项已核验（检查者枚举完整）" if coverage["ready"]

      "要求覆盖：尚未确认 — #{coverage['gap'] || '有未核验要求或枚举不完整'}"
    end

    def format(record)
      state = current_state(record)
      status = state.fetch("status")
      lines = ["任务：#{summary(record)}", "状态：#{label(state)}（#{status}）",
               *([completion_invalidation_line(state)].compact),
               "用户处理：#{user_attention(state)}",
               "产物目录：#{artifact_root(state)}",
               "绑定时间：#{state.dig('workspace', 'bound_at') || '未单独记录'}",
               "最近重新绑定：#{latest_rebind(state)}",
               "执行协作：#{execution_status(state)}",
               *([recent_delegation_event(state)].compact),
               "JEV：#{jev_status(state)}",
               check_activity_line(state),
               *([checker_model_line(state)].compact),
               *([review_blocked_line(state)].compact),
               *([completion_readiness_line(state)].compact),
               requirement_coverage_line(state),
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
                    elsif check["role"] == "adjudicator"
                      "争议裁定记录，不是交付终检通过"
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
      basis = state["next_check_basis"] if %w[starting running].include?(status)
      lines << "下次检查：#{next_check || '未安排'}#{basis ? "（依据：#{basis}）" : ''}"
      lines << "运行错误：#{state['error']}" if state["error"]
      lines << "停止错误：#{state['cleanup_error']}" if state["cleanup_error"]
      lines.concat(stop_diagnostics_lines(state))
      lines << "观察说明：#{state.dig('observation_pending', 'reason')}" if state["observation_pending"]
      lines << "任务 ID：#{state.fetch('id')}"
      lines.join("\n")
    end
  end
end
