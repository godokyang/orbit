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

  def send_message(text)
    raise Orbit::Connection::Error, @fail_send_message if @fail_send_message.is_a?(String)

    @messages << text
    @state["status"] = "active"
    { "id" => "sent-#{@messages.length}" }
  end

  attr_accessor :fail_send_message

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
  attr_accessor :scores, :failure, :on_call, :delegation_scores, :delegation_failure, :candidate_scores

  def initialize(scores)
    @scores, @calls = scores, []
    @delegation_calls = []
    @candidate_calls = []
    @delegation_scores = { "member_fit" => 0.8, "parallel_gain" => 0.75, "cost_appropriate" => 0.8 }
  end

  def assess(state:)
    @calls << state
    @on_call&.call
    raise @failure if @failure

    { "model" => "jev-test", "scores" => @scores, "usage" => { "input_tokens" => 10, "output_tokens" => 3 } }
  end

  def assess_delegation(state:)
    @delegation_calls << state
    raise @delegation_failure if @delegation_failure

    { "model" => "jev-test", "scores" => @delegation_scores, "usage" => { "input_tokens" => 20, "output_tokens" => 4 } }
  end

  def assess_candidates(state:, candidates:)
    @candidate_calls << { "state" => state, "candidates" => candidates }
    { "model" => "jev-test", "scores" => @candidate_scores, "usage" => { "input_tokens" => 30, "output_tokens" => 5 } }
  end
end

def events(record)
  File.readlines(File.join(record.path, "events.jsonl")).map { |line| JSON.parse(line) }
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
    metrics = { "output_tokens_per_second" => { "value" => 120.5, "unit" => "tokens/s", "basis" => "median" } }
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

def fixture(interval: 60)
  Dir.mktmpdir("orbit-runtime-test-") do |root|
    File.write(File.join(root, "artifact.txt"), "first behavior")
    record = Orbit::TaskRecord.create(
      project_root: root, instruction: "Provide first and second behaviors.\n",
      source: { "id" => "original", "kind" => "native_user_message" },
      connection: { "provider" => "omp" }, review: { "interval_seconds" => interval }, estimate: {}
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
  assert(checker.calls.length == 1, "a stale clue does not immediately restart the checker")
  record.submit("check")
  runtime.tick(now: now + 1.5)
  checker.result = answer("continue", resolved: ["clue"])
  runtime.tick(now: now + 3)
  assert(record.state["recheck"].nil? &&
         host.messages.none? { |message| message.include?("Orbit independent check") },
         "an explicit withdrawal clears the clue without a correction")
end

# Delegation has two stages: the structural `delegatable` score only decides
# whether model evidence is needed. A hint requires validated cache evidence
# plus member_fit/parallel_gain and is bounded to once per observation
# signature; nothing dispatches automatically.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.6)
  cache = evidence_cache(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache)
  now = Time.now.to_f
  assert(Orbit::TaskView.format(record).include?("JEV：未启用"), "status shows JEV disabled before any assessment")
  runtime.tick(now: now + 6)
  requests = host.messages.select { |message| message.include?("model evidence request") }
  assert(requests.length == 1, "one evidence request is sent for the observation")
  assert(requests.first.include?("opencode-go/deepseek-v4.1-flash") &&
         requests.first.include?("orbit model-evidence #{record.path} --file -") &&
         requests.first.include?("speed, quality, cost and local samples") &&
         requests.first.include?("coarse cost_tier") &&
         requests.first.include?("an explicit unknown is acceptable"),
         "the request lists the identity, the needed facts and the dedicated command")
  assert(host.messages.none? { |message| message.include?("delegation hint") },
         "the structural stage never hints directly")
  assert(record.state.dig("jev", "evidence_status") == "requested" && advisor.delegation_calls.empty?,
         "evidence is pending and the second stage has not run")
  status_text = Orbit::TaskView.format(record)
  assert(status_text.include?("JEV：已判断") && status_text.include?("等待 Root 提交模型证据") &&
         status_text.include?("当前仅独立检查；执行成员 0 个"),
         "status shows the JEV assessment, pending evidence and zero execution members")

  host.working("more progress")
  runtime.tick(now: now + 70)
  assert(host.messages.count { |message| message.include?("model evidence request") } == 1,
         "repeated ticks do not loop the evidence request")
  assert(advisor.delegation_calls.empty?, "missing evidence never reaches the second stage")

  requested = record.state.dig("evidence_request", "identities")
  assert(requested.dig("root", "provider") == requested.dig("candidates", 0, "provider") &&
         requested.dig("root", "model") == requested.dig("candidates", 0, "model") &&
         requested.dig("root", "reasoning") == requested.dig("candidates", 0, "reasoning"),
         "precondition: the same-host candidate shares the Root identity")
  assert(requested.dig("candidates", 0, "billing_route") == "direct_api" &&
         requested.dig("root", "billing_route").nil?,
         "precondition: the candidate carries the host route while the Root stays route-less")
  cache.record(evidence_entry(billing_route: "unknown"))
  cache.record(evidence_entry(billing_route: "direct_api"))
  # Distinct billing routes make the Root and candidate identities distinct;
  # the submission must cover both.
  submission = [evidence_entry(billing_route: "unknown"), evidence_entry(billing_route: "direct_api")]
  record.submit("model_evidence", "entries" => submission.map do |entry|
    entry.slice("provider", "model", "reasoning", "billing_route", "status")
  end)
  runtime.tick(now: now + 71)
  assert(advisor.delegation_calls.length == 1, "submitted evidence triggers one second-stage judgment")
  summary = advisor.delegation_calls.first.fetch("model_evidence")
  assert(summary.dig("root", "provider") == "opencode-go" &&
         summary.dig("root", "metrics").key?("output_tokens_per_second") &&
         !JSON.generate(summary).include?("<html"),
         "the bounded summary carries validated metrics and no web page text")
  hints = host.messages.select { |message| message.include?("delegation hint") }
  assert(hints.length == 1 && hints.first.include?("native task"),
         "passing thresholds hint once and name the native task dispatch")
  assert(record.state.dig("delegation_hint", "member_fit") == 0.8 &&
         record.state.dig("delegation_hint", "parallel_gain") == 0.75 &&
         record.state.dig("delegation_hint", "cost_appropriate") == 0.8 &&
         record.state.dig("delegation_hint", "cost_basis") == "coarse_tier" &&
         record.state.dig("delegation_hint", "signature"),
         "the hint records all second-stage scores, its cost basis and signature")
  assert(record.state.dig("jev", "delegation", "decision") == "recommended",
         "a passing second stage records decision recommended")
  assert(record.state.dig("jev", "evidence_status") == "used", "evidence use is recorded")
  used = events(record).select { |event| event["type"] == "model_evidence_used" }
  assert(used.length == 1 && used.first["summary"] == summary &&
         used.first["summary"] == record.state.dig("jev", "evidence", "summary") &&
         used.first.dig("summary", "root", "sources") == ["https://artificialanalysis.ai/models"] &&
         used.first.dig("summary", "root", "metrics", "output_tokens_per_second", "basis") == "median",
         "the submitted path records the same bounded summary and its signature")
  assert(record.state.dig("jev", "evidence", "signature") == used.first["signature"],
         "task state keeps the traced summary")

  host.working("still more progress")
  runtime.tick(now: now + 140)
  assert(advisor.delegation_calls.length == 1 &&
         host.messages.count { |message| message.include?("delegation hint") } == 1,
         "repeated ticks neither re-judge nor re-hint the same signature")
  assert(record.state.dig("jev", "delegation", "usage") == { "input_tokens" => 20, "output_tokens" => 4 },
         "the latest second-stage usage stays readable with the delegation status")

  record.register_member("orbit-hinted", requested_name: "hinted", status: "registered")
  runtime.tick(now: now + 141)
  assert(record.state["members"].first && record.state.dig("delegation_hint", "followed") == true &&
         record.state.dig("delegation_hint", "followed_kind") == "omp",
         "the registration gate records the hinted native member")
  assert(record.state.dig("members", 0, "delegation_basis") == "orbit_hint",
         "the member keeps its delegation basis for status and review context")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("delegation_hint_followed") },
         "the follow-up event is recorded")
  assert(Orbit::TaskView.format(record).include?("已委派 1 个执行成员"), "status shows the execution member count")

  # A changing artifact may produce a new signature while the member works,
  # but the existing execution lane must suppress another automatic hint.
  runtime.send(:stage_delegation, { "delegatable" => 0.9 }, "changed-artifact", now + 142)
  assert(advisor.delegation_calls.length == 1 &&
         host.messages.count { |message| message.include?("delegation hint") } == 1,
         "an active execution member suppresses a second delegation assessment and hint")
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

