# frozen_string_literal: true

require_relative "task_record"

module Orbit
  # Read-only project selection and presentation; the runtime remains the writer.
  module TaskView
    SETTLED = %w[complete paused needs_user].freeze
    STALE_REASONS = {
      "artifact" => "产物变化", "input" => "输入变化", "host" => "Root 执行状态变化", "dispute" => "争议状态变化"
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

    def list(records)
      records.map do |record|
        state = record.state
        "#{state.fetch('id')}  #{LABELS.fetch(state['status'], state['status'])}  #{summary(record)}"
      end.join("\n")
    end

    def format(record)
      state = record.state
      status = state.fetch("status")
      lines = ["任务：#{summary(record)}", "状态：#{LABELS.fetch(status, status)}（#{status}）"]
      check = state.fetch("checks", []).last
      if check
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
      next_check = %w[starting running].include?(status) ? state["next_check_at"] : nil
      basis = state["next_check_basis"]
      lines << "下次检查：#{next_check || '未安排'}#{basis ? "（依据：#{basis}）" : ''}"
      attention = case status
                  when "needs_user", "failed", "stop_unconfirmed"
                    state["stop_reason"] || state["error"] || "请核对任务错误及停止结果。"
                  else
                    "当前记录未要求用户处理"
                  end
      lines << "用户处理：#{attention}"
      lines << "运行错误：#{state['error']}" if state["error"]
      lines << "停止错误：#{state['cleanup_error']}" if state["cleanup_error"]
      lines << "观察说明：#{state.dig('observation_pending', 'reason')}" if state["observation_pending"]
      lines << "任务 ID：#{state.fetch('id')}"
      lines.join("\n")
    end
  end
end
