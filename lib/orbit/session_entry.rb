# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "codex_connection"
require_relative "task_record"

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
      if argv == ["--help"] || argv == ["-h"]
        puts "orbit codex [Codex options] [prompt]\norbit codex resume [session ID]\n\n" \
             "Open the Codex terminal UI on a local app-server owned by this launcher. " \
             "Works in an ordinary terminal, tmux or Herdr. Uses Codex model and permission settings. " \
             "This entry does not start an Orbit task; the executing Agent uses the Orbit skill when appropriate."
        return 0
      end
      raise ArgumentError, "orbit codex uses the local native endpoint; do not pass --remote" if argv.any? { |arg| arg == "--remote" || arg.start_with?("--remote=") }
      raise ArgumentError, "orbit codex requires an interactive terminal" unless $stdin.tty? && $stdout.tty?
      raise ArgumentError, "unset ORBIT_CODEX_SOCKET before using the default local launcher" if ENV["ORBIT_CODEX_SOCKET"]

      directory = Dir.mktmpdir("orbit-host-", "/tmp")
      socket = File.join(directory, "control.sock")
      mcp = File.expand_path("../../scripts/orbit-mcp.cjs", __dir__)
      configuration = ["-c", codex_configuration(mcp: mcp, socket: socket)]
      env = { "ORBIT_CODEX_SOCKET" => socket }
      log = File.join(directory, "server.log")
      server = Process.spawn(env, "codex", *configuration, "app-server", "--listen", "unix://#{socket}",
                             in: File::NULL, out: log, err: [:child, :out], pgroup: true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until File.socket?(socket)
        if Process.waitpid(server, Process::WNOHANG)
          server = nil
          raise ArgumentError, "Codex app-server exited before it was ready: #{File.read(log).lines.last(8).join}"
        end
        raise ArgumentError, "Codex app-server did not become ready; inspect #{log}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      tui = Process.spawn(env, "codex", *configuration, "--remote", "unix://#{socket}", *argv)
      _, status = Process.wait2(tui)
      status.exitstatus || 1
    ensure
      if server
        warn "Orbit: closing this local host and stopping its execution; session history is retained."
        confirmed = File.socket?(socket) && shutdown_host(socket)
        begin
          Process.kill("TERM", -server)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          until Process.waitpid(server, Process::WNOHANG)
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              Process.kill("KILL", -server)
              Process.wait(server)
              break
            end
            sleep 0.1
          end
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
      if directory && File.directory?(directory)
        if confirmed
          FileUtils.remove_entry(directory)
        else
          warn "Orbit: shutdown was not fully confirmed; diagnostics retained at #{directory}"
        end
      end
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
