# frozen_string_literal: true

# Real-git tests for Orbit::GitRemoteEvidence, the bounded read-only remote
# evidence the runtime injects into the checker context as "git_remote".
# Uses local bare remotes only: no network, no credential store, no prompt.
# Run:
#   ruby --disable-gems tests/git_remote_evidence_test.rb

require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/orbit/git_remote_evidence"

module GitRemoteEvidenceTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  COMMIT_ENV = {
    "GIT_AUTHOR_NAME" => "orbit-test", "GIT_AUTHOR_EMAIL" => "orbit-test@example.com",
    "GIT_COMMITTER_NAME" => "orbit-test", "GIT_COMMITTER_EMAIL" => "orbit-test@example.com"
  }.freeze

  def git(dir, *args)
    ok = system(COMMIT_ENV, "git", "-C", dir, "-c", "commit.gpgsign=false",
                "-c", "core.hooksPath=/dev/null", *args, out: File::NULL, err: File::NULL)
    raise "fixture git #{args.join(' ')} failed" unless ok
  end

  # A work clone with one pushed commit on main and an origin bare remote.
  def pushed_repo(root, branch: "main")
    work = File.join(root, "work")
    remote = File.join(root, "remote.git")
    Dir.mkdir(work)
    git(root, "init", "-q", "--bare", remote)
    git(work, "init", "-q", "-b", branch, ".")
    File.write(File.join(work, "file.txt"), "one\n")
    git(work, "add", "-A")
    git(work, "commit", "-qm", "one")
    git(work, "remote", "add", "origin", remote)
    git(work, "push", "-q", "-u", "origin", branch)
    [work, remote]
  end

  def json_serializable?(evidence)
    JSON.generate(evidence)
    true
  rescue JSON::JSONError, TypeError
    false
  end

  def verified_when_local_head_equals_the_remote_reference
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "实现修复并推送到远端")
      assert(evidence["status"] == "verified", "an up-to-date push is verified")
      assert(evidence["remote_contacted"] == true && evidence["remote_head"] == evidence["head"],
             "the remote reference resolves to the same commit as the local HEAD")
      assert(evidence["branch"] == "main" && evidence["upstream"] == "origin/main" &&
             evidence["remote_ref"] == "refs/heads/main",
             "the target branch and remote reference are captured")
      assert(evidence["reason"].is_a?(String) && !evidence["reason"].empty?, "verified carries a reason")
      assert(json_serializable?(evidence), "the evidence is JSON-serializable for the checker context")
    end
  end

  def mismatch_when_the_remote_lags_behind_local_head
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      File.write(File.join(work, "file.txt"), "two\n")
      git(work, "add", "-A")
      git(work, "commit", "-qm", "two")
      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "commit and push to origin")
      assert(evidence["status"] == "mismatch", "an unpushed commit is a mismatch, never verified")
      assert(evidence["head"] != evidence["remote_head"] && evidence["remote_contacted"] == true,
             "the mismatch compares the real remote reference, not a Root report")
      assert(evidence["reason"].include?("differs"), "the reason names the divergence")
    end
  end

  def unknown_when_the_remote_is_unreachable
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      git(work, "remote", "set-url", "origin", File.join(root, "missing.git"))
      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "push the branch")
      assert(evidence["status"] == "unknown" && evidence["remote_contacted"] == true,
             "an unreachable remote is unknown and honestly reported as contacted-but-unverifiable")
      assert(evidence["remote_head"].nil? && evidence["reason"].include?("not verifiable"),
             "no remote commit is asserted when verification failed")
      assert(evidence["head"] && evidence["upstream"], "local facts survive the failed verification")
    end
  end

  def plain_commit_instructions_do_not_contact_the_remote
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      ["just commit the fix", "merge the changes into main 本地合并"].each do |instruction|
        evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: instruction)
        assert(evidence["status"] == "unknown" && evidence["remote_contacted"] == false,
             "a plain commit/merge instruction contacts no remote: #{instruction}")
        assert(evidence["remote_head"].nil?, "no remote fact is asserted without contact")
        assert(evidence["head"] && evidence["remote_url"], "local facts are still captured: #{instruction}")
      end
    end
  end

  def unknown_without_upstream_or_repository
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      git(work, "branch", "--unset-upstream")
      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "push it")
      assert(evidence["status"] == "unknown" && evidence["reason"].include?("no upstream"),
             "a branch without upstream tracking is unknown with an actionable reason")

      empty = File.join(root, "empty")
      Dir.mkdir(empty)
      evidence = Orbit::GitRemoteEvidence.capture(workspace: empty, instruction: "push it")
      assert(evidence["status"] == "unknown" && evidence["reason"].include?("not a git repository"),
             "a non-repository workspace is unknown, not an exception")
    end
  end

  def explicit_target_wins_over_upstream_and_ambiguity_stays_unknown
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      git(work, "checkout", "-q", "-b", "feature")
      File.write(File.join(work, "file.txt"), "feature\n")
      git(work, "add", "-A")
      git(work, "commit", "-qm", "feature")
      git(work, "push", "-q", "-u", "origin", "feature")
      git(work, "push", "-q", "origin", "HEAD:main")

      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "推送到 origin/main")
      assert(evidence["status"] == "verified" && evidence["target_source"] == "explicit" &&
             evidence["remote_ref"] == "refs/heads/main",
             "an explicit origin/main target is compared against origin/main, not the tracked feature branch")
      assert(evidence["upstream"] == "origin/feature" && evidence["branch"] == "feature",
             "the tracking branch stays visible as a local fact")

      File.write(File.join(work, "file.txt"), "ahead\n")
      git(work, "add", "-A")
      git(work, "commit", "-qm", "ahead")
      lagging = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "fix and push to origin/main")
      assert(lagging["status"] == "mismatch" && lagging["remote_ref"] == "refs/heads/main",
             "an unpushed HEAD is a mismatch against the explicit target, never a verified feature upstream")

      spec = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "git push origin HEAD:main")
      assert(spec["target_source"] == "explicit" && spec["remote_ref"] == "refs/heads/main",
             "a push refspec names the explicit target branch")

      git(work, "push", "-q", "origin", "HEAD~1:refs/heads/dev")
      ambiguous = Orbit::GitRemoteEvidence.capture(workspace: work,
                                                   instruction: "merge origin/main into origin/dev and push")
      assert(ambiguous["status"] == "unknown" && ambiguous["remote_contacted"] == false &&
             ambiguous["reason"].include?("more than one distinct remote target"),
             "two distinct named targets are ambiguous and unknown, not a guess at one of them")
    end
  end

  def explicit_target_can_name_a_nonfirst_configured_remote
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      release = File.join(root, "release.git")
      git(root, "init", "-q", "--bare", release)
      git(work, "remote", "add", "release", release)
      git(work, "push", "-q", "release", "main")
      File.write(File.join(work, "file.txt"), "new release\n")
      git(work, "add", "file.txt")
      git(work, "commit", "-qm", "new release")
      git(work, "push", "-q", "origin", "main")

      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "请推送到 release/main")
      assert(evidence["status"] == "mismatch" && evidence["remote"] == "release" &&
             evidence["target_source"] == "explicit" && evidence["upstream"] == "origin/main",
             "a verified origin/main must not stand in for the unpushed second remote release/main")
    end
  end

  def nested_branch_references_stay_intact
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      git(work, "checkout", "-q", "-b", "feature/deep")
      File.write(File.join(work, "file.txt"), "deep\n")
      git(work, "add", "-A")
      git(work, "commit", "-qm", "deep")
      git(work, "push", "-q", "-u", "origin", "feature/deep")
      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "push branch")
      assert(evidence["status"] == "verified" && evidence["remote_ref"] == "refs/heads/feature/deep",
             "a branch name containing slashes keeps its full remote reference")
    end
  end

  def urls_and_errors_are_sanitized_and_read_only
    Dir.mktmpdir("orbit-git-ev-") do |root|
      work, = pushed_repo(root)
      git(work, "remote", "set-url", "origin", "https://user:secret-token@example.com/org/repo.git")
      evidence = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "merge and commit only")
      assert(evidence["remote_url"] == "https://[redacted]@example.com/org/repo.git",
             "userinfo credentials in the remote URL are redacted")
      assert(!JSON.generate(evidence).include?("secret-token"), "no secret reaches the evidence")

      git(work, "remote", "set-url", "origin", File.join(root, "missing.git"))
      lagging = Orbit::GitRemoteEvidence.capture(workspace: work, instruction: "publish the release")
      assert(!JSON.generate(lagging).include?("secret-token"), "failure reasons stay sanitized too")

      status = nil
      Dir.chdir(work) { IO.popen(["git", "status", "--porcelain"]) { |io| status = io.read } }
      assert(status.strip.empty?, "the capture leaves the working tree untouched")
    end
  end

  def a_hanging_command_is_bounded_and_killed
    pid = Process.spawn("sleep", "30", pgroup: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = Orbit::GitRemoteEvidence.send(:wait_with_deadline, pid, 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert(status.nil? || !status.exited? || !status.success?,
           "a command past the timeout never reports success")
    assert(elapsed < 5, "the kill path stays bounded, took #{elapsed.round(2)}s")
    begin
      Process.kill(0, -pid)
      raise "timeout did not kill the process group"
    rescue Errno::ESRCH
      true
    end
  end

  def run
    verified_when_local_head_equals_the_remote_reference
    mismatch_when_the_remote_lags_behind_local_head
    unknown_when_the_remote_is_unreachable
    plain_commit_instructions_do_not_contact_the_remote
    unknown_without_upstream_or_repository
    explicit_target_wins_over_upstream_and_ambiguity_stays_unknown
    explicit_target_can_name_a_nonfirst_configured_remote
    nested_branch_references_stay_intact
    urls_and_errors_are_sanitized_and_read_only
    a_hanging_command_is_bounded_and_killed
    puts "PASS git remote evidence"
  end
end

GitRemoteEvidenceTest.run
