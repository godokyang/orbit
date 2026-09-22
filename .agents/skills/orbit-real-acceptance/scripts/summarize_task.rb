#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

task_dir = ARGV.fetch(0) do
  warn "usage: summarize_task.rb /absolute/path/to/.orbit/tasks/TASK_ID"
  exit 2
end
state_path = File.join(File.expand_path(task_dir), "state.json")
events_path = File.join(File.expand_path(task_dir), "events.jsonl")
state = JSON.parse(File.read(state_path))
events = if File.exist?(events_path)
           File.readlines(events_path, chomp: true).filter_map do |line|
             JSON.parse(line)
           rescue JSON::ParserError
             nil
           end
         else
           []
         end

checks = state.fetch("checks", [])
summary = {
  "task_dir" => File.dirname(state_path),
  "id" => state["id"] || File.basename(File.dirname(state_path)),
  "status" => state["status"],
  "created_at" => state["created_at"],
  "workspace" => state["workspace"],
  "jev" => state["jev"],
  "usage" => state["usage"],
  "members" => state.fetch("members", []).map do |member|
    member.slice("kind", "adapter", "thread_id", "model", "status", "reported_turn", "stop_confirmation")
  end,
  "checks" => checks.map do |check|
    check.slice("number", "role", "kind", "started_at", "finished_at", "trigger_cause", "manual",
                "stale", "stale_reasons", "usage").merge(
      "verdict" => check.dig("result", "verdict"),
      "finding_ids" => check.dig("result", "findings")&.map { |finding| finding["id"] },
      "resolved_ids" => check.dig("result", "resolved_ids")
    )
  end,
  "findings" => state.fetch("findings", {}).transform_values do |finding|
    finding.slice("status", "check", "resolution_check", "observed_root", "observed_version", "resolution_version")
  end,
  "stop_confirmation" => state["stop_confirmation"],
  "event_counts" => events.group_by { |event| event["type"] }.transform_values(&:length),
  "timeline" => events.filter_map do |event|
    next unless %w[jev_assessed evidence_requested delegation_assessed delegation_hint delegation_hint_followed
                   member_result check_started check_finished correction_sent finalization_notice workspace_rebound stopped].include?(event["type"])

    event.slice("at", "type", "number", "check", "score", "member_fit", "parallel_gain",
                "thread_id", "status", "stale", "stale_reasons", "reason")
  end
}

puts JSON.pretty_generate(summary)
