# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/orbit/openrouter_model_overview"
require_relative "../lib/orbit/openrouter_setup"

module OpenRouterModelOverviewTest
  ENTRY = File.expand_path("../scripts/orbit", __dir__)
  NOW = Time.utc(2026, 9, 29, 12)

  module_function

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-openrouter-overview") do |tmp|
      test_setup_writes_private_env_and_cli_route(tmp)
      test_missing_key_and_disabled_project_stay_offline(tmp)
      test_first_fetch_reuse_ttl_and_single_refresh(tmp)
      test_http_failure_backoff_and_new_key_recovery(tmp)
      test_mapping_identity_validation_and_prior_bounds(tmp)
      test_lookup_target_alias_drift_and_benchmark_gates(tmp)
      test_task_indices_and_unknown_measurement_date(tmp)
      test_old_snapshot_is_not_reused_as_v3(tmp)
      test_benchmark_join_is_exact_and_keeps_variants_separate(tmp)
      test_unverifiable_benchmark_matches_supply_no_prior(tmp)
      test_benchmark_failure_never_stores_half_a_snapshot(tmp)
      test_pagination_completeness(tmp)
      test_status_diagnostics_are_read_only(tmp)
      test_mapping_provenance(tmp)
      test_base_model_match_reuses_capability_across_channels(tmp)
      test_base_model_match_stays_bounded_and_keeps_audited_rules(tmp)
      test_prior_sources_keep_benchmark_provenance_under_the_cap(tmp)
    end
    puts("OPENROUTER_MODEL_OVERVIEW_TEST_PASS assertions=#{@assertions}")
  end

  # Any unexpected catalog request fails loudly instead of touching the
  # network, so the zero-request guarantees hold by construction.
  class FakeHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses.dup
      @requests = []
    end

    def call(url:, headers:)
      @requests << { "url" => url, "authorization" => headers["Authorization"] }
      response = @responses.shift
      raise "unexpected OpenRouter request" if response.nil?

      [response[0], response[1]]
    end
  end

  def test_setup_writes_private_env_and_cli_route(tmp)
    home = File.join(tmp, "home")
    shell = { "HOME" => home, "SHELL" => "/bin/zsh", "ZDOTDIR" => home }
    Orbit::OpenRouterSetup.configure("or-key-setup", env: shell, home: home)
    env_file = File.join(home, ".config", "openrouter", "env")
    assert(File.read(env_file).include?("export OPENROUTER_API_KEY=or-key-setup") &&
           File.stat(env_file).mode & 0o777 == 0o600 &&
           File.stat(File.dirname(env_file)).mode & 0o777 == 0o700,
           "the saved key and its containing directory are private")
    assert(File.read(File.join(home, ".zshrc")).include?('if [ -z "${OPENROUTER_API_KEY:-}" ]'),
           "an existing environment variable wins over the file")
    raised = begin
      Orbit::OpenRouterSetup.configure("a\nb")
      false
    rescue ArgumentError
      true
    end
    assert(raised, "multiline key input is rejected")

    cli_env = shell.merge("XDG_CONFIG_HOME" => File.join(tmp, "xdg"), "XDG_CACHE_HOME" => tmp)
    out, err, status = Open3.capture3(cli_env, RbConfig.ruby, "--disable-gems", ENTRY,
                                      "openrouter", "setup", chdir: tmp, stdin_data: "or-cli-key\n")
    assert(status.success? && !(out + err).include?("or-cli-key"), "the CLI succeeds without printing the key")
    assert(File.read(File.join(tmp, "xdg", "openrouter", "env")).include?("or-cli-key"),
           "the CLI stores the key in the private env file")
  end

  def test_missing_key_and_disabled_project_stay_offline(tmp)
    project = File.join(tmp, "project-disabled")
    FileUtils.mkdir_p(File.join(project, ".orbit"))
    File.write(File.join(project, ".env"), "OPENROUTER_API_KEY=or-dotenv-key\n")

    configured = overview(tmp, "gate", http: FakeHttp.new([
                             [200, models_body([row("deepseek/deepseek-v4.1-flash")])],
                             [200, benchmarks_body([variant("deepseek/deepseek-v4.1-flash")])]]))
    write_map(configured.map_path, [mapping])
    assert_equal("fresh", configured.refresh(project_root: project).fetch("status"), "a configured key fetches once")
    assert_equal("fresh", configured.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project).fetch("status"),
                 "the mapped prior resolves for the configured key")

    no_key = overview(tmp, "gate", env: { "OPENROUTER_API_KEY" => nil }, http: FakeHttp.new([]))
    assert_equal("not_configured", no_key.refresh(project_root: project).fetch("status"), "no key means no request")
    assert_equal("not_configured", no_key.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project).fetch("status"),
                 "a project .env key is not borrowed and cached priors die without the key")

    File.write(File.join(project, ".orbit", "jev-disabled"), "")
    gated = overview(tmp, "gate", http: FakeHttp.new([]))
    assert_equal("disabled", gated.refresh(project_root: project).fetch("status"), "refresh is gated by the project")
    assert_equal("disabled", gated.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project).fetch("status"),
                 "lookup consumes nothing while outbound is disabled")
  end

  def test_first_fetch_reuse_ttl_and_single_refresh(tmp)
    project = tmp
    now = NOW
    response = [[200, models_body([row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715")])],
                [200, benchmarks_body([variant("moonshotai/kimi-k3-20260715")])]]
    http = FakeHttp.new(response + response)
    instance = overview(tmp, "ttl", clock: -> { now }, http: http)
    assert_equal("fresh", instance.refresh(project_root: project).fetch("status"), "the first fetch stores a snapshot")

    now = NOW + 71 * 60 * 60
    assert_equal("fresh", instance.refresh(project_root: project).fetch("status"), "inside 72h the snapshot is reused")
    assert_equal("fresh", overview(tmp, "ttl", clock: -> { now }, http: FakeHttp.new([]))
                    .refresh(project_root: project).fetch("status"), "a second process reuses the snapshot")
    assert_equal(2, http.requests.length, "one refresh is exactly one catalogue plus one benchmark request")
    assert(http.requests.map { |request| request["url"] }.any? { |url| url.include?("/benchmarks?source=artificial-analysis") },
           "the benchmark source is requested separately from the catalogue")

    now = NOW + 72 * 60 * 60 + 1
    assert_equal("stale", instance.lookup(model: "moonshotai/kimi-k3", project_root: project).fetch("status"),
                 "an expired snapshot is not a prior")
    assert_equal("fresh", instance.refresh(project_root: project).fetch("status"), "expiry triggers a refetch")
    assert_equal(4, http.requests.length, "lookup stayed offline and expiry fetched exactly once")

    content = File.read(instance.cache_path)
    assert(!content.include?("or-test-key-1") && File.stat(instance.cache_path).mode & 0o777 == 0o600,
           "the snapshot is private and key-free")
  end

  def test_http_failure_backoff_and_new_key_recovery(tmp)
    project = tmp
    http = FakeHttp.new([[401, '{"error":{"message":"invalid key"}}'],
                         [200, models_body([row("deepseek/deepseek-v4.1-flash")])],
                         [200, benchmarks_body([variant("deepseek/deepseek-v4.1-flash")])]])
    broken = overview(tmp, "auth", clock: -> { NOW }, http: http)
    write_map(broken.map_path, [mapping])
    result = broken.refresh(project_root: project)
    assert_equal("error", result.fetch("status"), "an HTTP failure is reported")
    assert(result.fetch("error").include?("401") && !result.fetch("error").include?("or-test-key-1"),
           "the failure reason carries no key material")
    assert_equal("stale", broken.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project).fetch("status"),
                 "a failed refresh leaves no prior")
    assert_equal("backoff", broken.refresh(project_root: project).fetch("status"), "an immediate retry is backed off")
    assert_equal(1, http.requests.length, "backoff performs no request")

    corrected = overview(tmp, "auth", env: { "OPENROUTER_API_KEY" => "or-test-key-2" }, clock: -> { NOW }, http: http)
    assert_equal("fresh", corrected.refresh(project_root: project).fetch("status"),
                 "a corrected key retries immediately instead of inheriting the old key's backoff")
    assert_equal("fresh", corrected.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project).fetch("status"),
                 "the refreshed snapshot serves the corrected key")
    assert_equal("stale", broken.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project).fetch("status"),
                 "the old account's snapshot is never a prior for the previous key")
  end

  def test_mapping_identity_validation_and_prior_bounds(tmp)
    project = tmp
    http = FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash"),
                                            row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715")])],
                         [200, benchmarks_body([variant("deepseek/deepseek-v4.1-flash", coding: 56.2, agentic: nil),
                                                variant("moonshotai/kimi-k3-20260715", coding: 76.2)])]])
    instance = overview(tmp, "maps", http: http)
    instance.refresh(project_root: project)

    write_map(instance.map_path, [
      mapping,
      mapping("provider" => "kimi-code", "model" => "k3-256k", "reasoning" => "high",
              "openrouter_id" => "moonshotai/kimi-k3", "canonical_slug" => "moonshotai/kimi-k3-20260715"),
      mapping("model" => "no-sources", "sources" => []),
    ])
    prior = instance.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project,
                            indices: %w[coding_index agentic_index]).fetch("prior")
    assert_equal(56.2, prior.fetch("coding_index"), "the coding index is carried through")
    assert_equal(false, prior.key?("agentic_index"), "an unavailable requested index is not supplied as a score")
    assert(prior.fetch("sources").length <= 5 &&
           prior.fetch("sources").include?("https://vendor.example/deepseek-v4.1-flash") &&
           prior.fetch("sources").include?("https://openrouter.ai/api/v1/models") &&
           prior.fetch("reasoning_note").include?("推理变体未核实"),
           "sources stay bounded and an unknown reasoning variant is labeled weak")

    assert_equal("fresh", instance.lookup(model: "kimi-code/k3-256k", reasoning: "high", project_root: project).fetch("status"),
                 "a concrete reasoning matching the audited variant resolves")
    assert_equal("unmapped", instance.lookup(model: "kimi-code/k3-256k", reasoning: "low", project_root: project).fetch("status"),
                 "a conflicting concrete variant invalidates the mapping")
    assert_equal("unmapped", instance.lookup(model: "opencode-go/deepseek-v4.1-flash", billing_route: "direct_api",
                                             project_root: project).fetch("status"), "billing_route matches exactly")
    assert_equal("unmapped", instance.lookup(model: "opencode-go/no-sources", project_root: project).fetch("status"),
                 "a mapping without first-party sources cannot become a prior")
  end

  def test_lookup_target_alias_drift_and_benchmark_gates(tmp)
    project = tmp
    rows = [
      row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715"),
      row("zhipu/glm-5.3-flashx"),
      row("deepseek/deepseek-v4.1-flash"),
      row("~deepseek/deepseek-v4-flash-latest", slug: "deepseek/deepseek-v4-flash")
    ]
    instance = overview(tmp, "gates", http: FakeHttp.new([
                          [200, models_body(rows)],
                          [200, benchmarks_body([variant("moonshotai/kimi-k3-20260715", coding: 76.2, agentic: 50.0),
                                                 variant("deepseek/deepseek-v4.1-flash")])]]))
    write_map(instance.map_path, [
      mapping("provider" => "kimi-code", "model" => "k3-256k", "openrouter_id" => "moonshotai/kimi-k3",
              "canonical_slug" => "moonshotai/kimi-k3-20260715"),
      mapping("provider" => "zhipu-coding-plan", "model" => "glm-5.3-flashx", "openrouter_id" => "zhipu/glm-5.3-flashx",
              "canonical_slug" => "zhipu/glm-5.3-flashx"),
      mapping("provider" => "opencode-go", "model" => "deepseek-v4-flash", "openrouter_id" => "deepseek/deepseek-v4-flash",
              "canonical_slug" => "deepseek/deepseek-v4-flash"),
      mapping("provider" => "opencode-go", "model" => "drifted", "openrouter_id" => "deepseek/deepseek-v4.1-flash",
              "canonical_slug" => "deepseek/deepseek-v4.1-flash-old")
    ])
    instance.refresh(project_root: project)

    kimi = instance.lookup(model: "kimi-code/k3-256k", project_root: project, indices: ["coding_index"])
    assert_equal("fresh", kimi.fetch("status"), "the mapped canonical row resolves through its real catalog id")
    assert_equal(76.2, kimi.fetch("prior").fetch("coding_index"), "the audited coding index is carried through")
    assert_equal("no_benchmark", instance.lookup(model: "zhipu-coding-plan/glm-5.3-flashx", project_root: project).fetch("status"),
                 "a null coding index never becomes a capability")
    assert_equal("unavailable", instance.lookup(model: "opencode-go/deepseek-v4-flash", project_root: project).fetch("status"),
                 "a tilde alias row is skipped and never resolves a mapping")
    assert_equal("unavailable", instance.lookup(model: "opencode-go/drifted", project_root: project).fetch("status"),
                 "canonical drift suspends the mapping instead of silently re-pointing it")
  end

  def test_task_indices_and_unknown_measurement_date(tmp)
    rows = [row("example/agentic-only"), row("example/analysis-only")]
    instance = overview(tmp, "task-indices", http: FakeHttp.new([
                          [200, models_body(rows)],
                          [200, benchmarks_body([variant("example/agentic-only", coding: nil, agentic: 17.0),
                                                 variant("example/analysis-only", coding: nil, agentic: nil,
                                                         intelligence: 31.0)])]]))
    write_map(instance.map_path, rows.map do |model|
      mapping("provider" => "example", "model" => model["id"].split("/", 2).last,
              "openrouter_id" => model["id"], "canonical_slug" => model["canonical_slug"])
    end)
    instance.refresh(project_root: tmp)
    facts_only = instance.lookup(model: "example/agentic-only", project_root: tmp)
    assert_equal("fresh", facts_only["status"], "agentic-only data is not blocked by null coding")
    assert_equal(nil, facts_only["prior"], "an unclassified task gets facts without a guessed quality prior")
    facts = facts_only.fetch("facts")
    assert_equal("example/agentic-only", facts["id"], "the real catalog id is retained")
    assert_equal(8192, facts["context_length"], "catalog context remains a catalog fact")
    assert_equal(["text"], facts.dig("architecture", "input_modalities"), "input modality facts are retained")
    assert_equal(["tools"], facts["supported_parameters"], "supported parameters remain catalog facts")
    assert_equal(nil, facts["measurement_date"], "fetch time is never substituted for benchmark measurement time")
    assert_equal("unknown", facts["measurement_date_status"], "measurement freshness is explicitly unknown")

    agentic = instance.lookup(model: "example/agentic-only", project_root: tmp, indices: ["agentic_index"])
    assert_equal(17.0, agentic.dig("prior", "agentic_index"), "the requested agentic index can form a weak task prior")
    assert_equal(["agentic_index"], agentic.dig("prior", "relevant_indices"), "the projection records the requested task index")
    assert_equal("no_benchmark", instance.lookup(model: "example/agentic-only", project_root: tmp,
                                                  indices: ["coding_index"])["status"],
                 "agentic does not silently fill a missing coding requirement")
    analysis = instance.lookup(model: "example/analysis-only", project_root: tmp, indices: ["intelligence_index"])
    assert_equal(31.0, analysis.dig("prior", "intelligence_index"), "intelligence is normalized and can be explicitly selected")
    assert_equal(false, analysis["prior"].key?("coding_index"), "intelligence never becomes coding")
    dated = instance.lookup(model: "example/agentic-only", project_root: tmp, indices: ["agentic_index"],
                            require_measurement_date: true)
    assert_equal("measurement_date_unknown", dated["status"], "an explicit measurement-date requirement cannot pass on fetch time")
    assert_equal(nil, dated["prior"], "unknown measurement date withholds the task prior when a date is required")
    assert(dated["facts"], "facts remain visible when task qualification fails")
  end

  def test_old_snapshot_is_not_reused_as_v3(tmp)
    response = [[200, models_body([row("deepseek/deepseek-v4.1-flash")])],
                [200, benchmarks_body([variant("deepseek/deepseek-v4.1-flash", intelligence: 23.0)])]]
    http = FakeHttp.new(response + response)
    instance = overview(tmp, "schema-change", http: http)
    write_map(instance.map_path, [mapping])
    instance.refresh(project_root: tmp)
    old = JSON.parse(File.read(instance.cache_path))
    old["schema_version"] = "orbit-openrouter-model-overview-v1"
    File.write(instance.cache_path, JSON.generate(old))
    assert_equal("stale", instance.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: tmp)["status"],
                 "old snapshots are not promoted into the intelligence-aware schema")
    instance.refresh(project_root: tmp)
    assert_equal(4, http.requests.length, "the new schema requires a real refresh instead of invented old fields")
    assert_equal(23.0, instance.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: tmp).dig("facts", "intelligence_index"),
                 "the refreshed schema keeps the new index as a fact")
  end

  def test_pagination_completeness(tmp)
    project = tmp
    http = FakeHttp.new([[200, models_body([row("a/one"), row("a/two")], next_link: "/api/v1/models?offset=2", total_count: 3)],
                         [200, models_body([row("a/three")], total_count: 3)],
                         [200, benchmarks_body([variant("a/one")])]])
    instance = overview(tmp, "pages", http: http)
    assert_equal(3, instance.refresh(project_root: project).fetch("model_count"),
                 "pagination links are followed to the full snapshot")

    partial = overview(tmp, "pages-partial", http: FakeHttp.new([[200, models_body([row("a/a")], total_count: 5)]]))
    assert_equal("error", partial.refresh(project_root: project).fetch("status"), "a partial list is not mistaken for complete")
    offsite = overview(tmp, "pages-offsite",
                       http: FakeHttp.new([[200, models_body([row("a/a")], next_link: "https://evil.example/m")]]))
    assert_equal("error", offsite.refresh(project_root: project).fetch("status"), "off-site pagination links are refused")
  end

  # The benchmark join is exact and shape-preserving: the row's own
  # model_permaslug must equal the catalogue row's canonical_slug or its exact
  # id, one measured variant may carry top-level scores, several variants stay
  # separate, and this endpoint's pricing never becomes a stored fact.
  def test_benchmark_join_is_exact_and_keeps_variants_separate(tmp)
    project = tmp
    http = FakeHttp.new([
      [200, models_body([row("a/one", slug: "a/one-20260101"),
                         row("a/two", slug: "a/two-20260101"),
                         row("a/four", slug: "a/four-20260101"),
                         row("a/five", slug: "a/five-20260101")])],
      [200, benchmarks_body([variant("a/one-20260101", display_name: "One", coding: 61.5, agentic: nil, intelligence: 55.0),
                             variant("a/two-20260101", display_name: "Two (max)", coding: 70.0),
                             variant("a/two-20260101", display_name: "Two (low)", coding: 64.0),
                             variant("a/five", display_name: "By id", coding: 66.0),
                             variant("a/four-20260101", display_name: "Arena", coding: 98.0, source: "design-arena")])]
    ])
    instance = overview(tmp, "join", http: http)
    write_map(instance.map_path, [mapping("provider" => "a", "model" => "one", "openrouter_id" => "a/one",
                                          "canonical_slug" => "a/one-20260101", "sources" => ["https://a.example/one"]),
                                  mapping("provider" => "a", "model" => "two", "openrouter_id" => "a/two",
                                          "canonical_slug" => "a/two-20260101", "sources" => ["https://a.example/two"]),
                                  mapping("provider" => "a", "model" => "four", "openrouter_id" => "a/four",
                                          "canonical_slug" => "a/four-20260101", "sources" => ["https://a.example/four"]),
                                  mapping("provider" => "a", "model" => "five", "openrouter_id" => "a/five",
                                          "canonical_slug" => "a/five-20260101", "sources" => ["https://a.example/five"])])
    instance.refresh(project_root: project)

    one = instance.lookup(model: "a/one", project_root: project,
                          indices: %w[coding_index agentic_index intelligence_index])
    assert_equal("fresh", one["status"], "one exact benchmark row resolves through its canonical slug")
    assert_equal(61.5, one.dig("prior", "coding_index"), "a single measured variant carries its own score")
    assert_equal("One", one.dig("prior", "benchmark_display_name"), "the variant that supplied the score is named")
    assert_equal(%w[coding_index intelligence_index], one.dig("prior", "relevant_indices"),
                 "an index missing from that variant is not supplied as a score")
    assert(one.dig("prior", "benchmark_variants").none? { |entry| entry.key?("pricing") },
           "benchmark pricing is never stored as a capability fact")
    assert_equal("2026-06-03T12:00:00Z", one.dig("prior", "benchmark_as_of"),
                 "the dataset snapshot date is carried as a dataset fact, not a measurement date")
    assert_equal("unknown", one.dig("prior", "measurement_date_status"), "the measurement date stays unknown")

    two = instance.lookup(model: "a/two", project_root: project, indices: ["coding_index"])
    assert_equal(nil, two.dig("prior", "coding_index"),
                 "several reasoning variants are never collapsed to a highest or average score")
    assert_equal([["Two (max)", 70.0], ["Two (low)", 64.0]],
                 two.dig("prior", "benchmark_variants").map { |entry| [entry["display_name"], entry["coding_index"]] },
                 "each variant keeps its own display_name and index")

    five = instance.lookup(model: "a/five", project_root: project, indices: ["coding_index"])
    assert_equal("fresh", five["status"], "a benchmark row keyed by the catalogue row's exact id resolves")
    assert_equal(66.0, five.dig("prior", "coding_index"), "that exact-id match supplies its own measured variant")

    four = instance.lookup(model: "a/four", project_root: project, indices: ["coding_index"])
    assert_equal("no_benchmark", four["status"], "a non-artificial-analysis source never supplies these indices")
  end

  # An unverifiable join is a gap, not a guess: suffixed, neighbouring-version
  # and ambiguous matches supply no prior, and both lookups agreeing on one key
  # is required.
  def test_unverifiable_benchmark_matches_supply_no_prior(tmp)
    project = tmp
    http = FakeHttp.new([
      [200, models_body([row("b/one", slug: "b/one-20260101"),
                         row("b/two", slug: "b/two-20260101"),
                         row("b/three", slug: "b/three-20260101")])],
      [200, benchmarks_body([variant("b/one-20260101-preview", display_name: "Preview", coding: 71.0),
                             variant("b/one-20260102", display_name: "Next", coding: 72.0),
                             variant("b/two-20260101", display_name: "Two", coding: 65.0),
                             variant("b/three-20260101", display_name: "By slug", coding: 74.0),
                             variant("b/three", display_name: "By id", coding: 75.0)])]
    ])
    instance = overview(tmp, "join-gaps", http: http)
    write_map(instance.map_path, [mapping("provider" => "b", "model" => "one", "openrouter_id" => "b/one",
                                          "canonical_slug" => "b/one-20260101", "sources" => ["https://b.example/one"]),
                                  mapping("provider" => "b", "model" => "two", "openrouter_id" => "b/two",
                                          "canonical_slug" => "b/two-20260101", "sources" => ["https://b.example/two"]),
                                  mapping("provider" => "b", "model" => "three", "openrouter_id" => "b/three",
                                          "canonical_slug" => "b/three-20260101", "sources" => ["https://b.example/three"])])
    instance.refresh(project_root: project)

    one = instance.lookup(model: "b/one", project_root: project, indices: ["coding_index"])
    assert_equal("no_benchmark", one["status"], "a suffixed or neighbouring-version slug never supplies the index")
    assert_equal([], one.dig("facts", "benchmark_variants"), "no variant is invented for an unverified match")
    assert_equal(nil, one["prior"], "a gap is not a score")

    two = instance.lookup(model: "b/two", project_root: project, indices: ["coding_index"])
    assert_equal("fresh", two["status"], "an exact canonical-slug match still resolves next to a gap")
    assert_equal(65.0, two.dig("prior", "coding_index"), "the matching row keeps its own measured variant")

    three = instance.lookup(model: "b/three", project_root: project, indices: ["coding_index"])
    assert_equal("no_benchmark", three["status"],
                 "two exact keys pointing at different rows are ambiguous and supply no prior")
    assert_equal([], three.dig("facts", "benchmark_variants"), "an ambiguous join invents no variant")
  end

  # Both requests belong to one snapshot: a benchmark failure leaves the previous
  # snapshot untouched instead of storing half a document.
  def test_benchmark_failure_never_stores_half_a_snapshot(tmp)
    project = tmp
    http = FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash")])],
                         [429, "too many requests"]])
    instance = overview(tmp, "bench-half", http: http)
    write_map(instance.map_path, [mapping])
    result = instance.refresh(project_root: project)
    assert_equal("error", result.fetch("status"), "a benchmark failure fails the whole refresh")
    assert(result.fetch("error").include?("429"), "the failure reason names the real status")
    assert(!File.exist?(instance.cache_path) || JSON.parse(File.read(instance.cache_path))["models"].nil?,
           "no half snapshot is written")
    assert_equal("stale", instance.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project)["status"],
                 "a failed refresh leaves no prior")
  end

  def test_status_diagnostics_are_read_only(tmp)
    project = tmp
    http = FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash")])],
                         [200, benchmarks_body([variant("deepseek/deepseek-v4.1-flash")])]])
    instance = overview(tmp, "diag", http: http)
    write_map(instance.map_path, [mapping])

    instance.refresh(project_root: project)
    report = instance.status(project_root: project)
    assert_equal("fresh", report.fetch("status"), "a current snapshot reports fresh")
    assert_equal("https://openrouter.ai/api/v1/models", report.fetch("source"), "the catalog source is reported")
    assert_equal("ok", report.fetch("last_attempt"), "the last attempt outcome is reported")
    assert(report.values.none? { |value| value.to_s.include?("or-test-key-1") } && http.requests.length == 2,
           "diagnostics are key-free and never fetch")

    rotated = overview(tmp, "diag", env: { "OPENROUTER_API_KEY" => "or-test-key-2" }, http: FakeHttp.new([]))
    report = rotated.status(project_root: project)
    assert_equal("stale", report.fetch("status"), "a rotated key cannot claim the old snapshot")
    assert_equal(true, report.fetch("key_rotated"), "rotation is visible in diagnostics")

    failing = overview(tmp, "diag-err", http: FakeHttp.new([[429, "too many requests"]]))
    failing.refresh(project_root: project)
    report = failing.status(project_root: project)
    assert_equal("error", report.fetch("last_attempt"), "a failed attempt is reported")
    assert(report.fetch("last_error").include?("429"), "the last failure is visible without the key")
  end

  def test_mapping_provenance(tmp)
    project = File.join(tmp, "project-provenance")
    http = FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash")])],
                         [200, benchmarks_body([variant("deepseek/deepseek-v4.1-flash")])]])
    instance = overview(tmp, "provenance", http: http)
    write_map(instance.map_path, [mapping])
    instance.refresh(project_root: project)

    provenance = instance.mapping_provenance(model: "opencode-go/deepseek-v4.1-flash", project_root: project)
    assert_equal("2026-09-28T00:00:00Z", provenance.fetch("verified_at"), "the mapping review date is queryable")
    assert_equal("Root", provenance.fetch("verified_by"), "the mapping reviewer is queryable")
    assert_equal(["https://vendor.example/deepseek-v4.1-flash"], provenance.fetch("sources"),
                 "the mapping first-party sources are queryable")
    assert_equal("unknown", provenance.dig("mapping_identity", "billing_route"), "provenance keeps the exact identity")
    assert_equal(nil, instance.mapping_provenance(model: "opencode-go/stranger", project_root: project),
                 "an unmapped identity has no provenance")
    assert_equal(nil, instance.mapping_provenance(model: "opencode-go/deepseek-v4.1-flash",
                                                  billing_route: "direct_api", project_root: project),
                 "provenance follows the same exact route matching as lookup")

    keyless = overview(tmp, "provenance-keyless", env: { "OPENROUTER_API_KEY" => nil }, http: FakeHttp.new([]))
    assert_equal(nil, keyless.mapping_provenance(model: "opencode-go/deepseek-v4.1-flash", project_root: project),
                 "no key closes the provenance gate")

    FileUtils.mkdir_p(File.join(project, ".orbit"))
    File.write(File.join(project, ".orbit", "jev-disabled"), "")
    assert_equal(nil, instance.mapping_provenance(model: "opencode-go/deepseek-v4.1-flash", project_root: project),
                 "a disabled project closes the provenance gate")
  end

  # With a full five-source audited mapping the unbounded list would exceed
  # MAX_SOURCES; the measured benchmark site and its dedicated endpoint must
  # survive truncation ahead of mapping sources and the catalogue endpoint.
  def test_prior_sources_keep_benchmark_provenance_under_the_cap(tmp)
    project = tmp
    http = FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash")])],
                         [200, benchmarks_body([variant("deepseek/deepseek-v4.1-flash", coding: 56.2)])]])
    instance = overview(tmp, "capped-sources", http: http)
    instance.refresh(project_root: project)
    write_map(instance.map_path, [mapping("sources" => (1..5).map { |n| "https://vendor.example/source-#{n}" })])

    prior = instance.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project,
                            indices: %w[coding_index]).fetch("prior")
    sources = prior.fetch("sources")
    assert(sources.length <= 5 &&
           sources.include?("https://artificialanalysis.ai") &&
           sources.include?("https://openrouter.ai/api/v1/benchmarks?source=artificial-analysis"),
           "the benchmark source and dedicated endpoint survive the source cap")
    assert(sources.include?("https://vendor.example/source-1"),
           "audited mapping sources still fill the remaining bound")
  end

  # A concrete same-model catalogue row wins over any downgrade, and the
  # downgrade itself is labeled and never carries route-shaped facts.
  def test_base_model_match_reuses_capability_across_channels(tmp)
    project = tmp
    rows = [row("x-ai/grok-4.7-fast"), row("x-ai/grok-4.7"), row("x-ai/grok-4.8")]
    http = FakeHttp.new([[200, models_body(rows)], [200, benchmarks_body([variant("x-ai/grok-4.7-fast", coding: 61.5),
                                                                          variant("x-ai/grok-4.7", coding: 70.0),
                                                                          variant("x-ai/grok-4.8", coding: 55.0)])]])
    instance = overview(tmp, "base-match", http: http)
    write_map(instance.map_path, [mapping])
    instance.refresh(project_root: project)

    concrete = instance.lookup(model: "cursor/grok-4.7-fast", billing_route: "subscription_quota", project_root: project, indices: ["coding_index"])
    assert_equal(61.5, concrete.dig("prior", "coding_index"), "the concrete same-model row is matched before any downgrade")
    assert_equal("concrete", concrete.dig("facts", "mapping", "match"), "the concrete match is labeled")
    assert_equal(false, concrete.dig("facts", "mapping", "audited"), "a concrete row is not an audited identity")
    assert_equal("x-ai/grok-4.7-fast", concrete.dig("facts", "mapping", "matched_catalog_id"), "the matched row is named")
    assert_equal({ "provider" => "cursor", "model" => "grok-4.7-fast", "reasoning" => "unknown", "billing_route" => "subscription_quota" }, concrete.dig("facts", "mapping", "requested_identity"), "the requested identity and real route are kept")
    assert_equal(8192, concrete.dig("facts", "context_length"), "catalogue facts stay visible for the reader")
    assert_equal(nil, concrete.dig("prior", "context_length"), "the prior never presents another channel's context window")
    assert_equal(nil, concrete.dig("prior", "supported_parameters"), "the prior never presents another channel's parameters")
    assert_equal(nil, concrete.dig("facts", "mapping_identity"), "no audited identity is claimed")
    assert(!concrete.fetch("prior").fetch("sources").include?("https://vendor.example/deepseek-v4.1-flash"), "no audited source rides along")

    downgraded = instance.lookup(model: "cursor/grok-4.8-fast", project_root: project, indices: ["coding_index"])
    assert_equal("base_model", downgraded.dig("facts", "mapping", "match"), "without a concrete row the labeled downgrade applies")
    assert_equal("grok-4.8", downgraded.dig("facts", "mapping", "normalized_base_model"), "the base model is traceable")
    assert_equal(55.0, downgraded.dig("prior", "coding_index"), "the base model's index is usable")
    assert_equal("base_model", instance.mapping_provenance(model: "cursor/grok-4.8-fast", project_root: project).fetch("match"), "provenance resolves exactly like lookup")
    assert_equal(nil, instance.mapping_provenance(model: "opencode-go/deepseek-v4.1-flash", project_root: project), "an audited identity whose catalogue row is absent resolves unavailable in both paths")
    assert_equal("unmapped", instance.lookup(model: "cursor/grok-4", project_root: project).fetch("status"), "a different generation never borrows grok-4.7")
    assert_equal("no_catalog_row_for_base_model", instance.lookup(model: "cursor/stranger", project_root: project).dig("mapping", "reason"), "an unknown base model states why nothing resolved")
  end

  # Named suffixes stay concrete, ambiguity stays unresolved, and the audited
  # variant and route rules are unchanged.
  def test_base_model_match_stays_bounded_and_keeps_audited_rules(tmp)
    project = tmp
    rows = [row("zhipu/glm-5.3-flashx"), row("other/glm-5.3-flashx"), row("x-ai/grok-4.7", slug: "x-ai/grok-4.7-20260101"),
            row("x-ai/grok-4.7-preview", slug: "x-ai/grok-4.7-20260202")]
    entry = mapping("provider" => "kimi-code", "model" => "k3-256k", "reasoning" => "high", "openrouter_id" => "moonshotai/kimi-k3", "canonical_slug" => "moonshotai/kimi-k3-20260715")
    instance = overview(tmp, "base-guards", http: FakeHttp.new([[200, models_body(rows)], [200, benchmarks_body([variant("zhipu/glm-5.3-flashx", coding: 70.0)])]]))
    write_map(instance.map_path, [entry])
    instance.refresh(project_root: project)

    assert_equal("unmapped", instance.lookup(model: "zhipu-coding-plan/glm-5.3-flash", project_root: project).fetch("status"), "flash stays part of the concrete name and never becomes flashx")
    assert_equal("ambiguous_concrete_rows", instance.lookup(model: "somechannel/glm-5.3-flashx", project_root: project).dig("mapping", "reason"), "two concrete rows of one name are stated, not guessed")
    assert_equal("unmapped", instance.lookup(model: "opencode-go/deepseek-v4-flash", project_root: project).fetch("status"), "a different base model is never guessed from another row")
    assert_equal("ambiguous_catalog_rows", instance.lookup(model: "cursor/grok-4.7-500k-fast", project_root: project).dig("mapping", "reason"), "two distinct canonical rows for one base stay unresolved")
    assert_equal("unmapped", instance.lookup(model: "kimi-code/k3-256k", reasoning: "low", project_root: project).fetch("status"), "an audited identity with a conflicting concrete variant keeps its result")
    assert_equal("unsupported_billing_route", instance.lookup(model: "somechannel/glm-5.3-flashx", billing_route: "made_up", project_root: project).dig("mapping", "reason"), "an unsupported route value never reaches a match")
    assert_equal(nil, instance.mapping_provenance(model: "somechannel/glm-5.3-flashx", billing_route: "made_up", project_root: project), "provenance applies the same route validation")
  end

  def overview(tmp, name, env: {}, clock: nil, http: nil)
    home = File.join(tmp, "home-#{name}")
    Orbit::OpenRouterModelOverview.new(env: { "HOME" => home, "OPENROUTER_API_KEY" => "or-test-key-1" }.merge(env),
                                       home: home, clock: clock || -> { NOW },
                                       cache_path: File.join(tmp, name, "overview.json"),
                                       map_path: File.join(tmp, name, "map.json"),
                                       http_get: http || FakeHttp.new([]))
  end

  # A catalogue row shape without benchmark indices. The live catalogue now
  # embeds an `artificial_analysis` object on some rows; the fixture omits it
  # because this code never consumes catalogue-carried indices.
  def row(id, slug: id)
    { "id" => id, "canonical_slug" => slug, "name" => "Model", "description" => "Bounded description.",
      "context_length" => 8192,
      "supported_parameters" => ["tools"],
      "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["text"], "tokenizer" => "Other" } }
  end

  def models_body(rows, next_link: nil, total_count: nil)
    JSON.generate({ "data" => rows, "links" => { "next" => next_link },
                    "total_count" => total_count.nil? ? rows.length : total_count })
  end

  # One row of the separate Artificial Analysis endpoint, with the variant's own
  # display_name and a pricing block the module must never store.
  def variant(slug, display_name: "Variant", coding: 50.0, agentic: 40.0, intelligence: nil,
              source: "artificial-analysis")
    { "source" => source, "model_permaslug" => slug, "display_name" => display_name,
      "coding_index" => coding, "agentic_index" => agentic, "intelligence_index" => intelligence,
      "pricing" => { "prompt" => "0.000001", "completion" => "0.000002" } }
  end

  def benchmarks_body(rows, as_of: "2026-06-03T12:00:00Z")
    JSON.generate({ "data" => rows, "meta" => { "as_of" => as_of, "version" => "v1", "source_url" => nil } })
  end

  def write_map(path, entries)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate({ "schema_version" => "orbit-openrouter-model-map-v1", "entries" => entries }))
  end

  def mapping(overrides = {})
    { "provider" => "opencode-go", "model" => "deepseek-v4.1-flash", "reasoning" => "unknown",
      "billing_route" => "unknown", "openrouter_id" => "deepseek/deepseek-v4.1-flash",
      "canonical_slug" => "deepseek/deepseek-v4.1-flash",
      "sources" => ["https://vendor.example/deepseek-v4.1-flash"],
      "verified_at" => "2026-09-28T00:00:00Z", "verified_by" => "Root" }.merge(overrides)
  end

  def assert(condition, message)
    @assertions += 1
    raise("assertion failed: #{message}") unless condition
  end

  def assert_equal(expected, actual, message)
    assert(expected == actual, "#{message} (expected #{expected.inspect}, got #{actual.inspect})")
  end
end

OpenRouterModelOverviewTest.run
