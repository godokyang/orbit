# frozen_string_literal: true

require "json"
require "tmpdir"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "../lib/orbit/task_record"
require_relative "../lib/orbit/work_unit"

# Work units (main proposal §5.2, ADR-009 §6.3): declared by the Root before a
# native dispatch, bound to one actual member/tool_call_id/model attempt, and
# finished with concrete verification. The store enforces non-empty objective/
# requirements/acceptance/escalation, a declared scope, existing dependencies,
# and refuses binding a unit declared against a stale task input version.
# It records the handoff only; member-side tool interception is the host's
# seam, not this class.
def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition
end

def refute(condition, message)
  assert(!condition, message)
end

def raises_error(message)
  yield
  raise "ASSERTION FAILED: expected WorkUnitStore::Error (#{message})"
rescue Orbit::WorkUnitStore::Error => failure
  assert(failure.message.length > 10, "error message must explain: #{message}")
  failure
end

@temp = Dir.mktmpdir("orbit-work-unit-")
@project = File.join(@temp, "project")
FileUtils.mkdir_p(@project)
ENTRY = File.expand_path("../scripts/orbit-work-unit", __dir__)

def new_record
  Orbit::TaskRecord.create(
    project_root: @project,
    instruction: "原始要求:完成工作单元",
    source: {},
    connection: { "provider" => "omp", "thread_id" => "root", "socket" => File.join(Dir.mktmpdir, "host.sock") },
    review: {}
  )
end

SPEC = {
  "objective" => "把工作单元登记接入派发",
  "requirements" => ["docs/plan/mixed-model-delivery-proposal.md#5.2", "ADR-009 §6.3"],
  "context" => "宿主只做工具层约束,持久化由本类负责",
  "decisions" => ["状态机保持 declared/bound/accepted/rejected/failed"],
  "allowed_paths" => ["lib/orbit"],
  "allowed_tools" => ["read", "edit", "bash"],
  "allowed_commands" => ["ruby tests/"],
  "acceptance" => "新测试通过且不破坏既有登记测试",
  "escalation" => "范围与既有任务冲突时停下并报告"
}.freeze

def store_for(record)
  Orbit::WorkUnitStore.new(record)
end

