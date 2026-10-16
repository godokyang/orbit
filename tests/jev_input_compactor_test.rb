# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/orbit/jev_input_compactor"

module JevInputCompactorTest
  module_function

  CANDIDATE = "opencode-go/deepseek-v4.1-flash"
  OTHER = "openai/gpt-6-sol"
  ITEM = { "role" => "constraint", "text" => "must not commit" }.freeze
  SECTIONS = { "objective" => "deliver the module", "constraints" => "must not commit",
               "background" => "shared worktree", "undetermined" => "" }.freeze

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-jev-compactor") do |tmp|
      test_selection_chain_caches_one_compaction(tmp)
      test_failure_flight_is_shared_but_never_cached(tmp)
      test_recover_retries_once(tmp)
      test_capacity_gate_refuses_without_a_fitting_candidate(tmp)
      test_output_checks_and_cannot_preserve(tmp)
    end
    puts("JEV_INPUT_COMPACTOR_TEST_PASS assertions=#{@assertions}")
  end

  # One full selection chain: JEV sees metadata only, the runner runs once, the
  # result is reusable from the cache with the call facts preserved.
  def test_selection_chain_caches_one_compaction(tmp)
    provider = FakeProvider.new("compaction_choice_0" => 0.9, "compaction_choice_1" => 0.2, "no_candidate_suitable" => 0.1)
    runner = FakeRunner.new(->(_prompt, model) { success(model) })
    compactor = build(tmp, "chain", provider: provider, runner: runner)
    material = "合同正文" * 6_000

    first = compact(compactor, material)
    assert_equal("compacted", first["status"], "a suitable candidate compacts the material")
    assert_equal(CANDIDATE, first["model"], "the judge's choice is the chosen model")
    assert_equal(1, runner.calls.length, "exactly one compaction call is made")
    assert(first["text"].include?("## necessary conditions and constraints"), "the rendered text keeps the groups")
    assert_equal([{ "role" => "constraint", "present" => true }], first["preserved"], "required items are reported per role")
    assert_equal([{ "call_id" => "call-1" }], first["call"]["usage"], "runner usage receipts reach the caller")
    assert(first["call"]["evidence"].is_a?(Hash), "the runner evidence reaches the caller")
    assert(first["selection"]["trace"]["request"].is_a?(Hash), "the JEV request reaches the caller")
    assert(first["selection"]["trace"]["provider_response"].is_a?(Hash), "the provider response reaches the caller")
    state = JSON.generate(provider.requests.last.state)
    assert(!state.include?("合同正文"), "the material text is never part of the JEV selection input")
    assert(state.include?("compaction_task"), "the selection input carries the compaction metadata")
    assert_equal(first["selection"]["chosen"], CANDIDATE, "the selection records the chosen model")
    assert_equal(0.9, first["selection"]["choices"][CANDIDATE], "the selection records the combined choice probability")

    second = compact(compactor, material)
    assert_equal("cached", second["status"], "an unchanged compaction is reused")
    assert_equal("hit", second["cache"], "the reuse is reported as a cache hit")
    assert_equal(1, runner.calls.length, "a cache hit pays for no second compaction")
    assert_equal(first["text"], second["text"], "the cached text is the same text")
    assert_equal(1, provider.requests.length, "a cache hit spends no judgment call")
    speed = JSON.parse(File.read(File.join(compactor.cache_dir, "speed.json")))
    assert(speed.dig("models", CANDIDATE, 0, "input_bytes").positive?, "the real measurement is recorded")
  end

  # Concurrent same-key askers share one in-flight result, failures included;
  # the failure is a flight receipt only, so a later request retries.
  def test_failure_flight_is_shared_but_never_cached(tmp)
    attempts = []
    runner = FakeRunner.new(lambda { |_prompt, model|
      attempts << model
      sleep(0.2)
      attempts.length == 1 ? { "ok" => false, "error" => { "kind" => "unavailable", "detail" => "boom" } } : success(model)
    })
    compactor = build(tmp, "flight", runner: runner)
    # The caller builds one compactor per ask, so the shared flight must work
    # across instances, not only inside one object.
    results = parallel(3) { build(tmp, "flight", runner: runner).compact(purpose: "member_selection", material: material, must_keep: [ITEM], output_budget_bytes: 2_000, candidates: [candidate]) }

    assert_equal(1, attempts.length, "three simultaneous askers make one compaction call")
    assert(results.all? { |result| result["status"] == "unavailable" }, "every asker receives the shared failure")
    assert(results.all? { |result| result["reason"].include?("boom") }, "the shared failure keeps its reason")
    assert_equal(%w[leader shared shared].sort, results.map { |result| result["flight"] }.sort,
                 "exactly one asker led the shared call across instances")
    cache = File.join(compactor.cache_dir, "cache.json")
    assert(!File.file?(cache) || JSON.parse(File.read(cache))["entries"].empty?, "a failed compaction is never cached")

    retry_result = compact(compactor, material)
    assert_equal(2, attempts.length, "a later request retries instead of reusing the failure")
    assert_equal("compacted", retry_result["status"], "the retry succeeds once the runner works")
  end

  # Only an explicit input/token limit starts a compaction, and the original
  # judgment is then retried at most once, with the compacted text.
  def test_recover_retries_once(tmp)
    runner = FakeRunner.new(->(_prompt, model) { success(model) })
    compactor = build(tmp, "recover", runner: runner)
    seen = []
    result = compactor.recover(purpose: "checker_selection", material: material, must_keep: [ITEM],
                               output_budget_bytes: 2_000, candidates: [candidate]) do |text|
      seen << text
      {"status" => "unavailable", "error" => "max_tokens_exceeded"}
    end
    assert_equal("retried", result["status"], "a capacity refusal triggers one compaction and one retry")
    assert_equal(1, runner.calls.length, "the compaction runs a single time")
    assert_equal(2, seen.length, "the original judgment is tried exactly twice")
    assert_equal(material, seen.first, "the first attempt used the original material")
    assert(result["judgment"].is_a?(Hash) && result["first_judgment"].is_a?(Hash), "both attempts are reported")
    assert_equal(result["compaction"]["text"], seen.last, "the retry used the compacted text")

    quiet = build(tmp, "recover-network", runner: runner)
    calls = 0
    other = quiet.recover(purpose: "member_selection", material: material, must_keep: [ITEM], output_budget_bytes: 2_000,
                          candidates: [candidate]) do |_text|
      calls += 1
      {"status" => "unavailable", "error" => "TypeSafe assessment failed: SocketError"}
    end
    assert_equal("not_needed", other["status"], "a transport failure never starts a compaction")
    assert_equal(1, calls, "no retry happens without an explicit capacity refusal")
    assert_equal(false, Orbit::JevInputCompactor.overflow?({ "error" => "HTTP 401 unauthorized" }), "auth is not overflow")
  end

  # Capacity is decided by the program: unverified or too small context cannot
  # be selected, and no judgment or compaction is paid for.
  def test_capacity_gate_refuses_without_a_fitting_candidate(tmp)
    provider = FakeProvider.new({})
    runner = FakeRunner.new(->(_prompt, model) { success(model) })
    compactor = build(tmp, "capacity", provider: provider, runner: runner)

    unknown = compact(compactor, material, candidates: [{ "model" => CANDIDATE }])
    assert_equal("unavailable", unknown["status"], "a candidate without a verified context limit is not selectable")
    assert(unknown["reason"].include?("one pass"), "the refusal names the capacity gate")
    assert_equal(0, provider.requests.length, "no judgment is spent on an ineligible candidate set")
    assert_equal(0, runner.calls.length, "no compaction is paid for without a fitting candidate")

    small = compact(compactor, material, candidates: [{ "model" => CANDIDATE, "context_limit_tokens" => 3_000 }])
    assert_equal("unavailable", small["status"], "a candidate that cannot hold material and budget is not selectable")
    assert_equal(0, runner.calls.length, "no compaction is paid for a too small context")
  end

  # The output contract is checked, not assumed: the four groups, the required
  # items, the budget and an explicit cannot_preserve answer.
  def test_output_checks_and_cannot_preserve(tmp)
    cases = {
      "cannot-persist" => [{ "status" => "cannot_preserve", "reason" => "the constraints do not fit" }, "cannot preserve"],
      "nested-json" => [{ "status" => "compacted", "sections" => SECTIONS.merge("constraints" => "something else") }, "dropped required items"],
      "too-long" => [{ "status" => "compacted", "sections" => SECTIONS.merge("background" => "b" * 4_000) }, "over the"],
      "prose" => ["compacted prose without json", "not the required JSON object"],
      "deferral" => [{ "status" => "compacted", "sections" => SECTIONS.merge("constraints" => "#{ITEM['text']} 详见原文") }, "defers to the original"]
    }
    cases.each do |name, (payload, expected)|
      runner = FakeRunner.new(->(_prompt, model) { success(model, text: payload.is_a?(String) ? payload : JSON.generate(payload)) })
      compactor = build(tmp, name, runner: runner)
      result = compact(compactor, material)
      assert_equal("unavailable", result["status"], "#{name}: a broken output is a failed compaction")
      assert(result["reason"].include?(expected), "#{name}: the reason names the problem (#{result['reason']})")
      assert(result["text"].nil?, "#{name}: a failed compaction returns no text")
      assert_equal("leader", result["flight"], "#{name}: the failure is a flight receipt, not a cached summary")
    end
  end

  def material
    "必须保留的合同条款与背景事实。" * 500
  end

  def candidate
    { "model" => CANDIDATE, "context_limit_tokens" => 200_000 }
  end

  def compact(compactor, text, candidates: nil)
    compactor.compact(purpose: "member_selection", material: text, must_keep: [ITEM], output_budget_bytes: 2_000,
                      candidates: candidates || [candidate, { "model" => OTHER, "context_limit_tokens" => 200_000 }],
                      language: "zh")
  end

  def success(model, text: nil)
    body = text || JSON.generate("status" => "compacted", "sections" => SECTIONS)
    { "ok" => true, "text" => body, "model" => model, "input_bytes" => 30_000, "output_bytes" => body.bytesize,
      "seconds" => 1.5, "attempt_id" => "attempt-1", "usage" => [{ "call_id" => "call-1" }], "usage_gaps" => [],
      "evidence" => { "ok" => true, "mode" => "compaction" } }
  end

  def build(tmp, name, provider: nil, runner: nil)
    Orbit::JevInputCompactor.new(
      provider: provider || FakeProvider.new("compaction_choice_0" => 0.9, "no_candidate_suitable" => 0.1),
      runner: runner, cache_dir: File.join(tmp, name), clock: -> { Time.utc(2026, 10, 16, 12, 0, 0) }
    )
  end

  def parallel(count)
    threads = Array.new(count) { Thread.new { yield } }
    threads.map(&:value)
  end

  class FakeProvider
    attr_reader :requests, :last_response

    def initialize(scores)
      @scores = scores
      @requests = []
      @last_response = { "http_status" => 200, "body_encoding" => "base64" }
    end

    def judge(request)
      @requests << request
      answers = request.questions.keys.to_h do |id|
        [id, { "probability_true" => @scores.fetch(id, 0.0) }]
      end
      Orbit::JudgmentResult.answered(answers: answers, provider: "typesafe", actual_model: "jev-latest",
                                     usage: { "tokens" => 120 })
    end
  end

  class FakeRunner
    attr_reader :calls

    def initialize(handler)
      @handler = handler
      @calls = []
    end

    def run(prompt:, model:)
      @calls << { "prompt" => prompt, "model" => model }
      @handler.call(prompt, model)
    end
  end

  def assert(condition, message)
    @assertions += 1
    raise("assertion failed: #{message}") unless condition
  end

  def assert_equal(expected, actual, message)
    assert(expected == actual, "#{message} (expected #{expected.inspect}, got #{actual.inspect})")
  end
end

JevInputCompactorTest.run
