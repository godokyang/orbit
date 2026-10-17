# frozen_string_literal: true

require "json"
require "time"
require_relative "task_view"

module Orbit
  # Read-only, offset-based projection of the host-reported native session
  # transcript. It lets an integrator show the assistant's visible reply
  # without reading internal task files or replaying the conversation to a
  # model. It never writes, never calls a model and never infers a message
  # that the host did not record.
  module Conversation
    MAX_BYTES = 1_000_000
    MAX_MESSAGES = 100
    ROLES = %w[assistant].freeze

    class Error < StandardError; end

    module_function

    def read(record, after: 0, roles: ROLES)
      state = TaskView.current_state(record)
      file = state.dig("session_binding", "session_file")
      raise Error, "the task records no host-reported session file" unless file.is_a?(String) && !file.empty?
      raise Error, "the recorded session file is not a regular file" if File.symlink?(file) || !File.file?(file)

      offset = integer(after)
      size = File.size(file)
      raise Error, "offset is beyond the recorded session file" if offset > size

      bytes = File.open(file, "rb") { |handle| handle.seek(offset); handle.read(MAX_BYTES) } || ""
      complete_at = bytes.rindex("\n")
      return result(file, offset, offset, [], false, 0) if complete_at.nil?

      complete = bytes.byteslice(0, complete_at + 1)
      next_offset = offset + complete.bytesize
      messages = []
      dropped = 0
      complete.each_line do |line|
        entry = JSON.parse(line)
        message = visible(entry, roles)
        next if message.nil?

        if messages.length < MAX_MESSAGES
          messages << message
        else
          dropped += 1
        end
      rescue JSON::ParserError
        # A line that is not valid JSON is not guessed into a message.
        next
      end
      result(file, offset, next_offset, messages, bytes.bytesize >= MAX_BYTES, dropped)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
      raise Error, "the recorded session file could not be read (#{error.class.name})"
    end

    def visible(entry, roles)
      return nil unless entry.is_a?(Hash) && entry["type"] == "message"

      message = entry["message"]
      return nil unless message.is_a?(Hash) && roles.include?(message["role"])
      return nil if message["internal"] == true || entry["attribution"] == "agent"

      content = message["content"]
      text =
        if content.is_a?(String)
          content
        elsif content.is_a?(Array)
          content.filter_map { |part| part.is_a?(Hash) && part["type"] == "text" ? part["text"] : nil }.join
        else
          ""
        end
      text = text.to_s.strip
      return nil if text.empty?

      { "id" => entry["id"].to_s, "role" => message["role"], "text" => text,
        "created_at" => entry["timestamp"] }
    end

    def integer(value)
      parsed = value.is_a?(Integer) ? value : Integer(String(value), 10)
      raise Error, "offset must not be negative" if parsed.negative?

      parsed
    rescue ArgumentError, TypeError
      raise Error, "offset must be a non-negative integer"
    end

    def result(file, offset, next_offset, messages, truncated, dropped)
      {
        "session_file" => File.realpath(file), "offset" => offset, "next_offset" => next_offset,
        "messages" => messages, "truncated" => truncated, "dropped" => dropped,
        "read_at" => Time.now.utc.iso8601
      }
    end
  end
end
