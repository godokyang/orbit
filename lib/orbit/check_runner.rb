# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Orbit
  # R5b: one independent read-only check via the local Codex CLI.
  #
  # A CheckRunner owns at most one check process. `start` writes the review
  # prompt and schema, then spawns `codex exec` in its own process group
  # without blocking. `poll` returns nil while the process runs, or the
  # schema-validated result object when it exits successfully. `stop!`
  # terminates only this runner's process group and confirms exit, keeping
  # diagnostics. `close` releases the run, stopping it first if needed.
  #
  # The program never relaxes the sandbox, never falls back to another model,
  # never guesses prices, and never turns a failed or malformed model response
  # into a pass.
  class CheckRunner
    ROLES = %w[reviewer adjudicator].freeze
    VERDICTS = %w[continue correct pause complete needs_user].freeze
    FINDING_KEYS = %w[id requirement evidence action].freeze
    RESULT_KEYS = %w[verdict reason findings resolved_ids next_check_seconds].freeze
    DEFAULT_STOP_GRACE_SECONDS = 5

    class Error < StandardError; end

    Run = Struct.new(:pid, :pgid, :directory, :output_dir, :role, :model, :schema_path,
                     :prompt_path, :events_path, :stderr_path, :last_message_path,
                     :started_at, keyword_init: true)

    def initialize(model:, executable: "codex", schema: nil, stop_grace_seconds: DEFAULT_STOP_GRACE_SECONDS)
      raise Error, "model is required (no automatic model fallback)" if model.to_s.strip.empty?
      raise Error, "executable is required" if executable.to_s.strip.empty?
      raise Error, "stop_grace_seconds must be a positive number" unless stop_grace_seconds.to_f.positive?

      @model = model.to_s
      @executable = executable.to_s
      @schema = schema ? File.expand_path(schema.to_s) : default_schema_path
      @stop_grace_seconds = stop_grace_seconds.to_f
      @run = nil
      @result = nil
      @failure = nil
      @reaped = false
      @stopped = false
      @closed = false
    end

    attr_reader :model, :executable

    def start(directory:, inputs:, context:, output_dir:, role: "reviewer")
      raise Error, "runner is closed" if @closed
      if @run
        raise Error, "this runner already has an active check" unless @result || @stopped

        stop! if group_alive?
        @run = @result = @failure = nil
        @reaped = @stopped = false
      end

      role = role.to_s
      raise Error, "role must be one of: #{ROLES.join(', ')}" unless ROLES.include?(role)
      raise Error, "check schema not found: #{@schema}" unless File.file?(@schema)
      raise Error, "codex executable is not available: #{@executable}" unless executable_available?

      snapshot = validate_snapshot!(directory)
      out = validate_output_dir!(output_dir, snapshot)
      prompt = build_prompt(snapshot: snapshot, inputs: inputs, context: context, role: role)

      prompt_path = File.join(out, "prompt.txt")
      schema_copy = File.join(out, "check-result.schema.json")
      last_message_path = File.join(out, "last-message.json")
      events_path = File.join(out, "events.jsonl")
      stderr_path = File.join(out, "stderr.log")

      write_file(prompt_path, prompt)
      FileUtils.cp(@schema, schema_copy)
      File.unlink(last_message_path) if File.exist?(last_message_path)

      argv = command_argv(snapshot: snapshot, schema_path: schema_copy, last_message_path: last_message_path)
      pid = spawn_check(argv, snapshot, prompt_path, events_path, stderr_path)

      run = Run.new(
        pid: pid, pgid: pid, directory: snapshot, output_dir: out, role: role, model: @model,
        schema_path: schema_copy, prompt_path: prompt_path, events_path: events_path,
        stderr_path: stderr_path, last_message_path: last_message_path, started_at: Time.now.utc.iso8601
      )
      @run = run
      begin
        write_run_record(run)
      rescue StandardError
        stop!
        raise
      end
      run
    end

    def poll
      raise Error, "runner is closed" if @closed
      raise Error, "no check run" unless @run
      return @result if @result
      raise @failure if @failure
      raise Error, "check run was stopped; no result is available" if @stopped

      status = wait_nonblock
      if status.nil?
        raise Error, "check process was reaped outside this runner" if @reaped

        return nil
      end

      unless status.success?
        @failure = Error.new(failure_message(status))
        raise @failure
      end
      stop! if group_alive?
      @result = load_result
    end

    def stop!(grace: @stop_grace_seconds)
      raise Error, "runner is closed" if @closed
      raise Error, "no check run" unless @run
      return if @reaped && !group_alive?

      @stopped = true
      signal_group("TERM")
      return if wait_for_exit(grace)

      signal_group("KILL")
      return if wait_for_exit(grace)

      raise Error, "could not confirm exit of check process group #{@run.pgid}"
    end

    def close
      return if @closed

      stop! if active?
      @closed = true
    end

    def usage
      return nil unless @run && File.file?(@run.events_path)

      observed = nil
      File.foreach(@run.events_path) do |line|
        event = JSON.parse(line)
        observed = event["usage"] if event["type"] == "turn.completed"
      rescue JSON::ParserError
        next
      end
      observed
    end

    private

    def active?
      @run && (!@reaped || group_alive?)
    end

    def default_schema_path
      File.expand_path("../../contracts/check-result.schema.json", __dir__)
    end

    def validate_snapshot!(directory)
      path = File.realpath(directory.to_s)
      raise Error, "snapshot directory is not a directory: #{directory}" unless File.directory?(path)

      path
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error, "snapshot directory does not exist: #{directory}"
    end

    def validate_output_dir!(output_dir, snapshot)
      path = File.expand_path(output_dir.to_s)
      FileUtils.mkdir_p(path)
      path = File.realpath(path)
      raise Error, "output_dir must not be inside the fixed snapshot: #{path}" if within?(snapshot, path)
      raise Error, "output_dir is not a directory: #{path}" unless File.directory?(path)

      path
    rescue Errno::EEXIST, Errno::ENOTDIR
      raise Error, "output_dir is not usable: #{output_dir}"
    end

    def command_argv(snapshot:, schema_path:, last_message_path:)
      [
        @executable, "exec",
        "--cd", snapshot,
        "--sandbox", "read-only",
        "--ephemeral",
        "--json",
        "--output-schema", schema_path,
        "--output-last-message", last_message_path,
        "--model", @model,
        "--skip-git-repo-check",
        "-c", "approval_policy=never"
      ]
    end

    def spawn_check(argv, snapshot, prompt_path, events_path, stderr_path)
      events = nil
      errors = nil
      begin
        events = File.open(events_path, "wb")
        errors = File.open(stderr_path, "wb")
        Process.spawn(*argv, in: prompt_path, out: events, err: errors,
                      pgroup: true, chdir: snapshot, close_others: true)
      rescue SystemCallError => e
        raise Error, "cannot start check: #{e.class}: #{e.message}"
      ensure
        events&.close
        errors&.close
      end
    end

    def build_prompt(snapshot:, inputs:, context:, role:)
      instruction = fetch_instruction(inputs)
      amendments = input_items(inputs, "amendments")
      basis = input_items(inputs, "basis")
      context_text = render_context(context)

      parts = [role_prompt(role)]
      library = File.expand_path("../../skills/orbit/assets/rule-library", __dir__)
      parts << "## Applicable Orbit role rules\n\n" + %w[shared/escalation-payload.md tasks/review.md].map do |relative|
        File.read(File.join(library, relative))
      end.join("\n\n")
      parts << "## Original instruction (verbatim)\n\n#{instruction}"
      unless amendments.empty?
        parts << "## Amendments (latest valid input, apply in order)\n\n#{render_items(amendments, 'Amendment')}"
      end
      unless basis.empty?
        parts << "## Named basis (verbatim)\n\n#{render_items(basis, 'Basis')}"
      end
      parts << "## Current execution context (program record)\n\n```json\n#{context_text}\n```"
      parts << "## Fixed artifact snapshot\n\n" \
               "Your working root is the fixed snapshot directory selected by --cd: a read-only copy of the " \
               "delivered workspace plus project rules. The original workspace is not your input. Do not write " \
               "anywhere. If a command would modify a repository, do not run it; report the concrete gap that " \
               "needs isolated verification instead."
      parts << "## Output\n\n" \
               "Return exactly one JSON object matching the attached output schema: verdict, reason, findings, " \
               "resolved_ids, next_check_seconds. verdict is one of: #{VERDICTS.join(', ')}. findings is a list " \
               "of objects with id, requirement, evidence, action. resolved_ids is a list of strings. " \
               "next_check_seconds is a positive integer. No markdown, no code fences, no extra text."
      parts.join("\n\n")
    end

    def fetch_instruction(inputs)
      raise Error, "inputs must be a Hash with instruction/amendments/basis" unless inputs.is_a?(Hash)

      instruction = inputs["instruction"]
      unless instruction.is_a?(String) && !instruction.empty?
        raise Error, "inputs.instruction must be a non-empty string"
      end

      instruction
    end

    def input_items(inputs, key)
      items = inputs[key] || []
      raise Error, "inputs.#{key} must be an array" unless items.is_a?(Array)

      items.map do |item|
        case item
        when String
          { "text" => item, "label" => nil }
        when Hash
          text = item["text"]
          raise Error, "inputs.#{key} entries must carry a text string" unless text.is_a?(String)

          label = [item["source"], item["path"]].compact.join(" - ")
          { "text" => text, "label" => label.empty? ? nil : label }
        else
          raise Error, "inputs.#{key} entries must be strings or objects with text"
        end
      end
    end

    def render_items(items, title)
      items.each_with_index.map do |item, index|
        heading = item["label"] ? "#{title} #{index + 1} (#{item['label']})" : "#{title} #{index + 1}"
        "### #{heading}\n\n#{item['text']}"
      end.join("\n\n")
    end

    def render_context(context)
      case context
      when Hash, Array
        JSON.pretty_generate(context)
      when String
        context
      else
        raise Error, "context must be a Hash, Array or String"
      end
    rescue JSON::JSONError, TypeError => e
      raise Error, "context must be JSON-serializable: #{e.message}"
    end

    def role_prompt(role)
      if role == "adjudicator"
        "You are an independent Orbit adjudicator session. The program, not you, owns messages, timing and " \
          "stop control. Decide only the real disputes listed in the context: weigh both sides' concrete " \
          "evidence and issue an executable conclusion within the original goal and authorization. Do not " \
          "vote, do not require the parties to agree, and do not change requirements, acceptance or scope. " \
          "You may overturn the Root or the reviewer on a disputed point when the evidence supports it; list " \
          "the reviewed ids in resolved_ids and explain the decision in reason. Read the relevant AGENTS.md " \
          "files inside the fixed snapshot; project rules apply to your judgment too."
      else
        "You are an independent Orbit check session, separate from the Root session that produced the " \
          "artifact. Work strictly read-only: never modify the snapshot or the shared project. Judge the " \
          "fixed artifact against the original instruction, amendments and named basis: find work that is " \
          "missing, wrong or extra; judge whether continuing the current work is worthwhile from the " \
          "instruction and concrete evidence. Do not require or run the full test suite, and do not treat " \
          "test counts or elapsed time as failure; name specific gaps that need isolated verification " \
          "instead. Do not change requirements, do not invent acceptance criteria, and do not turn an " \
          "engineering preference into a blocker. Read the relevant AGENTS.md files inside the fixed " \
          "snapshot; project rules apply to your judgment too. Only reuse a history finding id when it is " \
          "the same real problem. If a finding or a previously withdrawn conclusion no longer applies, " \
          "list its id in resolved_ids and explain in reason; a finding withdrawn by an independent " \
          "adjudication is not an unresolved problem. Verdict rules: complete only when the instruction " \
          "is actually satisfied and known problems are resolved. While Root is still executing, never " \
          "declare complete; use correct when an actionable current finding needs attention, otherwise " \
          "continue. Choose pause only for an authorization boundary or a concrete adjudicated correction " \
          "that stays unimplemented, never for estimate overruns, test counts or preference; choose " \
          "needs_user only when the next step needs a decision only the user can make."
      end
    end

    def executable_available?
      return File.executable?(@executable) if @executable.include?("/")

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        !dir.empty? && File.executable?(File.join(dir, @executable))
      end
    end

    def write_run_record(run)
      record = {
        "format" => "orbit-check-run-1",
        "model" => run.model,
        "role" => run.role,
        "pid" => run.pid,
        "pgid" => run.pgid,
        "started_at" => run.started_at,
        "snapshot" => run.directory,
        "output_dir" => run.output_dir,
        "schema" => run.schema_path,
        "executable" => @executable
      }
      write_file(File.join(run.output_dir, "run.json"), JSON.pretty_generate(record) + "\n")
    end

    def write_file(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(bytes)
        file.flush
      end
    end

    def wait_nonblock
      return nil if @reaped

      result = Process.waitpid2(@run.pid, Process::WNOHANG)
      return nil unless result

      @reaped = true
      result.last
    rescue Errno::ECHILD
      @reaped = true
      nil
    end

    def wait_for_exit(grace)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
      loop do
        wait_nonblock unless @reaped
        return true if @reaped && !group_alive?
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
    end

    def group_alive?
      return false unless @run

      Process.kill(0, -@run.pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def signal_group(signal)
      Process.kill(signal, -@run.pgid)
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM
      raise Error, "not permitted to signal check process group #{@run.pgid}"
    end

    def load_result
      path = @run.last_message_path
      raise Error, "check produced no final message: #{path}" unless File.file?(path)

      text = File.read(path).strip
      raise Error, "check final message is empty: #{path}" if text.empty?

      begin
        parsed = JSON.parse(text)
      rescue JSON::ParserError
        raise Error, "check final message is not valid JSON: #{path}"
      end
      validate_result(parsed)
    end

    def validate_result(value)
      problems = []
      unless value.is_a?(Hash)
        raise Error, "check result must be a JSON object, got #{value.class}"
      end

      extra = value.keys - RESULT_KEYS
      missing = RESULT_KEYS - value.keys
      problems << "unexpected keys: #{extra.join(', ')}" unless extra.empty?
      problems << "missing keys: #{missing.join(', ')}" unless missing.empty?
      problems << "verdict must be one of: #{VERDICTS.join(', ')}" unless VERDICTS.include?(value["verdict"])
      unless value["reason"].is_a?(String) && !value["reason"].empty?
        problems << "reason must be a non-empty string"
      end
      problems.concat(validate_findings(value["findings"]))
      unless value["resolved_ids"].is_a?(Array) && value["resolved_ids"].all? { |id| id.is_a?(String) && !id.empty? }
        problems << "resolved_ids must be an array of non-empty strings"
      end
      unless value["next_check_seconds"].is_a?(Integer) && value["next_check_seconds"].positive?
        problems << "next_check_seconds must be a positive integer"
      end
      return value if problems.empty?

      raise Error, "check result does not match contracts/check-result.schema.json: #{problems.join('; ')}"
    end

    def validate_findings(findings)
      unless findings.is_a?(Array)
        return ["findings must be an array"]
      end

      findings.each_with_index.flat_map do |finding, index|
        unless finding.is_a?(Hash) && finding.keys.sort == FINDING_KEYS.sort
          next ["findings[#{index}] must be an object with exactly: #{FINDING_KEYS.join(', ')}"]
        end

        FINDING_KEYS.filter_map do |key|
          value = finding[key]
          unless value.is_a?(String) && !value.empty?
            "findings[#{index}].#{key} must be a non-empty string"
          end
        end
      end
    end

    def failure_message(status)
      code = status.exitstatus || "signal #{status.termsig}"
      parts = ["check run failed (exit #{code})"]
      details = tail(@run.stderr_path, 4096)
      parts << "stderr:\n#{details}" unless details.strip.empty?
      parts << "events: #{@run.events_path}"
      parts << "output_dir: #{@run.output_dir}"
      parts.join("\n")
    end

    def tail(path, limit)
      return "" unless File.file?(path)

      File.open(path, "rb") do |file|
        file.seek([File.size(path) - limit, 0].max)
        file.read.to_s
      end
    end

    def within?(root, path)
      path == root || path.start_with?("#{root}/")
    end
  end
end
