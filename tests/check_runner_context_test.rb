# frozen_string_literal: true

# Deterministic tests for the CheckRunner program-context compression and
# prompt assembly. No model, no process, no network: only the private
# rendering paths are exercised.
# Run:
#   ruby --disable-gems tests/check_runner_context_test.rb

require "digest"
require "json"

require_relative "../lib/orbit/check_runner"

module CheckRunnerContextTest
  module_function

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition

    true
  end

  def runner
    @runner ||= Orbit::CheckRunner.new(model: "test-model", executable: "stub-checker")
  end

  def compress(context)
    runner.send(:compress_context, context)
  end

  def context_json(context)
    runner.send(:render_context, compress(context))
  end

  def parsed(context)
    JSON.parse(context_json(context))
  end

  def long_text(marker, size = 4_000)
    "#{marker}-start-" + ("x" * size) + "-#{marker}-tail"
  end

  def bound_text(original)
    prefix = original[0, Orbit::CheckRunner::CONTEXT_STRING_CAP]
    "#{prefix}…[#{original.length}:#{Digest::SHA256.hexdigest(original)}]"
  end

  def base_context
    {
      "root" => {
        "thread_id" => "thread-1", "cwd" => "/tmp/project", "status" => "idle",
        "status_detail" => { "type" => "idle", "activeFlags" => [] },
        "turn_id" => nil, "last_turn_id" => "turn-9", "last_turn_status" => "completed",
        "observations" => [{ "kind" => "agent_message", "text" => "done", "phase" => "final" }]
      },
      "findings" => {
        "f-1" => { "id" => "f-1", "requirement" => "ship a", "evidence" => "missing b",
                   "action" => "add b", "status" => "open", "check" => 2 },
        "f-0" => { "id" => "f-0", "requirement" => "old", "evidence" => "old evidence",
                   "action" => "old action", "status" => "resolved", "check" => 1,
                   "resolution" => "fixed earlier", "resolution_version" => "sha256:old" }
      },
      "recent_events" => [{ "at" => "2026-09-22T00:00:00Z", "type" => "check_finished", "verdict" => "correct" }],
      "recheck" => {
        "check" => 3, "at" => "2026-09-22T00:00:00Z",
        "findings" => [{ "id" => "f-1", "requirement" => "ship a", "evidence" => "missing b", "action" => "add b" }]
      },
      "execution_members" => [{
        "kind" => "omp", "adapter" => "same_host", "thread_id" => "m-1", "model" => "gpt",
        "status" => "completed", "result" => [{ "kind" => "agent_message", "text" => "member done" }],
        "stop_confirmation" => { "confirmed" => true, "detail" => "y" * 300 },
        "socket" => "/tmp/member.sock"
      }],
      "decisions" => [{
        "dispute" => "is b required?", "check" => 4,
        "input_digest" => "sha256:input-1", "artifact_root" => "/tmp/project",
        "artifact_digest" => "sha256:artifact-1", "resolved_ids" => ["f-0"], "finding_ids" => ["f-1"],
        "reason" => "b is in the instruction", "decided_at" => "2026-09-22T01:00:00Z",
        "result" => { "verdict" => "correct", "reason" => "b is in the instruction",
                      "findings" => [{ "id" => "f-1", "requirement" => "ship a",
                                       "evidence" => "missing b", "action" => "add b" }],
                      "resolved_ids" => [], "next_check_seconds" => 300 }
      }],
      "dispute" => nil, "estimate" => nil, "hard_deadline" => nil, "elapsed_seconds" => 120,
      "project_rules" => ["AGENTS.md"],
      "uncopied_entries" => []
    }
  end

  def run
    check_determinism
    check_open_findings_and_tail_digest
    check_recheck_keeps_every_clue
    check_bounded_history_sections
    check_decision_memory_fields
    check_omitted_ids_stay_traceable
    check_low_priority_drops_before_findings
    check_hard_byte_limit_and_valid_json
    check_prompt_keeps_inputs_and_decision_memory
    check_review_focus_is_explicit_and_deterministic
    check_review_focus_is_bounded_and_traceable
    check_review_focus_prompt_policy
    check_non_hash_context_is_bounded
    puts "CHECK_RUNNER_CONTEXT_TEST_PASS (deterministic)"
  end

  def check_determinism
    context = base_context
    first = context_json(context)
    check(first == context_json(context), "the same context renders byte-identical JSON")
    check(first == context_json(Marshal.load(Marshal.dump(context))), "an equal copy renders identically")

    reordered = Marshal.load(Marshal.dump(context))
    reordered["findings"] = context["findings"].to_a.reverse.to_h
    check(context_json(reordered) == first, "finding hash insertion order does not change the record")
  end

  def check_open_findings_and_tail_digest
    context = base_context
    shared = "s" * 3_000
    first = "#{shared}-tail-a"
    second = "#{shared}-tail-b"
    context["findings"]["f-1"]["evidence"] = first
    other = Marshal.load(Marshal.dump(context))
    other["findings"]["f-1"]["evidence"] = second
    record = parsed(context)
    check(record["findings"].keys == ["f-1"], "only open findings are carried")
    check(record["findings"]["f-1"].keys.sort == %w[action check evidence id requirement status],
          "only the necessary finding fields are carried")
    check(!context_json(context).include?("resolution_version"), "resolved-finding internals are dropped")

    bounded = record.dig("findings", "f-1", "evidence")
    check(bounded == bound_text(first), "the long field keeps a prefix plus original length and SHA-256")
    check(bounded != parsed(other).dig("findings", "f-1", "evidence"),
          "a difference in the tail still changes the bounded record")
  end

  def check_recheck_keeps_every_clue
    context = base_context
    clues = (1..12).map do |index|
      { "id" => "c-#{index}", "requirement" => "r#{index}",
        "evidence" => long_text("clue-#{index}", 3_000), "action" => "a#{index}" }
    end
    context["recheck"] = { "check" => 7, "at" => "x", "findings" => clues }
    record = parsed(context)
    kept = record.dig("recheck", "findings")
    check(kept.map { |clue| clue["id"] } == clues.map { |clue| clue["id"] },
          "every pending clue is kept and none is silently dropped")
    check(kept.all? { |clue| clue.keys.sort == %w[action evidence id requirement] }, "clue fields stay minimal")
    check(kept.first["evidence"] == bound_text(clues.first["evidence"]),
          "a bounded clue keeps a prefix plus original length and SHA-256")
  end

  def check_bounded_history_sections
    context = base_context
    context["root"]["observations"] = (1..40).map { |i| { "kind" => "command", "output" => "obs-#{i}" } }
    context["decisions"] = (1..10).map do |i|
      { "dispute" => "d#{i}", "check" => i,
        "result" => { "verdict" => "continue", "reason" => "reason-#{i}", "findings" => [],
                      "resolved_ids" => [], "next_check_seconds" => 300 } }
    end
    original = long_text("member-20", 2_500)
    context["execution_members"] = [{
      "kind" => "omp", "adapter" => "same_host", "host" => "omp", "thread_id" => "m-1", "model" => "gpt",
      "status" => "completed", "socket" => "/tmp/member.sock",
      "stop_confirmation" => { "confirmed" => true, "detail" => "y" * 200 },
      "result" => (1..19).map { |i| { "kind" => "command", "aggregated_output" => "run #{i}" } } +
        [{ "kind" => "command", "aggregated_output" => original }]
    }]
    record = parsed(context)
    observations = record.dig("root", "observations")
    check(observations.first["output"] == "obs-33" && observations.last["output"] == "obs-40",
          "root observations keep the bounded newest tail")
    check(record["decisions"].map { |decision| decision["check"] } == [8, 9, 10],
          "decisions keep the bounded newest tail")
    member = record.dig("execution_members", 0)
    check(member["kind"] == "omp" && member["thread_id"] == "m-1" && member["status"] == "completed",
          "member identity and status are kept")
    check(member["stop_confirmed"] == true, "the member stop result is summarized")
    check(!member.key?("socket") && !member.key?("stop_confirmation"), "non-essential member fields are dropped")
    check(member["result"].length == 10, "member results keep a bounded newest tail")
    expected = "#{original[0, Orbit::CheckRunner::CONTEXT_MEMBER_RESULT_CAP]}" \
               "…[#{original.length}:#{Digest::SHA256.hexdigest(original)}]"
    check(member["result"].last["aggregated_output"] == expected,
          "the member result summary is bounded with original length and SHA-256")
  end

  def check_decision_memory_fields
    context = base_context
    decision = context["decisions"].first
    long_reason = long_text("decision-reason", 3_000)
    decision["reason"] = long_reason
    record = parsed(context).dig("decisions", 0)
    decision.each_key do |key|
      next if key == "reason"

      check(record.key?(key), "the decision field #{key} is kept")
    end
    check(record["input_digest"] == "sha256:input-1" && record["artifact_digest"] == "sha256:artifact-1",
          "the decision evidence versions are kept")
    check(record["reason"] == bound_text(long_reason), "a long decision reason is bounded, not dropped")
    check(record.dig("result", "verdict") == "correct" && record.dig("result", "next_check_seconds") == 300,
          "the decision result stays available")
  end

  def check_omitted_ids_stay_traceable
    context = base_context
    context["findings"] = (1..300).map do |i|
      ["f-#{i}", { "id" => "f-#{i}", "requirement" => "r", "evidence" => "e", "action" => "a",
                   "status" => "open", "check" => i }]
    end.to_h
    context["recheck"] = {
      "check" => 5, "at" => "x",
      "findings" => (1..250).map do |i|
        { "id" => "c-#{i}", "requirement" => "r", "evidence" => "e", "action" => "a" }
      end
    }
    record = parsed(context)
    check(record["findings"].keys.first == "f-101" && record["findings"].keys.last == "f-300",
          "the newest open findings are kept")
    omitted = record["findings_omitted"]
    omitted_ids = (1..100).map { |i| "f-#{i}" }
    check(omitted["count"] == 100, "the omitted open finding count is recorded")
    check(omitted["ids"] == omitted_ids.last(50), "the omitted ids that fit are kept")
    check(omitted["ids_sha256"] == Digest::SHA256.hexdigest(JSON.generate(omitted_ids)),
          "the digest covers every omitted open finding id")
    clues = record["recheck_omitted"]
    clue_ids = (1..50).map { |i| "c-#{i}" }
    check(clues["count"] == 50 && clues["ids"] == clue_ids, "omitted pending clues keep their ids")
    check(clues["ids_sha256"] == Digest::SHA256.hexdigest(JSON.generate(clue_ids)),
          "the digest covers every omitted clue id")
    check(record.dig("recheck", "findings").last["id"] == "c-250", "the newest pending clue is kept")
  end

  def check_low_priority_drops_before_findings
    context = base_context
    context["uncopied_entries"] = (1..25).map do |i|
      entry = { "path" => long_text("path-#{i}", 3_000), "kind" => "other", "materialized" => false }
      3.times { |j| entry["detail-#{j}"] = long_text("detail-#{i}-#{j}", 3_000) }
      entry
    end
    json = context_json(context)
    check(json.bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT, "the uncopied overflow converges under the cap")
    record = JSON.parse(json)
    check(record["uncopied_entries"] == [], "uncopied manifest entries are dropped first")
    check(record.dig("context_compression", "degraded") == ["uncopied entries dropped"],
          "the applied degradation is recorded")
    check(record.dig("context_compression", "string_cap") == Orbit::CheckRunner::CONTEXT_STRING_CAP,
          "higher-priority caps are not reduced for a low-priority overflow")
    check(record.dig("findings", "f-1", "evidence") == "missing b", "open findings are untouched")
  end

  def check_hard_byte_limit_and_valid_json
    context = base_context
    context["root"]["observations"] = (1..60).map { |i| { "kind" => "command", "output" => long_text("obs-#{i}", 4_000) } }
    context["findings"] = (1..300).map do |i|
      ["f-#{i}", { "id" => "f-#{i}", "requirement" => long_text("req-#{i}", 3_000),
                   "evidence" => long_text("ev-#{i}", 4_000), "action" => long_text("act-#{i}", 1_000),
                   "status" => "open", "check" => i }]
    end.to_h
    context["recheck"] = {
      "check" => 9, "at" => "x",
      "findings" => (1..200).map do |i|
        { "id" => "c-#{i}", "requirement" => "r#{i}", "evidence" => long_text("clue-#{i}", 2_000), "action" => "a#{i}" }
      end
    }
    context["execution_members"] = (1..30).map do |i|
      { "kind" => "omp", "thread_id" => "m-#{i}", "status" => "completed",
        "result" => (1..15).map { |j| { "kind" => "command", "aggregated_output" => long_text("member-#{i}-#{j}", 2_000) } } }
    end
    context["decisions"] = (1..20).map do |i|
      { "dispute" => "d#{i}", "check" => i,
        "result" => { "verdict" => "correct", "reason" => long_text("reason-#{i}", 4_000),
                      "findings" => (1..5).map do |j|
                        { "id" => "df-#{i}-#{j}", "requirement" => "r",
                          "evidence" => long_text("dev-#{i}-#{j}", 3_000), "action" => "a" }
                      end,
                      "resolved_ids" => [], "next_check_seconds" => 300 } }
    end
    context["review_focus"] = {
      "added" => (1..500).map { |i| "focus/added-#{i}.rb" },
      "modified" => (1..500).map { |i| "focus/modified-#{i}.rb" },
      "deleted" => (1..500).map { |i| "focus/deleted-#{i}.rb" }
    }
    json = context_json(context)
    check(json.bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT,
          "the rendered program context stays within #{Orbit::CheckRunner::CONTEXT_BYTE_LIMIT} bytes")
    record = JSON.parse(json)
    check(record["findings"].key?("f-300"), "the newest open finding survives compression")
    check(record.dig("decisions", -1, "check") == 20, "the newest decision survives compression")
    check(record["root"]["status"] == "idle" && record["project_rules"] == ["AGENTS.md"],
          "current program facts survive compression")
    focus = record["review_focus"]
    check(focus.is_a?(Hash) && focus.values.all? { |paths| !paths.empty? },
          "review_focus survives the hard byte cap with every category present")
    check(focus.values.flatten.length <= 3 * Orbit::CheckRunner::CONTEXT_CAPS.fetch(:review_focus_limit),
          "review_focus stays within its own bound under the hard cap")
    check(record.dig("review_focus_omitted", "ids_sha256").to_s.length == 64,
          "focus paths dropped at the cap stay traceable by count and digest")
    check(record.dig("context_compression", "string_cap").to_i.positive?,
          "the record reports how it was compressed")
    check(record.dig("findings_omitted", "ids_sha256").to_s.length == 64,
          "omitted open findings are traceable by count and digest")
    check(record.dig("findings_omitted", "ids").length == 50,
          "the omitted ids that fit are kept even under the hard cap")
    check(record.dig("recheck_omitted", "ids_sha256").to_s.length == 64,
          "omitted pending clues are traceable by count and digest")
  end

  def check_prompt_keeps_inputs_and_decision_memory
    instruction = "original requirement\n" + long_text("instruction", 8_000)
    amendment = "amendment\n" + long_text("amendment", 6_000)
    basis = "basis\n" + long_text("basis", 6_000)
    prompt = runner.send(
      :build_prompt, snapshot: "/unused",
      inputs: {
        "instruction" => instruction,
        "amendments" => [{ "source" => "user", "text" => amendment }],
        "basis" => [{ "path" => "TASK.md", "text" => basis }]
      },
      context: base_context, role: "reviewer"
    )
    check(prompt.include?(instruction), "the original instruction is verbatim")
    check(prompt.include?(amendment), "the amendment is verbatim")
    check(prompt.include?(basis), "the named basis is verbatim")
    blocks = prompt.scan(/```json\n(.*?)\n```/m).flatten
    check(!blocks.empty?, "the prompt carries JSON blocks")
    blocks.each { |block| JSON.parse(block) }
    check(blocks.last.bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT,
          "the program-context JSON block stays within the hard byte cap")
    check(prompt.include?("decision memory"), "the reviewer prompt names the decision memory")
    check(prompt.include?("Reuse the existing finding id"), "the reviewer prompt requires reusing the finding id")
    check(prompt.include?("do not re-raise a point"), "the reviewer prompt forbids re-raising settled points")
    check(prompt.include?("new evidence"), "the reviewer prompt requires new evidence for a settled point")

    process_prompt = runner.send(
      :build_prompt, snapshot: "/unused", inputs: { "instruction" => "do it" },
      context: base_context.merge(
        "model_evidence_request" => { "identities" => { "root" => { "provider" => "kimi-code" } },
                                      "needed" => %w[speed], "at" => "2026-09-24T19:23:15Z", "resolved" => nil }
      ),
      role: "process_reviewer"
    )
    check(process_prompt.include?("pending model_evidence_request") &&
          process_prompt.include?("authorized workflow") &&
          process_prompt.include?("\"model_evidence_request\""),
          "process review treats a pending evidence request as authorized and receives it bounded")

    context = base_context
    clue_evidence = "unique-clue-evidence-marker"
    context["recheck"]["findings"][0]["evidence"] = clue_evidence
    clue_prompt = runner.send(:build_prompt, snapshot: "/unused", inputs: { "instruction" => "do it" },
                              context: context, role: "reviewer")
    check(clue_prompt.include?("Pending clues from a check that went stale"), "the clue instructions are kept")
    check(clue_prompt.scan(clue_evidence).length == 1,
          "the clue finding data appears exactly once, in the program record")
  end

  def check_review_focus_is_explicit_and_deterministic
    baseline = parsed(base_context)
    context = base_context
    context["review_focus"] = {
      "modified" => ["lib/z.rb", "lib/a.rb", "lib/a.rb"],
      "deleted" => ["docs/gone.md"],
      "added" => ["lib/new.rb", ""]
    }
    record = parsed(context)
    check(record["review_focus"] == {
            "added" => ["lib/new.rb"], "modified" => ["lib/a.rb", "lib/z.rb"],
            "deleted" => ["docs/gone.md"]
          },
          "review_focus keeps the three categories as sorted, de-duplicated path lists")
    check(record.keys - ["review_focus"] == baseline.keys,
          "a review_focus field changes nothing else in the program record")
    check(!record.key?("review_focus_omitted"), "a focus list inside its limit carries no omission record")

    reordered = Marshal.load(Marshal.dump(context))
    reordered["review_focus"] = {
      "deleted" => ["docs/gone.md"], "added" => ["", "lib/new.rb"],
      "modified" => ["lib/a.rb", "lib/a.rb", "lib/z.rb"]
    }
    check(context_json(reordered) == context_json(context),
          "focus key and path order does not change the rendered record")
    check(!baseline.key?("review_focus"), "a context without review_focus does not invent one")
  end

  def check_review_focus_is_bounded_and_traceable
    context = base_context
    added = (1..220).map { |i| format("src/added-%03d.rb", i) }
    modified = (1..30).map { |i| format("src/modified-%03d.rb", i) }
    context["review_focus"] = { "added" => added, "modified" => modified, "deleted" => [] }
    json = context_json(context)
    check(json.bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT,
          "an oversized focus list stays within the hard byte cap")
    record = JSON.parse(json)
    limit = Orbit::CheckRunner::CONTEXT_CAPS.fetch(:review_focus_limit)
    check(record.dig("review_focus", "added") == added.first(limit),
          "an oversized focus category keeps its first #{limit} paths in a stable order")
    check(record.dig("review_focus", "modified") == modified,
          "one oversized focus category does not starve the others")
    check(record.dig("review_focus", "deleted") == [], "an empty focus category stays explicit")
    omitted = added.drop(limit)
    check(record.dig("review_focus_omitted", "count") == omitted.length,
          "the omitted focus path count is recorded")
    check(record.dig("review_focus_omitted", "ids") == omitted.last(50),
          "the omitted focus paths that fit are kept")
    check(record.dig("review_focus_omitted", "ids_sha256") == Digest::SHA256.hexdigest(JSON.generate(omitted)),
          "the digest covers every omitted focus path")
    check(record.dig("findings", "f-1", "evidence") == "missing b", "open findings keep their priority")
  end

  def check_review_focus_prompt_policy
    context = base_context
    context["review_focus"] = { "added" => ["lib/new.rb"], "modified" => [], "deleted" => ["lib/old.rb"] }
    prompt = runner.send(
      :build_prompt, snapshot: "/unused", inputs: { "instruction" => "do the original thing" },
      context: context, role: "reviewer"
    )
    check(prompt.include?("review_focus"), "the reviewer prompt names review_focus")
    check(prompt.include?("direct dependencies first"), "the reviewer starts from focus and direct dependencies")
    check(prompt.include?("extend to whatever the original instruction"),
          "the reviewer still expands to the full requirement")
    check(prompt.include?("priority clue, not a scope limit"),
          "the reviewer is told review_focus is not a scope limit")
    check(prompt.include?("never ignore a requirement because its files are not listed"),
          "the reviewer must not skip requirements whose files are unlisted")
    check(prompt.include?("lib/new.rb") && prompt.include?("lib/old.rb"),
          "the focus paths reach the program record")
    check(prompt.include?("## Original instruction (verbatim)\n\ndo the original thing"),
          "the original instruction is still verbatim")
    check(prompt.include?("## Fixed artifact snapshot"), "the fixed snapshot section is still present")
    check(prompt.include?("Pending clues from a check that went stale"),
          "the pending clues are still present")

    plain = runner.send(
      :build_prompt, snapshot: "/unused", inputs: { "instruction" => "do the original thing" },
      context: base_context, role: "reviewer"
    )
    check(!plain.include?("priority clue, not a scope limit"),
          "no focus policy is added when the record carries no review_focus")
  end

  def check_non_hash_context_is_bounded
    check(compress("short context") == "short context", "a small raw context passes through unchanged")
    text = "raw-" + long_text("raw", 90_000)
    bounded = compress(text)
    check(bounded.bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT &&
          bounded.start_with?("raw-") &&
          bounded.end_with?("…[#{text.length}:#{Digest::SHA256.hexdigest(text)}]"),
          "a raw context is byte-bounded with a prefix, original length and SHA-256")
    entries = (1..200).map { |i| long_text("entry-#{i}", 3_000) }
    rendered = JSON.generate(compress(entries))
    check(rendered.bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT, "an array context stays within the hard byte cap")
    JSON.parse(rendered)
  end
end

CheckRunnerContextTest.run
