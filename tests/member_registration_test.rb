# frozen_string_literal: true

require "json"
require "tmpdir"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "../lib/orbit/task_record"

# Member registration: the task-owned authoritative list the OMP extension
# writes synchronously in the AgentRegistry `registered` window, before any
# member model work. Durable (file fsync + rename + directory fsync), atomic,
# duplicate ids refused without overwrite, corrupt list fails closed.
def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition
end

def refute(condition, message)
  assert(!condition, message)
end

@temp = Dir.mktmpdir("orbit-member-registration-")
@project = File.join(@temp, "project")
FileUtils.mkdir_p(@project)
ENTRY = File.expand_path("../scripts/orbit-register-member", __dir__)

def record_for(project)
  Orbit::TaskRecord.create(
    project_root: project,
    instruction: "原始要求",
    source: {},
    connection: { "provider" => "omp", "thread_id" => "root", "socket" => File.join(Dir.mktmpdir, "host.sock") },
    review: {}
  )
end

begin
  record = record_for(@project)

  state_before = File.read(File.join(record.path, "state.json"))
  result = record.register_member("orbit-abc-123", requested_name: "orbit-abc-123", model: "glm/x", tool_call_id: "call-1")
  assert(result["ok"], "register failed: #{result.inspect}")
  members = record.members
  assert(members.length == 1, "expected one member, got #{members.inspect}")
  assert(members[0]["thread_id"] == "orbit-abc-123", "wrong id: #{members[0].inspect}")
  assert(members[0]["status"] == "registered", "wrong status: #{members[0].inspect}")
  assert(members[0]["model"] == "glm/x", "model not recorded")
  assert(File.read(File.join(record.path, "state.json")) == state_before, "state.json must not be rewritten by registration")
  events = File.readlines(File.join(record.path, "events.jsonl")).map { |line| JSON.parse(line) }
  assert(events.any? { |event| event["type"] == "member_registered" && event["thread_id"] == "orbit-abc-123" }, "member_registered event missing")

  duplicate = record.register_member("orbit-abc-123", requested_name: "orbit-abc-123", status: "refused", reason: "id_drift")
  refute(duplicate["ok"], "duplicate must be refused")
  assert(duplicate["reason"] == "duplicate_member_id", "wrong duplicate reason: #{duplicate.inspect}")
  assert(record.members.length == 1, "duplicate must not add a record")
  assert(record.members[0]["status"] == "registered", "existing record must survive the duplicate attempt")

  refusal = record.register_member("orbit-rej", requested_name: "orbit-rej", status: "refused", reason: "registration_failed: disk", abort_confirmed: true)
  assert(refusal["ok"], "refusal record failed: #{refusal.inspect}")
  rejected = record.members.find { |entry| entry["thread_id"] == "orbit-rej" }
  assert(rejected["status"] == "refused", "refusal status missing")
  assert(rejected["reason"] == "registration_failed: disk", "refusal reason missing")
  assert(rejected["abort_confirmed"] == true, "abort_confirmed must be persisted")

  File.write(File.join(record.path, "members.json"), "{not json")
  corrupt = record.register_member("orbit-x", requested_name: "orbit-x")
  refute(corrupt["ok"], "corrupt list must fail closed")
  begin
    record.members
    raise "ASSERTION FAILED: corrupt members list must raise"
  rescue JSON::ParserError
    # expected: unreadable list surfaces, never silently treated as empty
  end

  other = record_for(@project)
  refute(other.register_member("orbit-bad/id", requested_name: "orbit-bad/id")["ok"], "invalid id must be rejected")
  refute(other.register_member("", requested_name: "x")["ok"], "empty id must be rejected")
  refute(other.register_member("orbit-y", requested_name: "  ")["ok"], "blank requested name must be rejected")
  refute(other.register_member("orbit-z", requested_name: "orbit-z", status: "working")["ok"], "invalid status must be rejected")
  assert(Dir.glob(File.join(other.path, "members.json")).empty?, "rejected inputs must not create members.json")

  clean = record_for(@project)
  clean.register_member("orbit-clean", requested_name: "orbit-clean")
  leftovers = Dir.glob(File.join(clean.path, "*.tmp")) + Dir.glob(File.join(clean.path, "members.json.*.tmp"))
  assert(leftovers.empty?, "temporary files left behind: #{leftovers.inspect}")

  out, _err, status = Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, clean.path, "--id", "orbit-cli", "--requested", "orbit-cli", "--model", "glm/x")
  assert(status.success?, "entry register failed: #{out}")
  assert(JSON.parse(out.lines.last)["ok"], "entry must report ok")
  _out, _err, dup_status = Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, clean.path, "--id", "orbit-cli", "--requested", "orbit-cli")
  refute(dup_status.success?, "entry duplicate must exit non-zero")
  _out, _err, missing_status = Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, File.join(@temp, "nope"), "--id", "orbit-nope", "--requested", "orbit-nope")
  refute(missing_status.success?, "entry must fail on unknown task dir")

  rediscovery = record_for(@project)
  rediscovery.register_member("orbit-a", requested_name: "orbit-a")
  rediscovery.register_member("orbit-b", requested_name: "orbit-b", status: "refused", reason: "id_drift", abort_confirmed: false)
  ids = rediscovery.members.map { |member| member["thread_id"] }
  assert(ids == %w[orbit-a orbit-b], "crash-retry rediscovery list wrong: #{ids.inspect}")
  unconfirmed = rediscovery.members.find { |member| member["thread_id"] == "orbit-b" }
  assert(unconfirmed["abort_confirmed"] == false, "unconfirmed abort must be explicit for TaskRuntime")

  puts "member_registration_test: PASS"
ensure
  FileUtils.remove_entry(@temp)
end
