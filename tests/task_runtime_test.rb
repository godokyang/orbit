# frozen_string_literal: true

require "json"
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
               "last_turn_id" => id, "last_turn_status" => "completed", "observations" => [id] }
  end

  def state = @state.dup
  def connect! = self
  def close = true
  def configured_model = "opencode-go/deepseek-v4.1-flash"
  def default_member_model = configured_model
  def default_member_route = "direct_api"
  def working(note)
    @state["status"] = "active"
    @state["observations"] = [note]
  end

  def interrupt
    @state["status"] = "idle"
    @state["last_turn_status"] = "interrupted"
  end
  def events = []
  def user_messages(after_id:) = []

  def send_message(text, integration_check: nil)
    raise Orbit::Connection::Error, @fail_send_message if @fail_send_message.is_a?(String)

    @on_send&.call(text, integration_check)
    @messages << text
    (@integration_tags ||= []) << integration_check
    @state["status"] = "active"
    { "id" => "sent-#{@messages.length}" }
  end

  attr_accessor :fail_send_message, :on_send
  def integration_tags = (@integration_tags ||= [])

  def stop!
    @stop_calls += 1
    { "confirmed" => @confirmed, "scope" => "deterministic host double" }
  end

  def stop_member(id)
    @member_stops ||= []
    @member_stops << id
    { "confirmed" => true, "active_tools_after" => 0, "async_jobs_settled" => true }
  end

  attr_reader :member_stops
end

# Serves this task's own sent messages back exactly like the native host
# serves Orbit custom messages (internal: true), so collect_amendments sees
# the same readback a real Root session produces after a hint delivery.
class RuntimeBoundaryHost < RuntimeHost
  def initialize(root)
    super
    @thread_messages = [{ "id" => "original", "internal" => false, "text" => "original instruction" }]
  end

  def send_message(text)
    sent = super
    @thread_messages << { "id" => sent.fetch("id"), "internal" => true, "text" => text }
    sent
  end

  def post_user_message(text)
    message = { "id" => "user-#{@thread_messages.length + 1}", "internal" => false, "text" => text }
    @thread_messages << message
    message
  end

  def user_messages(after_id:)
    index = @thread_messages.index { |message| message["id"] == after_id }
    index ? @thread_messages.drop(index + 1) : []
  end
end

class RuntimeAskHost < RuntimeHost
  attr_accessor :ask_events

  def hub_events
    @ask_events || { "events" => [], "dropped_oldest" => 0, "next_seq" => 1, "buffer_cap" => 500 }
  end
end

class RuntimeTeamHost < RuntimeHost
  attr_reader :members, :member_cwds

  def create_member(model:, cwd:)
    @members ||= {}
    @member_cwds ||= []
    @member_cwds << cwd
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
  attr_reader :start_member_calls, :shutdown_calls, :member_cwd

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

  def create_member(_host, model: nil, cwd: nil)
    @member_cwd = cwd
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
  attr_reader :calls, :delegation_calls, :candidate_calls
  attr_accessor :scores, :failure, :on_call, :on_candidate_call, :delegation_scores, :delegation_failure, :candidate_scores

  def initialize(scores)
    @scores, @calls = scores, []
    @delegation_calls = []
    @candidate_calls = []
    @delegation_scores = { "handoff_fit" => 0.8, "member_task_fit" => 0.75 }
  end

  def assess(state:)
    @calls << state
    @on_call&.call
    raise @failure if @failure

    { "provider" => "typesafe", "model" => "jev-test", "question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch("observation"),
      "scores" => @scores, "usage" => { "input_tokens" => 10, "output_tokens" => 3 } }
  end

  def assess_delegation(state:)
    @delegation_calls << state
    raise @delegation_failure if @delegation_failure

    { "provider" => "typesafe", "model" => "jev-test", "question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch("delegation"),
      "scores" => @delegation_scores, "usage" => { "input_tokens" => 20, "output_tokens" => 4 } }
  end

  def assess_candidates(state:, candidates:)
    @candidate_calls << { "state" => state, "candidates" => candidates }
    @on_candidate_call&.call
    { "provider" => "typesafe", "model" => "jev-test", "question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch("candidates"),
      "scores" => @candidate_scores, "usage" => { "input_tokens" => 30, "output_tokens" => 5 } }
  end
end

def events(record)
  File.readlines(File.join(record.path, "events.jsonl")).map { |line| JSON.parse(line) }
end

def assert(value, message)
  raise "ASSERTION FAILED: #{message}" unless value
end

def answer(verdict, findings: [], resolved: [], delivery_ready: true, delivery_reason: "Finished deliverable is inspectable")
  { "verdict" => verdict, "reason" => "Concrete fixture evidence", "findings" => findings,
    "resolved_ids" => resolved, "next_check_seconds" => 60,
    "delivery" => { "ready" => delivery_ready, "reason" => delivery_reason } }
    .merge("coverage" => { "complete" => true, "items" => [
      { "requirement" => "Fixture deliverable", "status" => delivery_ready ? "verified" : "unverified",
        "evidence" => delivery_reason }
    ] })
end

# Shared completion-hand-off preamble: qualified notice, delivery turn in
# progress, queued completion stop, then the turn finishing. Returns its tick.
def qualified_handoff!(record, host, checker, runtime)
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  assert(record.state["finalization_notices"].length == 1, "finalization hand-off is qualified")
  host.working("delivery turn in progress")
  record.submit("stop", "reason" => "User requested stop", "complete" => true)
  runtime.tick(now: now + 2)
  assert(record.state["completion_stop_pending"], "completion stop is queued")
  host.finish("delivered")
  now + 3
end

def member_policy(allowed)
  Orbit::MemberPolicy.new(allowed_kinds: allowed, source: "test", path: "/tmp/orbit-test-members.json")
end

# The user-level evidence cache lives under .orbit (excluded from workspace
# snapshots) so a test never reads or writes the developer's real cache.
def evidence_cache(root, entries = [])
  cache = Orbit::ModelEvidenceCache.new(path: File.join(root, ".orbit", "model-evidence-v1.json"))
  entries.each { |entry| cache.record(entry) }
  cache
end

# The Root identity carries no billing route (unknown), so a complete
# comparison needs one unknown-route entry for the Root and one explicit-route
# entry for the candidate.
def both_route_evidence(root, candidate_route: "direct_api", **entry_kwargs)
  cache = evidence_cache(root)
  cache.record(evidence_entry(billing_route: "unknown", **entry_kwargs))
  cache.record(evidence_entry(billing_route: candidate_route, **entry_kwargs))
  cache
end

def evidence_entry(model: "deepseek-v4.1-flash", provider: "opencode-go", reasoning: "unknown", status: "evidence",
                   billing_route: "direct_api", priced: true, quota: false)
  base = { "provider" => provider, "model" => model, "reasoning" => reasoning, "status" => status,
           "billing_route" => billing_route, "retrieved_at" => Time.now.utc.iso8601 }
  if status == "evidence"
    metrics = { "coding_index" => { "value" => 50, "unit" => "index", "basis" => "scripted fixture" } }
    if priced
      metrics["cost.output_peak"] = { "value" => 1.2, "unit" => "USD per 1M tokens",
                                      "basis" => "official DeepSeek API pricing page" }
    end
    if quota
      metrics["quota.included_output_tokens"] = { "value" => 20_000_000, "unit" => "tokens per billing period",
                                                  "basis" => "official coding-plan page" }
    end
    base.merge("sources" => ["https://artificialanalysis.ai/models"], "metrics" => metrics)
  else
    base.merge("reason" => "no comparable public benchmark found")
  end
end

def fixture(interval: 60, host_class: RuntimeHost)
  Dir.mktmpdir("orbit-runtime-test-") do |root|
    File.write(File.join(root, "artifact.txt"), "first behavior")
    record = Orbit::TaskRecord.create(
      project_root: root, instruction: "Provide first and second behaviors.\n",
      source: { "id" => "original", "kind" => "native_user_message" },
      connection: { "provider" => "omp" }, review: { "interval_seconds" => interval }, estimate: {}
    )
    host, checker = host_class.new(root), RuntimeChecker.new
    yield root, record, host, checker, Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  end
end

# Only the owning Root's native tool receipt reaches an independent check.
# Later artifact changes invalidate it without rewriting its original input.
fixture do |root, record, host, checker, _runtime|
  now = Time.now.to_f
  state = record.state
  state["connection"]["thread_id"] = "existing-root"
  record.save(state)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  artifact_root = state.fetch("workspace").fetch("artifact_root")
  receipt = { "source" => "omp_native_tool_result", "task_directory" => record.path,
    "root_session_id" => "existing-root", "tool_call_id" => "test-call", "tool" => "bash",
    "command" => "npm test", "execution_cwd" => root, "input_digest" => record.input_digest(record.state),
    "artifact_root" => artifact_root, "artifact_root_at_completion" => artifact_root, "fingerprint_status" => "ok",
    "artifact_digest" => Orbit::WorkspaceSnapshot.fingerprint(project_root: root),
    "status" => "completed", "exit_code" => 0, "output" => "8 tests passed" }
  host.instance_variable_get(:@state)["root_verifications"] = [receipt,
    receipt.merge("task_directory" => "/another-task"), receipt.merge("root_session_id" => "another-root")]
  record.submit("check")
  runtime.tick(now: now)
  context = checker.calls.last.fetch(:context)
  receipts = context.fetch("root_verifications")
  assert(receipts.length == 1 && receipts[0]["artifact_matches"] && receipts[0]["input_matches"],
         "current, native, owned execution is supplied once with exact version matches")
  assert(!context.fetch("root").key?("root_verifications"), "raw receipts are not duplicated in Root context")
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  File.write(File.join(root, "artifact.txt"), "changed after tests")
  host.finish("changed")
  host.instance_variable_get(:@state)["root_verifications"] = [receipt]
  record.submit("check")
  runtime.tick(now: now + 2)
  historical = checker.calls.last.fetch(:context).fetch("root_verifications").first
  assert(!historical["artifact_matches"] && historical["input_digest"] == receipt["input_digest"],
         "tests from an earlier artifact stay historical; their binding is never retagged")
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
  record.submit("check")
  runtime.tick(now: now + 2.5)
  assert(checker.calls.length == 2, "a stale result does not self-restart; the explicit manual check reviews the current version")
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
  assert(final["status"] != "complete", "an adjudicator verdict cannot complete the task")
  assert(final.dig("findings", "preference", "status") == "resolved", "retraction is retained")
  assert(final["decisions"].length == 1, "adjudication reason is retained")
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
  assert(checker.calls.length == 1, "a stale result waits for a new trigger instead of calling again")
  record.submit("check")
  runtime.tick(now: now + 2.5)
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
  assert(events(record).count { |event| event["type"] == "correction_sent" } == 1 &&
         record.state.dig("findings", "missing", "status") == "open",
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
  assert(checker.calls.length == 1, "a stale clue does not immediately restart the checker")
  record.submit("check")
  runtime.tick(now: now + 1.5)
  checker.result = answer("continue", resolved: ["clue"])
  runtime.tick(now: now + 3)
  assert(record.state["recheck"].nil? &&
         events(record).none? { |event| event["type"] == "correction_sent" },
         "an explicit withdrawal clears the clue without a correction")
end

# JEV usage aggregation is independent of scheduling. Multiple measured calls
# add within their stage; an unmeasured call makes the stage total explicitly
# incomplete instead of fabricating zero tokens.
fixture do |_root, record, host, checker, runtime|
  runtime.send(:accumulate_jev_usage, "jev_stage1", { "input_tokens" => 10, "output_tokens" => 3 })
  runtime.send(:accumulate_jev_usage, "jev_stage1", { "input_tokens" => 10, "output_tokens" => 3 })
  runtime.send(:save)
  assert(record.state.dig("usage", "jev_stage1") ==
         { "input_tokens" => 20, "output_tokens" => 6, "incomplete" => false },
         "measured JEV calls accumulate within one stage")

  runtime.send(:accumulate_jev_usage, "jev_stage1", nil)
  runtime.send(:save)
  assert(record.state.dig("usage", "jev_stage1", "incomplete") == true,
         "a JEV call without measured usage makes the stage total unknown")
end

class RuntimePoolHost < RuntimeTeamHost
  attr_accessor :catalog

  def initialize(root)
    super
    @catalog = { "current" => "openai/gpt-6-astra",
                 "available" => %w[openai/gpt-6-astra opencode-go/deepseek-v4.1-flash zhipu/glm-5],
                 "agents" => { "opencode-go/deepseek-v4.1-flash" => "orbit-m-deepseek",
                               "zhipu/glm-5" => "orbit-m-glm" },
                 "routes" => { "opencode-go/deepseek-v4.1-flash" => "direct_api",
                               "zhipu/glm-5" => "unknown" } }
  end

  def model_catalog = @catalog
  def configured_model = "openai/gpt-6-astra"
  def default_member_model = "opencode-go/deepseek-v4.1-flash"
  def default_member_route = "direct_api"
end

class StubCandidatePool
  attr_accessor :models

  def initialize(models)
    @models = models
  end

  def read = @models
end

# These are scripted runtime integration cases. Model/task-fit semantics and
# release binding are verified in member_model_selector_test; none of these
# fixtures is a real Jev call or proof of autonomous model-backed delivery.
class RuntimeMemberSelector
  attr_reader :calls
  attr_accessor :decision, :on_call, :receipts

  def initialize
    @calls = []
    @decision = "recommended"
    @sequence = 0
    @receipts = %w[delegation candidates].map do |phase|
      { "phase" => phase, "provider" => "typesafe", "model" => "jev-1.13.0", "status" => "answered",
        "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
        "question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS[phase],
        "requested_model" => "jev-1.13.0", "call_id" => "runtime-fixture-#{phase}",
        "usage" => { "input_tokens" => 12, "output_tokens" => 2 } }
    end
  end

  def assess(state:, work_unit:, previous: nil)
    @calls << { "state" => state, "work_unit" => work_unit }
    signature = Digest::SHA256.hexdigest(JSON.generate([state, work_unit, @decision, @receipts]))
    return previous.merge("reused" => true) if previous && previous["signature"] == signature

    @on_call&.call
    @sequence += 1
    { "version" => Orbit::MemberModelSelector::VERSION, "signature" => signature,
      "decision" => @decision, "reason" => "scripted selection", "reused" => false,
      "judgments" => @receipts.map { |receipt| receipt.merge("call_id" => "#{receipt['call_id']}-#{@sequence}") },
      "judgment_state" => state,
      "candidates" => [{ "agent" => "orbit-m-deepseek", "model" => "opencode-go/deepseek-v4.1-flash",
                          "quality_basis" => "exact_model_evidence", "recommendation_hold" => false }],
      "recommendation" => { "first" => @decision == "recommended" ? "orbit-m-deepseek" : nil, "backups" => [] } }
  end
end

def declared_unit(record, dependencies: [])
  Orbit::WorkUnitStore.new(record).declare(
    "objective" => "Implement the second behavior", "requirements" => ["original: second behavior"],
    "context" => "Root owns integration", "decisions" => ["Keep first behavior"],
    "allowed_paths" => ["artifact.txt"], "allowed_tools" => %w[read write],
    "acceptance" => "Both declared behaviors can be inspected", "dependencies" => dependencies,
    "escalation" => "Return conflicts to Root", "model_requirements" => { "relevant_indices" => ["coding_index"] }
  )
end

# Actual unit input/scope goes through the selector, both invocations are
# accounted once, a restart reuses the result, and a delivered hint is unique.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  unit = declared_unit(record)
  selector = RuntimeMemberSelector.new
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor, member_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  request = selector.calls.first
  assert(request["work_unit"]["id"] == unit["id"] && request["work_unit"]["acceptance"] == unit["acceptance"] &&
         request["state"]["instruction"] == record.inputs["instruction"] && request["state"]["workspace"] == record.state["workspace"],
         "selection receives the actual work unit, instruction and workspace")
  hint = record.state["delegation_hint"]
  assert(hint["work_unit_id"] == unit["id"] && host.messages.last.include?("orbit-unit: #{unit['id']}") &&
         !host.messages.last.match?(/parallel_gain|end-to-end time|cost tier/), "new advice names the unit and has no time/tier score")
  ledger = runtime.send(:resource_call_ledger).calls
  assert(ledger.length == 2, "both real-shaped invocation receipts are accounted")
  restarted = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor, member_selector: selector)
  restarted.tick(now: now + 8)
  assert(host.messages.length == 1 && runtime.send(:resource_call_ledger).calls.length == 2,
         "restart repeats neither the delivered hint nor consumption")
end

# A matching model alone cannot attribute a hint; the native dispatch must
# actually bind the same unit, member id and tool call. A wrong call stays Root's choice.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  unit = declared_unit(record)
  selector = RuntimeMemberSelector.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, member_selector: selector)
  runtime.send(:stage_delegation, runtime.send(:fingerprint_artifact), Time.now.to_f, host: host.state)
  runtime.send(:deliver_pending_hint)
  member = { "thread_id" => "orbit-actual-member", "tool_call_id" => "actual-call", "model" => "opencode-go/deepseek-v4.1-flash" }
  assert(runtime.send(:delegation_basis, member) == "root_without_hint", "same model without a unit binding is insufficient")
  hint = record.state["delegation_hint"]
  Orbit::WorkUnitStore.new(record).bind(unit["id"], member_id: member["thread_id"], tool_call_id: member["tool_call_id"], model: member["model"],
                                      hint_signature: hint["signature"], hint_message_id: hint["message_id"])
  assert(runtime.send(:delegation_basis, member.merge("tool_call_id" => "other-call")) == "root_without_hint", "wrong invocation cannot inherit the hint")
  record.register_member(member["thread_id"], requested_name: "bounded-task", model: member["model"], tool_call_id: member["tool_call_id"])
  runtime.tick(now: Time.now.to_f)
  assert(record.state.dig("members", 0, "delegation_basis") == "orbit_hint" &&
         record.state.dig("delegation_hint", "followed_tool_call_id") == member["tool_call_id"], "actual bound native member follows the advice")
  runtime.tick(now: Time.now.to_f + 1)
  assert(events(record).count { |event| event["type"] == "delegation_hint_followed" } == 1, "actual following is recorded once")
  Orbit::WorkUnitStore.new(record).finish(unit["id"], status: "rejected", result: "second behavior absent",
                                        verification: "Root inspected and rejected the previous attempt")
  runtime.send(:stage_delegation, runtime.send(:fingerprint_artifact), Time.now.to_f, host: host.state)
  runtime.send(:deliver_pending_hint)
  assert(record.state.dig("delegation_hint", "dispatch_attempt") == 2 &&
         runtime.send(:delegation_basis, member) == "root_without_hint" &&
         record.state.dig("delegation_hint", "followed") != true,
         "the previous dispatch cannot follow advice for a new attempt before that attempt actually binds")
end

