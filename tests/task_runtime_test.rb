# frozen_string_literal: true

require "tmpdir"
require "socket"
require_relative "../lib/orbit/task_runtime"
require_relative "../lib/orbit/task_view"

# Runtime tests never read the developer's real ~/.config/orbit/members.json.
ENV["XDG_CONFIG_HOME"] = Dir.mktmpdir("orbit-test-config-")

class RuntimeHost
  attr_reader :messages, :stop_calls
  attr_accessor :confirmed

  def initialize(root)
    @root, @messages, @stop_calls, @confirmed = root, [], 0, true
    finish("first")
  end

  def finish(id)
    @state = { "thread_id" => "existing-root", "cwd" => @root, "status" => "idle",
               "last_turn_id" => id, "last_turn_status" => "completed", "observations" => id }
  end

  def state = @state.dup
  def connect! = self
  def close = true
  def working(note)
    @state["status"] = "active"
    @state["observations"] = note
  end

  def interrupt
    @state["status"] = "idle"
    @state["last_turn_status"] = "interrupted"
  end
  def events = []
  def user_messages(after_id:) = []

  def send_message(text)
    @messages << text
    @state["status"] = "active"
    { "id" => "sent-#{@messages.length}" }
  end

  def stop!
    @stop_calls += 1
    { "confirmed" => @confirmed, "scope" => "deterministic host double" }
  end
end

class RuntimeTeamHost < RuntimeHost
  attr_reader :members

  def create_member(model:)
    @members ||= {}
    id = "member-#{@members.length + 1}"
    @members[id] = RuntimeHost.new(@root)
    id
  end

  def start_member(id, instruction) = @members.fetch(id).send_message(instruction)
  def member_connection(id) = @members.fetch(id)
end

class RuntimeChecker
  attr_reader :calls
  attr_accessor :result

  def initialize
    @calls = []
  end

  def start(**args)
    @calls << args
    @result = nil
  end

  def poll = @result
  def stop! = true
end

class RuntimeCodexMemberConnection
  attr_accessor :state_value, :stop_error

  def initialize
    @state_value = { "status" => "active", "last_turn_id" => nil, "last_turn_status" => nil, "observations" => [] }
  end

  def state = @state_value
  def close = true

  def stop!
    raise @stop_error if @stop_error

    { "confirmed" => true }
  end
end

class RuntimeCodexHost
  attr_accessor :alive
  attr_reader :start_member_calls, :shutdown_calls

  def initialize(record, member_connection)
    @record, @member_connection = record, member_connection
    @alive = true
    @start_member_calls = []
    @shutdown_calls = []
  end

  def start
    { "kind" => "codex", "socket" => "/tmp/orbit-mbr-test/m.sock", "pid" => 42, "pgid" => 42,
      "directory" => "/tmp/orbit-mbr-test" }
  end

  def create_member(_host, model: nil)
    { "thread_id" => "codex-thread-1", "model" => model || "gpt-codex-side" }
  end

  def start_member(_host, thread_id, instructions)
    persisted = JSON.parse(File.read(File.join(@record.path, "state.json")))["members"]
                  .find { |member| member["thread_id"] == thread_id }
    raise "member must be persisted before turn/start" unless persisted && persisted["status"] == "starting"

    @start_member_calls << { "thread_id" => thread_id, "instructions" => instructions }
  end

  def connection_for(_host, _thread_id) = @member_connection
  def alive?(_host) = @alive

  def shutdown(host)
    @shutdown_calls << host
    @alive = false
    { "confirmed" => true, "pgid" => host["pgid"] }
  end
end

class RuntimeAdvisor
  attr_reader :calls
  attr_accessor :scores, :failure, :on_call

  def initialize(scores)
    @scores, @calls = scores, []
  end

  def assess(state:)
    @calls << state
    @on_call&.call
    raise @failure if @failure

    { "model" => "jev-test", "scores" => @scores, "usage" => { "input_tokens" => 10, "output_tokens" => 3 } }
  end
end

def assert(value, message)
  raise "ASSERTION FAILED: #{message}" unless value
end

def answer(verdict, findings: [], resolved: [])
  { "verdict" => verdict, "reason" => "Concrete fixture evidence", "findings" => findings,
    "resolved_ids" => resolved, "next_check_seconds" => 60 }
end

def member_policy(allowed)
  Orbit::MemberPolicy.new(allowed_kinds: allowed, source: "test", path: "/tmp/orbit-test-members.json")
end

