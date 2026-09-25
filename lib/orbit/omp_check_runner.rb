# frozen_string_literal: true

require "json"
require_relative "check_runner"

module Orbit
  # Drop-in check process for an independent OMP reviewer/adjudicator session.
  #
  # TaskRuntime calls start/poll/stop!/close/usage. Prompt text and result
  # validation stay in CheckRunner. This class never builds a `codex exec`
  # command; it spawns runners/omp-reviewer/reviewer.ts in its own process group.
  class OmpCheckRunner < CheckRunner
    REVIEWER = File.expand_path("../../runners/omp-reviewer/reviewer.ts", __dir__)

    def self.default_command
      ["bun", REVIEWER]
    end

    def initialize(model:, command: nil, schema: nil, stop_grace_seconds: DEFAULT_STOP_GRACE_SECONDS)
      launcher = command || self.class.default_command
      raise Error, "omp reviewer command is required" if launcher.empty? || launcher.first.to_s.empty?

      super(model: model, executable: launcher.first.to_s, schema: schema, stop_grace_seconds: stop_grace_seconds)
      @command = launcher.map(&:to_s)
      @evidence = nil
      @usage = nil
      @actual_model = nil
    end

    attr_reader :actual_model, :evidence

    # Judgment rules that role_prompt does not already state, plus the actual session tools.
    def build_prompt(snapshot:, inputs:, context:, role:)
      instruction = fetch_instruction(inputs)
      amendments = input_items(inputs, "amendments")
      basis = input_items(inputs, "basis")
      program_context = compress_context(context)
      context_text = render_context(program_context)
      parts = [role_prompt(role, focus: review_focus_present?(program_context)), retained_check_rules]
      parts << "## Original instruction (verbatim)\n\n#{instruction}"
      unless amendments.empty?
        parts << "## Amendments (latest valid input, apply in order)\n\n#{render_items(amendments, 'Amendment')}"
      end
      unless basis.empty?
        parts << "## Named basis (verbatim)\n\n#{render_items(basis, 'Basis')}"
      end
      recheck = program_context.is_a?(Hash) ? program_context["recheck"] : nil
      if recheck.is_a?(Hash) && recheck["findings"].is_a?(Array) && !recheck["findings"].empty?
        parts << "## Pending clues from a check that went stale\n\n" \
                 "The program record below carries these findings under recheck (check #{recheck['check']}); they " \
                 "were reported against an older version and were not applied. Verify each clue against the " \
                 "current fixed snapshot: if it still holds, include it in findings and reuse its id; if it no " \
                 "longer holds, list its id in resolved_ids and explain. Every listed id must appear in either " \
                 "findings or resolved_ids; do not silently ignore a clue."
      end
      parts << "## Current execution context (program record)\n\n" \
               "This record is deterministic and bounded. The original instruction, amendments and named basis " \
               "above are complete and are not compressed.\n\n```json\n#{context_text}\n```"
      parts << "## Fixed artifact snapshot\n\n" \
               "You are a separate OMP process, not a member of the execution team. " \
               "Use the SDK read/grep/glob tools on the fixed snapshot. " \
               "The original workspace is not your working directory and is not writable from this session. " \
               "Judge the snapshot files, not a model plan or summary."
      parts << "## Output\n\n" \
               "Return JSON matching these fields and nothing else: verdict, reason, findings, " \
               "resolved_ids, next_check_seconds. verdict is one of: #{VERDICTS.join(', ')}. " \
               "findings is a list of objects with id, requirement, evidence, action. " \
               "resolved_ids is a list of strings. next_check_seconds is a positive integer. " \
               "No markdown and no code fences."
      parts.join("\n\n")
    end

    def start(directory:, inputs:, context:, output_dir:, role: "reviewer")
      raise Error, "runner is closed" if @closed
      if @run
        raise Error, "this runner already has an active check" unless @result || @stopped

        stop! if group_alive?
        reset_run!
      end

      role = role.to_s
      raise Error, "role must be one of: #{ROLES.join(', ')}" unless ROLES.include?(role)
      raise Error, "check schema not found: #{@schema}" unless File.file?(@schema)
      raise Error, "omp reviewer command is not available: #{@command.first}" unless command_available?

      snapshot = validate_snapshot!(directory)
      out = validate_output_dir!(output_dir, snapshot)
      prompt = build_prompt(snapshot: snapshot, inputs: inputs, context: context, role: role)
      prompt_path = File.join(out, "prompt.txt")
      schema_copy = File.join(out, "check-result.schema.json")
      evidence_path = File.join(out, "evidence.json")
      stderr_path = File.join(out, "stderr.log")
      config_path = File.join(out, "request.json")
      profile = File.join(out, "profile")
      FileUtils.mkdir_p(profile)
      write_file(prompt_path, prompt)
      FileUtils.cp(@schema, schema_copy)
      File.unlink(evidence_path) if File.exist?(evidence_path)
      write_file(config_path, JSON.generate(
        "snapshot" => snapshot,
        "profile" => profile,
        "out" => evidence_path,
        "prompt" => prompt_path,
        "model" => @model
      ))

      pid = spawn_reviewer(config_path, profile, out, stderr_path)
      run = Run.new(
        pid: pid, pgid: pid, directory: snapshot, output_dir: out, role: role, model: @model,
        schema_path: schema_copy, prompt_path: prompt_path, events_path: evidence_path,
        stderr_path: stderr_path, last_message_path: evidence_path, started_at: Time.now.utc.iso8601
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
      stop! if group_alive?
      parsed = read_evidence
      @evidence = parsed if parsed.is_a?(Hash)
      unless status.success? && @evidence.is_a?(Hash) && @evidence["ok"] == true
        @failure = Error.new(failure_text(status, @evidence))
        raise @failure
      end
      unless fingerprint_held?(@evidence)
        @failure = Error.new("snapshot fingerprint missing or changed")
        raise @failure
      end
      begin
        @result = validate_result(@evidence["result"])
      rescue Error => error
        @failure = error
        raise
      end
      @actual_model = @evidence["model"] if @evidence["model"].is_a?(String) && !@evidence["model"].empty?
      @usage = normalize_usage(@evidence["usage"])
      @result
    end

    def usage
      @usage
    end

    private

    def retained_check_rules
      "## Check rules\n\n" \
        "Judge on two axes. For each original requirement, say whether the fixed snapshot did it, did it only " \
        "partly, did not do it, or did extra work. Extra work is a finding too. A change that fails no real " \
        "requirement is not a missing-instruction finding. Evidence must be verifiable: location plus what you " \
        "saw. Do not invent a trigger or a consequence. An opinion without that evidence is not a finding. " \
        "An issue already decided by an adjudication does not reopen unless the artifact, the input, or concrete " \
        "evidence changed. Pause or stop only for a real authorization gap, or a real dispute that blocks the " \
        "disputed part. A model plan or summary is not the artifact."
    end

    def reset_run!
      @run = @result = @failure = @evidence = @usage = @actual_model = nil
      @reaped = @stopped = false
    end

    def command_available?
      binary = @command.first
      return File.executable?(binary) if binary.include?("/")

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        !dir.empty? && File.executable?(File.join(dir, binary))
      end
    end

    def spawn_reviewer(config_path, profile, out, stderr_path)
      env = ENV.to_h
      env["OMP_PROFILE"] = nil
      env["PI_CODING_AGENT_DIR"] = profile
      errors = nil
      begin
        errors = File.open(stderr_path, "wb")
        Process.spawn(env, *@command, "--config", config_path,
                      in: File::NULL, out: errors, err: [:child, :out],
                      pgroup: true, chdir: out, close_others: true)
      rescue SystemCallError => error
        raise Error, "cannot start omp reviewer: #{error.class}: #{error.message}"
      ensure
        errors&.close
      end
    end

    def read_evidence
      path = @run.last_message_path
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def fingerprint_held?(evidence)
      before = evidence["fingerprint_before"]
      before.is_a?(String) && !before.empty? && before == evidence["fingerprint_after"]
    end

    def normalize_usage(raw)
      self.class.normalize_usage(raw)
    end

    # TaskRuntime sums input_tokens + output_tokens and does not read cacheRead.
    # input_tokens therefore includes measured cacheRead so that sum is the
    # sample total. The raw split stays beside it. Missing cache is unknown,
    # not free. Cost is not copied or guessed.
    def self.normalize_usage(raw)
      items = case raw
              when Array then raw
              when Hash then [raw]
              else return nil
              end
      return nil if items.empty? || items.any? { |item| !item.is_a?(Hash) }

      inputs = items.map { |item| item["input"] }
      caches = items.map { |item| item["cacheRead"] }
      outputs = items.map { |item| item["output"] }
      return nil unless [inputs, caches, outputs].all? { |values| values.all? { |value| value.is_a?(Integer) && value >= 0 } }

      input = inputs.sum
      cache_read = caches.sum
      output = outputs.sum
      {
        "input" => input,
        "cacheRead" => cache_read,
        "output" => output,
        "input_tokens" => input + cache_read,
        "output_tokens" => output,
        "total_tokens" => input + cache_read + output
      }
    end

    def failure_text(status, evidence)
      parts = [failure_message(status)]
      problems = evidence.is_a?(Hash) ? evidence["problems"] : nil
      parts << "evidence problems: #{problems.join('; ')}" if problems.is_a?(Array) && !problems.empty?
      parts.join("\n")
    end
  end
end