# A delivered hint is served back by the native host as this task's own
# internal message. Scanning that readback must not move the real user
# boundary: the unchanged input/artifact reuses the same selection without
# paying a second two-phase judgment, no duplicate hint is delivered, and
# the actually bound member still follows the advice.
fixture(interval: 300, host_class: RuntimeBoundaryHost) do |root, record, host, checker, _runtime|
  host.working("progress")
  unit = declared_unit(record)
  selector = RuntimeMemberSelector.new
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor, member_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  hint = record.state["delegation_hint"]
  assert(hint && hint["message_id"] && record.state["sent_message_ids"].include?(hint["message_id"]),
         "the delivered hint is this task's own recorded message")
  boundary = record.state["last_user_message_id"]
  runtime.tick(now: now + 7)
  assert(record.state["last_user_message_id"] == boundary,
         "the hint's own readback never moves the real user boundary")
  assert(runtime.send(:resource_call_ledger).calls.length == 2,
         "same actual input/artifact with only the internal hint readback pays no second two-phase judgment")
  assert(host.messages.length == 1, "the unchanged selection delivers no duplicate hint")
  assert(events(record).none? { |event| event["type"] == "user_message_unassigned" },
         "the internal readback is never mistaken for a user amendment")
  member = { "thread_id" => "orbit-boundary-member", "tool_call_id" => "boundary-call",
             "model" => "opencode-go/deepseek-v4.1-flash" }
  Orbit::WorkUnitStore.new(record).bind(unit["id"], member_id: member["thread_id"], tool_call_id: member["tool_call_id"],
                                      model: member["model"], hint_signature: hint["signature"], hint_message_id: hint["message_id"])
  assert(runtime.send(:delegation_basis, member) == "orbit_hint",
         "a hint delivered by Orbit itself stays attributable to the actual dispatch")
end

# A real new user message still moves the boundary: the delivered hint stops
# being attributable and the next assessment round may be paid again.
fixture(interval: 300, host_class: RuntimeBoundaryHost) do |root, record, host, checker, _runtime|
  host.working("progress")
  unit = declared_unit(record)
  selector = RuntimeMemberSelector.new
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor, member_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  hint = record.state["delegation_hint"]
  assert(hint && hint["user_boundary"] == record.state["last_user_message_id"],
         "hint delivered against the pre-revision boundary")
  posted = host.post_user_message("改:第二个行为改为问候全名")
  runtime.tick(now: now + 7)
  assert(record.state["last_user_message_id"] == posted["id"] &&
         record.state["unassigned_user_message_id"] == posted["id"],
         "the real user message moves the boundary and stays an unassigned amendment")
  assert(runtime.send(:resource_call_ledger).calls.length == 4,
         "a real user boundary move allows a fresh paid two-phase assessment")
  member = { "thread_id" => "orbit-revised-member", "tool_call_id" => "revised-call",
             "model" => "opencode-go/deepseek-v4.1-flash" }
  Orbit::WorkUnitStore.new(record).bind(unit["id"], member_id: member["thread_id"], tool_call_id: member["tool_call_id"],
                                      model: member["model"], hint_signature: hint["signature"], hint_message_id: hint["message_id"])
  assert(runtime.send(:delegation_basis, member) == "root_without_hint",
         "a hint from before a real user boundary move cannot attribute the dispatch")
end

# Repeated scans over only internal readbacks are idempotent: the boundary
# stays put, nothing is reclassified as a user message and no further
# judgment or hint is produced.
fixture(interval: 300, host_class: RuntimeBoundaryHost) do |root, record, host, checker, _runtime|
  host.working("progress")
  declared_unit(record)
  selector = RuntimeMemberSelector.new
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor, member_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  boundary = record.state["last_user_message_id"]
  3.times { |round| runtime.tick(now: now + 7 + round) }
  assert(record.state["last_user_message_id"] == boundary && host.messages.length == 1 &&
         runtime.send(:resource_call_ledger).calls.length == 2 &&
         events(record).none? { |event| event["type"] == "user_message_unassigned" },
         "repeated internal readback scans never loop into new boundaries, judgments or hints")
end

# Unreviewed production selection never pays for member fit or recommends;
# ordinary native dispatch remains independent of the advisory selector.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimePoolHost.new(root)
  host.working("progress")
  declared_unit(record)
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1)
  selector = Orbit::MemberModelSelector.new(connection: host, project_root: root,
    pool: StubCandidatePool.new(["opencode-go/deepseek-v4.1-flash"]), evidence_cache: evidence_cache(root), advisor: advisor, release: nil)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor, member_selector: selector)
  runtime.tick(now: Time.now.to_f + 6)
  assert(record.state.dig("jev", "delegation", "decision") == "facts_only" && advisor.delegation_calls.empty? &&
         advisor.candidate_calls.empty? && host.messages.empty?, "unreviewed task fit displays facts without a paid recommendation")
  record.register_member("orbit-root-chose", requested_name: "own-choice", model: "opencode-go/deepseek-v4.1-flash", tool_call_id: "own-call")
  runtime.tick(now: Time.now.to_f + 7)
  assert(record.state.dig("members", 0, "delegation_basis") == "root_without_hint", "Root can choose a native member without a Jev hint")
end

# Declared dependencies must be accepted before a unit reaches selection;
# revising the task invalidates the old input and every undelivered hint.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  prerequisite = declared_unit(record)
  dependent = declared_unit(record, dependencies: [prerequisite["id"]])
  store = Orbit::WorkUnitStore.new(record)
  store.bind(prerequisite["id"], member_id: "pre", tool_call_id: "pre-call", model: "opencode-go/deepseek-v4.1-flash")
  selector = RuntimeMemberSelector.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, member_selector: selector)
  runtime.send(:stage_delegation, runtime.send(:fingerprint_artifact), Time.now.to_f, host: host.state)
  assert(selector.calls.empty?, "an unaccepted dependency is never assessed as ready")
  store.finish(prerequisite["id"], status: "accepted", result: "first behavior", verification: "Root inspected artifact")
  runtime.send(:stage_delegation, runtime.send(:fingerprint_artifact), Time.now.to_f, host: host.state)
  assert(selector.calls.last["work_unit"]["id"] == dependent["id"], "acceptance enables exactly the dependent unit")
  record.submit("amend", "text" => "Change second behavior", "source" => { "id" => "revised", "kind" => "native_user_message" })
  runtime.send(:consume_commands)
  runtime.send(:deliver_pending_hint)
  assert(record.state["delegation_hint"].nil? && host.messages.none? { |text| text.include?("Orbit model recommendation") },
         "old-unit recommendation cannot be delivered after an input amendment")
end

# A supervision finding takes precedence and does not spend member judgments.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  declared_unit(record)
  selector = RuntimeMemberSelector.new
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor, member_selector: selector)
  runtime.tick(now: Time.now.to_f + 6)
  assert(checker.calls.last[:role] == "process_reviewer" && selector.calls.empty? && host.messages.empty?,
         "process review wins before any member judgment or hint")
end

# Failed judgment consumption is kept even without any recommendation. Reuse
# of that exact unavailable observation adds neither calls nor fake zero usage.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  declared_unit(record)
  selector = RuntimeMemberSelector.new
  selector.decision = "not_recommended"
  selector.receipts = [{ "phase" => "delegation", "provider" => "typesafe", "model" => "jev-1.13.0",
                         "requested_model" => "jev-1.13.0", "status" => "unavailable", "call_id" => "failed-real-shaped-call",
                         "input_version" => Orbit::ModelQualityPolicy::INPUT_VERSION,
                         "question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS["delegation"],
                         "usage" => { "input_tokens" => 17 }, "error" => "partial response" }]
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, member_selector: selector)
  2.times { runtime.send(:stage_delegation, runtime.send(:fingerprint_artifact), Time.now.to_f, host: host.state) }
  ledger = runtime.send(:resource_call_ledger).calls
  call = ledger.first
  assert(ledger.length == 1 && call["usage"] == { "input_tokens" => 17 } && call["usage_status"] == "partial",
         "failed partial usage is attributable, retained and never filled with zero")
  assert(record.state["delegation_hint"].nil? && host.messages.empty?, "a failure receipt cannot create positive advice")
  unit = Orbit::WorkUnitStore.new(record).list.first
  selector.decision = "recommended"
  selector.on_call = lambda do
    store = Orbit::WorkUnitStore.new(record)
    store.bind(unit["id"], member_id: "orbit-interleaved", tool_call_id: "interleaved-call",
               model: "opencode-go/deepseek-v4.1-flash")
    store.finish(unit["id"], status: "failed", result: "interleaved failed attempt",
                 verification: "Root inspected that the member failed")
  end
  runtime.send(:stage_delegation, runtime.send(:fingerprint_artifact), Time.now.to_f, host: host.state)
  runtime.send(:deliver_pending_hint)
  assert(record.state["delegation_hint"].nil? && host.messages.empty?,
         "a dispatch completed during assessment invalidates the prospective hint before it can be delivered")
end

# ADR-009 §4 checker model integration: selection happens only before a
# new check, an in-flight check never switches, an undecided selection
# blocks without snapshots or selector hammering, and a pool change affects
# exactly the next check.
class RuntimeSelectingChecker
  attr_reader :calls, :selected_models
  attr_accessor :result, :failure_message, :failure_kind, :failure_basis

  def initialize
    @calls = []
    @selected_models = []
    @failure_kind = "auth_or_quota"
    @failure_basis = "structured"
  end

  def start(**args)
    @calls << args
  end

  def poll
    raise Orbit::CheckRunner::Error, @failure_message if @failure_message

    @result
  end

  def stop! = true
  def failure_kind = @failure_message ? @failure_kind : nil
  def failure_basis = @failure_message ? @failure_basis : nil

  def select_model!(model)
    @selected_models << model
  end
end

class StubCheckerSelector
  attr_accessor :model, :error, :signature, :snapshot_value
  attr_reader :calls

  def initialize(model, signature = "sig-1")
    @model = model
    @signature = signature
    @snapshot_value = "snap-1"
    @calls = []
  end

  def snapshot(instruction:)
    @snapshot_value
  end

  def select(explicit:, instruction:, previous: nil, selected_for:, excluded: [], state: {})
    @calls << { "role" => selected_for, "instruction" => instruction, "excluded" => excluded, "state" => state }
    raise Orbit::CheckerModelSelector::Error, @error if @error

    choices = [explicit, @model, "openai/gpt-6-astra"].compact.map(&:to_s).reject(&:empty?).uniq
    chosen = choices.find { |model| !excluded.include?(model) }
    raise Orbit::CheckerModelSelector::Error, "no unused model" unless chosen

    [chosen, { "source" => chosen == explicit ? "explicit" : "candidate_pool",
               "model" => chosen, "signature" => @signature, "selected_for" => selected_for }]
  end
end

fixture do |root, record, _host, _checker, _runtime|
  host = RuntimeTeamHost.new(root)
  pool = StubCandidatePool.new(["zhipu/glm-5"])
  selector = StubCheckerSelector.new("zhipu/glm-5")
  checker = RuntimeSelectingChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker,
                                   candidate_pool: pool, checker_selector: selector)
  now = Time.now.to_f
  selector.error = "no runnable checker model in the candidate pool"
  runtime.tick(now: now)
  assert(checker.calls.empty? && record.state.fetch("checks").empty? &&
         record.state.dig("review", "blocked", "type") == "selection_undecided",
         "an undecided selection blocks without starting a check or building a snapshot")
  runtime.tick(now: now + 1)
  assert(checker.calls.empty? && selector.calls.length == 1 &&
         host.messages.count { |text| text.include?("orbit review-model") } == 1,
         "the blocked state neither re-runs the selector nor repeats the notice")

  selector.error = nil
  selector.signature = "sig-2"
  selector.snapshot_value = "snap-2" # catalog/evidence changed outside the pool
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 1 && checker.selected_models == ["zhipu/glm-5"] &&
         record.state.dig("review", "selection", "model") == "zhipu/glm-5" &&
         record.state.dig("review", "blocked").nil?,
         "a changed selection snapshot (catalog or evidence) clears the undecided block and the next check uses the fresh selection")

  selector.model = "openai/gpt-6-astra"
  runtime.tick(now: now + 3)
  assert(checker.calls.length == 1 && checker.selected_models == ["zhipu/glm-5"],
         "an in-flight check never switches its model")

  checker.result = answer("complete")
  runtime.tick(now: now + 4)
  record.submit("check")
  host.finish("delivered before manual selection")
  runtime.tick(now: now + 5)
  assert(checker.calls.length == 2 && checker.selected_models.last == "openai/gpt-6-astra" &&
         record.state.dig("review", "model") == "openai/gpt-6-astra",
         "the next check after the pool change runs on the new selection")

  runtime.send(:add_amendment, "Add a login page.", { "kind" => "test", "id" => "amend-1" })
  checker.result = answer("complete")
  runtime.tick(now: now + 6)
  record.submit("check")
  runtime.tick(now: now + 7)
  assert(checker.calls.length == 3 &&
         selector.calls.last["instruction"].include?("Provide first and second behaviors.") &&
         selector.calls.last["instruction"].include?("Add a login page.") &&
         selector.calls.last["instruction"].include?("--- amendment ---"),
         "an amendment reaches the next selection inside the effective instruction (Q20)")
end

# A real failure is preserved, the next OMP model checks the same version,
# and only exhausted candidates block. Root can choose again after repair.
fixture do |root, record, _host, _checker, _runtime|
  host = RuntimeTeamHost.new(root)
  selector = StubCheckerSelector.new("zhipu/glm-5")
  checker = RuntimeSelectingChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker,
                                   candidate_pool: StubCandidatePool.new(["zhipu/glm-5"]),
                                   checker_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now)
  assert(checker.calls.length == 1, "precondition: a check is in flight")
  checker.failure_message = "OMP reviewer exited 1: 401 invalid api key"
  runtime.tick(now: now + 1)
  failed = record.state.fetch("checks").last
  assert(failed["failed"] && failed.dig("result", "verdict") == "check_failed" &&
         failed.dig("result", "failure_kind") == "auth_or_quota" &&
         record.state.dig("review", "failed_models", "models") == ["zhipu/glm-5"] &&
         record.state.dig("review", "blocked").nil?,
         "the failed check is retained and its model excluded, without failing the task")

  checker.failure_message = nil
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 2 && checker.selected_models.last == "openai/gpt-6-astra" &&
         selector.calls.last["excluded"] == ["zhipu/glm-5"],
         "a different OMP model is tried automatically without a user directive")
  checker.result = answer("complete")
  runtime.tick(now: now + 3)
  assert(record.state.fetch("checks").last.dig("result", "verdict") == "complete" &&
         record.state.fetch("checks").first["failed"],
         "the successful replacement check does not erase the failed attempt")

  record.submit("check")
  host.finish("delivered final answer")
  runtime.tick(now: now + 4)
  checker.failure_message = "provider returned 429"
  runtime.tick(now: now + 5)
  runtime.tick(now: now + 6)
  assert(record.state.dig("review", "blocked", "type") == "selection_undecided" &&
         checker.calls.length == 3, "all failed candidates block without replaying the same model")
  record.submit("review_model", "model" => "zhipu/glm-5", "reason" => "Root explicitly re-tries this model")
  checker.failure_message = nil
  runtime.tick(now: now + 7)
  assert(checker.calls.length == 4 && record.state.dig("review", "blocked").nil? &&
         record.state.dig("review", "model") == "zhipu/glm-5",
         "Root can choose an available model after repairing credentials without user authorization")
end

# Task-scoped structured auth_or_quota exclusion: a model that RETURNED a
# structured auth/quota failure is not retried after the artifact changes
# (033 checks #1 -> #8), while plain unavailable/invalid_result failures keep
# their existing artifact-scoped retry semantics; Root's review-model is an
# explicit retry authorization for exactly the named target and never wipes
# other structured exclusions.
fixture do |root, record, _host, _checker, _runtime|
  host = RuntimeTeamHost.new(root)
  selector = StubCheckerSelector.new("zhipu/glm-5")
  checker = RuntimeSelectingChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker,
                                   candidate_pool: StubCandidatePool.new(["zhipu/glm-5"]),
                                   checker_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.failure_message = "OMP reviewer exited 1: 401 invalid api key"
  runtime.tick(now: now + 1)
  assert(record.state.dig("review", "auth_or_quota_models") == ["zhipu/glm-5"],
         "a structured auth_or_quota failure records the model in the task-scoped set")
  File.write(File.join(root, "artifact.txt"), "changed after credential failure")
  checker.failure_message = nil
  runtime.tick(now: now + 2)
  assert(record.state.dig("review", "failed_models").nil? &&
         selector.calls.last["excluded"] == ["zhipu/glm-5"] &&
         checker.selected_models.last == "openai/gpt-6-astra",
         "the artifact change clears artifact-scoped failures but the evidenced auth_or_quota model stays excluded")
  checker.result = answer("complete")
  runtime.tick(now: now + 3)
  selector.model = "zhipu/glm-5"
  record.submit("check")
  host.finish("delivered final answer")
  runtime.tick(now: now + 4)
  runtime.tick(now: now + 5)
  assert(checker.selected_models.last == "openai/gpt-6-astra" &&
         selector.calls.last["excluded"].include?("zhipu/glm-5"),
         "a new artifact never re-selects the task-scoped auth_or_quota model on its own")
end

fixture do |root, record, _host, _checker, _runtime|
  host = RuntimeTeamHost.new(root)
  selector = StubCheckerSelector.new("zhipu/glm-5")
  checker = RuntimeSelectingChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker,
                                   candidate_pool: StubCandidatePool.new(["zhipu/glm-5"]),
                                   checker_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.failure_message = "OMP reviewer exited 1: model overloaded"
  checker.failure_kind = "unavailable"
  runtime.tick(now: now + 1)
  assert(record.state.dig("review", "auth_or_quota_models").nil?,
         "a plain unavailable failure never enters the task-scoped set")
  File.write(File.join(root, "artifact.txt"), "changed after overload")
  checker.failure_message = nil
  runtime.tick(now: now + 2)
  assert(selector.calls.last["excluded"] == [] &&
         checker.selected_models.last == "zhipu/glm-5",
         "an artifact change restores an unavailable model exactly as before")
  checker.failure_message = "OMP reviewer produced an invalid result"
  checker.failure_kind = "invalid_result"
  runtime.tick(now: now + 3)
  File.write(File.join(root, "artifact.txt"), "changed after invalid result")
  checker.failure_message = nil
  runtime.tick(now: now + 4)
  assert(record.state.dig("review", "auth_or_quota_models").nil? &&
         checker.selected_models.last == "zhipu/glm-5" &&
         selector.calls.last["excluded"] == [],
         "an invalid_result failure also stays out of the task-scoped set and the model is retried after the artifact change")
end

fixture do |root, record, _host, _checker, _runtime|
  host = RuntimeTeamHost.new(root)
  selector = StubCheckerSelector.new("zhipu/glm-5")
  checker = RuntimeSelectingChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker,
                                   candidate_pool: StubCandidatePool.new(["zhipu/glm-5"]),
                                   checker_selector: selector)
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.failure_message = "OMP reviewer exited 1: 401 invalid api key"
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 2)
  checker.failure_message = "OMP reviewer exited 1: 429 quota exceeded on replacement"
  runtime.tick(now: now + 4)
  runtime.tick(now: now + 5)
  assert(record.state.dig("review", "auth_or_quota_models") == ["zhipu/glm-5", "openai/gpt-6-astra"] &&
         record.state.dig("review", "blocked", "type") == "selection_undecided",
         "two structured auth_or_quota failures block with both models recorded task-scoped")
  record.submit("review_model", "model" => "zhipu/glm-5", "reason" => "Root explicitly re-tries this model")
  checker.failure_message = nil
  runtime.tick(now: now + 6)
  runtime.tick(now: now + 7)
  assert(checker.selected_models.last == "zhipu/glm-5" &&
         record.state.dig("review", "auth_or_quota_models") == ["openai/gpt-6-astra"],
         "review-model recovers only the named target; the other exclusion survives")
