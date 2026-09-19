# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "codex_connection"
require_relative "task_record"
require_relative "release_lease"

module Orbit
  # User-selected TUI entry. Orbit start still only binds the current session.
  module SessionEntry
    module_function

    def socket_path
      ENV["ORBIT_CODEX_SOCKET"] || File.join(ENV.fetch("CODEX_HOME", File.join(Dir.home, ".codex")),
                                          "app-server-control", "app-server-control.sock")
    end

    def doctor(thread_id: ENV["CODEX_THREAD_ID"], socket: socket_path)
      report = { "socket" => socket, "thread_id" => thread_id, "ready" => false }
      if thread_id.to_s.empty?
        report["reason"] = "Run orbit doctor inside the Codex session that will execute the task."
      else
        connection = CodexConnection.new(socket: socket, thread_id: thread_id)
        begin
          connection.connect!
          report.merge!("ready" => true, "project" => connection.cwd)
        rescue CodexConnection::Error => error
          report["reason"] = error.message
        ensure
          connection.close
        end
      end
      unless report["ready"]
        report["setup"] = "For future sessions, open Codex with: orbit codex. " \
                          "An already open embedded session is not moved automatically; " \
                          "finish or pause its work, then explicitly resume that same session through orbit codex resume."
      end
      report
    end

    # Lifecycle permission fields the proxy rewrites. Keys are the field names
    # accepted by thread/start, thread/resume and thread/fork; the mapping is
    # the config name users may pass with -c.
    PERMISSION_CONFIG_KEYS = {
      "sandbox_mode" => "sandbox",
      "approval_policy" => "approvalPolicy",
      "approvals_reviewer" => "approvalsReviewer"
    }.freeze
    DEFAULT_POLICY = { "approvalPolicy" => "never", "sandbox" => "danger-full-access" }.freeze
    BYPASS_POLICY = DEFAULT_POLICY
    AUTO_REVIEW_POLICY = {
      "approvalPolicy" => "on-request",
      "sandbox" => "workspace-write",
      "approvalsReviewer" => "auto_review"
    }.freeze
    SERVER_POLICY_KEYS = {
      "sandbox" => "sandbox_mode",
      "approvalPolicy" => "approval_policy",
      "approvalsReviewer" => "approvals_reviewer"
    }.freeze

    # Splits the user's permission options out of the TUI argv and folds them
    # into the one policy the lifecycle proxy applies (later options win per
    # field; unspecified fields keep Orbit's default). The TUI itself never
    # receives permission overrides, which is what made remote resume fail.
    # Returns [policy, kept argv].
    def permission_policy(argv)
      policy = DEFAULT_POLICY.dup
      kept = []
      index = 0
      while index < argv.length
        arg = argv[index]
        value = argv[index + 1]
        if %w[-s --sandbox].include?(arg) && value
          policy["sandbox"] = value
          index += 2
          next
        elsif (match = arg.match(/\A(?:-s|--sandbox)=(.*)\z/))
          policy["sandbox"] = match[1]
        elsif %w[-a --ask-for-approval].include?(arg) && value
          policy["approvalPolicy"] = value
          index += 2
          next
        elsif (match = arg.match(/\A(?:-a|--ask-for-approval)=(.*)\z/))
          policy["approvalPolicy"] = match[1]
        elsif arg == "--dangerously-bypass-approvals-and-sandbox"
          policy.merge!(BYPASS_POLICY)
        elsif %w[--approve-for-me --not-so-yolo].include?(arg)
          policy.merge!(AUTO_REVIEW_POLICY)
        elsif %w[-c --config].include?(arg)
          if (pair = permission_pair(value))
            policy[pair[0]] = pair[1]
            index += 2
            next
          end
          kept << arg
          if value
            kept << value
            index += 2
            next
          end
        elsif (pair = attached_permission_pair(arg))
          policy[pair[0]] = pair[1]
        else
          kept << arg
        end
        index += 1
      end
      [policy, kept]
    end

    def permission_pair(token)
      key, value = token.to_s.split("=", 2)
      mapped = PERMISSION_CONFIG_KEYS[key]
      return nil unless value && mapped

      [mapped, value.sub(/\A["']/, "").sub(/["']\z/, "")]
    end

    def attached_permission_pair(arg)
      body =
        if arg.start_with?("--config=")
          arg.delete_prefix("--config=")
        elsif arg.start_with?("-c=")
          arg.delete_prefix("-c=")
        elsif arg.start_with?("-c") && arg.length > 2
          arg.delete_prefix("-c")
        end
      body && permission_pair(body)
    end

    # v1 boundary: a profile can carry permission fields that Codex resolves
    # inside the TUI, which conflicts with the proxy's single permission
    # source. Reject it outright instead of silently overriding or dropping it;
    # no TOML parsing is added.
    def reject_profile!(argv)
      return unless argv.any? { |arg| %w[-p --profile].include?(arg) || arg.start_with?("--profile=") }

      raise ArgumentError, "orbit codex does not support -p/--profile: Codex resolves profile permissions " \
                           "inside the TUI, which conflicts with the single permission source of this entry. " \
                           "Remove the profile and pass permission options directly."
    end

    # The same policy in app-server config form. The proxy is the authority for
    # the TUI; this keeps direct control.sock connections (MCP, members, checks)
    # on the same defaults.
    def server_permission_args(policy)
      SERVER_POLICY_KEYS.filter_map do |policy_key, config_key|
        ["-c", "#{config_key}=#{JSON.generate(policy[policy_key])}"] if policy.key?(policy_key)
      end.flatten(1)
    end

    # Codex resolves per-tool MCP approval overrides by the actual tool name
    # (`task`, as exposed by scripts/orbit-mcp.cjs), not the server name.
    # `approve` means pre-approved by policy for this tool only; the default
    # `auto` would require approval for a tool without read-only annotations,
    # which an approval_policy=never session cannot grant.
    def codex_configuration(mcp:, socket:)
      "mcp_servers.orbit={command=\"node\",args=[#{JSON.generate(mcp)}]," \
        "env={ORBIT_CODEX_SOCKET=#{JSON.generate(socket)}}," \
        "tools={task={approval_mode=\"approve\"}}}"
    end

    def launch(argv)
      # This launcher and the host it starts resolve the MCP entry from this
      # release for the whole session; the lease keeps an update from deleting it.
      ReleaseLease.hold!
      if argv == ["--help"] || argv == ["-h"]
        puts "orbit codex [Codex options] [prompt]\norbit codex resume [session ID]\n\n" \
             "Open the Codex terminal UI on a local app-server owned by this launcher. " \
             "Works in an ordinary terminal, tmux or Herdr. The permissions of this command " \
             "(default full access; explicit sandbox or approval options win) are applied at every " \
             "user-thread lifecycle boundary inside the TUI (/new, /resume, /fork) by a launcher-owned " \
             "proxy, so the TUI itself never carries permission overrides and remote resume is not " \
             "rejected. Orbit control keeps using the app-server directly. -p/--profile is not supported. " \
             "Uses Codex model settings. " \
             "This entry does not start an Orbit task; the executing Agent uses the Orbit skill when appropriate."
        return 0
      end
      raise ArgumentError, "orbit codex uses the local native endpoint; do not pass --remote" if argv.any? { |arg| arg == "--remote" || arg.start_with?("--remote=") }
      raise ArgumentError, "orbit codex requires an interactive terminal" unless $stdin.tty? && $stdout.tty?
      raise ArgumentError, "unset ORBIT_CODEX_SOCKET before using the default local launcher" if ENV["ORBIT_CODEX_SOCKET"]
      reject_profile!(argv)

      policy, tui_argv = permission_policy(argv)
      directory = Dir.mktmpdir("orbit-host-", "/tmp")
      control_socket = File.join(directory, "control.sock")
      tui_socket = File.join(directory, "tui.sock")
      mcp = File.expand_path("../../scripts/orbit-mcp.cjs", __dir__)
      proxy_script = File.expand_path("../../scripts/codex-tui-proxy.cjs", __dir__)
      configuration = ["-c", codex_configuration(mcp: mcp, socket: control_socket)]
      env = { "ORBIT_CODEX_SOCKET" => control_socket }
      server_log = File.join(directory, "server.log")
      proxy_log = File.join(directory, "proxy.log")
      server = Process.spawn(env, "codex", *configuration, *server_permission_args(policy),
                             "app-server", "--listen", "unix://#{control_socket}",
                             in: File::NULL, out: server_log, err: [:child, :out], pgroup: true)
      if await_socket(server, control_socket, "Codex app-server", server_log) == :exited
        server = nil
        raise ArgumentError, "Codex app-server exited before it was ready: #{File.read(server_log).lines.last(8).join}"
      end
      proxy = Process.spawn(env, "node", proxy_script, tui_socket, control_socket, JSON.generate(policy),
                            in: File::NULL, out: proxy_log, err: [:child, :out], pgroup: true)
      if await_socket(proxy, tui_socket, "Codex TUI proxy", proxy_log) == :exited
        proxy = nil
        raise ArgumentError, "Codex TUI proxy exited before it was ready: #{File.read(proxy_log).lines.last(8).join}"
      end
      tui = Process.spawn(env, "codex", *configuration, "--remote", "unix://#{tui_socket}", *tui_argv)
      _, status = Process.wait2(tui)
      status.exitstatus || 1
    ensure
      if server
        warn "Orbit: closing this local host and stopping its execution; session history is retained."
        confirmed = File.socket?(control_socket) && shutdown_host(control_socket)
        terminate_process(proxy)
        File.unlink(tui_socket) if tui_socket && File.socket?(tui_socket)
        terminate_process(server)
      end
      if directory && File.directory?(directory)
        if confirmed
          FileUtils.remove_entry(directory)
        else
          warn "Orbit: shutdown was not fully confirmed; diagnostics retained at #{directory}"
        end
      end
    end

    # Waits until a spawned helper has bound its Unix socket. Returns :exited
    # when the process is already gone, so the caller can report its log.
    def await_socket(process, socket, label, log, timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.socket?(socket)
        return :exited if Process.waitpid(process, Process::WNOHANG)

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise ArgumentError, "#{label} did not become ready; inspect #{log}"
        end
        sleep 0.1
      end
      :ready
    end

    # Stops a helper owned by this launcher by process group; idempotent.
    def terminate_process(process)
      return unless process

      Process.kill("TERM", -process)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until Process.waitpid(process, Process::WNOHANG)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Process.kill("KILL", -process)
          Process.wait(process)
          break
        end
        sleep 0.1
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def shutdown_host(socket)
      server = CodexConnection.new(socket: socket, thread_id: nil).connect!
      failures = []
      server.loaded_threads.each do |id|
        connection = CodexConnection.new(socket: socket, thread_id: id)
        begin
          connection.connect!
          begin
            stop_tasks(socket, connection.cwd)
          rescue StandardError => error
            failures << error.message
          end
          connection.stop!
        rescue CodexConnection::ConnectionError => error
          # A never-materialized empty thread cannot have a running task.
          failures << error.message unless error.message.include?("does not expose turn history")
        rescue StandardError => error
          failures << "#{id}: #{error.message}"
        ensure
          connection.close
        end
      end
      raise CodexConnection::Error, failures.join("; ") unless failures.empty?
      true
    rescue CodexConnection::Error => error
      warn "orbit: host shutdown could not confirm all execution stopped: #{error.message}"
      false
    ensure
      server&.close
    end

    def stop_tasks(socket, project)
      records = Dir.glob(File.join(project, ".orbit", "tasks", "*", "state.json")).filter_map do |path|
        record = TaskRecord.new(File.dirname(path))
        state = record.state
        next unless state.dig("connection", "socket") == socket
        if %w[starting running].include?(state["status"])
          record.submit("stop", "reason" => "The user closed the Orbit Codex entry")
        end
        record
      end
      all_records = records.dup
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until records.empty?
        records.reject! { |record| !%w[starting running].include?(record.state["status"]) }
        break if records.empty?
        raise CodexConnection::Error, "task runtime did not finish shutdown" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      unresolved = all_records.select do |record|
        state = record.state
        state["cleanup_error"] || state["status"] == "stop_unconfirmed"
      end
      raise CodexConnection::Error, "Task cleanup remains unconfirmed: #{unresolved.map(&:path).join(', ')}" unless unresolved.empty?
    end
  end
end
