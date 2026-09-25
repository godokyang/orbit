# frozen_string_literal: true

require "json"
require "tmpdir"
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

    # A model identifier is a provider plus a non-empty id. The id may itself
    # contain slashes (e.g. zenmux/x-ai/grok-4.7), matching the reviewer's own
    # `[provider, ...rest] = spec.split("/")` / `rest.join("/")` split.
    # Whitespace is never allowed in either part.
    MODEL_ID = %r{\A[^\s/]+/[^\s]+\z}

    # A failing check is classified so the caller can keep the task alive and
    # blocked for Root's explicit reselection. A structured evidence["error"]
    # with a known kind wins; otherwise a bounded heuristic over the evidence
    # problems and the failure text labels it and is marked "heuristic" so it is
    # auditable, never proof. Unknown failures are "unavailable" and still block.
    FAILURE_KINDS = %w[auth_or_quota unavailable invalid_result].freeze
    AUTH_OR_QUOTA_PATTERN = /(?:\b40[13]\b|\b429\b|unauthor|forbidden|quota|rate[ _-]?limit|insufficient|out of credit|balance|payment|billing|no[ _-]?access)/i
    # A local probe only reads a catalog and the OMP token store; it can run a
    # credential command per distinct provider. Bound it so a stuck `omp token`
    # cannot hold the selection loop.
    PROBE_TIMEOUT_SECONDS = 60

    # Local-only availability probe for the independent checker's isolated
    # profile. For each candidate "provider/id" it asks the isolated catalog
    # (ModelRegistry.find) and OMP's own provider credential resolver, without
    # starting a session or sending a model request. It returns identifiers and
    # structured reasons only; a resolved token is never returned or written.
    #
    # models: array of "provider/id" identifiers.
    # Returns { "resolvable" => ["provider/id", ...],
    #           "unresolvable" => [{ "model" => "provider/id", "reason" => "..." }, ...] }.
    # Any reviewer or configuration failure raises Error; it is never reported
    # as an empty-but-successful probe.
    def self.probe_models(models:, command: nil, timeout: PROBE_TIMEOUT_SECONDS)
      launcher = (command || default_command).map(&:to_s)
      raise Error, "omp reviewer command is required" if launcher.empty? || launcher.first.empty?

      specs = Array(models).map { |model| model.to_s.strip }.reject(&:empty?).uniq
      raise Error, "at least one model is required" if specs.empty?

      Dir.mktmpdir("orbit-model-probe-") do |root|
        profile = File.join(root, "profile")
        FileUtils.mkdir_p(profile)
        File.chmod(0o700, profile)
        out = File.join(root, "evidence.json")
        stderr_path = File.join(root, "stderr.log")
        config_path = File.join(root, "request.json")
        File.write(config_path, JSON.generate(
                                "profile" => profile, "out" => out, "probe_models" => specs.join(",")
                              ))

        status = run_probe(launcher, config_path, profile, root, stderr_path, timeout)
        evidence = parse_probe_evidence(out)
        unless status.success? && evidence.is_a?(Hash) && evidence["ok"] == true
          raise Error, "model probe failed: #{probe_failure_text(status, evidence, stderr_path)}"
        end

        normalize_probe(evidence["probe_models"])
      end
    end

    def self.run_probe(launcher, config_path, profile, cwd, stderr_path, timeout)
      env = ENV.to_h
      env["OMP_PROFILE"] = nil
      env["PI_CODING_AGENT_DIR"] = profile
      errors = File.open(stderr_path, "wb")
      pid = Process.spawn(env, *launcher, "--config", config_path,
                          in: File::NULL, out: errors, err: [:child, :out],
                          pgroup: true, chdir: cwd, close_others: true)
      wait_probe(pid, timeout)
    rescue SystemCallError => error
      raise Error, "cannot start model probe: #{error.class}: #{error.message}"
    ensure
      errors&.close
    end
    private_class_method :run_probe

    def self.wait_probe(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      loop do
        result = Process.waitpid2(pid, Process::WNOHANG)
        return result.last if result
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          kill_probe(pid)
          raise Error, "model probe timed out after #{timeout} seconds"
        end

        sleep 0.05
      end
    rescue Errno::ECHILD
      raise Error, "model probe process was reaped outside this probe"
    end
    private_class_method :wait_probe

    def self.kill_probe(pid, grace: 2)
      signal_probe(pid, "TERM")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
      loop do
        return if Process.waitpid2(pid, Process::WNOHANG)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
      signal_probe(pid, "KILL")
      Process.waitpid2(pid)
    rescue Errno::ECHILD
      nil
    end
    private_class_method :kill_probe

    def self.signal_probe(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end
    private_class_method :signal_probe

    def self.parse_probe_evidence(path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end
    private_class_method :parse_probe_evidence

    def self.probe_failure_text(status, evidence, stderr_path)
      parts = [status ? "exit #{status.exitstatus || "signal #{status.termsig}"}" : "no process status"]
      problems = evidence.is_a?(Hash) ? evidence["problems"] : nil
      parts << "evidence problems: #{problems.join('; ')}" if problems.is_a?(Array) && !problems.empty?
      details = File.file?(stderr_path) ? File.read(stderr_path).to_s.strip : ""
      parts << "stderr: #{details[0, 4096]}" unless details.empty?
      parts.join("\n")
    end
    private_class_method :probe_failure_text

    def self.normalize_probe(raw)
      raise Error, "model probe returned no result" unless raw.is_a?(Hash)

      resolvable = Array(raw["resolvable"]).filter_map do |item|
        model = item.is_a?(Hash) ? item["model"] : item
        text = model.to_s.strip
        text if text.match?(MODEL_ID)
      end
      unresolvable = Array(raw["unresolvable"]).filter_map do |item|
        next unless item.is_a?(Hash)

        model = item["model"].to_s.strip
        next if model.empty?

        { "model" => model, "reason" => item["reason"].to_s.strip }
      end
      { "resolvable" => resolvable.uniq, "unresolvable" => unresolvable }
    end
    private_class_method :normalize_probe

    def initialize(model:, command: nil, schema: nil, stop_grace_seconds: DEFAULT_STOP_GRACE_SECONDS)
      launcher = command || self.class.default_command
      raise Error, "omp reviewer command is required" if launcher.empty? || launcher.first.to_s.empty?

      super(model: model, executable: launcher.first.to_s, schema: schema, stop_grace_seconds: stop_grace_seconds)
      @command = launcher.map(&:to_s)
      @evidence = nil
      @usage = nil
      @actual_model = nil
      @failure_kind = nil
      @failure_basis = nil
    end

    attr_reader :actual_model, :evidence, :failure, :failure_kind, :failure_basis

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

    # Switches the model used by the next check. Only allowed when no check is
    # in flight: before the first start, after poll returned a result, or after
    # stop! confirmed exit. A started check that has neither a result nor a stop
    # is in flight and rejects the switch, so a running reviewer never changes
    # model mid-check. The runner still never picks a model on its own; the
    # caller passes a user-confirmed provider/id, whose id may contain slashes.
    def select_model!(value)
      raise Error, "runner is closed" if @closed

      model = value.to_s.strip
      raise Error, "checker model must be provider/id (the id may contain slashes)" unless model.match?(MODEL_ID)
      raise Error, "cannot change the check model while a check is in flight" if in_flight?

      @model = model
    end

    def start(directory:, inputs:, context:, output_dir:, role: "reviewer")
      raise Error, "runner is closed" if @closed
      if @run
        raise Error, "this runner already has an active check" unless @result || @stopped || @failure

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
        @failure_kind, @failure_basis = classify_failure(@evidence)
        raise @failure
      end
      unless fingerprint_held?(@evidence)
        @failure = Error.new("snapshot fingerprint missing or changed")
        @failure_kind = "invalid_result"
        @failure_basis = "structural"
        raise @failure
      end
      begin
        @result = validate_result(@evidence["result"])
      rescue Error => error
        @failure = error
        @failure_kind = "invalid_result"
        @failure_basis = "structural"
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
      @failure_kind = @failure_basis = nil
      @reaped = @stopped = false
    end

    # A check process is in flight until it has produced a result, been stopped,
    # or failed. A failed run is over: the process has exited, so the caller may
    # switch models and start the next check. This is what lets a task stay alive
    # (blocked) after an auth/quota failure and retry on Root's explicit model
    # instead of terminating.
    def in_flight?
      @run && !@result && !@stopped && !@failure
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
      problems = (Array(evidence.is_a?(Hash) ? evidence["problems"] : nil) +
                  Array(evidence.is_a?(Hash) ? evidence["contract_problems"] : nil)).map(&:to_s).reject(&:empty?).uniq
      parts << "evidence problems: #{problems.join('; ')}" unless problems.empty?
      parts.join("\n")
    end

    def classify_failure(evidence)
      structured = evidence.is_a?(Hash) ? evidence["error"] : nil
      if structured.is_a?(Hash)
        kind = structured["kind"].to_s.strip
        return [kind, "structured"] if FAILURE_KINDS.include?(kind)
      end

      # A run whose returned result failed the check-result contract (for
      # example a parseable result with next_check_seconds=0) means the model
      # did respond and produced structurally invalid output. That is never an
      # availability failure, so it is classified from the evidence contract
      # before the text heuristic.
      contract = evidence.is_a?(Hash) ? evidence["contract_problems"] : nil
      return ["invalid_result", "structural"] if contract.is_a?(Array) && !contract.empty?

      problems = evidence.is_a?(Hash) ? Array(evidence["problems"]).join(" ") : ""
      text = "#{problems} #{@failure && @failure.message}"
      return ["auth_or_quota", "heuristic"] if text.match?(AUTH_OR_QUOTA_PATTERN)

      ["unavailable", "heuristic"]
    end
  end
end
