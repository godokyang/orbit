# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "yaml"
require_relative "../lib/orbit/omp_entry"

# `orbit omp` is a transparent launcher: it must keep every native OMP argument
# and the native exit code, and add exactly one explicit `-e` for this
# repository's Orbit extension. A stub omp records the real argv so the contract
# is checked without starting a model.
module OmpEntryTest
  ENTRY = File.expand_path("../scripts/orbit", __dir__)

  module_function

  def assert(value, message)
    raise message unless value
  end

  def with_stub_omp(exit_code, version: "omp/#{Orbit::OmpEntry::PINNED_OMP_VERSION}")
    Dir.mktmpdir("orbit-omp-entry-") do |tmp|
      bin = File.join(tmp, "bin")
      FileUtils.mkdir_p(bin)
      out = File.join(tmp, "argv.txt")
      stub = File.join(bin, "omp")
      File.write(stub, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' "$STUB_VERSION"
          exit 0
        fi
        printf '%s\\n' "$@" > "$STUB_OUT"
        printf '%s\\n' "$PI_CONFIG_FILES" > "$STUB_OUT.env"
        exit #{exit_code}
      SH
      File.chmod(0o755, stub)
      env = { "PATH" => "#{bin}:#{ENV.fetch('PATH', '')}", "STUB_OUT" => out, "STUB_VERSION" => version }
      yield(env, out)
    end
  end

  def extension_is_the_repository_orbit_extension
    assert(Orbit::OmpEntry::EXTENSION == File.expand_path("../plugins/omp.mjs", __dir__),
           "the entry loads the repository extension, not a global install")
    assert(File.file?(Orbit::OmpEntry::EXTENSION), "the repository extension exists")
  end

  def command_passes_native_arguments_and_the_explicit_extension
    argv = ["--model", "openai/gpt-5.2", "--resume", "abc123", "--profile", "work", "hello"]
    assert(Orbit::OmpEntry.command(argv) == ["omp", "-e", Orbit::OmpEntry::EXTENSION, *argv],
           "native arguments are kept and -e is added once")
    assert(Orbit::OmpEntry.command([]) == ["omp", "-e", Orbit::OmpEntry::EXTENSION],
           "a bare launch still loads the extension")
  end

  def command_keeps_other_extensions_enabled
    argv = Orbit::OmpEntry.command(["--resume", "sess-1"])
    assert(argv.count("-e") == 1 && !argv.include?("--no-extensions"),
           "only the explicit Orbit extension is added; ambient extensions stay enabled")
  end

  def idle_parking_overlay_only_sets_the_process_local_task_ttl
    overlay = Orbit::OmpEntry::IDLE_PARKING_OVERLAY
    assert(File.file?(overlay), "the idle-parking overlay ships with the entry")
    assert(YAML.safe_load(File.read(overlay)) == { "task" => { "agentIdleTtlMs" => 0 } },
           "the overlay sets exactly task.agentIdleTtlMs=0 and cannot change any other OMP setting")
  end

  def launch_env_appends_the_overlay_after_existing_config_files
    overlay = Orbit::OmpEntry::IDLE_PARKING_OVERLAY
    assert(Orbit::OmpEntry.launch_env({}) == { "PI_CONFIG_FILES" => overlay },
           "a launch without PI_CONFIG_FILES exports only the overlay")
    existing = "/tmp/user-a.yml#{File::PATH_SEPARATOR}/tmp/user-b.yml"
    env = { "PI_CONFIG_FILES" => existing }
    assert(Orbit::OmpEntry.launch_env(env) ==
             { "PI_CONFIG_FILES" => "#{existing}#{File::PATH_SEPARATOR}#{overlay}" },
           "the overlay is appended after every pre-existing entry")
    assert(env == { "PI_CONFIG_FILES" => existing }, "the caller's environment hash is not mutated")
    assert(Orbit::OmpEntry.launch_env("PI_CONFIG_FILES" => overlay) == { "PI_CONFIG_FILES" => overlay },
           "an already exported overlay is not duplicated")
  end

  def real_entry_exports_the_overlay_without_touching_native_flags
    with_stub_omp(0) do |env, out|
      argv = ["--config", "user.yml", "--profile", "work", "--model", "openai/gpt-5.2", "hello"]
      _stdout, stderr, status = Open3.capture3(env.merge("PI_CONFIG_FILES" => "/tmp/user.yml"),
                                               RbConfig.ruby, "--disable-gems", ENTRY, "omp", *argv)
      assert(status.success?, "the stub launch succeeds (#{stderr})")
      assert(File.read(out).split("\n") == ["-e", Orbit::OmpEntry::EXTENSION, *argv],
             "every native flag, including the user's own --config and --profile, stays untouched")
      assert(File.read("#{out}.env").strip ==
               "/tmp/user.yml#{File::PATH_SEPARATOR}#{Orbit::OmpEntry::IDLE_PARKING_OVERLAY}",
             "the child receives the process-local overlay after the user's own environment config files")
    end
  end

  def mismatched_native_version_is_refused
    with_stub_omp(0, version: "omp/18.3.0") do |env, out|
      _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "--disable-gems", ENTRY, "omp", "--model", "x")
      assert(status.exitstatus == 1, "a mismatched OMP version is refused")
      assert(stderr.include?("18.3.0") && stderr.include?(Orbit::OmpEntry::PINNED_OMP_VERSION) && stderr.include?("拒绝"),
             "the refusal names the detected and pinned versions")
      assert(!File.exist?(out), "a refused launch never starts omp")
    end
  end

  def unparseable_native_version_is_refused
    with_stub_omp(0, version: "omp/development") do |env, out|
      _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "--disable-gems", ENTRY, "omp")
      assert(status.exitstatus == 1 && stderr.include?("无法解析"), "an unparseable version is refused with the reason")
      assert(!File.exist?(out), "an unparseable version never starts omp")
    end
  end

  def detected_version_parses_the_omp_cli_output
    with_stub_omp(0) do |env, _out|
      stdout, _stderr, status = Open3.capture3(env, RbConfig.ruby, "--disable-gems",
                                               "-r", File.expand_path("../lib/orbit/omp_entry.rb", __dir__),
                                               "-e", "puts Orbit::OmpEntry.detected_version")
      assert(status.success? && stdout.strip == Orbit::OmpEntry::PINNED_OMP_VERSION,
             "omp/18.2.8 is parsed to the pinned version")
    end
  end

  def exit_code_is_preserved_through_the_real_entry
    with_stub_omp(23) do |env, out|
      argv = ["--model", "openai/gpt-5.2", "--resume", "sess-1"]
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "--disable-gems", ENTRY, "omp", *argv)
      assert(status.exitstatus == 23, "the native exit code is preserved (got #{status.exitstatus}: #{stderr})")
      assert(File.read(out).split("\n") == ["-e", Orbit::OmpEntry::EXTENSION, *argv],
             "the real entry launches omp with the explicit extension and the untouched argv")
      assert(stdout.empty?, "the wrapper adds no output of its own")
    end
  end

  def native_help_passes_through_and_wrapper_help_stays_available
    with_stub_omp(7) do |env, out|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "--disable-gems", ENTRY, "omp", "--help")
      assert(status.exitstatus == 7, "orbit omp --help reaches omp and keeps its exit code (got #{status.exitstatus}: #{stderr})")
      assert(File.read(out).split("\n") == ["-e", Orbit::OmpEntry::EXTENSION, "--help"],
             "the native --help is passed through untouched")
      assert(stdout.empty?, "the wrapper adds no help text of its own")
    end
    with_stub_omp(7) do |env, out|
      Open3.capture3(env, RbConfig.ruby, "--disable-gems", ENTRY, "omp", "-h")
      assert(File.read(out).split("\n") == ["-e", Orbit::OmpEntry::EXTENSION, "-h"],
             "the native -h is passed through too")
    end
    with_stub_omp(99) do |env, out|
      stdout, = Open3.capture3(env, RbConfig.ruby, "--disable-gems", ENTRY, "help", "omp")
      assert(stdout.include?("orbit omp [OMP 原生参数]") && stdout.include?("-e"),
             "orbit help omp still explains the wrapper")
      assert(!File.exist?(out), "wrapper help never starts omp")
    end
  end

  def main
    extension_is_the_repository_orbit_extension
    command_passes_native_arguments_and_the_explicit_extension
    command_keeps_other_extensions_enabled
    idle_parking_overlay_only_sets_the_process_local_task_ttl
    launch_env_appends_the_overlay_after_existing_config_files
    real_entry_exports_the_overlay_without_touching_native_flags
    mismatched_native_version_is_refused
    unparseable_native_version_is_refused
    detected_version_parses_the_omp_cli_output
    exit_code_is_preserved_through_the_real_entry
    native_help_passes_through_and_wrapper_help_stays_available
    puts "OMP_ENTRY_TEST_PASS explicit -e extension, native argv passthrough and exit code"
  end
end

OmpEntryTest.main
