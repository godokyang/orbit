# frozen_string_literal: true

module Orbit
  module Connection
    class Error < StandardError; end

    def self.open(record)
      case record.fetch("provider", "codex")
      when "codex"
        CodexConnection.new(socket: record.fetch("socket"), thread_id: record.fetch("thread_id"))
      when "opencode", "omp"
        PluginConnection.new(provider: record.fetch("provider"), socket: record.fetch("socket"), thread_id: record.fetch("thread_id"))
      else
        raise Error, "unsupported session provider"
      end
    end
  end
end