end

# ADR-009 model drift: OMP records `model_drift` on a registered member
# when the final model differs from the resolved candidate. The runtime
# fails the member on its next reconcile, never accepts a later native
# result as a completion, invalidates the stale hint, stops the drifted
# session and asks Root to explicitly re-select — it never switches models
# itself.
class RuntimeDriftHost < RuntimeTeamHost
  attr_reader :stopped_ids

  def initialize(root)
    super
    @stopped_ids = []
    # Before the drift is written the member is an ordinary running native
    # member with no accepted result; the accepted/idle observation is only
    # switched on afterwards to prove the drift veto blocks completion.
    @native_state = { "registry_status" => "running", "model" => "openai/gpt-6-astra" }
    @native_result = {}
  end

  def accept_drifted_result
    @native_state = { "registry_status" => "idle", "model" => "openai/gpt-6-astra",
                      "lifecycle" => { "acceptedAt" => 1 } }
    @native_result = { "output_text" => "work produced by the drifted model" }
  end

  def member_state(_id) = @native_state
  def member_result(_id) = @native_result

  def stop_member(id)
    @stopped_ids << id
    { "confirmed" => true, "active_tools_after" => 0, "async_jobs_settled" => true }
  end
end

fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeDriftHost.new(root)
  host.working("progress")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  now = Time.now.to_f
  record.register_member("orbit-drift1", requested_name: "drift1", status: "registered")
  runtime.tick(now: now)
  member = record.state["members"].first
  assert(member && member["status"] == "registered" && member["delegation_basis"] == "root_without_hint",
         "precondition: the member reconciles normally before any drift")

  state = runtime.instance_variable_get(:@state)
  state["delegation_hint"] = { "signature" => "stale", "followed" => false }
  record.record_member_model_drift("orbit-drift1", expected: "opencode-go/deepseek-v4.1-flash",
                                                   actual: "openai/gpt-6-astra",
                                  abort_attempted: true, abort_confirmed: false)
  host.accept_drifted_result
  runtime.tick(now: now + 1)
  member = record.state["members"].first
  assert(member["status"] == "failed" &&
         member.dig("model_drift", "expected") == "opencode-go/deepseek-v4.1-flash" &&
         member.dig("model_drift", "actual") == "openai/gpt-6-astra" &&
         member.dig("model_drift", "abort_confirmed") == false,
         "the drift is persisted and the member is failed, not registered")
  assert(host.stopped_ids == ["orbit-drift1"] && member["drift_stop"] == "confirmed",
         "the drifted session is stop-confirmed before more unauthorized work")
  notice = host.messages.find { |message| message.include?("model drift") }
  assert(notice && notice.include?("re-select") && notice.include?("orbit-drift1"),
         "Root is told to explicitly re-select; Orbit does not switch models itself")
  assert(state.dig("delegation_hint", "invalid_reason") == "model_drift" &&
         runtime.send(:delegation_basis) == "root_without_hint",
         "the stale hint is invalidated and cannot label later dispatches")
  assert(runtime.send(:member_blocks_new_hint?, member),
         "an unresolved drift blocks new automatic hints")

  runtime.tick(now: now + 2)
  member = record.state["members"].first
  assert(member["status"] == "failed" && member["result"].nil? &&
         events(record).none? { |event| event["type"] == "member_result_recorded" },
         "an accepted native result from the drifted model never completes the member")
  assert(host.messages.count { |message| message.include?("model drift") } == 1 &&
         host.stopped_ids.length == 1,
         "the drift handling is idempotent across ticks")
end

# A registered native member is stopped from the task record. There is no
# allowlist left to exempt or block that stop.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  native = { "registry_status" => "idle", "streaming" => false }
  host.define_singleton_method(:member_state) { |_id| native }
  host.define_singleton_method(:member_result) { |_id| { "output_text" => "returned result" } }
  record.register_member("orbit-handoff", requested_name: "handoff", status: "registered")
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  assert(record.state["pending_finalization"] && record.state["finalization_notices"].empty?,
         "a qualified review waits for native acceptance rather than treating idle or returned prose as completion")
  native["lifecycle"] = { "acceptedAt" => 1 }
  runtime.tick(now: now + 2)
  runtime.tick(now: now + 3)
  assert(record.state["members"].first["status"] == "completed" &&
         record.state["finalization_notices"].length == 1 && checker.calls.length == 1,
         "later native acceptance sends one same-version notice without buying a duplicate final review")
end

fixture do |_root, record, host, _checker, _runtime|
  state = record.state
  state["connection"]["thread_id"] = "existing-root"
  state["members"] = [{ "adapter" => "omp_native_task", "thread_id" => "orbit-m1", "kind" => "omp", "status" => "registered" }]
  record.save(state)
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil).retry_stop("User retried stop")
  assert(result["status"] == "paused" && host.member_stops == ["orbit-m1"],
         "a registered native member is stopped from the task record")
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
  assert(record.state["status"] != "complete" && record.state["recheck"].nil?,
         "withdrawing the clue qualifies the hand-off but does not complete the task")
  assert(record.state["finalization_notices"].length == 1, "the manual complete verdict wakes Root")
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
  assert(record.state.dig("findings", "clue").nil?, "a process check does not deliver the artifact clue")

  host.finish("integrated")
  checker.result = nil
  runtime.tick(now: now + 12)
  assert(checker.calls.last[:role] == "reviewer" && checker.calls.last[:context].dig("recheck", "findings", 0, "id") == "clue",
         "the next artifact check receives the pending clue")
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 13)
  assert(record.state["recheck"].nil?, "the artifact check confirms and clears the clue")
  assert(events(record).count { |event| event["type"] == "correction_sent" } == 2 &&
         record.state.dig("findings", "clue", "status") == "open",
         "the pending clue is delivered after the process finding")
end

# While Root executes, neither a short checker suggestion nor the elapsed
# interval triggers another unchanged full check. A completed turn does.
fixture(interval: 300) do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  host.working("Root is executing")
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  assert(record.state.fetch("checks").last["stale"] == false &&
         !record.state.fetch("checks").last["stale_reasons"].include?("host"),
         "an artifact check ignores a host-only digest change")
  runtime.tick(now: now + 61)
  assert(checker.calls.length == 1, "short checker suggestions do not restart full checks while Root executes")
  runtime.tick(now: now + 310)
  assert(checker.calls.length == 1, "an unchanged timer does not trigger a full check during Root execution")
  host.finish("new-delivery")
  runtime.tick(now: now + 311)
  assert(checker.calls.length == 2, "a completed Root turn triggers a fresh observation")
end

# A process check still expires when only the host digest changes. An artifact
# completion uses the same rule and is not blocked by that host change.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  host.working("progress")
  runtime.tick(now: now + 6)
  assert(checker.calls.last&.fetch(:role) == "process_reviewer", "precondition: a process check is in flight")
  host.working("host moved")
  checker.result = answer("continue")
  runtime.tick(now: now + 7)
  assert(record.state.fetch("checks").last["kind"] == "process" &&
         record.state.fetch("checks").last["stale_reasons"] == ["host"],
         "a process check stays stale when only the host digest changes")

  host.finish("delivered")
  checker.result = nil
  runtime.tick(now: now + 8)
  host.working("host moved again")
  host.finish("integrated")
  checker.result = answer("complete")
  runtime.tick(now: now + 9)
  finished = record.state.fetch("checks").last
  assert(finished["kind"] == "artifact" && finished["stale"] == false && !finished["stale_reasons"].include?("host"),
         "the artifact completion check ignores the host-only change")
  assert(record.state["status"] != "complete" && record.state["finalization_notices"].empty?,
         "an automatic complete verdict cannot finish the task or wake Root")
end

# The checker context receives only the snapshot's added, modified and deleted
# paths, already bounded. Unchanged tracked files are not a review focus.
fixture do |root, record, host, checker, runtime|
  git = lambda do |*args|
    ok = system("git", "-C", root, "-c", "user.name=orbit-test", "-c", "user.email=orbit-test@example.com",
                "-c", "commit.gpgsign=false", *args, out: File::NULL, err: File::NULL)
    raise "git #{args.join(' ')} failed" unless ok
  end
  git.call("init", "-q")
  File.write(File.join(root, "keep.txt"), "same")
  File.write(File.join(root, "edit.txt"), "old")
  File.write(File.join(root, "gone.txt"), "remove")
  git.call("add", "keep.txt", "edit.txt", "gone.txt", "artifact.txt")
  git.call("commit", "-q", "-m", "base")
  File.write(File.join(root, "edit.txt"), "new")
  File.write(File.join(root, "fresh.txt"), "added")
  File.unlink(File.join(root, "gone.txt"))
  runtime.tick
  focus = checker.calls.last[:context]["review_focus"]
  assert(focus["added"] == ["fresh.txt"] && focus["modified"] == ["edit.txt"] && focus["deleted"] == ["gone.txt"],
         "review_focus lists the snapshot's added, modified and deleted paths")
  assert(!focus.values.flatten.include?("keep.txt") && !focus.values.flatten.include?("artifact.txt"),
         "unchanged tracked files stay out of review_focus")
  overflow = (0..205).map { |index| { "path" => format("f%03d.txt", index), "status" => "added" } }
  overflow << { "path" => "tracked.txt", "status" => "tracked" }
  bounded = runtime.send(:review_focus, overflow)
  assert(bounded["added"].length == 200 && bounded["added"] == bounded["added"].sort &&
         bounded["modified"] == [] && bounded["deleted"] == [] && !bounded["added"].include?("tracked.txt"),
         "review_focus keeps a sorted bound and drops non-diff statuses")
end

# An unchanged idle observation is not re-checked at the checker-suggested
# time: the repeat is skipped and a new delivered turn still starts a fresh
# check for its own observation.
fixture(interval: 300) do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.result = answer("continue", delivery_ready: false)
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 59)
  assert(checker.calls.length == 1, "idle Root waits for the checker-suggested observation")
  runtime.tick(now: now + 62)
  assert(checker.calls.length == 1, "the same unchanged observation is skipped instead of re-checked")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("check_duplicate_skipped"),
         "the duplicate skip is visible in the record")
  host.finish("delivered")
  runtime.tick(now: now + 63)
  assert(checker.calls.length == 2, "a new delivered turn still starts a fresh check")
end

# A failed rebind notice must not lose the persisted rebind or fail the task.
fixture do |root, record, host, checker, runtime|
  Dir.mktmpdir("orbit-rebind-notice-") do |tmp|
    linked = File.join(tmp, "linked")
    git = lambda do |dir, *args|
      ok = system("git", "-C", dir, "-c", "user.name=orbit-test", "-c", "user.email=orbit-test@example.com",
                  "-c", "commit.gpgsign=false", *args, out: File::NULL, err: File::NULL)
      raise "git #{args.join(' ')} failed in #{dir}" unless ok
    end
    git.call(root, "init", "-q")
    File.write(File.join(root, "artifact.txt"), "same bytes")
    git.call(root, "add", "-A")
    git.call(root, "commit", "-q", "-m", "init")
    git.call(root, "worktree", "add", "--detach", "-q", linked, "HEAD")

    record.submit("rebind_workspace", "path" => linked, "reason" => "switch worktree",
                  "source" => { "kind" => "cli", "command" => "rebind-workspace" })
    host.fail_send_message = "omp connection: execution expired"
    runtime.tick
    assert(record.state.dig("workspace", "artifact_root") == File.realpath(linked),
           "the rebind stays persisted when the notice delivery fails")
    assert(record.state["status"] != "failed", "a failed notice does not fail the task")
    assert(File.read(File.join(record.path, "events.jsonl")).include?("workspace_rebind_notice_failed"),
           "the failed notice is auditable")
  end
end

# A transient correction delivery failure must not fail the task (N2
# regression): the failure is recorded, the finding stays open, and the
# correction redelivers when the Root is next observed idle.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  host.finish("delivered")
  missing = { "id" => "CHK-001", "requirement" => "second behavior", "evidence" => "absent in artifact", "action" => "implement second behavior" }
  checker.result = answer("correct", findings: [missing])
  host.fail_send_message = "omp connection: execution expired"
  runtime.tick(now: now + 1)
  assert(record.state["status"] != "failed", "a transient delivery failure does not fail the task")
  assert(record.state["pending_correction"] && record.state["findings"].values.any? { |f| f["status"] == "open" },
         "the failed delivery is kept pending with the finding still open")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("correction_delivery_failed"),
         "the delivery failure is auditable")
  host.fail_send_message = nil
  host.finish("delivered-again")
  runtime.tick(now: now + 2)
  assert(record.state["pending_correction"].nil? &&
         File.read(File.join(record.path, "events.jsonl")).include?("correction_sent"),
         "the pending correction redelivers on the next idle observation")
  sent = events(record).find { |event| event["type"] == "correction_sent" }
  observed = events(record).find { |event| event["type"] == "finding_recorded" }
  assert(sent["check"] == observed["check"] && sent["finding_ids"] == ["CHK-001"] &&
         observed.dig("finding", "evidence") == "absent in artifact" &&
         sent["artifact_digest"] == observed["artifact_digest"],
         "a retried correction remains attributable to its original finding and artifact version")
end

# A version change after a failed delivery retires the pending correction: it
# must NOT be redelivered as advice for the new version.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  host.finish("delivered")
  missing = { "id" => "CHK-001", "requirement" => "second behavior", "evidence" => "absent in artifact", "action" => "implement second behavior" }
  checker.result = answer("correct", findings: [missing])
  host.fail_send_message = "omp connection: execution expired"
  runtime.tick(now: now + 1)
  assert(record.state["pending_correction"], "precondition: a delivery failure leaves a pending correction")
  File.write(File.join(root, "NEW.md"), "version changed before redelivery")
  host.fail_send_message = nil
  host.finish("delivered-again")
  messages_before = host.messages.length
  runtime.tick(now: now + 2)
  assert(record.state["pending_correction"].nil?, "a stale pending correction is dropped")
  assert(host.messages.length == messages_before,
         "a stale pending correction is never redelivered as current-version advice")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("correction_redelivery_stale"),
         "the stale drop is auditable")
end

# A valid manual final review wakes an idle Root exactly once so it can stop;
# it does not accept `continue` as product completion or start a short loop.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 1, "next agreed time must control observation")
  assert(record.state["next_check_trigger"] == "finalization_wait",
         "the normal interval replaces the checker's short retry while finalization waits")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("finalization_notice"),
         "the finalization hand-off is auditable")

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

# A manual reviewer complete verdict is only a hand-off. An automatic
# complete verdict cannot finish the task. Completion still requires Root stop.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  host.finish("delivered")
  checker.result = answer("complete", delivery_ready: false)
  runtime.tick(now: now + 1)
  assert(record.state["status"] != "complete" && record.state["finalization_notices"].empty?,
         "an automatic complete verdict does not finish the task or notify Root")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("automatic_check_complete_ignored"),
         "the ignored automatic complete verdict is auditable")

  record.submit("check")
  runtime.tick(now: now + 2)
  checker.result = answer("complete")
  runtime.tick(now: now + 3)
  assert(record.state["status"] != "complete" && record.state["finalization_notices"].length == 1,
         "a manual complete verdict wakes Root and does not declare completion")

  host.working("delivering the final summary")
  record.submit("stop", "reason" => "User requested stop", "complete" => true)
  runtime.tick(now: now + 4)
  host.finish("delivered")
  runtime.tick(now: now + 5)
  assert(record.state["status"] == "complete",
         "Root's explicit stop after the notice records completion")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("completed_via_finalized_stop"),
         "completion still goes through the finalized stop path")
end

# A delivered answer that receives a clean automatic artifact check still
# needs a separate manual final review. The running Root must be woken to ask
# for it, once per version, rather than silently leaving the task open.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  host.finish("delivered")
  runtime.tick(now: now)
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  assert(host.messages.one? { |message| message.include?("action=check") } &&
         record.state["status"] != "complete" && record.state["finalization_notices"].empty?,
         "a clean automatic review prompts the Root for manual review without granting completion")
  assert(events(record).any? { |event| event["type"] == "manual_final_check_reminded" },
         "the one-time reminder has an auditable version")

  host.finish("reminder-acknowledged")
  record.submit("check")
  runtime.tick(now: now + 2)
  checker.result = answer("complete")
  runtime.tick(now: now + 3)
  assert(record.state["finalization_notices"].length == 1 &&
         host.messages.count { |message| message.include?("action=check") } == 1,
         "the manual reviewer, not the automatic pass, wakes finalization without repeating the reminder")


end

# The manual-final reminder send carries the narrow integration_check tag, and
# the durable facts the host must verify are already ON DISK when send_message
# is CALLED (captured inside the host before the ACK returns): the clean
# resolution check, the resolved finding and the matching delivery; the
# reminder record and the sent id are written only AFTER the real ACK.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  host.finish("delivered")
  runtime.tick(now: now)
  checker.result = answer("correct", findings: [{ "id" => "money-bug", "requirement" => "integer cents",
    "evidence" => "README:24", "action" => "reject lossy conversion" }])
  runtime.tick(now: now + 0.5)
  assert(record.state.dig("findings", "money-bug", "status") == "open", "the finding opens first")
  host.finish("fixed")
  runtime.tick(now: now + 0.8)
  checker.result = answer("complete", resolved: ["money-bug"])
  sent_count_before = host.messages.length
  at_send = nil
  host.on_send = lambda do |_text, tag|
    # Durable state at the moment the send is issued — BEFORE the host returns
    # an id, so the assertions prove save-before-send (removing the new save
    # would fail them under the old write order). The EXPECTED id of this very
    # send is derived from the pre-send message count; it must not be in the
    # durable sent list yet.
    expected_id = "sent-#{sent_count_before + 1}"
    at_send = { "tag" => tag, "expected_id" => expected_id,
                "state" => JSON.parse(File.read(File.join(record.path, "state.json"))) }
  end
  runtime.tick(now: now + 1)
  assert(host.messages.one? { |message| message.include?("action=check") },
         "the clean resolution check sends the manual-final reminder")
  assert(at_send, "the send hook captured the send-time disk state")
  clean = at_send["state"]["checks"].last
  assert(at_send["tag"] == clean["number"] && clean["result"]["verdict"] == "complete" &&
         clean["result"]["delivery"]["ready"] == true && clean["result"]["findings"] == [],
         "the tagged clean check (empty findings) is durable BEFORE the send")
  assert(at_send["state"].dig("findings", "money-bug", "status") == "resolved" &&
         at_send["state"].dig("findings", "money-bug", "resolution_check") == clean["number"],
         "the resolved finding is durable BEFORE the send")
  assert(at_send["state"].dig("task_delivery", "artifact_digest") == clean["artifact_digest"],
         "the matching delivery triple is durable BEFORE the send")
  key = Digest::SHA256.hexdigest(JSON.generate([clean["artifact_root"], clean["input_digest"], clean["artifact_digest"]]))
  assert(at_send["state"]["manual_check_reminders"].nil? ||
         !at_send["state"]["manual_check_reminders"].key?(key),
         "the reminder record does NOT exist at send time (written only after the ACK)")
  assert((at_send["state"]["sent_message_ids"] || []).include?(at_send["expected_id"]) == false,
         "this send's own id is NOT durable at send time (it exists only after the ACK)")
  reminder = record.state["manual_check_reminders"][key]
  assert(reminder && reminder["check"] == clean["number"] &&
         reminder["message_id"] == at_send["expected_id"] &&
         (record.state["sent_message_ids"] || []).include?(reminder["message_id"]),
         "after the ACK the reminder references exactly this send's real id")
