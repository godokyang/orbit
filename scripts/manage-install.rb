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

module OrbitInstall
  FORMAT = "orbit-install-3"
  MARKER = ".orbit-install.json"
  RELEASE = ".orbit-release.json"
  module_function

  def capture(*command, **options)
    out, err, status = Open3.capture3(*command, **options)
    raise "#{command.first} failed: #{err.strip}" unless status.success?
    out
  end

  def run(*command, **options)
    raise "#{command.first} failed" unless system(*command, **options)
  end

  def present?(path)
    File.exist?(path) || File.symlink?(path)
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
    <<~SH
      #!/usr/bin/env sh
      # Managed by Orbit installer.
      ORBIT_ROOT=#{runtime.shellescape}
      ORBIT_RELEASE=$(CDPATH= cd -- "$ORBIT_ROOT/current" && pwd -P) || exit 1
      exec "$ORBIT_RELEASE/scripts/orbit" "$@"
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
      p.on("--opencode-dir DIR") { |v| options[:opencode] = v }
      p.on("--no-opencode") { options[:no_opencode] = true }
      p.on("--omp-dir DIR") { |v| options[:omp] = v }
      p.on("--no-omp") { options[:no_omp] = true }
      p.on("--ref REF") { |_v| } # Source selection belongs to install.sh.
      p.on("--source DIR") { |v| options[:source] = File.realpath(v) }
      p.on("--source-commit SHA") { |v| options[:commit] = v }
      p.on("--source-ref REF") { |v| options[:ref] = v }
      p.on("-h", "--help") { puts p; exit }
    end
    parser.parse!(argv)
    raise "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    raise "choose --opencode-dir or --no-opencode" if options[:opencode] && options[:no_opencode]
    raise "choose --omp-dir or --no-omp" if options[:omp] && options[:no_omp]
    options[:runtime] ||= ENV["ORBIT_RUNTIME_DIR"] || File.join(ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local/share")), "orbit/orbit")
    runtime = File.expand_path(options.fetch(:runtime))
    raise "runtime directory must not be a symlink" if File.symlink?(runtime)
    marker = File.join(runtime, MARKER)
    owner = File.file?(marker) ? read_json(marker) : nil
    if owner
      raise "unknown installation format; choose an empty directory" unless owner["format"] == FORMAT
    elsif present?(runtime) && (!File.directory?(runtime) || !Dir.empty?(runtime))
      raise "runtime is not an owned installation; choose an empty directory (old installs are not migrated)"
    end
    options[:bin] ||= ENV["ORBIT_INSTALL_DIR"] || owner&.fetch("bin_dir") || File.join(Dir.home, ".local/bin")
    bin = File.expand_path(options.fetch(:bin))
    opencode = if options[:no_opencode]
                 nil
               elsif options[:opencode]
                 File.expand_path(options[:opencode])
               elsif owner&.key?("opencode_dir")
                 owner["opencode_dir"]
               elsif action == "install"
                 File.expand_path(ENV["OPENCODE_CONFIG_DIR"] || File.join(ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config")), "opencode"))
               end
    if owner&.key?("opencode_dir") && opencode != owner["opencode_dir"]
      raise "OpenCode installation path differs; reuse its recorded path or uninstall first"
    end
    omp = if options[:no_omp]
            nil
          elsif options[:omp]
            File.expand_path(options[:omp])
          elsif owner&.key?("omp_dir")
            owner["omp_dir"]
          elsif action == "install"
            profile = ENV["OMP_PROFILE"]
            default = profile && !profile.empty? ? File.join(Dir.home, ".omp/profiles", profile, "agent") : File.join(Dir.home, ".omp/agent")
            File.expand_path(ENV["PI_CODING_AGENT_DIR"] || default)
          end
    if owner&.key?("omp_dir") && omp != owner["omp_dir"]
      raise "OMP installation path differs; reuse its recorded path or uninstall first"
    end
    if owner && bin != owner["bin_dir"]
      raise "installation paths differ; reuse its recorded paths or uninstall before changing them"
    end
    raise "installation entry directories must be outside runtime" if [bin, opencode, omp].compact.any? { |path| path == runtime || path.start_with?(runtime + "/") }
    [action, options.merge(runtime: runtime, bin: bin, opencode: opencode, omp: omp, owner: owner)]
  end

  def endpoints(options)
    runtime = options.fetch(:runtime)
    entries = [[File.join(options.fetch(:bin), "orbit"), wrapper(runtime), :file]]
    if options[:opencode]
      entries << [File.join(options[:opencode], "plugins/orbit.js"), File.join(runtime, "current/plugins/opencode.mjs"), :symlink]
    end
    if options[:omp]
      entries << [File.join(options[:omp], "extensions/orbit.js"), File.join(runtime, "current/plugins/omp.mjs"), :symlink]
    end
    entries
  end

  def matching?(path, expected, kind)
    if kind == :symlink
      File.symlink?(path) && File.readlink(path) == expected
    else
      File.file?(path) && !File.symlink?(path) && File.read(path) == expected
    end
  end

  def check_endpoints!(options)
    endpoints(options).each do |path, expected, kind|
      next unless present?(path)
      raise "refusing to overwrite unowned #{path}" unless options[:owner] && matching?(path, expected, kind)
    end
  end

  def prerequisites!
    raise "Ruby >= 3.2 is required" if (RUBY_VERSION.split('.').map(&:to_i) <=> [3, 2]) < 0
    raise "Node >= 18 is required" if capture("node", "-p", "process.versions.node").split('.').first.to_i < 18
    %w[npm codex].each do |name|
      raise "#{name} is required on PATH" unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |p| File.executable?(File.join(p, name)) && !File.directory?(File.join(p, name)) }
    end
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
    run("node", "-e", "require('ws')", chdir: stage)
    raise "skill payload missing" unless File.file?(File.join(stage, "skills/orbit/SKILL.md"))
    run("node", "--check", "plugins/opencode.mjs", chdir: stage)
    run("node", "--input-type=module", "-e", "import('./plugins/opencode.mjs')", chdir: stage)
    run("node", "--check", "plugins/omp.mjs", chdir: stage)
    run("node", "--input-type=module", "-e", "import('./plugins/omp-host.mjs')", chdir: stage)
    record = { "format" => FORMAT, "version" => package.fetch("version"), "source" => source_record,
               "content_digest" => digest.hexdigest, "installed_at" => Time.now.utc.iso8601,
               "files" => paths, "owned_directories" => %w[node_modules .npm-cache] }
    atomic_write(File.join(stage, RELEASE), JSON.pretty_generate(record) + "\n")
    record
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
    raise "unknown release format" unless record["format"] == FORMAT
    paths = record.fetch("files").map { |path| safe_relative!(path) }
    directories = record.fetch("owned_directories")
    raise "unknown dependency directories" unless directories == %w[node_modules .npm-cache]
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

  def install(options)
    prerequisites!
    check_endpoints!(options)
    runtime = options.fetch(:runtime)
    previous = current_release(runtime)
    FileUtils.mkdir_p(File.join(runtime, "releases"))
    stage = Dir.mktmpdir(".prepare-", runtime)
    created = []
    marker = File.join(runtime, MARKER)
    old_marker = File.binread(marker) if File.file?(marker)
    switched = false
    begin
      record = prepare(options, stage)
      check_endpoints!(options)
      raise "installation changed during preparation; retry after the other installer finishes" unless current_release(runtime) == previous
      release = File.join(runtime, "releases", SecureRandom.hex(12))
      File.rename(stage, release)
      endpoints(options).each do |path, expected, kind|
        next if present?(path) # Ownership was checked before preparation.
        FileUtils.mkdir_p(File.dirname(path))
        kind == :symlink ? File.symlink(expected, path) : atomic_write(path, expected, mode: 0o755)
        created << path
      end
      owner = { "format" => FORMAT, "runtime_dir" => runtime, "bin_dir" => options.fetch(:bin), "opencode_dir" => options[:opencode], "omp_dir" => options[:omp] }
      atomic_write(marker, JSON.pretty_generate(owner) + "\n")
      link = File.join(runtime, ".current-#{SecureRandom.hex(6)}")
      File.symlink("releases/#{File.basename(release)}", link)
      File.rename(link, File.join(runtime, "current"))
      switched = true
      puts "Installed orbit #{record['version']} (#{record.dig('source', 'commit') || 'local source'})"
      puts "CLI: #{File.join(options.fetch(:bin), 'orbit')}"
      puts "Install skill separately: npx skills install godokyang/orbit --skill orbit --global"
      puts "OpenCode: #{options[:opencode] || 'not linked (--no-opencode)'}"
      puts "OMP: #{options[:omp] || 'not linked (--no-omp)'}"
      puts "Start OpenCode or OMP normally; running sessions load their extension on the next launch."
      puts "Details: orbit version --json"
      puts "Update: orbit update (skill: npx skills update orbit --global)."
      puts "Uninstall: orbit uninstall"
    ensure
      unless switched
        created.reverse_each { |path| File.unlink(path) if present?(path) }
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
      clean_release(previous) if previous
    rescue StandardError => error
      warn "New version is active; old release cleanup needs attention: #{error.message}"
    end
  end

  def uninstall(options)
    raise "no owned installation at #{options[:runtime]}" unless options[:owner]
    runtime = options.fetch(:runtime)
    release = current_release(runtime)
    endpoints(options).each do |path, expected, kind|
      if matching?(path, expected, kind)
        File.unlink(path)
      elsif present?(path)
        warn "Kept unowned entry: #{path}"
      end
    end
    File.unlink(File.join(runtime, "current")) if release
    clean_release(release) if release
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