def fixture(interval: 60)
  Dir.mktmpdir("orbit-runtime-test-") do |root|
    File.write(File.join(root, "artifact.txt"), "first behavior")
    record = Orbit::TaskRecord.create(
      project_root: root, instruction: "Provide first and second behaviors.\n",
      source: { "id" => "original", "kind" => "native_user_message" },
      connection: { "provider" => "opencode" }, review: { "interval_seconds" => interval }, estimate: {}
    )
    host, checker = RuntimeHost.new(root), RuntimeChecker.new
    yield root, record, host, checker, Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  end
end

# A changed artifact invalidates an old pass. A current finding is corrected;
# a later false positive can be independently overturned without a vote.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  File.write(File.join(root, "artifact.txt"), "first behavior, changed while checking")
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  assert(record.state.fetch("checks").last["stale"], "old result must be marked stale")
  assert(host.messages.empty? && host.stop_calls.zero?, "stale result cannot control Root")

  runtime.tick(now: now + 2)
  missing = { "id" => "missing", "requirement" => "second behavior", "evidence" => "absent in artifact", "action" => "implement second behavior" }
  checker.result = answer("correct", findings: [missing])
  runtime.tick(now: now + 3)
  assert(host.messages.length == 1, "current correction must reach existing Root")

  File.write(File.join(root, "artifact.txt"), "first and second behaviors")
  runtime.tick(now: now + 3.5)
  assert(checker.calls.length == 2, "first-artifact trigger is consumed by the initial check, not repeated during correction")
  host.finish("fixed")
  runtime.tick(now: now + 4)
  preference = { "id" => "preference", "requirement" => "invented layout preference", "evidence" => "plain text artifact", "action" => "add unwanted layout" }
  checker.result = answer("correct", findings: [preference], resolved: ["missing"])
  runtime.tick(now: now + 5)
  record.submit("dispute", "reason" => "The layout preference is not a user requirement")
  host.finish("disputed")
  runtime.tick(now: now + 6)
  assert(checker.calls.last.fetch(:role) == "adjudicator", "real dispute invokes independent adjudication")
  checker.result = answer("complete", resolved: ["preference"])
  runtime.tick(now: now + 7)
  final = record.state
  assert(final["status"] == "complete", "overturned false positive must not block valid completion")
  assert(final.dig("findings", "preference", "status") == "resolved", "retraction is retained")
  assert(final["decisions"].length == 1, "adjudication reason is retained")
  assert(final["delivery_digest"] == Orbit::WorkspaceSnapshot.fingerprint(project_root: root), "approval binds final bytes")
  assert(File.read(File.join(record.path, "instruction.txt")) == "Provide first and second behaviors.\n", "original text is preserved")
end

# A stale correction is not applied to the old version and is not dropped:
# it becomes a reconciliation clue, and the next non-stale check on the
# current version delivers the correction without Root polling the record.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  File.write(File.join(root, "artifact.txt"), "changed while checking")
  missing = { "id" => "missing", "requirement" => "second behavior", "evidence" => "absent in artifact", "action" => "implement second behavior" }
  checker.result = answer("correct", findings: [missing])
  runtime.tick(now: now + 1)
  last = record.state.fetch("checks").last
  assert(last["stale"] && last["stale_reasons"] == ["artifact"], "expiry records which version element changed")
  assert(host.messages.empty?, "a stale correction must not reach the old version")
  assert(record.state.dig("recheck", "findings", 0, "id") == "missing", "stale finding is kept as a reconciliation clue")
  text = Orbit::TaskView.format(record)
  assert(text.include?("产物变化") && text.include?("待重新核对") && text.include?("依据"),
         "status shows expiry reason, pending items and next-check basis")

  runtime.tick(now: now + 2)
  assert(checker.calls.last[:context].dig("recheck", "findings", 0, "id") == "missing",
         "the next check receives the pending clue, not only its id")
  checker.result = answer("continue")
  runtime.tick(now: now + 3)
  assert(record.state.dig("recheck", "findings", 0, "id") == "missing",
         "a check that neither reports nor withdraws the clue must not clear it")

  record.submit("check")
  runtime.tick(now: now + 4)
  checker.result = answer("correct", findings: [missing])
  runtime.tick(now: now + 5)
  assert(host.messages.length == 1 && host.messages.first.include?("missing"),
         "a clue confirmed on the current version is delivered automatically, without Root polling")
  assert(record.state["recheck"].nil?, "an explicit confirmation clears the pending clue")
end

# A clue explicitly withdrawn on the current version is cleared without a
# correction message.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  File.write(File.join(root, "artifact.txt"), "changed while checking")
  clue = { "id" => "clue", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement" }
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 2)
  checker.result = answer("continue", resolved: ["clue"])
  runtime.tick(now: now + 3)
  assert(record.state["recheck"].nil? && host.messages.empty?,
         "an explicit withdrawal clears the clue without a correction")
end

