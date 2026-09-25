# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "digest"
require_relative "../scripts/manage-install"

module InstallTest
  ROOT = File.expand_path("..", __dir__)
  module_function

  def run(*args, env: {}, success: true, cwd: @temp)
    out, err, status = Open3.capture3(@env.merge(env), *args, chdir: cwd)
    raise "#{args.inspect}\n#{out}\n#{err}" unless status.success? == success
    out
  end

  def assert(value, message)
    raise message unless value
  end

  def json(path)
    JSON.parse(File.read(path))
  end

  def missing_prerequisites
    Dir.mktmpdir("orbit-install-missing-") do |tmp|
      script = 'begin; OrbitInstall.prerequisites!; rescue => error; warn error.message; exit 2; end'
      _out, err, status = Open3.capture3({ "PATH" => tmp }, RbConfig.ruby, "--disable-gems", "-r",
                                         File.join(ROOT, "scripts/manage-install.rb"), "-e", script)
      assert(status.exitstatus == 2 && err.include?("Node.js 18+") && err.include?("npm") &&
             err.include?("bun >= 1.3.14") && !err.include?("Codex CLI") && err.include?("重新运行 Orbit 安装命令"),
             "single-host prerequisites are listed with a next step before installation")
    end
  end

  # bun installs the pinned reviewer SDK inside the staged release. The fixture
  # records the expected invocation and creates the SDK layout without network
  # access; version drift and install failures stay reachable in regression.
  def write_fixture_bun(directory)
    FileUtils.mkdir_p(directory)
    bun = File.join(directory, "bun")
    File.write(bun, <<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf '%s\\n' "${ORBIT_FIXTURE_BUN_VERSION:-1.3.14}"
        exit 0
      fi
      if [ "$1" != "install" ] || [ "$2" != "--frozen-lockfile" ]; then
        echo "fixture bun: unexpected arguments: $*" >&2
        exit 2
      fi
      if [ -n "$ORBIT_FIXTURE_BUN_FAIL" ]; then
        echo "fixture bun: dependency install failed" >&2
        exit 3
      fi
      mkdir -p node_modules/@oh-my-pi/pi-coding-agent || exit 1
      printf '{"name":"@oh-my-pi/pi-coding-agent","version":"%s"}\\n' "${ORBIT_FIXTURE_SDK_VERSION:-18.2.8}" > node_modules/@oh-my-pi/pi-coding-agent/package.json
      exit 0
    SH
    File.chmod(0o755, bun)
  end

  def fixture
    Dir.mktmpdir("orbit-install-test-") do |tmp|
      @temp = tmp
      @source = File.join(tmp, "source")
      @runtime = File.join(tmp, "runtime with spaces")
      @bin = File.join(tmp, "bin with spaces")
      @skills = File.join(tmp, "skills")
      @opencode = File.join(tmp, "opencode config")
      @omp = File.join(tmp, "omp agent")
      @shell_config = File.join(tmp, "shell config")
      @fixture_bin = File.join(tmp, "fixture-bin")
      write_fixture_bun(@fixture_bin)
      @env = { "SHELL" => "/bin/zsh", "ZDOTDIR" => @shell_config, "PATH" => @fixture_bin + File::PATH_SEPARATOR + ENV.fetch("PATH", ""),
               "ORBIT_REF" => nil, "ORBIT_RUNTIME_DIR" => nil, "ORBIT_INSTALL_DIR" => nil, "ORBIT_SKILL_DIR" => @skills, "OPENCODE_CONFIG_DIR" => @opencode, "PI_CODING_AGENT_DIR" => @omp }
      files = JSON.parse(run("npm", "pack", "--dry-run", "--json", "--ignore-scripts", cwd: ROOT))[0]["files"]
      files.each do |file|
        dest = File.join(@source, file.fetch("path"))
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(File.join(ROOT, file.fetch("path")), dest, preserve: true)
      end
      run("git", "init", "-q", @source)
      run("git", "add", ".", cwd: @source)
      run("git", "-c", "user.name=Orbit test", "-c", "user.email=orbit@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture", cwd: @source)
      yield
    end
  end

  def install(*args, env: {}, success: true, explicit_paths: true)
    paths = explicit_paths ? ["--bin-dir", @bin] : []
    run("sh", File.join(@source, "install.sh"), "--runtime-dir", @runtime, "--no-modify-path", *paths, *args, env: env, success: success)
  end

  def version
    JSON.parse(run(File.join(@bin, "orbit"), "version", "--json", cwd: "/"))
  end

  def active
    File.realpath(File.join(@runtime, "current"))
  end

  # An installation made by a release from before the pinned-Ruby wrapper
  # upgrades in place: the on-disk wrapper matching the old template for the
  # same runtime is recognized as owned, replaced atomically during update,
  # and the CLI keeps working from outside the repository.
  def old_wrapper_update
    archive = File.join(@temp, "source.tar.gz")
    run("tar", "--exclude=.git", "-czf", archive, "-C", @temp, "source")
    transport = File.join(@temp, "transport")
    FileUtils.mkdir_p(transport)
    File.write(File.join(transport, "curl"), <<~SCRIPT)
      #!/bin/sh
      cat "#{archive}"
    SCRIPT
    File.chmod(0o755, File.join(transport, "curl"))
    transport_env = { "PATH" => @fixture_bin + File::PATH_SEPARATOR + transport + File::PATH_SEPARATOR + ENV.fetch("PATH"),
                      "ORBIT_FIXTURE_BUN_VERSION" => Orbit::OmpEntry::PINNED_SDK_VERSION[/\d+\.\d+\.\d+/] }

    install(env: { "PATH" => @fixture_bin + File::PATH_SEPARATOR + ENV.fetch("PATH") })
    wrapper_path = File.join(@bin, "orbit")
    File.write(wrapper_path, OrbitInstall.legacy_wrapper(@runtime))
    bump
    run("tar", "--exclude=.git", "-czf", archive, "-C", @temp, "source")
    run(File.join(@bin, "orbit"), "update", env: transport_env, cwd: "/")
    assert(version["version"] == @updated_version, "update succeeds over the pre-Ruby-pin wrapper")
    upgraded = File.binread(wrapper_path)
    assert(upgraded == OrbitInstall.wrapper(@runtime) && upgraded.include?("ORBIT_RUBY="),
           "the owned legacy wrapper is replaced by the pinned-Ruby template")
    poison = File.join(@temp, "poison-bin")
    FileUtils.mkdir_p(poison)
    File.write(File.join(poison, "ruby"), "#!/bin/sh\necho 'ruby 2.6.10 (shadow)' >&2\nexit 42\n")
    File.chmod(0o755, File.join(poison, "ruby"))
    JSON.parse(run(File.join(@bin, "orbit"), "version", "--json",
                   env: { "PATH" => poison + File::PATH_SEPARATOR + ENV.fetch("PATH") }, cwd: "/"))

    # A wrapper that matches neither the current nor the legacy template is
    # unowned: the source installer refuses (the on-disk wrapper itself is no
    # longer Orbit code) and the current release stays active.
    File.write(wrapper_path, "#!/bin/sh\necho tampered\n")
    before = active
    refusal = begin
      install(env: transport_env)
      nil
    rescue RuntimeError => error
      error.message
    end
    assert(refusal && refusal.include?("refusing to overwrite unowned"),
           "a tampered CLI wrapper is refused by the installer")
    assert(active == before && File.read(File.join(@bin, "orbit")).include?("tampered"),
           "the refused update leaves the installation unchanged")
  end

  # Reproduce the format 3 layout: the marker records the host directories and
  # the installation owns a link into its current release at each one.
  def link_legacy_host_entries
    marker = File.join(@runtime, OrbitInstall::MARKER)
    owner = json(marker)
    owner["format"] = "orbit-install-3"
    owner["omp_dir"] = @omp
    owner["opencode_dir"] = @opencode
    File.write(marker, JSON.pretty_generate(owner))
    FileUtils.mkdir_p(File.join(@omp, "extensions"))
    FileUtils.mkdir_p(File.join(@opencode, "plugins"))
    File.symlink(File.join(@runtime, "current/plugins/omp.mjs"), File.join(@omp, "extensions/orbit.js"))
    File.symlink(File.join(@runtime, "current/plugins/opencode.mjs"), File.join(@opencode, "plugins/orbit.js"))
  end

  # The installed entry must load the extension from the release it belongs to
  # and keep every native argument. A stub omp records the real argv.
  def installed_omp_entry
    stub = File.join(@temp, "omp-stub")
    FileUtils.mkdir_p(stub)
    recorded = File.join(@temp, "omp-argv.txt")
    exported = File.join(@temp, "omp-env.txt")
    File.unlink(recorded) if File.exist?(recorded)
    File.unlink(exported) if File.exist?(exported)
    File.write(File.join(stub, "omp"), <<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf '%s\\n' "omp/#{Orbit::OmpEntry::PINNED_OMP_VERSION}"
        exit 0
      fi
      printf '%s\\n' "$@" > "$STUB_OUT"
      printf '%s\\n' "$PI_CONFIG_FILES" > "$STUB_ENV"
    SH
    File.chmod(0o755, File.join(stub, "omp"))
    args = ["--model", "native/model", "--resume", "sess-1"]
    _out, err, status = Open3.capture3({ "PATH" => stub + File::PATH_SEPARATOR + ENV.fetch("PATH"),
                                        "STUB_OUT" => recorded, "STUB_ENV" => exported, "PI_CONFIG_FILES" => nil },
                                       File.join(@bin, "orbit"), "omp", *args)
    expected = ["-e", File.join(active, "plugins/omp.mjs"), *args]
    overlay = File.join(active, "plugins/omp-idle-parking.yml")
    exported_overlay = File.read(exported).strip
    assert(status.success? && File.read(recorded).split("\n") == expected &&
           File.file?(overlay) && File.file?(exported_overlay) &&
           File.realpath(exported_overlay) == File.realpath(overlay),
           "installed orbit omp loads the release extension, keeps native arguments and exports the installed idle-parking overlay (#{err})")
  end

  def bump
    package = File.join(@source, "package.json")
    data = json(package)
    @updated_version = data.fetch("version").sub(/\d+\z/) { |patch| (patch.to_i + 1).to_s }
    data["version"] = @updated_version
    File.write(package, JSON.pretty_generate(data))
    lock = File.join(@source, "npm-shrinkwrap.json")
    data = json(lock)
    data["version"] = data.fetch("packages").fetch("")["version"] = @updated_version
    File.write(lock, JSON.pretty_generate(data))
  end

  def first_install
    # Exercise the remote bootstrap without depending on a moving public branch.
    # curl is a transport fixture; unpacking, npm ci and installed CLI are real.
    archive = File.join(@temp, "source.tar.gz")
    run("tar", "--exclude=.git", "-czf", archive, "-C", @temp, "source")
    transport = File.join(@temp, "transport")
    FileUtils.mkdir_p(transport)
    File.write(File.join(transport, "curl"), <<~SCRIPT)
      #!#{RbConfig.ruby}
      require "json"
      require "fileutils"
      url = ARGV.last
      destination = ARGV.fetch(ARGV.index("-o") + 1)
      File.open(ENV.fetch("ORBIT_FIXTURE_CURL_LOG"), "a") { |f| f.puts(url) }
      if url == "https://api.github.com/repos/godokyang/orbit/commits/branch%2Fstable"
        File.write(destination, JSON.generate("sha" => "a" * 40))
      elsif url == "https://codeload.github.com/godokyang/orbit/tar.gz/" + "a" * 40
        FileUtils.cp(ENV.fetch("ORBIT_FIXTURE_ARCHIVE"), destination)
      else
        abort "unexpected unpinned source request: " + url
      end
    SCRIPT
    File.chmod(0o755, File.join(transport, "curl"))
    log = File.join(@temp, "downloads.log")
    transport_env = { "PATH" => @fixture_bin + File::PATH_SEPARATOR + transport + File::PATH_SEPARATOR + ENV.fetch("PATH"),
                      "ORBIT_FIXTURE_CURL_LOG" => log, "ORBIT_FIXTURE_ARCHIVE" => archive }
    install_out = install("--modify-path", "--ref", "branch/stable", env: transport_env)
    assert(install_out.include?("Independent reviewer bundle"), "install reports the reviewer bundle")
    shell_before = File.read(File.join(@shell_config, ".zshrc"))
    assert(run("zsh", "-ic", "command -v orbit").strip == File.join(@bin, "orbit"), "fresh zsh discovers installed CLI")
    info = version
    assert(info.fetch("version") == json(File.join(ROOT, "package.json")).fetch("version"), "installed CLI version")
    assert(info.dig("source", "commit") == "a" * 40 && info.dig("source", "ref") == "branch/stable", "record pinned commit and requested ref")
    assert(File.readlines(log).length == 2, "resolve source once, fetch one fixed archive")
    assert([@skills, File.join(@opencode, "skills"), File.join(@omp, "skills")].none? { |p| File.exist?(p) }, "CLI installation creates no skill directories")
    assert(run(File.join(@bin, "orbit"), "--version").strip == "orbit #{info['version']}", "short version command")
    assert(!File.exist?(File.join(active, "lib/orbit/v2")), "no retired runtime in installation")
    assert(!File.exist?(File.join(@omp, "extensions/orbit.js")) && !File.exist?(File.join(@opencode, "plugins/orbit.js")),
           "the single-host install creates no global Orbit entry")
    sdk = File.join(active, "runners/omp-reviewer/node_modules/@oh-my-pi/pi-coding-agent/package.json")
    assert(File.file?(sdk) && JSON.parse(File.read(sdk)).fetch("version") == Orbit::OmpEntry::PINNED_SDK_VERSION,
           "the release carries the pinned reviewer SDK")
    assert(File.file?(File.join(active, "runners/omp-reviewer/bun.lock")), "the release carries the reviewer lockfile")
    installed_omp_entry
    diagnosis = JSON.parse(run(File.join(@bin, "orbit"), "doctor", "--json", cwd: "/"))
    assert(diagnosis.dig("installation", "ready") && diagnosis.dig("connection", "ready").nil?, "installed CLI does not prove a connected session")

    # A PATH that resolves `ruby` to an older interpreter must not break the
    # installed CLI: the wrapper pins the Ruby that passed installation.
    poison = File.join(@temp, "poison-bin")
    FileUtils.mkdir_p(poison)
    File.write(File.join(poison, "ruby"), "#!/bin/sh\necho 'ruby 2.6.10 (shadow)' >&2\nexit 42\n")
    File.chmod(0o755, File.join(poison, "ruby"))
    shadowed = JSON.parse(run(File.join(@bin, "orbit"), "version", "--json",
                              env: { "PATH" => poison + File::PATH_SEPARATOR + ENV.fetch("PATH") }, cwd: "/"))
    assert(shadowed["version"] == json(File.join(active, "package.json"))["version"],
           "the installed CLI runs under the pinned Ruby even when an older ruby shadows PATH")
    wrapper = File.read(File.join(@bin, "orbit"))
    assert(wrapper.include?(RbConfig.ruby) && wrapper.include?("ORBIT_RUBY=") &&
           wrapper.include?('"$ORBIT_RUBY" --disable-gems "$ORBIT_RELEASE/scripts/orbit"'),
           "the wrapper pins the install-time Ruby, keeps --disable-gems, and exports it for extension children")

    # Switch from a format 3 install: the owned global entries are part of the
    # switch, doctor reports them while present, and the update only claims
    # passivity after they are verified gone.
    link_legacy_host_entries
    pending = JSON.parse(run(File.join(@bin, "orbit"), "doctor", "--json", cwd: "/", success: false))
    assert(!pending.dig("installation", "ready") && !pending["ready"],
           "an owned legacy extension keeps the installation not ready")
    bump
    run("tar", "--exclude=.git", "-czf", archive, "-C", @temp, "source")
    out = run(File.join(@bin, "orbit"), "update", env: transport_env, cwd: "/")
    assert(version["version"] == @updated_version && version.dig("source", "ref") == "branch/stable", "remote update follows the recorded ref")
    assert(File.readlines(log).length == 4, "remote update resolves original ref again")
    assert(!File.symlink?(File.join(@omp, "extensions/orbit.js")) && !File.symlink?(File.join(@opencode, "plugins/orbit.js")),
           "update removes the owned legacy global entries")
    assert(json(File.join(@runtime, OrbitInstall::MARKER)).fetch("format") == OrbitInstall::FORMAT, "the switch records the single-host format")
    assert(out.include?("plain omp loads no Orbit extension"), "a clean switch may claim passivity")
    assert(File.read(File.join(@shell_config, ".zshrc")) == shell_before, "update does not append duplicate PATH blocks")
  end

  def successful_update
    prepare_external_skills
    install
    old = active
    obsolete = File.join(old, "obsolete-rule.md")
    File.write(obsolete, "old shipped rule")
    marker = File.join(old, ".orbit-release.json")
    record = json(marker)
    record["files"] << "obsolete-rule.md"
    File.write(marker, JSON.generate(record))
    File.write(File.join(@runtime, "user-notes.txt"), "keep")
    bump
    File.open(File.join(@source, "README.md"), "a") { |f| f.puts("\nUpdated fixture readme.") }
    run(File.join(@bin, "orbit"), "update", env: { "ORBIT_RUNTIME_DIR" => "/wrong-runtime", "ORBIT_INSTALL_DIR" => "/wrong-bin" }, cwd: "/")
    assert(version["version"] == @updated_version, "updated CLI version")
    assert(version.dig("source", "commit") == run("git", "rev-parse", "HEAD", cwd: @source).strip, "local source commit recorded")
    assert(version.dig("source", "dirty") == true, "local edits not mislabeled as clean commit")
    assert(!File.exist?(old) && !File.exist?(obsolete), "retired release and obsolete shipped files removed")
    assert_external_skills
    assert(!File.exist?(File.join(@opencode, "plugins/orbit.js")) && !File.exist?(File.join(@omp, "extensions/orbit.js")),
           "update keeps the single-host layout free of global Orbit entries")
    assert(File.read(File.join(@runtime, "user-notes.txt")) == "keep", "update preserves user files")
    assert(!File.exist?(@shell_config), "update preserves the PATH opt-out")
  end

  # A release referenced by a running task or loaded host must survive update;
  # a later install removes it once its holders are gone.
  def update_keeps_referenced_release
    install
    old = active
    record = File.join(@temp, "fake task")
    FileUtils.mkdir_p(record)
    File.write(File.join(record, "state.json"), JSON.generate(
      "connection" => { "provider" => "opencode", "socket" => File.join(@temp, "missing.sock") }
    ))
    task_pid = Process.spawn(File.join(@bin, "orbit"), "run", record, out: File::NULL, err: File::NULL)
    Process.wait(task_pid)
    leases = Dir.glob(File.join(old, ".leases/*.json"))
    assert(leases.any? { |path| JSON.parse(File.read(path))["pid"] == task_pid },
           "a task runtime records its release lease")
    run("node", "--input-type=module", "-e", "await import('./plugins/host.mjs')", cwd: old)
    assert(Dir.glob(File.join(old, ".leases/*.json")).length == 2,
           "a loaded host records its release lease")
    omp_stub = File.join(@temp, "omp-lease-stub")
    FileUtils.mkdir_p(omp_stub)
    File.write(File.join(omp_stub, "omp"), <<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf '%s\\n' "omp/#{Orbit::OmpEntry::PINNED_OMP_VERSION}"
        exit 0
      fi
      sleep 30
    SH
    File.chmod(0o755, File.join(omp_stub, "omp"))
    omp_pid = Process.spawn({ "PATH" => omp_stub + File::PATH_SEPARATOR + ENV.fetch("PATH") },
                            File.join(@bin, "orbit"), "omp", out: File::NULL, err: File::NULL)

    holder = Process.spawn(RbConfig.ruby, "--disable-gems", "-r", File.join(old, "lib/orbit/release_lease.rb"),
                           "-e", "Orbit::ReleaseLease.hold!; sleep", out: File::NULL, err: File::NULL)
    begin
      50.times do
        break if File.file?(File.join(old, ".leases", "#{omp_pid}.json"))
        sleep 0.1
      end
      assert(File.file?(File.join(old, ".leases", "#{omp_pid}.json")), "the orbit omp entry records its release lease")
      50.times do
        break if File.file?(File.join(old, ".leases", "#{holder}.json"))
        sleep 0.1
      end
      assert(File.file?(File.join(old, ".leases", "#{holder}.json")), "test holder records a live lease")
      bump
      run(File.join(@bin, "orbit"), "update", cwd: "/")
      assert(version["version"] == @updated_version, "update succeeds while a task or host holds the old release")
      assert(File.file?(File.join(old, "scripts/orbit")), "a release in use survives update")
    ensure
      [holder, omp_pid].each do |pid|
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    bump
    run(File.join(@bin, "orbit"), "update", cwd: "/")
    assert(!File.exist?(old), "stale leases let a later update clean the retired release")
  end

  def failed_update
    prepare_external_skills
    install
    before = version
    old = active
    link_legacy_host_entries
    bump
    runner = File.join(@temp, "failed-dependency")
    FileUtils.mkdir_p(runner)
    npm = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |p| File.join(p, "npm") }.find { |p| File.executable?(p) }
    File.write(File.join(runner, "npm"), <<~SCRIPT)
      #!#{RbConfig.ruby}
      abort "fixture: dependency install failed" if ARGV.first == "ci"
      exec #{npm.inspect}, *ARGV
    SCRIPT
    File.chmod(0o755, File.join(runner, "npm"))
    run(File.join(@bin, "orbit"), "update", env: { "PATH" => runner + File::PATH_SEPARATOR + @fixture_bin + File::PATH_SEPARATOR + ENV.fetch("PATH") }, success: false, cwd: "/")
    assert(version == before && active == old, "failed dependency update retains working old installation")
    assert_external_skills
    assert(File.readlink(File.join(@opencode, "plugins/orbit.js")) == File.join(@runtime, "current/plugins/opencode.mjs") &&
           File.realpath(File.join(@omp, "extensions/orbit.js")) == File.join(old, "plugins/omp.mjs"),
           "failed update retains the legacy host entries untouched")
    assert(json(File.join(@runtime, OrbitInstall::MARKER)).fetch("format") == "orbit-install-3",
           "failed update keeps the old installation record")
    assert(Dir.glob(File.join(@runtime, ".prepare-*"), File::FNM_DOTMATCH).empty?, "failed preparation cleaned")
  end

  # A reviewer SDK that does not match the pin aborts preparation; the old
  # release and its pinned SDK stay active.
  def reviewer_sdk_version_mismatch_keeps_old_release
    install
    before = version
    old = active
    bump
    _out, err, status = Open3.capture3(@env.merge("ORBIT_FIXTURE_SDK_VERSION" => "18.3.0"),
                                       File.join(@bin, "orbit"), "update", chdir: "/")
    assert(!status.success? && err.include?("does not match the pinned"),
           "a drifted reviewer SDK aborts the update (#{err})")
    assert(version == before && active == old, "the previous release stays active with the pinned SDK")
    sdk = File.join(old, "runners/omp-reviewer/node_modules/@oh-my-pi/pi-coding-agent/package.json")
    assert(JSON.parse(File.read(sdk)).fetch("version") == Orbit::OmpEntry::PINNED_SDK_VERSION,
           "the active release keeps the pinned SDK")
  end

  # A failing bundle install aborts the update before the switch.
  def reviewer_install_failure_keeps_old_release
    install
    before = version
    old = active
    bump
    _out, err, status = Open3.capture3(@env.merge("ORBIT_FIXTURE_BUN_FAIL" => "1"),
                                       File.join(@bin, "orbit"), "update", chdir: "/")
    assert(!status.success? && err.include?("bun failed"), "a failing bun install aborts the update (#{err})")
    assert(version == before && active == old, "the previous release stays active after a failed reviewer install")
  end

  def uninstall_preserves_user_files
    prepare_external_skills
    install("--modify-path")
    shell_before = File.read(File.join(@shell_config, ".zshrc"))
    File.write(File.join(@runtime, "user-notes.txt"), "keep root")
    release = active
    File.write(File.join(release, "user-extra.txt"), "keep release")
    FileUtils.mkdir_p(File.join(release, "user-empty-folder"))
    project = File.join(@temp, "project/.orbit")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "task.json"), "keep task")
    File.write(File.join(@omp, "config.yml"), "user: keep\n")
    File.write(File.join(@opencode, "opencode.json"), '{"user":"keep"}')
    link_legacy_host_entries
    File.write(File.join(@omp, "extensions/keep.txt"), "not an Orbit entry")
    File.symlink("/nonexistent-orbit-foreign", File.join(@opencode, "plugins/foreign.js"))
    Orbit::ReleaseLease.hold!(root: release, pid: Process.pid)
    begin
      _out, err, status = Open3.capture3(@env, File.join(@bin, "orbit"), "uninstall", chdir: "/")
      assert(!status.success? && err.include?("仍有进程使用") && err.include?("安装记录未改动"),
             "uninstall explains why a live release prevents removal")
      assert(File.symlink?(File.join(@runtime, "current")) &&
             File.file?(File.join(@runtime, OrbitInstall::MARKER)) &&
             File.file?(File.join(@bin, "orbit")), "refused uninstall keeps the installation usable")
    ensure
      File.unlink(File.join(release, ".leases", "#{Process.pid}.json"))
    end
    run(File.join(@bin, "orbit"), "uninstall", env: { "ORBIT_RUNTIME_DIR" => File.join(@temp, "other-runtime") }, cwd: "/")
    assert_external_skills
    assert(!File.exist?(File.join(@bin, "orbit")), "owned CLI wrapper removed")
    assert(File.read(File.join(@shell_config, ".zshrc")) == shell_before, "uninstall retains shared PATH configuration")
    assert(!File.symlink?(File.join(@omp, "extensions/orbit.js")), "owned OMP extension removed")
    assert(File.read(File.join(@omp, "extensions/keep.txt")) == "not an Orbit entry", "unowned file in the agent directory kept")
    assert(File.read(File.join(@omp, "config.yml")) == "user: keep\n", "OMP config retained")
    assert(!File.symlink?(File.join(@opencode, "plugins/orbit.js")), "owned OpenCode plugin removed")
    assert(File.symlink?(File.join(@opencode, "plugins/foreign.js")), "unowned plugin link kept")
    assert(File.read(File.join(@opencode, "opencode.json")) == '{"user":"keep"}', "OpenCode user config retained")
    assert(!File.symlink?(File.join(@runtime, "current")), "active release link removed")
    assert(!File.exist?(File.join(release, "scripts/orbit")), "shipped code removed")
    assert(!File.exist?(File.join(release, "runners/omp-reviewer/node_modules")),
           "nested reviewer dependency directory removed")
    assert(!File.exist?(File.join(release, "runners/omp-reviewer/package.json")), "reviewer bundle files removed")
    assert(File.read(File.join(@runtime, "user-notes.txt")) == "keep root", "root user file kept")
    assert(File.read(File.join(release, "user-extra.txt")) == "keep release", "extra file in release kept")
    assert(File.directory?(File.join(release, "user-empty-folder")), "unowned empty folder kept")
    assert(File.read(File.join(project, "task.json")) == "keep task", "project task data kept")
  end

  # A failing owned-entry removal must abort the switch before it becomes
  # active: the old version stays usable, the already removed link is
  # restored, and the output makes no passivity claim.
  def failed_legacy_cleanup_keeps_old_version
    install
    old = active
    before = version
    link_legacy_host_entries
    directory = File.join(@omp, "extensions")
    File.chmod(0o555, directory)
    begin
      bump
      out, err, status = Open3.capture3(@env, File.join(@bin, "orbit"), "update", chdir: "/")
      assert(!status.success? && err.include?("Permission denied"),
             "a failing legacy cleanup aborts the update with the real error (#{err})")
      assert(!out.include?("Controlled OMP entry"), "a failed switch prints no success or passivity claim")
    ensure
      File.chmod(0o755, directory)
    end
    assert(version == before && active == old, "the previous version stays active and usable")
    assert(File.symlink?(File.join(directory, "orbit.js")), "the owned legacy entry remains for a retry")
    assert(File.symlink?(File.join(@opencode, "plugins/orbit.js")), "an entry removed before the failure is restored")
    assert(json(File.join(@runtime, OrbitInstall::MARKER)).fetch("format") == "orbit-install-3",
           "a failed switch keeps the old installation record")
  end

  # A same-named entry that this installation does not own is never deleted.
  # The install reports that plain-omp passivity is unconfirmed, and doctor
  # keeps the installation not ready until the user resolves it.
  def upgrade_keeps_unowned_orbit_entry_and_reports_uncertainty
    install
    marker = File.join(@runtime, OrbitInstall::MARKER)
    owner = json(marker)
    owner["omp_dir"] = @omp
    File.write(marker, JSON.pretty_generate(owner))
    FileUtils.mkdir_p(File.join(@omp, "extensions"))
    foreign = File.join(@omp, "extensions/orbit.js")
    File.write(foreign, "user's own extension\n")
    bump
    out = run(File.join(@bin, "orbit"), "update", cwd: "/")
    assert(version["version"] == @updated_version, "update succeeds with an unowned same-named entry")
    assert(File.file?(foreign) && File.read(foreign) == "user's own extension\n", "the unowned entry is never deleted")
    assert(!out.include?("plain omp loads no Orbit extension"), "no passivity claim while the unowned entry remains")
    report = JSON.parse(run(File.join(@bin, "orbit"), "doctor", "--json", cwd: "/", success: false))
    entry = report.fetch("installation").fetch("extensions").find { |item| item["path"] == foreign }
    assert(entry && entry["ready"] == false && entry["next_step"].to_s.include?(foreign),
           "doctor reports the unowned entry instead of claiming passivity")
    File.unlink(foreign)
    bump
    out = run(File.join(@bin, "orbit"), "update", cwd: "/")
    assert(out.include?("plain omp loads no Orbit extension"), "the claim returns once the conflict is resolved")
    assert(JSON.parse(run(File.join(@bin, "orbit"), "doctor", "--json", cwd: "/")).dig("installation", "ready"),
           "doctor is ready after the conflict is resolved")
  end

  # Independently managed content and links must survive the CLI lifecycle.
  def prepare_external_skills
    @external_skill = File.join(@temp, ".agents/skills/orbit")
    FileUtils.mkdir_p(@external_skill)
    File.write(File.join(@external_skill, "SKILL.md"), "managed by skills CLI")
    [@skills, File.join(@opencode, "skills"), File.join(@omp, "skills")].each do |directory|
      FileUtils.mkdir_p(directory)
      File.symlink(@external_skill, File.join(directory, "orbit"))
    end
  end

  def assert_external_skills
    assert(File.read(File.join(@external_skill, "SKILL.md")) == "managed by skills CLI", "external skill content preserved")
    [@skills, File.join(@opencode, "skills"), File.join(@omp, "skills")].each do |directory|
      assert(File.readlink(File.join(directory, "orbit")) == @external_skill, "external skill link preserved")
    end
  end

  def shell_configuration
    # Existing Bash dotfiles may be symlinks and have no trailing newline.
    target = File.join(@temp, "dotfile")
    File.write(target, "# user settings")
    File.chmod(0o640, target)
    rc = File.join(@temp, ".bashrc")
    File.symlink(target, rc)
    profile = File.join(@temp, ".bash_profile")
    File.write(profile, "# login settings")
    bin = File.join(@temp, "bin with spaces ' $() [x]")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "orbit"), "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(bin, "orbit"))
    options = { bin: bin, modify_path: true }
    2.times { OrbitInstall.configure_shell_path(options, home: @temp, shell: "/bin/bash") }
    assert(File.symlink?(rc) && (File.stat(target).mode & 0o777) == 0o640, "dotfile symlink and permissions preserved")
    assert(File.read(target).start_with?("# user settings\n") && File.read(target).scan("# Orbit CLI path").length == 1, "existing content preserved and no duplicate configuration")
    assert(!File.exist?(File.join(@temp, ".profile")), "do not create a profile that hides the existing login profile")
    [rc, profile].each do |path|
      command = 'source "$1"; source "$1"; command -v orbit; printf "%s\n" "$PATH"'
      out = run("bash", "--noprofile", "--norc", "-c", command, "bash", path)
      lines = out.lines.map(&:strip)
      assert(lines.first == File.join(bin, "orbit") && lines.last.split(":").count(bin) == 1, "Bash loads custom path literally without duplicate entries")
    end
  end

  def main
    missing_prerequisites
    puts "INSTALL_TEST_PASS missing_prerequisites"
    %i[first_install successful_update old_wrapper_update update_keeps_referenced_release failed_update
       reviewer_sdk_version_mismatch_keeps_old_release reviewer_install_failure_keeps_old_release
       failed_legacy_cleanup_keeps_old_version upgrade_keeps_unowned_orbit_entry_and_reports_uncertainty
       uninstall_preserves_user_files shell_configuration].each do |test|
      fixture { send(test) }
      puts "INSTALL_TEST_PASS #{test}"
    end
  end
end

InstallTest.main
