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

puts "TASK_RUNTIME_TEST_PASS (deterministic, not real-model acceptance)"
