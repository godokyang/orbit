# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "socket"
require_relative "../lib/orbit/task_record"
require_relative "../lib/orbit/task_runtime"
require_relative "../lib/orbit/omp_entry"
require_relative "../lib/orbit/jev_advisor"
require_relative "../lib/orbit/jev_setup"
require_relative "../lib/orbit/model_evidence_cache"

module CliTest
  ENTRY = File.expand_path("../scripts/orbit", __dir__)
  module_function

  def assert(value, message)
    raise message unless value
  end

  def cli(*args, cwd: @project, success: true, env: {}, stdin_data: nil)
    base = { "XDG_CONFIG_HOME" => @temp, "XDG_CACHE_HOME" => @temp }
    out, err, status = Open3.capture3(base.merge(env), RbConfig.ruby, "--disable-gems", ENTRY, *args,
                                     chdir: cwd, stdin_data: stdin_data)
    assert(status.success? == success, "#{args.inspect}\n#{out}\n#{err}")
    out + err
  end

  def task(status = "running", **extra)
    record = Orbit::TaskRecord.create(project_root: @project, instruction: "实现用户要求并完成验证", source: {},
                                      connection: { "provider" => "omp", "thread_id" => "root", "socket" => File.join(@temp, "host.sock") },
                                      review: {})
    record.save(record.state.merge("status" => status).merge(extra.transform_keys(&:to_s)))
    record
  end

  def commands(record)
    Dir.glob(File.join(record.path, "inbox/*.json"))
  end

  def route_forecast_is_scoped_and_never_consumption
    record = task
    payload = { "scope" => "review", "candidates" => {
      "zhipu/glm-5.2" => { "route" => { "provider" => "zhipu", "model" => "glm-5.2",
        "reasoning" => "unknown", "billing_route" => "direct_api" }, "account_scope" => "verified-account",
        "plan" => nil, "prediction" => { "kind" => "declared_workload", "usage" => { "input" => 1000, "output" => 200 },
          "basis" => "scripted bounded workload assumption", "applies_to" => "this review" } }
    } }
    before = File.binread(File.join(record.path, "state.json"))
    response = JSON.parse(cli("route-resources", "forecast", record.path, "--file", "-",
                              stdin_data: JSON.generate(payload)))
    path = File.join(record.path, "route-cost-inputs.json")
    assert(response["ok"] && response.dig("forecast", "task_id") == record.state["id"] &&
           File.stat(path).mode & 0o777 == 0o600 && File.binread(File.join(record.path, "state.json")) == before &&
           commands(record).empty? && !File.exist?(File.join(record.path, "resource-calls.json")),
           "a forecast is private scoped input; it does not record consumption, dispatch or alter task state")
    record.save(record.state.merge("status" => "complete"))
    retained = File.binread(path)
    cli("route-resources", "forecast", record.path, "--file", "-", stdin_data: JSON.generate(payload), success: false)
    assert(File.binread(path) == retained, "settled tasks refuse a new forecast")
  end

  def single_task_from_project_subdirectory
    record = task
    child = File.join(@project, "src/deep")
    FileUtils.mkdir_p(child)
    text = cli("status", cwd: child)
    assert(text.include?("实现用户要求") && text.include?("running"), "readable requirement and status")
    assert(JSON.parse(cli("status", "--json", cwd: child)) == record.state, "machine output preserves raw state")
    text = cli("stop", "--reason", "用户停止", cwd: child)
    assert(text.include?("尚未确认停止"), "queued is not reported as stopped")
    command = JSON.parse(File.read(commands(record).fetch(0)))
    assert(command["type"] == "stop" && command["reason"] == "用户停止", "stop targets the project task")
    assert(record.state["status"] == "running", "CLI does not manufacture runtime state")
  end

  def multiple_tasks_require_explicit_selection
    first, second = task, task("stop_unconfirmed")
    list = JSON.parse(cli("status", "--json"))
    assert(list["tasks"].map { |t| t["id"] }.sort == [first, second].map { |t| t.state["id"] }.sort, "include unresolved stop in candidates")
    text = cli("stop", success: false)
    assert(text.include?(first.state["id"]) && text.include?(second.state["id"]), "ambiguous stop lists choices")
    assert(commands(first).empty? && commands(second).empty?, "ambiguous stop performs no action")
    result = JSON.parse(cli("stop", first.state["id"][0, 8], "--json"))
    assert(result["task_directory"] == first.path && commands(second).empty?, "unique prefix selects only the requested task")
  end

  def completed_and_absent_tasks
    assert(JSON.parse(cli("status", "--json"))["tasks"].empty?, "empty project has no selected task")
    cli("stop", success: false)
    latest = task("complete", created_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-03T00:00:00Z")
    task("paused", created_at: "2026-01-02T00:00:00Z", finished_at: "2026-01-02T01:00:00Z")
    assert(JSON.parse(cli("status", "--json"))["id"] == latest.state["id"], "status shows most recent settled task")
    cli("stop", success: false)
    nested = File.join(@project, "other-project")
    FileUtils.mkdir_p(File.join(nested, ".git"))
    assert(JSON.parse(cli("status", "--json", cwd: nested))["tasks"].empty?, "nested project does not inherit parent tasks")
  end

  def status_separates_check_activity_from_task_completion
    record = task("running")
    text = cli("status", record.path)
    assert(text.include?("检查状态：尚无检查结果") && text.include?("下一动作：等待当前助手（Root）继续执行"),
           "a running task with no check facts is idle and still with Root")
    assert(text.include?("裁定记录：0 条"), "status keeps adjudication history separate from open work")
    assert(text.include?("执行中，尚未完成验收") && !text.include?("不是任务完成"),
           "idle does not claim the task is complete")

    record.save(record.state.merge(
      "checks" => [{ "role" => "reviewer", "stale" => false, "result" => { "verdict" => "complete", "reason" => "检查通过" } }]
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：最近检查结论 complete（检查结论，不是任务完成）"),
           "a complete verdict stays a check result")
    assert(text.include?("状态：执行中，尚未完成验收（running）"), "the task status stays running")

    record.save(record.state.merge(
      "check_observations" => { "obs-1" => { "status" => "in_flight" } },
      "next_check_at" => "2026-09-22T00:00:00Z", "next_check_trigger" => "manual_check", "next_check_manual" => true
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：独立检查进行中（等待结果即可，无需重复请求检查）") &&
           !text.include?("检查状态：最近检查结论"),
           "an in-flight check is running and is not the task verdict")

    record.save(record.state.merge("check_observations" => { "obs-1" => { "status" => "finished" } }))
    text = cli("status", record.path)
    assert(text.include?("检查状态：手动终检已排队（不是任务完成）") && text.include?("下一动作：手动检查已排队"),
           "a manual next check is queued, not a completed task")

    record.save(record.state.merge("next_check_trigger" => "rebind", "next_check_basis" => "工作区重新绑定", "next_check_manual" => false))
    text = cli("status", record.path)
    assert(text.include?("下一动作：重新绑定工作区"),
           "a workspace rebind outranks a manual queue")

    record.save(record.state.merge(
      "status" => "needs_user", "stop_reason" => "请确认绑定",
      "checks" => [{ "stale" => true, "stale_reasons" => ["workspace"], "result" => { "verdict" => "complete", "reason" => "旧检查" } }]
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：最近检查已过期（未采纳）") && text.include?("下一动作：需要用户处理"),
           "needs_user outranks rebind, and a stale verdict is not task completion")
    assert(!text.include?("检查状态：最近检查结论"),
           "a settled stale check is not shown as a current complete verdict")

    record.save(record.state.merge(
      "status" => "running", "next_check_at" => "2026-09-23T00:00:00Z", "next_check_trigger" => "timer",
      "next_check_basis" => "约定检查间隔", "next_check_manual" => false,
      "checks" => [{ "role" => "reviewer", "stale" => false, "result" => { "verdict" => "continue", "reason" => "继续" } }],
      "findings" => {}
    ))
    text = cli("status", record.path)
    assert(text.include?("下一动作：检查已安排"),
           "a scheduled check stays arranged, not a completed task")

    record.save(record.state.merge("next_check_at" => nil, "next_check_trigger" => nil, "next_check_basis" => nil,
                                   "checks" => [{ "role" => "reviewer", "stale" => true, "stale_reasons" => ["workspace"],
                                                  "result" => { "verdict" => "correct", "reason" => "旧工作区" } }]))
    text = cli("status", record.path)
    assert(text.include?("检查状态：最近检查已过期（未采纳）") && text.include?("下一动作：重新绑定工作区"),
           "a workspace-stale check asks for rebind without calling the task complete")

    record.save(record.state.merge(
      "checks" => [{ "role" => "reviewer", "stale" => true, "result" => { "verdict" => "correct", "reason" => "过期" } }],
      "findings" => { "gap" => { "status" => "open" } }
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：最近检查已过期（未采纳）") && text.include?("待处理问题：开放问题 1 条"),
           "a stale check retains its still-open finding")
    assert(!text.include?("下一动作：重新绑定工作区"), "a stale check without a workspace reason is not a rebind")

  end
  def terminal_status_never_prompts_recheck_of_stopped_tasks
    # The 639… shape (kickoff ④): a wrong not_ready reason survives an
    # adjudication that overturned it, the task then stops ordinarily. The
    # status must not ask a stopped task for artifacts or a re-check.
    record = task("paused",
                  stop_confirmation: { "confirmed" => true },
                  completion_readiness: { "status" => "not_ready", "reason" => "No deliverable exists for this instruction" },
                  decisions: [{ "id" => "d1", "outcome" => "root", "decided_at" => "2026-09-28T12:54:57Z" }],
                  checks: [{ "role" => "adjudicator", "stale" => false,
                             "result" => { "verdict" => "complete", "reason" => "Root 胜" } }])
    text = cli("status", record.path)
    assert(text.include?("已暂停并确认停止（paused）"), "the task is still reported as paused")
    assert(text.lines.any? { |line| line.start_with?("下一动作：") && line.include?("新任务") },
           "a paused task directs new work to a new task")
    assert(!text.include?("补齐实际交付") && !text.include?("再重检") && !text.include?("No deliverable exists"),
           "the overturned not_ready reason never becomes a next action")
    assert(text.lines.any? { |line| line.start_with?("用户处理：") && line.include?("无需用户操作") },
           "a confirmed stop needs no user action")
    assert(text.include?("争议裁定记录") && text.include?("不是交付终检"),
           "an adjudicator result remains a dispute record rather than a final delivery review")

    # Same terminal rule without any adjudication: a plain stop with leftover
    # readiness and an open finding must not ask the stopped record for work.
    plain = task("paused",
                 stop_confirmation: { "confirmed" => true },
                 completion_readiness: { "status" => "not_ready", "reason" => "尚无交付" },
                 findings: { "gap" => { "status" => "open" } })
    text = cli("status", plain.path)
    assert(text.lines.any? { |line| line.start_with?("下一动作：") && line.include?("新任务") },
           "an ordinary stop also directs new work to a new task")
    assert(!text.include?("先处理检查问题") && !text.include?("补齐实际交付"),
           "leftover findings and readiness do not become work for a stopped task")

    done = task("complete", stop_confirmation: { "confirmed" => true },
                            completion_readiness: { "status" => "not_ready", "reason" => "旧理由" })
    text = cli("status", done.path)
    assert(text.include?("下一动作：无") && text.include?("无需用户操作"),
           "a complete task stays terminal with nothing to do")
  end


  def status_usage_sums_known_roles_and_excludes_root_cumulative
    record = task(
      "running",
      checks: [
        { "role" => "reviewer", "usage" => { "input_tokens" => 100, "output_tokens" => 10, "cached_input_tokens" => 80 } },
        { "role" => "reviewer", "usage" => { "input_tokens" => 40, "output_tokens" => 5 } },
        { "role" => "process_reviewer", "usage" => { "input_tokens" => 7, "output_tokens" => 1 } },
        { "role" => "adjudicator", "usage" => { "input_tokens" => 3, "output_tokens" => 2 } }
      ],
      jev: {
        "usage" => { "input_tokens" => 11, "output_tokens" => 4 },
        "delegation" => { "usage" => { "input_tokens" => 99, "output_tokens" => 99 } }
      },
      usage: {
        "root_session_cumulative" => 99_999, "check_tokens" => 1, "tokens" => 1,
        "jev_stage1" => { "input_tokens" => 30, "output_tokens" => 8 },
        "jev_stage2" => { "input_tokens" => 20, "output_tokens" => 6 }
      }
    )
    text = cli("status", record.path)
    assert(text.include?("独立检查 reviewer：输入 140，输出 15，合计 155"), "reviewer calls sum; cached input is not added")
    assert(text.include?("独立检查 process_reviewer：输入 7，输出 1，合计 8"), "process reviewer is separate")
    assert(text.include?("独立检查 adjudicator：输入 3，输出 2，合计 5"), "adjudicator is separate")
    assert(text.include?("JEV 第一阶段：输入 30，输出 8，合计 38"), "stage 1 uses the aggregate, not the latest assessment")
    assert(text.include?("JEV 委派第二阶段：输入 20，输出 6，合计 26"), "stage 2 uses the aggregate, not the latest assessment")
    assert(!text.include?("JEV 第一阶段：输入 11") && !text.include?("JEV 委派第二阶段：输入 99"),
           "latest JEV assessments do not replace the aggregates")
    assert(text.include?("Root 会话累计：99999（非任务增量）"), "root cumulative is labeled as not this task")
    assert(text.include?("可核算总计：输入 200，输出 32，合计 232（不含 Root 会话累计）"),
           "the accountable total adds only complete components")
    assert(!text.include?("99999") || text.include?("非任务增量"), "root cumulative is not presented as the task total")
    assert(!text.include?("cached_input_tokens") && !text.include?("输入 180"), "cached tokens are not folded into input")
  end

  def status_usage_is_unknown_when_any_component_is_missing
    record = task(
      "running",
      checks: [
        { "role" => "reviewer", "usage" => { "input_tokens" => 100 } },
        { "role" => "process_reviewer", "usage" => nil },
        { "role" => "adjudicator", "usage" => { "input_tokens" => 3, "output_tokens" => 2 } },
        { "usage" => { "input_tokens" => 9, "output_tokens" => 9 } }
      ],
      jev: {
        "usage" => { "input_tokens" => 11, "output_tokens" => 4 },
        "delegation" => { "usage" => { "input_tokens" => 20, "output_tokens" => 6 } }
      },
      usage: {
        "root_session_cumulative" => 5000, "check_tokens" => 999,
        "jev_stage2" => { "input_tokens" => 5, "output_tokens" => 1, "incomplete" => true }
      }
    )
    text = cli("status", record.path)
    assert(text.include?("独立检查 reviewer：未知"), "output omitted from a reviewer call is unknown")
    assert(text.include?("独立检查 process_reviewer：未知"), "a recorded check without usage is unknown")
    assert(text.include?("独立检查 adjudicator：输入 3，输出 2，合计 5"), "a complete role still displays its own sum")
    assert(text.include?("JEV 第一阶段：输入 11，输出 4，合计 15"), "an old record still reads the latest stage 1 assessment")
    assert(text.include?("JEV 委派第二阶段：未知"), "an incomplete stage 2 aggregate is unknown")
    assert(!text.include?("JEV 委派第二阶段：输入 5") && !text.include?("JEV 委派第二阶段：输入 20"),
           "incomplete aggregate tokens and the latest assessment are not shown as the stage total")
    assert(text.include?("独立检查未标注角色：未知"), "a check without a role is not assigned")
    assert(text.include?("Root 会话累计：5000（非任务增量）"), "root cumulative stays visible and excluded")
    assert(text.include?("可核算总计：未知（缺少 独立检查 reviewer、独立检查 process_reviewer、独立检查未标注角色、JEV 委派第二阶段）"),
           "the total names every missing component")
    assert(!text.include?("可核算总计：输入"), "a partial or root figure is not promoted to the task total")
  end

  def status_reads_late_final_receipts_without_changing_terminal_state
    record = task("complete", stop_confirmation: { "confirmed" => true },
                  usage: { "resource_calls" => { "call_count" => 0 } })
    original = File.binread(File.join(record.path, "state.json"))
    ledger = Orbit::ResourceCallLedger.new(task_path: record.path, task_id: record.state.fetch("id"))
    ledger.record(call_id: "late-final-call", role: "root", phase: "root_execution", status: "completed",
                  provider: "fixture", actual_model: "actual", usage: { "input" => 41, "output" => 7 },
                  usage_units: { "input" => "token", "output" => "token" }, usage_source: "native_message")
    visible = JSON.parse(cli("status", record.path, "--json"))
    assert(visible["status"] == "complete" && visible.dig("stop_confirmation", "confirmed") == true,
           "a late receipt does not reopen execution or revoke confirmed stop")
    assert(visible.dig("usage", "resource_calls", "call_count") == 1, "the display reads the final ledger instead of cached zero calls")
    text = cli("status", record.path)
    assert(text.include?("input 41 token") && text.include?("output 7 token"), "final reported categories are visible without being summed")
    summary = JSON.parse(cli("session-summary", "--thread", "root"))
    assert(summary["tasks"].first.dig("resource_calls", "call_count") == 1, "session summary includes the same finalized task ledger")
    assert(File.binread(File.join(record.path, "state.json")) == original && commands(record).empty?,
           "queries do not mutate authoritative state or queue execution")
  end

  def status_exposes_pending_and_corrupt_accounting_as_unknown
    record = task("paused", usage: { "resource_calls" => { "call_count" => 0 } })
    File.write(File.join(record.path, "native-model-calls.json"), JSON.generate(
      "schema_version" => "orbit-native-model-calls-v1", "task_id" => record.state.fetch("id"),
      "calls" => { "pending-call" => { "finalized" => false } }, "gaps" => []))
    pending = JSON.parse(cli("status", record.path, "--json"))
    assert(pending.dig("usage", "native_call_observations", "pending_calls") == 1,
           "an observed pending invocation remains unknown after task stop")
    assert(cli("status", record.path).include?("原生调用尚无最终用量：1"), "pending usage is never displayed as zero consumption")
    original = File.binread(File.join(record.path, "state.json"))
    File.write(File.join(record.path, "resource-calls.json"), "{corrupt")
    broken = JSON.parse(cli("status", record.path, "--json"))
    assert(broken.dig("usage", "resource_calls", "coverage") == "unreadable" &&
           broken.dig("usage", "resource_calls", "call_count").nil?, "a corrupt ledger has no asserted count")
    assert(cli("status", record.path).include?("已记录调用：未知"), "read failures are visible without stale totals")
    assert(File.binread(File.join(record.path, "state.json")) == original, "the display never repairs or overwrites accounting evidence")
  end

  def stale_result_and_user_action
    record = task("needs_user", stop_reason: "请确认需求文档中的支付规则", next_check_at: "2026-01-01T00:00:00Z",
                  checks: [{ "stale" => true, "result" => { "verdict" => "complete", "reason" => "旧版检查" } }])
    text = cli("status")
    assert(text.include?("已过期，未采纳") && text.include?("请确认需求文档中的支付规则"), "stale result and required user action remain distinct")
    assert(!text.include?("2026-01-01"), "settled task has no upcoming check")
    cli("stop", record.path, success: false)
    assert(commands(record).empty?, "settled task cannot be stopped again")
    record.save(record.state.merge("status" => "stop_unconfirmed", "stop_reason" => "用户停止", "error" => "成员仍在执行"))
    assert(cli("status").include?("成员仍在执行"), "show the actual stop failure, not only the stop request reason")
    record.save(record.state.merge(
      "status" => "complete", "stop_reason" => nil, "error" => nil, "next_check_at" => nil,
      "next_check_basis" => "等待 Root 根据有效终检收尾",
      "stop_confirmation" => { "confirmed" => true, "thread_id" => "root", "status_after" => "idle" },
      "checks" => [{ "role" => "reviewer", "stale" => false, "manual" => true,
                     "result" => { "verdict" => "complete", "reason" => "已通过" } }]
    ))
    text = cli("status", record.path)
    assert(text.include?("下一动作：无") && text.include?("下次检查：未安排") &&
           !text.include?("等待 Root 根据有效终检收尾"),
           "completed work must not retain a next-check reason instructing Root to finish again")
  end

  # A failed run may have confirmed that execution stopped; that is different
  # from a failure whose stop result still needs verification.
  def failed_stop_confirmation_is_reported
    record = task("failed", error: "读取角色规则库失败")
    text = cli("status")
    assert(text.include?("运行失败，停止情况需核实") && text.include?("读取角色规则库失败"),
           "a missing stop confirmation keeps the verification prompt")
    record.save(record.state.merge("stop_confirmation" => { "confirmed" => false, "scope" => "原会话" }))
    assert(cli("status").include?("运行失败，停止情况需核实"), "an explicit unconfirmed stop still needs verification")
    record.save(record.state.merge("stop_confirmation" => { "confirmed" => true, "thread_id" => "root", "status_after" => "idle" }))
    text = cli("status")
    assert(text.include?("运行失败，停止已确认") && text.include?("请查看下方运行错误") && !text.include?("停止情况需核实"),
           "a confirmed stop is reported as such instead of an unverified stop")
  end

  def doctor_without_connection_or_dependencies
    report = JSON.parse(cli("doctor", "--json"))
    assert(report["environment_ready"] && report.dig("connection", "ready").nil? && !report["ready"], "installed dependencies do not prove a connection")
    assert(!report.dig("credentials", "verified"), "no model or quota verification claimed")
    report = JSON.parse(cli("doctor", "--json", env: { "PATH" => @temp }, success: false))
    assert(!report["environment_ready"] && report["dependencies"].any? { |d| !d["ready"] && d["next_step"] }, "missing dependencies have an actionable diagnosis")
  end

  def doctor_reads_existing_native_connection
    record = task
    socket = record.state.dig("connection", "socket")
    server = worker = nil
    %w[omp].each do |provider|
      record.save(record.state.merge("connection" => record.state["connection"].merge("provider" => provider)))
      server = UNIXServer.new(socket)
      requests = []
      worker = Thread.new do
        2.times do
          peer = server.accept
          request = JSON.parse(peer.gets)
          requests << request
          peer.puts(JSON.generate("result" => { "cwd" => File.realpath(@project), "status" => "idle" }))
          peer.close
        end
      end
      report = JSON.parse(cli("doctor", record.path, "--json"))
      assert(worker.join(3), "diagnostic requests completed")
      assert(report["ready"] && report.dig("connection", "project") == File.realpath(@project), "native state read verifies the connection")
      assert(requests.all? { |r| r["method"] == "state" && r["session"] == "root" }, "diagnostics sends only read requests")
      server.close
      File.unlink(socket)
    end
    report = JSON.parse(cli("doctor", record.path, "--json", success: false))
    assert(report.dig("connection", "ready") == false && report.dig("connection", "next_step"), "closed host yields a connection error")
  ensure
    server&.close unless server&.closed?
    worker&.kill if worker&.alive?
    worker&.join
  end

  # A record whose runtime process is gone cannot consume queued commands; an
  # explicit stop must go through the confirmed retry path instead.
  def stop_retries_when_recorded_runtime_is_gone
    dead = Process.spawn(RbConfig.ruby, "--disable-gems", "-e", "exit 0")
    Process.wait(dead)
    record = task("running", runtime_pid: dead)
    socket = record.state.dig("connection", "socket")
    server = UNIXServer.new(socket)
    worker = Thread.new do
      2.times do
        peer = server.accept
        request = JSON.parse(peer.gets)
        result = request["method"] == "state" ? { "cwd" => File.realpath(@project), "status" => "idle" } : { "confirmed" => true }
        peer.puts(JSON.generate("result" => result))
        peer.close
      end
    end
    result = JSON.parse(cli("stop", record.path, "--json"))
    assert(worker.join(3), "retry reconnects the native Root")
    assert(result["status"] == "paused", "a dead runtime record still accepts an explicit confirmed stop")
    assert(commands(record).empty?, "retry performs cleanup instead of queueing an unconsumed command")
  ensure
    server&.close unless server&.closed?
    worker&.kill if worker&.alive?
    worker&.join
  end

  # An abnormal exit removes runtime_pid but leaves finished_at and a
  # non-terminal status; stop must use the confirmed retry path instead of
  # queueing a command no process remains to consume.
  def stop_retries_when_runtime_exited_without_terminal_status
    record = task("running", finished_at: "2026-09-24T17:07:33Z")
    refused = JSON.parse(cli("stop", record.path, "--complete", "--json"))
    assert(refused["status"] == "rejected" && refused["reason"] == "runtime_unavailable" &&
           commands(record).empty?,
           "a completion intent on a gone runtime is refused instead of queueing an unconsumed command")
    socket = record.state.dig("connection", "socket")
    server = UNIXServer.new(socket)
    worker = Thread.new do
      2.times do
        peer = server.accept
        request = JSON.parse(peer.gets)
        result = request["method"] == "state" ? { "cwd" => File.realpath(@project), "status" => "idle" } : { "confirmed" => true }
        peer.puts(JSON.generate("result" => result))
        peer.close
      end
    end
    result = JSON.parse(cli("stop", record.path, "--json"))
    assert(worker.join(3), "retry reconnects the recorded native Root")
    assert(result["status"] == "paused", "a recorded exit without a terminal status still accepts an explicit confirmed stop")
    assert(commands(record).empty?, "retry performs cleanup instead of queueing an unconsumed command")
  ensure
    server&.close unless server&.closed?
    worker&.kill if worker&.alive?
    worker&.join
  end

  # A completion intent is adjudicated synchronously before anything is queued;
  # a plain stop keeps the ordinary pause path and a current notice queues the
  # hand-off for the runtime recheck.
  def completion_stop_requires_a_current_notice
    record = task("running")
    rejected = JSON.parse(cli("stop", record.path, "--complete", "--json"))
    assert(rejected["status"] == "rejected" && rejected["reason"] == "no_current_finalization_notice",
           "a completion without a current notice is refused with its machine reason")
    assert(commands(record).empty? && record.state["status"] == "running" &&
           File.read(File.join(record.path, "events.jsonl")).include?("completion_stop_rejected"),
           "a refused completion queues nothing, changes no state, and is auditable")

    state = record.state
    key = Digest::SHA256.hexdigest(JSON.generate([
      state.fetch("project_root"),
      Orbit::WorkspaceSnapshot.fingerprint(project_root: state.fetch("project_root")), record.input_digest(state)
    ]))
    qualified = state.merge(
      "finalization_notices" => { key => { "check" => 1, "at" => "2026-09-25T00:00:00Z" } },
      "completion_readiness" => {
        "status" => "ready", "artifact_root" => state.fetch("project_root"),
        "artifact_digest" => Orbit::WorkspaceSnapshot.fingerprint(project_root: state.fetch("project_root")),
        "input_digest" => record.input_digest(state), "notice_key" => key
      }
    )
    record.save(qualified)
    Orbit::RequirementCoverage.new(record: record).record(check_id: "1", kind: "artifact", role: "reviewer",
      coverage: { "complete" => true, "items" => [
        { "requirement" => "实现用户要求并完成验证", "status" => "verified", "evidence" => "Scripted current fixture validation" }
      ] }, input_digest: record.input_digest(qualified), artifact_digest: qualified.dig("completion_readiness", "artifact_digest"),
      artifact_root: qualified.fetch("project_root"))
    accepted = JSON.parse(cli("stop", record.path, "--complete", "--json"))
    fresh = commands(record)
    assert(accepted["status"] == "queued" && fresh.length == 1 && JSON.parse(File.read(fresh.first))["complete"] == true,
           "a completion backed by the current notice is queued for the runtime recheck")

    plain = JSON.parse(cli("stop", record.path, "--json"))
    added = commands(record) - fresh
    assert(plain["status"] == "queued" && added.length == 1 && JSON.parse(File.read(added.first))["complete"].nil?,
           "a plain stop without the marker stays the ordinary pause path")

    { "open_findings" => { "findings" => { "gap" => { "status" => "open" } } },
      "pending_clue_recheck" => { "recheck" => { "check" => 1, "findings" => [{ "id" => "clue" }] } },
      "checker_cleanup_unverified" => { "cleanup_error" => "Checker stop unconfirmed" } }.each do |code, extra|
      record.save(qualified.merge(extra))
      reply = JSON.parse(cli("stop", record.path, "--complete", "--json"))
      assert(reply["reason"] == code, "#{code} blocks completion instead of letting an invalid task finish")
    end

    # A blocker outranks the missing notice: a Zeen-like task with an open
    # finding and no current notice is told to fix first, not to re-check.
    record.save(state.merge("findings" => { "gap" => { "status" => "open" } }))
    mixed = JSON.parse(cli("stop", record.path, "--complete", "--json"))
    assert(mixed["reason"] == "open_findings", "open findings outrank a missing final-check notice")

  end

  def doctor_states_single_host_entry_and_omp_checker
    report = JSON.parse(cli("doctor", "--json"))
    assert(report.dig("omp_entry", "entry") == "orbit omp" && report.dig("omp_entry", "extension_ready"),
           "doctor states the implemented explicit OMP entry")
    assert(report.dig("omp_entry", "minimum_version") == Orbit::OmpEntry::MINIMUM_OMP_VERSION &&
           report.dig("omp_entry", "pinned_version") == Orbit::OmpEntry::MINIMUM_OMP_VERSION,
           "doctor states the minimum OMP version and preserves the existing field")
    if report.dig("omp_entry", "omp_path")
      detected = report.dig("omp_entry", "version")
      assert(report.dig("omp_entry", "version_ready") == (detected && Orbit::OmpEntry.supported_version?(detected)),
             "doctor reports the detected OMP version against the minimum")
    end
    assert(report.dig("checker", "component") == "omp-reviewer" && report.dig("checker", "status") == "active",
           "doctor labels the single OMP checker as the active component")
    assert(report.dig("migration", "phase") == "M4" && !report.key?("members") && !report.key?("review_model"),
           "doctor does not advertise an old-host member roster as the single-host state")
    text = cli("doctor")
    assert(text.include?("OMP 显式入口") && text.include?("检查组件：omp-reviewer（active）") && text.include?("迁移状态："),
           "doctor text keeps the same single-host statement")
    assert(!text.include?("成员名单") && !text.include?("不可调用成员"),
           "doctor text no longer lists old-host member kinds")

    # An existing task still verifies its native connection; that does not
    # change the migration statement.
    record = task
    socket = record.state.dig("connection", "socket")
    server = UNIXServer.new(socket)
    worker = Thread.new do
      2.times do
        peer = server.accept
        request = JSON.parse(peer.gets)
        peer.puts(JSON.generate("result" => { "cwd" => File.realpath(@project), "status" => "idle" })) if request["method"] == "state"
        peer.close
      end
    end
    verified = JSON.parse(cli("doctor", record.path, "--json"))
    assert(worker.join(3), "verified session reads native state")
    assert(verified.dig("connection", "ready") == true && verified.dig("migration", "phase") == "M4",
           "a verified connection does not change the migration statement")
  ensure
    server&.close unless server&.closed?
    worker&.kill if worker&.alive?
    worker&.join
  end

  def rebind_workspace_queues_and_legacy_status_reads_project_root
    record = task
    canonical = File.realpath(@project)
    text = cli("status", record.path)
    assert(text.include?("产物目录：#{canonical}") && text.include?("绑定时间：#{record.state.dig('workspace', 'bound_at')}") &&
           text.include?("最近重新绑定：无"), "status shows the artifact root and binding time")
    assert(cli("rebind-workspace", "--help").include?("amend / dispute"), "rebind help keeps text from switching paths")
    queued = JSON.parse(cli("rebind-workspace", record.path, @project, "--reason", "confirm current"))
    command = JSON.parse(File.read(commands(record).fetch(0)))
    assert(queued["status"] == "queued" && command["type"] == "rebind_workspace" && command["path"] == canonical &&
           command["reason"] == "confirm current" && command.dig("source", "command") == "rebind-workspace",
           "rebind queues the canonical path with source and reason")
    assert(record.state.dig("workspace", "history").empty?, "queueing rebind does not write workspace history")
    File.unlink(commands(record).fetch(0))

    other = File.join(@temp, "elsewhere")
    FileUtils.mkdir_p(other)
    rejected = cli("rebind-workspace", record.path, other, "--reason", "leave", success: false)
    assert(rejected.include?("non-Git") && commands(record).empty?, "a different non-Git path is rejected before queueing")

    state = record.state
    state.delete("workspace")
    record.save(state)
    legacy = cli("status", record.path)
    assert(legacy.include?("产物目录：#{canonical}") && legacy.include?("未单独记录") && legacy.include?("最近重新绑定：无"),
           "an old record shows the project root without a migration")
    cli("stop", record.path, "--reason", "用户停止")
    assert(record.state["workspace"].nil? && JSON.parse(File.read(commands(record).fetch(0)))["type"] == "stop",
           "status and stop do not rewrite an old record")
  end

  # The evidence entry is valid at the moment of the test: retrieved_at is
  # shortly in the past and the fixed model version defaults to a 7-day
  # window.
  def evidence(overrides = {})
    entry = {
      "provider" => "opencode-go", "model" => "deepseek-v4.8", "reasoning" => "default", "status" => "evidence",
      "retrieved_at" => (Time.now.utc - 60).strftime("%Y-%m-%dT%H:%M:%SZ"),
      "sources" => ["https://artificialanalysis.ai/models"],
      "metrics" => { "coding_index" => { "value" => 50.5, "unit" => "index", "basis" => "scripted task-quality measurement" } }
    }
    if overrides["status"] == "unavailable"
      entry = entry.slice("provider", "model", "reasoning", "status", "retrieved_at")
                   .merge("reason" => "no comparable public benchmark found")
    end
    entry.merge(overrides)
  end

  # Submitting evidence validates and writes the user-level cache before one
  # dedicated control command that carries identity and status only.
  def model_evidence_caches_object_and_queues_dedicated_command
    record = task
    reply = JSON.parse(cli("model-evidence", record.path, "--file", "-", stdin_data: JSON.generate(
      evidence("model" => "deepseek-v4.8", "measured_at" => (Time.now.utc - 120).iso8601,
               "method_version" => "scripted-method-1")
    )))
    assert(reply["status"] == "queued" && reply["count"] == 1 &&
           reply["identities"] == [{ "provider" => "opencode-go", "model" => "deepseek-v4.8", "reasoning" => "default",
                                     "billing_route" => "unknown" }],
           "the reply names the queued identity including the typed billing route")
    assert(!JSON.generate(reply).include?("metrics") && !JSON.generate(reply).include?("http") &&
           !JSON.generate(reply).include?("list price"),
           "the reply does not echo metrics, source URLs or cost-tier text")

    command = JSON.parse(File.read(commands(record).fetch(0)))
    assert(command["type"] == "model_evidence" && command.dig("source", "command") == "model-evidence" &&
           command["entries"] == [{ "provider" => "opencode-go", "model" => "deepseek-v4.8", "reasoning" => "default",
                                    "billing_route" => "unknown", "status" => "evidence" }] &&
           !command.key?("text") && !command.key?("metrics"),
           "the dedicated command carries the typed identity and status, not the submitted body")
    stored = JSON.parse(File.read(File.join(@temp, "orbit", "model-evidence-v1.json")))
    assert(stored.fetch("entries").length == 1 && stored.dig("entries", 0, "metrics", "coding_index", "value") == 50.5 &&
           stored.dig("entries", 0, "method_version") == "scripted-method-1" &&
           stored.dig("entries", 0, "measured_at").is_a?(String) && !stored.fetch("entries").first.key?("cost_tier"),
           "the sourced quality, measurement date and method remain distinct from obsolete costs")
  end

  # A batch is validated as a whole; rejections and ended tasks write neither
  # cache nor inbox.
  def model_evidence_accepts_array_and_rejects_invalid_or_terminal
    record = task
    missing = cli("model-evidence", File.join(@temp, "missing"), "--file", "-", stdin_data: JSON.generate(evidence), success: false)
    assert(missing.include?("No such file") && !File.exist?(File.join(@temp, "orbit", "model-evidence-v1.json")),
           "a missing task writes no cache")

    entries = [evidence("model" => "deepseek-v4.8"), evidence("model" => "kimi-k3", "status" => "unavailable")]
    reply = JSON.parse(cli("model-evidence", record.path, "--file", "-", stdin_data: JSON.generate(entries)))
    command = JSON.parse(File.read(commands(record).fetch(0)))
    assert(reply["count"] == 2 && reply["identities"].length == 2 &&
           command["entries"].map { |entry| entry["status"] } == %w[evidence unavailable],
           "an array submission queues every identity with its status")
    File.unlink(commands(record).fetch(0))

    invalid = cli("model-evidence", record.path, "--file", "-", stdin_data: JSON.generate(evidence.merge("reason" => "not evidence")), success: false)
    assert(invalid.include?("unsupported model evidence fields") && commands(record).empty?,
           "an invalid payload queues nothing")
    empty = cli("model-evidence", record.path, "--file", "-", stdin_data: "[]", success: false)
    assert(empty.include?("non-empty array") && commands(record).empty?, "an empty array is rejected before queueing")

    settled = task("complete")
    terminal = cli("model-evidence", settled.path, "--file", "-", stdin_data: JSON.generate(evidence("provider" => "openai", "model" => "gpt-6-astra")), success: false)
    assert(terminal.include?("task process has ended") && commands(settled).empty?, "a terminal task is rejected before queueing")
    stored = JSON.parse(File.read(File.join(@temp, "orbit", "model-evidence-v1.json")))
    assert(stored.fetch("entries").length == 2, "rejected submissions leave the cache unchanged")
  end

  # Bootstrap: model selection can block on an empty cache before any
  # TaskRecord exists. The taskless form writes the same user cache the
  # selector reads, an invalid batch leaves it byte-identical, and the
  # task-bound mode keeps queueing against that same cache afterwards.
  def model_evidence_taskless_submission_writes_cache_without_a_task
    help = cli("model-evidence", "--help")
    assert(help.include?("[TASK_DIRECTORY]") && help.include?('status "cached"'),
           "the help documents the optional task directory and the cache-only status")

    reply = JSON.parse(cli("model-evidence", "--file", "-", stdin_data: JSON.generate(evidence)))
    assert(reply == { "status" => "cached", "count" => 1,
                      "identities" => [{ "provider" => "opencode-go", "model" => "deepseek-v4.8", "reasoning" => "default",
                                         "billing_route" => "unknown" }] },
           "a taskless submission reports a cache-only write, not a queued command")
    assert(JSON.parse(cli("status", "--json"))["tasks"].empty?, "no task record is manufactured")

    cache = File.join(@temp, "orbit", "model-evidence-v1.json")
    readable = Orbit::ModelEvidenceCache.new(env: { "XDG_CACHE_HOME" => @temp })
    assert(readable.lookup(provider: "opencode-go", model: "deepseek-v4.8").dig("metrics", "coding_index", "value") == 50.5,
           "the selector's own read path finds the taskless fact inside its validity window")

    before = File.read(cache)
    invalid = cli("model-evidence", "--file", "-",
                  stdin_data: JSON.generate(evidence("model" => "kimi-k3").merge("reason" => "not evidence")), success: false)
    assert(invalid.include?("unsupported model evidence fields") && File.read(cache) == before,
           "an invalid taskless batch is rejected and leaves the cache untouched")

    record = task
    queued = JSON.parse(cli("model-evidence", record.path, "--file", "-",
                            stdin_data: JSON.generate(evidence("provider" => "openai", "model" => "gpt-6-astra"))))
    command = JSON.parse(File.read(commands(record).fetch(0)))
    assert(queued["status"] == "queued" && command["type"] == "model_evidence" &&
           JSON.parse(File.read(cache)).fetch("entries").length == 2,
           "the task-bound mode still queues against the same cache without dropping the taskless fact")
  end

  # Root may select OMP-accessible models; an absent catalog identity still
  # cannot be queued as a checker.
  def review_model_checks_omp_catalog_and_status_shows_the_block
    record = task
    missing = cli("review-model", record.path, success: false)
    invalid = cli("review-model", record.path, "--model", "glm-5.2", success: false)
    assert(missing.include?("provider/id") && invalid.include?("provider/id") && commands(record).empty?,
           "missing or malformed IDs never enqueue a check")

    server = UNIXServer.new(record.state.dig("connection", "socket"))
    worker = Thread.new do
      loop do
        peer = server.accept
        request = JSON.parse(peer.gets)
        result = case request["method"]
                 when "state" then { "cwd" => File.realpath(@project), "status" => "idle" }
                 when "model_catalog" then { "current" => "root/model", "available" => ["root/model"], "families" => {} }
                 else []
                 end
        peer.puts(JSON.generate("result" => result))
        peer.close
      rescue IOError, SystemCallError
        break
      end
    end
    denied = cli("review-model", record.path, "--model", "zenmux/x-ai/grok-4.7", success: false)
    assert(denied.include?("not available in this OMP session") && commands(record).empty?,
           "a model outside OMP's actual catalog cannot be queued by Root")

    settled = task("complete")
    terminal = cli("review-model", settled.path, "--model", "zenmux/x-ai/grok-4.7", success: false)
    assert(terminal.include?("task process has ended") && commands(settled).empty?,
           "a terminal task rejects a model change no process would apply")

    blocked = task("running",
                   "review" => {
                     "model" => "zhipu-coding-plan/glm-5.2",
                     "selection" => { "model" => "zenmux/x-ai/grok-4.7" },
                     "blocked" => { "model" => "zenmux/x-ai/grok-4.7", "type" => "check_failure",
                                    "failure_kind" => "auth_or_quota", "reason" => "provider returned 401" }
                   },
                   "checks" => [{ "status" => "failed", "error" => "provider returned 401" }])
    check = JSON.parse(cli("check", blocked.path))
    assert(check["status"] == "rejected" && check["reason"] == "checker_model_blocked" &&
           check["next_action"].include?("Root can inspect OMP availability") && commands(blocked).empty?,
           "an unavailable checker rejects repeated manual checks before queueing work")
    text = cli("status", blocked.path)
    assert(text.include?("检查模型：zenmux/x-ai/grok-4.7"), "status shows the model actually used for checks")
    assert(text.include?("检查阻塞：模型 zenmux/x-ai/grok-4.7（auth_or_quota）") &&
           text.include?("provider returned 401") && text.include?("orbit review-model"),
           "status shows the block and the explicit recovery action")
    assert(text.include?("最近检查：失败 — provider returned 401") && text.include?("任务保持运行"),
           "status shows the failed check as not adopted")
  ensure
    worker&.kill if worker&.alive?
    server&.close unless server&.closed?
    worker&.join
  end

  def jev_state(decision: nil, delegatable: 0.91, quality: 0.63)
    delegation = {
      "status" => "assessed", "question_set_version" => "jev-candidates-2",
      "scores" => { "quality" => quality }
    }
    delegation["decision"] = decision if decision
    {
      "status" => "assessed", "assessed_at" => "2026-09-22T12:00:00Z",
      "scores" => { "delegatable" => delegatable },
      "delegation" => delegation
    }
  end

  def jev_line(text)
    text.lines.find { |line| line.start_with?("JEV：") } || ""
  end

  # A high stage-one score is not a recommendation. Only an explicit decision,
  # or the absence of one on an old record, chooses the wording.
  def status_separates_delegatable_score_from_final_decision
    declined = task("running",
                    "jev" => jev_state(decision: "declined"),
                    "members" => [{ "thread_id" => "member-1", "status" => "working" }])
    declined_text = cli("status", declined.path)
    declined_jev = jev_line(declined_text)
    candidate = declined_jev[/第一阶段候选分[^；]*/].to_s
    assert(candidate.include?("delegatable 0.91") && candidate.include?("不是委派建议"),
           "a high delegatable score stays a candidate, not a recommendation")
    assert(declined_jev.include?("最终不建议委派") && declined_jev.include?("任务质量判断 0.63") &&
           !declined_jev.include?("parallel_gain") && !declined_jev.include?("最终建议委派"),
           "declined is the final recommendation even when delegatable is high")
    assert(declined_text.include?("Root 在无 hint 时显式委派") &&
           declined_text.include?("最近事件：Root 在无 hint 时显式委派") &&
           !declined_text.include?("由 Orbit hint"),
           "members without a hint are an explicit Root delegation")

    recommended = task("running",
                       "jev" => jev_state(decision: "recommended", quality: 0.80),
                       "delegation_hint" => { "followed" => true, "quality" => 0.80 },
                       "members" => [{ "thread_id" => "member-2", "status" => "working" }])
    recommended_text = cli("status", recommended.path)
    recommended_jev = jev_line(recommended_text)
    assert(recommended_jev.include?("最终建议委派") && recommended_jev.include?("任务质量判断 0.80") &&
           !recommended_jev.include?("parallel_gain") && !recommended_jev.include?("最终不建议委派") &&
           !recommended_jev.include?("不能从分数"),
           "recommended names the final delegation advice and task quality without a time score")
    assert(recommended_text.include?("执行成员由 Orbit hint 后产生") &&
           recommended_text.include?("最近事件：执行成员由 Orbit hint 后产生"),
           "a followed hint is the recorded member source")

    pending_hint = task("running", "jev" => jev_state(decision: "recommended", quality: 0.80))
    pending_jev = jev_line(cli("status", pending_hint.path))
    assert(pending_jev.include?("delegation_hint 尚未持久化") &&
           pending_jev.include?("不能视为可执行建议") && !pending_jev.include?("最终建议委派"),
           "a recommended score is not actionable before the final hint is persisted")

    legacy_jev_state = jev_state
    legacy_jev_state["delegation"] = {
      "status" => "assessed", "question_set_version" => "jev-delegation-1",
      "scores" => { "member_fit" => 0.80, "parallel_gain" => 0.70 }
    }
    legacy = task("running", "jev" => legacy_jev_state)
    legacy_text = cli("status", legacy.path)
    legacy_jev = jev_line(legacy_text)
    assert(legacy_jev.include?("delegatable 0.91") && legacy_jev.include?("不是委派建议") &&
           legacy_jev.include?("历史委派判断（jev-delegation-1）") && legacy_jev.include?("不用于新版自动推荐") &&
           !legacy_jev.include?("member_fit 0.80") && !legacy_jev.include?("parallel_gain 0.70") &&
           !legacy_jev.include?("最终建议委派") && !legacy_jev.include?("最终不建议委派"),
           "an old record without decision does not promote scores into a recommendation")
    assert(!legacy_text.include?("最近事件"), "no member source is invented when there are no members")
    raw = JSON.parse(cli("status", "--json", legacy.path))
    assert(raw.dig("jev", "delegation").key?("decision") == false && raw == legacy.state,
           "status does not rewrite an old record")
  end

  # The OMP extension bridge reuses the shared pool file: list/add/remove each
  # print one JSON document, and an id whose remainder contains a slash is kept
  # intact across separate CLI invocations.
  def model_candidates_bridge_round_trips_and_keeps_ids_with_slashes
    assert(JSON.parse(cli("model-candidates", "list")) == { "models" => [] }, "an empty pool lists as an empty JSON array")

    assert(JSON.parse(cli("model-candidates", "add", "zhipu-coding-plan/glm-5.2")) ==
           { "models" => ["zhipu-coding-plan/glm-5.2"] }, "add prints the resulting pool")
    added = JSON.parse(cli("model-candidates", "add", "zenmux/x-ai/grok-4.7"))
    assert(added == { "models" => ["zhipu-coding-plan/glm-5.2", "zenmux/x-ai/grok-4.7"] },
           "a multi-segment id is stored and printed intact")
    assert(JSON.parse(cli("model-candidates", "list")) == added, "a separate invocation reads the persisted pool")

    secret = "sk-credential-sentinel"
    output = cli("model-candidates", "remove", "zenmux/x-ai/grok-4.7", env: { "OPENCODE_GO_API_KEY" => secret })
    assert(JSON.parse(output) == { "models" => ["zhipu-coding-plan/glm-5.2"] }, "remove prints the remaining pool")
    assert(!output.include?(secret), "the bridge never echoes an ambient credential")

    path = File.join(@temp, "orbit", "model-candidates.json")
    document = JSON.parse(File.read(path))
    assert(document.keys.sort == %w[models schema_version] && document["schema_version"] == "orbit-model-candidates-v1" &&
           document["models"] == ["zhipu-coding-plan/glm-5.2"],
           "the bridge reuses the versioned pool file and stores no extra fields")
  end

  # Rejections exit non-zero, leave the pool untouched, and never print the
  # rejected value; a successful call writes only JSON to stdout.
  def model_candidates_bridge_fails_closed_without_echoing_input
    cli("model-candidates", "add", "provider/good")
    path = File.join(@temp, "orbit", "model-candidates.json")
    before = File.read(path)

    secret = "sk-pasted-by-mistake"
    rejected = cli("model-candidates", "add", secret, success: false)
    assert(rejected.include?("provider/id") && !rejected.include?(secret),
           "a malformed argument is rejected without echoing the pasted value")
    assert(File.read(path) == before, "a rejected add leaves the pool unchanged")
    assert(cli("model-candidates", "frobnicate", success: false).include?("usage:"), "an unknown subcommand is rejected")
    assert(cli("model-candidates", "add", success: false).include?("required"), "a missing model argument is rejected")

    out, err, status = Open3.capture3({ "XDG_CONFIG_HOME" => @temp, "XDG_CACHE_HOME" => @temp },
                                      RbConfig.ruby, "--disable-gems", ENTRY, "model-candidates", "list",
                                      chdir: @project)
    assert(status.success? && err.empty? && JSON.parse(out) == { "models" => ["provider/good"] },
           "a successful bridge call writes only the JSON document to stdout")
  end

  # The picker's commit bridge: one apply-delta applies the net change
  # atomically, refuses a same-ID conflict without writing, and accepts empty
  # lists (the picker passes '' when a side of the delta is empty).
  def model_candidates_bridge_applies_one_net_delta_atomically
    cli("model-candidates", "add", "provider/kept")
    cli("model-candidates", "add", "provider/out")
    snapshot = JSON.parse(cli("model-candidates", "list"))["models"]

    cli("model-candidates", "add", "provider/other-session") # disjoint concurrent edit
    result = JSON.parse(cli("model-candidates", "apply-delta",
                            "--base", snapshot.join(","), "--add", "provider/in", "--remove", "provider/out"))
    base = %w[provider/kept provider/other-session provider/in]
    cli("model-candidates", "add", "provider/taken") # same-ID concurrent edit since that snapshot
    refused = cli("model-candidates", "apply-delta",
                  "--base", base.join(","), "--add", "provider/taken", success: false)
    assert(refused.include?("changed since the snapshot") && refused.include?("provider/taken"),
           "a same-ID conflict refuses the whole commit and names the id")
    assert(JSON.parse(cli("model-candidates", "list"))["models"] ==
           %w[provider/kept provider/other-session provider/in provider/taken], "a refused commit writes nothing")

    empty_sides = JSON.parse(cli("model-candidates", "apply-delta", "--base", "", "--add", "", "--remove", ""))
    assert(empty_sides == { "models" => %w[provider/kept provider/other-session provider/in provider/taken] },
           "empty LIST values are an empty side, not a malformed id")
  end

  # Mid-flight takeover (main proposal §3.4; audit A05/A07). These tests cover
  # the program-captured boundary document and the CLI seams that must work
  # without a live OMP session: the payload is refused before any connection,
  # and a valid takeover request follows the ordinary start path. The record
  # contents are built through the same public TaskRecord.create the CLI calls.
  # NOT TESTED here: a successful CLI `start` that spawns the runtime — that
  # needs a live isolated checker and is covered by source reading plus the CLI
  # refusal paths below only; the native success path waits for an installed
  # build and is not claimed.
  def takeover_boundary_is_program_captured_and_scope_is_declared_or_unknown
    File.write(File.join(@project, "spec.md"), "# requirement\n")
    instruction = "按 docs/spec.md 实现 CSV 对账并完成验证"
    source = { "kind" => "omp_user_message", "id" => "native-msg-1" }
    fixed = Time.utc(2026, 9, 30, 12, 0, 0)
    clock = -> { fixed }
    original = File.binread(File.join(@project, "spec.md"))
    before = Orbit::WorkspaceSnapshot.fingerprint(project_root: @project)
    record = Orbit::TaskRecord.create(
      project_root: @project, instruction: instruction, source: source, connection: {}, review: {}, clock: clock,
      takeover: Orbit::TaskRecord.parse_takeover(
        JSON.generate("reason" => "用户要求把这项已执行的要求纳入监督", "prior_scope" => "Root 已改 src/a.rb")
      )
    )
    block = record.state["takeover"]
    relative = block.dig("artifact", "snapshot_path")
    snapshot = File.join(record.path, relative)
    assert(block["format"] == Orbit::TaskRecord::TAKEOVER_FORMAT && block.dig("artifact", "digest") == before &&
           block.dig("artifact", "digest").start_with?("sha256:") && block.dig("artifact", "source") == "program_workspace_snapshot",
           "the artifact digest is the program's real workspace fingerprint, not a caller value")
    assert(!relative.to_s.empty? && File.directory?(snapshot) &&
           File.binread(File.join(snapshot, "spec.md")) == original &&
           File.binread(File.join(record.path, "instruction.txt")).b == instruction.b,
           "the takeover really preserves the artifact bytes and the requirement bytes in the task's private directory")
    assert([block["requested_at"], block.dig("supervision", "starts_at"), block.dig("artifact", "captured_at")] == [fixed.iso8601] * 3,
           "the supervision boundary timestamps come from the program clock")
    assert(block.dig("requirement", "native_message_id") == "native-msg-1" &&
           block.dig("requirement", "instruction_sha256") == Digest::SHA256.hexdigest(instruction.b) &&
           block.dig("requirement", "instruction_bytes") == instruction.bytesize,
           "the original native message id and the byte digest of the preserved requirement are stored")
    assert(block.dig("prior_scope", "status") == "declared" && block.dig("prior_scope", "text").include?("src/a.rb"),
           "a prior scope Root states is kept verbatim as a declaration")
    assert(block.dig("prior_execution", "recognized_as_controlled") == false && block.dig("prior_execution", "imported") == [],
           "the earlier execution is not recognized as controlled and nothing of it is imported")

    File.write(File.join(@project, "spec.md"), "# changed after takeover\n")
    assert(File.binread(File.join(snapshot, "spec.md")) == original &&
           Orbit::WorkspaceSnapshot.fingerprint(project_root: @project) != before,
           "editing the original after takeover does not move the preserved boundary snapshot")

    unstated = Orbit::TaskRecord.create(project_root: @project, instruction: instruction, source: source,
                                       connection: {}, review: {}, clock: clock,
                                       takeover: Orbit::TaskRecord.parse_takeover('{"reason":"take over"}'))
    assert(unstated.state.dig("takeover", "prior_scope", "status") == "unknown" &&
           unstated.state.dig("takeover", "prior_scope", "text").nil?,
           "an unstated prior scope stays unknown instead of being guessed from摘要 or Git")

    # A real capture failure through the real create path: WorkspaceSnapshot
    # cannot read a file it must snapshot (deterministic Errno::EACCES, the same
    # rejection the snapshot module raises elsewhere). External symlinks are only
    # flagged by that module, so they cannot drive this case. The half-created
    # record must be removed by create itself, not by the test.
    File.write(File.join(@project, "spec.md"), "# requirement\n")
    before_tasks = Dir.glob(File.join(@project, ".orbit", "tasks", "*"))
    unreadable = File.join(@project, "unreadable.txt")
    File.write(unreadable, "secret\n")
    File.chmod(0o000, unreadable)
    refusal = begin
      Orbit::TaskRecord.create(project_root: @project, instruction: instruction, source: source, connection: {},
                               review: {}, clock: clock,
                               takeover: Orbit::TaskRecord.parse_takeover('{"reason":"take over"}'))
      nil
    rescue StandardError => error
      error
    ensure
      File.chmod(0o644, unreadable)
      File.unlink(unreadable)
    end
    tasks = Dir.glob(File.join(@project, ".orbit", "tasks", "*"))
    assert(refusal.is_a?(Errno::EACCES) && (tasks - before_tasks).empty? && tasks.length == before_tasks.length,
           "create reaches the real capture, fails on the unreadable artifact and removes the half-created task " \
           "instead of leaving a starting record claiming supervision (got #{refusal.inspect})")

    %w[artifact_digest started_at supervision_started_at digest captured_at].each do |field|
      refused = false
      begin
        Orbit::TaskRecord.parse_takeover(JSON.generate("reason" => "x", field => "2026-01-01T00:00:00Z"))
      rescue ArgumentError => error
        refused = error.message.include?(field)
      end
      assert(refused, "a payload may not state the program-captured #{field}")
    end
    [['{"prior_scope":"x"}', "reason"], ["not json", "JSON"], ['[]', "JSON object"]].each do |text, expected|
      refused = false
      begin
        Orbit::TaskRecord.parse_takeover(text)
      rescue ArgumentError => error
        refused = error.message.include?(expected)
      end
      assert(refused, "an invalid takeover payload is refused (#{expected})")
    end
  end

  def takeover_payload_is_refused_before_any_session_or_task_exists
    File.write(File.join(@project, "AGENTS.md"), "# rules\n")
    socket = File.join(@temp, "host.sock")
    server = UNIXServer.new(socket)
    handled = []
    worker = Thread.new do
      loop do
        peer = server.accept
        handled << JSON.parse(peer.gets)["method"]
        peer.puts(JSON.generate("result" => { "cwd" => File.realpath(@project), "status" => "idle" }))
        peer.close
      end
    rescue IOError
      nil
    end
    worker.report_on_exception = false
    base = ["start", "--provider", "omp", "--project", @project, "--thread", "root", "--socket", socket, "--message-id", "m1"]
    failures = {
      "takeover payload needs a stated reason" => ['{"prior_scope":"only scope"}', base],
      "takeover payload may not state program-captured facts: artifact_digest" =>
        [JSON.generate("reason" => "x", "artifact_digest" => "sha256:forged"), base],
      "--prompt-file cannot take over" => ['{"reason":"x"}', base - ["--message-id", "m1"] + ["--prompt-file", "-"]]
    }
    failures.each do |expected, (payload, args)|
      text = cli(*args, "--takeover-file", "-", stdin_data: payload, success: false)
      assert(text.include?(expected), "a bad takeover request is refused: #{expected}")
    end
    assert(handled.empty?, "no session request is sent for a refused takeover request")
    assert(!File.exist?(File.join(@project, ".orbit", "tasks")),
           "a refused takeover creates no task and therefore claims no supervision")
  ensure
    server&.close unless server&.closed?
    worker&.kill if worker&.alive?
  end

  def takeover_does_not_disturb_the_ordinary_start_path
    socket = File.join(@temp, "host.sock")
    server = UNIXServer.new(socket)
    worker = Thread.new do
      loop do
        peer = server.accept
        request = JSON.parse(peer.gets)
        result = case request["method"]
                 when "state" then { "cwd" => File.realpath(@project), "status" => "idle" }
                 when "messages" then [{ "id" => "m1", "text" => "对账实现", "internal" => false }]
                 when "model_catalog" then { "current" => "a/b", "available" => [], "families" => {}, "agents" => {},
                                             "routes" => {}, "limits" => {}, "agent_dir" => nil }
                 else { "ok" => true }
                 end
        peer.puts(JSON.generate("result" => result))
        peer.close
      end
    rescue IOError
      nil
    end
    worker.report_on_exception = false
    base = ["start", "--provider", "omp", "--project", @project, "--thread", "root", "--socket", socket, "--message-id", "m1"]
    takeover = cli(*base, "--takeover-file", "-", stdin_data: JSON.generate("reason" => "把这项已执行的要求纳入监督"),
                   success: false)
    ordinary = cli(*base, success: false)
    head = ->(text) { text.split("selection trace:").first }
    assert(head.call(takeover) == head.call(ordinary),
           "a takeover request ends the same way as an ordinary start when no runnable checker exists")
    assert(takeover.include?("no unused OMP model is available") && !takeover.include?("artifact_digest"),
           "a valid takeover payload is not mistaken for a caller-supplied boundary")
    assert(!File.exist?(File.join(@project, ".orbit", "tasks")),
           "a start without a runnable checker leaves no task, takeover or not")
  ensure
    server&.close unless server&.closed?
    worker&.kill if worker&.alive?
  end

  def takeover_scope_declarations_are_queued_append_only
    instruction = "按 docs/spec.md 实现 CSV 对账并完成验证"
    source = { "kind" => "omp_user_message", "id" => "native-msg-2" }
    record = Orbit::TaskRecord.create(
      project_root: @project, instruction: instruction, source: source, connection: {}, review: {},
      clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) },
      takeover: Orbit::TaskRecord.parse_takeover(JSON.generate("reason" => "take over"))
    )
    payload = File.join(@temp, "scope-declaration.json")
    File.write(payload, JSON.generate("prior_scope" => "Root 早前已改 src/a.rb", "reason" => "后来补充"))
    queued = JSON.parse(cli("takeover-scope", record.path, "--file", payload))
    assert(queued["status"] == "queued" && queued["command_id"].is_a?(String),
           "a later prior_scope declaration is queued with an id")
    command = JSON.parse(File.read(commands(record).last))
    assert(command["type"] == "takeover_scope" && command["prior_scope"] == "Root 早前已改 src/a.rb" &&
           command.dig("source", "kind") == "submitter_declaration",
           "the queue carries the submitter declaration with its source")
    assert(!record.state["takeover"].key?("prior_scope_declarations"),
           "the CLI only enqueues; the runtime remains the sole state writer")

    # Explicit rejections: missing scope, wrong types, unknown keys (a caller
    # cannot smuggle its own declared_at/snapshot), a non-takeover task and a
    # terminal task.
    File.write(payload, JSON.generate("reason" => "no scope"))
    cli("takeover-scope", record.path, "--file", payload, success: false)
    File.write(payload, JSON.generate("prior_scope" => 42))
    cli("takeover-scope", record.path, "--file", payload, success: false)
    File.write(payload, JSON.generate("prior_scope" => "x", "reason" => 7))
    cli("takeover-scope", record.path, "--file", payload, success: false)
    File.write(payload, JSON.generate("prior_scope" => "x", "declared_at" => "2026-09-30T13:00:00Z"))
    cli("takeover-scope", record.path, "--file", payload, success: false)
    plain = task("running")
    File.write(payload, JSON.generate("prior_scope" => "x"))
    cli("takeover-scope", plain.path, "--file", payload, success: false)
    queued_before = commands(record).length
    record.save(record.state.merge("status" => "paused"))
    cli("takeover-scope", record.path, "--file", payload, success: false)
    assert(commands(plain).empty? && commands(record).length == queued_before,
           "refused declarations never reach the queue")
  end

  def maintenance_requires_an_installed_cli
    %w[update uninstall].each { |command| cli(command, success: false) }
    assert(cli("start", "--help").include?("--provider"), "execution details are available in subcommand help")
  end

  def jev_setup_exports_key_in_new_shell
    env = { "HOME" => @temp, "TYPESAFE_API_KEY" => nil, "SHELL" => "/bin/zsh", "ZDOTDIR" => @temp }
    output = cli("jev", "setup", env: env, stdin_data: "test-key\n")
    path = File.join(@temp, "typesafe-ai", "env")
    profile = File.join(@temp, ".zshrc")
    assert(File.read(path).include?("export TYPESAFE_API_KEY=test-key") && File.stat(path).mode & 0o777 == 0o600,
           "the TypeSafe environment file is private")
    assert(File.read(profile).include?(path) && !File.read(profile).include?("test-key") &&
           !File.exist?(File.join(@temp, "orbit", "typesafe-key")), "Orbit config and shell profile contain no key")
    shell_out, shell_err, shell_status = Open3.capture3({ "HOME" => @temp, "ZDOTDIR" => @temp, "TYPESAFE_API_KEY" => nil },
                                                        "zsh", "-ic", 'printf "%s" "$TYPESAFE_API_KEY"')
    assert(shell_status.success? && shell_out == "test-key" && shell_err.empty? &&
           Orbit::JevAdvisor.for_project(@project, env: { "TYPESAFE_API_KEY" => shell_out }),
           "a new shell exports the key for the task runtime")
    assert(!output.include?("test-key"), "the command does not print the key")
    cli("jev", "setup", env: env, stdin_data: "\n", success: false)
    assert(File.read(path).include?("test-key"), "empty input does not replace the existing key")
  end

  def session_summary_separates_check_facts_from_missing_evidence
    first = task("complete")
    second = task("running")
    unrelated = task("paused")
    unrelated.save(unrelated.state.merge("connection" => unrelated.state.fetch("connection").merge("thread_id" => "other")))
    first.save(first.state.merge("checks" => [
      { "stale" => true, "manual" => false, "usage" => { "input_tokens" => 8, "output_tokens" => 2 },
        "result" => { "findings" => [{ "id" => "F1" }] } },
      { "manual" => true, "usage" => nil, "result" => { "findings" => [{ "id" => "F1" }] } }
    ]))
    second.save(second.state.merge("checks" => [
      { "kind" => "process", "usage" => { "input_tokens" => 5, "output_tokens" => 5 } }
    ]))
    2.times { first.event("jev_assessed") }
    first.event("correction_sent")
    first.event("check_failed")
    before = File.read(File.join(second.path, "state.json"))
    report = JSON.parse(cli("session-summary", "--thread", "root"))
    assert(report.fetch("tasks").map { |row| row["id"] }.sort == [first, second].map { |item| item.state["id"] }.sort &&
           report.dig("counts", "checks") == 3 && report.dig("counts", "stale_checks") == 1 &&
           report.dig("counts", "process_checks") == 1 && report.dig("counts", "findings") == 1,
           "the report aggregates only this native session and counts task-scoped findings once")
    assert(report.dig("counts", "jev_assessments").nil? &&
           report.dig("counts", "correction_sent").nil? &&
           report.dig("usage", "checker_tokens_observed") == 20 &&
           report.dig("usage", "checker_tokens_complete") == false &&
           report.dig("usage", "task_total_tokens").nil? &&
           report.fetch("tasks").all? { |row| row["collaboration_log"] == "missing" } &&
           File.read(File.join(second.path, "state.json")) == before,
           "missing logs and unreported token usage remain unknown without changing task evidence")
    second.event("jev_assessed")
    complete = JSON.parse(cli("session-summary", "--thread", "root"))
    assert(complete.dig("counts", "jev_assessments") == 3 &&
           complete.dig("counts", "correction_sent") == 1 &&
           complete.dig("counts", "failed_checks") == 1,
           "once both event streams exist the independent Jev, delivery and failure counts are known")
  end

  def main
    %i[single_task_from_project_subdirectory multiple_tasks_require_explicit_selection completed_and_absent_tasks
       status_separates_check_activity_from_task_completion
       terminal_status_never_prompts_recheck_of_stopped_tasks
       status_usage_sums_known_roles_and_excludes_root_cumulative
       status_usage_is_unknown_when_any_component_is_missing
       status_reads_late_final_receipts_without_changing_terminal_state
       status_exposes_pending_and_corrupt_accounting_as_unknown
       route_forecast_is_scoped_and_never_consumption
       stale_result_and_user_action failed_stop_confirmation_is_reported doctor_without_connection_or_dependencies
       doctor_reads_existing_native_connection
       stop_retries_when_recorded_runtime_is_gone
       stop_retries_when_runtime_exited_without_terminal_status
       completion_stop_requires_a_current_notice
       doctor_states_single_host_entry_and_omp_checker
       rebind_workspace_queues_and_legacy_status_reads_project_root
       model_evidence_caches_object_and_queues_dedicated_command
       model_evidence_accepts_array_and_rejects_invalid_or_terminal
       model_evidence_taskless_submission_writes_cache_without_a_task
       review_model_checks_omp_catalog_and_status_shows_the_block
       session_summary_separates_check_facts_from_missing_evidence
       status_separates_delegatable_score_from_final_decision
       model_candidates_bridge_round_trips_and_keeps_ids_with_slashes
       model_candidates_bridge_fails_closed_without_echoing_input
       model_candidates_bridge_applies_one_net_delta_atomically
       takeover_boundary_is_program_captured_and_scope_is_declared_or_unknown
       takeover_scope_declarations_are_queued_append_only
       takeover_payload_is_refused_before_any_session_or_task_exists
       takeover_does_not_disturb_the_ordinary_start_path
       maintenance_requires_an_installed_cli
       jev_setup_exports_key_in_new_shell].each do |test|
      Dir.mktmpdir("orbit-cli-test-") do |tmp|
        @temp = tmp
        @project = File.join(tmp, "project")
        FileUtils.mkdir_p(@project)
        send(test)
      end
      puts "CLI_TEST_PASS #{test}"
    end
  end
end

CliTest.main