end

# A host-only stale process check sends ONE historical notice (not a current
# correction) and persists the attempt for crash-recovery dedup.
fixture do |_root, record, host, _checker, _runtime|
  now = Time.now.to_f
  start_host = { "status" => "active", "last_turn_id" => "turn-1", "last_turn_status" => "inProgress",
                 "observations" => [{ "kind" => "command", "tool" => "write", "status" => "failed" }], "interrupted" => false }
  changed_host = start_host.merge("last_turn_id" => "turn-2",
    "observations" => start_host["observations"] + [{ "kind" => "command", "tool" => "write", "status" => "failed" }])
  checker = RuntimeChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  runtime.send(:start_check, start_host, now, kind: "process", trigger: "jev_process")
  result = answer("correct", findings: [{ "id" => "stuck-1", "requirement" => "progress",
    "evidence" => "3+ same-method retries", "action" => "try a different approach" }])
  runtime.send(:finish_check, result, changed_host, now + 1)
  check = record.state["checks"].last
  assert(check["stale"] && check["stale_reasons"] == ["host"], "precondition: host-only stale process check")
  assert(host.messages.one? { |m| m.include?("历史过程检查线索") }, "the historical notice reaches Root once")
  assert(host.messages.one? { |m| m.include?("stuck-1") }, "finding evidence is included")
  assert(!host.messages.any? { |m| m.include?("correction") || m.include?("纠正") && !m.include?("历史") },
         "the notice is NOT a current correction")
  assert(check["historical_process_notice"] && check["historical_process_notice"]["confirmed"] == true,
         "the persisted attempt is confirmed")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |l| l.include?("historical_process_notice") },
         "the notice has its own auditable event")
  assert(record.state.dig("recheck", "findings")&.any? { |f| f["id"] == "stuck-1" },
         "recheck clues remain intact for the next applicable check")
end

# Dedup after restart + negative gates (interrupted / stale for non-host reasons /
# unattributed turn) — a table fixture covering the remaining control branches.
fixture do |root, record, host, _checker, _runtime|
  now = Time.now.to_f
  base_obs = [{ "kind" => "command", "tool" => "write", "status" => "failed" }]
  start_host = { "status" => "active", "last_turn_id" => "t1", "last_turn_status" => "inProgress",
                 "observations" => base_obs, "interrupted" => false }
  changed_host = start_host.merge("last_turn_id" => "t2",
    "observations" => base_obs + [{ "kind" => "command", "tool" => "write", "status" => "failed" }])

  # (a) First run: the notice fires once; no current finding opened; task not stopped.
  checker = RuntimeChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  runtime.send(:start_check, start_host, now, kind: "process", trigger: "jev_process")
  result = answer("correct", findings: [{ "id" => "stuck-1", "requirement" => "progress",
    "evidence" => "repeated retries", "action" => "try different approach" }])
  runtime.send(:finish_check, result, changed_host, now + 1)
  assert(host.messages.count { |m| m.include?("历史过程检查线索") } == 1, "exactly one notice")
  assert(!record.state["findings"].any? { |_id, f| f["status"] == "open" },
         "no current finding is opened by the historical notice")
  assert(!%w[complete paused failed].include?(record.state["status"]),
         "the notice does not stop, complete or fail the task")

  # (b) A NEW runtime from the same persisted record: normal tick does NOT re-send.
  host.messages.clear
  host.fail_send_message = nil
  fresh = Orbit::TaskRuntime.new(record: record, connection: host, checker: RuntimeChecker.new)
  fresh.tick(now: now + 10)
  assert(host.messages.count { |m| m.include?("历史过程检查线索") } == 0,
         "a restart does not re-send the historical notice")

  # (c) Negative gate: artifact changed during the check → stale_reasons has
  # "artifact" too → no historical notice.
  neg_root = File.join(root, "neg")
  FileUtils.mkdir_p(neg_root)
  host2 = RuntimeHost.new(nil)
  record2 = Orbit::TaskRecord.create(
    project_root: neg_root,
    instruction: "Negative gate test.
", source: { "id" => "orig", "kind" => "native_user_message" },
    connection: { "provider" => "omp" }, review: { "interval_seconds" => 300 }, estimate: {})
  rt2 = Orbit::TaskRuntime.new(record: record2, connection: host2, checker: RuntimeChecker.new)
  h2_start = { "status" => "active", "last_turn_id" => "a1", "last_turn_status" => "inProgress",
               "observations" => base_obs, "interrupted" => false }
  h2_changed = h2_start.merge("last_turn_id" => "a2")
  rt2.send(:start_check, h2_start, now + 20, kind: "process", trigger: "jev_process")
  File.write(File.join(neg_root, "artifact.txt"), "changed")
  rt2.send(:finish_check, answer("correct", findings: [{ "id" => "ng1", "requirement" => "r", "evidence" => "e", "action" => "a" }]),
           h2_changed, now + 21)
  assert(record2.state["checks"].last["stale_reasons"].include?("artifact"),
         "precondition: artifact is also stale")
  assert(!host2.messages.any? { |m| m.include?("历史过程检查线索") },
         "no historical notice when artifact also changed")
  assert(!record2.state["checks"].last["historical_process_notice"], "no attempt persisted")

  # (d) Interrupted Root → no notice (host genuinely changed AND interrupted).
  int_root = File.join(root, "int")
  FileUtils.mkdir_p(int_root)
  host3 = RuntimeHost.new(nil)
  record3 = Orbit::TaskRecord.create(
    project_root: int_root,
    instruction: "Interrupt gate test.
", source: { "id" => "orig", "kind" => "native_user_message" },
    connection: { "provider" => "omp" }, review: { "interval_seconds" => 300 }, estimate: {})
  rt3 = Orbit::TaskRuntime.new(record: record3, connection: host3, checker: RuntimeChecker.new)
  h3_start = { "status" => "active", "last_turn_id" => "i1", "last_turn_status" => "inProgress",
               "observations" => base_obs, "interrupted" => false }
  h3_changed = { "status" => "active", "last_turn_id" => "i2", "last_turn_status" => "inProgress",
    "observations" => base_obs + [{ "kind" => "command", "tool" => "write", "status" => "failed" }], "interrupted" => true }
  rt3.send(:start_check, h3_start, now + 30, kind: "process", trigger: "jev_process")
  rt3.send(:finish_check, answer("correct", findings: [{ "id" => "ig1", "requirement" => "r", "evidence" => "e", "action" => "a" }]),
           h3_changed, now + 31)
  assert(!host3.messages.any? { |m| m.include?("历史过程检查线索") },
         "an interrupted Root gets no historical notice")
  assert(!record3.state["checks"].last["historical_process_notice"], "no attempt when gate rejects")
end

# A delivery failure records unconfirmed, does not fake success, and a
# subsequent normal tick does not auto-retry.
fixture do |_root, record, host, _checker, _runtime|
  now = Time.now.to_f
  start_host = { "status" => "active", "last_turn_id" => "t1", "last_turn_status" => "inProgress",
                 "observations" => [{ "kind" => "command", "tool" => "write", "status" => "failed" }], "interrupted" => false }
  changed_host = start_host.merge("last_turn_id" => "t2")
  checker = RuntimeChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  runtime.send(:start_check, start_host, now, kind: "process", trigger: "jev_process")
  result = answer("correct", findings: [{ "id" => "p3", "requirement" => "r", "evidence" => "e", "action" => "a" }])
  host.fail_send_message = "connection dropped"
  runtime.send(:finish_check, result, changed_host, now + 1)
  stored = record.state["checks"].last["historical_process_notice"]
  assert(stored && stored["confirmed"] == false, "the attempt is persisted as unconfirmed")
  assert(stored["error_class"], "the error class is recorded")
  assert(!host.messages.any? { |m| m.include?("历史过程检查线索") }, "no notice text was delivered")
  assert(record.state["status"] != "failed", "the send failure does not fail the task")
  assert(!(record.state["sent_message_ids"] || []).include?("fake-id"), "no fake sent id recorded")
  # Subsequent normal tick with delivery restored: no auto-retry
  host.fail_send_message = nil
  runtime.tick(now: now + 10)
  assert(!host.messages.any? { |m| m.include?("历史过程检查线索") },
         "a failed historical notice is not auto-retried")
end

# A manual final check queued during the Root's delivery turn must inspect
# the actual completed reply, rather than spending a check on an in-progress,
# empty agent_message and rejecting an otherwise complete artifact.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  host.working("writing the final delivery")
  record.submit("check")
  runtime.tick(now: now)
  assert(checker.calls.empty? && record.state["next_check_manual"] == true,
         "manual final check waits while Root's answer is still in progress")
  host.finish("actual final answer")
  runtime.tick(now: now + 1)
  assert(checker.calls.length == 1 && record.state["check_observations"].values.last["manual"] == true,
         "the queued manual check starts on Root's completed delivery")
  checker.result = answer("complete")
  runtime.tick(now: now + 2)
  assert(record.state["finalization_notices"].length == 1,
         "the delivered answer can receive one valid completion notice")
end

# A version-bound pending hand-off must still reach an active Root within the
# bounded wait, and a repeated same-version hand-off must not reset the timer.
fixture(interval: 300) do |root, record, host, checker, runtime|
  now = Time.now.to_f
  host.finish("delivered")
  record.submit("check")
  runtime.tick(now: now)
  host.working("waiting without ending the next turn")
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  pending = record.state["pending_finalization"]
  assert(pending && record.state["finalization_notices"].empty?,
         "precondition: an active Root keeps the pending notice")

  digest = Orbit::WorkspaceSnapshot.fingerprint(project_root: root)
  runtime.send(:queue_finalization_handoff,
               { "number" => 99, "artifact_root" => pending["artifact_root"],
                 "input_digest" => pending["input_digest"] }, digest, now + 40)
  assert(record.state.dig("pending_finalization", "at") == pending["at"],
         "a repeated same-version hand-off preserves the original bounded-wait timer")

  runtime.tick(now: now + 30)
  assert(record.state["finalization_notices"].empty?,
         "the notice still prefers the completed turn before the original bound")
  runtime.tick(now: now + 61)
  assert(record.state["finalization_notices"].length == 1 && record.state["pending_finalization"].nil?,
         "the version-bound notice is delivered within the bound while Root stays active")
  assert(record.state["status"] != "complete", "the notice alone never completes the task")
end

# An explicit Root stop after a valid finalization hand-off defers completion:
# the stop is queued so the delivery turn finishes untouched, then the runtime
# stops, re-verifies the hand-off version, and records complete.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  assert(record.state["finalization_notices"].length == 1,
         "finalization hand-off recorded for the current version")
  host.working("delivering the final summary")
  record.submit("stop", "reason" => "User requested stop", "complete" => true)
  runtime.tick(now: now + 2)
  assert(!Orbit::TaskRuntime::TERMINAL.include?(record.state["status"]) && record.state["completion_stop_pending"],
         "a qualified stop is queued while the delivery turn is still running")
  host.finish("delivered")
  runtime.tick(now: now + 3)
  assert(record.state["status"] == "complete",
         "once the delivery turn completes, the queued stop records complete")
  assert(record.state["delivery_digest"] && record.state["stop_confirmation"]["confirmed"] == true,
         "completion carries the delivery version and confirmed teardown evidence")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("completed_via_finalized_stop"),
         "the completion path is auditable")
end

# The deferred completion stop is bounded: an idle observation never arrives,
# the queue still stops the task instead of waiting forever.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  assert(record.state["finalization_notices"].length == 1, "finalization hand-off is qualified")
  host.working("runaway delivery turn")
  record.submit("stop", "reason" => "User requested stop", "complete" => true)
  runtime.tick(now: now + 2)
  runtime.tick(now: now + 2 + Orbit::TaskRuntime::COMPLETION_STOP_TIMEOUT_SECONDS + 1)
  assert(record.state["status"] == "paused",
         "beyond the cap the queued stop executes as an ordinary stop, never complete")
end

# An interrupted delivery turn is never a completion: the queued stop falls
# back to the ordinary stop path.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  host.working("delivery attempt")
  record.submit("stop", "reason" => "User requested stop", "complete" => true)
  runtime.tick(now: now + 2)
  host.interrupt
  runtime.tick(now: now + 3)
  assert(record.state["status"] == "paused",
         "an interrupted delivery turn degrades the queued stop to an ordinary stop")
end

# A version change DURING the queued delivery turn also breaks the hand-off:
# the turn may finish normally, but the stop adjudicates again and must refuse
# -- never complete, never silently recorded as an ordinary pause. The task
# keeps running, the refusal is recorded, and Root is woken with the next action.
fixture do |root, record, host, checker, runtime|
  at = qualified_handoff!(record, host, checker, runtime)
  File.write(File.join(root, "LATE.md"), "artifact changed during the delivery turn")
  before = record.state["status"]
  runtime.tick(now: at)
  assert(record.state["status"] == before && !Orbit::TaskRuntime::TERMINAL.include?(before) &&
         record.state["delivery_digest"].nil? && record.state["completion_stop_pending"].nil?,
         "a version change during the queued turn keeps the task running and records no delivery")
  assert(record.state.dig("completion_rejections", 0, "reason") == "no_current_finalization_notice" &&
         events(record).any? { |event| event["type"] == "completion_stop_rejected" },
         "the refusal records why the hand-off no longer qualifies")
  assert(events(record).any? { |event| event["type"] == "completion_rejection_delivered" },
         "Root receives the refusal and can take the recorded next action")
end

# A member registered after the final check refuses the completion hand-off:
# the stop reconciles the authoritative roster before adjudicating, so a state
# roster that has not caught up can never record an unsettled member complete.
# An unreadable roster cannot qualify either.
fixture do |_root, record, host, checker, runtime|
  at = qualified_handoff!(record, host, checker, runtime)
  assert(record.state["members"].empty?, "the state roster has not seen the late member yet")
  record.register_member("orbit-m-late", requested_name: "orbit-m-late")
  runtime.tick(now: at)
  assert(!Orbit::TaskRuntime::TERMINAL.include?(record.state["status"]) &&
         record.state.dig("completion_rejections", 0, "reason") == "members_not_settled",
         "a member registered after the final check refuses the hand-off")
  File.write(File.join(record.path, "members.json"), "{ not a roster")
  runtime.send(:stop, "User requested stop", allow_complete: true)
  assert(!Orbit::TaskRuntime::TERMINAL.include?(record.state["status"]) &&
         record.state["completion_rejections"].last["reason"] == "members_unreadable",
         "an unreadable member roster refuses the hand-off instead of completing")
end

# Teardown can outlive the hand-off check (member stops wait for in-flight
# work). A version change inside that window records an ordinary stop with an
# explicit reason -- never completion, and never as if the task were running.
fixture do |root, record, host, checker, runtime|
  at = qualified_handoff!(record, host, checker, runtime)
  original_stop = host.method(:stop!)
  host.define_singleton_method(:stop!) do
    File.write(File.join(root, "DURING-TEARDOWN.md"), "artifact changed while the task stopped")
    original_stop.call
  end
  runtime.tick(now: at)
  assert(record.state["status"] == "paused" && record.state["delivery_digest"].nil? &&
         record.state["stop_confirmation"]["confirmed"] == true,
         "a hand-off invalidated during teardown records a confirmed ordinary stop, never completion")
  assert(record.state.dig("completion_invalidation", "reason") == "no_current_finalization_notice" &&
         events(record).any? { |event| event["type"] == "completion_invalidated_after_stop" } &&
         record.state["completion_stop_pending"].nil?,
         "the invalidation is durable and auditable")
end

# A member that lands in the authoritative roster while the task is being torn
# down was never stopped; the post-teardown re-read must refuse completion and
# record an unconfirmed stop, never a confirmed pause.
fixture do |_root, record, host, checker, runtime|
  at = qualified_handoff!(record, host, checker, runtime)
  original_stop = host.method(:stop!)
  host.define_singleton_method(:stop!) do
    record.register_member("orbit-m-during-stop", requested_name: "orbit-m-during-stop")
    original_stop.call
  end
  runtime.tick(now: at)
  assert(record.state["status"] == "stop_unconfirmed" &&
         record.state.dig("completion_invalidation", "reason") == "members_registered_during_stop" &&
         record.state["completion_invalidation"]["detail"].include?("orbit-m-during-stop"),
         "a member registered during teardown is never completed and is named as an unconfirmed stop")
  assert(record.state["stop_confirmation"]["confirmed"] != true &&
         record.state.dig("execution_stop_confirmation", "confirmed") == true &&
         record.state["stop_confirmation"]["unaccounted_members"] == ["orbit-m-during-stop"],
         "the overall confirmation is false while the verified Root/member part is preserved")
  assert(events(record).any? { |event| event["type"] == "stop_unconfirmed" &&
                                       event["unaccounted_members"] == ["orbit-m-during-stop"] } &&
         events(record).none? { |event| event["type"] == "stopped" },
         "the event log records the unconfirmed stop instead of a confirmed one")
end

# The post-teardown recheck must not ask the stopped Root's bridge: a transient
# failure there would turn a valid completion into a pause. Once the resources
# are stopped, only durable state can invalidate the hand-off.
fixture do |_root, record, host, checker, runtime|
  at = qualified_handoff!(record, host, checker, runtime)
  original_stop = host.method(:stop!)
  host.define_singleton_method(:stop!) do
    result = original_stop.call
    define_singleton_method(:state) { raise Orbit::Connection::Error, "bridge is gone after stop" }
    result
  end
  runtime.tick(now: at)
  assert(record.state["status"] == "complete" && record.state["completion_invalidation"].nil?,
         "an unreachable bridge after teardown cannot turn a valid completion into a pause")
end

# A plain stop without the explicit completion intent stays an immediate
# ordinary stop even when a finalization hand-off is qualified.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  assert(record.state["finalization_notices"].length == 1, "finalization hand-off is qualified")
  record.submit("stop", "reason" => "User requested stop")
  runtime.tick(now: now + 2)
  assert(record.state["status"] == "paused" && record.state["completion_stop_pending"].nil?,
         "a plain CLI stop never takes the completion path")
end

# An explicit hard deadline preempts a queued completion wait: it stops
# immediately as an ordinary stop instead of waiting out the delivery turn.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  state = record.state
  state["hard_deadline"] = Time.at(now + 5).utc.iso8601
  record.save(state)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  host.working("slow delivery turn")
  record.submit("stop", "reason" => "User requested stop", "complete" => true)
  runtime.tick(now: now + 2)
  assert(record.state["completion_stop_pending"], "completion stop is queued")
  runtime.tick(now: now + 6)
  assert(record.state["status"] == "paused",
         "a reached hard deadline stops immediately and never records completion")
end

# The bridge-level interrupted flag also degrades a queued completion stop to
# an ordinary stop, even without an idle/interrupted turn summary.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  host.working("delivery in progress")
  record.submit("stop", "reason" => "User requested stop", "complete" => true)
  runtime.tick(now: now + 2)
  host.instance_variable_get(:@state)["interrupted"] = true
  runtime.tick(now: now + 3)
  assert(record.state["status"] == "paused",
         "a bridge-level interrupt degrades the queued stop to an ordinary stop")