# A successful second-stage assessment is durable even if the runtime dies
# before sending its advisory message. The replacement rebuilds the pending
# hint from the recorded scores and delivers it once.
fixture do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  cache = both_route_evidence(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache)
  now = Time.now.to_f
  state = runtime.instance_variable_get(:@state)
  state["jev"] = { "scores" => { "delegatable" => 0.9 } }
  options = runtime.send(:delegation_options)
  digest = Orbit::WorkspaceSnapshot.fingerprint(project_root: root)
  signature = runtime.send(:delegation_signature, digest, options)
  identities = runtime.send(:evidence_identities, options)
  entries = runtime.send(:evidence_states, identities)
  runtime.send(:run_delegation_assessment, identities, entries, signature, digest, now)
  assert(record.state.dig("delegation_assessments", signature, "scores"),
         "precondition: the passing assessment was persisted before delivery")

  replacement = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache)
  replacement.send(:stage_delegation, { "delegatable" => 0.9 }, digest, now + 1)
  replacement.send(:deliver_pending_hint)
  assert(host.messages.count { |message| message.include?("delegation hint") } == 1 &&
         record.state.dig("delegation_hints", signature),
         "the replacement runtime recovers and records exactly one hint")
end

# The cost gate is fail-closed: a route-less (legacy) cache entry cannot prove
# cost, so the route-specific lookup misses and asks for route-bearing
# evidence instead of judging or hinting.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: evidence_cache(root, [evidence_entry(billing_route: "unknown")]))
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.delegation_calls.empty?, "a route-less entry never reaches the second stage")
  assert(record.state["delegation_hint"].nil? && host.messages.none? { |message| message.include?("delegation hint") },
         "a route-less entry never hints")
  assert(record.state.dig("jev", "evidence_status") == "requested",
         "the route-specific lookup requests evidence instead of reusing the legacy entry")
end

# ADR-009 coarse cost semantics: without numeric cost facts the cost basis
# is unknown. Even a low recorded cost score must not by itself suppress a
# hint that already passed the quality and time bars, and the hint displays
# the unknown tier instead of reading it as free.
class RuntimeQuotaRouteHost < RuntimeTeamHost
  def default_member_route = "subscription_quota"
end

fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeQuotaRouteHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.delegation_scores = { "member_fit" => 0.8, "parallel_gain" => 0.75, "cost_appropriate" => 0.3 }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: both_route_evidence(root, candidate_route: "subscription_quota",
                                                                      priced: false))
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.delegation_calls.length == 1, "an unknown cost basis still reaches the second stage")
  assert(record.state.dig("jev", "delegation", "decision") == "recommended" &&
         record.state.dig("jev", "delegation", "cost_basis") == "unknown",
         "a low cost score on an unknown basis does not suppress the passing recommendation")
  hint = host.messages.find { |message| message.include?("delegation hint") }
  assert(hint && hint.include?("cost tier unknown") && hint.include?("unknown cost is not free"),
         "the hint displays the unknown cost tier instead of reading it as free")
  assert(record.state.dig("delegation_hint", "cost_basis") == "unknown" &&
         record.state.dig("delegation_hint", "cost_appropriate") == 0.3,
         "the hint record keeps the ungated cost score and its unknown basis")
  assert(File.readlines(File.join(record.path, "events.jsonl")).none? { |line| line.include?("delegation_cost_unverified") },
         "the removed route/fact gate records no unverified-cost events")
end

# Numeric `quota.*` facts make a known coarse tier: the cost judgment runs
# and a passing score delivers the hint with its recorded basis.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeQuotaRouteHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.delegation_scores = { "member_fit" => 0.8, "parallel_gain" => 0.75, "cost_appropriate" => 0.8 }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: both_route_evidence(root, candidate_route: "subscription_quota",
                                                                      priced: false, quota: true))
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.delegation_calls.length == 1, "quota.* numeric facts make a known coarse tier that reaches one cost judgment")
  assert(record.state.dig("delegation_hint", "cost_appropriate") == 0.8 &&
         record.state.dig("delegation_hint", "cost_basis") == "coarse_tier" &&
         record.state.dig("jev", "delegation", "decision") == "recommended" &&
         host.messages.any? { |message| message.include?("delegation hint") },
         "a passing known-tier judgment persists and delivers the hint")
  hint_event = events(record).find { |event| event["type"] == "delegation_hint" }
  assert(hint_event && hint_event["cost_appropriate"] == 0.8 && hint_event["cost_basis"] == "coarse_tier",
         "the delivered hint event records the cost score and its known basis")
end

# `quota.*` facts on a direct_api route are not cost facts for that route:
# the billing modes never mix, so the basis is unknown and a passing
# recommendation is not suppressed, while the quota facts are never read as
# API prices.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.delegation_scores = { "member_fit" => 0.8, "parallel_gain" => 0.75, "cost_appropriate" => 0.4 }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: both_route_evidence(root, priced: false, quota: true))
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.delegation_calls.length == 1, "namespace-mismatched facts still reach the cost judgment")
  assert(record.state.dig("jev", "delegation", "cost_basis") == "unknown" &&
         record.state.dig("jev", "delegation", "decision") == "recommended",
         "quota facts on a direct_api route make an unknown, not known, cost basis")
  hint = host.messages.find { |message| message.include?("delegation hint") }
  assert(hint && hint.include?("cost tier unknown"),
         "the hint still ships and displays the unknown tier")
end

# A verified direct_api route with a price still needs the cost score to pass.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.delegation_scores = { "member_fit" => 0.8, "parallel_gain" => 0.75, "cost_appropriate" => 0.4 }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: both_route_evidence(root))
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.delegation_calls.length == 1, "route+price evidence reaches one cost judgment")
  assert(record.state.dig("jev", "delegation", "decision") == "declined" &&
         host.messages.none? { |message| message.include?("delegation hint") },
         "a cost score below 0.50 declines without a hint")
end

# The signature carries the resolved candidate model and route, so a changed
# @task route cannot reuse a stored assessment or hint.
class RuntimeRouteSwitchHost < RuntimeTeamHost
  attr_writer :route_value
  def default_member_route = @route_value || "direct_api"
end

fixture do |root, record, _host, checker, _runtime|
  host = RuntimeRouteSwitchHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: evidence_cache(root))
  options = runtime.send(:delegation_options)
  digest = Orbit::WorkspaceSnapshot.fingerprint(project_root: root)
  direct = runtime.send(:delegation_signature, digest, options)
  host.route_value = "subscription_quota"
  quota = runtime.send(:delegation_signature, digest, options)
  assert(direct != quota, "a changed resolved route changes the delegation signature")
end

# Evidence pending when the @task route changes is stale: the submission still
# matches its original request, but it is not assessed under the new
# candidate, and the cache entries remain reusable for their own route.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeRouteSwitchHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  cache = evidence_cache(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache)
  runtime.tick(now: Time.now.to_f + 6)
  assert(record.state.dig("jev", "evidence_status") == "requested", "precondition: evidence is pending")
  host.route_value = "subscription_quota"
  submission = [evidence_entry(billing_route: "unknown"), evidence_entry(billing_route: "direct_api")]
  submission.each { |entry| cache.record(entry) }
  record.submit("model_evidence", "entries" => submission.map do |entry|
    entry.slice("provider", "model", "reasoning", "billing_route", "status")
  end)
  runtime.tick(now: Time.now.to_f + 7)
  assert(advisor.delegation_calls.empty?, "a changed route leaves the pending evidence unassessed")
  assert(record.state.dig("jev", "evidence_status") == "unknown" &&
         host.messages.none? { |message| message.include?("delegation hint") },
         "a changed route records unknown and never hints")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("model_evidence_stale") },
         "the stale pending evidence is recorded")
  assert(cache.stored_entries.length == 2, "cache entries stay reusable for their own routes")
end

# ADR-009 first candidate wiring: pool ∩ session-available ∩ agent names
# replaces the default member as the automatic candidate source on hosts
# exposing a model catalog. Root's own model is excluded from automatic
# multi-agent recommendation. Evidence requests carry model+agent, but until
# per-candidate quality/time judgment lands the round is held at
# pending_candidates — no generalized delegation hint, no specific model
# recommendation. Explicit native dispatch stays allowed and registered.
class RuntimePoolHost < RuntimeTeamHost
  attr_accessor :catalog

  def initialize(root)
    super
    @catalog = { "current" => "openai/gpt-6-astra",
                 "available" => %w[openai/gpt-6-astra opencode-go/deepseek-v4.1-flash zhipu/glm-5],
                 "agents" => { "opencode-go/deepseek-v4.1-flash" => "orbit-m-deepseek",
                               "zhipu/glm-5" => "orbit-m-glm" } }
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

fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimePoolHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  cache = evidence_cache(root)
  pool = StubCandidatePool.new(["opencode-go/deepseek-v4.1-flash", "openai/gpt-6-astra", "qwen/qwen4-max"])
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache, candidate_pool: pool)
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  request = host.messages.find { |message| message.include?("model evidence request") }
  assert(request && request.include?("- candidate (omp): opencode-go/deepseek-v4.1-flash") &&
         request.include?("orbit-m-deepseek") && request.include?("openai/gpt-6-astra"),
         "the request names the pooled candidate with its agent plus the root")
  assert(request.scan("- candidate").length == 1 && !request.include?("qwen/qwen4-max"),
         "unavailable models and the Root's own model are excluded from candidates")

  cache.record(evidence_entry(provider: "openai", model: "gpt-6-astra", billing_route: "unknown"))
  deepseek = evidence_entry(billing_route: "direct_api")
  deepseek["cost_tier"] = { "band" => "low", "confidence" => "medium", "basis" => "official pricing page" }
  cache.record(deepseek)
  submission = [evidence_entry(provider: "openai", model: "gpt-6-astra", billing_route: "unknown"),
                evidence_entry(billing_route: "direct_api")]
  record.submit("model_evidence", "entries" => submission.map do |entry|
    entry.slice("provider", "model", "reasoning", "billing_route", "status")
  end)
  advisor.candidate_scores = { "0" => { "quality" => 0.8, "time" => 0.7 } }
  runtime.tick(now: now + 7)
  assert(advisor.delegation_calls.empty? && advisor.candidate_calls.length == 1,
         "the pool path runs one per-candidate judgment and never the whole-group questions")
  evidence_to_jev = advisor.candidate_calls.first.dig("state", "model_evidence")
  assert(evidence_to_jev.dig("candidates", 0, "cost_tier", "band") == "low" &&
         evidence_to_jev.dig("candidates", 0, "sources") == ["https://artificialanalysis.ai/models"],
         "the validated cost tier, sources and validity reach the judgment with the metrics")
  assert(record.state.dig("jev", "delegation", "decision") == "recommended" &&
         record.state.dig("jev", "delegation", "recommendation", "first", "agent") == "orbit-m-deepseek" &&
         record.state.dig("jev", "delegation", "recommendation", "first", "cost_band") == "low",
         "the recommendation names the first choice with its agent and verified cost band")
  message = host.messages.find { |text| text.include?("Orbit model recommendation") }
  assert(message && message.include?("First choice: orbit-m-deepseek") &&
         message.include?("model opencode-go/deepseek-v4.1-flash") &&
         message.include?("cost tier low"),
         "the delivered message names agent+model with quality, time and cost reasons")
  assert(host.messages.none? { |text| text.include?("Orbit delegation hint") },
         "the pool path never falls back to the old generalized hint")
  log = File.readlines(File.join(record.path, "events.jsonl"))
  assert(log.any? { |line| line.include?("delegation_recommendation") } &&
         log.any? { |line| line.include?("delegation_recommendation_delivered") },
         "the recommendation and its delivery are recorded as events")

  record.register_member("orbit-explicit1", requested_name: "explicit1", status: "registered")
  runtime.tick(now: now + 8)
  member = record.state["members"].first
  assert(member && member["status"] == "registered" && member["delegation_basis"] == "orbit_hint" &&
         record.state.dig("delegation_hint", "followed") == true,
         "Root's explicit dispatch follows the recommendation and records the orbit_hint basis")
end

# ADR-009 §3 quality line: a candidate whose sourced evidence does not
# clear the quality bar stays pending — it is never recommended, and with no
# qualified candidate there is no recommendation message at all.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimePoolHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.candidate_scores = { "0" => { "quality" => 0.3, "time" => 0.8 } }
  cache = evidence_cache(root)
  cache.record(evidence_entry(provider: "openai", model: "gpt-6-astra", billing_route: "unknown"))
  cache.record(evidence_entry(billing_route: "direct_api"))
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache,
                                   candidate_pool: StubCandidatePool.new(["opencode-go/deepseek-v4.1-flash"]))
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.candidate_calls.length == 1 &&
         record.state.dig("jev", "delegation", "decision") == "pending_candidates" &&
         record.state.dig("jev", "delegation", "candidates", 0, "status") == "pending_quality",
         "a candidate below the sourced quality line is recorded as pending, not recommended")
  assert(host.messages.none? { |message| message.include?("Orbit model recommendation") } &&
         record.state["delegation_hint"].nil?,
         "no recommendation is sent or recorded when no candidate qualifies")
end

