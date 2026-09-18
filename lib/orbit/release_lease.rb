# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Orbit
  # A running task or loaded host keeps resolving files from the release it
  # started in. Each holder writes a pid lease inside its own release; the
  # installer deletes a retired release only when no leased pid is alive.
  module ReleaseLease
    DIRECTORY = ".leases"

    module_function

    def release_root
      root = File.expand_path("../..", __dir__)
      File.file?(File.join(root, ".orbit-release.json")) ? root : nil
    end

    def hold!(root: release_root, pid: Process.pid)
      return nil unless root && File.directory?(root)

      directory = File.join(root, DIRECTORY)
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.write(File.join(directory, "#{pid}.json"),
                 JSON.generate("pid" => pid, "held_at" => Time.now.utc.iso8601), perm: 0o600)
    rescue SystemCallError
      nil
    end

    def prune_stale(release)
      Dir.glob(File.join(release, DIRECTORY, "*.json")).each do |path|
        File.unlink(path) unless alive?(path)
      end
    rescue SystemCallError
      nil
    end

    def live?(release)
      Dir.glob(File.join(release, DIRECTORY, "*.json")).any? { |path| alive?(path) }
    end

    def alive?(path)
      pid = JSON.parse(File.read(path)).fetch("pid")
      return false unless pid.is_a?(Integer) && pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue JSON::ParserError, KeyError, SystemCallError
      # An unreadable lease is uncertainty, not proof the release is unused.
      true
    end
  end
end