end

# A version change after the finalization notice keeps ordinary stop semantics:
# the hand-off no longer describes the current artifact, so stop stays paused.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  File.write(File.join(root, "NEW.md"), "version changed after the notice")
  record.submit("stop", "reason" => "User requested stop")
  runtime.tick(now: now + 2)
  assert(record.state["status"] == "paused", "a version change after the notice keeps stop at paused")
end

# An interrupt is never a completion: even with a qualified finalization
# hand-off, the internal stop-request path records paused.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue")
  runtime.tick(now: now + 1)
  assert(record.state["finalization_notices"].length == 1, "finalization hand-off is qualified")
  runtime.request_stop
  runtime.tick(now: now + 2)
  assert(record.state["status"] == "paused", "an interrupt after the notice stays paused, never complete")
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

# Interrupting Root through its native UI must also stop its native members.
fixture do |_root, record, host, checker, runtime|
  state = runtime.instance_variable_get(:@state)
  state["members"] = [{ "adapter" => "omp_native_task", "thread_id" => "orbit-m1", "kind" => "omp", "status" => "registered" }]
  record.save(state)
  host.interrupt
  runtime.tick
  assert(record.state["status"] == "paused", "native Root interruption pauses the whole task")
  assert(host.member_stops == ["orbit-m1"], "member is stopped without relying on Root")
end

# A failed Root stop cannot prevent attempts to stop the remaining members.
fixture do |_root, record, host, checker, runtime|
  state = runtime.instance_variable_get(:@state)
  state["members"] = [{ "adapter" => "omp_native_task", "thread_id" => "orbit-m1", "kind" => "omp", "status" => "registered" }]
  record.save(state)
  host.confirmed = false
  record.submit("stop")
  runtime.tick
  assert(record.state["status"] == "stop_unconfirmed", "partial cleanup cannot claim whole-task stop")
  assert(host.member_stops == ["orbit-m1"], "remaining members are still stopped")
end

fixture do |_root, record, host, checker, runtime|
  state = runtime.instance_variable_get(:@state)
  state["members"] = [{ "adapter" => "same_host", "thread_id" => "old-member", "kind" => "opencode", "status" => "working" }]
  record.save(state)
  runtime.tick
  assert(record.state["status"] == "stop_unconfirmed", "a legacy member is not treated as stopped")
  assert(record.state["error"].to_s.include?("no migration path"), record.state["error"].to_s)
  assert(record.state["members"].first["status"] == "working", "the old record is not relabeled completed")
  assert(Array(host.member_stops).empty?, "the removed host path is not called")
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
  host = RuntimeHost.new(root)
  host.confirmed = false
  state["members"] = [{ "adapter" => "omp_native_task", "thread_id" => "orbit-m1", "kind" => "omp", "status" => "registered" }]
  record.save(state)
  def checker.start(**args) = raise("checker could not start")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  runtime.run
  assert(record.state["status"] == "stop_unconfirmed", "observer failure records unconfirmed cleanup")
  assert(host.member_stops == ["orbit-m1"], "observer failure still stops the member")
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

# Jev can defer an early first-change review; an unchanged timer while Root
# executes does not pay for a full check, but a completed turn still does.
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
  assert(checker.calls.empty?, "pure elapsed time does not launch a full check while Root is active")
  host.finish("completed-artifact")
  runtime.tick(now: now + 62)
  assert(checker.calls.length == 1 && checker.calls.last.fetch(:role) == "reviewer",
         "completed Root work triggers the deferred artifact check")
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
fixture(interval: 300) do |_root, _record, host, checker, _runtime|
  host.send_message("Working")
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1)
  advisor.on_call = -> { host.finish("during-#{advisor.calls.length}"); host.send_message("New work during assessment") }
  runtime = Orbit::TaskRuntime.new(record: _record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now + 10)
  runtime.tick(now: now + 11)
  runtime.tick(now: now + 69)
  assert(advisor.calls.length == 1, "changed observations cannot request Jev again each tick")
  assert(checker.calls.empty?, "a stale Jev decision does not start a checker")
  runtime.tick(now: now + 70)
  assert(advisor.calls.length == 2, "changed observations may be reassessed after the scheduled cooldown")
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
  receipt = Orbit::JudgmentResult.unavailable(
    provider: "typesafe", reason: "service unavailable", actual_model: "jev-failure-fixture",
    usage: { "input_tokens" => 11, "output_tokens" => 2 }
  ).to_h.merge("question_set_version" => Orbit::ModelQualityPolicy::QUESTION_SET_VERSIONS.fetch("observation"))
  advisor.failure = Orbit::JevAdvisor::Error.new("service unavailable", receipt: receipt)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now + 1)
  File.write(File.join(root, "artifact.txt"), "changed despite service failure")
  runtime.tick(now: now + 10)
  assert(checker.calls.last.fetch(:role) == "reviewer", "failed Jev call falls back to full review")
  assert(record.state.dig("jev", "unavailable") == "service unavailable", "failure is recorded")
  assert(Orbit::TaskView.format(record).include?("JEV：不可用（service unavailable）"), "status shows JEV unavailable with its reason")
  assert(record.state.dig("jev", "model") == "jev-failure-fixture" &&
         record.state.dig("usage", "jev_stage1", "input_tokens") == 11,
         "first-stage failure retains its actual model and reported consumption")
end

Dir.mktmpdir("orbit-jev-config-") do |root|
  env = { "TYPESAFE_API_KEY" => "test-key" }
  assert(Orbit::JevAdvisor.for_project(root, env: env), "one global enable covers a project")
  assert(Orbit::JevAdvisor.for_project(root, env: {}).nil?, "no key keeps the existing scheduling path")
  Dir.mkdir(File.join(root, ".orbit"))
  File.write(File.join(root, ".orbit", "jev-disabled"), "")
  assert(Orbit::JevAdvisor.for_project(root, env: env).nil?,
         "a project can disable external Jev calls")
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

# Amendment and dispute text stay evidence. Only rebind_workspace changes
# the artifact directory, and a different non-Git path is rejected.
fixture do |root, record, host, checker, runtime|
  other = File.join(root, "notes")
  FileUtils.mkdir_p(other)
  record.submit("amend", "text" => "Continue in #{other}", "source" => { "kind" => "explicit_text" })
  record.submit("dispute", "reason" => "The files are in #{other}")
  runtime.tick
  assert(record.state.dig("workspace", "artifact_root") == File.realpath(root), "text cannot switch the artifact root")
  assert(record.state.dig("workspace", "history").empty?, "text does not record a rebind")

  record.submit("rebind_workspace", "path" => other, "reason" => "move",
                "source" => { "kind" => "cli", "command" => "rebind-workspace" })
  runtime.tick
  assert(record.state.dig("workspace", "artifact_root") == File.realpath(root), "a different non-Git path stays rejected")
  assert(host.messages.any? { |message| message.include?("rebind was rejected") }, "Root hears the rejection")
  events = File.read(File.join(record.path, "events.jsonl"))
  assert(events.include?("workspace_rebind_rejected") && !events.include?("workspace_rebound"),
         "rejection is an event and does not pretend the workspace moved")
end

# An in-flight check of the old worktree is stale because the workspace
# changed, even when both trees have the same bytes. The next check reads
# the new artifact root, and a new member is created there.
Dir.mktmpdir("orbit-rebind-runtime-") do |tmp|
  root = File.join(tmp, "main")
  other = File.join(tmp, "linked")
  FileUtils.mkdir_p(root)
  git = lambda do |dir, *args|
    ok = system("git", "-C", dir, "-c", "user.name=orbit-test", "-c", "user.email=orbit-test@example.com",
                "-c", "commit.gpgsign=false", *args, out: File::NULL, err: File::NULL)
    raise "git #{args.join(' ')} failed in #{dir}" unless ok
  end
  git.call(root, "init", "-q")
  File.write(File.join(root, "artifact.txt"), "same bytes")
  git.call(root, "add", "-A")
  git.call(root, "commit", "-q", "-m", "init")
  git.call(root, "worktree", "add", "--detach", "-q", other, "HEAD")
  assert(Orbit::WorkspaceSnapshot.fingerprint(project_root: root) ==
         Orbit::WorkspaceSnapshot.fingerprint(project_root: other), "the two worktrees start with the same digest")

  record = Orbit::TaskRecord.create(
    project_root: root, instruction: "Keep the behavior and move the workspace.\n",
    source: { "id" => "original", "kind" => "native_user_message" },
    connection: { "provider" => "opencode" }, review: { "interval_seconds" => 300 }, estimate: {}
  )
  host = RuntimeTeamHost.new(root)
  checker = RuntimeChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  now = Time.now.to_f
  runtime.tick(now: now)
  assert(checker.calls.length == 1, "the first check reads the original workspace")
  record.submit("rebind_workspace", "path" => other, "reason" => "switch worktree",
                "source" => { "kind" => "cli", "command" => "rebind-workspace" })
  runtime.tick(now: now + 1)
  assert(checker.calls.length == 1, "rebind does not start a second check while one is in flight")
  assert(record.state.dig("workspace", "artifact_root") == File.realpath(other), "rebind switches the artifact root")
  assert(record.state.fetch("project_root") == File.realpath(root), "rebind keeps the project root")
  history = record.state.dig("workspace", "history")
  assert(history.length == 1 && history[0]["reason"] == "switch worktree" &&
         history[0].dig("source", "command") == "rebind-workspace" &&
         history[0]["from"] == File.realpath(root) && history[0]["to"] == File.realpath(other),
         "rebind records source, reason and history")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("workspace_rebound"), "rebind writes an event")
  notice = host.messages.find { |message| message.include?("artifact root moved to") }
  assert(notice && notice.include?(File.realpath(other)) && notice.include?("has not moved") &&
         notice.include?("not a new user instruction") && notice.include?("under the new root"),
         "Root is told the normalized new root, that the session cwd did not move, and where artifacts go")

  checker.result = answer("complete")
  runtime.tick(now: now + 2)
  last = record.state.fetch("checks").last
  assert(last["stale"] && last["stale_reasons"] == ["workspace"],
         "the same digest is still stale because the workspace changed")
  assert(host.messages.length == 1 && host.messages.first.include?("artifact root moved to") &&
         record.state["status"] != "complete",
         "the stale old-worktree pass sends no correction or finalization (only the rebind notice) and cannot complete the task")
  assert(record.state["next_check_basis"] == "工作区重新绑定", "rebind schedules a check of the new workspace")

  checker.result = nil
  runtime.tick(now: now + 3)
  scope = JSON.parse(File.read(File.join(record.path, "checks", "2", "scope.json")))
  assert(checker.calls.length == 2 && scope["artifact_root"] == File.realpath(other) &&
         scope.dig("snapshot", "source_root") == File.realpath(other),
         "the check after rebind reads the new artifact root")
  text = Orbit::TaskView.format(record)
  assert(text.include?("产物目录：#{File.realpath(other)}") && text.include?("switch worktree") &&
         text.include?("工作区切换"), "status shows the artifact root, latest rebind and workspace expiry")

end

# JEV's change summary follows the artifact workspace, not the project root.
Dir.mktmpdir("orbit-jev-artifact-") do |tmp|
  root = File.join(tmp, "main")
  other = File.join(tmp, "linked")
  FileUtils.mkdir_p(root)
  git = lambda do |dir, *args|
    ok = system("git", "-C", dir, "-c", "user.name=orbit-test", "-c", "user.email=orbit-test@example.com",
                "-c", "commit.gpgsign=false", *args, out: File::NULL, err: File::NULL)
    raise "git #{args.join(' ')} failed in #{dir}" unless ok
  end
  git.call(root, "init", "-q")
  File.write(File.join(root, "artifact.txt"), "same bytes")
  git.call(root, "add", "-A")
  git.call(root, "commit", "-q", "-m", "init")
  git.call(root, "worktree", "add", "--detach", "-q", other, "HEAD")
  File.write(File.join(other, "only-worktree.txt"), "from the linked worktree")
  record = Orbit::TaskRecord.create(
    project_root: root, instruction: "Inspect the linked worktree.\n",
    source: { "id" => "original", "kind" => "native_user_message" },
    connection: { "provider" => "opencode" }, review: { "interval_seconds" => 300 }, estimate: {}
  )
  state = record.state
  state["workspace"] = Orbit::WorkspaceBinding.rebind(state.fetch("workspace"), artifact_root: other)
  record.save(state)
  host = RuntimeHost.new(root)
  host.working("editing the linked worktree")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.1)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: RuntimeChecker.new, advisor: advisor)
  runtime.tick(now: Time.now.to_f + 10)
  changes = advisor.calls.fetch(0).fetch("changes").fetch("status").to_s
  assert(changes.include?("only-worktree.txt"), "JEV changes are read from artifact_root")
  assert(!File.exist?(File.join(root, "only-worktree.txt")), "the project root does not contain the artifact file")
end

# One observation, two automatic triggers: the delivered turn starts one
# check, and the later timer for the same observation is skipped instead of
# paying for a second model call.
fixture(interval: 300) do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  started = record.state.fetch("check_observations").values.last
  assert(started && started["status"] == "in_flight" && started["trigger_cause"] == "delivery",
         "the first check names its delivery cause")
  checker.result = answer("continue")
  runtime.tick(now: now + 1)

  host.finish("second")
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 2, "the delivered turn starts exactly one check")
  assert(record.state.fetch("check_observations").values.last["trigger_cause"] == "delivery",
         "the interleaved delivery keeps its cause")
  checker.result = answer("continue")
  runtime.tick(now: now + 3)

  runtime.tick(now: now + 64)
  assert(checker.calls.length == 2, "the same observation is not checked twice")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("check_duplicate_skipped"),
         "the duplicate skip is visible in the event record")
  finished = record.state.dig("check_observations", record.state.fetch("checks").last["observation_key"])
  assert(finished && finished["status"] == "finished" && finished["stale"] == false &&
         finished["check"] == 2, "the observation key is recorded as finished with its check number")
  assert(record.state["next_check_trigger"] == "timer" && record.state["next_check_manual"] == false,
         "a skipped duplicate falls back to the normal timer")
end

# A stale result no longer summons an immediate second check: while Root is
# idle it waits for the normal timer, and its findings stay as reconciliation
# clues instead of forcing another model call.
fixture(interval: 300) do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  File.write(File.join(root, "artifact.txt"), "changed while checking")
  clue = { "id" => "clue", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement" }
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 1)
  assert(record.state.fetch("checks").last["stale_reasons"] == ["artifact"], "precondition: artifact expiry")
  assert(record.state.dig("recheck", "findings", 0, "id") == "clue", "the stale finding stays as a clue")
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 1, "a stale idle result does not immediately call the checker again")
  assert(record.state["next_check_trigger"] == "checker_interval" && record.state["next_check_manual"] == false,
         "the next check waits for the checker interval, not an immediate retry")
  assert(host.messages.empty?, "a stale clue is not delivered as if it applied to the old version")
end

# The same holds with a pending dispute: a stale adjudication does not
# release an immediate second adjudication; the dispute stays pending for the
# normal timer.
fixture(interval: 300) do |root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("dispute", "reason" => "The layout preference is not a user requirement")
  runtime.tick(now: now)
  started = record.state.fetch("check_observations").values.last
  assert(checker.calls.length == 1 && checker.calls.last.fetch(:role) == "adjudicator" &&
         started["trigger_cause"] == "manual_dispute",
         "precondition: the user dispute starts one adjudication")
  File.write(File.join(root, "artifact.txt"), "changed while checking")
  clue = { "id" => "clue", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement" }
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 1)
  assert(record.state.fetch("checks").last["stale_reasons"] == ["artifact"],
         "precondition: the version changed under the adjudication and the dispute stays open")
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 1, "a stale result with a pending dispute does not immediately call again")
  assert(record.state["dispute"], "the dispute stays pending for the next applicable check")
  assert(record.state["next_check_trigger"] == "checker_interval", "the next check waits for the normal timer")
  runtime.tick(now: now + 61)
  assert(checker.calls.length == 2 && checker.calls.last.fetch(:role) == "adjudicator",
         "the normal timer reaches the pending dispute without a stale-triggered loop")
  assert(events(record).none? { |event| event["type"] == "correction_sent" },
         "the stale finding of an adjudication is not delivered")
end

# A check that finished against a rebound-away workspace is binding-invalid:
# its findings never migrate as clues, and exactly one check starts on the
# new root for the rebind.
Dir.mktmpdir("orbit-rebind-dedup-") do |tmp|
  root = File.join(tmp, "main")
  other = File.join(tmp, "linked")
  FileUtils.mkdir_p(root)
  git = lambda do |dir, *args|
    ok = system("git", "-C", dir, "-c", "user.name=orbit-test", "-c", "user.email=orbit-test@example.com",
                "-c", "commit.gpgsign=false", *args, out: File::NULL, err: File::NULL)
    raise "git #{args.join(' ')} failed in #{dir}" unless ok
  end
  git.call(root, "init", "-q")
  File.write(File.join(root, "artifact.txt"), "same bytes")
  git.call(root, "add", "-A")
  git.call(root, "commit", "-q", "-m", "init")
  git.call(root, "worktree", "add", "--detach", "-q", other, "HEAD")

  record = Orbit::TaskRecord.create(
    project_root: root, instruction: "Keep the behavior and move the workspace.\n",
    source: { "id" => "original", "kind" => "native_user_message" },
    connection: { "provider" => "opencode" }, review: { "interval_seconds" => 300 }, estimate: {}
  )
  host = RuntimeHost.new(root)
  checker = RuntimeChecker.new
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  now = Time.now.to_f
  runtime.tick(now: now)

  record.submit("rebind_workspace", "path" => other, "reason" => "switch worktree",
                "source" => { "kind" => "cli", "command" => "rebind-workspace" })
  runtime.tick(now: now + 1)
  clue = { "id" => "old-root", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement" }
  checker.result = answer("correct", findings: [clue])
  runtime.tick(now: now + 2)
  last = record.state.fetch("checks").last
  assert(last["stale_reasons"] == ["workspace"], "the old-root result is workspace-stale")
  stale_record = record.state.fetch("check_observations").values.first
  assert(stale_record["status"] == "finished" && stale_record["stale"] == true && stale_record["check"] == 1,
         "the workspace-stale observation key is marked finished with its stale flag and check number")
  assert(record.state["recheck"].nil?, "findings from the wrong workspace never migrate as clues")
  assert(record.state["next_check_trigger"] == "rebind" && record.state["next_check_manual"] == false &&
         record.state["next_check_basis"] == "工作区重新绑定", "the workspace stale schedules one check of the new root")

  checker.result = nil
  runtime.tick(now: now + 3)
  scope = JSON.parse(File.read(File.join(record.path, "checks", "2", "scope.json")))
  assert(checker.calls.length == 2 && scope["artifact_root"] == File.realpath(other) &&
         scope["trigger_cause"] == "rebind" && scope["manual"] == false,
         "exactly one check reads the new root, caused by the rebind")
  runtime.tick(now: now + 4)
  assert(checker.calls.length == 2 && record.state.fetch("checks").length == 1,
         "the new-root check is in flight and no duplicate is started")
end

# A user-requested check bypasses the completed-observation dedup and re-runs
# the same observation; queued manual checks still run one at a time.
fixture(interval: 300) do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.result = answer("continue", delivery_ready: false)
  runtime.tick(now: now + 1)
  assert(record.state.fetch("checks").length == 1, "precondition: the observation was checked once")

  record.submit("check")
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 2, "an explicit user check re-runs the same observation")
  manual = record.state.fetch("check_observations").values.last
  assert(manual["manual"] == true && manual["trigger_cause"] == "manual_check",
         "the manual re-run keeps its structured cause")

  record.submit("check")
  runtime.tick(now: now + 3)
  assert(checker.calls.length == 2 && record.state["next_check_basis"] == "用户请求的检查",
         "a queued manual check waits while one check is in flight")
  checker.result = answer("continue")
  runtime.tick(now: now + 4)
  host.finish("delivered after the preceding check")
  runtime.tick(now: now + 5)
  assert(checker.calls.length == 3, "the queued manual request runs after the first check finishes")
  queued = record.state.fetch("check_observations").values.last
  assert(queued["manual"] == true && queued["trigger_cause"] == "manual_check",
         "the queued request keeps its manual cause instead of becoming an automatic repeat")
