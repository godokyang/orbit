# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "digest"

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

  def fixture
    Dir.mktmpdir("orbit-install-test-") do |tmp|
      @temp = tmp
      @source = File.join(tmp, "source")
      @runtime = File.join(tmp, "runtime with spaces")
      @bin = File.join(tmp, "bin with spaces")
      @skills = File.join(tmp, "skills")
      @opencode = File.join(tmp, "opencode config")
      @omp = File.join(tmp, "omp agent")
      @env = { "ORBIT_REF" => nil, "ORBIT_RUNTIME_DIR" => nil, "ORBIT_INSTALL_DIR" => nil, "ORBIT_SKILL_DIR" => @skills, "OPENCODE_CONFIG_DIR" => @opencode, "PI_CODING_AGENT_DIR" => @omp }
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
    run("sh", File.join(@source, "install.sh"), "--runtime-dir", @runtime, *paths, *args, env: env, success: success)
  end

  def version
    JSON.parse(run(File.join(@bin, "orbit"), "version", "--json", cwd: "/"))
  end

  def active
    File.realpath(File.join(@runtime, "current"))
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
    install("--ref", "branch/stable", env: { "PATH" => transport + File::PATH_SEPARATOR + ENV.fetch("PATH"), "ORBIT_FIXTURE_CURL_LOG" => log, "ORBIT_FIXTURE_ARCHIVE" => archive })
    info = version
    assert(info.fetch("version") == json(File.join(ROOT, "package.json")).fetch("version"), "installed CLI version")
    assert(info.dig("source", "commit") == "a" * 40 && info.dig("source", "ref") == "branch/stable", "record pinned commit and requested ref")
    assert(File.readlines(log).length == 2, "resolve source once, fetch one fixed archive")
    assert([@skills, File.join(@opencode, "skills"), File.join(@omp, "skills")].none? { |p| File.exist?(p) }, "CLI installation creates no skill directories")
    assert(run(File.join(@bin, "orbit"), "--version").strip == "orbit #{info['version']}", "short version command")
    assert(!File.exist?(File.join(active, "lib/orbit/v2")), "no retired runtime in installation")
  end

  def successful_update
    prepare_external_skills
    install("--opencode-dir", @opencode)
    old = active
    obsolete = File.join(old, "obsolete-rule.md")
    File.write(obsolete, "old shipped rule")
    marker = File.join(old, ".orbit-release.json")
    record = json(marker)
    record["files"] << "obsolete-rule.md"
    File.write(marker, JSON.generate(record))
    File.write(File.join(@runtime, "user-notes.txt"), "keep")
    bump
    File.open(File.join(@source, "skills/orbit/SKILL.md"), "a") { |f| f.puts("\nUpdated fixture skill.") }
    install(explicit_paths: false)
    assert(version["version"] == @updated_version, "updated CLI version")
    assert(version.dig("source", "commit") == run("git", "rev-parse", "HEAD", cwd: @source).strip, "local source commit recorded")
    assert(version.dig("source", "dirty") == true, "local edits not mislabeled as clean commit")
    assert(!File.exist?(old) && !File.exist?(obsolete), "retired release and obsolete shipped files removed")
    assert_external_skills
    assert(File.realpath(File.join(@opencode, "plugins/orbit.js")) == File.join(active, "plugins/opencode.mjs"), "OpenCode plugin follows update")
    assert(File.realpath(File.join(@omp, "extensions/orbit.js")) == File.join(active, "plugins/omp.mjs"), "OMP extension follows update")
    assert(File.read(File.join(@runtime, "user-notes.txt")) == "keep", "update preserves user files")
  end

  def failed_update
    prepare_external_skills
    install
    before = version
    old = active
    assert(File.realpath(File.join(@omp, "extensions/orbit.js")) == File.join(active, "plugins/omp.mjs"), "OMP installed in native agent directory")
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
    install(env: { "PATH" => runner + File::PATH_SEPARATOR + ENV.fetch("PATH") }, success: false)
    assert(version == before && active == old, "failed dependency update retains working old installation")
    assert_external_skills
    assert(File.realpath(File.join(@opencode, "plugins/orbit.js")) == File.join(old, "plugins/opencode.mjs"), "failed update retains OpenCode plugin")
    assert(Dir.glob(File.join(@runtime, ".prepare-*"), File::FNM_DOTMATCH).empty?, "failed preparation cleaned")
  end

  def uninstall_preserves_user_files
    prepare_external_skills
    install
    File.write(File.join(@runtime, "user-notes.txt"), "keep root")
    release = active
    File.write(File.join(release, "user-extra.txt"), "keep release")
    FileUtils.mkdir_p(File.join(release, "user-empty-folder"))
    project = File.join(@temp, "project/.orbit")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "task.json"), "keep task")
    File.write(File.join(@omp, "config.yml"), "user: keep\n")
    File.write(File.join(@opencode, "opencode.json"), '{"user":"keep"}')
    run("sh", File.join(@runtime, "current/uninstall.sh"), "--runtime-dir", @runtime)
    assert_external_skills
    assert(!File.exist?(File.join(@bin, "orbit")), "owned CLI wrapper removed")
    assert(!File.symlink?(File.join(@omp, "extensions/orbit.js")), "owned OMP extension removed")
    assert(File.read(File.join(@omp, "config.yml")) == "user: keep\n", "OMP config retained")
    assert(!File.symlink?(File.join(@opencode, "plugins/orbit.js")), "owned OpenCode plugin removed")
    assert(File.read(File.join(@opencode, "opencode.json")) == '{"user":"keep"}', "OpenCode user config retained")
    assert(!File.symlink?(File.join(@runtime, "current")), "active release link removed")
    assert(!File.exist?(File.join(release, "scripts/orbit")), "shipped code removed")
    assert(File.read(File.join(@runtime, "user-notes.txt")) == "keep root", "root user file kept")
    assert(File.read(File.join(release, "user-extra.txt")) == "keep release", "extra file in release kept")
    assert(File.directory?(File.join(release, "user-empty-folder")), "unowned empty folder kept")
    assert(File.read(File.join(project, "task.json")) == "keep task", "project task data kept")
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

  def main
    %i[first_install successful_update failed_update uninstall_preserves_user_files].each do |test|
      fixture { send(test) }
      puts "INSTALL_TEST_PASS #{test}"
    end
  end
end

InstallTest.main
