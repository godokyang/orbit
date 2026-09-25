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

  # ADR-009 model drift: dedicated update path on an already-registered member.
  # It must NOT go through register_member (duplicate_member_id refusal) and
  # must keep the original registration entry intact. Fresh record: the shared
  # `record` above deliberately has a corrupt members.json at this point.
  driftrec = record_for(@project)
  drift = driftrec.register_member("orbit-drift", requested_name: "orbit-drift", model: "stub/m1")
  assert(drift["ok"], "drift fixture registration failed: #{drift.inspect}")
  recorded = driftrec.record_member_model_drift("orbit-drift", expected: "stub/m1", actual: "stub/m2",
    abort_attempted: true, abort_confirmed: false)
  assert(recorded["ok"], "drift record failed: #{recorded.inspect}")
  entry = driftrec.members.find { |member| member["thread_id"] == "orbit-drift" }
  assert(entry["status"] == "registered", "drift must not rewrite the registration status: #{entry.inspect}")
  assert(entry["model"] == "stub/m1", "original pinned model must survive: #{entry.inspect}")
  assert(entry["model_drift"]["expected"] == "stub/m1" && entry["model_drift"]["actual"] == "stub/m2", "drift block wrong: #{entry.inspect}")
  assert(entry["model_drift"]["abort_attempted"] == true, "abort_attempted must be persisted: #{entry.inspect}")
  assert(entry["model_drift"]["abort_confirmed"] == false, "unconfirmable abort must be explicit: #{entry.inspect}")
  assert(entry["model_drift"]["recorded_at"].is_a?(String), "recorded_at missing: #{entry.inspect}")
  # Slashed model ids (e.g. zenmux/x-ai/grok-4.7) are valid identifiers.
  slashed = driftrec.record_member_model_drift("orbit-drift", expected: "zenmux/x-ai/grok-4.7", actual: "stub/m2")
  assert(slashed["ok"], "slashed id must be accepted: #{slashed.inspect}")
  bad_ident = driftrec.record_member_model_drift("orbit-drift", expected: "nostroke", actual: "stub/m2")
  refute(bad_ident["ok"], "identifier without provider/id shape must be refused")
  assert(bad_ident["reason"] == "invalid_model_identifier", "wrong identifier reason: #{bad_ident.inspect}")
  blank_ident = driftrec.record_member_model_drift("orbit-drift", expected: nil, actual: "stub/m2")
  refute(blank_ident["ok"], "nil identifier must be refused")
  drift_events = File.readlines(File.join(driftrec.path, "events.jsonl")).map { |line| JSON.parse(line) }
  assert(drift_events.any? { |event| event["type"] == "member_model_drift" && event["thread_id"] == "orbit-drift" && event["expected"] == "stub/m1" && event["actual"] == "stub/m2" }, "member_model_drift event missing: #{drift_events.inspect}")
  # Re-registration after drift must still be refused as a duplicate.
  redup = driftrec.register_member("orbit-drift", requested_name: "orbit-drift", status: "refused")
  refute(redup["ok"], "drift must not enable a second registration")
  assert(redup["reason"] == "duplicate_member_id", "wrong post-drift duplicate reason: #{redup.inspect}")
  # Unknown member drift is refused, never fabricates membership.
  stranger = driftrec.record_member_model_drift("orbit-never-registered", expected: "a/b", actual: "c/d")
  refute(stranger["ok"], "drift for unknown member must be refused")
  assert(stranger["reason"] == "unknown_member_id", "wrong unknown-member reason: #{stranger.inspect}")
  assert(driftrec.members.none? { |member| member["thread_id"] == "orbit-never-registered" }, "unknown drift must not create a member")

  # Script-level drift entry (same interface the extension spawns).
  out, _err, status = Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, clean.path, "--event", "model_drift", "--id", "orbit-cli", "--expected", "stub/m1", "--actual", "stub/m9")
  assert(status.success?, "entry drift failed: #{out}")
  parsed = JSON.parse(out.lines.last)
  assert(parsed["ok"], "entry drift must report ok: #{parsed.inspect}")
  cli_entry = clean.members.find { |member| member["thread_id"] == "orbit-cli" }
  assert(cli_entry["model_drift"]["actual"] == "stub/m9", "entry drift not persisted: #{cli_entry.inspect}")
  _out, _err, bad_status = Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, clean.path, "--event", "model_drift", "--id", "orbit-ghost", "--expected", "a/b", "--actual", "c/d")
  refute(bad_status.success?, "entry drift for unknown member must exit non-zero")

  puts "member_registration_test: PASS"
ensure
  FileUtils.remove_entry(@temp)
end
