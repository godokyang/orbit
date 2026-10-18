# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/orbit/task_events"

# The projection is read-only and cursor based: a frozen subset of event
# types, complete lines only, no path or free-form text, no synthesized event.
module TaskEventsTest
  Record = Struct.new(:state, :path)
  module_function

  def assert(value, message)
    raise "ASSERTION FAILED: #{message}" unless value
  end

  def line(type, fields = {})
    JSON.generate({ "at" => "2026-10-18T08:00:00Z", "type" => type }.merge(fields)) + "\n"
  end

  def run
    Dir.mktmpdir("orbit-events") do |root|
      file = File.join(root, "events.jsonl")
      body = +""
      body << line("check_started", "number" => 1, "role" => "artifact", "kind" => "review",
                   "trigger" => "timer", "manual" => false, "model" => "p/m",
                   "input_digest" => "in", "artifact_digest" => "art", "artifact_root" => "/secret")
      body << line("check_finished", "number" => 1, "stale" => false, "stale_reasons" => [],
                   "verdict" => "correct", "reason" => "free text",
                   "finding_ids" => ["F1"], "resolved_ids" => [], "artifact_digest" => "art")
      body << line("finding_recorded", "check" => 1,
                   "finding" => { "id" => "F1", "problem" => "secret body" })
      body << line("instruction_amended",
                   "source" => { "kind" => "native_user_message", "id" => "m1", "path" => "/secret" })
      body << line("stopped", "reason" => "done",
                   "confirmation" => { "confirmed" => true, "detail" => "secret" })
      body << line("runtime_error", "error" => "secret")
      body << "not json\n"
      body << '{"at":"2026-10-18T08:01:00Z","type":"check_failed"'
      File.write(file, body)
      record = Record.new({}, root)

      value = Orbit::TaskEvents.read(record, after: 0)
      assert(value["events"].map { |event| event["kind"] } ==
             %w[check_started check_finished finding_recorded instruction_amended stopped],
             "only whitelisted events are projected")
      assert(value["skipped"] == 1, "unknown types are counted, not projected")
      assert(value["unreadable"] == 1, "a non-JSON line is counted, not guessed")
      assert(value["truncated"] == false, "a small file is not truncated")
      assert(value["next_cursor"] < File.size(file), "the partial line is not consumed")
      text = JSON.generate(value)
      %w[artifact_root free\ text secret\ body path detail].each do |word|
        assert(!text.include?(word), "trimmed content is absent: #{word}")
      end
      assert(value["events"][0]["number"] == 1, "retained fields survive")
      assert(value["events"][2]["finding_id"] == "F1", "finding id is projected")
      assert(value["events"][3]["source"] == { "kind" => "native_user_message", "id" => "m1" },
             "the amendment source is reduced to kind and id")
      assert(value["events"][4]["confirmed"] == true, "stop confirmation is projected")

      File.write(file, ",\"number\":2,\"failure_kind\":\"auth_or_quota\"}\n", mode: "a")
      tail = Orbit::TaskEvents.read(record, after: value["next_cursor"])
      assert(tail["events"].map { |event| event["kind"] } == %w[check_failed],
             "a completed partial line is consumed on the next read")
      assert(tail["events"][0]["number"] == 2, "failed check retains its number")

      same = Orbit::TaskEvents.read(record, after: tail["next_cursor"])
      assert(same["events"].empty? && same["next_cursor"] == tail["next_cursor"],
             "no data means no offset change")

      missing = Record.new({}, Dir.mktmpdir("orbit-events-empty"))
      empty = Orbit::TaskEvents.read(missing, after: 7)
      assert(empty["events"].empty? && empty["cursor"] == 7 && empty["next_cursor"] == 7,
             "a task without an events file returns the cursor unchanged")

      failure = begin
        Orbit::TaskEvents.read(record, after: 10_000_000)
        false
      rescue Orbit::TaskEvents::Error
        true
      end
      assert(failure, "a cursor beyond the file fails instead of returning empty success")

      many = File.join(root, "many")
      FileUtils.mkdir_p(many)
      File.write(File.join(many, "events.jsonl"),
                 Array.new(205) { |index| line("check_failed", "number" => index + 1, "failure_kind" => "k") }.join)
      capped = Orbit::TaskEvents.read(Record.new({}, many), after: 0)
      assert(capped["events"].length == 200, "the event cap is enforced")
      assert(capped["dropped"] == 5 && capped["truncated"] == true, "overflow is reported")
    end
    puts "task_events_test: ok"
  end
end

TaskEventsTest.run
