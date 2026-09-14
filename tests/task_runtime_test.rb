# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/orbit/task_runtime"

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

def assert(value, message)
  raise "ASSERTION FAILED: #{message}" unless value
end

def answer(verdict, findings: [], resolved: [])
  { "verdict" => verdict, "reason" => "Concrete fixture evidence", "findings" => findings,
    "resolved_ids" => resolved, "next_check_seconds" => 60 }
end

def fixture
  Dir.mktmpdir("orbit-runtime-test-") do |root|
    File.write(File.join(root, "artifact.txt"), "first behavior")
    record = Orbit::TaskRecord.create(
      project_root: root, instruction: "Provide first and second behaviors.\n",
      source: { "id" => "original", "kind" => "native_user_message" },
      connection: {}, review: { "interval_seconds" => 60 }, estimate: {}
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

puts "TASK_RUNTIME_TEST_PASS (deterministic, not real-model acceptance)"
