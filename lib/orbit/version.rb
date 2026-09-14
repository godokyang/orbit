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
end
