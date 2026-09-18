# frozen_string_literal: true

require "json"
require "open3"
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

    # Options whose following token is a value, used to locate the first
    # positional (subcommand) without treating a value as one.
    VALUE_OPTIONS = %w[-c --config -m --model -s --sandbox -a --ask-for-approval
                       -C --cd --enable --disable -i --image -p --profile --remote].freeze
    PERMISSION_OPTIONS = %w[-s --sandbox -a --ask-for-approval
                            --dangerously-bypass-approvals-and-sandbox --full-auto --approve-for-me].freeze
    PERMISSION_CONFIG_KEYS = %w[sandbox_mode approval_policy approvals_reviewer].freeze
    SANDBOX_MODES = %w[read-only workspace-write danger-full-access].freeze
    FULL_ACCESS_ARGS = ["-s", "danger-full-access", "-a", "never"].freeze
    # Orbit's daily full-access default belongs to the app-server this launcher
    # owns. Codex restores a resumed session's approval policy but not its
    # sandbox, so a remote resume without permission flags otherwise falls back
    # to the user's configured workspace-write sandbox.
    FULL_ACCESS_CONFIG = {
      "sandbox_mode" => JSON.generate("danger-full-access"),
      "approval_policy" => JSON.generate("never")
    }.freeze
    BYPASS_CONFIG = {
      "sandbox_mode" => JSON.generate("danger-full-access"),
      "approval_policy" => JSON.generate("never")
    }.freeze
    AUTO_REVIEW_CONFIG = {
      "sandbox_mode" => JSON.generate("workspace-write"),
      "approval_policy" => JSON.generate("on-request"),
      "approvals_reviewer" => JSON.generate("auto_review")
    }.freeze

    def first_positional_index(argv)
      skip_value = false
      argv.each_with_index do |arg, index|
        if skip_value
          skip_value = false
          next
        end
        return index unless arg.start_with?("-")

        skip_value = VALUE_OPTIONS.include?(arg)
      end
      nil
    end

    def first_positional(argv)
      index = first_positional_index(argv)
      index && argv[index]
    end

    def resume_invocation?(argv)
      first_positional(argv) == "resume"
    end

    # The explicit UUID resume target, or nil when the target is chosen inside
    # the TUI (--last, picker or a session name).
    def resume_thread_id(argv)
      index = first_positional_index(argv)
      return nil unless index && argv[index] == "resume"

      skip_value = false
      argv[(index + 1)..].to_a.each do |arg|
        if skip_value
          skip_value = false
          next
        end
        if arg.start_with?("-")
          skip_value = VALUE_OPTIONS.include?(arg)
          next
        end
        return arg if arg.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)

        return nil
      end
      nil
    end

    def last_resume?(argv)
      index = first_positional_index(argv)
      index && argv[index] == "resume" && argv.include?("--last")
    end

    # The working directory this invocation resumes in: an explicit -C/--cd or
    # the current directory.
    def resume_cwd(argv)
      argv.each_with_index do |arg, index|
        return arg.delete_prefix("--cd=") if arg.start_with?("--cd=")
        return argv[index + 1] if %w[-C --cd].include?(arg) && argv[index + 1]
      end
      Dir.pwd
    end

    # The explicit UUID target, or the newest resumable session recorded for
    # this project when --last is used. Nil when the target is chosen inside
    # the TUI (picker).
    def resume_target(argv)
      explicit = resume_thread_id(argv)
      return explicit if explicit
      return nil unless last_resume?(argv)

      latest_project_thread_id(resume_cwd(argv))
    end

    # Replaces Codex's global `--last` with the project-scoped UUID so the TUI
    # cannot resume another project's session. Returns argv unchanged when
    # there is nothing to replace.
    def with_resume_id(argv, thread_id)
      return argv if thread_id.to_s.empty?

      index = first_positional_index(argv)
      return argv unless index && argv[index] == "resume"

      tail = argv[(index + 1)..].to_a.reject { |arg| arg == "--last" }
      argv[0..index] + [thread_id] + tail
    end

    # Resume argv for the TUI. An explicit UUID is already in the argv and must
    # stay untouched; only a target resolved from `--last` replaces `--last`.
    def resume_tui_argv(argv, kept, target)
      return kept if target.to_s.empty? || !resume_thread_id(argv).nil?

      with_resume_id(kept, target)
    end

    # New-session TUI arguments. Explicit approval overrides only approval;
    # explicit sandbox and combined permission modes choose their own sandbox.
    # Resume argv is not passed here: the launcher applies resume permissions
    # to its app-server because the remote resume TUI rejects overrides.
    def explicit_permissions?(argv)
      argv.each_with_index.any? do |arg, index|
        next true if PERMISSION_OPTIONS.include?(arg)
        next true if arg.start_with?("--sandbox=", "--ask-for-approval=", "--full-auto=", "--approve-for-me=")
        next true if PERMISSION_CONFIG_KEYS.any? { |key| arg.start_with?("-c#{key}=", "-c=#{key}=", "--config=#{key}=") }
        next true if ["-c", "--config"].include?(arg) && PERMISSION_CONFIG_KEYS.any? { |key| argv[index + 1].to_s.start_with?("#{key}=") }

        false
      end
    end

    def explicit_sandbox?(argv)
      argv.each_with_index.any? do |arg, index|
        next true if %w[-s --sandbox --dangerously-bypass-approvals-and-sandbox --full-auto --approve-for-me].include?(arg)
        next true if arg.start_with?("--sandbox=", "--full-auto=", "--approve-for-me=")
        next true if arg.start_with?("-csandbox_mode=", "-c=sandbox_mode=", "--config=sandbox_mode=")
        next true if ["-c", "--config"].include?(arg) && argv[index + 1].to_s.start_with?("sandbox_mode=")

        false
      end
    end

    def default_permission_args(argv)
      return [] if resume_invocation?(argv) || explicit_sandbox?(argv)
      # An approval-only override (for example -a never) must not silently
      # restore Codex's configured workspace-write sandbox.
      return ["-s", "danger-full-access"] if explicit_permissions?(argv)

      FULL_ACCESS_ARGS.dup
    end

    # Codex rejects permission overrides when the TUI resumes a remote task
    # ("Permission overrides are not supported when resuming a remote task"),
    # so a resume argv must not carry them. The launcher applies the user's
    # explicit options to the app-server it owns instead. New sessions keep the
    # native TUI options unchanged. Returns [config overrides, kept argv].
    def split_permissions(argv)
      overrides = {}
      kept = []
      index = 0
      while index < argv.length
        arg = argv[index]
        value = argv[index + 1]
        if %w[-s --sandbox].include?(arg) && value
          overrides["sandbox_mode"] = JSON.generate(value)
          index += 2
          next
        elsif (match = arg.match(/\A(?:-s|--sandbox)=(.*)\z/))
          overrides["sandbox_mode"] = JSON.generate(match[1])
        elsif %w[-a --ask-for-approval].include?(arg) && value
          overrides["approval_policy"] = JSON.generate(value)
          index += 2
          next
        elsif (match = arg.match(/\A(?:-a|--ask-for-approval)=(.*)\z/))
          overrides["approval_policy"] = JSON.generate(match[1])
        elsif arg == "--dangerously-bypass-approvals-and-sandbox"
          overrides.merge!(BYPASS_CONFIG)
        elsif %w[--approve-for-me --not-so-yolo].include?(arg)
          overrides.merge!(AUTO_REVIEW_CONFIG)
        elsif %w[-c --config].include?(arg)
          if (pair = permission_pair(value))
            overrides[pair[0]] = pair[1]
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
          overrides[pair[0]] = pair[1]
        else
          kept << arg
        end
        index += 1
      end
      [overrides, kept]
    end

    def permission_pair(token)
      key, value = token.to_s.split("=", 2)
      return nil unless value && PERMISSION_CONFIG_KEYS.include?(key)

      [key, value]
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

    # Explicit permission options become app-server configuration, overriding
    # Orbit's full-access default only for the options actually given. With no
    # defaults (unknown resume target) Codex's own configuration stays in use.
    def server_permission_args(overrides, defaults: FULL_ACCESS_CONFIG)
      defaults.merge(overrides).flat_map { |key, value| ["-c", "#{key}=#{value}"] }
    end

    def codex_home
      home = ENV["CODEX_HOME"].to_s
      home.empty? ? File.join(Dir.home, ".codex") : home
    end

    def rollout_path(thread_id)
      suffix = "*#{thread_id}.jsonl"
      %w[sessions archived_sessions].each do |group|
        root = File.join(codex_home, group)
        next unless File.directory?(root)

        matches = Dir.glob(File.join(root, "**", suffix))
        return matches.max_by { |path| File.mtime(path) } unless matches.empty?
      end
      nil
    end

    def canonical_path(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    def same_project_cwd?(recorded, project)
      !recorded.to_s.empty? && canonical_path(recorded) == canonical_path(project)
    end

    # The newest rollout Codex recorded for this project that has a user turn.
    # Bounded to this project's own records so `resume --last` can be replaced
    # by a project-scoped UUID instead of Codex's global (cross-project) --last
    # selection; no session discovery beyond the current directory.
    def latest_project_thread_id(project)
      root = File.join(codex_home, "sessions")
      return nil unless File.directory?(root)

      Dir.glob(File.join(root, "**", "*.jsonl")).sort_by { |path| File.mtime(path) }.reverse.each do |path|
        meta = rollout_session_meta(path)
        next unless meta.is_a?(Hash) && meta["originator"] == "codex-tui"
        next unless same_project_cwd?(meta["cwd"], project)
        next unless saved_turn_context_from(path)
        return meta["id"] unless meta["id"].to_s.empty?
      end
      nil
    end

    def rollout_session_meta(path)
      File.foreach(path) do |line|
        item = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        return item["payload"] if item["type"] == "session_meta"
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # The last recorded turn context for this thread, or nil when unavailable.
    # Codex restores the approval policy and reviewer itself but not the
    # sandbox, so the launcher resumes with the same sandbox instead of
    # widening or narrowing it.
    def saved_turn_context(thread_id)
      return nil if thread_id.to_s.empty?

      path = rollout_path(thread_id)
      path && saved_turn_context_from(path)
    end

    def saved_turn_context_from(path)
      settings = nil
      File.foreach(path) do |line|
        item = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next unless item["type"] == "turn_context"

        payload = item["payload"] || {}
        sandbox = payload.dig("sandbox_policy", "type")
        next unless SANDBOX_MODES.include?(sandbox)

        settings = {
          "sandbox_mode" => sandbox,
          "approval_policy" => payload["approval_policy"],
          "approvals_reviewer" => payload["approvals_reviewer"]
        }
      end
      settings
    rescue SystemCallError, IOError
      nil
    end

    # Permission configuration for a resume. Codex restores the saved approval
    # policy and reviewer but not the sandbox, so:
    # - an explicit sandbox is applied through the app-server;
    # - without one, the sandbox Codex recorded for that session is restored
    #   (never the full-access default);
    # - a target chosen inside the TUI (picker) is not project-safe and fails
    #   before launch; --last is resolved to this project's own newest
    #   resumable session by the launcher and passed to the TUI as that UUID;
    # - an explicit approval option that differs from the saved approval policy
    #   cannot be honored and fails before launch.
    # Returns [defaults, notice].
    def resume_permission_defaults(argv, overrides, target_id: resume_target(argv))
      if target_id.nil?
        if last_resume?(argv)
          raise ArgumentError, "orbit codex resume --last found no resumable session recorded for this " \
                               "project (#{resume_cwd(argv)}); pass an explicit session ID."
        end
        raise ArgumentError, "orbit codex resume requires an explicit session ID (UUID): a target chosen " \
                             "inside Codex (picker) cannot be checked before launch. Pass the session ID, " \
                             "or start a new session."
      end

      saved = saved_turn_context(target_id)
      verify_resume_approval!(saved, overrides)
      return [{}, nil] if overrides.key?("sandbox_mode")
      if saved.nil?
        raise ArgumentError, "orbit codex resume could not determine this session's saved sandbox; pass " \
                             "an explicit sandbox option (for example -s danger-full-access) to choose one, " \
                             "or start a new session."
      end
      return [{ "sandbox_mode" => JSON.generate("danger-full-access") }, nil] if saved["sandbox_mode"] == "danger-full-access"

      [{ "sandbox_mode" => JSON.generate(saved["sandbox_mode"]) },
       "resuming with this session's saved #{saved['sandbox_mode']} sandbox; pass an explicit sandbox option to override it."]
    end

    # An explicit approval option cannot change a resumed thread: Codex
    # restores the saved approval policy and reviewer over app-server
    # configuration. Fail with the concrete mismatch rather than continuing
    # with permissions the user did not choose.
    def verify_resume_approval!(saved, overrides)
      requested = overrides.keys & %w[approval_policy approvals_reviewer]
      return if requested.empty?

      if saved.nil?
        raise ArgumentError, "cannot verify that Codex will apply the explicit #{requested.join('/')} " \
                             "option(s) to this resume target; resume an explicit session ID (UUID) or start a new session."
      end

      changed = requested.reject do |key|
        requested_value = overrides[key].to_s.delete('"')
        saved_value = saved[key]
        saved_value.is_a?(String) ? saved_value == requested_value : JSON.generate(saved_value) == requested_value
      end
      return if changed.empty?

      details = changed.map { |key| "#{key}=#{overrides[key].to_s.delete('"')} (saved: #{saved[key].inspect})" }
      raise ArgumentError, "Codex keeps this session's saved approval settings on resume, so the explicit " \
                           "#{details.join(', ')} cannot take effect. Resume without that option, or start a new " \
                           "session with it."
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
             "Works in an ordinary terminal, tmux or Herdr. New sessions default to full access; " \
             "explicit permission options are kept. A resume restores the sandbox Codex recorded for " \
             "that session and applies explicit permission options to this launcher's app-server instead " \
             "of the remote TUI, which rejects them. --last is resolved to the newest resumable session " \
             "recorded for this project before launch, so Codex cannot resume another project's session; " \
             "without such a record the resume fails and an explicit session ID is required. " \
             "Uses Codex model settings. " \
             "This entry does not start an Orbit task; the executing Agent uses the Orbit skill when appropriate."
        return 0
      end
      raise ArgumentError, "orbit codex uses the local native endpoint; do not pass --remote" if argv.any? { |arg| arg == "--remote" || arg.start_with?("--remote=") }
      raise ArgumentError, "orbit codex requires an interactive terminal" unless $stdin.tty? && $stdout.tty?
      raise ArgumentError, "unset ORBIT_CODEX_SOCKET before using the default local launcher" if ENV["ORBIT_CODEX_SOCKET"]

      overrides, resume_argv = split_permissions(argv)
      defaults = FULL_ACCESS_CONFIG
      target = nil
      if resume_invocation?(argv)
        # A resume never applies the full-access default to the sandbox: the
        # saved sandbox is restored, an explicit sandbox wins, and an explicit
        # approval option Codex would override fails before launch. --last is
        # resolved to this project's own UUID so Codex cannot pick another
        # project's session.
        target = resume_target(argv)
        defaults, notice = resume_permission_defaults(argv, overrides, target_id: target)
        warn "Orbit: #{notice}" if notice
      end

      directory = Dir.mktmpdir("orbit-host-", "/tmp")
      socket = File.join(directory, "control.sock")
      mcp = File.expand_path("../../scripts/orbit-mcp.cjs", __dir__)
      configuration = ["-c", codex_configuration(mcp: mcp, socket: socket)]
      env = { "ORBIT_CODEX_SOCKET" => socket }
      log = File.join(directory, "server.log")
      server = Process.spawn(env, "codex", *configuration, *server_permission_args(overrides, defaults: defaults),
                             "app-server", "--listen", "unix://#{socket}",
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
      tui_argv = resume_invocation?(argv) ? resume_tui_argv(argv, resume_argv, target) : argv
      tui = Process.spawn(env, "codex", *configuration, *default_permission_args(tui_argv),
                          "--remote", "unix://#{socket}", *tui_argv)
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