Dir.mktmpdir("orbit-members-policy-") do |home|
  default = Orbit::MemberPolicy.load(env: {}, home: home)
  assert(default.allowed_kinds == Orbit::MemberPolicy::DEFAULT_KINDS, "missing file uses the six default kinds")
  path = File.join(home, ".config", "orbit", "members.json")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate("allowed_kinds" => %w[opencode kimi]))
  loaded = Orbit::MemberPolicy.load(env: {}, home: home)
  assert(loaded.allowed_kinds == %w[opencode kimi] && loaded.source == path, "an existing file fully overrides the default list")
  File.write(path, JSON.generate("allowed_kinds" => []))
  begin
    Orbit::MemberPolicy.load(env: {}, home: home).check!("codex")
    raise "ASSERTION FAILED: an empty allowlist must forbid new members"
  rescue Orbit::MemberPolicy::NotAllowed
    nil
  end
  File.write(path, '{"allowed_kinds":["opencode"],"extra":1}')
  begin
    Orbit::MemberPolicy.load(env: {}, home: home)
    raise "ASSERTION FAILED: unknown config keys must be rejected"
  rescue Orbit::MemberPolicy::Error
    nil
  end
  File.write(path, "not json")
  begin
    Orbit::MemberPolicy.load(env: {}, home: home)
    raise "ASSERTION FAILED: invalid JSON must be rejected"
  rescue Orbit::MemberPolicy::Error
    nil
  end
end

policy = member_policy(%w[codex omp opencode kimi])
assert(policy.resolve_kind("native", "opencode") == "opencode" && policy.resolve_kind(nil, "codex") == "codex",
       "native resolves to the Root's actual kind before the allowlist check")
assert(Orbit::MemberAdapters.resolve("codex", "opencode")["adapter"] == "codex_host",
       "OpenCode Root to Codex member is the verified cross-host path")
assert(Orbit::MemberAdapters.resolve("opencode", "opencode")["adapter"] == "same_host", "same-host opencode member")
assert(Orbit::MemberAdapters.resolve("kimi", "opencode").nil?, "kimi has no controlled adapter")
assert(Orbit::MemberAdapters.portably_callable_kinds.sort == %w[codex omp opencode], "only verified kinds are callable")
begin
  Orbit::MemberAdapters.require!("codex", "omp")
  raise "ASSERTION FAILED: an OMP Root has no controlled codex adapter"
rescue Orbit::MemberPolicy::NoAdapter => error
  assert(error.message.include?("no controlled adapter"), "the adapter gap reason is specific")
end

# A disallowed kind is rejected before any host or member is created, and a
# rejected delegation must not fail the task.
fixture do |_root, record, host, checker, _runtime|
  codex_host = RuntimeCodexHost.new(record, RuntimeCodexMemberConnection.new)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker,
                                   member_host: codex_host, member_policy: member_policy(["kimi"]))
  record.submit("delegate", "kind" => "codex", "text" => "scoped work")
  runtime.tick(now: Time.now.to_f)
  assert(record.state["members"].empty?, "a disallowed kind creates no member")
  assert(codex_host.start_member_calls.empty? && codex_host.shutdown_calls.empty?,
         "no member host is started before the allowlist decision")
  assert(!%w[failed stop_unconfirmed].include?(record.state["status"]) && record.state["error"].nil?,
         "a rejected delegation does not fail the task")
  assert(host.messages.last.to_s.include?("not in allowed_kinds"), "Root receives the specific rejection reason")
end

# Allowed kinds without a controlled adapter are reported as gaps before
# anything is created and are never presented as callable.
fixture do |_root, record, host, checker, _runtime|
  state = record.state
  state["connection"]["provider"] = "omp"
  record.save(state)
  codex_host = RuntimeCodexHost.new(record, RuntimeCodexMemberConnection.new)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker,
                                   member_host: codex_host, member_policy: member_policy(["codex"]))
  record.submit("delegate", "kind" => "codex", "text" => "scoped work")
  runtime.tick(now: Time.now.to_f)
  assert(record.state["members"].empty? && codex_host.start_member_calls.empty?,
         "an allowed kind without an adapter creates nothing")
  assert(host.messages.last.to_s.include?("no controlled adapter"), "the adapter gap is reported")
end

# Jev's delegation probability only reaches Root when an allowed and actually
# callable member exists; it is bounded to once per task and never dispatches.
fixture do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   member_policy: member_policy(%w[opencode kimi]))
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  assert(host.messages.count { |message| message.include?("delegation hint") } == 1, "one delegation hint is delivered")
  assert(record.state.dig("delegation_hint", "score") == 0.9 &&
         record.state.dig("delegation_hint", "callable_kinds") == ["opencode"],
         "the hint signal and the allowed callable kinds are recorded")

  host.working("more progress")
  runtime.tick(now: now + 90)
  assert(host.messages.count { |message| message.include?("delegation hint") } == 1, "the hint is not repeated")

  record.submit("delegate", "kind" => "opencode", "text" => "bounded subtask")
  runtime.tick(now: now + 91)
  assert(record.state["members"].first && record.state.dig("delegation_hint", "followed") == true &&
         record.state.dig("delegation_hint", "followed_kind") == "opencode",
         "the Root's actual delegation is recorded")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("delegation_hint_followed") },
         "the follow-up event is recorded")