# Convergence for the real re-submission path: a pending_candidates round
# judged on thin evidence re-opens when Root later submits richer validated
# evidence against the still-pending request, and only then — an unchanged
# re-submission never re-runs the judgment.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimePoolHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  cache = evidence_cache(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache,
                                   candidate_pool: StubCandidatePool.new(["opencode-go/deepseek-v4.1-flash"]))
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  assert(host.messages.any? { |message| message.include?("model evidence request") },
         "precondition: the thin-evidence round went through a real request")

  thin = [evidence_entry(provider: "openai", model: "gpt-6-astra", billing_route: "unknown"),
          evidence_entry(billing_route: "direct_api")]
  thin.each { |entry| cache.record(entry) }
  record.submit("model_evidence", "entries" => thin.map do |entry|
    entry.slice("provider", "model", "reasoning", "billing_route", "status")
  end)
  advisor.candidate_scores = { "0" => { "quality" => 0.3, "time" => 0.8 } }
  runtime.tick(now: now + 7)
  assert(advisor.candidate_calls.length == 1 &&
         record.state.dig("jev", "delegation", "decision") == "pending_candidates" &&
         record.state.dig("jev", "delegation", "candidates", 0, "status") == "pending_quality",
         "precondition: the thin round ends pending_candidates below the quality line")

  rich = evidence_entry(billing_route: "direct_api")
  rich["cost_tier"] = { "band" => "low", "confidence" => "medium", "basis" => "official pricing page" }
  cache.record(rich)
  record.submit("model_evidence", "entries" => thin.map do |entry|
    entry.slice("provider", "model", "reasoning", "billing_route", "status")
  end)
  advisor.candidate_scores = { "0" => { "quality" => 0.8, "time" => 0.7 } }
  runtime.tick(now: now + 8)
  assert(advisor.candidate_calls.length == 2 &&
         record.state.dig("jev", "delegation", "decision") == "recommended" &&
         record.state.dig("jev", "delegation", "recommendation", "first", "agent") == "orbit-m-deepseek" &&
         host.messages.any? { |message| message.include?("First choice: orbit-m-deepseek") },
         "changed validated evidence re-opens the pending round and recommends")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("delegation_assessment_reopened") },
         "the re-open is recorded as an event")

  record.submit("model_evidence", "entries" => thin.map do |entry|
    entry.slice("provider", "model", "reasoning", "billing_route", "status")
  end)
  runtime.tick(now: now + 9)
  assert(advisor.candidate_calls.length == 2 &&
         record.state.dig("jev", "delegation", "decision") == "recommended",
         "an unchanged re-submission never re-runs the judgment")
end

# ADR-009 §4 checker model integration: selection happens only before a
# new check, an in-flight check never switches, an undecided selection
# blocks without snapshots or selector hammering, and a pool change affects
# exactly the next check.
class RuntimeSelectingChecker
  attr_reader :calls, :selected_models
  attr_accessor :result, :failure_message

  def initialize
    @calls = []
    @selected_models = []
  end

  def start(**args)
    @calls << args
  end

  def poll
    raise Orbit::CheckRunner::Error, @failure_message if @failure_message

    @result
  end

  def stop! = true
  def failure_kind = @failure_message ? "auth_or_quota" : nil
  def failure_basis = @failure_message ? "structured" : nil

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

  def select(explicit:, instruction:, previous:, selected_for:)
    @calls << { "role" => selected_for, "instruction" => instruction }
    raise Orbit::CheckerModelSelector::Error, @error if @error

    explicit_text = explicit.to_s
    chosen = explicit_text.empty? ? @model : explicit_text
    [chosen, { "source" => explicit_text.empty? ? "candidate_pool" : "explicit",
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
  selector.error = "no candidate pool model passed the JEV quality line"
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

# A real check failure records a failed check, keeps the running task with
# its members, blocks automatic checks, and Root's explicit review-model
# clears the block and starts a fresh check that recovers.
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
  assert(!Orbit::TaskRuntime::TERMINAL.include?(record.state["status"]) && record.state["error"].nil?,
         "a failed check is a blocked checker, not a failed task")
  failed = record.state.fetch("checks").last
  assert(failed["failed"] && failed.dig("result", "verdict") == "check_failed" &&
         failed.dig("result", "failure_kind") == "auth_or_quota" &&
         record.state.dig("review", "blocked", "type") == "check_failure" &&
         record.state.dig("review", "blocked", "model") == "zhipu/glm-5",
         "the failure is recorded as a failed check with its kind and model")
  assert(Orbit::TaskView.format(record).include?("检查阻塞：模型 zhipu/glm-5"),
         "orbit status surfaces the blocked checker line")
  notice = host.messages.find { |text| text.include?("orbit review-model") }
  assert(notice && notice.include?("--model") && notice.include?(record.path) &&
         notice.include?("does not retry"),
         "Root is told in English to explicitly re-select via review-model")

  runtime.tick(now: now + 400)
  assert(checker.calls.length == 1, "blocked automatic checks neither start nor snapshot")

  record.submit("review_model", "model" => "openai/gpt-6-astra", "reason" => "auth failed")
  runtime.tick(now: now + 401)
  recorded = events(record).find { |event| event["type"] == "review_model_recorded" }
  assert(record.state.dig("review", "explicit_model") == "openai/gpt-6-astra" &&
         recorded && recorded["in_pool"] == false &&
         recorded["notice"] == "explicit review model is outside the candidate pool" &&
         record.state.dig("review", "blocked").nil?,
         "the explicit model is pinned with an out-of-pool notice and clears the block")
  assert(checker.calls.length == 2 && checker.selected_models.last == "openai/gpt-6-astra",
         "a fresh check starts immediately on the explicit model")

  checker.failure_message = nil
  checker.result = answer("complete")
  runtime.tick(now: now + 402)
  assert(record.state.fetch("checks").last.dig("result", "verdict") == "complete",
         "checks recover after the explicit re-selection")
end

# Q17 (ADR-009): an empty pool (or an empty session intersection) produces no
# member recommendation at all, and a pool change must invalidate old
# signatures so stale recommendations cannot survive.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimePoolHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  pool = StubCandidatePool.new([])
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: evidence_cache(root), candidate_pool: pool)
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  assert(host.messages.none? { |message| message.include?("model evidence request") } &&
         host.messages.none? { |message| message.include?("delegation hint") } &&
         advisor.delegation_calls.empty?,
         "an empty pool recommends nothing: no request, no judgment, no hint")
  assert(record.state.dig("jev", "delegation", "decision") == "no_candidates" &&
         record.state.dig("jev", "evidence_note").to_s.include?("Q17"),
         "the Q17 no-recommendation reason is recorded")

  options = runtime.send(:delegation_options)
  digest = Orbit::WorkspaceSnapshot.fingerprint(project_root: root)
  empty_signature = runtime.send(:delegation_signature, digest, options)
  pool.models = ["opencode-go/deepseek-v4.1-flash"]
  filled_signature = runtime.send(:delegation_signature, digest, options)
  assert(empty_signature != filled_signature,
         "a pool change changes the delegation signature and invalidates old recommendations")
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

# Evidence can be cached proactively, but without a task request it is not
# consumed by this observation; the ignored submission remains explicit.
fixture do |_root, record, _host, _checker, runtime|
  record.submit("model_evidence", "entries" => [evidence_entry.slice("provider", "model", "reasoning", "status")])
  runtime.tick(now: Time.now.to_f)
  assert(record.state.dig("jev", "evidence_status") == "unrequested",
         "an unsolicited evidence submission is not described as used")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("model_evidence_ignored") },
         "the ignored task submission remains auditable while the cache stays reusable")
