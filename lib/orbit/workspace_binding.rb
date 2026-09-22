# frozen_string_literal: true

require "open3"
require "time"

module Orbit
  # Identity and scope checks for `project_root` and `artifact_root`.
  #
  # `bind` and `rebind` canonicalize a directory and record its real path
  # plus Git common-dir, worktree and HEAD. They do not read or write task
  # state. A different artifact path is allowed only when both directories
  # are work trees of the same repository. A non-Git directory can only be
  # bound to its own real path.
  module WorkspaceBinding
    class Error < StandardError; end
    class InvalidPath < Error; end
    class RebindRejected < Error; end

    GIT_ENV_KEYS = %w[
      GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
      GIT_CEILING_DIRECTORIES
    ].freeze

    class << self
      def bind(project_root:, artifact_root: nil, bound_at: nil)
        project = identify(project_root)
        artifact = artifact_root.nil? ? project.dup : identify(artifact_root)
        ensure_allowed!(project, artifact)
        record(project, artifact, bound_at)
      end

      def rebind(current, artifact_root:, bound_at: nil)
        project = identify(required_project_root(current))
        artifact = identify(artifact_root)
        ensure_allowed!(project, artifact)
        record(project, artifact, bound_at)
      end

      def identify(path)
        root = normalize(path)
        git = git_identity(root)
        {
          "path" => root,
          "git" => !git.nil?,
          "common_dir" => git && git["common_dir"],
          "worktree" => git && git["worktree"],
          "head" => git && git["head"]
        }
      end

      def normalize(path)
        text = path.to_s
        raise InvalidPath, "workspace path is empty" if text.strip.empty?

        root = File.realpath(text)
        raise InvalidPath, "workspace path is not a directory: #{text}" unless File.directory?(root)

        root
      rescue Errno::ENOENT
        raise InvalidPath, "workspace path does not exist: #{text}"
      rescue Errno::ENOTDIR
        raise InvalidPath, "workspace path is not a directory: #{text}"
      rescue Errno::ELOOP
        raise InvalidPath, "workspace path has a symlink loop: #{text}"
      rescue Errno::EACCES
        raise InvalidPath, "workspace path is not accessible: #{text}"
      end

      private

      def required_project_root(current)
        root = current.is_a?(Hash) ? current["project_root"] : nil
        return root if root.is_a?(String) && !root.empty?

        raise Error, "binding record must include project_root"
      end

      def ensure_allowed!(project, artifact)
        return if project["path"] == artifact["path"]
        return if same_repository?(project, artifact)

        raise RebindRejected, rejection_message(project, artifact)
      end

      def same_repository?(project, artifact)
        project["git"] && artifact["git"] &&
          project["common_dir"] && project["common_dir"] == artifact["common_dir"]
      end

      def rejection_message(project, artifact)
        if project["git"] && artifact["git"]
          "workspace binding rejected: #{artifact['path']} is a different Git repository " \
            "(#{artifact['common_dir']}) from #{project['path']} (#{project['common_dir']})"
        elsif project["git"]
          "workspace binding rejected: #{artifact['path']} is not in the Git repository " \
            "of #{project['path']} (#{project['common_dir']})"
        else
          "workspace binding rejected: non-Git workspace #{project['path']} " \
            "can only be bound to the same path, not #{artifact['path']}"
        end
      end

      def record(project, artifact, bound_at)
        {
          "project_root" => project["path"],
          "artifact_root" => artifact["path"],
          "project" => project,
          "artifact" => artifact,
          "bound_at" => stamp(bound_at)
        }
      end

      def stamp(bound_at)
        return Time.now.utc.iso8601 if bound_at.nil?

        text = bound_at.to_s
        raise Error, "bound_at must not be empty" if text.empty?

        text
      end

      def git_identity(root)
        stdout, stderr, status = git(root, "rev-parse", "--is-inside-work-tree")
        if status == :missing
          return nil unless File.exist?(File.join(root, ".git"))

          raise Error, "git is required to identify #{root} but was not found"
        end
        return nil if not_a_repository?(status, stderr)
        unless status.success? && stdout.strip == "true"
          raise Error, "cannot determine Git identity for #{root}#{detail(stderr)}"
        end

        {
          "common_dir" => git_absolute(root, "--git-common-dir"),
          "worktree" => git_absolute(root, "--show-toplevel"),
          "head" => git_head(root)
        }
      end

      def git_absolute(root, flag)
        stdout, stderr, status = git(root, "rev-parse", "--path-format=absolute", flag)
        if status == :missing || !status.success?
          stdout, stderr, status = git(root, "rev-parse", flag)
        end
        if status == :missing || !status.success?
          raise Error, "cannot resolve #{flag} for #{root}#{detail(stderr)}"
        end

        text = stdout.strip
        raise Error, "cannot resolve #{flag} for #{root}" if text.empty?

        absolute = text.start_with?("/") ? text : File.expand_path(text, root)
        File.realpath(absolute)
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error, "cannot resolve #{flag} for #{root}"
      end

      def git_head(root)
        stdout, _stderr, status = git(root, "rev-parse", "HEAD")
        return nil if status == :missing || !status.success?

        head = stdout.strip
        head.match?(/\A[0-9a-f]{40,64}\z/) ? head : nil
      end

      def not_a_repository?(status, stderr)
        status.is_a?(Process::Status) && status.exitstatus == 128 &&
          stderr.to_s.include?("not a git repository")
      end

      def detail(stderr)
        text = stderr.to_s.strip
        text.empty? ? "" : ": #{text.lines.first.to_s.strip}"
      end

      def git(root, *args)
        env = {}
        GIT_ENV_KEYS.each { |key| env[key] = nil }
        Open3.capture3(env, "git", "--no-optional-locks", "-C", root, *args)
      rescue Errno::ENOENT
        ["", "", :missing]
      end
    end
  end
end