end

fixture do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.95)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   member_policy: member_policy(["kimi"]))
  runtime.tick(now: Time.now.to_f + 6)
  assert(host.messages.none? { |message| message.include?("delegation hint") },
         "no hint is sent without an allowed callable member")
end

# A check requested by the same Jev judgment wins: the advisory hint must
# not interrupt or precede it.
fixture(interval: 300) do |_root, record, host, checker, _runtime|
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   member_policy: member_policy(%w[opencode]))
  runtime.tick(now: Time.now.to_f + 6)
  assert(checker.calls.last&.fetch(:role) == "process_reviewer", "the process check from this judgment starts")
  assert(host.messages.none? { |message| message.include?("delegation hint") },
         "the hint does not interrupt the process check")
  assert(record.state["delegation_hint"].nil?, "no hint is recorded when a check wins")
end

# A hint is only delivered after the same freshness re-check as check
# decisions; an observation that changed during the assessment drops it.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.on_call = -> { File.write(File.join(root, "artifact.txt"), "changed during assessment") }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   member_policy: member_policy(%w[opencode]))
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  assert(host.messages.none? { |message| message.include?("delegation hint") } && record.state["delegation_hint"].nil?,
         "a hint against a changed observation is dropped")

  advisor.on_call = nil
  runtime.tick(now: now + 70)
  assert(host.messages.count { |message| message.include?("delegation hint") } == 1,
         "a later fresh assessment delivers the hint")
end

# A changed allowlist never blocks stopping an already-registered member.
fixture do |root, record, _host, checker, _runtime|
  team = RuntimeTeamHost.new(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: team, checker: checker,
                                   member_policy: member_policy(["opencode"]))
  record.submit("delegate", "text" => "scoped work")
  runtime.tick(now: Time.now.to_f)
  member = record.state["members"].first
  assert(member && member["kind"] == "opencode", "an allowed native member is created")
  state = record.state
  state["connection"]["thread_id"] = "existing-root"
  record.save(state)
  retry_runtime = Orbit::TaskRuntime.new(record: record, connection: team, checker: nil,
                                         member_policy: member_policy([]))
  result = retry_runtime.retry_stop("User retried stop")
  assert(result["status"] == "paused" && team.members.fetch(member["thread_id"]).stop_calls == 1,
         "an emptied allowlist does not block stopping a registered member")
end

# Pending clues block completion until an artifact check confirms or
# withdraws them; a complete verdict that ignores the clue is not accepted.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  File.write(File.join(root, "artifact.txt"), "changed while checking")
  clue = { "id" => "clue", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement" }
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 1)
  host.finish("delivered")
  checker.result = answer("complete")
  runtime.tick(now: now + 2)
  checker.result = answer("complete")
  runtime.tick(now: now + 3)
  assert(record.state["status"] != "complete" && record.state["recheck"], "an unaddressed clue blocks completion")

  record.submit("check")
  runtime.tick(now: now + 4)
  checker.result = answer("complete", resolved: ["clue"])
  runtime.tick(now: now + 5)
  assert(record.state["status"] == "complete" && record.state["recheck"].nil?,
         "an explicit withdrawal lets completion proceed")
end

# Pending artifact clues belong only to the next artifact review: a process
# check must neither receive, deliver, nor clear them.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now)
  host.working("progress")
  File.write(File.join(root, "artifact.txt"), "changed while checking")
  clue = { "id" => "clue", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement" }
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 1)
  assert(record.state.dig("recheck", "findings", 0, "id") == "clue", "precondition: stale clue is pending")

  runtime.tick(now: now + 10)
  assert(checker.calls.last[:role] == "process_reviewer", "the suspected process issue starts a process check")
  assert(checker.calls.last[:context]["recheck"].nil?, "a process check does not receive artifact clues")
  process_finding = { "id" => "process-issue", "requirement" => "process", "evidence" => "repeated failure", "action" => "change approach" }
  checker.result = answer("correct", findings: [process_finding])
  runtime.tick(now: now + 11)
  assert(record.state.dig("recheck", "findings", 0, "id") == "clue", "a process check cannot clear a pending artifact clue")
  assert(host.messages.none? { |message| message.include?("clue") }, "a process check does not deliver the artifact clue")

  host.finish("integrated")
  checker.result = nil
  runtime.tick(now: now + 12)
  assert(checker.calls.last[:role] == "reviewer" && checker.calls.last[:context].dig("recheck", "findings", 0, "id") == "clue",
         "the next artifact check receives the pending clue")
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 13)
  assert(record.state["recheck"].nil?, "the artifact check confirms and clears the clue")
  assert(host.messages.count { |message| message.include?('"id": "clue"') } == 1,
         "the clue correction is delivered exactly once")