end

# A recorded `unavailable` is a real answer: no new request, no second stage,
# no automatic hint, and manual delegation stays allowed.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                                                      evidence_cache: both_route_evidence(root, status: "unavailable"))
  runtime.tick(now: Time.now.to_f + 6)
  assert(host.messages.none? { |message| message.include?("model evidence request") },
         "an unexpired unavailable is not re-requested")
  assert(host.messages.none? { |message| message.include?("delegation hint") } && advisor.delegation_calls.empty?,
         "unavailable evidence never reaches the second stage or hints")
  assert(record.state.dig("jev", "evidence_status") == "unavailable", "status shows the unavailable evidence")
  assert(Orbit::TaskView.format(record).include?("模型证据不可用"), "the view names the unavailable evidence")

end

# A submission whose identities do not cover the pending comparison is a
# mismatch: the automatic chain stops without a second stage or a hint. A
# matching `unavailable` submission is recorded as unavailable, never as
# incomplete.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  cache = evidence_cache(root)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: cache)
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  assert(host.messages.count { |message| message.include?("model evidence request") } == 1,
         "precondition: the comparison is requested")

  wrong = { "provider" => "openai", "model" => "gpt-6-astra", "reasoning" => "unknown", "status" => "evidence" }
  candidate_unknown = evidence_entry(billing_route: "unknown")
  record.submit("model_evidence", "entries" => [wrong,
                                                candidate_unknown.slice("provider", "model", "reasoning", "billing_route", "status")])
  runtime.tick(now: now + 7)
  assert(record.state.dig("jev", "evidence_status") == "mismatch" && advisor.delegation_calls.empty?,
         "a mismatched submission never reaches the second stage and records the mismatch status")
  note = record.state.dig("jev", "evidence_note").to_s
  assert(note.include?("deepseek-v4.1-flash billing_route must be direct_api") && note.include?("submitted unknown"),
         "the mismatch note names the expected candidate route and the submitted route")
  status_text = Orbit::TaskView.format(record)
  assert(status_text.include?("提交的证据与待比较身份不一致") && status_text.include?("billing_route must be direct_api"),
         "ordinary status surfaces the bounded mismatch correction note")
  assert(host.messages.none? { |message| message.include?("delegation hint") }, "a mismatch never hints")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("model_evidence_mismatch") },
         "the mismatch is recorded")

  root_unavailable = evidence_entry(status: "unavailable", billing_route: "unknown")
  candidate_unavailable = evidence_entry(status: "unavailable")
  cache.record(root_unavailable)
  cache.record(candidate_unavailable)
  record.submit("model_evidence", "entries" => [root_unavailable, candidate_unavailable].map do |entry|
    entry.slice("provider", "model", "reasoning", "billing_route", "status")
  end)
  runtime.tick(now: now + 8)
  assert(record.state.dig("jev", "evidence_status") == "unavailable",
         "a matching unavailable submission is recorded as unavailable, not incomplete")
  assert(advisor.delegation_calls.empty? && host.messages.none? { |message| message.include?("delegation hint") },
         "unavailable evidence never reaches the second stage or hints")
end

# Valid cached evidence is judged directly; a member_fit below the threshold
# never hints and the decline is recorded.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.delegation_scores = { "member_fit" => 0.5, "parallel_gain" => 0.9 }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: both_route_evidence(root))
  runtime.tick(now: Time.now.to_f + 6)
  assert(advisor.delegation_calls.length == 1, "a cache hit runs the second stage without a request")
  assert(host.messages.none? { |message| message.include?("model evidence request") }, "a cache hit needs no request")
  assert(host.messages.none? { |message| message.include?("delegation hint") },
         "member_fit below the threshold never hints")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("delegation_declined") },
         "the declined judgment is recorded")
  assert(record.state.dig("jev", "delegation", "decision") == "declined",
         "a below-threshold second stage records decision declined")
end

# A second-stage service error is an explicit unavailable decision. It does
# not hint and does not forbid a later manual delegate.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.delegation_failure = Orbit::JevAdvisor::Error.new("stage two down")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: both_route_evidence(root))
  runtime.tick(now: Time.now.to_f + 6)
  assert(record.state.dig("jev", "delegation", "decision") == "unavailable" &&
         record.state.dig("jev", "delegation", "status") == "unavailable",
         "a failed second stage records decision unavailable")
  assessment = record.state.fetch("delegation_assessments").values.find { |entry| entry["error"] == "stage two down" }
  assert(assessment && assessment["decision"] == "unavailable",
         "the per-signature assessment keeps the unavailable decision")
  assert(record.state["delegation_hint"].nil? && host.messages.none? { |message| message.include?("delegation hint") },
         "an unavailable decision does not hint")
end

# Identities Orbit cannot establish stay unknown: no request, no hint, no host
# probing. This covers an unavailable Root model and a cross-host candidate.
class RuntimeUnknownModelHost < RuntimeHost
  def configured_model = ""
  def default_member_model = ""