begin
  # 1. declare persists a complete unit bound to the current task input version.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  assert(unit["id"].match?(/\Awu-[0-9a-f]{16}\z/), "unit id missing: #{unit.inspect}")
  assert(unit["task_id"] == File.basename(record.path), "task id binding missing")
  assert(unit["input_digest"] == record.input_digest, "input digest binding missing")
  assert(unit["status"] == "declared", "new unit must be declared, got #{unit['status']}")
  assert(unit["scope"] == { "allowed_paths" => ["lib/orbit"], "allowed_tools" => %w[read edit bash],
                            "allowed_commands" => ["ruby tests/"] }, "scope must keep all three lists")
  assert(unit["dispatches"] == [] && unit["member_id"].nil?, "declared unit must not carry a member")
  stored = JSON.parse(File.read(File.join(record.path, "work-units.json")))
  assert(stored["format"] == "orbit-work-units-2" && stored["units"].key?(unit["id"]), "unit not persisted durably")
  assert(store.read(unit["id"])["objective"] == SPEC["objective"], "read must return the stored unit")
  assert(store.list.length == 1, "list must return the declared unit")
  events = File.read(File.join(record.path, "events.jsonl"))
  assert(events.include?("work_unit_declared"), "declare audit event missing")
  assert(unit["model_requirements"] == {}, "absent model_requirements must default to {}")
  assert(Orbit::WorkUnitStore.execution_role(unit) == "unspecified", "absent execution stays an unspecified pending unit")
  root_unit = store.declare(SPEC.merge("execution" => "root"))
  delegate_unit = store.declare(SPEC.merge("execution" => "delegate"))
  assert(root_unit["execution"] == "root" && Orbit::WorkUnitStore.execution_role(root_unit) == "root_self_execute",
         "root execution must be stored and classified")
  assert(delegate_unit["execution"] == "delegate" &&
         Orbit::WorkUnitStore.execution_role(delegate_unit) == "pending_dispatch",
         "delegate execution must be stored and classified")

  # 2. declare validation: objective/requirements/acceptance/escalation, scope, dependencies.
  record = new_record
  store = store_for(record)
  %w[objective acceptance escalation].each do |field|
    raises_error("empty #{field}") { store.declare(SPEC.merge(field => "  ")) }
  end
  raises_error("empty requirements") { store.declare(SPEC.merge("requirements" => [])) }
  raises_error("empty scope") do
    store.declare(SPEC.merge("allowed_paths" => [], "allowed_tools" => [], "allowed_commands" => []))
  end
  raises_error("unknown dependency") { store.declare(SPEC.merge("dependencies" => ["wu-0000000000000000"])) }
  raises_error("unknown field") { store.declare(SPEC.merge("owner" => "root")) }
  raises_error("bad execution") { store.declare(SPEC.merge("execution" => "self")) }
  raises_error("non tool name") { store.declare(SPEC.merge("allowed_tools" => ["rm -rf"])) }
  raises_error("empty member entrance") { store.declare(SPEC.merge("allowed_tools" => [], "allowed_commands" => [])) }
  raises_error("protected path") { store.declare(SPEC.merge("allowed_paths" => [".orbit"])) }
  raises_error("escaping path") { store.declare(SPEC.merge("allowed_paths" => ["../outside"])) }
  raises_error("bash without commands") { store.declare(SPEC.merge("allowed_commands" => [])) }
  raises_error("missing input material") { store.declare(SPEC.merge("input_materials" => ["lib/orbit/missing.md"])) }
  assert(store.list.empty?, "failed declares must not persist anything")

  # 3. unknown units: read is nil, bind/finish refuse.
  record = new_record
  store = store_for(record)
  assert(store.read("wu-1111111111111111").nil?, "unknown read must be nil")
  raises_error("bind unknown") { store.bind("wu-1111111111111111", member_id: "m1", tool_call_id: "c1", model: "x") }
  raises_error("finish unknown") do
    store.finish("wu-1111111111111111", status: "accepted", result: "r", verification: "v")
  end

  # 4. bind records the full handoff: member, native tool_call_id, model, dispatch history.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  bound = store.bind(unit["id"], member_id: "orbit-a1b2", tool_call_id: "call-7", model: "kimi-code/k3-256k")
  assert(bound["status"] == "bound", "bound status missing")
  assert(bound["member_id"] == "orbit-a1b2" && bound["tool_call_id"] == "call-7", "handoff identity missing")
  assert(bound["model"] == "kimi-code/k3-256k", "dispatch model missing")
  assert(bound["dispatches"].length == 1 && bound["dispatches"][0]["bound_at"], "dispatch history missing")
  refute(bound.key?("event_error"), "healthy task dir must not surface an event error")
  reloaded = store_for(record).read(unit["id"])
  assert(reloaded["status"] == "bound" && reloaded["tool_call_id"] == "call-7", "bind must be durable")

  # 5. bind refuses a live dispatch and a verified unit.
  raises_error("double bind") { store.bind(unit["id"], member_id: "m2", tool_call_id: "c2", model: "y") }

  # 6. stale requirement version: an amendment after declaration blocks binding.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  state = JSON.parse(File.read(File.join(record.path, "state.json")))
  File.write(File.join(record.path, "amendment-1.txt"), "补充要求")
  state["amendments"] = [{ "path" => "amendment-1.txt", "received_at" => Time.now.utc.iso8601 }]
  record.durable_write("state.json", JSON.pretty_generate(state))
  failure = raises_error("stale input") { store.bind(unit["id"], member_id: "m1", tool_call_id: "c1", model: "x") }
  assert(failure.message.include?("older task input"), "stale refusal must name the cause: #{failure.message}")
  assert(store.read(unit["id"])["status"] == "declared", "refused stale bind must leave the unit declared")

  # 7. dependencies must be accepted before the dependent binds.
  record = new_record
  store = store_for(record)
  first = store.declare(SPEC)
  second = store.declare(SPEC.merge("dependencies" => [first["id"]]))
  raises_error("unaccepted dependency") { store.bind(second["id"], member_id: "m1", tool_call_id: "c1", model: "x") }
  store.bind(first["id"], member_id: "m1", tool_call_id: "c1", model: "x")
  store.finish(first["id"], status: "rejected", result: "缺测试", verification: "ruby tests 未跑")
  raises_error("rejected dependency") { store.bind(second["id"], member_id: "m1", tool_call_id: "c2", model: "x") }
  store.bind(first["id"], member_id: "m1", tool_call_id: "c3", model: "x")
  store.finish(first["id"], status: "accepted", result: "完成", verification: "tests/work_unit_test.rb 通过")
  bound = store.bind(second["id"], member_id: "m2", tool_call_id: "c4", model: "x")
  assert(bound["status"] == "bound", "accepted dependency must unblock the dependent")

  # 8. finish: bound-only, evidence required, rejected units re-dispatch as a new attempt.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  raises_error("finish before bind") { store.finish(unit["id"], status: "accepted", result: "r", verification: "v") }
  store.bind(unit["id"], member_id: "m1", tool_call_id: "c1", model: "x")
  raises_error("empty verification") { store.finish(unit["id"], status: "accepted", result: "r", verification: " ") }
  raises_error("invalid status") { store.finish(unit["id"], status: "done", result: "r", verification: "v") }
  done = store.finish(unit["id"], status: "rejected", result: "越界写入", verification: "git diff 显示范围外文件")
  assert(done["status"] == "rejected" && done["result"] == "越界写入", "finish result missing")
  assert(done["verification"].include?("git diff"), "finish verification missing")
  assert(done["finished_at"], "finished_at missing")
  rebound = store.bind(unit["id"], member_id: "m2", tool_call_id: "c2", model: "x")
  assert(rebound["dispatches"].length == 2, "re-dispatch must append a new attempt")
  assert(rebound["member_id"] == "m2" && rebound["status"] == "bound", "re-dispatch identity missing")
  prior = rebound["dispatches"].first
  assert(prior.slice("member_id", "tool_call_id", "model") ==
         { "member_id" => "m1", "tool_call_id" => "c1", "model" => "x" } &&
         prior.slice("status", "result", "verification", "finished_at") ==
         done.slice("status", "result", "verification", "finished_at"),
         "a retry must hand over the previous rejection and evidence with its actual call identity")
  assert(rebound["result"].nil? && rebound["verification"].nil? && rebound["finished_at"].nil?,
         "a new active attempt must not masquerade as the prior finished result")
  store.finish(unit["id"], status: "failed", result: "服务不可用", verification: "调用返回供应商错误")
  # Reproduce a v2 record written before per-attempt outcomes were stored.
  document = JSON.parse(File.read(File.join(record.path, "work-units.json")))
  document["units"][unit["id"]]["dispatches"].last.delete_if do |key, _|
    %w[status result verification finished_at].include?(key)
  end
  record.durable_write("work-units.json", JSON.pretty_generate(document))
  store_for(record).bind(unit["id"], member_id: "m3", tool_call_id: "c3", model: "y")
  completed = store_for(record).finish(unit["id"], status: "accepted", result: "完成", verification: "测试通过")
  history = store_for(record).read(unit["id"])["dispatches"]
  assert(history.map { |attempt| attempt["status"] } == %w[rejected failed accepted] &&
         history[0] == prior && history[1]["result"] == "服务不可用" &&
         history[1]["tool_call_id"] == "c2" &&
         history.last.slice("status", "result", "verification", "finished_at") ==
         completed.slice("status", "result", "verification", "finished_at"),
         "reloading and switching models must preserve every known attempt outcome, including legacy latest outcomes")
  raises_error("re-bind accepted") { store.bind(unit["id"], member_id: "m3", tool_call_id: "c3", model: "x") }
  raises_error("double finish") { store.finish(unit["id"], status: "accepted", result: "r", verification: "v") }

  # 9. corrupt or foreign store fails closed instead of pretending empty.
  record = new_record
  store = store_for(record)
  store.declare(SPEC)
  File.write(File.join(record.path, "work-units.json"), "not json")
  raises_error("corrupt store") { store.list }
  other = new_record
  store_for(other).declare(SPEC)
  FileUtils.cp(File.join(other.path, "work-units.json"), File.join(record.path, "work-units.json"))
  raises_error("foreign store") { store.list }

  # 10. a failed audit event surfaces on the returned unit but never rolls the
  # durable write back or masquerades as a failed operation.
  record = new_record
  FileUtils.mkdir_p(File.join(record.path, "events.jsonl"))
  store = store_for(record)
  unit = store.declare(SPEC)
  assert(unit["event_error"].is_a?(String), "event failure must be surfaced: #{unit.inspect}")
  assert(store.read(unit["id"])["status"] == "declared", "unit must be durable despite the event failure")
  refute(store.read(unit["id"]).key?("event_error"), "event_error is operation output, not stored state")
  # 11. model_requirements (§6 task indicators): full hash round-trips; only the
  # declared keys and shapes pass, nothing is inferred from names.
  record = new_record
  store = store_for(record)
  requirements = {
    "relevant_indices" => %w[coding_index intelligence_index],
    "required_context_tokens" => 200_000,
    "required_input_modalities" => ["text"],
    "required_output_modalities" => ["text"],
    "required_parameters" => ["tools"],
    "require_measurement_date" => true
  }
  unit = store.declare(SPEC.merge("model_requirements" => requirements))
  assert(unit["model_requirements"] == requirements, "model_requirements must round-trip: #{unit['model_requirements'].inspect}")
  assert(store_for(record).read(unit["id"])["model_requirements"] == requirements, "model_requirements must be durable")
  raises_error("unknown model_requirements field") do
    store.declare(SPEC.merge("model_requirements" => { "speed" => 1 }))
  end
  raises_error("unknown index") do
    store.declare(SPEC.merge("model_requirements" => { "relevant_indices" => %w[coding_index speed_index] }))
  end
  unconstrained = store.declare(SPEC.merge("model_requirements" => { "relevant_indices" => [], "required_input_modalities" => [] }))
  assert(unconstrained["model_requirements"]["relevant_indices"] == [], "unclassified tasks remain facts-only")
  raises_error("non-positive context") do
    store.declare(SPEC.merge("model_requirements" => { "required_context_tokens" => 0 }))
  end
  raises_error("non-integer context") do
    store.declare(SPEC.merge("model_requirements" => { "required_context_tokens" => "200k" }))
  end
  raises_error("non-boolean measurement flag") do
    store.declare(SPEC.merge("model_requirements" => { "require_measurement_date" => "yes" }))
  end
  raises_error("non-string modalities") do
    store.declare(SPEC.merge("model_requirements" => { "required_input_modalities" => [nil] }))
  end
  assert(store.list.length == 2, "invalid model_requirements must not persist extra units")

  # 12. orbit-work-unit script: real subprocess declare/list/bind/finish/read,
  # one JSON object on stdin, one on stdout, exit 1 with ok:false on failure.
  record = new_record
  run = lambda do |action, payload|
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, record.path, action,
                                            stdin_data: JSON.generate(payload))
    assert(stderr.empty?, "script wrote to stderr: #{stderr}")
    [status.exitstatus, JSON.parse(stdout)]
  end
  code, out = run.call("declare", { "spec" => SPEC })
  assert(code == 0 && out["ok"] == true, "script declare failed: #{out.inspect}")
  assert(out["unit"]["id"].start_with?("wu-") && out["unit"]["status"] == "declared", "script declare unit missing")
  id = out["unit"]["id"]
  code, out = run.call("list", {})
  assert(code == 0 && out["units"].length == 1, "script list failed: #{out.inspect}")
  code, out = run.call("bind", { "id" => id, "member_id" => "orbit-x1", "tool_call_id" => "call-9", "model" => "k3" })
  assert(code == 0 && out["unit"]["status"] == "bound" && out["unit"]["tool_call_id"] == "call-9", "script bind failed: #{out.inspect}")
  code, out = run.call("finish", { "id" => id, "status" => "accepted", "result" => "done", "verification" => "subprocess test observed stdout" })
  assert(code == 0 && out["unit"]["status"] == "accepted", "script finish failed: #{out.inspect}")
  code, out = run.call("read", { "id" => id })
  assert(code == 0 && out["unit"]["status"] == "accepted", "script read failed: #{out.inspect}")
  code, out = run.call("read", { "id" => "wu-0000000000000000" })
  assert(code == 0 && out["ok"] == true && out["unit"].nil?, "missing read must be ok with null unit")
  code, out = run.call("bind", { "id" => "wu-0000000000000000", "member_id" => "m", "tool_call_id" => "c", "model" => "x" })
  assert(code == 1 && out["ok"] == false && out["reason"].is_a?(String), "unknown bind must fail with exit 1: #{out.inspect}")
  code, out = run.call("frobnicate", {})
  assert(code == 1 && out["ok"] == false, "unknown action must fail with exit 1")
  stdout, _stderr, status = Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, record.path, "list",
                                           stdin_data: "not json")
  assert(status.exitstatus == 1 && JSON.parse(stdout)["ok"] == false, "invalid stdin must fail with exit 1")

  # 13. declare captures the real artifact_root from the task workspace; a
  # submitter can neither supply it nor declare without a workspace source.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  expected_root = record.state.dig("workspace", "artifact_root")
  assert(unit["artifact_root"] == expected_root, "declare must capture the real artifact_root: #{unit.inspect}")
  raises_error("submitter artifact_root") { store.declare(SPEC.merge("artifact_root" => "/tmp/fake")) }
  bare = new_record
  state = JSON.parse(File.read(File.join(bare.path, "state.json")))
  state.delete("workspace")
  bare.durable_write("state.json", JSON.pretty_generate(state))
  raises_error("missing workspace source") { store_for(bare).declare(SPEC) }

  # 14. a workspace rebind after declaration blocks binding to the old root.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  state = JSON.parse(File.read(File.join(record.path, "state.json")))
  state["workspace"]["artifact_root"] = Dir.mktmpdir("orbit-other-root")
  record.durable_write("state.json", JSON.pretty_generate(state))
  failure = raises_error("rebound workspace") { store.bind(unit["id"], member_id: "m1", tool_call_id: "c1", model: "x") }
  assert(failure.message.include?("different workspace"), "rebind refusal must name the cause: #{failure.message}")
  assert(store.read(unit["id"])["status"] == "declared", "refused rebind must leave the unit declared")

  # 15. an amendment during execution: accepted is refused, rejected stays as evidence.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  store.bind(unit["id"], member_id: "m1", tool_call_id: "c1", model: "x")
  state = JSON.parse(File.read(File.join(record.path, "state.json")))
  File.write(File.join(record.path, "amendment-1.txt"), "执行中补充要求")
  state["amendments"] = [{ "path" => "amendment-1.txt", "received_at" => Time.now.utc.iso8601 }]
  record.durable_write("state.json", JSON.pretty_generate(state))
  failure = raises_error("stale accepted") { store.finish(unit["id"], status: "accepted", result: "完成", verification: "测试通过") }
  assert(failure.message.include?("older task input"), "stale accepted refusal must name the cause: #{failure.message}")
  assert(store.read(unit["id"])["status"] == "bound", "refused accepted must leave the unit bound")
  stale = store.finish(unit["id"], status: "rejected", result: "旧版产物", verification: "基于旧要求的 diff 留证")
  assert(stale["status"] == "rejected" && stale["result"] == "旧版产物", "old-version artifact must be recorded, not accepted")
  raises_error("stale re-dispatch") { store.bind(unit["id"], member_id: "m2", tool_call_id: "c2", model: "x") }

  # 16. a workspace rebind during execution: accepted is refused, failed stays as evidence.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  store.bind(unit["id"], member_id: "m1", tool_call_id: "c1", model: "x")
  state = JSON.parse(File.read(File.join(record.path, "state.json")))
  state["workspace"]["artifact_root"] = Dir.mktmpdir("orbit-other-root")
  record.durable_write("state.json", JSON.pretty_generate(state))
  failure = raises_error("rebound accepted") { store.finish(unit["id"], status: "accepted", result: "完成", verification: "测试通过") }
  assert(failure.message.include?("different workspace"), "rebound accepted refusal must name the cause: #{failure.message}")
  stale = store.finish(unit["id"], status: "failed", result: "工作区已切换", verification: "rebind 记录")
  assert(stale["status"] == "failed", "old-workspace failure must be recorded as evidence")
  raises_error("rebound re-dispatch") { store.bind(unit["id"], member_id: "m2", tool_call_id: "c2", model: "x") }

  # 17. the undelivered v1 format is invalidated explicitly, not migrated.
  record = new_record
  store = store_for(record)
  store.declare(SPEC)
  document = JSON.parse(File.read(File.join(record.path, "work-units.json")))
  document["format"] = "orbit-work-units-1"
  File.write(File.join(record.path, "work-units.json"), JSON.pretty_generate(document))
  failure = raises_error("v1 format") { store.list }
  assert(failure.message.include?("orbit-work-units-1"), "v1 refusal must name the dead format: #{failure.message}")

  # 18. program-observed execution failure: exact member+call on a bound unit
  # marks it failed inside the lock, keeps the real error/source/time on the
  # attempt, emits the audit event and leaves re-binding legal.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  store.bind(unit["id"], member_id: "m-fail", tool_call_id: "c-fail", model: "glm/x")
  error = { "stop_reason" => "error", "at" => Time.now.utc.iso8601,
            "error_status" => 429, "error_message" => "429 Go usage limit exceeded" }
  failed = store.record_execution_failure(member_id: "m-fail", tool_call_id: "c-fail",
                                          error: error, model: "glm/x")
  assert(failed["status"] == "failed" && failed["result"].include?("429"),
         "the exact bound attempt is failed with the real error")
  attempt = failed["dispatches"].last
  assert(attempt["failure_source"] == "native_turn_error" &&
         attempt.dig("failure_error", "error_status") == 429 &&
         attempt["failure_model"] == "glm/x" && attempt["finished_at"] &&
         attempt["status"] == "failed",
         "the attempt retains error, source, model and program time")
  assert(File.read(File.join(record.path, "events.jsonl")).include?("work_unit_execution_failed"),
         "the failure emits its audit event")
  rebound = store.bind(unit["id"], member_id: "m-second", tool_call_id: "c-second", model: "glm/x")
  assert(rebound["status"] == "bound" && rebound["dispatches"].length == 2 &&
         rebound["dispatches"].first.dig("failure_error", "error_status") == 429,
         "a failed unit re-binds legally with the failed attempt preserved")

  # 19. ownership guards: a foreign or stale tool call never touches the unit,
  # and a Root-verdict terminal unit is never overwritten.
  record = new_record
  store = store_for(record)
  unit = store.declare(SPEC)
  store.bind(unit["id"], member_id: "m-keep", tool_call_id: "c-keep", model: "glm/x")
  assert(store.record_execution_failure(member_id: "m-keep", tool_call_id: "c-other",
                                        error: { "stop_reason" => "error", "error_message" => "x" }).nil?,
         "a non-latest tool call releases nothing")
  assert(store.read(unit["id"])["status"] == "bound", "the unit stays bound for a foreign call")
  store.finish(unit["id"], status: "accepted", result: "done", verification: "tests")
  assert(store.record_execution_failure(member_id: "m-keep", tool_call_id: "c-keep",
                                        error: { "stop_reason" => "error", "error_message" => "x" }).nil?,
         "an accepted unit is never overwritten by a late program failure")
  assert(store.read(unit["id"])["status"] == "accepted", "the Root verdict survives")

  # 20. root self-execute units finish from declared without a member handoff,
  # while the evidence, current-version and dependency gates still hold.
  record = new_record
  store = store_for(record)
  prereq = store.declare(SPEC)
  root_unit = store.declare(SPEC.merge("execution" => "root", "dependencies" => [prereq["id"]]))
  raises_error("root accepted before dependency") do
    store.finish(root_unit["id"], status: "accepted", result: "r", verification: "tests passed")
  end
  raises_error("delegate finish before bind") do
    store.finish(store.declare(SPEC.merge("execution" => "delegate"))["id"],
                 status: "accepted", result: "r", verification: "v")
  end
  store.bind(prereq["id"], member_id: "m1", tool_call_id: "c1", model: "x")
  store.finish(prereq["id"], status: "accepted", result: "完成", verification: "tests/work_unit_test.rb 通过")
  done = store.finish(root_unit["id"], status: "accepted", result: "自执行完成",
                      verification: "局部回归通过：work_unit_test")
  assert(done["status"] == "accepted" && done["result"] == "自执行完成" && done["verification"].include?("回归"),
         "a root self-execute unit records its real result and evidence")
  assert(done["dispatches"].empty? && done["member_id"].nil? && done["tool_call_id"].nil?,
         "a root self-execute finish fabricates no member binding")
  failed = store.finish(store.declare(SPEC.merge("execution" => "root"))["id"],
                        status: "failed", result: "验证失败", verification: "调用返回供应商错误")
  assert(failed["status"] == "failed" && failed["result"] == "验证失败",
         "a root self-execute failure leaves a legal result without member binding")

  puts "work_unit_test: all assertions passed"
ensure
  FileUtils.remove_entry(@temp) if @temp && File.exist?(@temp)
end