end

# While Root is executing, a short checker-suggested next observation cannot
# restart full checks before the agreed interval; an idle Root still honors it.
fixture(interval: 300) do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  host.working("Root is executing")
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  assert(record.state.fetch("checks").last["stale_reasons"] == ["host"],
         "host execution change alone is recorded as the expiry reason")
  runtime.tick(now: now + 61)
  assert(checker.calls.length == 1, "short checker suggestions do not restart full checks while Root executes")
  runtime.tick(now: now + 310)
  assert(checker.calls.length == 2, "the agreed interval still triggers the next full check")
end

fixture(interval: 300) do |_root, _record, _host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 59)
  assert(checker.calls.length == 1, "idle Root waits for the checker-suggested observation")
  runtime.tick(now: now + 62)
  assert(checker.calls.length == 2, "checker-suggested observation applies while Root is idle")
end

# Waiting does not wake Root or spend a model call. Only an explicit hard
# deadline stops work; a missing confirmation must remain unconfirmed.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 2)
  assert(host.messages.empty?, "empty continue must not create a self-triggering Root loop")
  assert(checker.calls.length == 1, "next agreed time must control observation")

  state = record.state
  state["hard_deadline"] = Time.at(now - 1).utc.iso8601
  record.save(state)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  host.confirmed = false
  runtime.tick(now: now + 3)
  assert(record.state["status"] == "stop_unconfirmed", "request acknowledgement is not a confirmed stop")
  assert(checker.calls.length == 1, "hard boundary must not launch another check")
  assert(host.stop_calls == 1, "hard boundary reaches host control")
end

# A queued amendment after stop must not start a new turn on the paused Root.
fixture do |_root, record, host, checker, runtime|
  record.submit("stop", "reason" => "User stopped the task")
  record.submit("amend", "text" => "A later correction", "source" => { "kind" => "explicit_text" })
  record.submit("check")
  runtime.tick
  assert(record.state["status"] == "paused", "stop remains the final state")
  assert(host.stop_calls == 1 && host.messages.empty?, "later queued commands cannot wake Root")
  assert(checker.calls.empty?, "later queued checks cannot spend model calls")
  assert(Dir.glob(File.join(record.path, "inbox", "*.json")).empty?, "rejected queued commands are consumed")
end

# An already received process stop signal takes priority over queued delivery.
fixture do |_root, record, host, checker, runtime|
  record.submit("amend", "text" => "Pending correction", "source" => { "kind" => "explicit_text" })
  runtime.request_stop
  runtime.tick
  assert(record.state["status"] == "paused", "runtime stop is confirmed")
  assert(host.messages.empty? && checker.calls.empty?, "stop signal precedes inbox delivery")
end

# Member output must reach Root for integration before final completion.
fixture do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  record.submit("delegate", "text" => "Implement second behavior")
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  assert(record.state["status"] != "complete", "active member prevents completion")
  record.submit("amend", "text" => "Make second behavior uppercase", "source" => { "kind" => "explicit_text" })
  runtime.tick(now: now + 2)
  member = host.members.fetch("member-1")
  assert(member.messages.last.include?("uppercase"), "user amendment reaches the active member")
  member.finish("member-done")
  runtime.tick(now: now + 3)
  assert(host.messages.last.include?("execution member result"), "result reaches existing Root")
  host.finish("integrated")
  runtime.tick(now: now + 4)
  checker.result = answer("complete")
  runtime.tick(now: now + 5)
  assert(record.state.fetch("checks").last["stale"], "check started before integration cannot approve it")
  runtime.tick(now: now + 6)
  checker.result = answer("complete")
  runtime.tick(now: now + 7)
  assert(record.state["status"] == "complete", "integrated result can complete after independent check")
  assert(record.state.dig("stop_confirmation", "members", 0, "confirmation", "confirmed"), "completion confirms member cleanup")
end

# Interrupting Root through its native UI must also stop its execution members.
fixture do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  record.submit("delegate", "text" => "Run a bounded job")
  runtime.tick
  host.interrupt
  runtime.tick
  assert(record.state["status"] == "paused", "native Root interruption pauses the whole task")
  assert(host.members.fetch("member-1").stop_calls == 1, "member is stopped without relying on Root")
end

