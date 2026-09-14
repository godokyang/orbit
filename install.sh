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
abort "orbit install: Ruby >= 3.2 is required" if (RUBY_VERSION.split('.').map(&:to_i) <=> [3, 2]) < 0
local = ARGV.shift
if ARGV.include?("--help") || ARGV.include?("-h")
  puts "Install/update Orbit: sh install.sh [--bin-dir DIR] [--runtime-dir DIR] [--skill-dir DIR | --no-skill] [--opencode-dir DIR | --no-opencode] [--omp-dir DIR | --no-omp] [--ref REF]"
  puts "Local checkout by default; --ref (or ORBIT_REF) downloads one pinned GitHub commit. Remote default: main."
  puts "skill-dir is the parent directory containing the orbit skill. Updates reuse recorded paths."
  exit
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
