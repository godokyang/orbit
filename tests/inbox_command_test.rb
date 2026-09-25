# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/orbit/task_record"

# N3 regression: a hand-written inbox file that is not a typed command (for
# example the OMP Root's {"action":"check","text":...}) must be rejected and
# removed with a command_rejected event instead of raising KeyError into the
# runtime loop. Valid commands still yield and are consumed.
def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition
end

@temp = Dir.mktmpdir("orbit-inbox-command-")
begin
  project = File.join(@temp, "project")
  FileUtils.mkdir_p(project)
  record = Orbit::TaskRecord.create(
    project_root: project, instruction: "x", source: {},
    connection: { "provider" => "omp", "thread_id" => "root", "socket" => File.join(@temp, "x.sock") },
    review: {}
  )
  inbox = File.join(record.path, "inbox")
  seen = []

  # N3 payload: action/text without a type.
  File.write(File.join(inbox, "check.json"), JSON.generate("action" => "check", "text" => "Done: rewrote slug()"))
  record.commands { |command| seen << command }
  assert(seen.empty?, "an untyped command must not be yielded")
  assert(!File.exist?(File.join(inbox, "check.json")), "the untyped command file is removed")
  events = File.readlines(File.join(record.path, "events.jsonl")).map { |line| JSON.parse(line) }
  rejected = events.find { |event| event["type"] == "command_rejected" }
  assert(rejected && rejected["file"] == "check.json", "the rejection is recorded with the file name")

  # Invalid JSON must not raise either.
  File.write(File.join(inbox, "bad.json"), "{not json")
  record.commands { |command| seen << command }
  assert(seen.empty?, "invalid JSON is not yielded")
  assert(!File.exist?(File.join(inbox, "bad.json")), "the invalid JSON file is removed")

  # Non-object JSON is rejected the same way.
  File.write(File.join(inbox, "array.json"), "[1,2]")
  record.commands { |command| seen << command }
  assert(seen.empty?, "a non-object payload is not yielded")
  assert(!File.exist?(File.join(inbox, "array.json")), "the non-object file is removed")

  # A valid command still works.
  File.write(File.join(inbox, "valid.json"), JSON.generate("type" => "check"))
  record.commands { |command| seen << command }
  assert(seen.length == 1 && seen.first["type"] == "check", "a valid command is yielded")
  assert(!File.exist?(File.join(inbox, "valid.json")), "a consumed command is removed")

  puts "inbox_command_test: PASS"
ensure
  FileUtils.remove_entry(@temp)
end