end

# An already-open finding is not delivered again merely because Root produced
# another host turn. Without changed input, root, artifact or finding text it
# is the same unresolved problem, not a fresh correction.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  finding = { "id" => "f-open", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement it" }
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 1)
  assert(events(record).count { |event| event["type"] == "correction_sent" } == 1 &&
         record.state.dig("findings", "f-open", "status") == "open",
         "precondition: the first current finding reaches Root as one correction")

  host.finish("t1")
  runtime.tick(now: now + 2)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 3)
  assert(events(record).count { |event| event["type"] == "correction_sent" } == 1,
         "the same still-open finding is not corrected twice")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("finding_repeat_ignored") },
         "the suppressed repeat remains auditable")
end

# A resolved finding is not reopened by the same evidence on the same
# versions: inputs, artifact root, artifact bytes and the finding's own text
# all unchanged means the re-raise is the same decision and is ignored.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  finding = { "id" => "f-1", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement it" }
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 1)
  assert(record.state.dig("findings", "f-1", "status") == "open", "precondition: the finding is open")

  host.finish("t1")
  runtime.tick(now: now + 2)
  checker.result = answer("continue", resolved: ["f-1"])
  runtime.tick(now: now + 3)
  resolved = record.state.dig("findings", "f-1")
  assert(resolved["status"] == "resolved" && resolved["resolution_role"] == "reviewer" &&
         resolved["resolution_check"] == 2 && resolved["resolution"] == "Concrete fixture evidence" &&
         resolved["resolution_root"] == File.realpath(root) && resolved["resolution_version"].is_a?(String) &&
         resolved["resolution_input"].is_a?(String),
         "a resolved finding keeps role, check, reason, root, artifact version and input version")
  messages_before_recheck = host.messages.length

  host.finish("t2")
  runtime.tick(now: now + 4)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 5)
  assert(record.state.dig("findings", "f-1", "status") == "resolved",
         "the same finding text on the same versions is not reopened")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("finding_reopen_ignored") },
         "the ignored re-raise is recorded")
  assert(host.messages.length == messages_before_recheck, "an ignored re-raise does not re-notify Root")
end

# Any real evidence dimension reopens a resolved finding: changed artifact
# bytes, changed task inputs, or changed finding text each allow a fresh open.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  finding = { "id" => "f-1", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement it" }
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 1)
  assert(record.state.dig("findings", "f-1", "status") == "open", "precondition: the finding is open")
  host.finish("t1")
  runtime.tick(now: now + 2)
  checker.result = answer("continue", resolved: ["f-1"])
  runtime.tick(now: now + 3)
  assert(record.state.dig("findings", "f-1", "status") == "resolved", "precondition: resolved on the original bytes")

  File.write(File.join(root, "artifact.txt"), "first behavior, extended")
  host.finish("t2")
  runtime.tick(now: now + 4)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 5)
  assert(record.state.dig("findings", "f-1", "status") == "open" &&
         record.state.dig("findings", "f-1", "check") == 3,
         "changed artifact bytes reopen the finding")

  host.finish("t3")
  runtime.tick(now: now + 6)
  checker.result = answer("continue", resolved: ["f-1"])
  runtime.tick(now: now + 7)
  record.submit("amend", "text" => "Also cover the edge case.", "source" => { "kind" => "native_user_message", "id" => "amend-1" })
  host.finish("t4")
  runtime.tick(now: now + 8)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 9)
  assert(record.state.dig("findings", "f-1", "status") == "open" &&
         record.state.dig("findings", "f-1", "check") == 5,
         "changed task inputs reopen the finding")

  host.finish("t5")
  runtime.tick(now: now + 10)
  checker.result = answer("continue", resolved: ["f-1"])
  runtime.tick(now: now + 11)
  host.finish("t6")
  runtime.tick(now: now + 12)
  changed = finding.merge("evidence" => "still absent after the rework")
  checker.result = answer("correct", findings: [changed])
  runtime.tick(now: now + 13)
  reopened = record.state.dig("findings", "f-1")
  assert(reopened["status"] == "open" && reopened["evidence"] == "still absent after the rework" &&
         reopened["check"] == 7,
         "changed finding text reopens the finding")
end

# An adjudication decision binds the exact versions it judged: inputs, root,
# artifact bytes, resolved and reported finding ids, reason and time, while
# the full checker result stays available to existing consumers.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  finding = { "id" => "f-1", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement it" }
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 1)
  record.submit("dispute", "reason" => "The requirement is not a user requirement")
  host.finish("t1")
  runtime.tick(now: now + 2)
  checker.result = answer("complete", resolved: ["f-1"])
  runtime.tick(now: now + 3)
  decision = record.state.fetch("decisions").last
  scope = JSON.parse(File.read(File.join(record.path, "checks", "2", "scope.json")))
  assert(decision["input_digest"] == scope["input_digest"] &&
         decision["artifact_root"] == File.realpath(root) &&
         decision["artifact_digest"] == scope.dig("snapshot", "digest") &&
         decision["resolved_ids"] == ["f-1"] && decision["finding_ids"] == [] &&
         decision["reason"] == "Concrete fixture evidence" && decision["decided_at"].is_a?(String) &&
         decision.dig("result", "verdict") == "complete" &&
         decision["dispute"] == "The requirement is not a user requirement",
         "the decision records versions, finding ids, reason, time and keeps the result")
end

# A queued manual trigger survives a runtime restart: initialize defaults the
# schedule fields only when absent, so a queued manual/rebind check is not
# demoted to an automatic timer by the new process.
fixture(interval: 300) do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  record.submit("check")
  runtime.tick(now: now + 1)
  assert(record.state["next_check_manual"] == true && record.state["next_check_trigger"] == "manual_check",
         "precondition: a manual check is queued behind the in-flight check")

  Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  assert(record.state["next_check_manual"] == true && record.state["next_check_trigger"] == "manual_check",
         "the queued manual trigger survives a runtime restart")
end

# A crashed runtime may leave a persisted in-flight observation without an
# owned checker process. A replacement runtime marks that record abandoned and
# retries once; otherwise observation dedup would suppress the check forever.
fixture(interval: 300) do |_root, record, host, _checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  first = record.state.fetch("check_observations").values.first
  assert(first["status"] == "in_flight", "precondition: the old runtime persisted an active check")

  replacement_checker = RuntimeChecker.new
  replacement = Orbit::TaskRuntime.new(record: record, connection: host, checker: replacement_checker)
  replacement.tick(now: now + 1)
  observations = record.state.fetch("check_observations")
  assert(replacement_checker.calls.length == 1 && observations.values.any? { |entry| entry["status"] == "in_flight" },
         "the replacement runtime starts one check for the abandoned observation")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("check_abandoned_recovered") },
         "the recovery is visible in the event record")
end

# Legacy cross-identity claims remain archived but do not become current
# capability facts merely because their identity and expiry match.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.6)
  cache = evidence_cache(root)
  # Both route identities must be present: the Root stays route-less (unknown)
  # while the candidate's route is explicit. The legacy comparison.* metric
  # stays on both entries to exercise summary filtering without relaxing the
  # route gate.
  legacy_root = evidence_entry(billing_route: "unknown")
  legacy_candidate = evidence_entry(billing_route: "direct_api")
  [legacy_root, legacy_candidate].each do |entry|
    entry["valid_until"] = (Time.now.utc + 3600).iso8601
    entry["metrics"]["comparison.identity_offset"] = { "value" => 0, "unit" => "n/a", "basis" => "same model" }
  end
  File.write(cache.path, JSON.pretty_generate("schema_version" => Orbit::ModelEvidenceCache::SCHEMA_VERSION,
                                              "entries" => [legacy_root, legacy_candidate]))
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache)
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.delegation_calls.empty?, "invalid historical comparison claims do not reach a current model judgment")
  assert(JSON.generate(cache.stored_entries).include?("comparison.identity_offset"),
         "read-time qualification preserves the historical cache rather than rewriting its evidence")
end

# Two effective current checks reporting the same still-open finding
# escalate once with an action prompt; the repeat correction stays
# suppressed, and changed evidence resets the cycle so a later repeat may
# escalate again (proposal item 2).
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  finding = { "id" => "f-stuck", "requirement" => "second behavior", "evidence" => "absent", "action" => "implement it" }
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 1)
  assert(host.messages.length == 1 && record.state.dig("findings", "f-stuck", "current_reports") == 1,
         "precondition: the first effective report opens the finding and delivers the correction")

  host.finish("t2")
  runtime.tick(now: now + 2)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 3)
  entry = record.state.dig("findings", "f-stuck")
  assert(host.messages.length == 2 && host.messages.last.include?("f-stuck") && host.messages.last.include?("dispute"),
         "the second effective report escalates once with the finding id and the dispute path")
  assert(entry["current_reports"] == 2 && entry["escalated_at"] && entry["escalated_check"] == 2,
         "the escalation is durable on the finding record")
  assert(events(record).count { |event| event["type"] == "finding_repeat_escalated" } == 1,
         "the escalation is auditable exactly once")
  assert(Orbit::TaskView.format(record).include?("开放问题升级：f-stuck"),
         "the readable status names the escalated finding with its next actions")

  host.finish("t3")
  runtime.tick(now: now + 4)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 5)
  assert(host.messages.length == 2 && record.state.dig("findings", "f-stuck", "current_reports") == 3,
         "a third same-evidence report counts but never re-prompts")

  changed = finding.merge("evidence" => "still absent after the rewrite")
  host.finish("t4")
  runtime.tick(now: now + 6)
  checker.result = answer("correct", findings: [changed])
  runtime.tick(now: now + 7)
  entry = record.state.dig("findings", "f-stuck")
  assert(entry["current_reports"] == 1 && entry["escalated_at"].nil? && host.messages.length == 3,
         "changed evidence resets the cycle and re-delivers the correction")

  host.finish("t5")
  runtime.tick(now: now + 8)
  checker.result = answer("correct", findings: [changed])
  runtime.tick(now: now + 9)
  assert(host.messages.length == 4 && record.state.dig("findings", "f-stuck", "current_reports") == 2 &&
         record.state.dig("findings", "f-stuck", "escalated_at"),
         "after the substantive change a new repeat may escalate again")
end

# A stop that cannot confirm records structured per-phase diagnostics, and
# the explicit retry re-reads session and roster state first: an
# already-confirmed member is not stopped again, the Root stop is still
# attempted per the existing authorization, and a confirmed retry leaves no
# stale failure diagnostics behind (proposal item 3).
fixture do |_root, record, host, _checker, _runtime|
  state = record.state
  state["connection"]["thread_id"] = "existing-root"
  state["members"] = [{ "adapter" => "omp_native_task", "thread_id" => "orbit-m1", "kind" => "omp", "status" => "registered" }]
  record.save(state)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil)
  host.confirmed = false
  runtime.request_stop
  runtime.tick
  state = record.state
  assert(state["status"] == "stop_unconfirmed", "precondition: the stop stays unconfirmed")
  diagnostics = state["stop_diagnostics"]
  assert(diagnostics.is_a?(Hash) && diagnostics["confirmed"] == false &&
         diagnostics.dig("root", "ok") == false &&
         diagnostics["members"].any? { |entry| entry["thread_id"] == "orbit-m1" && entry["ok"] == true } &&
         state.dig("stop_confirmation", "confirmed") == false,
         "the failed stop persists structured diagnostics without a false confirmation")
  formatted = Orbit::TaskView.format(record)
  assert(formatted.include?("停止诊断") && formatted.include?("Root 未确认停止") &&
         formatted.include?("用 orbit stop <任务> 显式重试停止收尾"),
         "the readable status shows the failed phase and the explicit retry path")

  host.confirmed = true
  result = Orbit::TaskRuntime.new(record: record, connection: host, checker: nil).retry_stop("User retried stop")
  assert(result["status"] == "paused", "the retry confirms after the host recovers: #{result['error']}")
  probe = result["stop_retry_probe"]
  assert(probe.dig("root", "reachable") == true && probe["members"].first["already_confirmed"] == true,
         "the retry first re-reads the live session and roster state")
  assert(host.member_stops == ["orbit-m1"] && host.stop_calls == 2,
         "an already-confirmed member is not stopped again while Root is still confirmed per authorization")
  assert(result["stop_diagnostics"].nil?, "a confirmed retry leaves no stale failure diagnostics")
  assert(!Orbit::TaskView.format(record).include?("停止诊断"), "the readable status drops the resolved diagnostics")
end

# Native ask calls the host skipped are recorded from the plugin buffer,
# reminded once at a safe idle turn, cleared by a later successful ask from
# the same agent, and closed with the task otherwise (proposal item 1).
fixture do |root, record, _host, checker, _runtime|
  host = RuntimeAskHost.new(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  now = Time.now.to_f
  host.ask_events = { "events" => [{ "id" => "ask-1", "seq" => 1, "kind" => "ask_interrupted",
                                     "tool_call_id" => "call-abc", "agent_id" => "orbit-member-1",
                                     "session_id" => "s1", "question" => "Which database?",
                                     "skipped_source" => "system", "started" => false,
                                     "at" => "2026-09-26T06:00:00Z" }],
                      "dropped_oldest" => 0, "next_seq" => 2, "buffer_cap" => 500 }
  runtime.tick(now: now)
  entry = record.state.dig("ask_interrupts", "call-abc")
  assert(entry && entry["question"] == "Which database?" && entry["skipped_source"] == "system",
         "the skipped ask is recorded durably from the plugin buffer")
  assert(entry["reminded_at"] && host.messages.length == 1 && host.messages.last.include?("call-abc") &&
         host.messages.last.include?("does not answer for the user"),
         "one safe-turn reminder names the call and refuses to answer or resend")
  assert(Orbit::TaskView.format(record).include?("待补问：1 条") &&
         Orbit::TaskView.format(record).include?("已提醒补问"),
         "the readable status shows the pending interrupted ask")
  runtime.tick(now: now + 1)
  assert(host.messages.length == 1, "the reminder is never repeated")

  host.ask_events = { "events" => [{ "id" => "ask-2", "seq" => 2, "kind" => "ask_resolved",
                                     "tool_call_id" => "call-def", "agent_id" => "orbit-member-1",
                                     "at" => "2026-09-26T06:05:00Z" }],
                      "dropped_oldest" => 0, "next_seq" => 3, "buffer_cap" => 500 }
  runtime.tick(now: now + 4)
  entry = record.state.dig("ask_interrupts", "call-abc")
  assert(entry["cleared_at"] && entry["cleared_by"] == "ask_succeeded" &&
         !Orbit::TaskView.format(record).include?("待补问"),
         "a later successful ask from the same agent clears the pending interrupt")

  host.ask_events = { "events" => [{ "id" => "ask-3", "seq" => 3, "kind" => "ask_interrupted",
                                     "tool_call_id" => "call-ghi", "agent_id" => "orbit-member-1",
                                     "question" => "Which cache?", "skipped_source" => "user",
                                     "started" => true, "at" => "2026-09-26T06:10:00Z" }],
                      "dropped_oldest" => 0, "next_seq" => 4, "buffer_cap" => 500 }
  runtime.tick(now: now + 5)
  runtime.tick(now: now + 6)
  runtime.request_stop
  runtime.tick(now: now + 7)
  entry = record.state.dig("ask_interrupts", "call-ghi")
  assert(record.state["status"] == "paused" && entry["cleared_by"] == "task_terminal" && entry["cleared_at"],
         "a task terminal state closes the still-pending ask interrupt")
end

# An unrelated native user turn remains outside the checked instruction until
# the user explicitly assigns it to this task.
fixture do |_root, record, host, checker, runtime|
  original_digest = record.input_digest(record.state)
  host.define_singleton_method(:user_messages) do |after_id:|
    after_id == "original" ? [{ "id" => "new-question", "text" => "How does another project work?" }] : []
  end
  runtime.tick
  assert(record.state["amendments"].empty? &&
         record.input_digest(record.state) == original_digest &&
         record.state["unassigned_user_message_id"] == "new-question",
         "an unassigned native question cannot silently expand this task")
  host.finish("after-question")
  record.submit("amend", "text" => "Include the second behavior",
                "source" => { "kind" => "explicit_text" })
  runtime.tick
  assert(record.state["amendments"].length == 1 &&
         record.input_digest(record.state) != original_digest &&
         record.state["unassigned_user_message_id"].nil?,
         "only explicit amend changes the checked requirements")
end

# A clean continue verdict does not imply that a promised answer was delivered.
# Root must actually finish the response before a later independent check can
# issue a completion notice.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue", delivery_ready: false,
                          delivery_reason: "Root has not delivered the final answer")
  runtime.tick(now: now + 1)
  assert(record.state["finalization_notices"].empty? &&
         record.state.dig("completion_readiness", "status") == "not_ready" &&
         host.messages.any? { |message| message.include?("Root has not delivered") },
         "a no-finding check without a delivered answer keeps Root working")
  host.finish("actual final answer")
  record.submit("check")
  runtime.tick(now: now + 2)
  checker.result = answer("continue", delivery_ready: true,
                          delivery_reason: "Observed the Root's completed final answer")
  runtime.tick(now: now + 3)
  assert(record.state["finalization_notices"].length == 1 &&
         record.state.dig("completion_readiness", "status") == "ready",
         "an independent current check after delivery may issue the notice")
end

# A delivery-ready, finding-free report cannot silently cover an unverified
# requirement. A later full report qualifies; corrupting its durable coverage
# then makes the completion gate refuse without manufacturing a pass.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  incomplete = answer("continue")
  incomplete["coverage"]["items"] << { "requirement" => "Second behavior", "status" => "unverified",
                                         "evidence" => "No attributable verification is available" }
  checker.result = incomplete
  runtime.tick(now: now + 1)
  assert(record.state["finalization_notices"].empty? &&
         events(record).any? { |event| event["type"] == "requirement_coverage_unverified" },
         "finding-free delivery cannot release unverified requirements")
  assert(record.state.dig("completion_readiness", "status") == "not_ready" &&
         record.state.dig("completion_readiness", "check") == 1,
         "the same review cannot immediately overturn its own unverified coverage")
  host.finish("first and second behaviors delivered")
  record.submit("check")
  runtime.tick(now: now + 2)
  checker.result = answer("continue")
  runtime.tick(now: now + 3)
  assert(record.state["finalization_notices"].length == 1 && runtime.completion_gate[1].nil? &&
         Orbit::TaskView.format(record).include?("要求覆盖：当前版本"),
         "a current full independent report may qualify for completion")
  File.write(File.join(record.path, Orbit::RequirementCoverage::FILE_NAME), '{"records":[{}]}')
  assert(runtime.completion_gate[1] == "requirement_coverage_unverified" &&
         Orbit::TaskView.format(record).include?("要求覆盖：尚未确认"),
         "unreadable coverage never reuses the old ready assertion")
