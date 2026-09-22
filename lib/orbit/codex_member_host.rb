# frozen_string_literal: true

require "fileutils"
require "time"
require "tmpdir"
require_relative "codex_connection"

module Orbit
  # Owns one Codex app-server for this task's cross-host execution members
  # (OpenCode Root -> Codex member). The runtime holds its lifetime and
  # persists the returned record before any member turn starts, so an
  # explicit stop retry can reconnect from the task record. The control
  # address stays short for the Unix socket limit (macOS); the app-server
  # runs in its own process group so process-group exit is verifiable.
  #
  # This host never relaxes stop evidence: member creation stays on
  # CodexConnection's `approvalPolicy: never` / `danger-full-access` / no
  # Orbit MCP path, and stop is never inferred from a missing socket.
  class CodexMemberHost
    READY_TIMEOUT = 15.0
    SHUTDOWN_GRACE = 5.0
    DIR_PREFIX = "orbit-mbr-"

    class Error < StandardError; end

    def initialize(cwd:, executable: "codex", env: {})
      @cwd = File.realpath(cwd)
      @executable = executable
      @env = env
    end

    # Starts the member app-server and returns its durable record. The caller
    # persists this record before using it.
    def start
      directory = Dir.mktmpdir(DIR_PREFIX, "/tmp")
      socket = File.join(directory, "m.sock")
      log = File.join(directory, "server.log")
      server = Process.spawn(@env, @executable, "app-server", "--listen", "unix://#{socket}",
                             in: File::NULL, out: log, err: [:child, :out], pgroup: true)
      wait_until_ready(server, socket, log)
      {
        "kind" => "codex", "socket" => socket, "pid" => server, "pgid" => server,
        "directory" => directory, "log" => log, "started_at" => Time.now.utc.iso8601
      }
    rescue StandardError => error
      if server
        outcome = shutdown("pid" => server, "pgid" => server, "socket" => socket,
                           "directory" => directory, "log" => log)
        unless outcome["confirmed"]
          raise Error, "#{error.message}; member app-server pid #{server} stop unconfirmed; inspect #{log}"
        end
      elsif directory && File.directory?(directory)
        FileUtils.remove_entry(directory)
      end
      raise error
    end

    # Creates one member thread with the Codex-side model (or the explicitly
    # authorized one) and the artifact directory passed as cwd.
    def create_member(host, model: nil, cwd: @cwd)
      directory = File.realpath(cwd)
      connection = connection_for(host, nil)
      begin
        resolved = model.to_s.empty? ? connection.configured_model(cwd: directory) : model.to_s
        raise Error, "Codex member model is unavailable from the Codex side" if resolved.empty?

        thread_id = connection.create_member(model: resolved, cwd: directory, disable_orbit_mcp: false)
        { "thread_id" => thread_id, "model" => resolved }
      ensure
        connection.close
      end
    end

    # The member thread cannot be bound before its first turn, so the turn is
    # started through the unbound host connection (same call the Root-hosted
    # Codex member path uses); binding happens later when results are read.
    def start_member(host, thread_id, instructions)
      connection = connection_for(host, nil)
      begin
        connection.start_member(thread_id, instructions)
      ensure
        connection.close
      end
    end

    def connection_for(host, thread_id)
      CodexConnection.new(socket: host.fetch("socket"), thread_id: thread_id.to_s).connect!
    end

    # Process-group existence is the exit evidence; a socket that disappeared
    # is not by itself proof that member execution stopped.
    def alive?(host)
      group_alive?(host)
    end

    # Terminates the member app-server process group and verifies its exit.
    # Diagnostics are retained when exit is not confirmed.
    def shutdown(host)
      pgid = Integer(host.fetch("pgid"))
      unless alive?(host)
        cleanup(host)
        return { "confirmed" => true, "already_exited" => true, "pgid" => pgid, "socket" => host["socket"] }
      end

      begin
        Process.kill("TERM", -pgid)
      rescue Errno::EPERM
        # Darwin reports EPERM for a zombie-only group; the re-probe below
        # decides, not this signal request.
        nil
      end
      confirmed = wait_exit(host, SHUTDOWN_GRACE)
      unless confirmed
        begin
          Process.kill("KILL", -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        confirmed ||= wait_exit(host, 2.0)
      end
      cleanup(host) if confirmed
      { "confirmed" => confirmed, "pgid" => pgid, "socket" => host["socket"], "log" => host["log"] }
    rescue Errno::ESRCH
      cleanup(host)
      { "confirmed" => true, "already_exited" => true, "pgid" => host["pgid"] }
    rescue SystemCallError => error
      { "confirmed" => false, "error" => error.message, "pgid" => host["pgid"] }
    end

    private

    def wait_until_ready(server, socket, log)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
      until File.socket?(socket)
        if Process.waitpid(server, Process::WNOHANG)
          raise Error, "Codex member app-server exited before ready: #{File.read(log).lines.last(8).join.strip}"
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise Error, "Codex member app-server did not become ready; inspect #{log}"
        end
        sleep 0.1
      end
    end

    # A group whose app-server exited normally can still hold its own zombie
    # wrapper until this process reaps it; Darwin answers EPERM for that
    # group instead of ESRCH. Reaping our child and re-probing separates a
    # dead group from a live one without treating "not permitted" as proof.
    def group_alive?(host)
      pgid = Integer(host.fetch("pgid"))
      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      begin
        Process.waitpid(Integer(host.fetch("pid")), Process::WNOHANG)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
      begin
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end

    def wait_exit(host, seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        return true unless group_alive?(host)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
    end

    def cleanup(host)
      directory = host["directory"]
      FileUtils.remove_entry(directory) if directory && File.directory?(directory)
    end
  end
end
