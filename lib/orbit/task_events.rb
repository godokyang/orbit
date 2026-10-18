# frozen_string_literal: true

require "json"
require "time"
require_relative "task_view"

module Orbit
  # Read-only, cursor-based projection of the task's own event log.
  # It exposes a frozen subset of internal event types so an integrator can
  # follow checks, findings, corrections and stop facts without reading
  # internal task files or polling status diffs. It never writes, never calls
  # a model and never synthesizes an event the program did not record.
  module TaskEvents
    MAX_BYTES = 1_000_000
    MAX_EVENTS = 200

    # Internal type => retained fields. A type outside this table is counted
    # as skipped and never projected. Fields not listed are dropped, including
    # workspace paths, free-form reasons, error text and problem bodies.
    WHITELIST = {
      "check_started" => %w[number role check_kind trigger manual model input_digest artifact_digest],
      "check_finished" => %w[number stale stale_reasons verdict finding_ids resolved_ids artifact_digest],
      "check_failed" => %w[number failure_kind],
      "finding_recorded" => %w[check],
      "finding_resolved" => %w[id check],
      "instruction_amended" => %w[source],
      "correction_sent" => %w[id artifact_digest input_digest],
      "finalization_notice" => %w[check version],
      "completion_stop_queued" => [],
      "stopped" => [],
      "stop_unconfirmed" => [],
      "member_settled" => %w[thread_id status]
    }.freeze

    class Error < StandardError; end

    module_function

    def read(record, after: 0)
      offset = integer(after)
      file = File.join(record.path, "events.jsonl")
      # A task may exist before its first event is written. That is an empty
      # projection, not a failure, and the caller keeps its cursor.
      return empty(offset) unless File.exist?(file)
      raise Error, "the events file is not a regular file" if File.symlink?(file) || !File.file?(file)

      size = File.size(file)
      raise Error, "cursor is beyond the events file" if offset > size

      bytes = File.open(file, "rb") do |handle|
        handle.seek(offset)
        handle.read(MAX_BYTES)
      end || ""
      complete_at = bytes.rindex("\n")
      return empty(offset) if complete_at.nil?

      complete = bytes.byteslice(0, complete_at + 1)
      next_offset = offset + complete.bytesize
      events = []
      skipped = 0
      unreadable = 0
      dropped = 0
      complete.each_line do |line|
        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          unreadable += 1
          next
        end
        event = project(entry)
        if event.nil?
          skipped += 1
        elsif events.length < MAX_EVENTS
          events << event
        else
          dropped += 1
        end
      end
      result(offset, next_offset, events, bytes.bytesize >= MAX_BYTES || dropped.positive?, skipped, unreadable, dropped)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
      raise Error, "the events file could not be read (#{error.class.name})"
    end

    def project(entry)
      return nil unless entry.is_a?(Hash)

      kind = entry["type"].to_s
      fields = WHITELIST[kind]
      return nil if fields.nil?

      event = { "kind" => kind, "at" => entry["at"] }
      fields.each do |field|
        case field
        when "source"
          event["source"] = projection_source(entry["source"])
        when "check_kind"
          # The envelope already uses `kind` for the event type; the check's
          # own kind travels as `check_kind` so the two never collide.
          event["check_kind"] = entry["kind"] if entry.key?("kind")
        else
          event[field] = entry[field] if entry.key?(field)
        end
      end
      event["finding_id"] = entry.dig("finding", "id") if kind == "finding_recorded"
      event["confirmed"] = entry.dig("confirmation", "confirmed") == true if kind == "stopped"
      event.compact
    end

    def projection_source(source)
      return { "kind" => "unknown", "id" => nil } unless source.is_a?(Hash)

      { "kind" => source["kind"].to_s, "id" => source["id"] }
    end

    def empty(offset)
      result(offset, offset, [], false, 0, 0, 0)
    end

    def result(cursor, next_cursor, events, truncated, skipped, unreadable, dropped)
      {
        "cursor" => cursor, "next_cursor" => next_cursor,
        "events" => events, "truncated" => truncated,
        "skipped" => skipped, "unreadable" => unreadable, "dropped" => dropped,
        "read_at" => Time.now.utc.iso8601
      }
    end

    def integer(value)
      parsed = value.is_a?(Integer) ? value : Integer(String(value), 10)
      raise Error, "cursor must not be negative" if parsed.negative?

      parsed
    rescue ArgumentError, TypeError
      raise Error, "cursor must be a non-negative integer"
    end
  end
end