end

fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeUnknownModelHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: evidence_cache(root, [evidence_entry]))
  runtime.tick(now: Time.now.to_f + 6)
  assert(host.messages.none? { |message| message.include?("model evidence request") } &&
         host.messages.none? { |message| message.include?("delegation hint") },
         "an unknown Root model stops the automatic chain")
  assert(record.state.dig("jev", "evidence_status") == "unknown", "unknown is explicit in status")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("model_evidence_unknown") },
         "the unknown gap is recorded")
end

fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: evidence_cache(root))
  runtime.tick(now: Time.now.to_f + 6)
  request = host.messages.find { |message| message.include?("model evidence request") }
  assert(request && request.include?("- candidate (omp): opencode-go/deepseek-v4.1-flash"),
         "the same-host candidate is compared with its kind")
  assert(record.state.dig("jev", "evidence_status") == "requested", "the omp candidate requests evidence")
end

# A cache hit uses the same bounded summary as a Root submission and records
# it once. The trace is not a delegation hint.
fixture(interval: 300) do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.delegation_scores = { "member_fit" => 0.15, "parallel_gain" => 0.30 }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: both_route_evidence(root))
  runtime.tick(now: Time.now.to_f + 6)
  runtime.tick(now: Time.now.to_f + 70)
  sent = advisor.delegation_calls
  assert(sent.length == 1, "a cache hit reaches the second stage once")
  used = events(record).select { |event| event["type"] == "model_evidence_used" }
  assert(used.length == 1 && used.first["summary"] == sent.first["model_evidence"] &&
         used.first["summary"] == record.state.dig("delegation_evidence", used.first["signature"], "summary"),
         "the cache-hit summary saved before the judgment matches the observation")
  assert(used.first.dig("summary", "root", "retrieved_at") &&
         used.first.dig("summary", "candidates", 0, "metrics", "output_tokens_per_second", "basis") == "median",
         "identity time and metric basis are kept")
  assert(host.messages.none? { |message| message.include?("delegation hint") } &&
         record.state["delegation_hint"].nil?,
         "using evidence is not a final delegation hint")
end

fixture do |root, record, _host, checker, _runtime|
  host = RuntimeTeamHost.new(root)
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.95)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
)
  runtime.tick(now: Time.now.to_f + 6)
  assert(host.messages.none? { |message| message.include?("delegation hint") },
         "no hint is sent without an allowed callable member")
end

# A check requested by the same Jev judgment wins: the advisory hint must
# not interrupt or precede it.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                                                      evidence_cache: both_route_evidence(root))
  runtime.tick(now: Time.now.to_f + 6)
  assert(checker.calls.last&.fetch(:role) == "process_reviewer", "the process check from this judgment starts")
  assert(host.messages.none? { |message| message.include?("delegation hint") },
         "the hint does not interrupt the process check")
  assert(record.state["delegation_hint"].nil?, "no hint is recorded when a check wins")
end

# Research responsive to a pending Orbit model-evidence request is authorized
# workflow, and the process check receives the bounded request facts.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("researching the requested model facts")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                   evidence_cache: evidence_cache(root))
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  request = record.state["evidence_request"]
  assert(request.is_a?(Hash) && request["resolved"].nil?, "precondition: an evidence request is pending")
  advisor.scores = { "stuck" => 0.95, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9 }
  runtime.tick(now: now + 70)
  process = checker.calls.last
  assert(process && process[:role] == "process_reviewer", "precondition: the stuck signal started a process check")
  fact = process[:context]["model_evidence_request"]
  assert(fact.is_a?(Hash) && fact["identities"] == request["identities"] &&
         fact["needed"] == request["needed"] && fact["at"] == request["at"] && fact["resolved"].nil?,
         "the process check receives the bounded pending evidence request")
  assert(fact.keys.sort == %w[at identities needed resolved] &&
         !JSON.generate(fact).include?("sources") && !JSON.generate(fact).include?("http"),
         "the pending request fact stays non-secret and bounded")
end

# A hint is only delivered after the same freshness re-check as check
# decisions; an observation that changed during the assessment drops it.
fixture(interval: 300) do |root, record, host, checker, _runtime|
  host.working("progress")
  advisor = RuntimeAdvisor.new("stuck" => 0.1, "off_track" => 0.1, "artifact_ready" => 0.1, "delegatable" => 0.9)
  advisor.on_call = -> { File.write(File.join(root, "artifact.txt"), "changed during assessment") }
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor,
                                                                      evidence_cache: both_route_evidence(root))
  now = Time.now.to_f
  runtime.tick(now: now + 6)
  assert(host.messages.none? { |message| message.include?("delegation hint") } && record.state["delegation_hint"].nil?,
         "a hint against a changed observation is dropped")

  advisor.on_call = nil
  runtime.tick(now: now + 70)
  assert(host.messages.count { |message| message.include?("delegation hint") } == 1,
         "a later fresh assessment delivers the hint")
end

# A registered native member is stopped from the task record. There is no
# allowlist left to exempt or block that stop.
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
  assert(record.state.fetch("checks").last["stale"] == false &&
         !record.state.fetch("checks").last["stale_reasons"].include?("host"),
         "an artifact check ignores a host-only digest change")
  runtime.tick(now: now + 61)
  assert(checker.calls.length == 1, "short checker suggestions do not restart full checks while Root executes")
  runtime.tick(now: now + 310)
  assert(checker.calls.length == 2, "the agreed interval still triggers the next full check")
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
  checker.result = answer("continue")
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
  notices = host.messages.select { |message| message.include?("final-check notice") }
  assert(notices.length == 1 && notices.first.include?("call Orbit stop"),
         "a clean manual final review wakes Root once with an explicit stop hand-off")
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
  checker.result = answer("complete")
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
  assert(host.messages.any? { |message| message.include?("final-check notice") },
         "the same finalization notice is used for a clean manual complete verdict")

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

