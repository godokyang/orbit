# frozen_string_literal: true

require "open3"
require_relative "release_lease"

module Orbit
  # Explicit OMP entry. It starts the original omp binary and appends this
  # release's Orbit extension through OMP's own -e/--extension flag. The entry
  # only adds that explicit extension: whatever else OMP discovers (for
  # example a user extension) still loads as usual, and a plain `omp` launch is
  # untouched because the single-host installation never links a global Orbit
  # extension. Native flags (--model, --resume, --profile, permissions, help,
  # messages), terminal behavior and the exit code all pass through unchanged.
  #
  # Only the OMP version verified with this extension is accepted. Adopting a
  # new version has to follow ADR-008: recheck the extension hooks, task/hub,
  # model resolution and the stop path in an isolated project, then move the
  # pin; until then a mismatched CLI is refused instead of being presented as
  # supported.
  #
  # The launcher also exports one process-local PI_CONFIG_FILES overlay that
  # keeps idle native members attached for this process (see
  # IDLE_PARKING_OVERLAY). It is never written to global or project config and
  # does not touch argv: explicit user config files are still merged by OMP
  # after environment overlays and keep precedence.
  module OmpEntry
    module_function

    EXTENSION = File.expand_path("../../plugins/omp.mjs", __dir__)
    # Process-local OMP overlay: task.agentIdleTtlMs=0 keeps completed native
    # members attached until this process exits, so the member bridge can
    # verify their turn, attached jobs and PIDs on an explicit stop instead of
    # observing an already-parked session. PI_CONFIG_FILES is additive and
    # process-scoped; OMP appends every explicit user --config after
    # environment overlays, so a user config file keeps precedence.
    IDLE_PARKING_OVERLAY = File.expand_path("../../plugins/omp-idle-parking.yml", __dir__)

    PINNED_OMP_VERSION = "18.2.8"
    # The independent reviewer runner installs exactly this SDK release; the
    # installer verifies it inside the staged release before the switch.
    PINNED_SDK_VERSION = "18.2.8"

    # The exact command line handed to the OS, kept separate from exec so the
    # passthrough contract can be asserted without replacing the test process.
    def command(argv)
      ["omp", "-e", EXTENSION, *argv]
    end

    # The environment diff for the child process. PI_CONFIG_FILES is additive
    # in OMP, so every pre-existing entry is preserved verbatim; the overlay is
    # appended last to win over an earlier environment config file. Putting it
    # here instead of argv keeps native flags, including the user's own
    # --config and --profile, byte-for-byte untouched.
    def launch_env(env = ENV)
      existing = env["PI_CONFIG_FILES"].to_s
      return { "PI_CONFIG_FILES" => existing } if existing.split(File::PATH_SEPARATOR).include?(IDLE_PARKING_OVERLAY)

      value = existing.empty? ? IDLE_PARKING_OVERLAY : "#{existing}#{File::PATH_SEPARATOR}#{IDLE_PARKING_OVERLAY}"
      { "PI_CONFIG_FILES" => value }
    end

    # `omp --version` prints `omp/18.2.8`; anything unparseable is an error,
    # not a silent pass.
    def detected_version(executable = "omp")
      out, err, status = Open3.capture3(executable, "--version")
      unless status.success?
        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise ArgumentError, "无法确定 OMP 版本（#{executable} --version 退出 #{status.exitstatus}）：#{detail}"
      end
      match = out.match(/(\d+\.\d+\.\d+)/)
      raise ArgumentError, "无法解析 OMP 版本输出：#{out.strip.inspect}" unless match

      match[1]
    end

    def launch(argv)
      raise ArgumentError, "Orbit OMP extension is missing: #{EXTENSION}" unless File.file?(EXTENSION)
      unless File.file?(IDLE_PARKING_OVERLAY)
        raise ArgumentError, "Orbit OMP idle-parking overlay is missing: #{IDLE_PARKING_OVERLAY}"
      end

      version = detected_version
      unless version == PINNED_OMP_VERSION
        raise ArgumentError,
              "OMP #{version} 不在当前已验证范围：Orbit 只支持 OMP #{PINNED_OMP_VERSION}，orbit omp 拒绝启动未验证版本。" \
              "更新 OMP 前先按 ADR-008 在隔离项目复核扩展钩子、task/hub、模型解析与停止路径，再更新 pin。"
      end

      # exec keeps the pid, so the lease written here covers the OMP process
      # that continues in this process image. A source checkout has no release
      # record and records nothing.
      ReleaseLease.hold!
      exec(launch_env, *command(argv))
    rescue Errno::ENOENT
      raise ArgumentError, "omp was not found on PATH; install Oh My Pi first"
    end
  end
end
