# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "digest"
require_relative "../lib/orbit/task_record"
require_relative "../lib/orbit/task_evidence"
# `orbit export TASK --output FILE` regression: one local command packs a
# self-contained task evidence archive that separates complete from incomplete
# observation — task-attributable facts only, honest gaps, no task mutation.
module TaskEvidenceExportTest
  ENTRY = File.expand_path("../scripts/orbit", __dir__)
  module_function

  def assert(value, message)
    raise message unless value
  end

  def cli(*args, cwd: @project, success: true)
    out, err, status = Open3.capture3({ "XDG_CONFIG_HOME" => @temp, "XDG_CACHE_HOME" => @temp,
                                        "PI_CODING_AGENT_DIR" => File.join(@temp, "agent-store") },
                                      RbConfig.ruby, "--disable-gems", ENTRY, *args, chdir: cwd)
    assert(status.success? == success, "#{args.inspect}\n#{out}\n#{err}")
    out + err
  end

  def task(status = "running", **extra)
    record = Orbit::TaskRecord.create(project_root: @project, instruction: "实现并验证导出", source: {},
                                      connection: { "provider" => "omp", "thread_id" => "root", "socket" => File.join(@temp, "host.sock") },
                                      review: {})
    state = record.state.merge("status" => status).merge(extra.transform_keys(&:to_s))
    record.save(state)
    record
  end

  def export_and_unpack(record)
    archive = File.join(@temp, "evidence.tar.gz")
    summary = JSON.parse(cli("export", record.path, "--output", archive).lines.last)
    unpack = File.join(@temp, "unpack")
    FileUtils.mkdir_p(unpack)
    _out, err, status = Open3.capture3("tar", "-xzf", archive, "-C", unpack)
    assert(status.success?, "system tar extracts the archive: #{err}")
    [summary, archive, unpack, JSON.parse(File.read(File.join(unpack, "manifest.json")))]
  end

  def timeline(unpack)
    File.readlines(File.join(unpack, "timeline.jsonl")).map { |line| JSON.parse(line) }
  end

  def names(archive)
    out, err, status = Open3.capture3("tar", "-tzf", archive)
    assert(status.success?, "system tar lists the archive: #{err}")
    out.lines.map(&:strip)
  end

  # Given a running task with events, a check directory and live artifacts;
  # When the user exports it; Then the archive is self-contained, excludes
  # non-evidence, labels the snapshot in flight and inventories every file.
  def export_running_task_packs_evidence_and_marks_in_flight
    record = task
    FileUtils.mkdir_p(File.join(record.path, "inbox"))
    File.write(File.join(record.path, "inbox/pending.json"), '{"type":"stop"}')
    File.write(File.join(record.path, "runtime.lock"), "")
    File.write(File.join(record.path, "members.lock"), "")
    File.write(File.join(record.path, "leftover.tmp"), "partial")
    FileUtils.mkdir_p(File.join(record.path, "checks/1/profile"))
    File.write(File.join(record.path, "checks/1/scope.json"), "{}\n")
    File.write(File.join(record.path, "checks/1/evidence.json"), '{"verdict":"fail"}')
    File.write(File.join(record.path, "checks/1/profile/agent.db"), "db")
    File.symlink(@project, File.join(record.path, "escaping-link"))
    File.symlink("real-inside-name", File.join(record.path, "chained-link"))
    File.symlink(@temp, File.join(record.path, "real-inside-name"))
    File.symlink("state.json", File.join(record.path, "inside-link"))
    File.open(File.join(record.path, "events.jsonl"), "a") do |file|
      file.puts JSON.generate({ "at" => "2026-09-26T10:00:00Z", "type" => "check_started", "number" => 1 })
      file.puts JSON.generate({ "at" => "2026-09-26T10:00:01Z", "type" => "checker_model_selected",
                                "source" => "explicit", "model" => "provider/checker" })
    end
    state = record.state
    state["checks"] = [{ "number" => 1, "role" => "reviewer", "kind" => "artifact",
                         "started_at" => "2026-09-26T10:00:00Z", "result" => { "verdict" => "fail" } }]
    record.save(state)
    before = Dir.glob(File.join(record.path, "**/*")).sort

    summary, archive, unpack, manifest = export_and_unpack(record)
    assert(summary["task_id"] == record.state.fetch("id") && summary["in_flight"] == true &&
           summary["files"].positive? && summary["bytes"].positive?, "summary reports the export: #{summary}")
    listed = names(archive)
    %w[manifest.json timeline.jsonl task/state.json task/events.jsonl task/instruction.txt
       task/checks/1/evidence.json task/checks/1/profile/agent.db task/inside-link].each do |name|
      assert(listed.include?(name), "archive contains #{name}")
    end
    %w[task/runtime.lock task/members.lock task/inbox/pending.json task/leftover.tmp
       task/checks/1/profile/agent.db-wal task/escaping-link task/chained-link
       task/real-inside-name].each do |name|
      assert(!listed.include?(name), "archive excludes #{name}")
    end
    assert(Dir.glob(File.join(record.path, "**/*")).sort == before, "export does not touch the task directory")
    assert(manifest.fetch("archive_format") == "orbit-task-evidence-export-1" &&
           manifest.dig("task", "in_flight") == true && manifest.dig("task", "note"), "running task labelled in flight")
    state_entry = manifest.fetch("files").find { |entry| entry["path"] == "state.json" }
    assert(state_entry["sha256"] == Digest::SHA256.hexdigest(File.read(File.join(record.path, "state.json"))),
           "inventory sha256 matches the archived bytes")
    timeline_entry = manifest.fetch("files").find { |entry| entry["path"] == "timeline.jsonl" }
    assert(timeline_entry["sha256"] == Digest::SHA256.file(File.join(unpack, "timeline.jsonl")).hexdigest,
           "generated timeline is included in the integrity inventory")
    assert(manifest.fetch("excluded").any? { |entry| entry["path"] == "escaping-link" },
           "excluded symlinks are reported, not silently dropped")
    started = timeline(unpack).find { |entry| entry["type"] == "check_started" }
    assert(started["check_directory"] == "task/checks/1", "check events link their archived evidence directory")
    selected = timeline(unpack).find { |entry| entry["type"] == "checker_model_selected" }
    assert(selected["source"] == "events.jsonl" && selected["event_source"] == "explicit",
           "the original model-choice source never overwrites timeline provenance")
  end

  # Given collaboration evidence mixing attributable lines, a foreign task,
  # a seq gap and an invalid line, and an events log without a trailing
  # newline; When exported; Then only attributable facts are copied and every
  # gap, invalid line and truncation is marked.
  def export_joins_collaboration_and_marks_gaps
    record = task
    File.open(File.join(record.path, "events.jsonl"), "a") do |file|
      file.puts JSON.generate({ "at" => "2026-09-26T10:00:00Z", "type" => "attached", "thread_id" => "x" })
      file.write('{"at":"2026-09-26T12:00:00Z","type":"attached"')
    end
    File.open(File.join(record.path, "collaboration.jsonl"), "a") do |file|
      # omp-host plugin shape: task_dir attribution, durable monotonic seq,
      # and persistence_gap lines that themselves consume a sequence number.
      file.puts JSON.generate({ "at" => "2026-09-26T09:00:00Z", "seq" => 1, "kind" => "hub_call",
                                "task_dir" => record.path, "session_id" => "root", "agent_id" => nil, "to" => "a" })
      file.puts JSON.generate({ "at" => "2026-09-26T09:04:00Z", "seq" => 2, "kind" => "persistence_gap",
                                "task_dir" => record.path, "session_id" => nil, "agent_id" => nil,
                                "lost_count" => 3, "reason" => "buffer cap" })
      file.puts JSON.generate({ "at" => "2026-09-26T09:05:00Z", "seq" => 5, "kind" => "hub_call",
                                "task_dir" => record.path, "session_id" => "root", "agent_id" => nil, "to" => "b" })
      file.puts JSON.generate({ "at" => "2026-09-26T09:06:00Z", "seq" => 6, "kind" => "hub_call",
                                "task_dir" => "/somewhere/else", "session_id" => "root", "agent_id" => nil, "to" => "c" })
      file.puts "{ not json"
    end

    _summary, _archive, unpack, manifest = export_and_unpack(record)
    facts = timeline(unpack)
    assert(facts.first.fetch("source") == "collaboration.jsonl", "timeline is ordered by time")
    assert(facts.none? { |entry| entry["to"] == "c" }, "foreign-task session lines are never copied")
    packaged = File.read(File.join(unpack, "task/collaboration.jsonl"))
    assert(packaged.include?('"to":"b"') && packaged.include?("persistence_gap"), "attributable lines are packaged")
    assert(!packaged.include?('"to":"c"') && !packaged.include?("not json"),
           "foreign and unparseable lines are not packaged: #{packaged}")
    assert(manifest.fetch("files").find { |f| f["path"] == "collaboration.jsonl" }["sha256"] ==
           Digest::SHA256.hexdigest(packaged), "packaged subset is recorded with its own digest")
    assert(manifest.fetch("missing").any? { |m| m["item"] == "collaboration.jsonl" && m["reason"].include?("subset") },
           "subsetting is announced as a gap, not done silently")
    assert(manifest.fetch("missing").none? { |m| m["item"] == "collaboration.jsonl" &&
           m["reason"].include?("file changed during export") },
           "a static collaboration source does not produce a false concurrent-change claim")
    assert(facts.any? { |entry| entry["gap"] && entry["detail"].include?("seq 3..4 missing") }, "seq gap is marked")
    assert(facts.any? { |entry| entry["kind"] == "persistence_gap" }, "recorded plugin gap lines stay in the timeline")
    assert(facts.any? { |entry| entry["invalid"] && entry["source"] == "collaboration.jsonl" }, "invalid collaboration line is marked")
    assert(facts.any? { |entry| entry["truncated"] && entry["source"] == "events.jsonl" }, "mid-append trailing line is marked truncated")
    collaboration = manifest.fetch("sources").fetch("collaboration")
    assert(collaboration.fetch("attributable") == 3 && collaboration.fetch("unattributable") == 1,
           "attribution is counted separately: #{collaboration}")
    assert(collaboration.fetch("packaged") == "task-attributable subset", "packaging mode is stated")
    assert(manifest.fetch("sources").fetch("events").fetch("complete") == false, "completeness is stated, not assumed")
  end

  # Given absent, invalid or unreferenced evidence; When exported; Then the
  # manifest lists every gap instead of claiming a complete observation.
  def export_marks_absent_and_invalid_evidence
    record = task("complete", finished_at: "2026-09-26T13:00:00Z")
    File.unlink(File.join(record.path, "events.jsonl")) if File.exist?(File.join(record.path, "events.jsonl"))
    File.write(File.join(record.path, "members.json"), "{ broken")
    state = record.state
    state["basis"] = [{ "source" => "/gone.md", "path" => "basis/0-gone.md", "sha256" => Digest::SHA256.hexdigest("x") }]
    state["checks"] = [{ "number" => 7, "role" => "reviewer", "kind" => "artifact",
                         "started_at" => "2026-09-26T10:00:00Z", "finished_at" => "2026-09-26T10:01:00Z" }]
    record.save(state)

    _summary, _archive, unpack, manifest = export_and_unpack(record)
    items = manifest.fetch("missing").map { |entry| entry["item"] }
    assert(items.include?("events.jsonl") && items.include?("members.json") &&
           items.include?("collaboration.jsonl"), "absent and invalid evidence is listed: #{items}")
    assert(items.include?("basis/0-gone.md") && items.include?("checks/7"),
           "state references without files are listed: #{items}")
    assert(manifest.dig("sources", "members", "status") == "invalid" &&
           manifest.dig("task", "in_flight") == false, "invalid members and terminal status are facts")
  end


  # Given a fake OMP agent store with the Root transcript (lines before,
  # inside and after the task window, plus an id-mismatching decoy) and one
  # member transcript plus one member without a file; When exported; Then the
  # Root segment is time-scoped and id-verified, the member file is copied in
  # full only when its header verifies, and every other session is an
  # explicit missing entry.
  def export_copies_verified_task_scoped_native_sessions
    record = task
    state = record.state.merge(
      "connection" => { "provider" => "omp", "thread_id" => "root-session-1", "socket" => "/s" },
      "members" => [{ "thread_id" => "orbit-member-1" }, { "thread_id" => "orbit-member-2" },
                    { "thread_id" => "../unsafe" }],
      "created_at" => "2026-09-26T10:02:00Z", "status" => "complete", "finished_at" => "2026-09-26T10:05:00Z"
    )
    record.save(state)
    File.write(File.join(record.path, "members.json"), JSON.generate([
      { "thread_id" => "orbit-member-1", "status" => "registered" },
      { "thread_id" => "orbit-member-2", "status" => "registered" }
    ]))
    store = File.join(@temp, "agent-store", "sessions", "-project-")
    FileUtils.mkdir_p(store)
    root_lines = [
      JSON.generate({ "type" => "session", "id" => "root-session-1", "timestamp" => "2026-09-26T10:00:00Z" }),
      JSON.generate({ "type" => "message", "timestamp" => "2026-09-26T10:01:00Z", "text" => "before the task" }),
      JSON.generate({ "type" => "message", "timestamp" => "2026-09-26T10:03:00Z", "text" => "during the task" }),
      JSON.generate({ "type" => "message", "timestamp" => "2026-09-26T10:04:00Z", "text" => "still during" }),
      JSON.generate({ "type" => "message", "timestamp" => "2026-09-26T11:00:00Z", "text" => "after the export window" })
    ]
    File.write(File.join(store, "2026-09-26T10-00-00-000Z_root-session-1.jsonl"), root_lines.join("\n") + "\n")
    File.write(File.join(store, "2026-09-26T10-02-30-000Z_orbit-member-1.jsonl"),
               JSON.generate({ "type" => "session", "id" => "orbit-member-1", "timestamp" => "2026-09-26T10:02:30Z" }) + "\n" +
               JSON.generate({ "type" => "message", "timestamp" => 1790430098678, "text" => "member work" }) + "\n")
    File.write(File.join(store, "2026-09-26T10-02-40-000Z_orbit-member-2.jsonl"),
               JSON.generate({ "type" => "session", "id" => "someone-else", "timestamp" => "2026-09-26T10:02:40Z" }) + "\n")

    Orbit::TaskEvidence.export(record: record, output: File.join(@temp, "s.tar.gz"),
                               agent_dir: File.join(@temp, "agent-store"))
    unpack = File.join(@temp, "sunpack")
    FileUtils.mkdir_p(unpack)
    Open3.capture3("tar", "-xzf", File.join(@temp, "s.tar.gz"), "-C", unpack)
    manifest = JSON.parse(File.read(File.join(unpack, "manifest.json")))
    root_packaged = File.readlines(File.join(unpack, "sessions/root-session-1.jsonl")).map { |l| JSON.parse(l) }
    assert(root_packaged.length == 2 && root_packaged.all? { |l| l["text"] },
           "root session packaged only inside the task time window: #{root_packaged}")
    member = manifest.fetch("sources").fetch("sessions").find { |s| s["session_id"] == "orbit-member-1" }
    root_inventory = manifest.fetch("files").find { |entry| entry["path"] == "sessions/root-session-1.jsonl" }
    assert(root_inventory["sha256"] == Digest::SHA256.hexdigest(File.binread(File.join(unpack, root_inventory["path"]))),
           "session evidence appears in the archive digest inventory")
    assert(member.fetch("status") == "included" && member.fetch("scope") == "full session",
           "verified member session copied in full")
    decoy = manifest.fetch("sources").fetch("sessions").find { |s| s["session_id"] == "orbit-member-2" }
    assert(decoy.fetch("status") == "unverified" && !File.exist?(File.join(unpack, "sessions/orbit-member-2.jsonl")),
           "id-mismatching member transcript is never copied")
    items = manifest.fetch("missing").map { |m| m["item"] }
    assert(items.include?("session:orbit-member-2"), "unverified session is a missing entry")
    invalid = manifest.fetch("sources").fetch("sessions").find { |s| s["session_id"] == "../unsafe" }
    assert(invalid["status"] == "invalid_id" && !File.exist?(File.join(unpack, "unsafe.jsonl")) &&
           items.include?("session:../unsafe"), "malformed session ids cannot create traversal archive entries")
    root_entry = manifest.fetch("sources").fetch("sessions").find { |s| s["role"] == "root" }
    assert(root_entry.dig("window", "begin") == "2026-09-26T10:02:00Z" && root_entry["lines_outside_task_scope"] == 3,
           "window basis and omitted count are stated")
  end

  # Given a task file that changes size while being packaged; When the tar
  # member is written; Then the export aborts with a clean error instead of
  # writing a member whose header disagrees with its bytes.
  def export_aborts_when_packaged_files_change_size
    file = File.join(@temp, "growing.jsonl")
    File.write(file, "x" * 100)
    trigger = Class.new do
      def initialize(action) = @action = action
      def write(_chunk) = @action.call
    end
    shrink = trigger.new(-> { File.truncate(file, 40) })
    error = assert_raises(Orbit::TaskEvidence::Error) do
      Orbit::TaskEvidence::TarWriter.new(shrink).write_file("growing.jsonl", file)
    end
    assert(error.message.include?("shrank"), "shrink detected: #{error.message}")
    File.write(file, "x" * 100)
    grow = trigger.new(-> { File.open(file, "a") { |appended| appended.write("y" * 10) } })
    error = assert_raises(Orbit::TaskEvidence::Error) do
      Orbit::TaskEvidence::TarWriter.new(grow).write_file("growing.jsonl", file)
    end
    assert(error.message.include?("grew"), "growth detected: #{error.message}")
  end

  # Given unsafe destinations or non-task arguments; When exported; Then the
  # command refuses and leaves neither a task change nor a partial archive.
  def export_refuses_unsafe_destinations_and_non_tasks
    record = task
    inside = File.join(record.path, "inside.tar.gz")
    cli("export", record.path, "--output", inside, success: false)
    assert(!File.exist?(inside) && Dir[File.join(record.path, "*.tar.gz")].empty?, "no partial archive in the task directory")
    output = cli("export", record.state.fetch("id")[0, 8], "--output", File.join(@temp, "ok.tar.gz"))
    assert(JSON.parse(output.lines.last)["task_id"] == record.state.fetch("id"), "unique id prefix resolves the task")
    original_digest = Digest::SHA256.file(File.join(@temp, "ok.tar.gz")).hexdigest
    cli("export", record.path, "--output", File.join(@temp, "ok.tar.gz"), success: false)
    assert(Digest::SHA256.file(File.join(@temp, "ok.tar.gz")).hexdigest == original_digest,
           "a second export cannot overwrite the user's existing archive")
    FileUtils.rm(File.join(@temp, "ok.tar.gz"))
    cli("export", "--output", File.join(@temp, "x.tar.gz"), success: false)
    cli("export", record.path, "--output", File.join(@temp, "missing-dir/x.tar.gz"), success: false)
    cli("export", @project, "--output", File.join(@temp, "x.tar.gz"), success: false)
    cli("export", "deadbeef", "--output", File.join(@temp, "x.tar.gz"), success: false)
    assert(Dir[File.join(@temp, "*.tar.gz")].empty?, "refused exports write nothing")
  end

  def main
    %i[export_running_task_packs_evidence_and_marks_in_flight
       export_joins_collaboration_and_marks_gaps
       export_marks_absent_and_invalid_evidence
       export_copies_verified_task_scoped_native_sessions
       export_aborts_when_packaged_files_change_size
       export_refuses_unsafe_destinations_and_non_tasks].each do |test|
      Dir.mktmpdir("orbit-export-test-") do |tmp|
        @temp = tmp
        @project = File.join(tmp, "project")
        FileUtils.mkdir_p(@project)
        send(test)
      end
      puts "TASK_EVIDENCE_EXPORT_TEST_PASS #{test}"
    end
  end

  def assert_raises(expected)
    yield
    raise "expected #{expected} but nothing was raised"
  rescue expected => error
    error
  end
end

TaskEvidenceExportTest.main
