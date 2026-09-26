# frozen_string_literal: true

require "json"
require "digest"
require "find"
require "pathname"
require "securerandom"
require "time"
require "zlib"
require_relative "version"
require_relative "task_record"
require_relative "task_runtime"

module Orbit
  # User-invoked, local-only task evidence export.
  #
  # `orbit export TASK --output FILE` packs one task's observable records into a
  # single portable tar.gz: the at-export-time state, a fact-only timeline that
  # joins events.jsonl with the plugin's task-local collaboration.jsonl, the
  # check snapshots/outputs, basis and amendments, safely attributable native
  # OMP session segments, plus a deterministic manifest with a sha256 file
  # inventory. The export is read-only for the task: no uploads, no model
  # calls, no state changes. Missing, old, invalid or unattributable evidence
  # is marked as such in the manifest and timeline — never silently omitted
  # and never silently included. A still-running task is exported as a
  # point-in-time snapshot and labelled in flight; concurrently appended JSONL
  # is detected through its missing trailing newline, and files that change
  # size while being packaged abort the export instead of corrupting it.
  module TaskEvidence
    ARCHIVE_FORMAT = "orbit-task-evidence-export-1"
    LOCK_FILES = %w[runtime.lock members.lock].freeze
    SQLITE_LIVE_SUFFIXES = %w[-shm -wal].freeze
    # TaskRuntime event types whose archive-side check directory is linked into
    # timeline entries (fact association only, no defect judgment).
    CHECK_LINKED_TYPES = %w[check_started check_finished finding_recorded finding_resolved correction_sent].freeze
    SOURCE_ORDER = { "events.jsonl" => 0, "collaboration.jsonl" => 1 }.freeze

    class Error < StandardError; end

    module_function

    # `record` is a TaskRecord; `output` the destination archive path. Returns
    # a JSON-able summary. Raises Error/ArgumentError/SystemCallError on
    # failure; the destination is never left as a partial archive.
    def export(record:, output:, agent_dir: nil)
      output = File.expand_path(output)
      task_path = record.path
      state, state_bytes = load_state(record)
      validate_output!(output, task_path)
      exported_at = Time.now.utc.iso8601

      walk = walk_task(task_path)
      timeline, sources, missing, collaboration = observe(task_path, state.fetch("id"))
      sessions = native_sessions(state, exported_at, task_path, agent_dir: agent_dir)
      missing.concat(sessions.filter_map { |session| session.delete("missing_entry") })

      inventory = []
      manifest = nil
      temporary = File.join(File.dirname(output), ".orbit-export-#{SecureRandom.hex(8)}.tmp")
      begin
        File.open(temporary, "wb", 0o600) do |raw|
          Zlib::GzipWriter.wrap(raw) do |gzip|
            gzip.mtime = 0
            writer = TarWriter.new(gzip)
            walk[:files].each do |relative|
              absolute = File.join(task_path, relative)
              # collaboration.jsonl may contain lines belonging to other Orbit
              # tasks of the same native session; only the task-attributable
              # subset is ever packaged, and any omission is recorded.
              if relative == "collaboration.jsonl" && collaboration["subset_text"]
                writer.write_content("task/#{relative}", collaboration.fetch("subset_text"))
                inventory << { "path" => relative, "kind" => "file",
                               "bytes" => collaboration.fetch("subset_bytes"),
                               "sha256" => collaboration.fetch("subset_sha256"), "mode" => "0600" }
              else
                sha256, bytes, mode = writer.write_file("task/#{relative}", absolute)
                inventory << { "path" => relative, "kind" => "file", "bytes" => bytes,
                               "sha256" => sha256, "mode" => format("%04o", mode) }
              end
            end
            walk[:symlinks].each do |link|
              writer.write_symlink("task/#{link.fetch('path')}", link.fetch("target"))
              inventory << { "path" => link.fetch("path"), "kind" => "symlink", "target" => link.fetch("target") }
            end
            sessions.each do |session|
              next unless session["content"]

              content = session.delete("content")
              relative = "sessions/#{session.fetch('session_id')}.jsonl"
              writer.write_content(relative, content)
              session["packaged"] = relative
              session["sha256"] = Digest::SHA256.hexdigest(content)
              session["bytes"] = content.bytesize
              inventory << { "path" => relative, "kind" => "file", "bytes" => content.bytesize,
                             "sha256" => session["sha256"], "mode" => "0644" }
            end
            timeline_bytes = timeline_text(timeline)
            writer.write_content("timeline.jsonl", timeline_bytes)
            inventory << { "path" => "timeline.jsonl", "kind" => "file", "bytes" => timeline_bytes.bytesize,
                           "sha256" => Digest::SHA256.hexdigest(timeline_bytes), "mode" => "0644" }
            manifest = build_manifest(record: record, state: state, exported_at: exported_at,
                                      inventory: inventory.sort_by { |entry| entry.fetch("path") },
                                      excluded: walk[:excluded].sort_by { |entry| entry.fetch("path") },
                                      sources: sources, missing: missing, sessions: sessions,
                                      observed_digests: { "state.json" => Digest::SHA256.hexdigest(state_bytes),
                                                          "events.jsonl" => sources.dig("events", "sha256"),
                                                          "collaboration.jsonl" => collaboration["subset_text"] ?
                                                            collaboration.fetch("subset_sha256") : collaboration["source_sha256"] })
            writer.write_content("manifest.json", JSON.pretty_generate(deep_sort(manifest)) + "\n")
            writer.finish
          end
        end
        bytes = File.size(temporary)
        File.link(temporary, output)
        File.unlink(temporary)
      rescue StandardError
        File.unlink(temporary) if File.exist?(temporary)
        raise
      end

      { "task_directory" => task_path, "task_id" => state.fetch("id"), "status" => state["status"],
        "in_flight" => !TaskRuntime::TERMINAL.include?(state["status"]),
        "output" => output, "bytes" => bytes, "files" => inventory.length,
        "missing" => manifest.fetch("missing").length }
    end

    def load_state(record)
      path = File.join(record.path, "state.json")
      raise Error, "#{record.path} 不是 Orbit 任务记录（缺少 state.json）" unless File.file?(path)

      bytes = File.read(path)
      [JSON.parse(bytes), bytes]
    end

    # The export must never write into the task directory it reads, including
    # through an existing symlink at the destination or in its parent.
    def validate_output!(output, task_path)
      raise Error, "--output 已存在，拒绝覆盖：#{output}" if File.exist?(output) || File.symlink?(output)
      parent = File.dirname(output)
      raise Error, "--output 的父目录不存在：#{parent}" unless File.directory?(parent)
      inside = ->(path) { path == task_path || path.start_with?(task_path + File::SEPARATOR) }
      raise Error, "--output 不能写入任务目录内部（导出不得改动任务记录）" if inside.call(File.realpath(parent))
    end

    # Collects the archivable task-local content. Locks, the transient inbox
    # queue, atomic-write temp leftovers, SQLite live sidecars and non-regular
    # files are excluded and reported; a symlink is kept only when BOTH its
    # lexical target and its fully resolved realpath stay inside the task
    # directory, so a chained link cannot smuggle content out.
    def walk_task(task_path)
      files = []
      symlinks = []
      excluded = []
      Find.find(task_path) do |absolute|
        relative = absolute == task_path ? nil : absolute[(task_path.length + 1)..]
        next if relative.nil?

        if File.directory?(absolute) && !File.symlink?(absolute)
          if relative == "inbox"
            excluded << { "path" => "inbox", "reason" => "transient command queue, not evidence" }
            Find.prune
          end
          next
        end
        stat = File.lstat(absolute)
        if stat.symlink?
          target = File.readlink(absolute)
          lexical = lexical_target(absolute, target)
          resolved = safe_realpath(absolute)
          contained = ->(path) { path == task_path || path.start_with?(task_path + File::SEPARATOR) }
          if contained.call(lexical) && resolved && contained.call(resolved)
            symlinks << { "path" => relative, "target" => target }
          else
            excluded << { "path" => relative, "reason" => "symlink does not resolve inside the task directory",
                          "target" => target }
          end
        elsif stat.file?
          case
          when LOCK_FILES.include?(relative)
            excluded << { "path" => relative, "reason" => "runtime lock, not evidence" }
          when relative.end_with?(".tmp")
            excluded << { "path" => relative, "reason" => "atomic-write temporary leftover" }
          when SQLITE_LIVE_SUFFIXES.any? { |suffix| relative.end_with?(suffix) }
            excluded << { "path" => relative, "reason" => "SQLite live sidecar (shm/wal) of a check profile" }
          else
            files << relative
          end
        else
          excluded << { "path" => relative, "reason" => "non-regular file (socket/device/fifo)" }
        end
      end
      { files: files.sort, symlinks: symlinks.sort_by { |link| link.fetch("path") }, excluded: excluded }
    end

    def lexical_target(absolute, target)
      Pathname.new(File.dirname(absolute)).join(target).cleanpath.to_s
    end

    def safe_realpath(path)
      File.realpath(path)
    rescue StandardError
      nil
    end

    # Reads events.jsonl and collaboration.jsonl and produces the fact timeline
    # plus per-source observation facts. Collaboration lines are included only
    # when they carry this task's id (task_id/task/task_dir); other, unlabelled
    # or unparseable lines are counted and reported — and the packaged copy of
    # collaboration.jsonl contains only the attributable subset, so a native
    # session spanning several Orbit tasks never leaks foreign content.
    def observe(task_path, task_id)
      entries = []
      missing = []
      sources = {}

      events = read_jsonl(File.join(task_path, "events.jsonl"))
      if events.nil?
        sources["events"] = { "file" => "task/events.jsonl", "present" => false }
        missing << { "item" => "events.jsonl", "reason" => "task event log is absent" }
      else
        invalid = []
        events.fetch("lines").each do |line|
          if line["error"]
            invalid << line.slice("line", "error")
            entries << { "source" => "events.jsonl", "line" => line.fetch("line"),
                         "invalid" => true, "error" => line.fetch("error") }
            next
          end
          event = line["value"]
          entry = { "source" => "events.jsonl", "line" => line.fetch("line"),
                    "at" => event["at"], "type" => event["type"] }
          (event.keys - %w[at type]).sort.each do |key|
            target = entry.key?(key) || %w[gap invalid truncated check_directory check_directory_missing].include?(key) ?
              "event_#{key}" : key
            entry[target] = event[key]
          end
          link_check_directory(entry, event, task_path)
          entries << entry
        end
        entries << truncated_marker("events.jsonl") unless events.fetch("complete")
        sources["events"] = { "file" => "task/events.jsonl", "present" => true,
                              "lines" => events.fetch("lines").length, "complete" => events.fetch("complete"),
                              "sha256" => events.fetch("sha256"),
                              "invalid_line_count" => invalid.length, "invalid_lines" => invalid.first(50) }
        if invalid.any?
          missing << { "item" => "events.jsonl",
                       "reason" => "#{invalid.length} invalid lines (see manifest sources.events.invalid_lines)" }
        end
      end

      collaboration = read_jsonl(File.join(task_path, "collaboration.jsonl"))
      packaging = { "source_present" => false, "source_sha256" => nil, "subset_text" => nil }
      if collaboration.nil?
        sources["collaboration"] = { "file" => "task/collaboration.jsonl", "present" => false }
        missing << { "item" => "collaboration.jsonl",
                     "reason" => "native collaboration evidence was not recorded (session plugin predates persistence, no bound session, or a persistence failure)" }
      else
        attributable = 0
        unattributable = 0
        invalid = []
        previous_seq = nil
        last_at = nil
        raw_kept = []
        collaboration.fetch("lines").each do |line|
          line_number = line.fetch("line")
          if line["error"]
            invalid << line.slice("line", "error")
            entries << { "source" => "collaboration.jsonl", "line" => line_number,
                         "invalid" => true, "error" => line.fetch("error") }
            next
          end

          observed = line["value"]
          unless attributable_to?(observed, task_id, task_path)
            unattributable += 1
            next
          end

          attributable += 1
          raw_kept << line.fetch("raw")
          seq = observed["seq"].is_a?(Integer) ? observed["seq"] : nil
          restarted = observed["kind"] == "persistence_gap" &&
                      observed["reason"].to_s.include?("numbering restarted")
          if previous_seq && seq && seq <= previous_seq && restarted
            entries << gap("collaboration.jsonl", line_number, last_at,
                           "numbering restarted at seq #{seq} after a durable-sequence reset (segment boundary)")
            previous_seq = nil
          elsif previous_seq && seq && seq <= previous_seq
            entries << gap("collaboration.jsonl", line_number, last_at,
                           "seq #{seq} does not advance past #{previous_seq}")
          elsif previous_seq && seq && seq > previous_seq + 1
            entries << gap("collaboration.jsonl", line_number, last_at,
                           "seq #{previous_seq + 1}..#{seq - 1} missing before line #{line_number}")
          end
          previous_seq = seq if seq
          entry = { "source" => "collaboration.jsonl", "line" => line_number, "at" => observed["at"] }
          entry["seq"] = seq if seq
          entry["kind"] = observed["kind"] if !observed["kind"].nil? && observed["kind"] != ""
          (observed.keys - %w[at seq kind task_id task task_dir]).sort.each do |key|
            target = entry.key?(key) || %w[gap invalid truncated check_directory check_directory_missing].include?(key) ?
              "event_#{key}" : key
            entry[target] = observed[key]
          end
          entries << entry
          last_at = observed["at"] if observed["at"].is_a?(String)
        end
        entries << truncated_marker("collaboration.jsonl") unless collaboration.fetch("complete")
        omitted = unattributable + invalid.length + (collaboration.fetch("complete") ? 0 : 1)
        subset_text = raw_kept.empty? ? "" : "#{raw_kept.join("\n")}\n"
        source_text = collaboration.fetch("content")
        verbatim = subset_text == source_text
        unless verbatim
          packaging["subset_text"] = subset_text
          missing << { "item" => "collaboration.jsonl",
                       "reason" => "packaged copy is the task-attributable subset only: #{omitted} line(s) belonging to other tasks, unparseable or mid-append were omitted and are only counted" }
        end
        packaging["source_present"] = true
        packaging["source_sha256"] = collaboration.fetch("sha256")
        packaging["subset_bytes"] = subset_text.bytesize
        packaging["subset_sha256"] = Digest::SHA256.hexdigest(subset_text)
        sources["collaboration"] = {
          "file" => "task/collaboration.jsonl", "present" => true,
          "lines" => collaboration.fetch("lines").length, "complete" => collaboration.fetch("complete"),
          "attributable" => attributable, "unattributable" => unattributable,
          "packaged" => verbatim ? "verbatim" : "task-attributable subset",
          "invalid_line_count" => invalid.length, "invalid_lines" => invalid.first(50),
          "attribution" => "only lines whose task id equals the exported task are included; others are counted, never copied"
        }
        if attributable.zero? && !collaboration.fetch("lines").empty?
          missing << { "item" => "collaboration.jsonl",
                       "reason" => "present but no task-attributable lines (#{unattributable} unattributable, #{invalid.length} invalid)" }
        end
      end

      members_path = File.join(task_path, "members.json")
      members = if File.file?(members_path)
                  begin
                    list = JSON.parse(File.read(members_path))
                    { "status" => "ok", "members" => list.is_a?(Array) ? list.length : nil }
                  rescue JSON::ParserError
                    { "status" => "invalid" }
                  end
                else
                  { "status" => "absent" }
                end
      sources["members"] = { "file" => "task/members.json" }.merge(members)
      if members.fetch("status") == "invalid"
        missing << { "item" => "members.json", "reason" => "not valid JSON; the raw bytes are archived uninterpreted" }
      end

      missing << { "item" => "instruction.txt", "reason" => "original instruction file is missing" } unless File.file?(File.join(task_path, "instruction.txt"))

      [ordered(entries), sources, missing, packaging]
    end

    # Facts sorted by time with a deterministic tiebreak; gap/invalid/truncated
    # markers stay next to the line they describe.
    def ordered(entries)
      entries.each_with_index.sort_by do |entry, index|
        timestamped = entry["at"].is_a?(String) && !entry["at"].empty? ? 0 : 1
        [timestamped, entry["at"].to_s, SOURCE_ORDER.fetch(entry.fetch("source"), 9), entry["line"].to_i,
         entry["gap"] || entry["invalid"] ? 1 : 0, index]
      end.map(&:first)
    end

    def gap(source, line, at, detail)
      { "source" => source, "line" => line, "at" => at, "gap" => true, "detail" => detail }
    end

    def truncated_marker(source)
      { "source" => source, "gap" => true, "truncated" => true,
        "detail" => "last line has no trailing newline at export time; the file may be mid-append and this archive does not claim it is complete" }
    end

    # A session plugin line is safely attributable when it names this task by
    # id or by its task directory path (the omp-host plugin writes `task_dir`;
    # a Root session may span several tasks, so foreign references are never
    # copied into this task's export).
    def attributable_to?(observed, task_id, task_path)
      [observed["task_id"], observed["task"], observed["task_dir"]].compact.each do |reference|
        next unless reference.is_a?(String) && !reference.empty?

        return true if reference == task_id || reference == task_path || reference.end_with?("/#{task_id}")
        return false
      end
      false
    end

    # TaskRuntime check events are linked to the archived check directory so
    # the timeline points at the raw check evidence. Association only.
    def link_check_directory(entry, event, task_path)
      return unless CHECK_LINKED_TYPES.include?(event["type"])

      number = event["number"] || event["check"]
      return unless number.is_a?(Integer) || number.to_s.match?(/\A\d+\z/)

      relative = "checks/#{number}"
      if File.directory?(File.join(task_path, relative))
        entry["check_directory"] = "task/#{relative}"
      else
        entry["check_directory_missing"] = true
      end
    end

    def read_jsonl(path)
      return nil unless File.file?(path)

      content = File.read(path, mode: "rb")
      complete = content.end_with?("\n")
      lines = content.split("\n", -1)
      lines.pop if complete && !lines.empty?
      parsed = lines.each_with_index.map do |line, index|
        record = { "line" => index + 1, "raw" => line }
        if line.strip.empty?
          record["error"] = "blank line"
        else
          begin
            value = JSON.parse(line)
            if value.is_a?(Hash)
              record["value"] = value
            else
              record["error"] = "not a JSON object"
            end
          rescue JSON::ParserError => error
            record["error"] = error.message[0, 160]
          end
        end
        record
      end
      { "lines" => parsed, "complete" => complete, "content" => content,
        "sha256" => Digest::SHA256.hexdigest(content) }
    end

    def timeline_text(entries)
      entries.empty? ? "" : entries.map { |entry| JSON.generate(entry) }.join("\n") + "\n"
    end

    # Native OMP session evidence. Candidate sources, in order: the
    # runtime-persisted `state.root_session_file` / `state.members[].session_file`
    # (plugin-observed paths), then the agent store's per-session transcript
    # files (sessions/<mangled-cwd>/<timestamp>_<session-id>.jsonl) located by
    # the ids this task owns: the Root connection thread id and the member ids
    # registered in THIS task's members.json. The Root session file covers the
    # whole native conversation, which may span several Orbit tasks, so only
    # the segment inside this task's [created_at, finished_at] window (bounded
    # by the export time while running) is copied, line by line, using each
    # line's own timestamp; lines without a usable timestamp are omitted and
    # counted. A member session is copied in full only after the file's own
    # session header verifies the member id — member ids are unique per
    # dispatch and registered exactly once, so a verified file is task-scoped.
    # Anything not found or not verifiable becomes an explicit per-session
    # missing entry — never a silent absence and never a blind copy.
    def native_sessions(state, exported_at, task_path, agent_dir: nil)
      store = agent_dir || ENV["PI_CODING_AGENT_DIR"]
      store = File.join(Dir.home, ".omp", "agent") if store.to_s.empty?
      sessions_root = File.join(store, "sessions")
      window_end = Time.iso8601(state["finished_at"]) if state["finished_at"].is_a?(String) && !state["finished_at"].empty?
      window_end ||= Time.iso8601(exported_at)
      window_begin = begin
        Time.iso8601(state.fetch("created_at"))
      rescue ArgumentError
        nil
      end

      descriptors = []
      root_id = state.dig("connection", "thread_id")
      if root_id.is_a?(String) && !root_id.empty? && state.dig("connection", "provider") == "omp"
        descriptors << { "role" => "root", "session_id" => root_id, "candidate" => state["root_session_file"] }
      end
      member_candidates = {}
      Array(state["members"]).each do |member|
        next unless member.is_a?(Hash) && member["thread_id"].is_a?(String) && !member["thread_id"].empty?

        register_member_candidate(member_candidates, member)
      end
      members_file = File.join(task_path, "members.json")
      if File.file?(members_file)
        begin
          JSON.parse(File.read(members_file)).each do |member|
            next unless member.is_a?(Hash) && member["thread_id"].is_a?(String) && !member["thread_id"].empty?

            register_member_candidate(member_candidates, member)
          end
        rescue JSON::ParserError
          # The raw bytes are still archived; without a parseable member list
          # no member session can be verified, so each stays explicitly absent.
        end
      end
      member_candidates.each_key { |id| descriptors << { "role" => "member", "session_id" => id } }

      descriptors.map do |descriptor|
        session_entry(descriptor, sessions_root, window_begin, window_end, member_candidates)
      end
    end

    # A known member id is always tracked (its session evidence is expected);
    # a plugin-observed session_file path is only a hint, never a requirement.
    def register_member_candidate(candidates, member)
      id = member.fetch("thread_id")
      if member["session_file"].is_a?(String) && !member["session_file"].empty?
        candidates[id] ||= member["session_file"]
      else
        candidates[id] = nil unless candidates.key?(id)
      end
    end

    def session_entry(descriptor, sessions_root, window_begin, window_end, member_candidates)
      session_id = descriptor.fetch("session_id")
      record = { "role" => descriptor.fetch("role"), "session_id" => session_id, "store" => sessions_root }
      unless session_id.match?(/\A[A-Za-z0-9_-]+\z/)
        record["status"] = "invalid_id"
        record["missing_entry"] = { "item" => "session:#{session_id}",
                                    "reason" => "native session id cannot be used as an archive path" }
        return record
      end
      candidate = descriptor["candidate"] || member_candidates[session_id]
      session_file, origin =
        if candidate.is_a?(String) && !candidate.empty? && File.file?(candidate)
          [candidate, "state record"]
        else
          [session_transcript(sessions_root, session_id), "agent store id lookup"]
        end
      if session_file.nil?
        record.merge!("status" => "missing",
                      "reason" => "native session transcript not found; only task-local plugin observations are included")
        record["missing_entry"] = { "item" => "session:#{session_id}",
                                    "reason" => "#{descriptor.fetch('role')} native session transcript not found; task-local plugin observations only" }
        return record
      end

      record["source_path"] = session_file
      record["source_origin"] = origin
      unless session_file_verifies?(session_file, session_id)
        record.merge!("status" => "unverified",
                      "reason" => "the transcript's own session header does not match this session id; not safely attributable, no copy made")
        record["missing_entry"] = { "item" => "session:#{session_id}",
                                    "reason" => "#{descriptor.fetch('role')} native session transcript could not be verified against the session id; no copy included" }
        return record
      end

      content = File.read(session_file, mode: "rb")
      complete = content.end_with?("\n")
      lines = content.split("\n", -1)
      lines.pop if complete && !lines.empty?
      kept = []
      outside = 0
      lines.each do |line|
        if descriptor.fetch("role") == "member"
          kept << line
          next
        end

        timestamp = session_line_time(line)
        if timestamp && window_begin && timestamp >= window_begin && timestamp <= window_end
          kept << line
        else
          outside += 1
        end
      end
      record.merge!("scope" => descriptor.fetch("role") == "root" ? "task time window" : "full session",
                    "lines_total" => lines.length, "lines_included" => kept.length,
                    "lines_outside_task_scope" => outside, "trailing_complete" => complete,
                    "note" => "companion directories and lock files of the session store are not copied")
      if descriptor.fetch("role") == "root"
        record["window"] = { "begin" => window_begin&.utc&.iso8601, "end" => window_end.utc.iso8601,
                             "basis" => "state.json created_at/finished_at; the Root native conversation may span other tasks, so only this window is attributable" }
      end
      if kept.empty?
        record["status"] = "not_attributable"
        record["reason"] = "no transcript line falls inside the task's time window or carries a usable timestamp"
        record["missing_entry"] = { "item" => "session:#{session_id}",
                                    "reason" => "#{descriptor.fetch('role')} native session transcript has no task-attributable content" }
      else
        record["status"] = "included"
        record["content"] = "#{kept.join("\n")}\n"
      end
      record
    end

    def session_transcript(sessions_root, session_id)
      return nil unless Dir.exist?(sessions_root)

      Dir.glob(File.join(sessions_root, "*", "*_#{session_id}.jsonl")).find do |path|
        File.file?(path) && !File.basename(path).start_with?(".")
      end
    rescue SystemCallError
      nil
    end

    # A transcript is only trusted when its own session header (the first
    # `{"type":"session","id":...}` line) names the expected session id; a path
    # alone, however obtained, never justifies a copy.
    def session_file_verifies?(session_file, session_id)
      File.foreach(session_file).first(40).each do |line|
        value = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        return value.is_a?(Hash) && value["type"] == "session" && value["id"] == session_id if value.is_a?(Hash) && value["type"] == "session"
      end
      false
    end

    # Native transcript lines carry either an ISO string or epoch milliseconds
    # in their `timestamp` field; nil means not attributable by time.
    def session_line_time(line)
      value = begin
        JSON.parse(line)["timestamp"] if line.strip.start_with?("{")
      rescue JSON::ParserError
        nil
      end
      case value
      when String then begin Time.iso8601(value) rescue StandardError nil end
      when Integer then Time.at(value / 1000.0)
      when Float then Time.at(value)
      end
    end

    def build_manifest(record:, state:, exported_at:, inventory:, excluded:, sources:, missing:, sessions:,
                       observed_digests:)
      missing = missing.dup
      by_path = inventory.to_h { |entry| [entry.fetch("path"), entry] }
      in_flight = !TaskRuntime::TERMINAL.include?(state["status"])

      # The manifest must describe exactly the packaged bytes: if a live task
      # rewrote a source between observation and packaging, say so instead of
      # letting the embedded state/timeline disagree with the archive.
      observed_digests.each do |path, observed|
        next unless observed

        archived = by_path.dig(path, "sha256")
        if archived && archived != observed
          missing << { "item" => path,
                       "reason" => "file changed during export; the archived bytes differ from the version analyzed for this manifest" }
        end
      end

      Array(state["basis"]).each do |item|
        next unless item.is_a?(Hash) && item["path"].is_a?(String)

        archived = by_path[item["path"]]
        if archived.nil?
          missing << { "item" => item["path"], "reason" => "basis file referenced by state.json is not in the archive" }
        elsif item["sha256"].is_a?(String) && archived["sha256"] != item["sha256"]
          missing << { "item" => item["path"], "reason" => "basis content digest does not match state.json" }
        end
      end
      Array(state["amendments"]).each do |item|
        next unless item.is_a?(Hash) && item["path"].is_a?(String)

        missing << { "item" => item["path"], "reason" => "amendment file referenced by state.json is not in the archive" } if by_path[item["path"]].nil?
      end

      recorded_numbers = []
      Array(state["checks"]).each do |check|
        next unless check.is_a?(Hash)

        number = check["number"]
        next unless number.is_a?(Integer)

        recorded_numbers << number
        relative = "checks/#{number}"
        if by_path.key?("#{relative}/scope.json") || by_path.keys.any? { |path| path.start_with?("#{relative}/") }
          if check["finished_at"] && !by_path.key?("#{relative}/evidence.json") && !by_path.key?("#{relative}/run.json")
            missing << { "item" => "#{relative}", "reason" => "finished check has no result evidence (evidence.json/run.json) in the archive" }
          end
        else
          missing << { "item" => relative, "reason" => "check directory referenced by state.json is not in the archive" }
        end
      end
      inventory.map { |entry| entry.fetch("path") }.grep(%r{\Achecks/([^/]+)/}) { Regexp.last_match(1) }.uniq.each do |number|
        next unless number.match?(/\A\d+\z/)

        unless recorded_numbers.include?(number.to_i)
          missing << { "item" => "checks/#{number}", "reason" => "check directory has no entry in state.json (in flight or unrecorded at export time)" }
        end
      end
      if state["unconfirmed_check_run"].is_a?(String)
        missing << { "item" => state["unconfirmed_check_run"], "reason" => "check run recorded as unconfirmed" }
      end

      manifest = {
        "archive_format" => ARCHIVE_FORMAT,
        "exported_at" => exported_at,
        "exporter" => { "orbit_version" => Orbit::VERSION, "source" => Orbit.version_info.fetch("source") },
        "task" => {
          "id" => state["id"], "directory" => record.path, "project_root" => state["project_root"],
          "status" => state["status"], "created_at" => state["created_at"], "finished_at" => state["finished_at"],
          "in_flight" => in_flight,
          "in_flight_checks" => Array(state["checks"]).select { |check| check.is_a?(Hash) && !check["result"] }
                                                   .filter_map { |check| check["number"] },
          "unconfirmed_check_run" => state["unconfirmed_check_run"],
          "as_of" => exported_at,
          "note" => in_flight ? "task was not terminal at export time; this archive is a point-in-time snapshot and later facts are not included" : nil
        },
        "state" => state,
        "timeline" => { "file" => "timeline.jsonl", "sources" => %w[events.jsonl collaboration.jsonl],
                        "note" => "fact-only join ordered by time; source and line identify the origin record; gap/invalid/truncated entries flag observation limits, and check_* entries link their archived check directory" },
        "files" => inventory,
        "excluded" => excluded,
        "missing" => missing,
        "sources" => sources.merge("sessions" => sessions)
      }
      manifest["missing"] = manifest.fetch("missing").uniq { |item| [item["item"], item["reason"]] }
      manifest
    end

    def deep_sort(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, deep_sort(value[key])] }
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end

    # Minimal deterministic tar (ustar with GNU longname/longlink extensions):
    # regular files streamed from disk (hashing happens on the same pass),
    # in-archive generated content, symlinks, no username leakage, zero mtime
    # for generated members. Real file mtimes and modes are preserved. A file
    # that shrinks or grows while being read aborts the export instead of
    # writing a member whose header disagrees with its bytes.
    class TarWriter
      BLOCK = 512
      CHUNK = 1 << 20

      def initialize(io)
        @io = io
      end

      def write_file(name, path)
        stat = File.lstat(path)
        write_header(name: name, size: stat.size, mode: stat.mode & 0o777,
                     mtime: stat.mtime.to_i, typeflag: "0")
        digest = Digest::SHA256.new
        remaining = stat.size
        File.open(path, "rb") do |file|
          while remaining.positive? && (chunk = file.read([CHUNK, remaining].min))
            digest.update(chunk)
            @io.write(chunk)
            remaining -= chunk.bytesize
          end
          raise Error, "#{path} shrank while being read for export" if remaining.positive?
          raise Error, "#{path} grew while being read for export" if file.read(1)
        end
        pad(stat.size)
        [digest.hexdigest, stat.size, stat.mode & 0o777]
      end

      def write_content(name, content)
        bytes = content.b
        write_header(name: name, size: bytes.bytesize, mode: 0o644, mtime: 0, typeflag: "0")
        @io.write(bytes)
        pad(bytes.bytesize)
      end

      def write_symlink(name, target)
        link = target.b
        write_header(name: name, size: 0, mode: 0o777, mtime: 0, typeflag: "2", linkname: link)
      end

      def finish
        @io.write("\0".b * (BLOCK * 2))
      end

      private

      def pad(size)
        remainder = (BLOCK - (size % BLOCK)) % BLOCK
        @io.write("\0".b * remainder) if remainder.positive?
      end

      def write_header(name:, size:, mode:, mtime:, typeflag:, linkname: "")
        name = name.b
        linkname = linkname.b
        if name.bytesize > 100
          split = split_name(name)
          if split
            prefix, suffix = split
            name = suffix
          else
            write_gnu_long("L", name)
            name = name.byteslice(0, 100) || name
          end
        else
          prefix = nil
        end
        if linkname.bytesize > 100
          write_gnu_long("K", linkname)
          linkname = linkname.byteslice(0, 100) || ""
        end
        @io.write(build_header(name: name, prefix: prefix, size: size, mode: mode,
                               mtime: mtime, typeflag: typeflag, linkname: linkname))
      end

      def split_name(name)
        limit = [name.bytesize - 1, 155].min
        limit.downto(1) do |index|
          next unless name.getbyte(index) == 0x2f

          prefix = name.byteslice(0, index)
          suffix = name.byteslice(index + 1, name.bytesize - index - 1)
          return [prefix, suffix] if !suffix.empty? && suffix.bytesize <= 100
        end
        nil
      end

      def write_gnu_long(typeflag, payload)
        bytes = payload + "\0"
        @io.write(build_header(name: "././@LongLink", prefix: nil, size: bytes.bytesize,
                               mode: 0, mtime: 0, typeflag: typeflag))
        @io.write(bytes)
        pad(bytes.bytesize)
      end

      def build_header(name:, prefix:, size:, mode:, mtime:, typeflag:, linkname: "")
        header = +"".b
        header << field(name, 100)
        header << field(format("%07o", mode), 8)
        header << field("0000000", 8)
        header << field("0000000", 8)
        header << field(format("%011o", size), 12)
        header << field(format("%011o", mtime), 12)
        header << " " * 8
        header << typeflag.b
        header << field(linkname, 100)
        header << "ustar\0"
        header << "00"
        header << field("", 32)
        header << field("", 32)
        header << field("", 8)
        header << field("", 8)
        header << field(prefix.to_s, 155)
        header << "\0".b * 12
        header[148, 8] = format("%06o\0 ", header.bytes.sum).b
        header
      end

      def field(value, width)
        value.b.ljust(width, "\0")
      end
    end
  end
end
