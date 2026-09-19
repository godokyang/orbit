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
    base = { "CODEX_THREAD_ID" => nil, "ORBIT_CODEX_SOCKET" => nil, "XDG_CONFIG_HOME" => @temp }
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
       stale_result_and_user_action failed_stop_confirmation_is_reported doctor_without_connection_or_dependencies
       doctor_reads_existing_native_connection
       stop_retries_when_recorded_runtime_is_gone codex_launch_approval_targets_the_registered_tool
       codex_launch_builds_one_permission_policy codex_launch_rejects_profiles
       doctor_reports_member_allowlist_and_gaps
       delegate_checks_allowlist_before_queueing maintenance_requires_an_installed_cli
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
