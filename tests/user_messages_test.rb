# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../lib/orbit/user_messages"

# The projection validates the native session identity and returns only real
# user messages; it never invents an id or exposes internal entries.
module UserMessagesTest
  Record = Struct.new(:state, :path)
  module_function

  def assert(value, message)
    raise "ASSERTION FAILED: #{message}" unless value
  end

  def entry(id, role, text, extra = {})
    JSON.generate({ "type" => "message", "id" => id, "timestamp" => "2026-10-18T08:00:00Z",
                    "message" => { "role" => role, "content" => [{ "type" => "text", "text" => text }] } }.merge(extra))
  end

  def run
    Dir.mktmpdir("orbit-messages") do |root|
      file = File.join(root, "session.jsonl")
      body = [
        JSON.generate({ "type" => "title", "title" => "mutable metadata" }),
        JSON.generate({ "type" => "session", "id" => "s1", "cwd" => root }),
        entry("u1", "user", "第一轮"),
        entry("a1", "assistant", "回答"),
        entry("u2", "user", "内部", "internal" => true),
        entry("u3", "user", "代理", "attribution" => "agent"),
        entry("u4", "user", "第二轮")
      ].join("\n") + "\n"
      File.write(file, body)
      state = { "id" => "task-1", "status" => "running", "created_at" => "2026-10-18T07:00:00Z",
                "connection" => { "provider" => "omp", "thread_id" => "s1" },
                "root_session_file" => file,
                "project_root" => root, "workspace" => { "artifact_root" => root } }
      value = Orbit::UserMessages.read(Record.new(state, root))
      assert(value["session_id"] == "s1", "session identity is echoed")
      assert(value["messages"].map { |item| item["id"] } == %w[u1 u4],
             "only visible user messages are projected")
      assert(value["messages"][0]["text"] == "第一轮", "text is projected")
      assert(value["truncated"] == false, "a small file is not truncated")

      wrong = state.merge("connection" => { "provider" => "omp", "thread_id" => "other" })
      failure = begin
        Orbit::UserMessages.read(Record.new(wrong, root))
        false
      rescue Orbit::UserMessages::Error
        true
      end
      assert(failure, "a mismatched native session identity fails")

      missing = File.join(root, "missing.jsonl")
      failure = begin
        Orbit::UserMessages.read(Record.new(state.merge("root_session_file" => missing), root))
        false
      rescue Orbit::UserMessages::Error
        true
      end
      assert(failure, "a missing session file fails")

      duplicate = File.join(root, "duplicate.jsonl")
      File.write(duplicate, [
        JSON.generate({ "type" => "session", "id" => "s1", "cwd" => root }),
        JSON.generate({ "type" => "session", "id" => "s1", "cwd" => root })
      ].join("\n") + "\n")
      failure = begin
        Orbit::UserMessages.read(Record.new(state.merge("root_session_file" => duplicate), root))
        false
      rescue Orbit::UserMessages::Error
        true
      end
      assert(failure, "a repeated session header fails")
    end
    puts "user_messages_test: ok"
  end
end

UserMessagesTest.run