end

# An independent question must not replace an earlier task delivery or make
# the same fixed artifact pay for another automatic check. Manual review still
# sees the task-related answer and is never suppressed by this attribution.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  host.instance_variable_get(:@state)["last_turn_user_message_id"] = "original"
  host.instance_variable_get(:@state)["observations"] = [
    { "kind" => "agent_message", "text" => "Delivered artifact.txt for the original task" }
  ]
  runtime.tick(now: now)
  assert(checker.calls.length == 1, "the task's own completed reply can start an automatic check")
  checker.result = answer("continue")
  runtime.tick(now: now + 1)

  host.define_singleton_method(:user_messages) do |after_id:|
    after_id == "original" ? [{ "id" => "ux-question", "text" => "How does the unrelated UX work?" }] : []
  end
  host.finish("unrelated-turn")
  host.instance_variable_get(:@state)["last_turn_user_message_id"] = "ux-question"
  host.instance_variable_get(:@state)["observations"] = [
    { "kind" => "agent_message", "text" => "An unrelated UX answer" }
  ]
  runtime.tick(now: now + 2)
  runtime.tick(now: now + 62)
  assert(checker.calls.length == 1,
         "an unrelated reply and the next unchanged timer do not create another automatic review")
  record.submit("check")
  runtime.tick(now: now + 63)
  reviewed = checker.calls.last.fetch(:context)
  assert(checker.calls.length == 2 && reviewed.dig("root", "last_turn_task_attributed") == false &&
         reviewed.dig("task_delivery", "text") == "Delivered artifact.txt for the original task",
         "a manual review remains available and preserves the original task answer")
  checker.result = answer("complete")
  runtime.tick(now: now + 64)
  assert(record.state["finalization_notices"].length == 1,
         "a qualified manual check still sends a version-bound finalization notice")
end

# A check-request acknowledgement is a task-attributed Root reply, but it must
# not replace a substantive delivery from the same frozen input and artifact.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  host.instance_variable_get(:@state)["last_turn_user_message_id"] = "original"
  host.instance_variable_get(:@state)["observations"] = [
    { "kind" => "agent_message", "text" => "Delivered category routes and invoice examples, tests passed; no known limits." }
  ]
  runtime.tick(now: now)
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  reminder_id = record.state.fetch("sent_message_ids").last
  assert(reminder_id && host.messages.any? { |message| message.include?("手动终检") },
         "the clean automatic review prompts a version-bound manual check")

  host.finish("queued-manual-check")
  host.instance_variable_get(:@state)["last_turn_user_message_id"] = reminder_id
  host.instance_variable_get(:@state)["observations"] = [
    { "kind" => "agent_message", "text" => "Manual check queued; waiting for the reviewer." }
  ]
  record.submit("check")
  runtime.tick(now: now + 2)
  delivery = checker.calls.last.fetch(:context).fetch("task_delivery")
  assert(delivery["text"] == "Manual check queued; waiting for the reviewer." &&
         delivery.fetch("prior_turns").last["text"].include?("Delivered category routes and invoice examples"),
         "a queued check does not erase the earlier delivered answer on the same version")
end

# An overturned not_ready conclusion is retired from durable state, without
# treating an adjudicator or a subsequent automatic check as a final review.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue", delivery_ready: false,
                          delivery_reason: "No deliverable exists for this instruction")
  runtime.tick(now: now + 1)
  assert(record.state.dig("completion_readiness", "status") == "not_ready",
         "the initial manual review identifies an unready deliverable")
  host.finish("dispute-turn")
  record.submit("dispute", "reason" => "The committed artifact is present")
  runtime.tick(now: now + 2)
  checker.result = answer("complete", delivery_ready: true,
                          delivery_reason: "Read the delivered artifact in the fixed snapshot")
  runtime.tick(now: now + 3)
  status = record.state
  assert(status.dig("completion_readiness", "status") == "review_needed" &&
         status["finalization_notices"].empty? &&
         !Orbit::TaskView.next_action(status).include?("No deliverable"),
         "the current adjudication retires the false reason but does not approve completion")
  record.submit("check")
  runtime.tick(now: now + 4)
  checker.result = answer("complete")
  runtime.tick(now: now + 5)
  assert(record.state.dig("completion_readiness", "status") == "ready" &&
         record.state["finalization_notices"].length == 1,
         "only a later current manual reviewer can issue a completion hand-off")
end

fixture do |_root, record, _host, checker, runtime|
  now = Time.now.to_f
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("continue", delivery_ready: false, delivery_reason: "Not delivered yet")
  runtime.tick(now: now + 1)
  record.submit("stop", "reason" => "Ordinary pause")
  runtime.tick(now: now + 2)
  state = record.state
  action = Orbit::TaskView.next_action(state)
  assert(state["status"] == "paused" && action.include?("不能对已停止任务重检") &&
         action.include?("创建新任务"),
         "an ordinary paused task cannot ask for a check even without an adjudication")
end

# --- Member settlement contract (2026-09-30, 02a5eda7 regression) ---
# These fixtures cover the ranked settlement sources: dispatch-verdict
# completion with real native delivery, native turn error, business rejection,
# and the bounded wrap-up notice. None of them test real-model acceptance.

def settlement_member!(record, host, root, member_id:, output: nil, tool_call_id: nil, model: nil)
  output_path = output ? File.join(root, "member-output-#{member_id}.md") : nil
  File.write(output_path, "native task output\n") if output_path
  states = host.instance_variable_get(:@orbit_test_member_states) ||
           host.instance_variable_set(:@orbit_test_member_states, {})
  results = host.instance_variable_get(:@orbit_test_member_results) ||
            host.instance_variable_set(:@orbit_test_member_results, {})
  states[member_id] = { "registry_status" => "idle", "streaming" => false, "active_tools" => 0,
                        "session_attached" => true, "lifecycle" => {}, "last_turn_error" => nil }
  results[member_id] = { "output_path" => output_path, "output_text" => output_path ? "native task output" : nil,
                         "output_mtime" => output_path ? (Time.now.utc + 1).iso8601 : nil,
                         "output_size" => output_path ? File.size(output_path) : nil }
  host.define_singleton_method(:member_state) do |id|
    (instance_variable_get(:@orbit_test_member_states) || {})[id]
  end
  host.define_singleton_method(:member_result) do |id|
    (instance_variable_get(:@orbit_test_member_results) || {})[id] ||
      { "output_path" => nil, "output_text" => nil, "output_mtime" => nil, "output_size" => nil }
  end
  record.register_member(member_id, requested_name: member_id.sub("orbit-", "req-"),
                         tool_call_id: tool_call_id, model: model)
  (record.state["members"] || []).find { |member| member["thread_id"] == member_id }
end

def bind_unit!(record, runtime, member_id:, call_id:, status:, result: "delivered")
  units = Orbit::WorkUnitStore.new(record)
  unit = units.declare("objective" => "implement behavior", "acceptance" => "fixture checks",
                       "escalation" => "ask root", "requirements" => ["original"],
                       "allowed_paths" => ["src/"], "allowed_tools" => ["bash"])
  units.bind(unit["id"], member_id: member_id, tool_call_id: call_id,
             model: "zenmux/deepseek/deepseek-v4.1-flash")
  units.finish(unit["id"], status: status, result: result,
               verification: "fixture verification evidence") if status
  state = runtime.instance_variable_get(:@state)
  member = Array(state["members"]).find { |entry| entry["thread_id"] == member_id }
  member["work_unit_id"] = unit["id"]
  member["tool_call_id"] = call_id
  record.save(state)
  unit
end

# 02a5eda7 member 2 path: the Root-accepted dispatch with a real fresh native
# output settles the member completed without any SDK acceptedAt, and the
# finalization notice that stalled in the real session actually goes out.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-acc", output: true)
  record.submit("check")
  runtime.tick(now: now) # reconcile brings the member in; the manual check starts this tick
  bind_unit!(record, runtime, member_id: "orbit-m-acc", call_id: "call-acc", status: "accepted")
  checker.result = answer("complete")
  runtime.tick(now: now + 1) # settle from current facts, then finish the manual check
  member = record.state["members"].first
  assert(member["status"] == "completed" && member["result_delivery"] == "work_unit_acceptance" &&
         member["accepted_at"].nil? && member.dig("settlement_basis", "source") == "work_unit_acceptance",
         "a Root-accepted current dispatch with real native delivery settles completed without SDK acceptedAt")
  assert(record.state["finalization_notices"].length == 1 &&
         record.state.dig("completion_readiness", "status") == "ready",
         "the settled member no longer blocks the finalization notice (02a5eda7 stall)")
end

# 02a5eda7 member 1 path: a real native turn error (the frozen 429) settles
# failed directly from the structured SDK fact, not from Root prose or idle.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-err", output: false)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-err", call_id: "call-err", status: "rejected",
             result: "no code delivered")
  native_state = host.member_state("orbit-m-err")
  native_state["last_turn_error"] = { "stop_reason" => "error", "at" => (Time.now.utc + 1).iso8601,
                                      "error_status" => 429,
                                      "error_message" => "429 Go usage limit exceeded" }
  runtime.tick(now: now + 1)
  member = record.state["members"].first
  assert(member["status"] == "failed" && member["result_delivery"] == "native_turn_error" &&
         member["error"].include?("native turn error") && member["error"].include?("429"),
         "a current structured native turn error settles failed without waiting for Root to phrase it")
end

# Business rejection: a Root-rejected dispatch with real native output and no
# current native error settles `rejected` — never mislabelled as a failure.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-rej", output: true)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-rej", call_id: "call-rej", status: "rejected",
             result: "wrong output shape")
  runtime.tick(now: now + 1)
  member = record.state["members"].first
  assert(member["status"] == "rejected" && member["result_delivery"] == "work_unit_rejected" &&
         member["error"].nil?,
         "a business rejection with real native output settles rejected, not failed")
  assert(runtime.send(:members_settled?), "a rejected member counts as settled")
end

# No provable delivery, no settlement: an accepted verdict without a fresh
# native output keeps the member registered and the finalization queued.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-none", output: false)
  record.submit("check")
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-none", call_id: "call-none", status: "accepted")
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  runtime.tick(now: now + 2)
  member = record.state["members"].first
  assert(member["status"] == "registered",
         "no real native delivery means no settlement, whatever the unit verdict says")
  assert(record.state["pending_finalization"] && record.state["finalization_notices"].empty?,
         "the unprovable member keeps the finalization queued (fail-closed)")
end

# A turn error older than the dispatch binding is stale evidence and never
# settles the member.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-old", output: false)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-old", call_id: "call-old", status: "rejected")
  native_state = host.member_state("orbit-m-old")
  native_state["last_turn_error"] = { "stop_reason" => "error",
                                      "at" => (Time.now.utc - 10).iso8601,
                                      "error_status" => 500, "error_message" => "old crash" }
  runtime.tick(now: now + 1)
  assert(record.state["members"].first["status"] == "registered",
         "a pre-dispatch turn error is stale and must not fail the member")
end

# Settlement is current: a real new turn invalidates a completed settlement,
# and the same finished dispatch cannot reborn it after the member goes idle
# again — only a new Root finish or native acceptance can.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-live", output: true)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-live", call_id: "call-live", status: "accepted")
  runtime.tick(now: now + 1)
  assert(record.state["members"].first["status"] == "completed", "precondition: settled completed")
  native_state = host.member_state("orbit-m-live")
  native_state["streaming"] = true
  runtime.tick(now: now + 2)
  member = record.state["members"].first
  assert(member["status"] == "registered" && member["accepted_at"].nil? &&
         Array(member["settlement_history"]).any? { |entry| entry["reasons"] == ["new_turn_observed"] },
         "a real new turn invalidates the old settlement and clears the native acceptance")
  native_state["streaming"] = false
  runtime.tick(now: now + 3)
  assert(record.state["members"].first["status"] == "registered",
         "the same finished dispatch cannot settle the new turn (no old-verdict revival)")
end

# F3: past the finalization wait limit with an unprovable member, exactly one
# explicit Root wrap-up notice goes out; the task is neither completed nor
# degraded by the timer, and the notice never repeats.
fixture do |_root, record, host, checker, runtime|
  now = Time.now.to_f
  record.register_member("orbit-m-stuck", requested_name: "req-stuck")
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  assert(record.state["pending_finalization"] && record.state["members"].first["status"] == "registered",
         "precondition: a registered member without any dispatch fact queues the finalization")
  state = runtime.instance_variable_get(:@state)
  state["pending_finalization"]["at"] = (Time.now.utc - 120).iso8601
  record.save(state)
  runtime.tick(now: now + 2)
  wrapup = host.messages.find { |message| message.include?("成员结算无法证实") }
  assert(wrapup && wrapup.include?("orbit-m-stuck") && wrapup.include?("不是任务完成"),
         "one explicit wrap-up notice names the unprovable member and is not a completion")
  runtime.tick(now: now + 3)
  runtime.tick(now: now + 4)
  assert(host.messages.count { |message| message.include?("成员结算无法证实") } == 1,
         "the wrap-up notice is sent exactly once per pending version")
  assert(record.state["status"] != "needs_user" && record.state["status"] != "stop_unconfirmed" &&
         record.state["status"] != "complete" && !record.state["finalization_notices"].any?,
         "the timer never completes, degrades or stops the task by itself")
end

# Root gap 1: after a failed settlement, a real later successful turn must
# clear the stale native error (explicitly observed null), not re-fail the
# member from the old 429 fact.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-recover", output: false)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-recover", call_id: "call-rec", status: "rejected",
             result: "no code delivered")
  host.member_state("orbit-m-recover")["last_turn_error"] =
    { "stop_reason" => "error", "at" => (Time.now.utc + 1).iso8601,
      "error_status" => 429, "error_message" => "429 Go usage limit exceeded" }
  runtime.tick(now: now + 1)
  assert(record.state["members"].first["status"] == "failed", "precondition: the 429 settles failed")
  host.member_state("orbit-m-recover")["streaming"] = true
  runtime.tick(now: now + 2)
  assert(record.state["members"].first["status"] == "registered", "the retry turn invalidates the failure")
  host.member_state("orbit-m-recover")["streaming"] = false
  host.member_state("orbit-m-recover")["last_turn_error"] = nil
  runtime.tick(now: now + 3)
  member = record.state["members"].first
  assert(member["last_turn_error"].nil? && member["status"] == "registered",
         "an explicitly observed non-error turn clears the stale error and never re-fails the member")
end

# Root gap 2: missing or malformed time evidence never affirms a current
# turn/dispatch — unknown stamps must fail closed, not settle.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-badtime", output: false)
  settlement_member!(record, host, root, member_id: "orbit-m-badmtime", output: true)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-badtime", call_id: "call-badt", status: "rejected")
  bind_unit!(record, runtime, member_id: "orbit-m-badmtime", call_id: "call-badm", status: "accepted")
  host.member_state("orbit-m-badtime")["last_turn_error"] =
    { "stop_reason" => "error", "at" => "not-a-time",
      "error_status" => 429, "error_message" => "429 Go usage limit exceeded" }
  host.instance_variable_get(:@orbit_test_member_results)["orbit-m-badmtime"]["output_mtime"] = "not-a-time"
  runtime.tick(now: now + 1)
  statuses = record.state["members"].map { |member| [member["thread_id"], member["status"]] }.to_h
  assert(statuses == { "orbit-m-badtime" => "registered", "orbit-m-badmtime" => "registered" },
         "unparseable turn time and unparseable delivery mtime both stay unsettled (fail-closed)")
end

# Root gap 3: an invalidated native acceptedAt must not be revived by the same
# stored lifecycle value on later ticks, while a genuinely new acceptance is
# still allowed. SDK acceptedAt is a millisecond epoch number.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-native", output: false)
  runtime.tick(now: now)
  accepted_ms = (Time.now.to_f * 1000).round
  host.member_state("orbit-m-native")["lifecycle"] = { "acceptedAt" => accepted_ms }
  runtime.tick(now: now + 1)
  member = record.state["members"].first
  assert(member["status"] == "completed" && member["accepted_at"] == accepted_ms,
         "precondition: the native acceptance settles completed")
  host.member_state("orbit-m-native")["streaming"] = true
  runtime.tick(now: now + 2)
  member = record.state["members"].first
  assert(member["status"] == "registered" && member["accepted_at"].nil? &&
         Array(member["settlement_history"]).any? { |entry| entry["accepted_at"] == accepted_ms },
         "the new turn invalidates the native settlement and records it as history")
  host.member_state("orbit-m-native")["streaming"] = false
  runtime.tick(now: now + 3)
  runtime.tick(now: now + 4)
  assert(record.state["members"].first["status"] == "registered",
         "the same stored acceptedAt value cannot revive the invalidated settlement")
  host.member_state("orbit-m-native")["lifecycle"] = { "acceptedAt" => accepted_ms + 60_000 }
  runtime.tick(now: now + 5)
  assert(record.state["members"].first["status"] == "completed",
         "a genuinely new native acceptance settles again")
end

# Root gap 4: a unit declared against an older input version can never settle
# the member, whatever its dispatch says.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-stale", output: true)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-stale", call_id: "call-stale", status: "accepted")
  record.submit("amend", "text" => "A later correction", "source" => { "kind" => "explicit_text" })
  runtime.tick(now: now + 1)
  assert(record.state["members"].first["status"] == "registered",
         "a stale-input unit (version moved after the finish) never auto-settles the member")
end

