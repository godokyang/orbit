# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "json"

module Orbit
  # Orbit task runtime R3: a real, content-addressed workspace snapshot.
  #
  # `capture(project_root:, destination:)` materializes a fixed copy of the
  # working tree and returns a serializable manifest of that exact copy:
  # tracked uncommitted modifications, deletions and non-ignored new files
  # are included; without Git the tree is addressed by content. `.git`,
  # `.orbit` and Git-ignored content are excluded, and symlinks are never
  # followed out of the project. The copy is written from the same bytes
  # that were hashed, and collection fails closed with `UnstableError` if
  # the tree changes while it runs, so a returned digest never claims an
  # agreement that was not observed.
  #
  # `fingerprint(project_root:)` recomputes the same digest without
  # writing anything, for matching a delivered workspace against a
  # captured version.
  module WorkspaceSnapshot
    SCHEMA_VERSION = "orbit-workspace-snapshot-v1"
    EXCLUDED_COMPONENTS = %w[.git .orbit].freeze
    NON_GIT_DEPENDENCY_DIRS = %w[node_modules .venv __pycache__].freeze
    PUBLIC_KEYS = %w[path status kind content_digest size mode target external materialized].freeze

    class Error < StandardError
      attr_reader :paths

      def initialize(message, paths: [])
        super(message)
        @paths = paths.freeze
      end
    end

    class UnstableError < Error; end

    class DestinationError < Error; end

    module_function

    def capture(project_root:, destination:)
      root = validate_root!(project_root)
      dest = validate_destination!(root, destination)

      staging = "#{dest}.staging-#{Process.pid}-#{rand(1_000_000)}"
      FileUtils.mkdir_p(staging)
      begin
        collected = collect(root, copy_root: staging)
        verify_stable!(root, collected)
        digest = manifest_digest(collected[:entries])
        FileUtils.rm_rf(dest) if File.exist?(dest)
        File.rename(staging, dest)
      rescue StandardError
        FileUtils.rm_rf(staging)
        raise
      end

      {
        "schema_version" => SCHEMA_VERSION,
        "source_root" => root,
        "snapshot_path" => dest,
        "git_head" => collected[:git_head],
        "digest" => digest,
        "project_rules" => project_rules(collected[:entries]),
        "manifest" => collected[:entries].map { |entry| public_entry(entry) }
      }
    end

    def fingerprint(project_root:)
      root = validate_root!(project_root)
      collected = collect(root)
      verify_stable!(root, collected)
      manifest_digest(collected[:entries])
    end

    def validate_root!(project_root)
      root = File.realpath(project_root.to_s)
      raise Error, "project root is not a directory: #{project_root}" unless File.directory?(root)

      root
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error, "project root does not exist: #{project_root}"
    end

    def validate_destination!(root, destination)
      dest = File.expand_path(destination.to_s)
      ensure_destination_location!(root, dest)
      FileUtils.mkdir_p(File.dirname(dest))
      dest = File.join(File.realpath(File.dirname(dest)), File.basename(dest))
      ensure_destination_location!(root, dest)
      if File.symlink?(dest) || (File.exist?(dest) && !(File.directory?(dest) && Dir.empty?(dest)))
        raise DestinationError, "snapshot destination must be a fresh or empty directory: #{dest}"
      end

      dest
    end

    def ensure_destination_location!(root, dest)
      return unless within?(root, dest)
      return if dest.start_with?("#{File.join(root, '.orbit')}/")

      raise DestinationError, "snapshot destination must be outside the workspace or under .orbit: #{dest}"
    end

    def collect(root, copy_root: nil)
      git_head, skeletons = enumerate(root)
      entries = skeletons.map { |skeleton| hydrate(root, skeleton, copy_root: copy_root) }
      { git_head: git_head, entries: entries }
    end

    def enumerate(root)
      if git_work_tree?(root)
        [git_head(root), git_skeletons(root)]
      else
        [nil, walk_skeletons(root)]
      end
    end

    def git_work_tree?(root)
      top = git_output(root, "rev-parse", "--show-toplevel")
      !top.nil? && safe_realpath(top.strip) == root
    end

    def git_head(root)
      output = git_output(root, "rev-parse", "HEAD")
      output && output.strip
    end

    def git_skeletons(root)
      statuses = parse_status(git_output(root, "status", "--porcelain=v1", "-z", "--untracked-files=all"))
      listed = git_output(root, "ls-files", "-c", "-o", "--exclude-standard", "-z").split("\0").reject(&:empty?)
      paths = (listed + statuses.keys).uniq.reject { |path| excluded_path?(path) }
      paths.sort_by(&:b).map do |path|
        { "path" => path, "codes" => statuses.fetch(path, []), "listed" => listed.include?(path) }
      end
    end

    def parse_status(output)
      return {} unless output

      chunks = output.split("\0")
      statuses = Hash.new { |hash, key| hash[key] = [] }
      index = 0
      while index < chunks.length && !chunks[index].empty?
        chunk = chunks[index]
        status = chunk[0, 2]
        path = chunk[3..]
        index += 1
        next unless path

        statuses[path] << status
        if status.include?("R") || status.include?("C")
          source = chunks[index]
          statuses[source] << "D " if source && !source.empty?
          index += 1
        end
      end
      statuses
    end

    def derive_status(codes, listed)
      return "added" if codes.any? { |code| code.start_with?("?") || code.include?("A") }
      return "added" if codes.any? { |code| code.start_with?("D") }
      return "modified" if codes.any? { |code| !code.strip.empty? }

      listed ? "tracked" : "modified"
    end

    def walk_skeletons(root)
      entries = []
      walk_directory(root, root, entries)
      entries.sort_by { |entry| entry["path"].b }
    end

    def walk_directory(root, dir, out)
      Dir.children(dir).sort.each do |name|
        next if EXCLUDED_COMPONENTS.include?(name)

        absolute = File.join(dir, name)
        stat = safe_lstat(absolute)
        next unless stat
        next if stat.directory? && NON_GIT_DEPENDENCY_DIRS.include?(name)

        relative = absolute.delete_prefix("#{root}/")
        if stat.symlink?
          out << { "path" => relative, "status" => "present", "target" => safe_readlink(absolute) }
        elsif stat.directory?
          walk_directory(root, absolute, out)
        elsif stat.file?
          out << { "path" => relative, "status" => "present" }
        else
          out << { "path" => relative, "status" => "present", "kind" => "other" }
        end
      end
    end

    def hydrate(root, skeleton, copy_root: nil)
      path = skeleton["path"]
      absolute = File.join(root, path)
      stat = safe_lstat(absolute)
      return { "path" => path, "status" => "deleted" } unless stat

      status = skeleton.key?("codes") ? derive_status(skeleton["codes"], skeleton["listed"]) : skeleton["status"]
      entry =
        if stat.symlink?
          symlink_entry(root, skeleton, absolute, stat, status)
        elsif stat.directory?
          { "path" => path, "status" => status, "kind" => "gitlink", "stat_key" => stat_key(stat) }
        elsif stat.file?
          file_entry(absolute, skeleton, status)
        else
          { "path" => path, "status" => status, "kind" => "other", "stat_key" => stat_key(stat) }
        end
      materialize(copy_root, entry) if copy_root
      entry.delete("bytes")
      entry.delete("copy_target")
      entry
    end

    def file_entry(absolute, skeleton, status)
      bytes, stat = read_stable(absolute)
      {
        "path" => skeleton["path"], "status" => status, "kind" => "file",
        "content_digest" => "sha256:#{Digest::SHA256.hexdigest(bytes)}",
        "size" => stat.size, "mode" => stat.mode & 0o777,
        "bytes" => bytes, "stat_key" => stat_key(stat)
      }
    end

    def symlink_entry(root, skeleton, absolute, stat, status)
      target = skeleton["target"] || safe_readlink(absolute)
      if target.nil?
        raise UnstableError.new("workspace symlink changed while being read: #{skeleton['path']}",
                                paths: [skeleton["path"]])
      end

      copy_target = resolve_link_target(root, absolute, target)
      {
        "path" => skeleton["path"], "status" => status, "kind" => "symlink",
        "target" => target, "external" => copy_target.nil?,
        "materialized" => !copy_target.nil?,
        "content_digest" => "sha256:#{Digest::SHA256.hexdigest(target)}",
        "copy_target" => copy_target, "stat_key" => stat_key(stat)
      }
    end

    def resolve_link_target(root, absolute, target)
      expanded = target.start_with?("/") ? File.expand_path(target) : File.expand_path(target, File.dirname(absolute))
      if File.exist?(absolute)
        resolved = safe_realpath(absolute)
        return nil if resolved.nil? || !within?(root, resolved)

        expanded = resolved
      end
      return nil unless within?(root, expanded)
      return target unless target.start_with?("/")

      Pathname.new(expanded).relative_path_from(Pathname.new(File.dirname(absolute))).to_s
    end

    def materialize(copy_root, entry)
      return if entry["status"] == "deleted"

      destination = File.join(copy_root, entry["path"])
      case entry["kind"]
      when "file"
        FileUtils.mkdir_p(File.dirname(destination))
        File.binwrite(destination, entry.fetch("bytes"))
        File.chmod(entry.fetch("mode"), destination)
      when "symlink"
        return if entry["copy_target"].nil?

        FileUtils.mkdir_p(File.dirname(destination))
        File.symlink(entry.fetch("copy_target"), destination)
      end
    end

    def read_stable(path)
      before = File.lstat(path)
      bytes = File.binread(path)
      after = File.lstat(path)
      if stat_key(before) != stat_key(after)
        raise UnstableError.new("workspace file changed while being read: #{path}", paths: [path])
      end

      [bytes, after]
    end

    def verify_stable!(root, collected)
      entries = collected[:entries]
      changed = []
      entries.each do |entry|
        path = entry["path"]
        absolute = File.join(root, path)
        if entry["stat_key"].nil?
          changed << path if File.symlink?(absolute) || File.exist?(absolute)
          next
        end
        stat = safe_lstat(absolute)
        changed << path if stat.nil? || stat_key(stat) != entry["stat_key"]
      end

      before_paths = entries.map { |entry| entry["path"] }
      after_paths = enumerate(root).last.map { |skeleton| skeleton["path"] }
      changed.concat(before_paths - after_paths)
      changed.concat(after_paths - before_paths)
      return if changed.empty?

      raise UnstableError.new(
        "workspace changed during snapshot collection; recollect before inspecting",
        paths: changed.uniq.sort
      )
    end

    def manifest_digest(entries)
      input = entries.sort_by { |entry| entry["path"].b }.map do |entry|
        marker = if entry["status"] == "deleted"
                   "deleted"
                 else
                   entry["content_digest"] || entry["kind"] || "present"
                 end
        [entry["path"], entry["kind"], marker, entry["mode"]]
      end
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(input))}"
    end

    def project_rules(entries)
      entries.select do |entry|
        entry["kind"] == "file" && entry["status"] != "deleted" &&
          File.basename(entry["path"]) == "AGENTS.md"
      end.map { |entry| entry["path"] }.sort
    end

    def public_entry(entry)
      entry.slice(*PUBLIC_KEYS)
    end

    def git_output(root, *args)
      output = IO.popen(["git", "--no-optional-locks", "-C", root, *args], err: File::NULL, &:read)
      $?.success? ? output : nil
    rescue Errno::ENOENT
      nil
    end

    def safe_realpath(path)
      File.realpath(path)
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def safe_lstat(path)
      File.lstat(path)
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def safe_readlink(path)
      File.readlink(path)
    rescue SystemCallError
      nil
    end

    def stat_key(stat)
      [stat.dev, stat.ino, stat.size, stat.mtime.to_r, stat.mode]
    end

    def excluded_path?(path)
      path.split("/").any? { |component| EXCLUDED_COMPONENTS.include?(component) }
    end

    def within?(root, path)
      path == root || path.start_with?("#{root}/")
    end
  end
end
