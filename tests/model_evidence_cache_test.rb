# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/orbit/model_evidence_cache"

module ModelEvidenceCacheTest
  module_function

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-model-evidence") do |tmp|
      test_default_path_resolution(tmp)
      test_evidence_lookup_by_identity(tmp)
      test_validity_windows(tmp)
      test_unavailable_records(tmp)
      test_source_and_timestamp_validation(tmp)
      test_metric_and_field_validation(tmp)
      test_atomic_write_permissions_and_fail_closed(tmp)
      test_concurrent_writers_keep_every_entry(tmp)
      test_over_limit_write_is_rejected_without_touching_cache(tmp)
      test_corrupt_cache_fails_closed(tmp)
    end
    puts("MODEL_EVIDENCE_CACHE_TEST_PASS assertions=#{@assertions}")
  end

  def test_default_path_resolution(tmp)
    home = File.join(tmp, "home")
    xdg = Orbit::ModelEvidenceCache.default_path(env: { "XDG_CACHE_HOME" => File.join(tmp, "xdg"), "HOME" => home })
    assert_equal(File.join(tmp, "xdg", "orbit", "model-evidence-v1.json"), xdg, "absolute XDG_CACHE_HOME wins")

    relative = Orbit::ModelEvidenceCache.default_path(env: { "XDG_CACHE_HOME" => "relative/cache", "HOME" => home })
    assert_equal(File.join(home, ".cache", "orbit", "model-evidence-v1.json"), relative,
                 "relative XDG_CACHE_HOME falls back to HOME/.cache")

    fallback = Orbit::ModelEvidenceCache.default_path(env: { "HOME" => home })
    assert_equal(File.join(home, ".cache", "orbit", "model-evidence-v1.json"), fallback, "HOME/.cache fallback")

    injected = Orbit::ModelEvidenceCache.default_path(env: {}, home: File.join(tmp, "injected"))
    assert_equal(File.join(tmp, "injected", ".cache", "orbit", "model-evidence-v1.json"), injected,
                 "injected home fallback")

    explicit = Orbit::ModelEvidenceCache.new(path: File.join(tmp, "explicit.json"), env: {})
    assert_equal(File.join(tmp, "explicit.json"), explicit.path, "explicit path wins")
  end

  def test_evidence_lookup_by_identity(tmp)
    cache = cache_at(tmp, "identity", -> { Time.utc(2026, 9, 22, 10) })
    cache.record(evidence)

    hit = cache.lookup(provider: "opencode-go", model: "deepseek-v4.8", reasoning: "default")
    assert_equal("evidence", hit["status"], "evidence is stored")
    assert_equal(120.5, hit.dig("metrics", "output_tokens_per_second", "value"), "metric value preserved")
    assert_equal("tokens/s", hit.dig("metrics", "output_tokens_per_second", "unit"), "metric unit preserved")
    assert_equal(hit, cache.lookup(provider: "opencode-go", model: "deepseek-v4.8"), "omitted reasoning uses default")
    assert(cache.lookup(provider: "opencode-go", model: "deepseek-v4.8", reasoning: "max").nil?, "reasoning change misses")
    assert(cache.lookup(provider: "openai", model: "deepseek-v4.8").nil?, "provider change misses")
    assert(cache.lookup(provider: "opencode-go", model: "deepseek-v4.9").nil?, "model change misses")

    cache.record(evidence("reasoning" => "max"))
    assert_equal(2, JSON.parse(File.read(cache.path)).fetch("entries").length, "distinct identity appends")

    cache.record_all([evidence("reasoning" => "max", "model" => "gpt-6-astra"), evidence("reasoning" => "max")])
    stored = JSON.parse(File.read(cache.path)).fetch("entries")
    assert_equal(3, stored.length, "one batch upserts by identity")
    assert_equal("2026-09-22T09:00:00Z", cache.lookup(provider: "opencode-go", model: "deepseek-v4.8", reasoning: "max")["retrieved_at"],
                 "last entry for an identity wins inside a batch")
  end

  def test_validity_windows(tmp)
    now = Time.utc(2026, 9, 22, 10)
    cache = cache_at(tmp, "validity", -> { now })
    fixed = cache.record(evidence)
    assert_equal("2026-09-29T09:00:00Z", fixed["valid_until"], "concrete version defaults to seven days")

    offset = cache.record(evidence("model" => "gemini-2.5-pro-preview-06-05", "retrieved_at" => "2026-09-22T17:00:00+08:00"))
    assert_equal("2026-09-23T09:00:00Z", offset["valid_until"], "floating alias defaults to 24 hours")
    assert_equal("2026-09-22T09:00:00Z", offset["retrieved_at"], "timestamps normalize to UTC")
    assert_equal(24 * 60 * 60, Orbit::ModelEvidenceCache.validity_seconds(model: "gpt-6-astra-latest"), "latest is floating")
    assert_equal(7 * 24 * 60 * 60, Orbit::ModelEvidenceCache.validity_seconds(model: "gpt-6-astra"), "version is fixed")

    shorter = cache.record(evidence("model" => "gpt-6-astra", "valid_until" => "2026-09-22T12:00:00Z"))
    assert_equal("2026-09-22T12:00:00Z", shorter["valid_until"], "shorter submitted window is kept")

    now = Time.utc(2026, 9, 22, 11, 59, 59)
    assert(!cache.lookup(provider: "opencode-go", model: "gpt-6-astra").nil?, "shorter submitted window still hits before expiry")
    assert(!cache.lookup(provider: "opencode-go", model: "gemini-2.5-pro-preview-06-05").nil?, "floating alias inside 24h hits")
    now = Time.utc(2026, 9, 22, 12)
    assert(cache.lookup(provider: "opencode-go", model: "gpt-6-astra").nil?, "explicitly shortened window expires")
    now = Time.utc(2026, 9, 23, 9)
    assert(cache.lookup(provider: "opencode-go", model: "gemini-2.5-pro-preview-06-05").nil?, "floating alias expires after 24h")
    now = Time.utc(2026, 9, 29, 8, 59, 59)
    assert(!cache.lookup(provider: "opencode-go", model: "deepseek-v4.8").nil?, "fixed version hits before seven days")
    now = Time.utc(2026, 9, 29, 9)
    assert(cache.lookup(provider: "opencode-go", model: "deepseek-v4.8").nil?, "fixed version expires at the boundary")
  end

  def test_unavailable_records(tmp)
    now = Time.utc(2026, 9, 22, 10)
    cache = cache_at(tmp, "unavailable", -> { now })
    entry = cache.record("provider" => "kimi", "model" => "kimi-k3", "status" => "unavailable",
                         "retrieved_at" => "2026-09-22T09:30:00Z", "reason" => "no comparable public benchmark found")
    assert_equal("unavailable", entry["status"], "unavailable is recorded")
    hit = cache.lookup(provider: "kimi", model: "kimi-k3")
    assert_equal("no comparable public benchmark found", hit["reason"], "lookup returns the unavailable record")
    now = Time.utc(2026, 9, 29, 9, 30)
    assert(cache.lookup(provider: "kimi", model: "kimi-k3").nil?, "unavailable expires like evidence")
  end

  def test_source_and_timestamp_validation(tmp)
    cache = cache_at(tmp, "invalid", -> { Time.utc(2026, 9, 22, 10) })
    rejected = [
      ["empty sources", evidence("sources" => [])],
      ["non-http source", evidence("sources" => ["ftp://example.com/report"])],
      ["source with credentials", evidence("sources" => ["https://user:secret@example.com/report"])],
      ["source without host", evidence("sources" => ["https:///report"])],
      ["timestamp without zone", evidence("retrieved_at" => "2026-09-22 09:00:00")],
      ["retrieved_at in the future", evidence("retrieved_at" => "2026-09-22T11:00:00Z")],
      ["valid_until before retrieved_at", evidence("valid_until" => "2026-09-22T08:00:00Z")],
      ["valid_until beyond seven days", evidence("valid_until" => "2026-09-30T09:00:00Z")],
      ["valid_until beyond 24h for preview", evidence("model" => "gpt-6-astra-preview", "valid_until" => "2026-09-23T10:00:00Z")],
      ["valid_until already expired", evidence("valid_until" => "2026-09-22T09:30:00Z")]
    ]
    rejected.each do |label, payload|
      assert_raises(Orbit::ModelEvidenceCache::ValidationError, "rejects #{label}") { cache.record(payload) }
    end
    assert(!File.exist?(cache.path), "rejected submissions never create the cache")
  end

  def test_metric_and_field_validation(tmp)
    cache = cache_at(tmp, "fields", -> { Time.utc(2026, 9, 22, 10) })
    cache.record(evidence)
    before = File.read(cache.path)

    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "empty metrics rejected") do
      cache.record(evidence("metrics" => {}))
    end
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "metric without unit or basis rejected") do
      cache.record(evidence("metrics" => { "speed" => { "value" => 10 } }))
    end
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "non-numeric metric rejected") do
      cache.record(evidence("metrics" => { "speed" => { "value" => "fast", "unit" => "tokens/s", "basis" => "vendor" } }))
    end
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "extra metric fields rejected") do
      cache.record(evidence("metrics" => { "speed" => { "value" => 10, "unit" => "tokens/s", "basis" => "vendor", "raw" => "webpage body" } }))
    end
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "unknown entry fields rejected") do
      cache.record(evidence("page_text" => "a full webpage body"))
    end
    missing_status = evidence
    missing_status.delete("status")
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "missing status rejected") { cache.record(missing_status) }
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "unavailable without reason rejected") do
      cache.record("provider" => "kimi", "model" => "kimi-k3", "status" => "unavailable", "retrieved_at" => "2026-09-22T09:00:00Z")
    end
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "unavailable with metrics rejected") do
      cache.record("provider" => "kimi", "model" => "kimi-k3", "status" => "unavailable", "retrieved_at" => "2026-09-22T09:00:00Z",
                   "reason" => "none found", "metrics" => { "speed" => { "value" => 1, "unit" => "tokens/s", "basis" => "vendor" } })
    end

    assert_equal(before, File.read(cache.path), "rejected submissions leave the cache unchanged")
    assert(!File.read(cache.path).include?("webpage"), "web page text never reaches the cache")
    assert(!File.read(cache.path).include?("secret"), "credentials never reach the cache")
  end

  def test_atomic_write_permissions_and_fail_closed(tmp)
    cache = cache_at(tmp, "atomic", -> { Time.utc(2026, 9, 22, 10) })
    cache.record_all([evidence, evidence("model" => "gpt-6-astra")])
    assert_equal(0o600, File.stat(cache.path).mode & 0o777, "cache file is private")
    assert_equal(0o700, File.stat(File.dirname(cache.path)).mode & 0o777, "cache directory is private")
    leftovers = Dir.children(File.dirname(cache.path)) - [File.basename(cache.path), "#{File.basename(cache.path)}.lock"]
    assert_equal([], leftovers, "no temporary files remain")

    File.chmod(0o644, cache.path)
    cache.record(evidence("model" => "kimi-k3"))
    assert_equal(0o600, File.stat(cache.path).mode & 0o777, "rewrites tighten loose permissions")

    before = File.read(cache.path)
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "invalid batch rejected") do
      cache.record_all([evidence("model" => "gpt-6-astra"), evidence("model" => "broken", "retrieved_at" => "yesterday")])
    end
    assert_equal(before, File.read(cache.path), "failed batch leaves the previous cache intact")
  end

  def test_concurrent_writers_keep_every_entry(tmp)
    path = File.join(tmp, "concurrent", "cache", "model-evidence-v1.json")
    start = File.join(tmp, "concurrent", "start")
    FileUtils.mkdir_p(File.dirname(start))
    clock = -> { Time.utc(2026, 9, 22, 10) }

    pids = Array.new(6) do |index|
      Process.fork do
        sleep(0.001) until File.exist?(start)
        Orbit::ModelEvidenceCache.new(path: path, clock: clock).record(evidence("model" => "worker-#{index}"))
        exit!(0)
      end
    end
    File.write(start, "go")
    statuses = pids.map { |pid| Process.wait2(pid).last }
    assert(statuses.all?(&:success?), "every concurrent writer completed")

    cache = Orbit::ModelEvidenceCache.new(path: path, clock: clock)
    models = cache.stored_entries.map { |entry| entry["model"] }.sort
    assert_equal(Array.new(6) { |index| "worker-#{index}" }.sort, models, "every concurrent writer keeps its entry")
    assert_equal(0o600, File.stat("#{path}.lock").mode & 0o777, "lock file is private")
  end

  def test_over_limit_write_is_rejected_without_touching_cache(tmp)
    cache = cache_at(tmp, "size", -> { Time.utc(2026, 9, 22, 10) })
    filler = evidence("sources" => Array.new(5) { |index| "https://example.com/report-#{index}?#{'x' * 2000}" })
    previous = nil
    stored = 0
    failure = nil
    loop do
      previous = File.read(cache.path) if File.exist?(cache.path)
      begin
        cache.record(filler.merge("model" => "filler-#{stored}"))
        stored += 1
      rescue Orbit::ModelEvidenceCache::Error => error
        failure = error
        break
      end
      raise("cache did not reach the #{Orbit::ModelEvidenceCache::MAX_FILE_BYTES}-byte limit") if stored > 60
    end

    assert(failure, "write beyond the file limit is rejected")
    assert_equal(previous, File.read(cache.path), "rejected write leaves the previous cache intact")
    assert_equal(stored, cache.stored_entries.length, "rejected entry was not stored")

    cache.record(evidence("model" => "filler-0", "sources" => ["https://example.com/small"]))
    assert_equal(["https://example.com/small"], cache.lookup(provider: "opencode-go", model: "filler-0")["sources"],
                 "a later write succeeds after the rejected one released the lock")
  end

  def test_corrupt_cache_fails_closed(tmp)
    cache = cache_at(tmp, "corrupt", -> { Time.utc(2026, 9, 22, 10) })
    FileUtils.mkdir_p(File.dirname(cache.path))
    File.write(cache.path, "{ not json")

    assert_raises(Orbit::ModelEvidenceCache::Error, "lookup surfaces corruption") do
      cache.lookup(provider: "opencode-go", model: "deepseek-v4.8")
    end
    assert_raises(Orbit::ModelEvidenceCache::Error, "record does not overwrite corruption") { cache.record(evidence) }
    assert_equal("{ not json", File.read(cache.path), "corrupt cache is preserved for the operator")
  end

  def evidence(overrides = {})
    {
      "provider" => "opencode-go",
      "model" => "deepseek-v4.8",
      "reasoning" => "default",
      "status" => "evidence",
      "retrieved_at" => "2026-09-22T09:00:00Z",
      "sources" => ["https://artificialanalysis.ai/models"],
      "metrics" => {
        "output_tokens_per_second" => { "value" => 120.5, "unit" => "tokens/s", "basis" => "Artificial Analysis median" }
      }
    }.merge(overrides)
  end

  def cache_at(tmp, name, clock)
    Orbit::ModelEvidenceCache.new(path: File.join(tmp, name, "cache", "model-evidence-v1.json"), clock: clock)
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
    rescue error_class
      return
    end
    raise("assertion failed: expected #{message}")
  end
end

ModelEvidenceCacheTest.run
