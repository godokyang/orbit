# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tmpdir"

require_relative "omp_check_runner"

module Orbit
  # Supervises exactly one JEV compaction model call in its own local OMP
  # process: the no-tools session in runners/omp-reviewer/compaction.ts.
  #
  # The runner reuses the independent checker's confinement, catalog and
  # credential path (OmpCheckRunner): a fresh profile directory, the parent
  # session's own agent dir as the source catalog, and the same host launcher
  # flags with only the trusted extension entry swapped. No HTTP provider client
  # and no second login are introduced here.
  #
  # One `run` starts one process, one prompt and one model call; a failure is
  # reported as a structured fact instead of being retried. The class never
  # caches, never decides which model to use and never judges the returned text:
  # JevInputCompactor owns those decisions.
  class JevCompactionRunner
    COMPACTOR = File.expand_path("../../runners/omp-reviewer/compaction.ts", __dir__)
    # A compaction is a single bounded prompt; the caller's own timeout governs.
    DEFAULT_TIMEOUT_SECONDS = 300
    POLL_SECONDS = 0.2

    class Error < StandardError; end

    attr_reader :command, :timeout_seconds, :allowed_models

    # Same confined native launcher as the reviewer, with this runner's trusted
    # extension path in place of the reviewer entry.
    def self.default_command
      OmpCheckRunner.default_command.map { |part| part == OmpCheckRunner::REVIEWER ? COMPACTOR : part }
    end

    def initialize(command: nil, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, allowed_models: nil, omp_version: nil)
      launcher = command || self.class.default_command
      raise Error, "compaction launcher is required" if launcher.empty? || launcher.first.to_s.empty?

      @command = launcher.map(&:to_s)
      @timeout_seconds = timeout_seconds.to_f
      raise Error, "compaction timeout must be positive" unless @timeout_seconds.positive?

      @allowed_models = ModelAuthorization.parse(allowed_models)
      @omp_version = omp_version
    end

    # Runs one compaction request. `prompt` is the full text sent to the model
    # (instruction, required items and the material to shorten); the caller
    # writes it, never this class. Returns structured facts:
    #
    #   {"ok" => bool, "text" => String|nil, "model" => String|nil,
    #    "usage" => Array|nil, "usage_gaps" => [String], "seconds" => Float,
    #    "attempt_id" => String, "error" => {"kind" =>, "detail" =>}|nil,
    #    "evidence" => Hash}
    #
    # `ok` is true only for a completed no-tools session that returned a
    # non-empty text with no drift or provider error. Every other path stays a
    # failed compaction: it is reported, never repaired or retried here.
    def run(prompt:, model:, allowed_models: nil, attempt_id: nil, omp_version: nil)
      text = prompt.to_s
      raise Error, "compaction prompt is required" if text.strip.empty?

      identity = model.to_s
      raise Error, "compaction model must be provider/id" unless identity.match?(OmpCheckRunner::MODEL_ID)

      authorization = allowed_models.nil? ? @allowed_models : ModelAuthorization.parse(allowed_models)
      ModelAuthorization.check!(identity, authorization)
      version = omp_version || @omp_version || OmpCheckRunner.reviewer_sdk_version(@command.first)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return failed(identity, "unavailable", "compaction launcher is not available: #{@command.first}", {}, 0.0) unless executable?

      request = { "model" => identity, "sdk_version" => version }
      request["allowed_models"] = authorization if authorization
      request["attempt_id"] = attempt_id if attempt_id
      request.merge!(OmpCheckRunner.source_session_fields)
      evidence = launch(request, text)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      facts = normalize(evidence, identity, seconds)
      facts["evidence"] = evidence
      facts
    rescue Error
      raise
    rescue SystemCallError => error
      raise Error, "cannot start the compaction runner: #{error.class}: #{error.message}"
    end

    # Zero-cost contract check: start the same confined host, create the no-tools
    # session (optionally for one exact model, which also verifies catalog and
    # credential resolution) and dispose it without sending a prompt. No provider
    # call and no charge. Used to verify the installed host accepts this session
    # shape before a real compaction is paid for.
    def probe(model: nil, omp_version: nil)
      identity = model&.to_s
      unless identity.nil? || identity.match?(OmpCheckRunner::MODEL_ID)
        raise Error, "compaction model must be provider/id"
      end

      version = omp_version || @omp_version || OmpCheckRunner.reviewer_sdk_version(@command.first)
      request = { "session_probe" => true, "sdk_version" => version }.merge(OmpCheckRunner.source_session_fields)
      request["model"] = identity if identity
      evidence = launch(request, nil)
      {
        "ok" => evidence["ok"] == true, "session_created" => evidence["session_created"],
        "session_disposed" => evidence["session_disposed"], "active_tools" => evidence["active_tools"],
        "model" => evidence["model"], "problems" => Array(evidence["problems"]), "evidence" => evidence
      }
    rescue SystemCallError => error
      raise Error, "cannot start the compaction probe: #{error.class}: #{error.message}"
    end

    private

    # One confined host run. `prompt` is written only for a real compaction; a
    # probe sends none.
    def launch(request, prompt)
      evidence = {}
      Dir.mktmpdir("orbit-compaction-") do |root|
        profile = File.join(root, "profile")
        FileUtils.mkdir_p(profile, mode: 0o700)
        evidence_path = File.join(root, "evidence.json")
        config_path = File.join(root, "request.json")
        stderr_path = File.join(root, "stderr.log")
        body = request.merge("profile" => profile, "out" => evidence_path)
        unless prompt.nil?
          prompt_path = File.join(root, "prompt.txt")
          File.write(prompt_path, prompt)
          body["prompt"] = prompt_path
        end
        File.write(config_path, JSON.generate(body))
        pid = spawn_compactor(config_path, profile, root, stderr_path)
        evidence = collect(pid, evidence_path, stderr_path)
      end
      evidence
    end

    # Starts the confined host in its own process group so the whole group can
    # be ended after the evidence file reports completion.
    def spawn_compactor(config_path, profile, root, stderr_path)
      env = OmpCheckRunner.confined_env(profile, root, config_path)
      env.delete("ORBIT_REVIEW_REQUEST")
      env["ORBIT_COMPACTION_REQUEST"] = config_path
      errors = File.open(stderr_path, "wb")
      args = OmpCheckRunner.host_command?(@command) ? @command : @command + ["--config", config_path]
      Process.spawn(env, *args, in: File::NULL, out: errors, err: [:child, :out],
                    pgroup: true, chdir: root, close_others: true)
    rescue SystemCallError => error
      raise Error, "cannot start the compaction runner: #{error.class}: #{error.message}"
    ensure
      errors&.close
    end

    # Waits for the running process to write its own completion evidence, then
    # ends the group. A timeout or an exit without that evidence is a failed
    # compaction with the reason, never a partial result.
    def collect(pid, evidence_path, stderr_path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds
      terminated = false
      status = nil
      loop do
        facts = read_evidence(evidence_path)
        if facts.is_a?(Hash) && facts["host_completion"] == "complete"
          unless terminated
            signal_group(pid, "TERM")
            terminated = true
          end
        end
        wait = Process.waitpid2(pid, Process::WNOHANG)
        status = wait&.last
        break if status

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          signal_group(pid, "KILL")
          Process.waitpid2(pid)
          return (read_evidence(evidence_path) || {}).merge(
            "problems" => Array(read_evidence(evidence_path)&.fetch("problems", nil)) +
                          ["compaction runner timed out after #{@timeout_seconds.round} seconds"]
          )
        end
        sleep(POLL_SECONDS)
      end
      facts = read_evidence(evidence_path)
      return facts if facts.is_a?(Hash) && facts["host_completion"] == "complete"

      { "problems" => ["compaction runner exited without completion evidence (exit #{exit_text(status)})",
                       "stderr: #{bounded(File.file?(stderr_path) ? File.read(stderr_path) : "")}"] }
    end

    def read_evidence(path)
      return nil unless File.file?(path)

      facts = JSON.parse(File.read(path))
      facts.is_a?(Hash) ? facts : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # The evidence file is the only result channel. Text, usage and timings are
    # reported exactly as the process observed them; a missing field stays nil.
    def normalize(evidence, requested_model, seconds)
      facts = evidence.is_a?(Hash) ? evidence : {}
      problems = Array(facts["problems"]).map(&:to_s).reject(&:empty?)
      error = facts["error"].is_a?(Hash) ? facts["error"] : nil
      observed = facts["elapsed_ms"].is_a?(Numeric) ? facts["elapsed_ms"] / 1000.0 : seconds
      text = facts["raw_text"].is_a?(String) && !facts["raw_text"].strip.empty? ? facts["raw_text"] : nil
      ok = facts["ok"] == true && text && problems.empty?
      {
        "ok" => !!ok,
        "text" => text,
        "model" => facts["model"].is_a?(String) ? facts["model"] : nil,
        "requested_model" => requested_model,
        "usage" => facts["usage"].is_a?(Array) ? facts["usage"] : nil,
        "usage_gaps" => Array(facts["usage_gaps"]).map(&:to_s),
        "attempt_id" => facts["attempt_id"].is_a?(String) ? facts["attempt_id"] : nil,
        "input_bytes" => facts["input_bytes"].is_a?(Numeric) ? facts["input_bytes"] : nil,
        "output_bytes" => facts["output_bytes"].is_a?(Numeric) ? facts["output_bytes"] : nil,
        "seconds" => observed.round(3),
        "error" => ok ? nil : (error || { "kind" => "unavailable", "detail" => bounded(problems.join("; ")) }),
        "problems" => problems
      }
    end

    def failed(requested_model, kind, detail, evidence, seconds)
      {
        "ok" => false, "text" => nil, "model" => nil, "requested_model" => requested_model,
        "usage" => nil, "usage_gaps" => [], "attempt_id" => nil, "input_bytes" => nil, "output_bytes" => nil,
        "seconds" => seconds, "error" => { "kind" => kind, "detail" => bounded(detail) },
        "problems" => [detail], "evidence" => evidence
      }
    end

    def exit_text(status)
      return "no status" unless status

      status.exitstatus || "signal #{status.termsig}"
    end

    def bounded(text)
      text.to_s.gsub(/\s+/, " ").strip.slice(0, 300)
    end

    def executable?
      binary = @command.first
      return File.executable?(binary) if binary.include?("/")

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, binary)) }
    end

    def signal_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
