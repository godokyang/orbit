# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/orbit/workspace_binding"

module WorkspaceBindingTest
  module_function

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-workspace-binding") do |tmp|
      test_same_root_records_identity(tmp)
      test_same_repository_different_worktree(tmp)
      test_different_repository_is_rejected(tmp)
      test_missing_path(tmp)
      test_non_git_only_same_path(tmp)
    end
    puts("WORKSPACE_BINDING_TEST_PASS assertions=#{@assertions}")
  end

  def test_same_root_records_identity(tmp)
    root = git_project(tmp, "same")
    bound = Orbit::WorkspaceBinding.bind(project_root: root, bound_at: "2026-09-22T00:00:00Z")
    canonical = File.realpath(root)

    assert_equal(canonical, bound["project_root"], "project root is canonical")
    assert_equal(canonical, bound["artifact_root"], "artifact root defaults to the project")
    assert_equal(canonical, bound.dig("project", "path"), "identity records the real path")
    assert_equal(true, bound.dig("project", "git"), "git repository is recognized")
    assert_equal(File.realpath(File.join(root, ".git")), bound.dig("project", "common_dir"), "common dir recorded")
    assert_equal(canonical, bound.dig("project", "worktree"), "worktree recorded")
    assert_equal(rev_parse(root, "HEAD"), bound.dig("project", "head"), "HEAD recorded")
    assert_equal(bound["project"], bound["artifact"], "default artifact identity matches the project")
    assert_equal("2026-09-22T00:00:00Z", bound["bound_at"], "binding time is recorded")
    assert_equal(bound["project_root"], JSON.parse(JSON.generate(bound)).fetch("project_root"), "record is JSON serializable")

    link = File.join(tmp, "same-link")
    File.symlink(root, link)
    Dir.chdir(tmp) do
      rebound = Orbit::WorkspaceBinding.rebind(bound, artifact_root: "same")
      assert_equal(canonical, rebound["artifact_root"], "relative path resolves to the same root")
    end
    via_link = Orbit::WorkspaceBinding.rebind(bound, artifact_root: link)
    assert_equal(canonical, via_link["artifact_root"], "symlink resolves to the same root")

    sub = File.join(root, "nested")
    FileUtils.mkdir_p(sub)
    nested = Orbit::WorkspaceBinding.identify(sub)
    assert_equal(File.realpath(sub), nested["path"], "subdirectory keeps its own path")
    assert_equal(canonical, nested["worktree"], "subdirectory records the worktree root")
    assert_equal(bound.dig("project", "common_dir"), nested["common_dir"], "subdirectory stays in the repository")
  end

  def test_same_repository_different_worktree(tmp)
    root = git_project(tmp, "main")
    other = File.join(tmp, "linked")
    git(root, "worktree", "add", "--detach", "-q", other, "HEAD")
    write(other, "from-worktree.txt", "other")
    commit(other, "worktree change")

    bound = Orbit::WorkspaceBinding.bind(project_root: root)
    rebound = Orbit::WorkspaceBinding.rebind(bound, artifact_root: other)
    project_head = rev_parse(root, "HEAD")
    artifact_head = rev_parse(other, "HEAD")

    assert(project_head != artifact_head, "worktree HEAD diverged")
    assert_equal(File.realpath(root), rebound["project_root"], "rebind keeps the project root")
    assert_equal(File.realpath(other), rebound["artifact_root"], "rebind switches the artifact root")
    assert_equal(rebound.dig("project", "common_dir"), rebound.dig("artifact", "common_dir"), "worktrees share a common dir")
    assert(rebound.dig("project", "worktree") != rebound.dig("artifact", "worktree"), "worktree paths differ")
    assert_equal(project_head, rebound.dig("project", "head"), "project HEAD stays on the original worktree")
    assert_equal(artifact_head, rebound.dig("artifact", "head"), "artifact HEAD is read from the target worktree")
    assert_equal(File.realpath(File.join(root, ".git")), rebound.dig("artifact", "common_dir"), "common dir is the main git dir")

    back = Orbit::WorkspaceBinding.rebind(rebound, artifact_root: root)
    assert_equal(File.realpath(root), back["artifact_root"], "rebind can return to the original worktree")
  end

  def test_different_repository_is_rejected(tmp)
    root = git_project(tmp, "left")
    other = git_project(tmp, "right")
    bound = Orbit::WorkspaceBinding.bind(project_root: root)

    error = assert_raises(Orbit::WorkspaceBinding::RebindRejected) do
      Orbit::WorkspaceBinding.rebind(bound, artifact_root: other)
    end
    assert(error.message.include?(File.realpath(other)), "rejection names the target path")
    assert(error.message.include?("different Git repository"), "rejection names the repository mismatch")
    assert_equal(File.realpath(root), bound["artifact_root"], "rejected rebind leaves the caller record unchanged")

    assert_raises(Orbit::WorkspaceBinding::RebindRejected) do
      Orbit::WorkspaceBinding.bind(project_root: root, artifact_root: other)
    end

    previous = ENV.fetch("GIT_DIR", nil)
    ENV["GIT_DIR"] = File.join(other, ".git")
    begin
      seen = Orbit::WorkspaceBinding.identify(root)
      assert_equal(File.realpath(File.join(root, ".git")), seen["common_dir"], "GIT_DIR does not redirect identity")
    ensure
      previous.nil? ? ENV.delete("GIT_DIR") : ENV["GIT_DIR"] = previous
    end
  end

  def test_missing_path(tmp)
    missing = File.join(tmp, "missing")
    error = assert_raises(Orbit::WorkspaceBinding::InvalidPath) do
      Orbit::WorkspaceBinding.bind(project_root: missing)
    end
    assert(error.message.include?(missing), "missing path is named")
    assert(error.message.include?("does not exist"), "missing path explains the failure")

    root = git_project(tmp, "present")
    bound = Orbit::WorkspaceBinding.bind(project_root: root)
    rebind_error = assert_raises(Orbit::WorkspaceBinding::InvalidPath) do
      Orbit::WorkspaceBinding.rebind(bound, artifact_root: missing)
    end
    assert(rebind_error.message.include?(missing), "missing rebind target is named")

    file = File.join(root, "file.txt")
    File.write(file, "x")
    assert_raises(Orbit::WorkspaceBinding::InvalidPath) do
      Orbit::WorkspaceBinding.normalize(file)
    end
    assert(Orbit::WorkspaceBinding::InvalidPath < Orbit::WorkspaceBinding::Error, "invalid path is a binding error")
    assert(Orbit::WorkspaceBinding::RebindRejected < Orbit::WorkspaceBinding::Error, "rejection is a binding error")
  end

  def test_non_git_only_same_path(tmp)
    root = File.join(tmp, "plain")
    other = File.join(tmp, "plain-other")
    FileUtils.mkdir_p(root)
    FileUtils.mkdir_p(other)
    bound = Orbit::WorkspaceBinding.bind(project_root: root)

    assert_equal(false, bound.dig("project", "git"), "directory without git is not a repository")
    assert_equal(nil, bound.dig("project", "common_dir"), "non-git common dir is empty")
    assert_equal(nil, bound.dig("project", "worktree"), "non-git worktree is empty")
    assert_equal(nil, bound.dig("project", "head"), "non-git HEAD is empty")

    same = Orbit::WorkspaceBinding.rebind(bound, artifact_root: root)
    assert_equal(File.realpath(root), same["artifact_root"], "non-git rebind keeps the same path")

    error = assert_raises(Orbit::WorkspaceBinding::RebindRejected) do
      Orbit::WorkspaceBinding.rebind(bound, artifact_root: other)
    end
    assert(error.message.include?("non-Git"), "non-git rejection names the policy")
    assert(error.message.include?(File.realpath(other)), "non-git rejection names the other path")

    foreign = git_project(tmp, "foreign")
    assert_raises(Orbit::WorkspaceBinding::RebindRejected) do
      Orbit::WorkspaceBinding.rebind(bound, artifact_root: foreign)
    end
  end

  def git_project(tmp, name)
    root = File.join(tmp, name)
    FileUtils.mkdir_p(root)
    git(root, "init", "-q")
    write(root, "README.md", name)
    commit(root, "init")
    root
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def commit(root, message)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", message)
  end

  def git(dir, *args)
    ok = system(
      "git", "-C", dir,
      "-c", "user.name=orbit-test",
      "-c", "user.email=orbit-test@example.com",
      "-c", "commit.gpgsign=false",
      *args,
      out: File::NULL, err: File::NULL
    )
    raise("git #{args.join(' ')} failed in #{dir}") unless ok
  end

  def rev_parse(dir, *args)
    output = IO.popen(["git", "-C", dir, "rev-parse", *args], &:read)
    raise("git rev-parse failed in #{dir}") unless $?.success?

    output.strip
  end

  def assert(condition, message)
    @assertions += 1
    raise("assertion failed: #{message}") unless condition
  end

  def assert_equal(expected, actual, message)
    assert(expected == actual, "#{message} (expected #{expected.inspect}, got #{actual.inspect})")
  end

  def assert_raises(error_class)
    @assertions += 1
    begin
      yield
    rescue error_class => error
      return error
    end
    raise("assertion failed: expected #{error_class} to be raised")
  end
end

WorkspaceBindingTest.run
