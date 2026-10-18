# frozen_string_literal: true

require "json"
require "time"
require_relative "task_view"

module Orbit
  # Read-only projection of the native user messages the host recorded in the
  # task's session file. It lets an integrator replace its own session-file
  # parsing without reading internal task files or replaying the conversation
  # to a model. It never writes, never calls a model and never invents an id.
  module UserMessages
    MAX_MESSAGES = 200

    class Error < StandardError; end

    module_function

    def read(record)
      state = TaskView.current_state(record)
      binding = state["session_binding"].is_a?(Hash) ? state["session_binding"] : {}
      file = binding["session_file"]
      session_id = binding["session_id"]
      unless file.is_a?(String) && !file.empty? && session_id.is_a?(String) && !session_id.empty?
        raise Error, "the task records no host-reported session file and identity"
      end
      raise Error, "the recorded session file is not a regular file" if File.symlink?(file) || !File.file?(file)

      accepted = workspace_paths(state)
      messages = []
      dropped = 0
      seen_header = false
      File.foreach(file, chomp: true) do |line|
        next if line.strip.empty?

        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          raise Error, "the session file contains a line that is not JSON"
        end
        next unless entry.is_a?(Hash)
        next if !seen_header && entry["type"] == "title"

        unless seen_header
          unless entry["type"] == "session" && entry["id"] == session_id &&
                 entry["cwd"].is_a?(String) && accepted.include?(File.expand_path(entry["cwd"]))
            raise Error, "the native session identity or project differs"
          end

          seen_header = true
          next
        end
        raise Error, "the native session header is repeated" if entry["type"] == "session"

        message = visible_user(entry)
        next if message.nil?

        if messages.length < MAX_MESSAGES
          messages << message
        else
          dropped += 1
        end
      end
      raise Error, "the native session header is missing" unless seen_header

      { "session_id" => session_id, "session_file" => File.realpath(file),
        "messages" => messages, "truncated" => dropped.positive?, "dropped" => dropped,
        "read_at" => Time.now.utc.iso8601 }
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
      raise Error, "the recorded session file could not be read (#{error.class.name})"
    end

    def visible_user(entry)
      return nil unless entry["type"] == "message"
      return nil if entry["internal"] == true || entry["attribution"] == "agent"

      message = entry["message"]
      return nil unless message.is_a?(Hash)
      return nil unless message["role"] == "user"
      return nil if message["internal"] == true || message["attribution"] == "agent"

      ident = entry["id"]
      ident = entry["item_id"] if !ident.is_a?(String) || ident.strip.empty?
      return nil unless ident.is_a?(String) && !ident.strip.empty?
      return nil if ident.match?(/[\u0000-\u001f]/)

      { "id" => ident, "text" => text(message["content"]), "created_at" => entry["timestamp"] }
    end

    def text(content)
      if content.is_a?(String)
        content
      elsif content.is_a?(Array)
        content.filter_map { |part| part.is_a?(Hash) && part["type"] == "text" ? part["text"] : nil }.join
      else
        ""
      end
    end

    def workspace_paths(state)
      paths = []
      [state["project_root"], state.dig("workspace", "artifact_root")].each do |value|
        paths << File.expand_path(value) if value.is_a?(String) && !value.empty?
      end
      paths.uniq
    end
  end
end
