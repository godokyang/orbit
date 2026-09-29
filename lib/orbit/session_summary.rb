# frozen_string_literal: true

require "json"
require_relative "task_view"

module Orbit
  # A local fact report, not an LLM judgment or a cost estimate. Missing
  # event streams and unreported usage remain unknown, never synthetic zeros.
  module SessionSummary
    module_function

    def report(project:, thread:)
      root = File.realpath(project)
      tasks_root = File.join(root, ".orbit", "tasks")
      raise ArgumentError, "no Orbit task directory in #{root}" unless File.directory?(tasks_root)

      tasks = Dir.glob(File.join(tasks_root, "*", "state.json")).filter_map do |file|
        dir = File.dirname(file)
        next if File.symlink?(dir) || File.symlink?(file)
        state = JSON.parse(File.read(file))
        next unless state["format"] == "orbit-task-1" && state["project_root"] == root &&
                    state.dig("connection", "thread_id") == thread
        summarize(dir, TaskView.current_state(TaskRecord.new(dir)))
      end.sort_by { |task| [task.fetch("created_at"), task.fetch("id")] }
      counts = %w[checks stale_checks manual_checks process_checks failed_checks jev_assessments
                  correction_sent findings members model_evidence_requests].to_h do |key|
        [key, tasks.any? { |task| task[key].nil? } ? nil : tasks.sum { |task| task.fetch(key) }]
      end
      known = tasks.sum { |task| task["checker_tokens_observed"] }
      { "thread_id" => thread, "project_root" => root, "tasks" => tasks, "counts" => counts,
        "usage" => { "checker_tokens_observed" => known,
                     "checker_tokens_complete" => tasks.all? { |task| task["checker_tokens_complete"] },
                     "root_tokens" => nil, "member_tokens" => nil, "task_total_tokens" => nil,
                     "currency_cost" => nil } }
    end

    def summarize(dir, state)
      events_path = File.join(dir, "events.jsonl")
      event_counts = Hash.new(0)
      events_complete = File.file?(events_path)
      if events_complete
        File.foreach(events_path) do |line|
          event = JSON.parse(line)
          event_counts[event.fetch("type")] += 1
        rescue JSON::ParserError, KeyError
          events_complete = false
        end
      end
      checks = Array(state["checks"])
      known = checks.filter_map { |check| TaskView.token_pair(check["usage"]) }.sum { |pair| pair.sum }
      { "id" => state.fetch("id"), "created_at" => state.fetch("created_at"),
        "status" => state.fetch("status"), "stop_confirmed" => state.dig("stop_confirmation", "confirmed"),
        "collaboration_log" => File.file?(File.join(dir, "collaboration.jsonl")) ? "present" : "missing",
        "events_complete" => events_complete,
        "checks" => checks.length, "stale_checks" => checks.count { |check| check["stale"] == true },
        "manual_checks" => checks.count { |check| check["manual"] == true },
        "process_checks" => checks.count { |check| check["kind"] == "process" },
        "failed_checks" => events_complete ? event_counts["check_failed"] : nil,
        "jev_assessments" => events_complete ? event_counts["jev_assessed"] : nil,
        "correction_sent" => events_complete ? event_counts["correction_sent"] : nil,
        "model_evidence_requests" => events_complete ? event_counts["model_evidence_needed"] : nil,
        "findings" => checks.flat_map { |check| Array(check.dig("result", "findings")) }
                            .filter_map { |finding| finding["id"] }.uniq.length,
        "members" => Array(state["members"]).length,
        "checker_tokens_observed" => known,
        "checker_tokens_complete" => checks.all? { |check| !TaskView.token_pair(check["usage"]).nil? },
        "resource_calls" => state.dig("usage", "resource_calls"),
        "resource_call_gaps" => state.dig("usage", "resource_call_gaps"),
        "requirement_coverage" => state["requirement_coverage"],
        "native_call_observations" => state.dig("usage", "native_call_observations") }
    end
  end
end