# History-gap ticket (35f925ba): the independent checker receives a bounded,
# program-computed `check_history`. Its anchor is the EARLIEST VALID artifact
# review of the CURRENT input on the real artifact ROOT, keeping its own
# historical artifact digest — the pre-implementation check ran before the fix,
# so matching the current digest would evict exactly the check the checker
# needs. Failed and stale checks are never promoted, omissions stay counted,
# and no old finding is imported as a clue.
fixture do |root, record, host, checker, _runtime|
  now = Time.now.to_f
  state = record.state
  artifact_root = state.dig("workspace", "artifact_root")
  artifact_digest = Orbit::WorkspaceSnapshot.fingerprint(project_root: root)
  record.write("amendments/1.txt", "Add the second behavior.\n")
  state["amendments"] = [{ "path" => "amendments/1.txt", "source" => { "kind" => "explicit_text" },
                           "at" => "2026-09-30T05:09:00Z" }]
  record.save(state)
  state = record.state
  input_digest = record.input_digest(state)
  base = { "role" => "reviewer", "kind" => "artifact", "artifact_root" => artifact_root,
           "input_digest" => input_digest, "started_at" => "2026-09-30T05:00:00Z",
           "finished_at" => "2026-09-30T05:00:30Z", "stale" => false, "stale_reasons" => [],
           "result" => { "verdict" => "continue" } }
  stale_digest = "sha256:precheck-artifact"
  checks = [base.merge("number" => 1, "artifact_digest" => stale_digest, "failed" => true,
                       "result" => { "verdict" => "check_failed", "failure_kind" => "unavailable" })]
  checks << base.merge("number" => 2, "artifact_digest" => stale_digest,
                       "result" => { "verdict" => "continue" })
  checks << base.merge("number" => 3, "artifact_digest" => artifact_digest, "stale" => true,
                       "stale_reasons" => ["workspace"], "result" => { "verdict" => "correct" })
  (4..11).each { |number| checks << base.merge("number" => number, "artifact_digest" => artifact_digest) }
  checks << base.merge("number" => 12, "artifact_digest" => artifact_digest, "failed" => true,
                       "result" => { "verdict" => "check_failed", "failure_kind" => "provider_error" })
  state["checks"] = checks
  record.save(state)
  record.submit("check")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  runtime.tick(now: now)
  context = checker.calls.last.fetch(:context)
  history = context.fetch("check_history")
  assert(history["eligibility"].include?("not current completion eligibility"),
         "check history states it is history, not current completion eligibility")
  assert(history["anchor"] && history["anchor"]["number"] == 2,
         "the anchor is the earliest VALID check on the current input and root, not a tail or digest pick")
  assert(history["anchor"]["artifact_digest"] == stale_digest,
         "the anchor keeps its OWN historical artifact digest instead of the current one")
  assert(history["anchor"]["anchor_basis"].include?("real artifact root"),
         "the anchor states why it was chosen and that it grants no completion eligibility")
  assert(history["omitted_numbers"].include?(1) && history["omitted_numbers"].include?(3),
         "a failed and a stale check are omitted from the anchor, not promoted to it")
  assert(history["total_checks"] == 12, "the full check count stays visible")
  assert(history["recent"].length <= 6, "the recent window is bounded")
  assert(history["omitted_count"] >= 5, "omissions are counted, never silently absent")
  failed = history["recent"].find { |entry| entry["number"] == 12 }
  assert(failed && failed["terminal"] == "failed" && failed["failure_kind"] == "provider_error",
         "a failed check keeps its terminal state and failure kind")
  identity_keys = %w[number role kind artifact_root input_digest artifact_digest started_at finished_at
                     stale stale_reasons terminal failure_kind anchor_basis]
  assert((history["recent"] + [history["anchor"]]).all? { |entry| (entry.keys - identity_keys).empty? },
         "projected checks carry identity and outcome keys only")
  assert(!JSON.generate(history).include?("findings"),
         "no old finding is imported through check history")
  assert(context.fetch("findings").empty? && context["recheck"].nil?,
         "history facts never become pending clues")
end

# A failed check recorded before the identity slice existed recovers its
# identity from its own checks/<n>/scope.json instead of losing it.
fixture do |root, record, host, checker, _runtime|
  state = record.state
  artifact_root = state.dig("workspace", "artifact_root")
  artifact_digest = Orbit::WorkspaceSnapshot.fingerprint(project_root: root)
  input_digest = record.input_digest(state)
  dir = File.join(record.path, "checks", "5")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "scope.json"), JSON.generate(
    "number" => 5, "role" => "reviewer", "kind" => "artifact", "artifact_root" => artifact_root,
    "input_digest" => input_digest, "snapshot" => { "digest" => artifact_digest }))
  state["checks"] = [{ "number" => 5, "role" => "reviewer", "kind" => "artifact",
                       "started_at" => "2026-09-30T05:05:00Z", "finished_at" => "2026-09-30T05:05:10Z",
                       "failed" => true, "stale" => false,
                       "result" => { "verdict" => "check_failed", "failure_kind" => "unavailable" } }]
  record.save(state)
  record.submit("check")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker)
  runtime.tick(now: Time.now.to_f)
  entry = checker.calls.last.fetch(:context).fetch("check_history").fetch("recent").find { |item| item["number"] == 5 }
  assert(entry && entry["input_digest"] == input_digest && entry["artifact_digest"] == artifact_digest,
         "a legacy failed check recovers its identity from its own scope.json")
end


# Root self-selected dispatch path (root_without_hint, real 02a5eda7 Zenmux
# member): the durable unit carries the exact member/call binding and an
# accepted finish, while the member record itself never gets a unit
# association. Nothing is hand-stuffed; settlement restores it from the
# durable record.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  call_id = "call-self-1"
  settlement_member!(record, host, root, member_id: "orbit-m-self", output: true,
                     tool_call_id: call_id, model: "zenmux/deepseek/deepseek-v4.1-flash")
  units = Orbit::WorkUnitStore.new(record)
  unit = units.declare("objective" => "parse.js", "acceptance" => "node smoke",
                       "escalation" => "ask root", "requirements" => ["original"],
                       "allowed_paths" => ["src/"], "allowed_tools" => ["bash"])
  units.bind(unit["id"], member_id: "orbit-m-self", tool_call_id: call_id,
             model: "zenmux/deepseek/deepseek-v4.1-flash")
  units.finish(unit["id"], status: "accepted", result: "src/parse.js delivered",
               verification: "node assertions passed")
  runtime.tick(now: now)
  member = record.state["members"].first
  assert(member["work_unit_id"].nil?,
         "precondition: the member record never carried a unit association (Root self-selected)")
  assert(member["status"] == "completed" && member["result_delivery"] == "work_unit_acceptance" &&
         member.dig("settlement_basis", "tool_call_id") == call_id,
         "the durable exact member/call binding restores the association and settles the real root_without_hint path")
end

# Ambiguity and model mismatch are never attributed: two units claiming the
# same member/call, or a dispatch model differing from the observed member
# model, leave the member unsettled.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  call_a = "call-amb"
  settlement_member!(record, host, root, member_id: "orbit-m-amb", output: true,
                     tool_call_id: call_a, model: "zenmux/deepseek/deepseek-v4.1-flash")
  settlement_member!(record, host, root, member_id: "orbit-m-mm", output: true,
                     tool_call_id: "call-mm", model: "zenmux/deepseek/deepseek-v4.1-flash")
  units = Orbit::WorkUnitStore.new(record)
  2.times do |i|
    unit = units.declare("objective" => "duplicate #{i}", "acceptance" => "fixture",
                         "escalation" => "ask root", "requirements" => ["original"],
                         "allowed_paths" => ["src/"], "allowed_tools" => ["bash"])
    units.bind(unit["id"], member_id: "orbit-m-amb", tool_call_id: call_a,
               model: "zenmux/deepseek/deepseek-v4.1-flash")
    units.finish(unit["id"], status: "accepted", result: "duplicate", verification: "fixture evidence")
  end
  unit = units.declare("objective" => "model mismatch", "acceptance" => "fixture",
                       "escalation" => "ask root", "requirements" => ["original"],
                       "allowed_paths" => ["src/"], "allowed_tools" => ["bash"])
  units.bind(unit["id"], member_id: "orbit-m-mm", tool_call_id: "call-mm",
             model: "opencode-go/deepseek-v4.1-flash")
  units.finish(unit["id"], status: "accepted", result: "mismatch", verification: "fixture evidence")
  runtime.tick(now: now)
  statuses = record.state["members"].map { |member| [member["thread_id"], member["status"]] }.to_h
  assert(statuses == { "orbit-m-amb" => "registered", "orbit-m-mm" => "registered" },
         "ambiguous or model-mismatched durable matches stay unresolved (no heuristic attribution)")
end

# Execution fact vs evidence eligibility (p26 amend regression): a member
# settled failed by a real native turn error keeps that execution-terminated
# fact when the input version later moves; the amend itself never revives it
# as registered and never invents a new execution.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-amend-fail", output: false)
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-amend-fail", call_id: "call-af", status: "rejected")
  host.member_state("orbit-m-amend-fail")["last_turn_error"] =
    { "stop_reason" => "error", "at" => Time.now.utc.iso8601,
      "error_status" => 429, "error_message" => "429 Go usage limit exceeded" }
  runtime.tick(now: now + 1)
  assert(record.state["members"].first["status"] == "failed", "precondition: the 429 settles failed")
  record.submit("amend", "text" => "A later correction", "source" => { "kind" => "explicit_text" })
  runtime.tick(now: now + 2)
  member = record.state["members"].first
  assert(member["status"] == "failed" && member["result_delivery"] == "native_turn_error" &&
         member.dig("settlement_basis", "source") == "native_turn_error",
         "an amend alone never revives a failed execution fact (p26 regression)")
  assert(Array(member["settlement_history"]).empty?,
         "no invalidation is recorded for a version move without a new execution")
end

# An accepted real delivery keeps its physical execution fact across an amend,
# but the OLD ready/coverage evidence earns no eligibility for the new input:
# readiness invalidates and no notice appears; a real re-dispatch still
# invalidates the settlement.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-amend-acc", output: true)
  record.submit("check")
  runtime.tick(now: now)
  bind_unit!(record, runtime, member_id: "orbit-m-amend-acc", call_id: "call-aa", status: "accepted")
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  member = record.state["members"].first
  assert(member["status"] == "completed" && record.state["finalization_notices"].length == 1,
         "precondition: an accepted delivery settles completed and the notice qualifies")
  record.submit("amend", "text" => "A later correction", "source" => { "kind" => "explicit_text" })
  runtime.tick(now: now + 2)
  member = record.state["members"].first
  assert(member["status"] == "completed" &&
         member.dig("settlement_basis", "source") == "work_unit_acceptance",
         "the finished execution fact survives the version move with its own source")
  assert(record.state.dig("completion_readiness", "status") != "ready",
         "the old ready evidence earns no eligibility for the new input")
  # A real re-dispatch (new unfinished attempt, no new native acceptance)
  # still invalidates the settlement: the old verdict must not lend itself to
  # the new execution.
  bind_unit!(record, runtime, member_id: "orbit-m-amend-acc", call_id: "call-aa2", status: nil)
  runtime.tick(now: now + 3)
  member = record.state["members"].first
  assert(member["status"] == "registered" &&
         Array(member["settlement_history"]).any? { |entry| entry["reasons"] == ["dispatch_changed"] },
         "a truly changed dispatch identity still invalidates the old settlement")
end

# Later prior_scope declarations: the runtime appends them beside the created
# boundary (the original unknown is never rewritten), ignores identical retries
# and rejects tasks without a takeover boundary; the checker projection exposes
# the original and the declarations side by side.
fixture do |root, record, _host, _checker, runtime|
  now = Time.now.to_f
  state = runtime.instance_variable_get(:@state)
  state["takeover"] = {
    "format" => "orbit-takeover-1", "requested_at" => "2026-09-30T12:00:00Z", "reason" => "fixture",
    "prior_scope" => { "status" => "unknown", "text" => nil },
    "requirement" => { "source_kind" => "omp_user_message", "native_message_id" => "m-1",
                       "instruction_sha256" => "a" * 64, "instruction_bytes" => 10 },
    "artifact" => { "root" => root, "digest" => "sha256:x", "snapshot_path" => "takeover-snapshot",
                    "captured_at" => "2026-09-30T12:00:00Z", "git_head" => nil, "source" => "program_workspace_snapshot" },
    "supervision" => { "starts_at" => "2026-09-30T12:00:00Z", "boundary" => "fixture" },
    "prior_execution" => { "recognized_as_controlled" => false, "imported" => [], "note" => "fixture" }
  }
  record.save(state)
  declaration = { "prior_scope" => "Root 早前改过 src/a.rb", "reason" => "后来补充",
                  "source" => { "kind" => "omp_user_message" } }
  record.submit("takeover_scope", declaration)
  record.submit("takeover_scope", declaration)
  runtime.tick(now: now)
  takeover = record.state["takeover"]
  declarations = takeover["prior_scope_declarations"]
  assert(takeover.dig("prior_scope", "status") == "unknown" && takeover.dig("prior_scope", "text").nil?,
         "the created prior_scope stays unknown; declarations never rewrite it")
  assert(declarations.length == 1 && declarations.first["prior_scope"] == "Root 早前改过 src/a.rb" &&
         declarations.first["declared_at"].is_a?(String) &&
         declarations.first.dig("source", "kind") == "submitter_declaration",
         "the declaration is appended once, stamped as the submitter's statement — a command cannot dress it up as a native user observation")
  # A malformed payload is rejected explicitly instead of being silently dropped.
  record.submit("takeover_scope", "prior_scope" => 42)
  runtime.tick(now: now + 1)
  assert(record.state["takeover"]["prior_scope_declarations"].length == 1 &&
         events(record).any? { |event| event["type"] == "command_rejected" &&
                                       event["command_type"] == "takeover_scope" },
         "a malformed declaration is rejected explicitly")
  # More declarations: the checker projection keeps the recent five and counts
  # the omissions instead of dropping history silently.
  6.times { |index| record.submit("takeover_scope", "prior_scope" => "later scope #{index}") }
  runtime.tick(now: now + 2)
  projection = runtime.send(:takeover_context_projection)
  assert(record.state["takeover"]["prior_scope_declarations"].length == 7 &&
         projection["prior_scope"]["status"] == "unknown" &&
         projection["prior_scope_declarations"].length == 5 &&
         projection["prior_scope_declarations_omitted"] == 2 &&
         projection.dig("prior_execution", "recognized_as_controlled") == false,
         "the checker projection keeps the original unknown, the recent five declarations and an omission count")

  # A task without a takeover boundary rejects the declaration explicitly.
  state = runtime.instance_variable_get(:@state)
  state.delete("takeover")
  record.save(state)
  record.submit("takeover_scope", declaration)
  runtime.tick(now: now + 3)
  assert(record.state["takeover"].nil? &&
         events(record).any? { |event| event["type"] == "command_rejected" &&
                                       event["command_type"] == "takeover_scope" },
         "a non-takeover task rejects the declaration instead of silently accepting it")
end

# B (auto-release, positive): a real native turn error on the CURRENT bound
# dispatch with provably idle evidence (actual non-streaming, actual zero
# active tools, real empty owner-scoped async running list) records the
# same-unit execution failure atomically; the unit then re-binds legally with
# the failed attempt's error, source and time preserved in history.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-auto", output: false,
                     tool_call_id: "call-auto", model: "opencode-go/deepseek-v4.1-flash")
  runtime.tick(now: now)
  units = Orbit::WorkUnitStore.new(record)
  unit = units.declare("objective" => "auto release", "acceptance" => "fixture checks",
                       "escalation" => "ask root", "requirements" => ["original"],
                       "allowed_paths" => ["src/"], "allowed_tools" => ["bash"])
  units.bind(unit["id"], member_id: "orbit-m-auto", tool_call_id: "call-auto",
             model: "opencode-go/deepseek-v4.1-flash")
  state = runtime.instance_variable_get(:@state)
  member = Array(state["members"]).find { |entry| entry["thread_id"] == "orbit-m-auto" }
  member["work_unit_id"] = unit["id"]
  record.save(state)
  native_state = host.member_state("orbit-m-auto")
  native_state["async_jobs"] = { "running" => [] }
  native_state["last_turn_error"] = { "stop_reason" => "error", "at" => (Time.now.utc + 1).iso8601,
                                      "error_status" => 429, "error_message" => "429 Go usage limit exceeded" }
  runtime.tick(now: now + 1)
  member = record.state["members"].find { |entry| entry["thread_id"] == "orbit-m-auto" }
  assert(member["status"] == "failed" && member["result_delivery"] == "native_turn_error",
         "the member still settles failed from the structured native error")
  failed_unit = units.read(unit["id"])
  assert(failed_unit["status"] == "failed" && failed_unit["result"].include?("429"),
         "the same unit is auto-marked failed with the real error")
  attempt = failed_unit["dispatches"].last
  assert(attempt["failure_source"] == "native_turn_error" &&
         attempt.dig("failure_error", "error_status") == 429 &&
         attempt["status"] == "failed" && attempt["finished_at"],
         "the attempt keeps the real error, its source and the program time")
  assert(events(record).any? { |event| event["type"] == "work_unit_execution_failed" },
         "the auto-release emits its audit event")
  rebound = units.bind(unit["id"], member_id: "orbit-m-auto-2", tool_call_id: "call-auto-2",
                       model: "kimi-code/k3-256k")
  assert(rebound["status"] == "bound" && rebound["dispatches"].length == 2 &&
         rebound["dispatches"].first.dig("failure_error", "error_status") == 429,
         "the released unit re-binds legally with the failed attempt preserved")
end

# B (auto-release, unknown async): without a real owner-scoped async snapshot
# the same error settles the member but NEVER releases the unit — Root keeps
# the manual finish path.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-noasync", output: false,
                     tool_call_id: "call-noasync", model: "opencode-go/deepseek-v4.1-flash")
  runtime.tick(now: now)
  units = Orbit::WorkUnitStore.new(record)
  unit = units.declare("objective" => "unknown async", "acceptance" => "fixture checks",
                       "escalation" => "ask root", "requirements" => ["original"],
                       "allowed_paths" => ["src/"], "allowed_tools" => ["bash"])
  units.bind(unit["id"], member_id: "orbit-m-noasync", tool_call_id: "call-noasync",
             model: "opencode-go/deepseek-v4.1-flash")
  state = runtime.instance_variable_get(:@state)
  member = Array(state["members"]).find { |entry| entry["thread_id"] == "orbit-m-noasync" }
  member["work_unit_id"] = unit["id"]
  record.save(state)
  native_state = host.member_state("orbit-m-noasync")
  native_state["last_turn_error"] = { "stop_reason" => "error", "at" => (Time.now.utc + 1).iso8601,
                                      "error_status" => 429, "error_message" => "429 Go usage limit" }
  runtime.tick(now: now + 1)
  assert(units.read(unit["id"])["status"] == "bound",
         "a missing async snapshot never unlocks the same-unit retry")
end

# B (auto-release, unknown active tools): the settlement helper tolerates an
# absent active_tools count for history, but the auto-release demands the
# actual zero — the unit stays bound.
fixture do |root, record, host, _checker, runtime|
  now = Time.now.to_f
  settlement_member!(record, host, root, member_id: "orbit-m-notools", output: false,
                     tool_call_id: "call-notools", model: "opencode-go/deepseek-v4.1-flash")
  runtime.tick(now: now)
  units = Orbit::WorkUnitStore.new(record)
  unit = units.declare("objective" => "unknown tools", "acceptance" => "fixture checks",
                       "escalation" => "ask root", "requirements" => ["original"],
                       "allowed_paths" => ["src/"], "allowed_tools" => ["bash"])
  units.bind(unit["id"], member_id: "orbit-m-notools", tool_call_id: "call-notools",
             model: "opencode-go/deepseek-v4.1-flash")
  state = runtime.instance_variable_get(:@state)
  member = Array(state["members"]).find { |entry| entry["thread_id"] == "orbit-m-notools" }
  member["work_unit_id"] = unit["id"]
  record.save(state)
  native_state = host.member_state("orbit-m-notools")
  native_state.delete("active_tools")
  native_state["async_jobs"] = { "running" => [] }
  native_state["last_turn_error"] = { "stop_reason" => "error", "at" => (Time.now.utc + 1).iso8601,
                                      "error_status" => 429, "error_message" => "429 Go usage limit" }
  runtime.tick(now: now + 1)
  assert(units.read(unit["id"])["status"] == "bound",
         "an unknown active-tool count never unlocks the same-unit retry")
end

puts "TASK_RUNTIME_TEST_PASS (deterministic, not real-model acceptance)"
