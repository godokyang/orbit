# frozen_string_literal: true

# Slice 13: CI Release Readiness.
#
# Release tasks must separate local confidence (review/test pass) from release readiness
# (CI status, package hash, contents checked, generated artifacts, remote state).
# This module provides the skeleton, validation, and audit summaries.

ALLOWED_CI_STATUSES = %w[pending running passed failed cancelled skipped].freeze
ALLOWED_AHEAD_BEHIND = %w[up_to_date ahead behind diverged unknown].freeze

# Default release_readiness skeleton written by new-task for release-risk tasks.
def default_release_readiness
  {
    "source" => {
      "git_head" => "",
      "reviewed_diff_base" => ""
    },
    "ci" => {
      "provider" => "",
      "run_id" => "",
      "status" => ""
    },
    "package" => {
      "artifact_path" => "",
      "artifact_sha256" => "",
      "contents_checked" => false
    },
    "version_fields" => [],
    "generated_artifacts" => [],
    "remote_state" => {
      "branch" => "",
      "ahead_behind" => ""
    }
  }
end

# Safe nested dig that returns nil when intermediate values are not Hash.
def rr_dig(rr, *keys)
  val = rr
  keys.each do |k|
    return nil unless val.is_a?(Hash)
    val = val[k]
  end
  val
end

# Check if a release_readiness block has the full structure required.
# Validates that source/ci/package/remote_state are Hashes and version_fields/generated_artifacts are Arrays.
def release_readiness_has_structure?(rr)
  return false unless rr.is_a?(Hash)
  return false unless rr["source"].is_a?(Hash)
  return false unless rr["ci"].is_a?(Hash)
  return false unless rr["package"].is_a?(Hash)
  return false unless rr["version_fields"].is_a?(Array)
  return false unless rr["generated_artifacts"].is_a?(Array)
  return false unless rr["remote_state"].is_a?(Hash)
  true
end

