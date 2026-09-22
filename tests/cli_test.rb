# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "socket"
require_relative "../lib/orbit/task_record"
require_relative "../lib/orbit/session_entry"
require_relative "../lib/orbit/member_policy"
require_relative "../lib/orbit/jev_advisor"
require_relative "../lib/orbit/jev_setup"

module CliTest
  ENTRY = File.expand_path("../scripts/orbit", __dir__)
  module_function

  def assert(value, message)
    raise message unless value
  end

  def cli(*args, cwd: @project, success: true, env: {}, stdin_data: nil)
    base = { "CODEX_THREAD_ID" => nil, "ORBIT_CODEX_SOCKET" => nil, "XDG_CONFIG_HOME" => @temp, "XDG_CACHE_HOME" => @temp }
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
    assert(text.include?("检查状态：idle") && text.include?("下一动作：等待 Root"),
           "a running task with no check facts is idle and still with Root")
    assert(text.include?("裁定记录：0 条"), "status keeps adjudication history separate from open work")
    assert(text.include?("执行中，尚未完成验收") && !text.include?("不是任务完成"),
           "idle does not claim the task is complete")

    record.save(record.state.merge(
      "checks" => [{ "role" => "reviewer", "stale" => false, "result" => { "verdict" => "complete", "reason" => "检查通过" } }]
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：verdict(complete)（检查结论，不是任务完成）"),
           "a complete verdict stays a check result")
    assert(text.include?("状态：执行中，尚未完成验收（running）"), "the task status stays running")

    record.save(record.state.merge(
      "check_observations" => { "obs-1" => { "status" => "in_flight" } },
      "next_check_at" => "2026-09-22T00:00:00Z", "next_check_trigger" => "manual_check", "next_check_manual" => true
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：running") && !text.include?("检查状态：queued") && !text.include?("检查状态：verdict(complete)"),
           "an in-flight check is running and is not the task verdict")

    record.save(record.state.merge("check_observations" => { "obs-1" => { "status" => "finished" } }))
    text = cli("status", record.path)
    assert(text.include?("检查状态：queued（检查已排队，不是任务完成）") && text.include?("下一动作：手动检查已排队"),
           "a manual next check is queued, not a completed task")

    record.save(record.state.merge("next_check_trigger" => "rebind", "next_check_basis" => "工作区重新绑定", "next_check_manual" => false))
    text = cli("status", record.path)
    assert(text.include?("检查状态：queued（检查已排队，不是任务完成）") && text.include?("下一动作：重新绑定工作区"),
           "a workspace rebind outranks a manual queue")

    record.save(record.state.merge(
      "status" => "needs_user", "stop_reason" => "请确认绑定",
      "checks" => [{ "stale" => true, "stale_reasons" => ["workspace"], "result" => { "verdict" => "complete", "reason" => "旧检查" } }]
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：stale") && text.include?("下一动作：需要用户处理"),
           "needs_user outranks rebind, and a stale verdict is not task completion")
    assert(!text.include?("检查状态：verdict(complete)") && !text.include?("检查状态：queued"),
           "a settled stale check is not shown as queued or as a current complete verdict")

    record.save(record.state.merge(
      "status" => "running", "next_check_at" => "2026-09-23T00:00:00Z", "next_check_trigger" => "timer",
      "next_check_basis" => "约定检查间隔", "next_check_manual" => false,
      "checks" => [{ "role" => "reviewer", "stale" => false, "result" => { "verdict" => "continue", "reason" => "继续" } }],
      "findings" => {}
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：queued（检查已排队，不是任务完成）") && text.include?("下一动作：检查已安排"),
           "a scheduled check is queued and arranged, not a completed task")

    record.save(record.state.merge("next_check_at" => nil, "next_check_trigger" => nil, "next_check_basis" => nil,
                                   "checks" => [{ "role" => "reviewer", "stale" => true, "stale_reasons" => ["workspace"],
                                                  "result" => { "verdict" => "correct", "reason" => "旧工作区" } }]))
    text = cli("status", record.path)
    assert(text.include?("检查状态：stale") && text.include?("下一动作：重新绑定工作区"),
           "a workspace-stale check asks for rebind without calling the task complete")

    record.save(record.state.merge(
      "checks" => [{ "role" => "reviewer", "stale" => true, "result" => { "verdict" => "correct", "reason" => "过期" } }],
      "findings" => { "gap" => { "status" => "open" } }
    ))
    text = cli("status", record.path)
    assert(text.include?("检查状态：stale") && text.include?("下一动作：等待 Root"),
           "open findings wait for Root when no rebind or queue is recorded")
    assert(!text.include?("下一动作：重新绑定工作区"), "a stale check without a workspace reason is not a rebind")
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
    assert(text.include?("运行失败，停止已确认") && text.include?("请查看运行错误") && !text.include?("停止情况需核实"),
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
    %w[omp opencode].each do |provider|
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

  # The per-tool approval override must address the MCP tool's real name
  # (`task`), not the server name; otherwise the default `auto` requires
  # approval and approval_policy=never sessions cannot call the tool.
  def codex_launch_approval_targets_the_registered_tool
    mcp = File.expand_path("../scripts/orbit-mcp.cjs", __dir__)
    tool_name = File.read(mcp)[/name:\s*'([^']+)',\s*\n\s*description:/, 1]
    assert(tool_name, "the Orbit MCP registers exactly one tool name")
    configuration = Orbit::SessionEntry.codex_configuration(mcp: mcp, socket: "/tmp/orbit-test.sock")
    assert(configuration.include?("tools={#{tool_name}={approval_mode=\"approve\"}}"),
           "the approval override targets the registered tool #{tool_name.inspect}")
    assert(!configuration.include?("tools={orbit="), "the server name must not be used as a tool key")
    assert(configuration.include?("mcp_servers.orbit={") && configuration.include?("ORBIT_CODEX_SOCKET"),
           "the Orbit MCP server configuration is preserved")
  end

  # The TUI argv must never carry permission overrides; the launcher folds them
  # into the single policy its lifecycle proxy applies (default full access,
  # explicit options win per field).
  def codex_launch_builds_one_permission_policy
    full = { "approvalPolicy" => "never", "sandbox" => "danger-full-access" }
    policy, kept = Orbit::SessionEntry.permission_policy(["--model", "gpt-6"])
    assert(policy == full && kept == ["--model", "gpt-6"], "new sessions default to full access")

    policy, kept = Orbit::SessionEntry.permission_policy(["resume", "abc", "--dangerously-bypass-approvals-and-sandbox", "-m", "gpt-6"])
    assert(policy == full && kept == ["resume", "abc", "-m", "gpt-6"],
           "resume permission flags move into the policy and out of the TUI argv")

    policy, kept = Orbit::SessionEntry.permission_policy(["-s", "read-only"])
    assert(policy == full.merge("sandbox" => "read-only") && kept.empty?, "an explicit sandbox overrides only the sandbox")

    policy, = Orbit::SessionEntry.permission_policy(["-c", 'sandbox_mode="workspace-write"', "-a", "on-request"])
    assert(policy == { "approvalPolicy" => "on-request", "sandbox" => "workspace-write" },
           "config-form permission options are parsed like the flags")

    policy, kept = Orbit::SessionEntry.permission_policy(["--approve-for-me", "-c", "mcp_servers.orbit.enabled=false"])
    assert(policy == { "approvalPolicy" => "on-request", "sandbox" => "workspace-write", "approvalsReviewer" => "auto_review" },
           "auto review keeps its reviewer routing in the policy")
    assert(kept == ["-c", "mcp_servers.orbit.enabled=false"], "non-permission config stays with the TUI")

    args = Orbit::SessionEntry.server_permission_args(full)
    assert(args == ["-c", 'sandbox_mode="danger-full-access"', "-c", 'approval_policy="never"'],
           "the app-server keeps the same policy as its default")
  end

  # v1 boundary: a profile can carry permission fields Codex resolves inside
  # the TUI. Reject it explicitly instead of silently overriding or dropping it.
  def codex_launch_rejects_profiles
    [["-p", "work"], ["--profile", "work"], ["--profile=work"]].each do |argv|
      assert(!Orbit::SessionEntry.permission_policy(argv).first.nil?, "profile argv still parses for the error path")
      begin
        Orbit::SessionEntry.reject_profile!(argv)
        raise "a profile must be rejected before launch"
      rescue ArgumentError => error
        assert(error.message.include?("-p/--profile"), "the profile boundary is explained")
      end
    end
    Orbit::SessionEntry.reject_profile!(["--model", "gpt-6"])
  end

  def doctor_reports_member_allowlist_and_gaps
    report = JSON.parse(cli("doctor", "--json"))
    members = report["members"]
    assert(members["allowed_kinds"] == Orbit::MemberPolicy::DEFAULT_KINDS && members["callable_kinds"].nil?,
           "default allowlist is reported without a session")
    text = cli("doctor")
    assert(text.include?("成员名单：") && text.include?("不可调用成员：kimi、cursor-agent、grok"),
           "text shows allowed and unavailable kinds")

    FileUtils.mkdir_p(File.join(@temp, "orbit"))
    File.write(File.join(@temp, "orbit", "members.json"), JSON.generate("allowed_kinds" => %w[opencode kimi]))
    record = task
    report = JSON.parse(cli("doctor", record.path, "--json", success: false))
    assert(report.dig("members", "allowed_kinds") == %w[opencode kimi] && report.dig("members", "source").end_with?("members.json"),
           "an existing config fully overrides the default list")
    assert(report.dig("members", "callable_kinds").nil? && report.dig("members", "connection_ready") == false,
           "a failed session connection is not reported as callable")
    assert(report.dig("members", "unavailable_kinds") == ["kimi"],
           "adapter gaps are still reported without a verified session")
    failed_text = cli("doctor", record.path, success: false)
    assert(failed_text.include?("可调用成员：未验证") && !failed_text.include?("可调用成员：opencode"),
           "doctor text does not claim callable kinds after a failed connection")

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
    assert(verified.dig("members", "connection_ready") == true && verified.dig("members", "callable_kinds") == [],
           "a verified session reports callable kinds for its provider")
  ensure
    server&.close unless server&.closed?
    worker&.kill if worker&.alive?
    worker&.join
  end

  def delegate_checks_allowlist_before_queueing
    record = task
    FileUtils.mkdir_p(File.join(@temp, "orbit"))
    File.write(File.join(@temp, "orbit", "members.json"), JSON.generate("allowed_kinds" => %w[kimi]))
    text = cli("delegate", record.path, "--kind", "codex", "--file", "-", success: false)
    assert(text.include?("not in allowed_kinds") && commands(record).empty?,
           "a disallowed kind is rejected before queueing")

    File.write(File.join(@temp, "orbit", "members.json"), JSON.generate("allowed_kinds" => %w[codex]))
    text = cli("delegate", record.path, "--kind", "codex", "--file", "-", success: false)
    assert(text.include?("no controlled adapter") && commands(record).empty?,
           "an allowed kind without an adapter is rejected before queueing")
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
      "metrics" => { "output_tokens_per_second" => { "value" => 120.5, "unit" => "tokens/s", "basis" => "public benchmark median" } }
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
    reply = JSON.parse(cli("model-evidence", record.path, "--file", "-", stdin_data: JSON.generate(evidence("model" => "deepseek-v4.8"))))
    assert(reply["status"] == "queued" && reply["count"] == 1 &&
           reply["identities"] == [{ "provider" => "opencode-go", "model" => "deepseek-v4.8", "reasoning" => "default" }],
           "the reply names the queued identity")
    assert(!JSON.generate(reply).include?("metrics") && !JSON.generate(reply).include?("http"),
           "the reply does not echo metrics or source URLs")

    command = JSON.parse(File.read(commands(record).fetch(0)))
    assert(command["type"] == "model_evidence" && command.dig("source", "command") == "model-evidence" &&
           command["entries"] == [{ "provider" => "opencode-go", "model" => "deepseek-v4.8", "reasoning" => "default", "status" => "evidence" }] &&
           !command.key?("text") && !command.key?("metrics"),
           "the dedicated command carries identity and status, not the submitted body")
    stored = JSON.parse(File.read(File.join(@temp, "orbit", "model-evidence-v1.json")))
    assert(stored.fetch("entries").length == 1 && stored.dig("entries", 0, "metrics", "output_tokens_per_second", "value") == 120.5,
           "the validated entry is cached for the runtime to re-read")
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

  def jev_state(decision: nil, delegatable: 0.91, member_fit: 0.63, parallel_gain: 0.40)
    delegation = {
      "status" => "assessed",
      "scores" => { "member_fit" => member_fit, "parallel_gain" => parallel_gain }
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
    assert(declined_jev.include?("最终不建议委派") && declined_jev.include?("member_fit 0.63") &&
           declined_jev.include?("parallel_gain 0.40") && !declined_jev.include?("最终建议委派"),
           "declined is the final recommendation even when delegatable is high")
    assert(declined_text.include?("Root 在无 hint 时显式委派") &&
           declined_text.include?("最近事件：Root 在无 hint 时显式委派") &&
           !declined_text.include?("由 Orbit hint"),
           "members without a hint are an explicit Root delegation")

    recommended = task("running",
                       "jev" => jev_state(decision: "recommended", member_fit: 0.80, parallel_gain: 0.75),
                       "delegation_hint" => { "followed" => true, "member_fit" => 0.80, "parallel_gain" => 0.75 },
                       "members" => [{ "thread_id" => "member-2", "status" => "working" }])
    recommended_text = cli("status", recommended.path)
    recommended_jev = jev_line(recommended_text)
    assert(recommended_jev.include?("最终建议委派") && recommended_jev.include?("member_fit 0.80") &&
           recommended_jev.include?("parallel_gain 0.75") && !recommended_jev.include?("最终不建议委派") &&
           !recommended_jev.include?("不能从分数"),
           "recommended names the final delegation advice and both stage-two scores")
    assert(recommended_text.include?("执行成员由 Orbit hint 后产生") &&
           recommended_text.include?("最近事件：执行成员由 Orbit hint 后产生"),
           "a followed hint is the recorded member source")

    pending_hint = task("running", "jev" => jev_state(decision: "recommended", member_fit: 0.80, parallel_gain: 0.75))
    pending_jev = jev_line(cli("status", pending_hint.path))
    assert(pending_jev.include?("delegation_hint 尚未持久化") &&
           pending_jev.include?("不能视为可执行建议") && !pending_jev.include?("最终建议委派"),
           "a recommended score is not actionable before the final hint is persisted")

    legacy = task("running", "jev" => jev_state(delegatable: 0.91, member_fit: 0.80, parallel_gain: 0.70))
    legacy_text = cli("status", legacy.path)
    legacy_jev = jev_line(legacy_text)
    assert(legacy_jev.include?("delegatable 0.91") && legacy_jev.include?("不是委派建议") &&
           legacy_jev.include?("旧记录没有 decision，不能从分数视为最终建议") &&
           legacy_jev.include?("member_fit 0.80") && legacy_jev.include?("parallel_gain 0.70") &&
           !legacy_jev.include?("最终建议委派") && !legacy_jev.include?("最终不建议委派"),
           "an old record without decision does not promote scores into a recommendation")
    assert(!legacy_text.include?("最近事件"), "no member source is invented when there are no members")
    raw = JSON.parse(cli("status", "--json", legacy.path))
    assert(raw.dig("jev", "delegation").key?("decision") == false && raw == legacy.state,
           "status does not rewrite an old record")
  end

  def check_next_action_ends_the_turn
    record = task
    reply = JSON.parse(cli("check", record.path))
    assert(reply["status"] == "queued" && reply["task_directory"] == record.path && !reply["command_id"].to_s.empty?,
           "check still queues")
    assert(reply["next_action"] == "若无用户已明确要求且不依赖检查结果的后续状态变更，结束当前轮次并等待 Orbit 通知；不要仅为等待检查结论而 sleep、poll 或 status",
           "check tells the caller to end the turn instead of polling")
    command = JSON.parse(File.read(commands(record).fetch(0)))
    assert(command["type"] == "check", "the queued command remains check")
    File.unlink(commands(record).fetch(0))

    dispute = JSON.parse(cli("dispute", record.path, "--reason", "有反证"))
    assert(dispute["status"] == "queued" && !dispute["command_id"].to_s.empty? && !dispute.key?("next_action"),
           "other submit responses stay compatible")
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

  def main
    %i[single_task_from_project_subdirectory multiple_tasks_require_explicit_selection completed_and_absent_tasks
       status_separates_check_activity_from_task_completion
       status_usage_sums_known_roles_and_excludes_root_cumulative
       status_usage_is_unknown_when_any_component_is_missing
       stale_result_and_user_action failed_stop_confirmation_is_reported doctor_without_connection_or_dependencies
       doctor_reads_existing_native_connection
       stop_retries_when_recorded_runtime_is_gone codex_launch_approval_targets_the_registered_tool
       codex_launch_builds_one_permission_policy codex_launch_rejects_profiles
       doctor_reports_member_allowlist_and_gaps
       delegate_checks_allowlist_before_queueing rebind_workspace_queues_and_legacy_status_reads_project_root
       model_evidence_caches_object_and_queues_dedicated_command
       model_evidence_accepts_array_and_rejects_invalid_or_terminal
       status_separates_delegatable_score_from_final_decision
       check_next_action_ends_the_turn
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