# A failed Root stop cannot prevent attempts to stop the remaining members.
fixture do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  record.submit("delegate", "text" => "Run a bounded job")
  runtime.tick
  host.confirmed = false
  record.submit("stop")
  runtime.tick
  assert(record.state["status"] == "stop_unconfirmed", "partial cleanup cannot claim whole-task stop")
  assert(host.members.fetch("member-1").stop_calls == 1, "remaining members are still stopped")
end

# OpenCode Root delegation can create a task-owned Codex member: host and
# member identity are persisted before turn/start, and the result returns
# through the existing Root channel.
fixture do |_root, record, host, checker, _runtime|
  member_connection = RuntimeCodexMemberConnection.new
  codex_host = RuntimeCodexHost.new(record, member_connection)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, member_host: codex_host)
  record.submit("delegate", "kind" => "codex", "text" => "Verify greet behavior")
  runtime.tick(now: Time.now.to_f)
  member = record.state.fetch("members").first
  assert(member["kind"] == "codex" && member["thread_id"] == "codex-thread-1", "codex member is registered")
  assert(record.state.dig("member_hosts", "codex", "pgid") == 42, "task-owned member host identity is persisted")
  assert(codex_host.start_member_calls.length == 1, "the member turn starts on the task-owned host")
  assert(member["model"] == "gpt-codex-side" && member["status"] == "working", "Codex-side model and state are recorded")

  member_connection.state_value = { "status" => "idle", "last_turn_id" => "turn-1", "last_turn_status" => "completed",
                                    "observations" => [{ "kind" => "agent_message", "text" => "member verified greet" }] }
  runtime.tick(now: Time.now.to_f + 1)
  completed = record.state.fetch("members").first
  assert(completed["status"] == "completed" && completed["result"].first["text"] == "member verified greet",
         "member result is read from the native session")
  assert(host.messages.any? { |message| message.include?("execution member result") },
         "member result returns to the original Root")
end

# An explicit stop retry reconnects a live Codex member host; a missing socket
# only confirms when the recorded host process group no longer exists.
fixture do |_root, record, host, _checker, _runtime|
  state = record.state
  state["connection"]["thread_id"] = "existing-root"
  state["status"] = "running"
  record.save(state)
  member_connection = RuntimeCodexMemberConnection.new
  codex_host = RuntimeCodexHost.new(record, member_connection)
  reset = lambda do
    current = record.state
    current["status"] = "running"
    current["members"] = [{ "kind" => "codex", "thread_id" => "codex-thread-9", "model" => "gpt-codex-side",
                            "socket" => "/tmp/orbit-mbr-test/m.sock", "host" => "codex", "status" => "working" }]
    current["member_hosts"] = { "codex" => { "kind" => "codex", "socket" => "/tmp/orbit-mbr-test/m.sock",
                                             "pid" => 4242, "pgid" => 4242, "directory" => "/tmp/orbit-mbr-test" } }
    record.save(current)
  end

  reset.call
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil, member_host: codex_host)
                              .retry_stop("User retried stop")
  assert(result["status"] == "paused" && result.dig("member_host_shutdown", 0, "confirmed"),
         "a live member host reconnects, stops and confirms host exit")
  assert(codex_host.shutdown_calls.length == 1, "the confirmed retry closes the member host")

  reset.call
  member_connection.stop_error = "member socket refused"
  codex_host.alive = true
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil, member_host: codex_host)
                              .retry_stop("User retried stop")
  assert(result["status"] == "stop_unconfirmed" && codex_host.shutdown_calls.length == 1,
         "a live host with an unreachable member stays unconfirmed and keeps the host for retry")

  reset.call
  codex_host.alive = false
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil, member_host: codex_host)
                              .retry_stop("User retried stop")
  confirmation = result.fetch("member_stop_results").first.fetch("confirmation")
  assert(result["status"] == "paused" && confirmation["host_exit_verified"],
         "a missing socket with a dead recorded host process group is verified as stopped")

  reset.call
  codex_host.alive = true
  member_connection.stop_error = Orbit::CodexConnection::UnmaterializedThread.new("no turn yet")
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil, member_host: codex_host)
                              .retry_stop("User retried stop")
  confirmation = result.fetch("member_stop_results").first.fetch("confirmation")
  assert(result["status"] == "paused" && confirmation["no_materialized_turn"],
         "a member thread with no user turn has no execution to interrupt")
end

