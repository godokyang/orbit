# frozen_string_literal: true

module Orbit
  # Commit history is a review clue, not attribution: another task can commit
  # to the same branch between the task's bound HEAD and a fixed snapshot.
  module TaskGitEvidence
    MAX_BYTES = 16_384
    MAX_PATHS = 40
    HEAD_PATTERN = /\A[0-9a-f]{40,64}\z/i

    module_function

    def capture(workspace:, baseline_head:, snapshot_head:)
      return nil unless HEAD_PATTERN.match?(baseline_head.to_s) && HEAD_PATTERN.match?(snapshot_head.to_s)

      evidence = { "baseline_head" => baseline_head, "snapshot_head" => snapshot_head,
                   "note" => "Committed paths between these HEADs are review clues, not proof of task ownership. " \
                             "Inspect the fixed snapshot against the original instruction." }
      unless system("git", "-C", workspace, "merge-base", "--is-ancestor", baseline_head, snapshot_head,
                    out: File::NULL, err: File::NULL)
        return evidence.merge("status" => "unavailable", "reason" => "task baseline is not a proven ancestor of snapshot HEAD")
      end

      bytes = IO.popen(["git", "-C", workspace, "diff", "--no-ext-diff", "--no-textconv",
                        "--name-only", "--no-renames", "-z", baseline_head, snapshot_head, "--"],
                       err: File::NULL) { |io| io.read(MAX_BYTES + 1) }.to_s
      truncated = bytes.bytesize > MAX_BYTES
      return evidence.merge("status" => "unavailable", "reason" => "Git path diff failed") unless truncated || $?.success?

      prefix = bytes.byteslice(0, MAX_BYTES)
      paths = prefix.split("\0")
      paths.pop unless prefix.end_with?("\0")
      paths.reject! { |path| path == ".orbit" || path.start_with?(".orbit/", ".git/") }
      paths = paths.first(MAX_PATHS).map(&:scrub)
      evidence.merge("status" => "available", "changed_paths" => paths,
                     "truncated" => truncated || bytes.count("\0") > MAX_PATHS)
    rescue SystemCallError, IOError
      evidence&.merge("status" => "unavailable", "reason" => "Git task history could not be read")
    end
  end
end