# Compute release readiness blockers from a release_readiness block.
# Returns array of {source, message} hashes.
def release_readiness_blockers(rr)
  return [{ "source" => "task_file.release_readiness", "message" => "Release task is missing release_readiness block entirely." }] unless rr.is_a?(Hash)

  blockers = []

  # Structure check: nested fields must have correct types.
  unless release_readiness_has_structure?(rr)
    %w[source ci package remote_state].each do |field|
      blockers << { "source" => "task_file.release_readiness.#{field}", "message" => "release_readiness.#{field} must be a mapping." } unless rr[field].is_a?(Hash)
    end
    blockers << { "source" => "task_file.release_readiness.version_fields", "message" => "release_readiness.version_fields must be a list." } unless rr["version_fields"].is_a?(Array)
    blockers << { "source" => "task_file.release_readiness.generated_artifacts", "message" => "release_readiness.generated_artifacts must be a list." } unless rr["generated_artifacts"].is_a?(Array)
    # If structure is malformed, return blockers early to avoid crashes on non-Hash nested access.
    return blockers
  end

  # CI status must be present and passed.
  ci_status = rr_dig(rr, "ci", "status")
  if ci_status.nil? || ci_status.to_s.empty?
    blockers << { "source" => "task_file.release_readiness.ci.status", "message" => "CI status is missing; local tests cannot prove release readiness." }
  elsif ci_status.is_a?(String) && !ALLOWED_CI_STATUSES.include?(ci_status)
    blockers << { "source" => "task_file.release_readiness.ci.status", "message" => "CI status #{ci_status.inspect} is not one of #{ALLOWED_CI_STATUSES.join('|')}." }
  elsif ci_status != "passed"
    blockers << { "source" => "task_file.release_readiness.ci.status", "message" => "CI status is #{ci_status.inspect}; release requires CI to have passed." }
  end

  # Package artifact hash must be present and valid.
  artifact_sha = rr_dig(rr, "package", "artifact_sha256")
  if artifact_sha.nil? || artifact_sha.to_s.empty?
    blockers << { "source" => "task_file.release_readiness.package.artifact_sha256", "message" => "Package artifact_sha256 is missing; release requires a verified package hash." }
  elsif artifact_sha.is_a?(String) && !artifact_sha.match?(/\A[0-9a-f]{64}\z/)
    blockers << { "source" => "task_file.release_readiness.package.artifact_sha256", "message" => "Package artifact_sha256 is not a valid SHA256 hex string." }
  end

  # Package contents_checked must be true.
  contents_checked = rr_dig(rr, "package", "contents_checked")
  unless contents_checked == true
    blockers << { "source" => "task_file.release_readiness.package.contents_checked", "message" => "Package contents_checked is not true; release requires explicit confirmation that package contents were reviewed." }
  end

  # Remote state must have a branch.
  branch = rr_dig(rr, "remote_state", "branch")
  if branch.nil? || branch.to_s.empty?
    blockers << { "source" => "task_file.release_readiness.remote_state.branch", "message" => "Remote state branch is missing; release requires remote branch verification." }
  end

  # ahead_behind must be up_to_date; anything else is a gap.
  ahead_behind = rr_dig(rr, "remote_state", "ahead_behind")
  ab_source = "task_file.release_readiness.remote_state.ahead_behind"
  if ahead_behind.nil? || ahead_behind.to_s.empty?
    blockers << { "source" => ab_source, "message" => "Remote state ahead_behind is missing; release requires confirmed up_to_date remote state." }
  elsif !ahead_behind.is_a?(String) || !ALLOWED_AHEAD_BEHIND.include?(ahead_behind)
    blockers << { "source" => ab_source, "message" => "Remote state ahead_behind #{ahead_behind.inspect} is not one of #{ALLOWED_AHEAD_BEHIND.join('|')}." }
  elsif ahead_behind != "up_to_date"
    reason = case ahead_behind
             when "ahead" then "local commits not yet pushed to remote"
             when "behind" then "remote has commits not in local; pull/merge required"
             when "diverged" then "remote and local have diverged; rebase/merge required"
             when "unknown" then "remote sync status could not be determined"
             end
    blockers << { "source" => ab_source, "message" => "Remote state is #{ahead_behind} (#{reason}); release requires up_to_date." }
  end

  # Generated artifacts must be checked or explicitly waived.
  gen_artifacts = rr["generated_artifacts"]
  if gen_artifacts.is_a?(Array)
    unchecked = gen_artifacts.select do |a|
      next false unless a.is_a?(Hash)
      a["checked"] != true && a["waiver"].to_s.empty? && a["rationale"].to_s.empty? && a["gap"].to_s.empty?
    end
    if unchecked.any?
      blockers << { "source" => "task_file.release_readiness.generated_artifacts", "message" => "#{unchecked.length} generated artifact(s) not checked or waived; release requires all generated artifacts to be verified or have an explicit waiver/gap." }
    end
  end

  blockers
end

# Summarize release readiness for audit/handoff output.
def release_readiness_summary(task)
  rr = task.is_a?(Hash) ? task["release_readiness"] : nil
  return nil unless rr

  blockers = release_readiness_blockers(rr)
  {
    "has_structure" => release_readiness_has_structure?(rr),
    "ci_status" => rr_dig(rr, "ci", "status"),
    "package_hashed" => rr_dig(rr, "package", "artifact_sha256").is_a?(String) && !rr_dig(rr, "package", "artifact_sha256").empty?,
    "contents_checked" => rr_dig(rr, "package", "contents_checked") == true,
    "remote_branch" => rr_dig(rr, "remote_state", "branch"),
    "ahead_behind" => rr_dig(rr, "remote_state", "ahead_behind"),
    "blockers" => blockers,
    "blocker_count" => blockers.length,
    "ready" => blockers.empty?
  }
end
