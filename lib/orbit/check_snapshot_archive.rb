# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "find"
require "pathname"
require_relative "workspace_snapshot"

module Orbit
  # Project-local content archive for check snapshots.
  #
  # Objects live at `<project>/.orbit/snapshot-objects/sha256/<2>/<hex>` and are
  # a different inode from the source tree and from the in-flight workspace.
  # The workspace directory is removed only after the archive is read back and
  # verified, the runner reports a confirmed process-group exit, and receipts
  # have been collected. A missing PID is not that confirmation.
  #
  # Runner interface owned by H. This module only reads it.
  # Live: `check_lifecycle(number)` returns this hash, or nil before it is true:
  #   number, pid, pgid, reaped: true, group_probe: "esrch", receipts: "collected"
  # Durable: the same hash, written once to `checks/<n>/lifecycle.json` after this
  # runner has done all three, in order: `waitpid2` returned a status, `kill(0, -pgid)`
  # returned ESRCH, and the receipts were then read. A restarted runtime consumes
  # that owner record. It does not probe. ECHILD is not `reaped`. A later PID
  # absence, or `group_probe` other than "esrch", keeps the workspace. `pid` and
  # `pgid` must match `checks/<n>/run.json`. Live and stored facts that disagree
  # on these fields also keep it.
  class CheckSnapshotArchive
    ARCHIVE_SCHEMA = "orbit-check-snapshot-archive-v1"
    LIFECYCLE_SCHEMA = "orbit-check-lifecycle-v1"
    RECLAIM_SCHEMA = "orbit-check-workspace-reclaim-v1"
    LIFECYCLE_FIELDS = %w[number pid pgid reaped group_probe receipts].freeze

    class Error < StandardError; end

    def initialize(project_root)
      @project_root = File.realpath(project_root.to_s)
      @objects_root = File.join(@project_root, ".orbit", "snapshot-objects")
      @failures = []
    end

    attr_reader :failures, :objects_root, :project_root

    def store_file(digest, bytes)
      hex = self.class.hex_digest(digest)
      raise Error, "content digest is not sha256" unless hex

      relative = self.class.object_key(hex)
      final = File.join(@objects_root, relative)
      self.class.verify_store_parent!(@project_root, File.dirname(final))
      FileUtils.mkdir_p(File.dirname(final))
      self.class.verify_store_parent!(@project_root, File.dirname(final))
      if self.class.matching_object?(final, hex, bytes.bytesize)
        File.chmod(0o444, final)
        return relative
      end

      temp = File.join(File.dirname(final), ".#{hex}.#{Process.pid}.#{rand(1_000_000)}.tmp")
      File.binwrite(temp, bytes)
      File.chmod(0o444, temp)
      written = Digest::SHA256.file(temp).hexdigest
      raise Error, "snapshot object write mismatch for #{digest}" unless written == hex

      begin
        File.link(temp, final)
      rescue Errno::EEXIST
        nil
      ensure
        File.unlink(temp) if File.exist?(temp)
      end
      raise Error, "snapshot object #{relative} does not match #{digest}" unless self.class.matching_object?(final, hex, bytes.bytesize)

      File.chmod(0o444, final)
      relative
    rescue StandardError => error
      @failures << "#{digest}: #{error.class}: #{error.message}"
      nil
    end

    def seal(snapshot_digest:, source_root:, entries:)
      raise Error, @failures.join("; ") unless @failures.empty?

      archived = entries.map { |entry| archive_entry(entry) }
      self.class.verify_archived_entries!(archived, objects_root: @objects_root, snapshot_digest: snapshot_digest, project_root: @project_root)
      {
        "schema_version" => ARCHIVE_SCHEMA,
        "snapshot_digest" => snapshot_digest,
        "source_root" => source_root,
        "objects_root" => @objects_root,
        "verified_at" => Time.now.utc.iso8601,
        "entries" => archived
      }
    end

    def self.reclaim(task_path:, project_root:, number:, lifecycle:, run_record: nil,
                     cleanup_error: nil, in_flight: false, stop_unconfirmed: false)
      check_dir = check_directory(task_path, number)
      workspace = File.join(check_dir, "workspace")
      decision = {
        "schema_version" => RECLAIM_SCHEMA, "number" => number,
        "at" => Time.now.utc.iso8601, "status" => "retained", "reasons" => [], "gates" => {}
      }
      prior_path = File.join(check_dir, "workspace-reclaim.json")
      if !File.symlink?(workspace) && !File.exist?(workspace) && File.file?(prior_path)
        prior = JSON.parse(File.read(prior_path))
        return prior.merge("unchanged" => true) if prior.is_a?(Hash) && prior["status"] == "reclaimed"
      end
      present = File.symlink?(workspace) || File.exist?(workspace)
      archive_path = File.join(check_dir, "snapshot-archive.json")
      scope_path = File.join(check_dir, "scope.json")
      scope_bytes = File.file?(scope_path) ? File.binread(scope_path) : nil
      reasons = decision["reasons"]
      reasons << "in_flight" if in_flight
      reasons << "cleanup_error" unless cleanup_error.to_s.empty?
      reasons << "stop_unconfirmed" if stop_unconfirmed
      reasons << "workspace_symlink" if File.symlink?(workspace)
      reasons << "workspace_absent" unless present

      archive_ok = false
      begin
        archive = File.file?(archive_path) ? JSON.parse(File.read(archive_path)) : nil
        scope = scope_bytes ? JSON.parse(scope_bytes) : nil
        archive_ok = verify_archive!(archive, project_root: project_root, scope: scope)
        verify_workspace!(workspace, archive["entries"], source_root: archive["source_root"]) if present && !File.symlink?(workspace)
      rescue StandardError => error
        reasons << "archive_unverified: #{error.message}"
      end
      reasons << "archive_unverified" unless archive_ok || reasons.any? { |reason| reason.start_with?("archive_unverified") }

      if lifecycle.is_a?(Hash) && lifecycle["conflict"]
        reasons << "lifecycle_conflict"
      elsif lifecycle.is_a?(Hash) && lifecycle["unreadable"]
        reasons << "lifecycle_unreadable"
      elsif !lifecycle.is_a?(Hash)
        reasons << "lifecycle_missing"
      end
      gates = lifecycle_gates(lifecycle, run_record: run_record, number: number)
      gates.each { |gate, ok| reasons << "lifecycle_#{gate}" unless ok } if lifecycle.is_a?(Hash) && !lifecycle["conflict"] && !lifecycle["unreadable"]
      decision["gates"] = gates.merge("archive" => archive_ok)

      if reasons.empty?
        begin
          remove_workspace!(workspace, check_dir)
          decision["status"] = "reclaimed"
        rescue StandardError => error
          reasons << "remove_failed: #{error.class}: #{error.message}"
          decision["status"] = "retained"
        end
      end
      if scope_bytes && File.file?(scope_path) && File.binread(scope_path) != scope_bytes
        raise Error, "reclaim changed scope.json"
      end

      prior = File.file?(prior_path) ? JSON.parse(File.read(prior_path)) : nil
      if prior.is_a?(Hash) && prior["status"] == decision["status"] && prior["reasons"] == reasons &&
         (decision["status"] == "retained" || !present)
        return prior.merge("unchanged" => true)
      end
      writable = decision.reject { |key, _| key == "unchanged" }
      write_json(prior_path, writable)
      writable
    rescue JSON::ParserError => error
      decision["reasons"] << "reclaim_record_unreadable: #{error.message}"
      decision
    end

    def self.restore(task_path:, project_root:, number:, destination:)
      check_dir = check_directory(task_path, number)
      scope_path = File.join(check_dir, "scope.json")
      raise Error, "check scope is missing: #{scope_path}" unless File.file?(scope_path)

      scope_bytes = File.binread(scope_path)
      scope = JSON.parse(scope_bytes)
      snapshot = scope["snapshot"]
      raise Error, "scope has no snapshot manifest" unless snapshot.is_a?(Hash) && snapshot["digest"].is_a?(String)

      dest = File.expand_path(destination.to_s)
      raise Error, "restore destination already exists: #{dest}" if File.exist?(dest) || File.symlink?(dest)
      refuse_restore_destination!(dest, task_path: task_path, project_root: project_root)

      archive_path = File.join(check_dir, "snapshot-archive.json")
      workspace = File.join(check_dir, "workspace")
      if File.file?(archive_path)
        archive = JSON.parse(File.read(archive_path))
        verify_archive!(archive, project_root: project_root, scope: scope)
        entries = archive.fetch("entries")
        source = "archive"
      elsif File.directory?(workspace) && !File.symlink?(workspace)
        archive = nil
        entries = snapshot.fetch("manifest")
        verify_workspace!(workspace, entries, source_root: snapshot["source_root"])
        entries = entries.map { |entry| entry["kind"] == "symlink" && entry["materialized"] != false && !entry["external"] && entry["status"] != "deleted" ? entry.merge("snapshot_target" => File.readlink(File.join(workspace, entry["path"]))) : entry }
        source = "workspace"
      else
        raise Error, "check #{number} has neither a verified archive nor a complete workspace"
      end

      staging = "#{dest}.staging-#{Process.pid}-#{rand(1_000_000)}"
      FileUtils.mkdir_p(staging)
      begin
        materialize_restore!(staging, entries, source: source, archive: archive, workspace: workspace, project_root: project_root, source_root: snapshot["source_root"])
        restored = WorkspaceSnapshot.manifest_digest(entries)
        raise Error, "restored tree does not match the scope digest" unless restored == snapshot["digest"]
        File.rename(staging, dest)
      rescue StandardError
        FileUtils.rm_rf(staging)
        raise
      end
      raise Error, "restore changed scope.json" unless File.binread(scope_path) == scope_bytes

      { "destination" => dest, "digest" => snapshot["digest"], "source" => source, "check" => number }
    end

    # Files and symlinks to embed when the on-disk workspace is gone. Bytes stay
    # in the object store until the caller streams them; nothing here rewrites scope.
    def self.export_members(task_path:, project_root:)
      files = []
      symlinks = []
      missing = []
      checks = File.join(task_path, "checks")
      return { files: files, symlinks: symlinks, missing: missing } unless File.directory?(checks)

      Dir.children(checks).each do |name|
        next unless name.match?(/\A\d+\z/)

        directory = File.join(checks, name)
        archive_path = File.join(directory, "snapshot-archive.json")
        workspace = File.join(directory, "workspace")
        next unless File.file?(archive_path)
        next if File.directory?(workspace) && !File.symlink?(workspace)

        begin
          archive = JSON.parse(File.read(archive_path))
          scope_path = File.join(directory, "scope.json")
          scope = File.file?(scope_path) ? JSON.parse(File.read(scope_path)) : nil
          verify_archive!(archive, project_root: project_root, scope: scope)
        rescue StandardError => error
          missing << { "item" => "checks/#{name}/workspace", "reason" => "archived workspace could not be verified (#{error.message})" }
          next
        end
        Array(archive["entries"]).each do |entry|
          relative = export_relative(name, entry)
          next unless relative

          if entry["kind"] == "symlink"
            symlinks << { "path" => relative, "target" => snapshot_link_target(entry, archive["entries"], archive["source_root"]) }
          elsif entry["kind"] == "file"
            object = object_file(archive, entry, project_root)
            hex = hex_digest(entry["content_digest"])
            if object.nil? || hex.nil? || !matching_object?(object, hex, entry["size"])
              missing << { "item" => relative, "reason" => "archived file bytes are missing or do not match the scope digest" }
            else
              files << { "path" => relative, "object_path" => object, "mode" => entry["mode"] || 0o644,
                         "sha256" => hex, "bytes" => entry["size"] }
            end
          end
        end
      end
      { files: files, symlinks: symlinks, missing: missing }
    end

    def self.lifecycle_gates(facts, run_record:, number:)
      gates = { "reaped" => false, "group_probe" => false, "receipts" => false, "run" => false }
      return gates unless facts.is_a?(Hash) && !facts["conflict"] && !facts["unreadable"]
      return gates unless facts["number"] == number

      gates["reaped"] = facts["reaped"] == true
      gates["group_probe"] = facts["group_probe"] == "esrch"
      gates["receipts"] = facts["receipts"] == "collected"
      recorded = run_record.is_a?(Hash) ? run_record : {}
      gates["run"] = facts["pid"].is_a?(Integer) && facts["pid"].positive? &&
                     facts["pgid"].is_a?(Integer) && facts["pgid"].positive? &&
                     recorded["pid"] == facts["pid"] && recorded["pgid"] == facts["pgid"]
      gates
    end

    def self.hex_digest(digest)
      value = digest.to_s.delete_prefix("sha256:")
      value.match?(/\A[0-9a-f]{64}\z/) ? value : nil
    end

    def self.object_key(hex)
      "sha256/#{hex[0, 2]}/#{hex}"
    end

    def self.write_json(path, payload)
      temporary = "#{path}.#{SecureRandom.hex(4)}.tmp"
      FileUtils.mkdir_p(File.dirname(path))
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(payload) + "\n")
      end
      File.rename(temporary, path)
    rescue StandardError
      File.unlink(temporary) if File.exist?(temporary)
      raise
    end

    def self.matching_object?(path, hex, size)
      return false if File.symlink?(path) || !File.file?(path)
      return false unless File.size(path) == size

      Digest::SHA256.file(path).hexdigest == hex
    end

    def self.verify_archive!(archive, project_root:, scope:)
      raise Error, "archive is missing" unless archive.is_a?(Hash) && archive["schema_version"] == ARCHIVE_SCHEMA

      expected_root = File.join(File.realpath(project_root.to_s), ".orbit", "snapshot-objects")
      raise Error, "archive object store is outside the project" unless archive["objects_root"] == expected_root
      raise Error, "original scope manifest is missing" unless scope.is_a?(Hash) && scope.dig("snapshot", "manifest").is_a?(Array)
      if archive["snapshot_digest"] != scope.dig("snapshot", "digest")
        raise Error, "archive digest does not match scope"
      end
      raise Error, "archive source root does not match scope" unless archive["source_root"] == scope.dig("snapshot", "source_root")
      raise Error, "scope manifest does not match its digest" unless WorkspaceSnapshot.manifest_digest(scope["snapshot"]["manifest"]) == archive["snapshot_digest"]
      archived_manifest = archive.fetch("entries").map { |entry| WorkspaceSnapshot.public_entry(entry) }.sort_by { |entry| entry["path"] }
      scoped_manifest = scope["snapshot"]["manifest"].sort_by { |entry| entry["path"] }
      raise Error, "archive metadata differs from original scope" unless archived_manifest == scoped_manifest
      verify_store_parent!(File.realpath(project_root.to_s), expected_root)
      verify_archived_entries!(archive["entries"], objects_root: expected_root, snapshot_digest: archive["snapshot_digest"], project_root: project_root)
      archive["entries"].each do |entry|
        snapshot_link_target(entry, archive["entries"], archive["source_root"]) if materialized?(entry) && entry["kind"] == "symlink"
      end
      true
    end

    def self.verify_archived_entries!(entries, objects_root:, snapshot_digest:, project_root:)
      raise Error, "archive entries are missing" unless entries.is_a?(Array)

      entries.each do |entry|
        safe_relative!(entry["path"])
        if entry["kind"] == "symlink" && entry["status"] != "deleted"
          raise Error, "symlink digest differs from original target" unless entry["content_digest"] == "sha256:#{Digest::SHA256.hexdigest(entry.fetch('target'))}"
        end
        next unless entry["kind"] == "file" && entry["status"] != "deleted"

        hex = hex_digest(entry["content_digest"])
        raise Error, "archived file #{entry['path']} has no sha256" unless hex
        raise Error, "archived file #{entry['path']} has a foreign object key" unless entry["object"] == object_key(hex)

        path = File.join(objects_root, entry["object"])
        verify_store_parent!(File.realpath(project_root.to_s), File.dirname(path))
        raise Error, "archived file #{entry['path']} is missing" unless matching_object?(path, hex, entry["size"])
        real = File.realpath(path)
        root = File.realpath(objects_root)
        raise Error, "archived object escaped the store" unless real.start_with?("#{root}/")
      end
      digest = WorkspaceSnapshot.manifest_digest(entries)
      raise Error, "archive manifest does not match its snapshot digest" unless digest == snapshot_digest
    end

    def self.verify_store_parent!(project_root, parent)
      root = File.realpath(project_root)
      relative = Pathname.new(File.expand_path(parent)).relative_path_from(Pathname.new(root)).to_s
      raise Error, "object path is outside project" if relative.start_with?("../") || relative == ".."
      current = root
      relative.split("/").each do |part|
        current = File.join(current, part)
        raise Error, "symlinked object store parent: #{current}" if File.symlink?(current)
        raise Error, "object store parent is not a directory: #{current}" if File.exist?(current) && !File.directory?(current)
      end
    end

    def self.materialized?(entry)
      entry["status"] != "deleted" && entry["external"] != true && entry["materialized"] != false && %w[file symlink].include?(entry["kind"])
    end

    # Resolve absolute internal links using only the saved manifest, never live source.
    def self.snapshot_link_target(entry, entries, source_root)
      target = entry["target"]
      raise Error, "symlink target is missing" unless target.is_a?(String) && !target.empty?
      root = File.expand_path(source_root.to_s)
      saved = entry["snapshot_target"]
      if saved
        raise Error, "snapshot link target must be relative" unless saved.is_a?(String) && !saved.empty? && !saved.start_with?("/")
        resolved = File.expand_path(saved, File.join(root, File.dirname(entry["path"])))
        raise Error, "snapshot link target escaped historical tree" unless resolved == root || resolved.start_with?("#{root}/")
        return saved
      end
      # Older macOS scopes may name /var or /tmp while source_root is /private.
      # Normalize that OS alias lexically: never consult the current source tree.
      canonical = lambda do |value|
        alias_root = root.delete_prefix("/private")
        if RUBY_PLATFORM.include?("darwin") && root.match?(%r{\A/private/(var|tmp)(/|\z)}) &&
           (value == alias_root || value.start_with?("#{alias_root}/"))
          "/private#{value}"
        else
          value
        end
      end
      target = canonical.call(target) if target.start_with?("/")
      expanded = File.expand_path(target, File.join(root, File.dirname(entry["path"])))
      raise Error, "symlink is outside historical source" unless expanded == root || expanded.start_with?("#{root}/")
      if target.start_with?("/")
        seen = []
        loop do
          relative = Pathname.new(expanded).relative_path_from(Pathname.new(root)).to_s
          link = entries.find { |item| item["kind"] == "symlink" && (relative == item["path"] || relative.start_with?("#{item['path']}/")) }
          break unless link
          raise Error, "historical symlink cycle" if seen.include?(link["path"])
          seen << link["path"]
          suffix = relative.delete_prefix(link["path"])
          expanded = File.expand_path(canonical.call(link["target"]), File.join(root, File.dirname(link["path"]))) + suffix
          raise Error, "historical symlink chain escaped source" unless expanded == root || expanded.start_with?("#{root}/")
        end
        target = Pathname.new(expanded).relative_path_from(Pathname.new(File.join(root, File.dirname(entry["path"])))).to_s
      end
      target
    end

    def self.verify_workspace!(workspace, entries, source_root:)
      raise Error, "workspace is not an independent directory" unless File.directory?(workspace) && !File.symlink?(workspace)
      expected = entries.select { |entry| materialized?(entry) }.to_h { |entry| [safe_relative!(entry["path"]), entry] }
      allowed_dirs = expected.keys.flat_map do |path|
        parts = path.split("/")
        (1...parts.length).map { |length| parts.first(length).join("/") }
      end
      observed = []
      Find.find(workspace) do |absolute|
        next if absolute == workspace
        relative = absolute.delete_prefix("#{workspace}/")
        stat = File.lstat(absolute)
        if stat.directory?
          raise Error, "unexpected workspace directory: #{relative}" unless allowed_dirs.include?(relative)
          next
        end
        entry = expected[relative]
        raise Error, "unexpected workspace content: #{relative}" unless entry
        observed << relative
        if entry["kind"] == "symlink"
          raise Error, "workspace symlink changed: #{relative}" unless stat.symlink? && File.readlink(absolute) == snapshot_link_target(entry, entries, source_root)
          Find.prune
        else
          raise Error, "workspace file changed: #{relative}" unless stat.file? && !stat.symlink? &&
            (stat.mode & 0o777) == entry["mode"] && matching_object?(absolute, hex_digest(entry["content_digest"]), entry["size"])
        end
      end
      raise Error, "workspace paths are missing" unless observed.sort == expected.keys.sort
      true
    end

    def archive_entry(entry)
      archived = {}
      %w[path status kind content_digest size mode target external materialized snapshot_target].each do |key|
        archived[key] = entry[key] if entry.key?(key)
      end
      if entry["kind"] == "file" && entry["status"] != "deleted"
        hex = self.class.hex_digest(entry["content_digest"])
        archived["object"] = self.class.object_key(hex) if hex
      end
      archived
    end

    class << self
      private

      def check_directory(task_path, number)
        raise Error, "check number is invalid" unless number.is_a?(Integer) && number.positive?

        File.join(task_path, "checks", number.to_s)
      end

      def remove_workspace!(workspace, check_dir)
        raise Error, "refusing to remove a symlinked workspace" if File.symlink?(workspace)
        raise Error, "workspace is missing" unless File.directory?(workspace)

        real_check = File.realpath(check_dir)
        real_workspace = File.realpath(workspace)
        unless File.dirname(real_workspace) == real_check && File.basename(real_workspace) == "workspace"
          raise Error, "workspace path escaped the check directory"
        end
        FileUtils.rm_rf(real_workspace)
        raise Error, "workspace still exists after removal" if File.exist?(workspace) || File.symlink?(workspace)
      end

      def refuse_restore_destination!(dest, task_path:, project_root:)
        task = File.realpath(task_path)
        parent = File.dirname(dest)
        raise Error, "restore destination parent is missing" unless File.directory?(parent)

        real_parent = File.realpath(parent)
        inside = ->(root, path) { path == root || path.start_with?("#{root}/") }
        raise Error, "restore destination must not be inside the task" if inside.call(task, File.join(real_parent, File.basename(dest)))
        objects = File.join(File.realpath(project_root.to_s), ".orbit", "snapshot-objects")
        return unless File.directory?(objects)

        raise Error, "restore destination must not be inside the object store" if inside.call(File.realpath(objects), File.join(real_parent, File.basename(dest)))
      end

      def materialize_restore!(staging, entries, source:, archive:, workspace:, project_root:, source_root:)
        entries.each do |entry|
          path = safe_relative!(entry["path"])
          destination = File.join(staging, path)
          if entry["status"] == "deleted" || entry["external"] == true || entry["materialized"] == false ||
             %w[gitlink other].include?(entry["kind"])
            raise Error, "deleted or unmaterialized path was created: #{path}" if File.exist?(destination) || File.symlink?(destination)
            next
          end
          raise Error, "restore path escapes the destination" unless File.expand_path(destination).start_with?("#{File.expand_path(staging)}/")

          FileUtils.mkdir_p(File.dirname(destination))
          if entry["kind"] == "symlink"
            target = snapshot_link_target(entry, entries, source_root)
            raise Error, "symlink target is missing: #{path}" if target.empty?

            resolved = File.expand_path(target, File.dirname(destination))
            unless resolved == File.expand_path(staging) || resolved.start_with?("#{File.expand_path(staging)}/")
              raise Error, "symlink escapes the restored tree: #{path}"
            end
            File.symlink(target, destination)
            raise Error, "restored symlink target mismatch: #{path}" unless File.readlink(destination) == target
          elsif entry["kind"] == "file"
            bytes = restore_bytes(entry, source: source, archive: archive, workspace: workspace, project_root: project_root)
            hex = hex_digest(entry["content_digest"])
            raise Error, "restored bytes do not match the manifest: #{path}" unless hex && Digest::SHA256.hexdigest(bytes) == hex
            raise Error, "restored size does not match the manifest: #{path}" unless bytes.bytesize == entry["size"]

            File.binwrite(destination, bytes)
            File.chmod(entry["mode"] || 0o644, destination)
            raise Error, "restored mode does not match the manifest: #{path}" unless (File.stat(destination).mode & 0o777) == (entry["mode"] || 0o644)
            assert_independent_inode!(destination, entry, source: source, archive: archive, workspace: workspace, project_root: project_root)
          else
            raise Error, "unsupported archive entry: #{path}"
          end
        end
      end

      def restore_bytes(entry, source:, archive:, workspace:, project_root:)
        if source == "archive"
          path = object_file(archive, entry, project_root)
          raise Error, "archived bytes are missing: #{entry['path']}" unless path

          File.binread(path)
        else
          path = File.join(workspace, safe_relative!(entry["path"]))
          raise Error, "workspace file is missing: #{entry['path']}" unless File.file?(path) && !File.symlink?(path)

          File.binread(path)
        end
      end

      def assert_independent_inode!(destination, entry, source:, archive:, workspace:, project_root:)
        restored = File.stat(destination)
        sources = []
        if source == "archive"
          object = object_file(archive, entry, project_root)
          sources << File.stat(object) if object && File.file?(object)
        elsif File.file?(File.join(workspace, entry["path"]))
          sources << File.stat(File.join(workspace, entry["path"]))
        end
        sources.each do |stat|
          raise Error, "restore shares an inode with stored bytes: #{entry['path']}" if stat.dev == restored.dev && stat.ino == restored.ino
        end
      end

      def object_file(archive, entry, project_root)
        return nil unless archive.is_a?(Hash)

        expected = File.join(File.realpath(project_root.to_s), ".orbit", "snapshot-objects")
        return nil unless archive["objects_root"] == expected

        hex = hex_digest(entry["content_digest"])
        return nil unless hex && entry["object"] == object_key(hex)

        path = File.join(expected, entry["object"])
        verify_store_parent!(File.realpath(project_root.to_s), File.dirname(path))
        return nil unless File.file?(path) && !File.symlink?(path)

        real = File.realpath(path)
        real.start_with?("#{File.realpath(expected)}/") ? real : nil
      end

      def export_relative(number, entry)
        return nil if entry["status"] == "deleted" || entry["external"] == true || entry["materialized"] == false
        return nil unless %w[file symlink].include?(entry["kind"])

        "checks/#{number}/workspace/#{safe_relative!(entry['path'])}"
      end

      def safe_relative!(path)
        raise Error, "archive path is unsafe" unless path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.split("/").any? { |part| ["..", ".", ""].include?(part) }

        path
      end
    end
  end
end
