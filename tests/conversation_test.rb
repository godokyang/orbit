# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/orbit/conversation"

# The projection is read-only and offset based: only visible assistant text,
# only complete JSONL lines, no synthesized message, no task write.
module ConversationTest
  Record = Struct.new(:state, :path)
  module_function

  def assert(value, message)
    raise "ASSERTION FAILED: #{message}" unless value
  end

  def entry(id, role, text, type = "message")
    { "type" => type, "id" => id, "timestamp" => "2026-10-17T15:00:00Z",
      "message" => { "role" => role, "content" => [{ "type" => "text", "text" => text }] } }
  end

  def run
    Dir.mktmpdir("orbit-conversation") do |root|
      file = File.join(root, "session.jsonl")
      lines = [
        entry("m1", "assistant", "第一轮问题"),
        entry("m2", "user", "用户回答"),
        entry("m3", "assistant", "  "),
        entry("m4", "assistant", "第二轮问题"),
        { "type" => "message", "id" => "thinking",
          "message" => { "role" => "assistant", "content" => [{ "type" => "thinking", "thinking" => "secret" }] } },
        { "type" => "tool", "id" => "t1", "message" => { "role" => "assistant", "content" => [] } }
      ]
      first = lines.map { |line| JSON.generate(line) }.join("\n") + "\n"
      File.write(file, first + '{"type":"message","id":"partial"')
      record = Record.new(
        { "id" => "task-1", "status" => "running", "created_at" => "2026-10-17T14:00:00Z",
          "connection" => { "provider" => "omp", "thread_id" => "thread-1" },
          "root_session_file" => file },
        root
      )
      value = Orbit::Conversation.read(record, after: 0)
      assert(value["messages"].map { |item| item["id"] } == %w[m1 m4],
             "only visible assistant text is projected")
      assert(value["next_offset"] == first.bytesize, "the partial line is not consumed")
      assert(value["truncated"] == false, "a small file is not truncated")
      assert(value["session_file"] == File.realpath(file), "the real host path is reported")

      tail = Orbit::Conversation.read(record, after: value["next_offset"])
      assert(tail["messages"].empty?, "no duplicate message after next_offset")
      assert(tail["next_offset"] == value["next_offset"], "no data means no offset change")

      File.write(file, "{\"type\":\"message\"}\n", mode: "a")
      fresh = Orbit::Conversation.read(record, after: value["next_offset"])
      assert(fresh["messages"].empty?, "a complete but invisible message is not synthesized")

      failure = begin
        Orbit::Conversation.read(record, after: 10_000_000)
        false
      rescue Orbit::Conversation::Error
        true
      end
      assert(failure, "an offset beyond the file fails instead of returning empty success")

      missing = Record.new(record.state.merge("root_session_file" => File.join(root, "missing.jsonl")), root)
      failure = begin
        Orbit::Conversation.read(missing, after: 0)
        false
      rescue Orbit::Conversation::Error
        true
      end
      assert(failure, "a missing session file fails")
    end
    puts "conversation_test: ok"
  end
end

ConversationTest.run
