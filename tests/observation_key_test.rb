# frozen_string_literal: true

# Deterministic tests for Orbit::ObservationKey. No I/O beyond tmpdir
# fixtures, no network, no models. Run:
#   ruby --disable-gems tests/observation_key_test.rb

require "tmpdir"
require "fileutils"

require_relative "../lib/orbit/observation_key"

module ObservationKeyTest
  module_function

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition

    true
  end

  def key(root, **overrides)
    Orbit::ObservationKey.build(
      **{ input_digest: "input-v1", artifact_root: root, artifact_digest: "artifact-v1",
          host: base_host,
          findings: { "f-1" => { "id" => "f-1", "status" => "open", "check" => 2,
                                 "evidence" => "missing tests", "files" => %w[a.rb] } },
          dispute: nil, trigger: nil }.merge(overrides)
    )
  end

  def base_host
    { "status" => "idle", "turn_id" => "turn-9", "last_turn_id" => "turn-8", "last_turn_status" => "completed",
      "active_tools" => %w[bash read], "interrupted" => false,
      "observations" => [{ "kind" => "command", "output" => "rspec ok" }] }
  end

  def run
    Dir.mktmpdir("orbit-obs-key-") do |tmp|
      Dir.mktmpdir("orbit-obs-other-") do |other|
        check_determinism_and_order_independence(tmp)
        check_transient_noise_independence(tmp)
        check_dimension_sensitivity(tmp, other)
        check_artifact_root_canonicalization_and_validation(tmp)
        check_bounded_long_content(tmp)
        puts "OBSERVATION_KEY_TEST_PASS (deterministic)"
      end
    end
  end

  # Same observation, different container shapes: finding hash insertion
  # order, findings array order, and Hash-vs-Array must not change the key.
  def check_determinism_and_order_independence(tmp)
    baseline = key(tmp)
    reordered = { "f-1" => { "files" => %w[a.rb], "check" => 2, "evidence" => "missing tests", "status" => "open", "id" => "f-1" } }
    check(key(tmp, findings: reordered) == baseline, "finding hash insertion order does not change the key")

    as_array = [{ "evidence" => "missing tests", "check" => 2, "status" => "open", "id" => "f-1", "files" => %w[a.rb] }]
    check(key(tmp, findings: as_array) == baseline, "findings array order and Hash-vs-Array shape do not change the key")

    two = { "f-2" => { "id" => "f-2", "status" => "open", "evidence" => "n+1 queries", "check" => 3 },
            "f-1" => { "id" => "f-1", "status" => "open", "evidence" => "missing tests", "check" => 2, "files" => %w[a.rb] } }
    two_reversed = two.sort.reverse.to_h
    check(key(tmp, findings: two) == key(tmp, findings: two_reversed),
          "multiple findings in different insertion orders share one key")
    check(key(tmp, findings: two) != baseline, "adding an open finding changes the key")
    check(baseline.length == 64 && baseline.match?(/\A\h+\z/), "the key is a fixed-length SHA-256 hex string")
  end

  # Repeated status/check polls carry the same effective state plus transient
  # noise; the key must stay put.
  def check_transient_noise_independence(tmp)
    baseline = key(tmp)
    noisy_host = base_host.merge(
      "polled_at" => "2026-09-22T12:00:00Z", "poll_count" => 42,
      "active_tools" => %w[read bash], "interrupted" => true, "latency_ms" => 7
    )
    check(key(tmp, host: noisy_host) == baseline, "timestamps, poll counters and tool order are ignored")

    delivered_host = base_host.merge("status" => "idle", "last_turn_id" => "turn-8")
    check(key(tmp, host: delivered_host) == key(tmp), "identical effective host state polls to the same key")
  end

  # Every substantive dimension must change the key; non-open findings and
  # provenance-only changes must not.
  def check_dimension_sensitivity(tmp, other)
    baseline = key(tmp)
    {
      "input_digest" => { input_digest: "input-v2" },
      "artifact_digest" => { artifact_digest: "artifact-v2" },
      "artifact_root" => { artifact_root: other },
      "host status" => { host: base_host.merge("status" => "active") },
      "host last_turn_id" => { host: base_host.merge("last_turn_id" => "turn-9") },
      "host last_turn_status" => { host: base_host.merge("last_turn_status" => "failed") },
      "host observations" => { host: base_host.merge("observations" => [{ "kind" => "command", "output" => "rspec failed" }]) },
      "open finding evidence" => { findings: { "f-1" => { "id" => "f-1", "status" => "open", "check" => 2,
                                                          "evidence" => "missing unit tests", "files" => %w[a.rb] } } },
      "dispute" => { dispute: { "category" => "workspace_mismatch" } },
      "trigger" => { trigger: { "kind" => "delivery" } }
    }.each do |label, override|
      check(key(tmp, **override) != baseline, "changing #{label} changes the key")
    end

    resolved = { "f-1" => { "id" => "f-1", "status" => "resolved", "check" => 2, "evidence" => "missing tests",
                            "files" => %w[a.rb], "resolution" => "added tests" } }
    check(key(tmp, findings: resolved) != baseline, "an open finding resolving changes the key")
    check(key(tmp, findings: {}) != baseline, "the open finding set emptying changes the key")

    rechecked = { "f-1" => { "id" => "f-1", "status" => "open", "check" => 7, "evidence" => "missing tests",
                             "files" => %w[a.rb] } }
    check(key(tmp, findings: rechecked) == baseline, "the same finding refiled under a later check keeps the key")

    with_provenance = { "f-1" => rechecked.fetch("f-1").merge(
      "observed_root" => tmp, "observed_version" => "artifact-v1", "observed_input" => "input-v1"
    ) }
    check(key(tmp, findings: with_provenance) == baseline,
          "finding provenance duplicates top-level versions and does not manufacture a new observation")

    settled = key(tmp, dispute: { "category" => "workspace" })
    check(key(tmp, dispute: { "category" => "workspace" }) == settled && settled != baseline,
          "the same dispute material repeats its key")
  end

  def check_artifact_root_canonicalization_and_validation(tmp)
    link = File.join(Dir.mktmpdir("orbit-obs-link-"), "workspace-link")
    File.symlink(tmp, link)
    check(key(link) == key(tmp), "symlink spellings of the same directory canonicalize to one key")

    Dir.chdir(tmp) do
      check(Orbit::ObservationKey.build(input_digest: "i", artifact_root: ".",
                                        artifact_digest: "a", host: base_host, findings: {}) ==
            Orbit::ObservationKey.build(input_digest: "i", artifact_root: tmp,
                                        artifact_digest: "a", host: base_host, findings: {}),
            "a relative artifact_root resolves to the same canonical key")
    end

    file = File.join(tmp, "file.txt")
    File.write(file, "not a directory")
    expect_error("a non-directory artifact_root is rejected") { key(file) }
    expect_error("a missing artifact_root is rejected") { key(File.join(tmp, "absent")) }
    expect_error("an empty artifact_root is rejected") { key("") }
  end

  # Oversized finding text and observations must stay out of the material
  # while keeping the key cheap; any substantive change, including deep in the
  # tail, must still change the key.
  def check_bounded_long_content(tmp)
    long_tail_a = "x" * 20_000 + "alpha"
    long_tail_b = "x" * 20_000 + "omega"
    evidence_a = "e" * Orbit::ObservationKey::STRING_CAP + long_tail_a
    evidence_b = "e" * Orbit::ObservationKey::STRING_CAP + long_tail_b
    huge = { "f-1" => { "id" => "f-1", "status" => "open", "check" => 2, "evidence" => evidence_a, "files" => %w[a.rb] } }
    huge_b = { "f-1" => { "id" => "f-1", "status" => "open", "check" => 2, "evidence" => evidence_b, "files" => %w[a.rb] } }
    check(key(tmp, findings: huge) != key(tmp, findings: huge_b),
          "finding content differing only past the string bound still changes the key")
    check(key(tmp, findings: huge) != key(tmp), "bounded long content still differs from the baseline finding")

    material = Orbit::ObservationKey.material(input_digest: "input-v1", artifact_root: tmp, artifact_digest: "artifact-v1",
                                              host: base_host, findings: huge)
    bounded = material.fetch("open_findings").first.fetch("evidence")
    check(bounded.length <= Orbit::ObservationKey::STRING_CAP + 100 && bounded.include?("…[#{evidence_a.length}:"),
          "long text enters the material as a bounded prefix plus length and full-text digest")

    big_obs_host = base_host.merge("observations" => [{ "kind" => "output", "output" => "o" * 500_000 }] * 3)
    big_key = key(tmp, host: big_obs_host)
    check(big_key.length == 64 && big_key != key(tmp), "huge observations stay bounded and still change the key")
    check(JSON.generate(material).length < 20_000, "the canonical material itself stays small")
  end

  def expect_error(message)
    yield
    raise "ASSERTION FAILED: #{message}"
  rescue Orbit::ObservationKey::Error
    true
  end
end

ObservationKeyTest.run