# Checker cleanup failure must not skip the user's requested execution stop.
fixture do |_root, record, host, checker, runtime|
  runtime.tick
  process = Process.spawn("ruby", "-e", "sleep 60", pgroup: true)
  record.write("checks/1/run.json", JSON.generate("pgid" => process))
  def checker.stop! = raise("checker process is still alive")
  record.submit("stop")
  runtime.tick
  assert(host.stop_calls == 1, "Root stop is attempted despite checker cleanup failure")
  assert(record.state["status"] == "stop_unconfirmed", "checker cleanup failure prevents confirmed stop")
  Process.kill("TERM", -process)
  Process.wait(process)
  state = record.state
  state["connection"]["thread_id"] = "existing-root"
  record.save(state)
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil).retry_stop("Check process has exited")
  assert(result["status"] == "paused", "retry verifies actual checker exit instead of retaining a stale error")
ensure
  begin
    Process.kill("KILL", -process) if process
    Process.wait(process) if process
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end

# An observer error cannot strand members, and an explicit retry can confirm a
# previously unconfirmed stop after the runtime exits, without running a model.
fixture do |root, record, _host, checker, _runtime|
  state = record.state
  state["connection"]["thread_id"] = "existing-root"
  record.save(state)
  host = RuntimeTeamHost.new(root)
  host.confirmed = false
  def checker.start(**args) = raise("checker could not start")
  record.submit("delegate", "text" => "Perform scoped work")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  runtime.run
  assert(record.state["status"] == "stop_unconfirmed", "observer failure records unconfirmed cleanup")
  assert(host.members.fetch("member-1").stop_calls == 1, "observer failure still stops the member")
  host.confirmed = true
  retry_runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil)
  result = retry_runtime.retry_stop("User retried stop")
  assert(result["status"] == "paused", "explicit cleanup works after runtime exit")
  assert(checker.calls.empty?, "cleanup does not restart a checker")
end

# Rejecting attachment must not stop a session outside the target project.
fixture do |_root, record, _host, checker, _runtime|
  state = record.state
  state["connection"]["thread_id"] = "wrong-project"
  record.save(state)
  host = RuntimeHost.new(Dir.tmpdir)
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker).run
  assert(result["status"] == "failed", "wrong-project attachment is rejected")
  assert(host.stop_calls.zero? && checker.calls.empty?, "rejected attachment has no execution authority")
end

# Jev can defer the early first-change review, but not the agreed full check.
fixture do |root, record, host, checker, _runtime|
  host.send_message("Working")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now + 1)
  File.write(File.join(root, "artifact.txt"), "work in progress")
  runtime.tick(now: now + 10)
  assert(advisor.calls.length == 1 && checker.calls.empty?, "low readiness defers only the early file-change check")
  runtime.tick(now: now + 61)
  assert(checker.calls.length == 1 && checker.calls.last.fetch(:role) == "reviewer", "agreed full check still runs")
end

fixture do |_root, record, host, checker, _runtime|
  host.send_message("Working")
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  advisor.on_call = -> { runtime.request_stop }
  now = Time.now.to_f
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 10)
  assert(record.state["status"] == "paused", "stop during Jev assessment wins")
  assert(checker.calls.empty?, "an assessment finishing after stop cannot summon a checker")
end

# A changing host during the HTTP call must still respect the assessment debounce.
fixture do |_root, _record, host, checker, _runtime|
  host.send_message("Working")
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1)
  advisor.on_call = -> { host.finish("during-#{advisor.calls.length}"); host.send_message("New work during assessment") }
  runtime = Orbit::TaskRuntime.new(record: _record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now + 10)
  runtime.tick(now: now + 11)
  runtime.tick(now: now + 29)
  assert(advisor.calls.length == 1 && checker.calls.empty?, "changed observations cannot request Jev again each tick")
  runtime.tick(now: now + 30)
  assert(advisor.calls.length == 2, "changed observations may be reassessed after the debounce")
end

# Jev only summons a focused checker; its verdict cannot complete the task.
fixture do |_root, record, host, checker, _runtime|
  host.send_message("Working")
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 10)
  assert(checker.calls.last.fetch(:role) == "process_reviewer", "suspected stuckness gets process review")
  checker.result = answer("complete")
  runtime.tick(now: now + 11)
  assert(record.state["status"] != "complete", "process review cannot approve delivery")
  runtime.tick(now: now + 30)
  assert(checker.calls.length == 1, "the same observation does not summon another checker")
end

# TypeSafe failure returns to the existing first-change path.
fixture do |root, record, host, checker, _runtime|
  host.send_message("Working")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1)
  advisor.failure = Orbit::JevAdvisor::Error.new("service unavailable")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now + 1)
  File.write(File.join(root, "artifact.txt"), "changed despite service failure")
  runtime.tick(now: now + 10)
  assert(checker.calls.last.fetch(:role) == "reviewer", "failed Jev call falls back to full review")
  assert(record.state.dig("jev", "unavailable") == "service unavailable", "failure is recorded")
end

