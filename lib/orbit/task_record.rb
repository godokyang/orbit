# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "time"
require_relative "workspace_binding"
require_relative "workspace_snapshot"

module Orbit
  # Task-local records. The runtime is the sole state writer; other clients
  # submit commands through the inbox. Original instruction bytes are kept.
  class TaskRecord
    attr_reader :path

    def self.create(project_root:, instruction:, source:, connection:, review:, basis: [], estimate: {}, takeover: nil, clock: nil, artifact_root: nil)
      root = File.realpath(project_root)
      workspace = WorkspaceBinding.bind(project_root: root, artifact_root: artifact_root).merge("history" => [])
      path = File.join(root, ".orbit", "tasks", SecureRandom.uuid)
      FileUtils.mkdir_p(File.join(path, "inbox"), mode: 0o700)
      record = new(path)
      record.write("instruction.txt", instruction)
      # The takeover boundary is captured after this record's private directory
      # exists and before any state is written: a capture that fails removes the
      # half-created record instead of leaving a task that claims supervision.
      takeover_block = nil
      if takeover
        begin
          takeover_block = takeover_boundary(project_root: workspace.fetch("artifact_root"), source: source, instruction: instruction,
                                             payload: takeover, destination: File.join(path, "takeover-snapshot"),
                                             clock: clock)
        rescue StandardError
          FileUtils.rm_rf(path)
          raise
        end
      end
      documents = basis.map.with_index do |file, index|
        original = File.realpath(file)
        raise ArgumentError, "basis must be a file: #{file}" unless File.file?(original)

        bytes = File.binread(original)
        stored = "basis/#{index}-#{File.basename(original)}"
        record.write(stored, bytes)
        { "source" => original, "path" => stored, "sha256" => Digest::SHA256.hexdigest(bytes) }
      end
      record.save({
        "format" => "orbit-task-1", "id" => File.basename(path), "project_root" => root,
        **({ "takeover" => takeover_block } if takeover_block),
        "workspace" => workspace,
        "created_at" => Time.now.utc.iso8601, "status" => "starting",
        "instruction_source" => source, "basis" => documents, "amendments" => [],
        "connection" => connection, "review" => review, "estimate" => estimate,
        "checks" => [], "decisions" => [], "coverage_required" => true, "usage" => { "tokens" => nil }
      })
      record
    end

    # Mid-flight takeover of an already-executed requirement (main proposal
    # §3.4; audit A05/A07). Root asks the same `start` action to take over an
    # original native requirement that an uncontrolled execution already
    # worked on. The takeover block records only program-captured facts plus
    # Root's declared reason and prior scope; it never accepts a caller-supplied
    # digest, snapshot path or timestamp, and it never retroactively recognizes
    # the earlier execution as controlled or imports its usage, members or
    # checks into the new task.
    TAKEOVER_FORMAT = "orbit-takeover-1"
    TAKEOVER_KEYS = %w[reason prior_scope].freeze

    # Parses the optional takeover payload before any session work, so a bad
    # request fails without opening a connection or creating a task record.
    # `reason` is Root's own declaration and is kept verbatim; `prior_scope` is
    # a declaration when Root states one and stays unknown otherwise.
    def self.parse_takeover(text)
      raise ArgumentError, "takeover payload must be one JSON object" if text.nil?

      payload = JSON.parse(text)
      raise ArgumentError, "takeover payload must be one JSON object" unless payload.is_a?(Hash)

      unknown = payload.keys - TAKEOVER_KEYS
      unless unknown.empty?
        raise ArgumentError, "takeover payload may not state program-captured facts: #{unknown.sort.join(', ')} " \
                             "(allowed: #{TAKEOVER_KEYS.join(', ')})"
      end
      reason = payload["reason"]
      raise ArgumentError, "takeover payload needs a stated reason" unless reason.is_a?(String) && !reason.strip.empty?

      scope = payload["prior_scope"]
      if !scope.nil? && !scope.is_a?(String)
        raise ArgumentError, "takeover prior_scope must be a string when stated"
      end

      { "reason" => reason, "prior_scope" => scope.to_s.strip.empty? ? nil : scope }
    rescue JSON::ParserError => error
      raise ArgumentError, "takeover payload is not valid JSON: #{error.message}"
    end

    # The takeover boundary itself. The artifact digest and both timestamps are
    # produced here, by the program, from the real workspace and the process
    # clock; nothing in the payload can supply or override them. A workspace
    # that cannot be captured stably raises instead of recording a boundary.
    def self.takeover_boundary(project_root:, source:, instruction:, payload:, destination:, clock: nil)
      raise ArgumentError, "the takeover boundary needs a destination inside the task" if destination.to_s.empty?

      root = File.realpath(project_root)
      capture = WorkspaceSnapshot.capture(project_root: root, destination: destination)
      # Stamped after the capture, so the recorded boundary never claims a time
      # earlier than the bytes it preserves.
      now = (clock || -> { Time.now.utc }).call.utc
      # The preserved snapshot lives next to the record it belongs to; the
      # stored path is relative to the task directory.
      snapshot_relative = File.basename(File.expand_path(destination))
      bytes = instruction.to_s.b
      scope = payload["prior_scope"]
      {
        "format" => TAKEOVER_FORMAT,
        "requested_at" => now.iso8601,
        "reason" => payload.fetch("reason"),
        "prior_scope" => scope.nil? ? { "status" => "unknown", "text" => nil } : { "status" => "declared", "text" => scope },
        "requirement" => {
          "source_kind" => source["kind"], "native_message_id" => source["id"],
          "instruction_sha256" => Digest::SHA256.hexdigest(bytes), "instruction_bytes" => bytes.bytesize
        },
        "artifact" => { "root" => capture.fetch("source_root"), "digest" => capture.fetch("digest"),
                        "snapshot_path" => snapshot_relative,
                        "captured_at" => now.iso8601, "git_head" => capture["git_head"],
                        "source" => "program_workspace_snapshot" },
        "supervision" => { "starts_at" => now.iso8601,
                           "boundary" => "supervision starts at this takeover; the earlier execution of this requirement was not controlled" },
        "prior_execution" => { "recognized_as_controlled" => false, "imported" => [],
                               "note" => "the earlier execution's usage, members and checks are not carried into this task" }
      }
    end

    def initialize(path)
      @path = File.realpath(path)
    end

    def state
      JSON.parse(File.read(File.join(path, "state.json")))
    end

    def save(value)
      write("state.json", JSON.pretty_generate(value) + "\n")
    end

    # Task-owned authoritative member list, written only by the OMP extension's
    # synchronous registration gate (scripts/orbit-register-member). TaskRuntime
    # reads this from its normal tick and from explicit stop retries after a
    # crash, so actual member ids are rediscoverable without plugin memory.
    # Deliberately a separate file from state.json: the runtime process is the
    # sole state.json writer and must not race concurrent member registration.
    # Raises on unreadable/corrupt content: a silently empty list would let a
    # later registration overwrite real member ids, breaking crash retry and
    # the registration gate. Callers must surface the failure, not swallow it.
    def members
      file = File.join(path, "members.json")
      return [] unless File.exist?(file)

      JSON.parse(File.read(file))
    end

    # Atomic, durable registration. Returns { "ok" => true, "member" => entry }
    # (optionally with "event_error" when the audit event could not be appended)
    # or { "ok" => false, "reason" => ..., "thread_id" => ... }. A duplicate
    # member id is refused and never overwrites the existing record.
    def register_member(member_id, requested_name:, status: "registered", model: nil, tool_call_id: nil, reason: nil, abort_confirmed: nil, now: Time.now.utc)
      unless member_id.to_s.match?(/\Aorbit-[A-Za-z0-9-]+\z/)
        return { "ok" => false, "reason" => "invalid_member_id", "thread_id" => member_id }
      end
      unless %w[registered refused].include?(status)
        return { "ok" => false, "reason" => "invalid_status", "thread_id" => member_id }
      end
      if requested_name.to_s.strip.empty?
        return { "ok" => false, "reason" => "missing_requested_name", "thread_id" => member_id }
      end

      with_members_lock do
        list = members
        if list.any? { |member| member["thread_id"] == member_id }
          return { "ok" => false, "reason" => "duplicate_member_id", "thread_id" => member_id }
        end

        entry = {
          "thread_id" => member_id, "requested_name" => requested_name, "status" => status,
          "registered_at" => now.iso8601
        }
        entry["model"] = model if model
        entry["tool_call_id"] = tool_call_id if tool_call_id
        entry["reason"] = reason if reason
        entry["abort_confirmed"] = abort_confirmed unless abort_confirmed.nil?
        durable_write("members.json", JSON.pretty_generate(list + [entry]) + "\n")
        result = { "ok" => true, "member" => entry }
        begin
          event(
            status == "registered" ? "member_registered" : "member_registration_refused",
            { "thread_id" => member_id, "requested_name" => requested_name, "status" => status }.tap do |details|
              details["refusal_reason"] = reason if reason
            end
          )
        rescue StandardError => error
          # The member record IS durable at this point; never claim otherwise.
          # Surface the audit-event failure so operators can reconcile events.jsonl.
          result["event_error"] = "#{error.class}: #{error.message}"
        end
        result
      end
    rescue StandardError => error
      { "ok" => false, "reason" => "#{error.class}: #{error.message}", "thread_id" => member_id }
    end

    # Dedicated model-drift record for an ALREADY REGISTERED member (ADR-009):
    # override/auth-fallback resolution changed the member's final model
    # between dispatch and its first provider request. This is NOT a second
    # registration — register_member refuses duplicate ids — but an update to
    # the existing entry plus an audit event, under the same members lock and
    # durable-write discipline. The original registration stays authoritative;
    # `model_drift` is denormalized onto the member so TaskRuntime sees it on
    # its normal members.json read without parsing the event log. A drift for
    # an unknown member id is refused: silently accepting one would let a
    # non-member fabricate task membership.
    def record_member_model_drift(member_id, expected:, actual:, abort_attempted: nil, abort_confirmed: nil, now: Time.now.utc)
      pattern = %r{\A[^\s/]+/[^\s]+\z}
      unless expected.to_s.match?(pattern) && actual.to_s.match?(pattern)
        return { "ok" => false, "reason" => "invalid_model_identifier", "thread_id" => member_id }
      end
      with_members_lock do
        list = members
        index = list.index { |member| member["thread_id"] == member_id }
        unless index
          return { "ok" => false, "reason" => "unknown_member_id", "thread_id" => member_id }
        end

        # abort evidence is recorded honestly: `abort_attempted` says the
        # extension fired the abort path; `abort_confirmed` is TRUE only when
        # the registry flip read back `aborted`. ctx.abort() itself has no
        # public completion signal, so it never produces confirmed:true on
        # its own. TaskRuntime must treat a member with model_drift as failed
        # regardless — never as a successfully registered member.
        drift = { "expected" => expected, "actual" => actual, "recorded_at" => now.iso8601 }
        drift["abort_attempted"] = abort_attempted unless abort_attempted.nil?
        drift["abort_confirmed"] = abort_confirmed unless abort_confirmed.nil?
        list[index] = { **list[index], "model_drift" => drift }
        durable_write("members.json", JSON.pretty_generate(list) + "\n")
        result = { "ok" => true, "thread_id" => member_id, "model_drift" => drift }
        begin
          event("member_model_drift", { "thread_id" => member_id, "expected" => expected, "actual" => actual })
        rescue StandardError => error
          result["event_error"] = "#{error.class}: #{error.message}"
        end
        result
      end
    rescue StandardError => error
      { "ok" => false, "reason" => "#{error.class}: #{error.message}", "thread_id" => member_id }
    end

    # write() plus a directory fsync so the rename itself survives a crash.
    # Used only for member registration; other write paths stay unchanged.
    def durable_write(relative, bytes)
      write(relative, bytes)
      directory = File.open(path, File::RDONLY)
      begin
        directory.fsync
      ensure
        directory.close
      end
    end

    def with_members_lock
      File.open(File.join(path, "members.lock"), "w", 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def write(relative, bytes)
      destination = File.join(path, relative)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      temporary = "#{destination}.#{SecureRandom.hex(8)}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.rename(temporary, destination)
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end
    end

    def event(type, details = {})
      File.open(File.join(path, "events.jsonl"), "a", 0o600) do |file|
        file.puts(JSON.generate({ "at" => Time.now.utc.iso8601, "type" => type }.merge(details)))
        file.flush
      end
    end

    def with_runtime_lock
      File.open(File.join(path, "runtime.lock"), "w", 0o600) do |file|
        raise ArgumentError, "this task already has a runtime" unless file.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def with_root_lock(thread_id)
      directory = File.join(state.fetch("project_root"), ".orbit", "session-locks")
      FileUtils.mkdir_p(directory, mode: 0o700)
      lock_path = File.join(directory, "#{Digest::SHA256.hexdigest(thread_id)}.lock")
      File.open(lock_path, "w", 0o600) do |file|
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          raise ArgumentError, "this Root session already has an Orbit task process"
        end

        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def submit(type, details = {})
      id = "#{Time.now.utc.strftime('%Y%m%d%H%M%S%6N')}-#{SecureRandom.hex(6)}"
      write("inbox/#{id}.json", JSON.generate(details.merge("type" => type)))
      id
    end

    # Inbox files are written by Orbit clients. A malformed file (invalid JSON,
    # not an object, or missing a command type) is rejected and removed with a
    # command_rejected event instead of raising into the runtime loop.
    def commands
      Dir.glob(File.join(path, "inbox", "*.json")).sort.each do |file|
        command = begin
          JSON.parse(File.read(file))
        rescue JSON::ParserError => error
          event("command_rejected", "file" => File.basename(file),
                "reason" => "malformed command JSON", "error" => error.message)
          next
        end
        unless command.is_a?(Hash) && command["type"].is_a?(String) && !command["type"].strip.empty?
          event("command_rejected", "file" => File.basename(file), "reason" => "command is missing a type")
          next
        end
        yield command
      ensure
        File.unlink(file)
      end
    end

    def inputs(current_state = state)
      result = {
        "instruction" => File.read(File.join(path, "instruction.txt")),
        "amendments" => current_state.fetch("amendments").map do |item|
          item.merge("text" => File.read(File.join(path, item.fetch("path"))))
        end,
        "basis" => current_state.fetch("basis").map do |item|
          item.merge("text" => File.read(File.join(path, item.fetch("path"))))
        end
      }
      continuation = current_state["continuation"]
      if continuation
        result["continuation"] = { "source" => continuation.fetch("source"),
                                   "text" => File.read(File.join(path, continuation.fetch("message_path"))) }
      end
      result
    end

    def input_digest(current_state = state)
      Digest::SHA256.hexdigest(JSON.generate(inputs(current_state)))
    end
  end
end
