# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/orbit/workspace_snapshot"

module WorkspaceSnapshotTest
  module_function

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-workspace-snapshot") do |tmp|
      test_dirty_new_deleted_and_rules(tmp)
      test_fixed_copy_and_later_edits(tmp)
      test_exclusions_and_external_symlinks(tmp)
      test_non_git_project_by_content(tmp)
      test_destination_boundaries(tmp)
    end
    puts("WORKSPACE_SNAPSHOT_TEST_PASS assertions=#{@assertions}")
  end

  def test_dirty_new_deleted_and_rules(tmp)
    root = project(tmp, "dirty")
    init_git(root)
    write(root, "a.txt", "old-a")
    write(root, "AGENTS.md", "project rules")
    write(root, "b.txt", "old-b")
    write(root, "c.txt", "c-old")
    commit(root, "init")

    write(root, "a.txt", "new-a")
    File.delete(File.join(root, "b.txt"))
    write(root, "new.rb", "puts :new")
    git(root, "rm", "-q", "c.txt")
    write(root, "c.txt", "c-recreated")

    dest = File.join(tmp, "dirty-copy")
    snapshot = Orbit::WorkspaceSnapshot.capture(project_root: root, destination: dest)
    entries = index(snapshot)

    assert_equal("modified", entries.fetch("a.txt")["status"], "dirty tracked status")
    assert_equal(digest_hex("new-a"), entries.fetch("a.txt")["content_digest"], "dirty tracked content")
    assert_equal("deleted", entries.fetch("b.txt")["status"], "deleted tracked status")
    assert(!File.exist?(File.join(dest, "b.txt")), "deleted file is absent from the copy")
    assert_equal("added", entries.fetch("new.rb")["status"], "non-ignored new file status")
    assert_equal(digest_hex("puts :new"), entries.fetch("new.rb")["content_digest"], "new file content")
    assert_equal("added", entries.fetch("c.txt")["status"], "staged deletion with recreated file status")
    assert_equal(digest_hex("c-recreated"), entries.fetch("c.txt")["content_digest"], "recreated file content")
    assert_equal("c-recreated", File.read(File.join(dest, "c.txt")), "recreated file copied")
    assert_equal("new-a", File.read(File.join(dest, "a.txt")), "copy holds the dirty bytes")
    assert_equal("project rules", File.read(File.join(dest, "AGENTS.md")), "rules copied")
    assert_equal(["AGENTS.md"], snapshot["project_rules"], "rules indexed")
    assert(snapshot["git_head"].to_s.match?(/\A[0-9a-f]{40}\z/), "git head recorded")
    assert_equal(snapshot["digest"], fingerprint(root), "fingerprint matches the capture")
    round_trip = JSON.parse(JSON.generate(snapshot))
    assert_equal(snapshot["digest"], round_trip["digest"], "return value is JSON serializable")
  end

  def test_fixed_copy_and_later_edits(tmp)
    root = project(tmp, "fixed")
    init_git(root)
    write(root, "a.txt", "v1")
    commit(root, "init")

    dest = File.join(tmp, "fixed-copy")
    snapshot = Orbit::WorkspaceSnapshot.capture(project_root: root, destination: dest)
    entries = index(snapshot)
    assert_equal(0o644, entries.fetch("a.txt")["mode"], "file mode recorded")
    assert_equal(0o644, File.stat(File.join(dest, "a.txt")).mode & 0o777, "copy keeps captured mode")

    write(root, "a.txt", "v2")
    assert_equal("v1", File.read(File.join(dest, "a.txt")), "fixed copy keeps captured bytes")
    assert_equal(digest_hex("v1"), entries.fetch("a.txt")["content_digest"], "manifest keeps captured content")
    assert(snapshot["digest"] != fingerprint(root), "fingerprint moves with later edits")
    assert_equal("v2", File.read(File.join(root, "a.txt")), "source edit stands")

    write(root, "a.txt", "v1")
    assert_equal(snapshot["digest"], fingerprint(root), "restored content without mode change matches")
    File.chmod(0o755, File.join(root, "a.txt"))
    assert(snapshot["digest"] != fingerprint(root), "mode-only change moves the fingerprint")
  end

  def test_exclusions_and_external_symlinks(tmp)
    root = project(tmp, "excluded")
    init_git(root)
    write(root, ".gitignore", "ignored.txt\n")
    write(root, "tracked.txt", "tracked")
    commit(root, "init")
    write(root, "ignored.txt", "ignored-secret")
    write(root, ".orbit/records.json", "{}")
    outside = File.join(tmp, "outside.txt")
    File.write(outside, "external-secret")
    File.symlink(outside, File.join(root, "ext_link"))
    File.symlink("tracked.txt", File.join(root, "in_link"))
    File.symlink(root, File.join(root, "root_link"))

    dest = File.join(tmp, "excluded-copy")
    snapshot = Orbit::WorkspaceSnapshot.capture(project_root: root, destination: dest)
    entries = index(snapshot)

    assert(entries.keys.none? { |path| path == ".git" || path.start_with?(".git/") }, ".git excluded")
    assert(!entries.key?(".orbit/records.json"), ".orbit records excluded")
    assert(!entries.key?("ignored.txt"), "git-ignored file excluded")

    external = entries.fetch("ext_link")
    assert_equal(true, external["external"], "external symlink flagged")
    assert_equal(false, external["materialized"], "external symlink not materialized")
    assert(!File.symlink?(File.join(dest, "ext_link")) && !File.exist?(File.join(dest, "ext_link")),
           "external symlink absent from the copy")

    internal = entries.fetch("in_link")
    assert_equal(false, internal["external"], "internal symlink not flagged external")
    assert_equal(true, internal["materialized"], "internal symlink materialized")
    assert(File.symlink?(File.join(dest, "in_link")), "internal symlink reproduced")
    assert_equal("tracked", File.read(File.join(dest, "in_link")), "internal symlink resolves inside the copy")

    root_link = entries.fetch("root_link")
    assert_equal(false, root_link["external"], "absolute in-tree symlink not flagged external")
    assert_equal(true, root_link["materialized"], "absolute in-tree symlink materialized")
    assert_equal(File.realpath(dest), File.realpath(File.join(dest, "root_link")),
                 "absolute root link resolves inside the copy")

    assert_equal(snapshot["digest"], fingerprint(root), "exclusions are symmetric in fingerprint")
  end

  def test_non_git_project_by_content(tmp)
    root = project(tmp, "content")
    write(root, "src/main.rb", "puts 1")
    write(root, "README.md", "readme")
    write(root, "node_modules/package/index.js", "generated dependency")
    write(root, ".venv/lib/dependency.py", "generated dependency")
    write(root, "src/__pycache__/main.pyc", "generated bytecode")

    dest = File.join(tmp, "content-copy")
    snapshot = Orbit::WorkspaceSnapshot.capture(project_root: root, destination: dest)
    entries = index(snapshot)

    assert_equal(%w[README.md src/main.rb], entries.keys.sort, "non-git dependencies are excluded")
    assert(!File.exist?(File.join(dest, "node_modules")), "dependency tree is not copied")
    assert_equal("present", entries.fetch("src/main.rb")["status"], "non-git entry status")
    assert_equal(nil, snapshot["git_head"], "non-git capture has no git head")
    assert_equal(digest_hex("puts 1"), entries.fetch("src/main.rb")["content_digest"], "non-git content digest")
    assert_equal("puts 1", File.read(File.join(dest, "src/main.rb")), "non-git copy content")
    assert_equal(snapshot["digest"], fingerprint(root), "non-git fingerprint matches")

    write(root, "node_modules/package/index.js", "dependency changed")
    assert_equal(snapshot["digest"], fingerprint(root), "dependency churn does not trigger a check")

    write(root, "src/main.rb", "puts 2")
    assert(snapshot["digest"] != fingerprint(root), "non-git fingerprint tracks content changes")
  end

  def test_destination_boundaries(tmp)
    root = project(tmp, "destination")
    init_git(root)
    write(root, "a.txt", "a")
    commit(root, "init")

    inside = File.join(root, "snapshot-copy")
    assert_raises(Orbit::WorkspaceSnapshot::DestinationError) do
      Orbit::WorkspaceSnapshot.capture(project_root: root, destination: inside)
    end
    assert(!File.exist?(inside), "rejected destination was not created")

    dest = File.join(tmp, "destination-copy")
    Orbit::WorkspaceSnapshot.capture(project_root: root, destination: dest)
    assert_raises(Orbit::WorkspaceSnapshot::DestinationError) do
      Orbit::WorkspaceSnapshot.capture(project_root: root, destination: dest)
    end

    orbit_dest = File.join(root, ".orbit", "snapshots", "s1")
    snapshot = Orbit::WorkspaceSnapshot.capture(project_root: root, destination: orbit_dest)
    assert_equal(snapshot["digest"], fingerprint(root), "snapshot under .orbit is excluded from the fingerprint")
  end

  def project(tmp, name)
    root = File.join(tmp, name)
    FileUtils.mkdir_p(root)
    root
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def init_git(root)
    git(root, "init", "-q")
  end

  def commit(root, message)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", message)
  end

  def git(dir, *args)
    ok = system("git", "-C", dir, "-c", "user.name=orbit-test", "-c", "user.email=orbit-test@example.com",
                "-c", "commit.gpgsign=false", *args, out: File::NULL, err: File::NULL)
    raise("git #{args.join(' ')} failed in #{dir}") unless ok
  end

  def index(snapshot)
    snapshot.fetch("manifest").to_h { |entry| [entry.fetch("path"), entry] }
  end

  def fingerprint(root)
    Orbit::WorkspaceSnapshot.fingerprint(project_root: root)
  end

  def digest_hex(content)
    "sha256:#{Digest::SHA256.hexdigest(content)}"
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
    rescue error_class
      return
    end
    raise("assertion failed: expected #{error_class} to be raised")
  end
end

WorkspaceSnapshotTest.run
