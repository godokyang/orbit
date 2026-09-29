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
      test_cross_identity_comparison_metrics_are_rejected(tmp)
      test_billing_route_identity_and_lookup(tmp)
      test_legacy_selection_and_resource_metrics_are_rejected(tmp)
      test_cost_tier_is_no_longer_a_capability_fact(tmp)
      test_quality_measurement_date_and_method(tmp)
      test_legacy_history_is_stripped_on_read(tmp)
      test_legacy_route_less_entry_is_unknown(tmp)
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
    assert_equal(0.8, hit.dig("metrics", "quality_reasoning", "value"), "metric value preserved")
    assert_equal("score", hit.dig("metrics", "quality_reasoning", "unit"), "metric unit preserved")
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

  # A `comparison.*` metric asserts how the submitter compares with another
  # identity; it is not a measurement of this model and goes stale when either
  # identity changes. Submission must reject it outright.
  def test_cross_identity_comparison_metrics_are_rejected(tmp)
    cache = cache_at(tmp, "comparison", -> { Time.utc(2026, 9, 22, 10) })
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "cross-identity comparison metric rejected") do
      cache.record(evidence("metrics" => {
        "comparison.identity_offset" => { "value" => 0, "unit" => "n/a", "basis" => "Root and candidate are the same model" }
      }))
    end
    assert(cache.lookup(provider: "opencode-go", model: "deepseek-v4.8", reasoning: "default").nil?,
           "a rejected submission leaves the cache empty")
    stored = cache.record(evidence)
    assert_equal(0.8, stored.dig("metrics", "quality_reasoning", "value"),
                 "plain per-model quality measurements still record")
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
        "quality_reasoning" => { "value" => 0.8, "unit" => "score", "basis" => "Artificial Analysis median" }
      }
    }.merge(overrides)
  end

  # Billing route is part of the identity: an omitted route means typed
  # unknown, an explicit direct_api lookup selects only its own entry, and the
  # two routes coexist for the same model.
  def test_billing_route_identity_and_lookup(tmp)
    now = Time.utc(2026, 9, 22, 10)
    cache = cache_at(tmp, "routes", -> { now })
    cache.record(evidence("billing_route" => "unknown"))
    cache.record(evidence("billing_route" => "direct_api"))

    unknown = cache.lookup(provider: "opencode-go", model: "deepseek-v4.8")
    assert_equal("unknown", unknown["billing_route"], "an omitted route reads the typed unknown entry")
    direct = cache.lookup(provider: "opencode-go", model: "deepseek-v4.8", billing_route: "direct_api")
    assert_equal("direct_api", direct["billing_route"], "an explicit route selects its own entry")
    assert_equal(2, cache.stored_entries.length, "distinct routes coexist as distinct identities")
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "an untyped route is rejected") do
      cache.record(evidence("billing_route" => "reseller"))
    end
  end

  # 审计 C04: a time, speed or local-sample metric and a route price are not
  # capability measurements of this model. Route prices live in the independent
  # RouteResourceFacts layer; submitting them here is rejected outright.
  def test_legacy_selection_and_resource_metrics_are_rejected(tmp)
    cache = cache_at(tmp, "legacy-metrics", -> { Time.utc(2026, 9, 22, 10) })
    %w[speed.tokens_per_second latency_ms elapsed_seconds local_sample_latency_ms end_to_end_seconds
       throughput tokens_per_second].each do |name|
      assert_raises(Orbit::ModelEvidenceCache::ValidationError, "rejects metric #{name}") do
        cache.record(evidence("metrics" => { name => { "value" => 1.0, "unit" => "u", "basis" => "vendor" } }))
      end
    end
    %w[cost.input_price cost.output_price quota.included_tokens quota.monthly_allowance].each do |name|
      assert_raises(Orbit::ModelEvidenceCache::ValidationError, "rejects price metric #{name}") do
        cache.record(evidence("metrics" => { name => { "value" => 1.0, "unit" => "USD", "basis" => "vendor" } }))
      end
    end
    assert(!File.exist?(cache.path), "rejected submissions never create the cache")
    assert(Orbit::ModelEvidenceCache.legacy_selection_metric?("local_sample_latency_ms") &&
           Orbit::ModelEvidenceCache.legacy_selection_metric?("end_to_end_seconds") &&
           !Orbit::ModelEvidenceCache.legacy_selection_metric?("quality_reasoning") &&
           Orbit::ModelEvidenceCache.resource_metric?("quota.monthly_allowance") &&
           !Orbit::ModelEvidenceCache.resource_metric?("coding_index"),
           "the submission gate names exactly the legacy selection and price fields")
  end

  # The old coarse cost tier and its numeric cost gate are gone: a price is a
  # resource fact, so a submission carrying one is refused rather than stored as
  # evidence of model quality.
  def test_cost_tier_is_no_longer_a_capability_fact(tmp)
    cache = cache_at(tmp, "no-cost-tier", -> { Time.utc(2026, 9, 22, 10) })
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "cost_tier is no longer accepted") do
      cache.record(evidence("cost_tier" => { "band" => "high", "confidence" => "low", "basis" => "vendor list" }))
    end
    assert_raises(Orbit::ModelEvidenceCache::ValidationError, "cost_tier on unavailable is rejected") do
      cache.record("provider" => "kimi", "model" => "kimi-k3", "status" => "unavailable",
                   "retrieved_at" => "2026-09-22T09:00:00Z", "reason" => "no quote",
                   "cost_tier" => { "band" => "low", "confidence" => "low", "basis" => "guess" })
    end
    assert(!Orbit::ModelEvidenceCache.respond_to?(:numeric_metric?) &&
           !Orbit::ModelEvidenceCache.respond_to?(:route_metric_prefix),
           "the old numeric cost gate is removed rather than kept as a compatibility layer")
    stored = cache.record(evidence)
    assert(!stored.key?("cost_tier"), "no tier is derived or defaulted")
  end

  # A quality entry may carry the measurement date of its values and the method
  # version that produced them. Both are optional; an omitted one stays unknown
  # and the retrieval date never substitutes for a measurement date.
  def test_quality_measurement_date_and_method(tmp)
    cache = cache_at(tmp, "measured", -> { Time.utc(2026, 9, 22, 10) })
    stored = cache.record(evidence("measured_at" => "2026-09-20T00:00:00Z", "method_version" => "aa-intelligence-2026-08"))
    assert_equal("2026-09-20T00:00:00Z", stored["measured_at"], "the measurement date is stored as submitted")
    assert_equal("aa-intelligence-2026-08", stored["method_version"], "the method version is stored as submitted")
    same_instant = cache.record(evidence("model" => "same-instant", "measured_at" => "2026-09-22T09:00:00Z"))
    assert_equal("2026-09-22T09:00:00Z", same_instant["measured_at"], "a measurement at the retrieval instant is allowed")

    omitted = cache.record(evidence("model" => "no-date"))
    assert(!omitted.key?("measured_at") && !omitted.key?("method_version"),
           "an omitted date or method stays unknown instead of being defaulted")

    rejected = [
      ["measured_at after retrieved_at", evidence("model" => "late", "measured_at" => "2026-09-22T09:00:01Z")],
      ["measured_at in the future", evidence("model" => "future", "measured_at" => "2026-09-23T00:00:00Z")],
      ["measured_at without a zone", evidence("model" => "nozone", "measured_at" => "2026-09-20 00:00:00")],
      ["blank method_version", evidence("model" => "blank", "method_version" => "  ")],
      ["method_version too long", evidence("model" => "long", "method_version" => "v" * 200)]
    ]
    rejected.each do |label, payload|
      assert_raises(Orbit::ModelEvidenceCache::ValidationError, "rejects #{label}") { cache.record(payload) }
    end
  end

  # History stays exactly as stored; the read path strips the fields that are no
  # longer capability evidence and then validates the remaining quality fields in
  # full. An entry with nothing meaningful left is not a quality hit.
  def test_legacy_history_is_stripped_on_read(tmp)
    path = File.join(tmp, "history", "cache", "model-evidence-v1.json")
    FileUtils.mkdir_p(File.dirname(path))
    base = { "provider" => "legacy", "reasoning" => "unknown", "billing_route" => "unknown",
             "status" => "evidence", "retrieved_at" => "2026-09-22T09:00:00Z",
             "valid_until" => "2026-09-29T09:00:00Z", "sources" => ["https://vendor.example/evidence"] }
    kept = base.merge("model" => "mixed", "metrics" => {
      "quality_reasoning" => { "value" => 0.7, "unit" => "score", "basis" => "vendor" },
      "output_tokens_per_second" => { "value" => 120.0, "unit" => "tok/s", "basis" => "vendor" },
      "cost.input_price" => { "value" => 0.8, "unit" => "USD/Mtok", "basis" => "vendor" }
    }, "cost_tier" => { "band" => "low", "confidence" => "low", "basis" => "legacy tier" })
    legacy_only = base.merge("model" => "legacy-only", "metrics" => {
      "local_sample_latency_ms" => { "value" => 300.0, "unit" => "ms", "basis" => "local sample" }
    })
    broken = base.merge("model" => "broken", "sources" => ["not-a-url"],
                        "metrics" => { "quality_reasoning" => { "value" => 0.7, "unit" => "score", "basis" => "vendor" } })
    File.write(path, JSON.pretty_generate("schema_version" => Orbit::ModelEvidenceCache::SCHEMA_VERSION,
                                          "entries" => [kept, legacy_only, broken]))
    cache = Orbit::ModelEvidenceCache.new(path: path, clock: -> { Time.utc(2026, 9, 22, 10) })

    entry = cache.lookup(provider: "legacy", model: "mixed", reasoning: "unknown")
    assert_equal(["quality_reasoning"], entry["metrics"].keys,
                 "legacy time and price metrics are stripped before the remaining fact is validated")
    assert(!entry.key?("cost_tier"), "a legacy cost tier is stripped on read")
    assert_equal("2026-09-22T09:00:00Z", entry["retrieved_at"], "the remaining quality fact keeps its own dates")
    assert_equal(3, cache.stored_entries.length, "the stored history itself is unchanged")
    assert(cache.stored_entries.first.key?("cost_tier") &&
           cache.stored_entries.first.dig("metrics", "output_tokens_per_second").is_a?(Hash),
           "raw history keeps its legacy fields for audit")
    assert(cache.lookup(provider: "legacy", model: "legacy-only", reasoning: "unknown").nil?,
           "an entry with no meaningful measurement left is not a quality hit")
    assert(cache.lookup(provider: "legacy", model: "broken", reasoning: "unknown").nil?,
           "stripping never skips validating the remaining sources and dates")
    assert(cache.lookup(provider: "legacy", model: "mixed", reasoning: "unknown")
                 .dig("metrics", "quality_reasoning", "value") == 0.7,
           "a historical entry with a meaningful measurement is still a quality hit")
  end

  # Legacy stored entries without the route field remain readable as the typed
  # unknown identity and are never accepted as direct_api facts.
  def test_legacy_route_less_entry_is_unknown(tmp)
    now = Time.utc(2026, 9, 22, 10)
    cache = cache_at(tmp, "legacy", -> { now })
    FileUtils.mkdir_p(File.dirname(cache.path))
    File.write(cache.path, JSON.generate("schema_version" => Orbit::ModelEvidenceCache::SCHEMA_VERSION,
                                         "entries" => [evidence.merge("valid_until" => "2026-09-29T09:00:00Z")]))
    entry = cache.lookup(provider: "opencode-go", model: "deepseek-v4.8")
    assert(entry, "a legacy entry is still readable")
    assert_equal("unknown", Orbit::ModelEvidenceCache.billing_route(entry["billing_route"]),
                 "a legacy entry reads as the typed unknown route")
    assert_equal(nil, cache.lookup(provider: "opencode-go", model: "deepseek-v4.8", billing_route: "direct_api"),
                 "a direct_api lookup never consumes a legacy route-less entry")
    changed = evidence.merge("valid_until" => "2026-09-29T09:00:00Z", "sources" => ["file:///unverified"])
    File.write(cache.path, JSON.generate("schema_version" => Orbit::ModelEvidenceCache::SCHEMA_VERSION,
                                         "entries" => [changed]))
    assert_equal(nil, cache.lookup(provider: "opencode-go", model: "deepseek-v4.8"),
                 "an edited cache cannot bypass source validation at read time")
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
