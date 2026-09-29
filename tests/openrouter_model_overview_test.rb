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
      test_pagination_completeness(tmp)
      test_status_diagnostics_are_read_only(tmp)
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

    configured = overview(tmp, "gate", http: FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash")])]]))
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
    http = FakeHttp.new([[200, models_body([row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715")])],
                         [200, models_body([row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715")])]])
    instance = overview(tmp, "ttl", clock: -> { now }, http: http)
    assert_equal("fresh", instance.refresh(project_root: project).fetch("status"), "the first fetch stores a snapshot")

    now = NOW + 71 * 60 * 60
    assert_equal("fresh", instance.refresh(project_root: project).fetch("status"), "inside 72h the snapshot is reused")
    assert_equal("fresh", overview(tmp, "ttl", clock: -> { now }, http: FakeHttp.new([]))
                    .refresh(project_root: project).fetch("status"), "a second process reuses the snapshot")
    assert_equal(1, http.requests.length, "the lock coordinates concurrent tasks into one fetch")

    now = NOW + 72 * 60 * 60 + 1
    assert_equal("stale", instance.lookup(model: "moonshotai/kimi-k3", project_root: project).fetch("status"),
                 "an expired snapshot is not a prior")
    assert_equal("fresh", instance.refresh(project_root: project).fetch("status"), "expiry triggers a refetch")
    assert_equal(2, http.requests.length, "lookup stayed offline and expiry fetched exactly once")

    content = File.read(instance.cache_path)
    assert(!content.include?("or-test-key-1") && File.stat(instance.cache_path).mode & 0o777 == 0o600,
           "the snapshot is private and key-free")
  end

  def test_http_failure_backoff_and_new_key_recovery(tmp)
    project = tmp
    http = FakeHttp.new([[401, '{"error":{"message":"invalid key"}}'],
                         [200, models_body([row("deepseek/deepseek-v4.1-flash")])]])
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
    http = FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash", coding: 56.2, agentic: nil),
                                            row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715")])]])
    instance = overview(tmp, "maps", http: http)
    instance.refresh(project_root: project)

    write_map(instance.map_path, [
      mapping,
      mapping("provider" => "kimi-code", "model" => "k3-256k", "reasoning" => "high",
              "openrouter_id" => "moonshotai/kimi-k3", "canonical_slug" => "moonshotai/kimi-k3-20260715"),
      mapping("model" => "no-sources", "sources" => []),
    ])
    prior = instance.lookup(model: "opencode-go/deepseek-v4.1-flash", project_root: project).fetch("prior")
    assert_equal(56.2, prior.fetch("coding_index"), "the coding index is carried through")
    assert_equal(nil, prior.fetch("agentic_index"), "a null agentic index stays null")
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
      row("moonshotai/kimi-k3", slug: "moonshotai/kimi-k3-20260715", coding: 76.2, agentic: 50.0),
      row("zhipu/glm-5.3-flashx", coding: nil, agentic: nil),
      row("deepseek/deepseek-v4.1-flash"),
      row("~deepseek/deepseek-v4-flash-latest", slug: "deepseek/deepseek-v4-flash")
    ]
    instance = overview(tmp, "gates", http: FakeHttp.new([[200, models_body(rows)]]))
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

    kimi = instance.lookup(model: "kimi-code/k3-256k", project_root: project)
    assert_equal("fresh", kimi.fetch("status"), "the mapped canonical row resolves through its real catalog id")
    assert_equal(76.2, kimi.fetch("prior").fetch("coding_index"), "the audited coding index is carried through")
    assert_equal("no_benchmark", instance.lookup(model: "zhipu-coding-plan/glm-5.3-flashx", project_root: project).fetch("status"),
                 "a null coding index never becomes a capability")
    assert_equal("unavailable", instance.lookup(model: "opencode-go/deepseek-v4-flash", project_root: project).fetch("status"),
                 "a tilde alias row is skipped and never resolves a mapping")
    assert_equal("unavailable", instance.lookup(model: "opencode-go/drifted", project_root: project).fetch("status"),
                 "canonical drift suspends the mapping instead of silently re-pointing it")
  end

  def test_pagination_completeness(tmp)
    project = tmp
    http = FakeHttp.new([[200, models_body([row("a/one"), row("a/two")], next_link: "/api/v1/models?offset=2", total_count: 3)],
                         [200, models_body([row("a/three")], total_count: 3)]])
    instance = overview(tmp, "pages", http: http)
    assert_equal(3, instance.refresh(project_root: project).fetch("model_count"),
                 "pagination links are followed to the full snapshot")

    partial = overview(tmp, "pages-partial", http: FakeHttp.new([[200, models_body([row("a/a")], total_count: 5)]]))
    assert_equal("error", partial.refresh(project_root: project).fetch("status"), "a partial list is not mistaken for complete")
    offsite = overview(tmp, "pages-offsite",
                       http: FakeHttp.new([[200, models_body([row("a/a")], next_link: "https://evil.example/m")]]))
    assert_equal("error", offsite.refresh(project_root: project).fetch("status"), "off-site pagination links are refused")
  end

  def test_status_diagnostics_are_read_only(tmp)
    project = tmp
    http = FakeHttp.new([[200, models_body([row("deepseek/deepseek-v4.1-flash")])]])
    instance = overview(tmp, "diag", http: http)
    write_map(instance.map_path, [mapping])

    instance.refresh(project_root: project)
    report = instance.status(project_root: project)
    assert_equal("fresh", report.fetch("status"), "a current snapshot reports fresh")
    assert_equal("https://openrouter.ai/api/v1/models", report.fetch("source"), "the catalog source is reported")
    assert_equal("ok", report.fetch("last_attempt"), "the last attempt outcome is reported")
    assert(report.values.none? { |value| value.to_s.include?("or-test-key-1") } && http.requests.length == 1,
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

  def overview(tmp, name, env: {}, clock: nil, http: nil)
    home = File.join(tmp, "home-#{name}")
    Orbit::OpenRouterModelOverview.new(env: { "HOME" => home, "OPENROUTER_API_KEY" => "or-test-key-1" }.merge(env),
                                       home: home, clock: clock || -> { NOW },
                                       cache_path: File.join(tmp, name, "overview.json"),
                                       map_path: File.join(tmp, name, "map.json"),
                                       http_get: http || FakeHttp.new([]))
  end

  def row(id, slug: id, coding: 50.0, agentic: 40.0)
    { "id" => id, "canonical_slug" => slug, "name" => "Model", "description" => "Bounded description.",
      "context_length" => 8192,
      "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["text"], "tokenizer" => "Other" },
      "benchmarks" => { "artificial_analysis" => { "coding_index" => coding, "agentic_index" => agentic } } }
  end

  def models_body(rows, next_link: nil, total_count: nil)
    JSON.generate({ "data" => rows, "links" => { "next" => next_link },
                    "total_count" => total_count.nil? ? rows.length : total_count })
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
