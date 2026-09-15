# frozen_string_literal: true

require "json"

module Orbit
  ROOT = File.expand_path("../..", __dir__)
  VERSION = JSON.parse(File.read(File.join(ROOT, "package.json"))).fetch("version").freeze

  def self.version_info
    record = File.join(ROOT, ".orbit-release.json")
    info = File.file?(record) ? JSON.parse(File.read(record)) : { "source" => { "kind" => "checkout" } }
    info.slice("source", "content_digest", "installed_at").merge("version" => VERSION)
  end

  def self.installed_runtime
    root = File.realpath(ROOT)
    raise ArgumentError, "请从当前已安装的 Orbit CLI 执行此命令。" unless File.file?(File.join(root, ".orbit-release.json"))
    runtime = File.dirname(File.dirname(root))
    owner = JSON.parse(File.read(File.join(runtime, ".orbit-install.json")))
    # Keep the installer spelling (e.g. /var vs /private/var on macOS), while
    # verifying that it still points to this physical release.
    runtime = owner.fetch("runtime_dir", runtime)
    unless File.realpath(File.join(runtime, "current")) == root
      raise ArgumentError, "当前 CLI 不属于这套安装的活动版本。"
    end
    runtime
  end
end