# A manual complete that finishes while Root is still in a turn is kept
# for that exact version and delivered once when the turn actually completes.
fixture do |root, record, host, checker, runtime|
  now = Time.now.to_f
  host.working("still in the check turn")
  record.submit("check")
  runtime.tick(now: now)
  checker.result = answer("complete")
  runtime.tick(now: now + 1)
  assert(record.state["status"] != "complete" && record.state["finalization_notices"].empty?,
         "a busy Root does not receive the notice and is not marked complete")
  assert(record.state["pending_finalization"], "the reviewed version is retained for one hand-off")
  runtime.tick(now: now + 2)
  assert(checker.calls.length == 1 && record.state["finalization_notices"].empty?,
         "waiting for the turn does not start another model check")

  host.finish("turn-done")
  runtime.tick(now: now + 3)
  assert(record.state["finalization_notices"].length == 1 && record.state["pending_finalization"].nil?,
         "the same version is handed off once when Root is idle and completed")
  assert(checker.calls.length == 1, "the deferred hand-off does not rerun the checker")
  runtime.tick(now: now + 4)
  assert(host.messages.count { |message| message.include?("final-check notice") } == 1,
         "the deferred notice is not repeated")

  File.write(File.join(root, "artifact.txt"), "changed after a later review")
  host.working("editing again")
  record.submit("check")
  runtime.tick(now: now + 5)
  checker.result = answer("complete")
  runtime.tick(now: now + 6)
  File.write(File.join(root, "artifact.txt"), "changed before the hand-off")
  host.finish("edited")
  runtime.tick(now: now + 7)
  assert(record.state["finalization_notices"].length == 1,
         "a changed artifact does not receive the old notice")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("finalization_pending_stale"),
         "dropping the old hand-off is auditable")
  assert(checker.calls.length == 3, "the new version is checked once under the existing version-change rule")
end

# A version-bound pending hand-off must still reach an active Root within the
# bounded wait, and a repeated same-version hand-off must not reset the timer.
fixture(interval: 300) do |root, record, host, checker, runtime|
  now = Time.now.to_f
  host.working("waiting without ending the turn")
  record.submit("check")
  runtime.tick(now: now)
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
  assert(host.messages.count { |message| message.include?("final-check notice") } == 1,
         "the bounded fallback notice is sent exactly once")
  assert(record.state["status"] != "complete", "the notice alone never completes the task")
  runtime.tick(now: now + 120)
  assert(host.messages.count { |message| message.include?("final-check notice") } == 1,
         "later ticks do not repeat the delivered notice")
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
# the turn may finish normally, but the stop re-verifies the version and must
# record an ordinary stop, never completion, and leaves no delivery_digest.
fixture do |root, record, host, checker, runtime|
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
  File.write(File.join(root, "LATE.md"), "artifact changed during the delivery turn")
  host.finish("delivered")
  runtime.tick(now: now + 3)
  assert(record.state["status"] == "paused",
         "a version change during the queued turn stops ordinarily, never complete")
  assert(record.state["delivery_digest"].nil?,
         "no delivery version is recorded when the hand-off no longer matches")
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
  advisor.failure = Orbit::JevAdvisor::Error.new("service unavailable")
  runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: checker, advisor: advisor)
  now = Time.now.to_f
  runtime.tick(now: now + 1)
  File.write(File.join(root, "artifact.txt"), "changed despite service failure")
  runtime.tick(now: now + 10)
  assert(checker.calls.last.fetch(:role) == "reviewer", "failed Jev call falls back to full review")
  assert(record.state.dig("jev", "unavailable") == "service unavailable", "failure is recorded")
  assert(Orbit::TaskView.format(record).include?("JEV：不可用（service unavailable）"), "status shows JEV unavailable with its reason")
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
  assert(host.messages.none? { |message| message.include?('"id": "clue"') },
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
fixture(interval: 300) do |_root, record, _host, checker, runtime|
  now = Time.now.to_f
  runtime.tick(now: now)
  checker.result = answer("continue")
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
  assert(host.messages.length == 1 && record.state.dig("findings", "f-open", "status") == "open",
         "precondition: the first current finding reaches Root")

  host.finish("t1")
  runtime.tick(now: now + 2)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 3)
  assert(host.messages.length == 1, "the same still-open finding is not delivered twice")
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

  host.finish("t2")
  runtime.tick(now: now + 4)
  checker.result = answer("correct", findings: [finding])
  runtime.tick(now: now + 5)
  assert(record.state.dig("findings", "f-1", "status") == "resolved",
         "the same finding text on the same versions is not reopened")
  assert(File.readlines(File.join(record.path, "events.jsonl")).any? { |line| line.include?("finding_reopen_ignored") },
         "the ignored re-raise is recorded")
  assert(host.messages.length == 1, "an ignored re-raise does not re-notify Root")
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

# Legacy cache entries written before comparison.* rejection can still reach
# the second stage; the bounded summary must omit cross-identity claims and
# state the real validation scope.
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
  assert(advisor.delegation_calls.length == 1, "the legacy cached entry reaches one second-stage judgment")
  summary = advisor.delegation_calls.first.fetch("model_evidence")
  assert(summary.dig("root", "metrics").key?("output_tokens_per_second"), "real measurements are kept")
  assert(!JSON.generate(summary).include?("comparison."), "legacy cross-identity comparison metrics are omitted")
  assert(summary.fetch("note").include?("submitter-provided") &&
         summary.fetch("note").include?("not semantically verified"),
         "the note states structure-only validation")
end

puts "TASK_RUNTIME_TEST_PASS (deterministic, not real-model acceptance)"
