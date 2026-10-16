# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/orbit/model_candidate_pool"

module ModelCandidatePoolTest
  module_function

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-model-candidates") do |tmp|
      test_path_resolution_and_round_trip(tmp)
      test_validation_and_no_credentials(tmp)
      test_role_pools_are_independent_and_preserve_legacy(tmp)
      test_role_writes_reject_malformed_persisted_ids_without_overwriting(tmp)
      test_concurrent_adds_keep_every_model(tmp)
    end
    puts("MODEL_CANDIDATE_POOL_TEST_PASS assertions=#{@assertions}")
  end

  def test_role_writes_reject_malformed_persisted_ids_without_overwriting(tmp)
    path = File.join(tmp, "roles", "malformed.json")
    pool = Orbit::ModelCandidatePool.new(path: path, env: {})
    documents = [
      { "schema_version" => Orbit::ModelCandidatePool::ROLE_SCHEMA_VERSION,
        "legacy_models" => ["invalid legacy id"], "pools" => {} },
      { "schema_version" => Orbit::ModelCandidatePool::ROLE_SCHEMA_VERSION,
        "legacy_models" => [], "pools" => { "executor" => { "configured" => true, "models" => ["invalid role id"] } } }
    ]
    documents.each do |document|
      FileUtils.mkdir_p(File.dirname(path))
      original = JSON.generate(document)
      File.write(path, original)
      assert_raises(Orbit::ModelCandidatePool::Error, "role writes reject malformed inherited or configured IDs") do
        pool.add_role("executor", "executor/new")
      end
      assert_equal(original, File.read(path), "a rejected role write leaves the persisted document unchanged")
    end
  end

  def test_role_pools_are_independent_and_preserve_legacy(tmp)
    path = File.join(tmp, "roles", "model-candidates.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("schema_version" => "orbit-model-candidates-v1", "models" => ["legacy/model"]))
    pool = Orbit::ModelCandidatePool.new(path: path, env: {})
    assert_equal(["legacy/model"], pool.read_role("executor"), "legacy pool remains visible before role configuration")
    assert_equal(["legacy/model"], pool.read_role("checker"), "legacy pool remains compatible for the checker")
    reads = 0
    pool.define_singleton_method(:stored_document) do
      reads += 1
      super()
    end
    assert_equal({ "models" => ["legacy/model"], "configured" => false }, pool.role_snapshot("executor"),
                 "a legacy role snapshot returns models and configuration state together")
    assert_equal(1, reads, "one role snapshot parses exactly one stored document")

    pool.apply_role_delta("executor", base: ["legacy/model"], add: ["executor/one"], remove: ["legacy/model"])
    assert_equal(["executor/one"], pool.read_role("executor"), "executor delta is persisted independently")
    assert_equal(["legacy/model"], pool.read_role("checker"), "an unedited role continues inheriting legacy candidates")
    assert(pool.configured?("executor") && !pool.configured?("checker"), "configured status is role-specific")
    pool.add("legacy/second")
    assert_equal(["legacy/model", "legacy/second"], pool.read_role("checker"),
                 "legacy no-role writes remain visible to an unconfigured role")
    assert_equal(["executor/one"], pool.read_role("executor"), "legacy writes do not change a configured role")
    pool.remove_role("executor", "executor/one")
    assert_equal([], pool.read_role("executor") , "removing the final role model leaves a configured empty pool")
    assert(pool.configured?("executor"), "an explicitly emptied pool remains distinguishable from no configuration")
    assert_equal(["legacy/model", "legacy/second"], JSON.parse(File.read(path))["legacy_models"],
                 "legacy data is retained during role write")

    pool.add_role("checker", "checker/one")
    assert_equal([], pool.apply_role_delta("executor", base: [], add: [], remove: []),
                 "a no-op role delta leaves the configured empty pool unchanged")
    assert_equal(["legacy/model", "legacy/second", "checker/one"], pool.read_role("checker"),
                 "checker first edit freezes its inherited legacy candidates into its role pool")
    pool.add("legacy/third")
    assert_equal(["legacy/model", "legacy/second", "checker/one"], pool.read_role("checker"),
                 "old shared writes preserve configured role pools")
    assert_equal(["legacy/model", "legacy/second", "legacy/third"], pool.read,
                 "the no-role CLI view continues to expose the legacy shared pool")

    File.write(path, JSON.generate("schema_version" => Orbit::ModelCandidatePool::ROLE_SCHEMA_VERSION,
                                   "legacy_models" => [],
                                   "pools" => { "executor" => { "configured" => true, "models" => ["invalid model"] } }))
    assert_raises(Orbit::ModelCandidatePool::Error, "stored role identifiers are validated on read") { pool.read_role("executor") }
  end

  def test_path_resolution_and_round_trip(tmp)
    home = File.join(tmp, "home")

    absolute = Orbit::ModelCandidatePool.default_path(
      env: { "XDG_CONFIG_HOME" => File.join(tmp, "xdg"), "HOME" => home }
    )
    assert_equal(File.join(tmp, "xdg", "orbit", "model-candidates.json"), absolute,
                 "absolute XDG_CONFIG_HOME wins")

    relative = Orbit::ModelCandidatePool.default_path(
      env: { "XDG_CONFIG_HOME" => "relative/config", "HOME" => home }
    )
    assert_equal(File.join(home, ".config", "orbit", "model-candidates.json"), relative,
                 "relative XDG_CONFIG_HOME falls back to HOME/.config")

    fallback = Orbit::ModelCandidatePool.default_path(env: { "HOME" => home })
    assert_equal(File.join(home, ".config", "orbit", "model-candidates.json"), fallback,
                 "HOME/.config is the unset-XDG fallback")

    path = File.join(tmp, "pool", "model-candidates.json")
    pool = Orbit::ModelCandidatePool.new(path: path, env: {})
    assert_equal([], pool.read, "a missing pool reads as empty")
    assert(!File.exist?(path) && !File.exist?(File.dirname(path)),
           "read does not create the pool file or its directory")

    added = pool.add(["zhipu-coding-plan/glm-5.2", "zenmux/x-ai/grok-4.7"])
    assert_equal(["zhipu-coding-plan/glm-5.2", "zenmux/x-ai/grok-4.7"], added,
                 "add appends in order and keeps an id whose remainder contains a slash")
    assert_equal(added, Orbit::ModelCandidatePool.new(path: path, env: {}).read,
                 "a separate session reads the persisted pool")

    assert_equal(added, pool.add("zhipu-coding-plan/glm-5.2"), "adding a duplicate is a no-op")
    assert_equal(["zenmux/x-ai/grok-4.7"], pool.remove("zhipu-coding-plan/glm-5.2"),
                 "remove drops only the named model")
    assert_equal([], pool.remove("zenmux/x-ai/grok-4.7"), "removing the last model leaves an empty pool")
    assert_equal([], Orbit::ModelCandidatePool.new(path: path, env: {}).read, "the removal is persisted")

    assert_equal(0o600, File.stat(path).mode & 0o777, "the pool file is private")
    assert_equal(0o700, File.stat(File.dirname(path)).mode & 0o777, "the pool directory is private")
  end

  def test_validation_and_no_credentials(tmp)
    home = File.join(tmp, "home")
    config = File.join(tmp, "config")
    pool = Orbit::ModelCandidatePool.new(env: { "XDG_CONFIG_HOME" => config, "HOME" => home })
    assert_equal(File.join(config, "orbit", "model-candidates.json"), pool.path,
                 "the default path honors an absolute XDG_CONFIG_HOME")

    secret = "sk-credential-sentinel"
    previous = ENV["OPENCODE_GO_API_KEY"]
    ENV["OPENCODE_GO_API_KEY"] = secret
    begin
      pool.add("opencode-go/deepseek-v4.8")
      raw = File.read(pool.path)
      assert(!raw.include?(secret), "an ambient credential is never copied into the pool file")

      document = JSON.parse(raw)
      assert_equal(["models", "schema_version"], document.keys.sort,
                   "only the schema version and model identifiers are stored")
      assert_equal("orbit-model-candidates-v1", document["schema_version"], "the format version is persisted")

      assert_raises(Orbit::ModelCandidatePool::ValidationError, "an id without a provider slash is rejected") do
        pool.add("not-a-model")
      end
      assert_raises(Orbit::ModelCandidatePool::ValidationError, "whitespace inside an id is rejected") do
        pool.add("provider/bad id")
      end
      assert_equal(["opencode-go/deepseek-v4.8"], pool.read, "a rejected add leaves the pool unchanged")
    ensure
      previous.nil? ? ENV.delete("OPENCODE_GO_API_KEY") : ENV["OPENCODE_GO_API_KEY"] = previous
    end

    File.write(pool.path, "{ not json")
    assert_raises(Orbit::ModelCandidatePool::Error, "a corrupt pool raises on read") { pool.read }
    assert_raises(Orbit::ModelCandidatePool::Error, "a corrupt pool is never overwritten") do
      pool.add("provider/good")
    end
    assert_equal("{ not json", File.read(pool.path), "the corrupt file is preserved for the operator")
  end

  def test_concurrent_adds_keep_every_model(tmp)
    path = File.join(tmp, "concurrent", "model-candidates.json")
    start = File.join(tmp, "concurrent", "start")
    FileUtils.mkdir_p(File.dirname(start))

    pids = Array.new(6) do |index|
      Process.fork do
        sleep(0.001) until File.exist?(start)
        Orbit::ModelCandidatePool.new(path: path, env: {}).add("provider/worker-#{index}")
        exit!(0)
      end
    end
    File.write(start, "go")
    statuses = pids.map { |pid| Process.wait2(pid).last }
    assert(statuses.all?(&:success?), "every concurrent writer completed")

    models = Orbit::ModelCandidatePool.new(path: path, env: {}).read.sort
    assert_equal(Array.new(6) { |index| "provider/worker-#{index}" }.sort, models,
                 "every concurrent add survives; no writer silently overwrites another")
    assert_equal(0o600, File.stat("#{path}.lock").mode & 0o777, "the lock file is private")
  end

  # One picker Enter = one apply_delta: the add and the removal land together,
  # a different-ID edit made by another session since the snapshot survives,
  # and a same-ID membership change refuses the WHOLE commit (nothing written)
  # instead of silently overwriting the other session's choice.
  def test_apply_delta_commits_net_changes_and_refuses_same_id_conflicts(tmp)
    path = File.join(tmp, "delta", "model-candidates.json")
    pool = Orbit::ModelCandidatePool.new(path: path, env: {})
    pool.add(["provider/a", "provider/b"])

    other = Orbit::ModelCandidatePool.new(path: path, env: {})
    other.add("provider/other") # concurrent session, disjoint id, since snapshot

    result = pool.apply_delta(base: ["provider/a", "provider/b"],
                              add: ["provider/c"], remove: ["provider/b"])
    assert_equal(["provider/a", "provider/other", "provider/c"], result,
                 "one call applies add and remove while the other session's different-ID add survives")

    # Same-ID conflict: another session added the id this delta also adds.
    other.add("provider/taken")
    error = assert_raises(Orbit::ModelCandidatePool::ConflictError) do
      pool.apply_delta(base: result, add: ["provider/taken"])
    end
    assert_equal(["provider/taken"], error.conflicts, "the conflicting id is reported for refresh")
    assert_equal(["provider/a", "provider/other", "provider/c", "provider/taken"],
                 Orbit::ModelCandidatePool.new(path: path, env: {}).read,
                 "a refused commit writes nothing")

    # Same-ID conflict on removal: another session removed the id first.
    other.remove("provider/a")
    assert_raises(Orbit::ModelCandidatePool::ConflictError) do
      pool.apply_delta(base: ["provider/a", "provider/other", "provider/c", "provider/taken"], remove: ["provider/a"])
    end
    assert_equal(["provider/other", "provider/c", "provider/taken"],
                 Orbit::ModelCandidatePool.new(path: path, env: {}).read,
                 "the pool keeps the other session's removal")

    # An empty delta is a read-only no-op; a delta contradicting its own
    # snapshot is a caller bug, never a write.
    assert_equal(Orbit::ModelCandidatePool.new(path: path, env: {}).read,
                 pool.apply_delta(base: [], add: [], remove: []),
                 "an empty delta returns the current pool unchanged")
    assert_raises(Orbit::ModelCandidatePool::ValidationError) { pool.apply_delta(base: [], add: ["provider/x"], remove: ["provider/x"]) }
    assert_raises(Orbit::ModelCandidatePool::ValidationError) { pool.apply_delta(base: ["provider/x"], add: ["provider/x"]) }
    assert_raises(Orbit::ModelCandidatePool::ValidationError) { pool.apply_delta(base: [], remove: ["provider/x"]) }
  end

  def assert(condition, message)
    @assertions += 1
    raise("assertion failed: #{message}") unless condition
  end

  def assert_equal(expected, actual, message)
    assert(expected == actual, "#{message} (expected #{expected.inspect}, got #{actual.inspect})")
  end

  def assert_raises(error_class, message = error_class.name)
    @assertions += 1
    begin
      yield
    rescue error_class => captured
      return captured
    end
    raise("assertion failed: expected #{message}")
  end
end

ModelCandidatePoolTest.run
