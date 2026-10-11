#!/usr/bin/env sh
set -eu
command -v ruby >/dev/null 2>&1 || { echo 'orbit install: Ruby >= 3.2 is required' >&2; exit 1; }
source_dir=""
if [ -f "$0" ]; then
  source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fi
ruby --disable-gems - "$source_dir" "$@" <<'RUBY'
require "json"
require "tmpdir"
require "fileutils"
require "uri"
require "rbconfig"
require "open3"
abort "orbit install: Ruby >= 3.2 is required" if (RUBY_VERSION.split('.').map(&:to_i) <=> [3, 2]) < 0
local = ARGV.shift
if ARGV.include?("--help") || ARGV.include?("-h")
  puts "Install/update Orbit CLI: sh install.sh [--bin-dir DIR] [--runtime-dir DIR] [--no-modify-path] [--ref REF]"
  puts "Local checkout by default; --ref (or ORBIT_REF) downloads one pinned GitHub commit. Remote default: main."
  puts "Single-host install: the CLI plus the explicit orbit omp entry; plain omp loads no Orbit extension."
  puts "Owned global Orbit entries from an orbit-install-3 installation are cleaned up on switch."
  puts "Saves PATH for zsh/bash after installation. --no-modify-path disables this; --modify-path enables it again."
  exit
end
# This bootstrap also runs without a checkout. Check the local host before
# fetching source; the release manager repeats the gate before preparation.
omp_paths = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir.empty? ? "." : dir, "omp") }
omp = omp_paths.find { |path| File.executable?(path) && !File.directory?(path) }
unless omp
  if omp_paths.any? { |path| File.exist?(path) || File.symlink?(path) }
    abort "orbit install: 找到了 OMP，但无法执行。请检查执行权限和 PATH，再重新运行 Orbit 安装命令；旧安装保持不变。"
  end
  abort "orbit install: 未找到 OMP（Oh My Pi）。Orbit 需要复用本地 OMP，请先安装并加入 PATH，再重新运行 Orbit 安装命令；旧安装保持不变。"
end
begin
  version_output = nil
  Open3.popen3(omp, "--version", pgroup: true) do |input, output, error, child|
    input.close
    readers = [Thread.new { output.read }, Thread.new { error.read }]
    unless child.join(10)
      Process.kill("KILL", -child.pid) rescue nil
      child.join
      abort "orbit install: OMP 无法执行（版本检查超时）。请修复本地 OMP 后重新运行 Orbit 安装命令；旧安装保持不变。"
    end
    values = readers.map(&:value)
    abort "orbit install: OMP 无法执行（版本检查退出 #{child.value.exitstatus}）。请修复本地 OMP 后重新运行 Orbit 安装命令；旧安装保持不变。" unless child.value.success?
    version_output = values.first
  end
  version = version_output[/\d+\.\d+\.\d+/]
  unless version && (version.split('.').map(&:to_i) <=> [18, 2, 8]) >= 0
    abort "orbit install: OMP 版本不支持（#{version || '无法解析'}），需要至少 18.2.8 且支持可信检查器扩展。请自行安装兼容 OMP 后重试；旧安装保持不变。"
  end
rescue SystemCallError => error
  abort "orbit install: OMP 无法执行（#{error.message}）。请修复本地 OMP 后重新运行 Orbit 安装命令；旧安装保持不变。"
end
ref_index = ARGV.index("--ref")
ref = ref_index ? ARGV[ref_index + 1] : ENV.fetch("ORBIT_REF", "main")
abort "orbit install: --ref needs a value" if ref.nil? || ref.empty? || ref.start_with?("--")
entry = File.join(local, "scripts", "manage-install.rb")
if File.file?(entry) && !ref_index && !ENV.key?("ORBIT_REF")
  exec RbConfig.ruby, "--disable-gems", entry, "install", "--source", local, *ARGV
end
begin
  Dir.mktmpdir("orbit-source-") do |tmp|
    abort "orbit install: curl is required to download the release; install curl and retry" unless system("command -v curl >/dev/null 2>&1")
    abort "orbit install: tar is required to unpack the release; install tar and retry" unless system("command -v tar >/dev/null 2>&1")
    fetch = lambda do |url, destination|
      raise "download failed: #{url}" unless system("curl", "-fsSL", "--retry", "2", "-o", destination, "--", url)
    end
    sha = ref
    unless sha.match?(/\A[0-9a-fA-F]{40}\z/)
      metadata = File.join(tmp, "commit.json")
      fetch.call("https://api.github.com/repos/godokyang/orbit/commits/#{URI.encode_www_form_component(ref)}", metadata)
      sha = JSON.parse(File.read(metadata)).fetch("sha")
    end
    raise "invalid source commit" unless sha.match?(/\A[0-9a-fA-F]{40}\z/)
    archive = File.join(tmp, "source.tar.gz")
    fetch.call("https://codeload.github.com/godokyang/orbit/tar.gz/#{sha}", archive)
    source = File.join(tmp, "source")
    FileUtils.mkdir_p(source)
    raise "cannot extract source" unless system("tar", "-xzf", archive, "--strip-components=1", "-C", source)
    entry = File.join(source, "scripts", "manage-install.rb")
    raise "selected ref does not contain the current installer" unless File.file?(entry)
    ok = system(RbConfig.ruby, "--disable-gems", entry, "install", "--source", source,
                "--source-commit", sha.downcase, "--source-ref", ref, *ARGV)
    exit(ok ? 0 : 1)
  end
rescue StandardError => error
  abort "orbit install: #{error.message}"
end
RUBY
