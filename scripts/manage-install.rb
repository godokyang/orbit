# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "securerandom"
require "digest"
require "open3"
require "optparse"
require "rbconfig"
require "shellwords"
require "time"
require_relative "../lib/orbit/release_lease"
require_relative "../lib/orbit/omp_entry"

module OrbitInstall
  # Format 4 is the single-host layout: the CLI wrapper is the only installed
  # entry, and `orbit omp` loads the release extension explicitly. Format 3
  # markers and releases stay readable so an existing installation can switch
  # safely and have its old global host entries cleaned up.
  FORMAT = "orbit-install-4"
  LEGACY_FORMATS = ["orbit-install-3"].freeze
  SUPPORTED_FORMATS = [FORMAT, *LEGACY_FORMATS].freeze
  # Directories this installer creates and later removes with the release. The
  # reviewer bundle keeps its own SDK installation nested under its directory.
  OWNED_DIRECTORIES = %w[node_modules .npm-cache .bun-cache runners/omp-reviewer/node_modules].freeze
  # Releases prepared before the reviewer bundle shipped.
  LEGACY_OWNED_DIRECTORIES = %w[node_modules .npm-cache].freeze
  MARKER = ".orbit-install.json"
  RELEASE = ".orbit-release.json"
  module_function

  def capture(*command, **options)
    env = options.delete(:env)
    args = env ? [env, *command] : command
    out, err, status = Open3.capture3(*args, **options)
    raise "#{command.first} failed: #{err.strip}" unless status.success?
    out
  end

  def run(*command, **options)
    env = options.delete(:env)
    args = env ? [env, *command] : command
    raise "#{command.first} failed" unless system(*args, **options)
  end

  def present?(path)
    File.exist?(path) || File.symlink?(path)
  end

  def executable(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }
       .find { |path| File.executable?(path) && !File.directory?(path) }
  end

  def read_json(path)
    JSON.parse(File.read(path))
  end

  def atomic_write(path, bytes, mode: 0o600)
    temporary = "#{path}.#{SecureRandom.hex(6)}.tmp"
    File.write(temporary, bytes, mode: "wx", perm: mode)
    File.rename(temporary, path)
  ensure
    File.unlink(temporary) if temporary && File.exist?(temporary)
  end

  def safe_relative!(path)
    raise "invalid installed path: #{path.inspect}" unless path.is_a?(String) && !path.empty? &&
      !path.start_with?("/") && !path.split("/").any? { |part| ["..", ".", ""].include?(part) }
    path
  end

  def wrapper(runtime)
    ruby = RbConfig.ruby.shellescape
    <<~SH
      #!/usr/bin/env sh
      # Managed by Orbit installer.
      ORBIT_ROOT=#{runtime.shellescape}
      ORBIT_RELEASE=$(CDPATH= cd -- "$ORBIT_ROOT/current" && pwd -P) || exit 1
      # Pin the Ruby that passed the install-time version check: shells that
      # resolve `ruby` to an older interpreter must not break the CLI, and
      # extension-spawned children (plugin CLI, member registration) inherit
      # the same interpreter through the environment.
      ORBIT_RUBY=#{ruby}
      export ORBIT_RUBY
      exec "$ORBIT_RUBY" --disable-gems "$ORBIT_RELEASE/scripts/orbit" "$@"
    SH
  end

  def configure(argv)
    action = argv.shift
    raise "expected install or uninstall" unless %w[install uninstall].include?(action)
    options = {}
    parser = OptionParser.new do |p|
      p.banner = "Orbit #{action}: [--runtime-dir DIR] [--bin-dir DIR]"
      p.on("--runtime-dir DIR") { |v| options[:runtime] = v }
      p.on("--bin-dir DIR") { |v| options[:bin] = v }
      p.on("--[no-]modify-path") { |v| options[:modify_path] = v }
      p.on("--ref REF") { |_v| } # Source selection belongs to install.sh.
      p.on("--source DIR") { |v| options[:source] = File.realpath(v) }
      p.on("--source-commit SHA") { |v| options[:commit] = v }
      p.on("--source-ref REF") { |v| options[:ref] = v }
      p.on("-h", "--help") { puts p; exit }
    end
    parser.parse!(argv)
    raise "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options[:runtime] ||= ENV["ORBIT_RUNTIME_DIR"] || File.join(ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local/share")), "orbit/orbit")
    runtime = File.expand_path(options.fetch(:runtime))
    raise "runtime directory must not be a symlink" if File.symlink?(runtime)
    marker = File.join(runtime, MARKER)
    owner = File.file?(marker) ? read_json(marker) : nil
    if owner
      raise "unknown installation format; choose an empty directory" unless SUPPORTED_FORMATS.include?(owner["format"])
    elsif present?(runtime) && (!File.directory?(runtime) || !Dir.empty?(runtime))
      raise "runtime is not an owned installation; choose an empty directory (old installs are not migrated)"
    end
    options[:bin] ||= ENV["ORBIT_INSTALL_DIR"] || owner&.fetch("bin_dir") || File.join(Dir.home, ".local/bin")
    options[:modify_path] = options.fetch(:modify_path) { owner ? owner.fetch("modify_path", true) : true }
    bin = File.expand_path(options.fetch(:bin))
    if owner && bin != owner["bin_dir"]
      raise "installation paths differ; reuse its recorded paths or uninstall before changing them"
    end
    raise "installation entry directory must be outside runtime" if bin == runtime || bin.start_with?(runtime + "/")
    # Format 3 installations linked host entries next to their agent
    # directories. They are cleanup targets now: the single-host layout
    # creates no global extension, and cleanup removes only owned links.
    legacy = {
      "opencode_dir" => owner && owner["opencode_dir"],
      "omp_dir" => owner && owner["omp_dir"]
    }.compact
    [action, options.merge(runtime: runtime, bin: bin, owner: owner, legacy: legacy)]
  end

  # The wrapper template generated before the pinned-Ruby upgrade. An update
  # may only replace an on-disk wrapper whose bytes match this template for
  # the same runtime directory; anything else stays "unowned" and is refused.
  def legacy_wrapper(runtime)
    <<~SH
      #!/usr/bin/env sh
      # Managed by Orbit installer.
      ORBIT_ROOT=#{runtime.shellescape}
      ORBIT_RELEASE=$(CDPATH= cd -- "$ORBIT_ROOT/current" && pwd -P) || exit 1
      exec "$ORBIT_RELEASE/scripts/orbit" "$@"
    SH
  end

  def owned_wrapper?(path, expected, runtime)
    matching?(path, expected, :file) ||
      (File.file?(path) && !File.symlink?(path) && File.binread(path) == legacy_wrapper(runtime))
  end

  # The single-host installation owns exactly one entry: the CLI wrapper.
  # `orbit omp` reaches the extension inside the release without a global link.
  def endpoints(options)
    [[File.join(options.fetch(:bin), "orbit"), wrapper(options.fetch(:runtime)), :file]]
  end

  # Owned entries created by an orbit-install-3 installation. Only a link that
  # still points back into this installation's current release is removed;
  # anything else at those paths is kept and reported.
  def legacy_endpoints(options)
    runtime = options.fetch(:runtime)
    entries = []
    if (directory = options.dig(:legacy, "opencode_dir"))
      entries << [File.join(directory, "plugins/orbit.js"), File.join(runtime, "current/plugins/opencode.mjs"), :symlink]
    end
    if (directory = options.dig(:legacy, "omp_dir"))
      entries << [File.join(directory, "extensions/orbit.js"), File.join(runtime, "current/plugins/omp.mjs"), :symlink]
    end
    entries
  end

  # Removes owned format-3 host entries and returns what was removed plus any
  # same-named entries that are not owned by this installation. Unlink errors
  # and a surviving owned link are hard failures so the caller can abort and
  # roll back instead of claiming passivity. An unowned entry is never
  # deleted; it is surfaced as a conflict so no caller claims plain `omp` is
  # free of Orbit while it is still there.
  # Records each successful removal in the caller's array as it happens, so a
  # later failure still knows what to restore during rollback.
  def cleanup_legacy_endpoints(options, removed: [])
    conflicts = []
    legacy_endpoints(options).each do |path, expected, kind|
      if matching?(path, expected, kind)
        File.unlink(path)
        raise "legacy entry still present after removal: #{path}" if present?(path)
        puts "Removed legacy entry: #{path}"
        removed << [path, expected]
      elsif present?(path)
        warn "Kept unowned entry: #{path}"
        conflicts << path
      end
    end
    { "removed" => removed, "conflicts" => conflicts }
  end

  # A failed switch must leave the previous installation as usable as it was,
  # including the owned OMP host entry that was already removed for the new
  # layout. Best effort, reported instead of hidden.
  def restore_legacy_entries(removed)
    removed.reverse_each do |path, expected|
      next if present?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.symlink(expected, path)
    rescue SystemCallError => error
      warn "Legacy entry was not restored: #{path} (#{error.message})"
    end
  end

  def matching?(path, expected, kind)
    if kind == :symlink
      File.symlink?(path) && File.readlink(path) == expected
    else
      File.file?(path) && !File.symlink?(path) && File.read(path) == expected
    end
  end

  def check_endpoints!(options)
    runtime = options.fetch(:runtime)
    endpoints(options).each do |path, expected, kind|
      next unless present?(path)
      owned = kind == :file ? options[:owner] && owned_wrapper?(path, expected, runtime) : matching?(path, expected, kind)
      raise "refusing to overwrite unowned #{path}" unless owned
    end
  end

  def prerequisites!
    raise "Ruby >= 3.2 is required" if (RUBY_VERSION.split('.').map(&:to_i) <=> [3, 2]) < 0
    missing = []
    node = executable("node")
    if node
      begin
        version = capture(node, "-p", "process.versions.node").strip
        missing << "Node.js 18+：当前为 #{version}，请升级并加入 PATH" if version.split('.').first.to_i < 18
      rescue StandardError => error
        missing << "Node.js 18+：无法运行（#{error.message}），请检查安装和 PATH"
      end
    else
      missing << "Node.js 18+：未在 PATH 中找到，请先安装"
    end
    missing << "npm：未在 PATH 中找到，请安装 Node.js 附带的 npm" unless executable("npm")
    bun = executable("bun")
    if bun
      begin
        version = capture(bun, "--version").strip
        unless version_at_least?(version, "1.3.14")
          missing << "bun >= 1.3.14：当前为 #{version}，请升级并加入 PATH（独立检查组件安装需要）"
        end
      rescue StandardError => error
        missing << "bun >= 1.3.14：无法运行（#{error.message}），请检查安装和 PATH"
      end
    else
      missing << "bun >= 1.3.14：未在 PATH 中找到（独立检查组件安装需要）"
    end
    raise "缺少安装前置条件：\n- #{missing.join("\n- ")}\n安装后重新运行 Orbit 安装命令。" unless missing.empty?
  end

  def version_at_least?(version, minimum)
    (version.split(".").map(&:to_i) <=> minimum.split(".").map(&:to_i)) >= 0
  rescue StandardError
    false
  end

  def source_info(options)
    return { "kind" => "github", "commit" => options[:commit], "ref" => options[:ref], "dirty" => false } if options[:commit]
    root = options.fetch(:source)
    info = { "kind" => "local", "path" => root, "commit" => nil, "dirty" => nil }
    if File.exist?(File.join(root, ".git"))
      info["commit"] = capture("git", "-C", root, "rev-parse", "HEAD").strip
      info["dirty"] = !capture("git", "-C", root, "status", "--porcelain", "--untracked-files=normal").empty?
    end
    info
  end

  def prepare(options, stage)
    source = options.fetch(:source)
    paths = JSON.parse(capture("npm", "pack", "--dry-run", "--json", "--ignore-scripts", chdir: source)).fetch(0).fetch("files").map { |file| safe_relative!(file.fetch("path")) }.sort
    paths.each do |relative|
      destination = File.join(stage, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(source, relative), destination, preserve: true)
    end
    package = read_json(File.join(stage, "package.json"))
    source_record = source_info(options)
    digest = Digest::SHA256.new
    paths.each { |relative| digest << relative << "\0" << Digest::SHA256.file(File.join(stage, relative)).hexdigest << "\n" }
    run("npm", "ci", "--ignore-scripts", "--omit=dev", "--omit=optional", "--no-audit", "--no-fund", "--cache", File.join(stage, ".npm-cache"), chdir: stage)
    run(RbConfig.ruby, "--disable-gems", "scripts/check-version.rb", chdir: stage)
    actual = capture(File.join(stage, "scripts/orbit"), "--version", chdir: stage).strip
    raise "installed CLI version mismatch" unless actual == "orbit #{package.fetch('version')}"
    run("node", "--check", "plugins/omp.mjs", chdir: stage)
    run("node", "--input-type=module", "-e", "import('./plugins/omp-host.mjs')", chdir: stage)
    verify_member_registration_entry!(stage)
    install_reviewer_bundle!(stage)
    record = { "format" => FORMAT, "version" => package.fetch("version"), "source" => source_record,
               "content_digest" => digest.hexdigest, "installed_at" => Time.now.utc.iso8601,
               "files" => paths, "owned_directories" => OWNED_DIRECTORIES }
    atomic_write(File.join(stage, RELEASE), JSON.pretty_generate(record) + "\n")
    record
  end

  # The OMP extension spawns this entry synchronously before a native member
  # can start model work; a release without a runnable entry would fail-close
  # every member registration. Existence and the no-argument usage contract are
  # verified in the stage so the previous release keeps running on failure.
  def verify_member_registration_entry!(stage)
    register = File.join(stage, "scripts", "orbit-register-member")
    raise "member registration entry is missing: scripts/orbit-register-member" unless File.file?(register)

    out, err, _status = Open3.capture3(RbConfig.ruby, "--disable-gems", register)
    usage = begin
      JSON.parse(out)
    rescue JSON::ParserError
      nil
    end
    return if usage.is_a?(Hash) && usage["ok"] == false

    raise "member registration entry is not runnable: #{err.to_s.strip}"
  end

  # The independent reviewer runs on a pinned SDK. It installs into the staged
  # release, never into the CLI's own dependencies, and the installed version
  # is verified before the release can become active. Any failure here aborts
  # preparation, so the previous release stays active.
  def install_reviewer_bundle!(stage)
    runner = File.join(stage, "runners", "omp-reviewer")
    required = %w[package.json bun.lock reviewer.ts].map { |name| File.join(runner, name) }
    missing = required.reject { |path| File.file?(path) }
    raise "reviewer bundle is incomplete: #{missing.join(', ')}" unless missing.empty?

    run("bun", "install", "--frozen-lockfile", chdir: runner, env: { "BUN_INSTALL_CACHE_DIR" => File.join(stage, ".bun-cache") })
    package = File.join(runner, "node_modules", "@oh-my-pi", "pi-coding-agent", "package.json")
    raise "reviewer SDK was not installed: #{package}" unless File.file?(package)

    version = read_json(package)["version"]
    return if version == Orbit::OmpEntry::PINNED_SDK_VERSION

    raise "reviewer SDK version #{version.inspect} does not match the pinned #{Orbit::OmpEntry::PINNED_SDK_VERSION}"
  end

  def current_release(runtime)
    current = File.join(runtime, "current")
    return nil unless present?(current)
    raise "current entry is not an owned release link" unless File.symlink?(current)
    relative = File.readlink(current)
    raise "invalid release link" unless relative.match?(%r{\Areleases/[0-9a-f]+\z})
    release = File.join(runtime, relative)
    raise "release directory must not be a symlink" if File.symlink?(release)
    release
  end

  # Delete only recorded installation files. Extra user files remain where they are.
  def clean_release(release)
    record = read_json(File.join(release, RELEASE))
    raise "unknown release format" unless SUPPORTED_FORMATS.include?(record["format"])
    paths = record.fetch("files").map { |path| safe_relative!(path) }
    directories = record.fetch("owned_directories")
    unless [OWNED_DIRECTORIES, LEGACY_OWNED_DIRECTORIES].include?(directories)
      raise "unknown dependency directories"
    end
    FileUtils.rm_rf(File.join(release, Orbit::ReleaseLease::DIRECTORY))
    parents = []
    paths.each do |relative|
      path = File.join(release, relative)
      parent = File.dirname(path)
      until parent == release
        raise "installed parent directory is a symlink: #{parent}" if File.symlink?(parent)
        parents << parent
        parent = File.dirname(parent)
      end
      File.unlink(path) if File.file?(path) || File.symlink?(path)
    end
    directories.each { |name| FileUtils.rm_rf(File.join(release, name)) }
    File.unlink(File.join(release, RELEASE))
    parents.uniq.sort_by(&:length).reverse_each { |path| remove_empty_directory(path) }
    remove_empty_directory(release)
    warn "Kept user files in #{release}" if File.exist?(release)
  end

  def remove_empty_directory(path)
    Dir.rmdir(path) if File.directory?(path) && !File.symlink?(path) && Dir.empty?(path)
  end

  # Retired releases are removed only when no running task or loaded host
  # still holds a lease in them. A release kept now is retired again on the
  # next install or uninstall, so cleanup catches up after those holders exit.
  def cleanup_retired_releases(runtime, keep: nil)
    Dir.glob(File.join(runtime, "releases", "*")).sort.each do |release|
      next unless File.directory?(release) && !File.symlink?(release)
      next if keep && File.expand_path(release) == File.expand_path(keep)

      Orbit::ReleaseLease.prune_stale(release)
      if Orbit::ReleaseLease.live?(release)
        warn "Kept release in use: #{release}"
        next
      end
      clean_release(release)
    rescue StandardError => error
      warn "Kept release #{release}: #{error.message}"
    end
  end

  def configure_shell_path(options, home: Dir.home, shell: ENV["SHELL"], zdotdir: ENV["ZDOTDIR"])
    bin = options.fetch(:bin)
    unless options.fetch(:modify_path)
      puts "PATH: unchanged (--no-modify-path)."
      return
    end
    files = case File.basename(shell.to_s)
            when "zsh"
              [File.join(zdotdir.to_s.empty? ? home : File.expand_path(zdotdir), ".zshrc")]
            when "bash"
              profiles = %w[.bash_profile .bash_login .profile].map { |name| File.join(home, name) }
              [File.join(home, ".bashrc"), profiles.find { |path| File.file?(path) } || File.join(home, ".profile")]
            else
              warn "PATH: shell #{shell.inspect} is not configured automatically; add #{bin} to your shell's PATH."
              puts "Verify using the full command path: #{File.join(bin, 'orbit').shellescape} --version"
              return
            end
    command = "export PATH=#{bin.shellescape}:\"$PATH\""
    block = <<~SH
      # Orbit CLI path (shared command directory)
      case ":$PATH:" in
        *:#{bin.shellescape}:*) ;;
        *) #{command} ;;
      esac
    SH
    files.each do |path|
      content = File.exist?(path) ? File.read(path) : ""
      next if content.include?(block)
      FileUtils.mkdir_p(File.dirname(path))
      # Append through existing dotfile symlinks; preserve content and permissions.
      File.open(path, "a", 0o600) { |file| file.write("\n" + block) }
    end
    puts "PATH saved in: #{files.join(', ')}"
    puts "Open a new terminal, then run: orbit --version"
    puts "Or enable it in this terminal now: #{command}"
  rescue SystemCallError, IOError => error
    warn "Orbit is installed, but PATH configuration failed: #{error.message}"
    warn "Add #{bin} to your shell's PATH manually."
    puts "Verify using the full command path: #{File.join(bin, 'orbit').shellescape} --version"
  end

  def install(options)
    prerequisites!
    check_endpoints!(options)
    runtime = options.fetch(:runtime)
    previous = current_release(runtime)
    FileUtils.mkdir_p(File.join(runtime, "releases"))
    stage = Dir.mktmpdir(".prepare-", runtime)
    created = []
    replaced = []
    removed_legacy = []
    legacy_conflicts = []
    marker = File.join(runtime, MARKER)
    old_marker = File.binread(marker) if File.file?(marker)
    switched = false
    begin
      record = prepare(options, stage)
      check_endpoints!(options)
      raise "installation changed during preparation; retry after the other installer finishes" unless current_release(runtime) == previous
      # Removing the owned format-3 host entries is part of the switch and
      # must succeed before the new layout becomes active. The check and the
      # removal happen here so a failure aborts with the old version intact;
      # the removed links are restored by the rollback below.
      cleanup = cleanup_legacy_endpoints(options, removed: removed_legacy)
      legacy_conflicts = cleanup.fetch("conflicts")
      release = File.join(runtime, "releases", SecureRandom.hex(12))
      File.rename(stage, release)
      endpoints(options).each do |path, expected, kind|
        if present?(path)
          # Ownership was checked before preparation. A wrapper generated by an
          # older release of this installation is upgraded in place, with the
          # previous bytes restored if a later switch step fails.
          if kind == :file && File.file?(path) && !File.symlink?(path) &&
             File.binread(path) == legacy_wrapper(runtime) && File.binread(path) != expected
            previous_wrapper_bytes = File.binread(path)
            begin
              atomic_write(path, expected, mode: 0o755)
              replaced << [path, previous_wrapper_bytes]
            rescue SystemCallError
              atomic_write(path, previous_wrapper_bytes, mode: 0o755) rescue nil
              raise
            end
          end
          next
        end
        FileUtils.mkdir_p(File.dirname(path))
        kind == :symlink ? File.symlink(expected, path) : atomic_write(path, expected, mode: 0o755)
        created << path
      end
      owner = { "format" => FORMAT, "runtime_dir" => runtime, "bin_dir" => options.fetch(:bin), "modify_path" => options.fetch(:modify_path) }
      # Keep format 3 host directories as recorded cleanup targets; the links
      # themselves were removed above, and a later uninstall retries safely.
      owner.merge!(options.fetch(:legacy)) unless options.fetch(:legacy).empty?
      owner["legacy_conflicts"] = legacy_conflicts unless legacy_conflicts.empty?
      atomic_write(marker, JSON.pretty_generate(owner) + "\n")
      link = File.join(runtime, ".current-#{SecureRandom.hex(6)}")
      File.symlink("releases/#{File.basename(release)}", link)
      File.rename(link, File.join(runtime, "current"))
      switched = true
      puts "Installed orbit #{record['version']} (#{record.dig('source', 'commit') || 'local source'})"
      puts "CLI: #{File.join(options.fetch(:bin), 'orbit')}"
      if legacy_conflicts.empty?
        puts "Controlled OMP entry: orbit omp (plain omp loads no Orbit extension)."
      else
        puts "Controlled OMP entry: orbit omp."
        warn "普通 omp 是否仍加载 Orbit 未确认：保留了不是本安装创建的入口 #{legacy_conflicts.join('、')}；orbit doctor 会显示该状态。"
      end
      puts "Independent reviewer bundle: runners/omp-reviewer (SDK #{Orbit::OmpEntry::PINNED_SDK_VERSION})."
      if executable("omp")
        begin
          detected = Orbit::OmpEntry.detected_version
          if detected == Orbit::OmpEntry::PINNED_OMP_VERSION
            puts "OMP CLI: #{detected} (verified range)."
          else
            warn "OMP CLI #{detected} is outside the verified range (#{Orbit::OmpEntry::PINNED_OMP_VERSION}); orbit omp will refuse to start."
          end
        rescue StandardError => error
          warn "OMP CLI version could not be verified: #{error.message}"
        end
      else
        puts "OMP was not found on PATH; install Oh My Pi #{Orbit::OmpEntry::PINNED_OMP_VERSION} before using orbit omp."
      end
      puts "运行 orbit doctor 查看依赖和安装状态；模型登录及额度需在实际会话中验证。"
      puts "Details: orbit version --json"
      puts "Update: orbit update."
      puts "Uninstall: orbit uninstall"
    ensure
      unless switched
        restore_legacy_entries(removed_legacy)
        created.reverse_each { |path| File.unlink(path) if present?(path) }
        replaced.reverse_each do |path, content|
          atomic_write(path, content, mode: 0o755) if present?(path)
        rescue SystemCallError => error
          warn "Previously owned wrapper was not restored: #{path} (#{error.message})"
        end
        old_marker ? atomic_write(marker, old_marker) : (File.unlink(marker) if File.file?(marker))
        FileUtils.rm_rf(release) if release
      end
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_rf(stage) if stage
      unless switched
        remove_empty_directory(File.join(runtime, "releases"))
        remove_empty_directory(runtime)
      end
    end
    begin
      cleanup_retired_releases(runtime, keep: current_release(runtime))
    rescue StandardError => error
      warn "New version is active; old release cleanup needs attention: #{error.message}"
    end
    configure_shell_path(options)
  end

  def uninstall(options)
    raise "no owned installation at #{options[:runtime]}" unless options[:owner]
    runtime = options.fetch(:runtime)
    leased = Dir.glob(File.join(runtime, "releases", "*")).select do |path|
      next false unless File.directory?(path) && !File.symlink?(path)

      Orbit::ReleaseLease.prune_stale(path)
      Orbit::ReleaseLease.live?(path)
    end
    unless leased.empty?
      raise "仍有进程使用 Orbit 安装（#{leased.map { |path| File.basename(path) }.join('、')}）；" \
            "先结束相关任务和 Coding Agent 会话，再重试卸载。CLI 入口与安装记录未改动。"
    end
    release = current_release(runtime)
    # Remove legacy host entries before the CLI wrapper: a failure here leaves
    # the installation usable and the record intact for another attempt.
    cleanup_legacy_endpoints(options)
    runtime_dir = options.fetch(:runtime)
    endpoints(options).each do |path, expected, kind|
      if kind == :file ? owned_wrapper?(path, expected, runtime_dir) : matching?(path, expected, kind)
        File.unlink(path)
      elsif present?(path)
        warn "Kept unowned entry: #{path}"
      end
    end
    File.unlink(File.join(runtime, "current")) if release
    cleanup_retired_releases(runtime)
    File.unlink(File.join(runtime, MARKER))
    remove_empty_directory(File.join(runtime, "releases"))
    remove_empty_directory(runtime)
    puts "Uninstalled Orbit; any unowned files were retained. Project .orbit data was not touched."
  end

  def main(argv)
    action, options = configure(argv)
    action == "install" ? install(options) : uninstall(options)
  rescue StandardError => error
    warn "orbit install: #{error.message}"
    1
  else
    0
  end
end

exit OrbitInstall.main(ARGV) if $PROGRAM_NAME == __FILE__
