# frozen_string_literal: true

require "tmpdir"
require "socket"
require_relative "../lib/orbit/task_runtime"
require_relative "../lib/orbit/task_view"

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

def fixture(interval: 60)
  Dir.mktmpdir("orbit-runtime-test-") do |root|
    File.write(File.join(root, "artifact.txt"), "first behavior")
    record = Orbit::TaskRecord.create(
      project_root: root, instruction: "Provide first and second behaviors.\n",
      source: { "id" => "original", "kind" => "native_user_message" },
      connection: {}, review: { "interval_seconds" => interval }, estimate: {}
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
    inputs: { "instruction" => "Fix the task", "amendments" => amendments },
    host: { "status" => "active", "observations" => observations },
    members: 10.times.map { |index| { "status" => "done", "result" => "member-#{index}-" + ("y" * 10_000) } },
    project_root: root, artifact_digest: "digest", elapsed_seconds: 90
  )
  recent = state.fetch("recent_observations")
  assert(recent.fetch("latest_entries_json").last.include?("latest critical command failure"), "newest event survives the Jev input bound")
  assert(recent.fetch("omitted_older_entries").positive?, "older omissions are explicit")
  assert(state.fetch("amendments").first == "decision-0", "earlier effective user decisions are available to Jev")
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