Dir.mktmpdir("orbit-jev-config-") do |root|
  env = { "TYPESAFE_API_KEY" => "test-key" }
  assert(Orbit::JevAdvisor.for_project(root, env: env), "one global enable covers a project")
  assert(Orbit::JevAdvisor.for_project(root, env: {}).nil?, "no key keeps the existing scheduling path")
  Dir.mkdir(File.join(root, ".orbit"))
  File.write(File.join(root, ".orbit", "jev-disabled"), "")
  assert(Orbit::JevAdvisor.for_project(root, env: env).nil?, "a project can disable external Jev calls")
end

Dir.mktmpdir("orbit-jev-observation-") do |root|
  observations = 8.times.map { |index| { "kind" => "command", "output" => "old-#{index}-" + ("x" * 1000) } }
  observations << { "kind" => "command", "output" => "latest critical command failure" }
  amendments = 14.times.map { |index| { "text" => "decision-#{index}" } }
  state = Orbit::JevAdvisor.observation(
    inputs: { "instruction" => "Implement TASK.md", "basis" => [{ "path" => "basis/0-TASK.md",
              "text" => "Implement the parser and the independent HTML renderer." }], "amendments" => amendments },
    host: { "status" => "active", "observations" => observations },
    members: 10.times.map { |index| { "status" => "done", "result" => "member-#{index}-" + ("y" * 10_000) } },
    project_root: root, artifact_digest: "digest", elapsed_seconds: 90
  )
  recent = state.fetch("recent_observations")
  assert(recent.fetch("latest_entries_json").last.include?("latest critical command failure"), "newest event survives the Jev input bound")
  assert(recent.fetch("omitted_older_entries").positive?, "older omissions are explicit")
  assert(state.fetch("amendments").first == "decision-0", "earlier effective user decisions are available to Jev")
  assert(state.fetch("basis").first.fetch("text").include?("independent HTML renderer") && state["basis_omitted"].nil?,
         "a task defined in a basis document is available to Jev")
  assert(state.fetch("members").length == 5 && JSON.generate(state.fetch("members")).length < 6000,
         "member results remain bounded before leaving Orbit")

  many = 30.times.map { |index| { "text" => "amendment-#{index}-" + ("z" * 1200) } }
  bounded = Orbit::JevAdvisor.observation(
    inputs: { "instruction" => "Fix the task", "amendments" => many },
    host: { "status" => "active", "observations" => [] },
    members: [], project_root: root, artifact_digest: "digest", elapsed_seconds: 90
  )
  included = bounded.fetch("amendments")
  assert(included.length < many.length && included.last.include?("amendment-29"),
         "the newest effective amendments are kept within the Jev input budget")
  assert(bounded.dig("amendments_omitted", "count") == many.length - included.length &&
         bounded.dig("amendments_omitted", "included_range").end_with?("30"),
         "omitted amendment range is explicit instead of silently dropped")

  long_basis = 5.times.map { |index| { "path" => "basis/#{index}-requirement.md",
                                    "text" => "requirement-#{index}-" + ("b" * 5000) } }
  bounded_basis = Orbit::JevAdvisor.observation(
    inputs: { "instruction" => "Implement the attached requirements", "basis" => long_basis, "amendments" => [] },
    host: { "status" => "active", "observations" => [] },
    members: [], project_root: root, artifact_digest: "digest", elapsed_seconds: 90
  )
  excerpts = bounded_basis.fetch("basis")
  assert(excerpts.sum { |entry| entry.fetch("text").length } <= Orbit::JevAdvisor::BASIS_BUDGET &&
         excerpts.first.fetch("text").include?("requirement-0-") &&
         excerpts.last.fetch("text").include?("requirement-2-"),
         "specified documents remain identifiable within a bounded Jev request")
  assert(bounded_basis.dig("basis_omitted", "count") == 2 &&
         bounded_basis.dig("basis_omitted", "truncated_paths").length == 3,
         "truncated and omitted task documents are explicit")
end

server = TCPServer.new("127.0.0.1", 0)
worker = Thread.new do
  socket = server.accept
  headers = +""
  headers << socket.gets until headers.end_with?("\r\n\r\n")
  length = headers[/Content-Length:\s*(\d+)/i, 1].to_i
  socket.read(length)
  body = '{"model":"jev-test","answers":null}'
  socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  socket.close
end
advisor = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: URI("http://127.0.0.1:#{server.addr[1]}/v1/systemone"))
begin
  advisor.assess(state: { "instruction" => "test" })
  raise "ASSERTION FAILED: malformed TypeSafe response must fail safely"
rescue Orbit::JevAdvisor::Error
  nil
ensure
  server.close
  worker.join
end

puts "TASK_RUNTIME_TEST_PASS (deterministic, not real-model acceptance)"
