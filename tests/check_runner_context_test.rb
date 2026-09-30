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


  # A real 0.7.20 check showed the loss: the independent check received only the
  # two NEWEST receipts (both control-URI write receipts) while the program's
  # own `node --test` bash receipt - still current for that input and artifact -
  # was dropped when byte pressure halved list_limit down to 2. Selection must
  # keep current execution evidence, count the omission, and never promote an
  # old binding or hide a failure.
  def current_execution_receipts_survive_degraded_caps
    passed = { "at" => "2026-09-30T09:50:00.330Z", "at_ms" => 1790761800330, "tool" => "bash", "kind" => "root_verification",
               "status" => "completed", "command" => "node --test", "exit_code" => 0,
               "exit_code_source" => "sdk_terminal_success_contract", "output" => "tests 8, pass 8, fail 0",
               "output_saved" => true, "input_matches" => true, "artifact_matches" => true,
               "artifact_digest" => "sha256:#{'a' * 8}" }
    failed = passed.merge("at" => "2026-09-30T09:49:27.851Z", "exit_code" => 1, "status" => "failed",
                          "exit_code_source" => "reported", "command" => "node -e 'process.exit(1)'", "output" => "1 failing test")
    old_binding = passed.merge("at" => "2026-09-30T09:10:00.000Z", "input_matches" => false)
    control = ->(at, target) { { "at" => at, "at_ms" => 1790761819000, "tool" => "write", "kind" => "root_verification",
                                "status" => "completed", "control_targets" => [target], "targets_status" => "control_uri",
                                "exit_code" => nil, "exit_code_source" => "not_applicable", "output" => nil,
                                "output_saved" => false, "input_matches" => true, "artifact_matches" => true } }
    receipts = [old_binding, failed, passed, control.call("2026-09-30T09:50:19.196Z", "xd://report_issue"),
                control.call("2026-09-30T09:50:29.274Z", "xd://orbit")]

    # The real 0.7.20 check reached this degraded budget (list_limit 2) and the
    # checker received only the two newest control-URI writes. Everything below
    # reads the JSON the checker would actually get: build the bounded context
    # with the production caps except the known degraded list budget, render it
    # and parse it back.
    caps = Orbit::CheckRunner::CONTEXT_CAPS.merge(list_limit: 2)
    bounded = runner.send(:build_compressed_context, { "root_verifications" => receipts, "root" => {} }, caps, 4)
    parsed = JSON.parse(runner.send(:render_context, bounded))
    delivered = parsed["root_verifications"]
    check(delivered.length == 2, "the degraded budget delivers exactly its two receipt slots")
    check(parsed["root_verifications_omitted"] == 3,
          "the delivered JSON states how many receipts were omitted")
    check(delivered.map { |r| r["at"] } == [failed["at"], passed["at"]],
          "the delivered receipts are the current execution evidence, in their original order")
    check(delivered.all? { |r| r["tool"] == "bash" } &&
          delivered.map { |r| r["exit_code"] } == [1, 0] &&
          delivered.map { |r| r["exit_code_source"] } == %w[reported sdk_terminal_success_contract] &&
          delivered.map { |r| r["status"] } == %w[failed completed],
          "the delivered JSON keeps the real exit, exit source and status, including the failure")
    original = receipts.to_h { |r| [r["at"], r] }
    check(delivered.all? { |r| r["input_matches"] == original.fetch(r["at"])["input_matches"] &&
                              r["artifact_matches"] == original.fetch(r["at"])["artifact_matches"] },
          "the delivered JSON never rewrites a receipt binding")
    check(delivered.none? { |r| r["input_matches"] == false },
          "a receipt from an older input binding is not delivered as current evidence")
    check(JSON.generate(parsed).bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT,
          "the delivered JSON still fits the hard byte cap")
  end

  # Existing behaviour stays: with plenty of room nothing is omitted and the
  # original order is preserved.
  def root_verifications_keep_order_when_they_fit
    receipts = (1..3).map do |i|
      { "at" => "2026-09-30T09:5#{i}:00Z", "at_ms" => i, "tool" => "bash", "status" => "completed",
        "command" => "node --test ##{i}", "exit_code" => 0, "exit_code_source" => "sdk_terminal_success_contract",
        "output" => "ok", "input_matches" => true, "artifact_matches" => true }
    end
    compressed = compress({ "root_verifications" => receipts, "root" => {} })
    check(compressed["root_verifications"].map { |r| r["at"] } == receipts.map { |r| r["at"] },
          "receipts stay in their original order when they fit")
    check(compressed["root_verifications_omitted"].nil?, "no omission is reported when nothing was dropped")
  end

  def long_text(marker, size = 4_000)
    "#{marker}-start-" + ("x" * size) + "-#{marker}-tail"
  end

  def bound_text(original)
    prefix = original[0, Orbit::CheckRunner::CONTEXT_STRING_CAP]
    "#{prefix}…[#{original.length}:#{Digest::SHA256.hexdigest(original)}]"
  end

  def bound_at(text, cap)
    "#{text[0, cap]}…[#{text.length}:#{Digest::SHA256.hexdigest(text)}]"
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
    check_delivery_prompt_contract_and_validation
    check_verification_truncation_is_explicit
    check_delivered_answer_gets_wider_verbatim_prefix
    check_review_focus_is_explicit_and_deterministic
    check_review_focus_is_bounded_and_traceable
    check_non_hash_context_is_bounded
    check_check_history_stays_bounded_and_traceable
    current_execution_receipts_survive_degraded_caps
    root_verifications_keep_order_when_they_fit
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

  def check_delivery_prompt_contract_and_validation

    valid = {
      "verdict" => "continue", "reason" => "work in progress", "findings" => [],
      "resolved_ids" => [], "next_check_seconds" => 60,
      "delivery" => { "ready" => false, "reason" => "final answer not yet visible in root observations" }
    }
    check(runner.send(:validate_result, valid) == valid, "a result with a structured delivery validates")

    missing = Marshal.load(Marshal.dump(valid)).tap { |result| result.delete("delivery") }
    rejects(missing, "missing keys: delivery")
    string_ready = Marshal.load(Marshal.dump(valid))
    string_ready["delivery"]["ready"] = "yes"
    rejects(string_ready, "delivery.ready must be a boolean")
    empty_reason = Marshal.load(Marshal.dump(valid))
    empty_reason["delivery"]["reason"] = ""
    rejects(empty_reason, "delivery.reason must be a non-empty string")
    extra_key = Marshal.load(Marshal.dump(valid))
    extra_key["delivery"]["evidence"] = "snapshot"
    rejects(extra_key, "delivery has unexpected keys")
  end

  def rejects(result, expected)
    runner.send(:validate_result, result)
    raise "ASSERTION FAILED: expected rejection mentioning #{expected}"
  rescue Orbit::CheckRunner::Error => error
    check(error.message.include?(expected), "the contract rejects: #{expected}")
  end

  def check_verification_truncation_is_explicit
    context = base_context
    context["root_verifications"] = [{ "tool_call_id" => "actual-tests", "command" => "npm test",
      "exit_code" => 0, "artifact_matches" => true, "input_matches" => false,
      "output" => long_text("tests", 4_000), "output_truncated" => false }]
    receipt = parsed(context).fetch("root_verifications").first
    check(receipt["output_truncated"] == true && receipt["output"].include?("…["),
          "context compression cannot silently turn partial tool output into complete test evidence")
    check(receipt["tool_call_id"] == "actual-tests" && receipt["input_matches"] == false &&
          receipt["artifact_matches"] == true && receipt["exit_code"] == 0,
          "receipt identity, version flags and actual exit survive compression")
  end

  def check_delivered_answer_gets_wider_verbatim_prefix
    answer = "final answer\n" + ("a" * 6_000)
    command = { "kind" => "command", "tool" => "bash", "aggregated_output" => "x" * 3_500 }
    context = base_context
    context["root"]["observations"] = [{ "kind" => "agent_message", "text" => answer }, command]
    record = parsed(context)["root"]["observations"]
    cap = Orbit::CheckRunner::CONTEXT_DELIVERY_TEXT_CAP
    check(record[0]["text"] == "#{answer[0, cap]}…[#{answer.length}:#{Digest::SHA256.hexdigest(answer)}]",
          "the delivered agent message keeps a wider verbatim prefix")
    output = "x" * 3_500
    check(record[1]["aggregated_output"] == bound_at(output, Orbit::CheckRunner::CONTEXT_STRING_CAP),
          "ordinary observations stay at the standard string cap")
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

  # History-gap ticket: the check-history channel survives compression, keeps
  # the current-input anchor, and reports what it dropped instead of hiding it.
  def check_check_history_stays_bounded_and_traceable
    recent = (3..12).map { |number| { "number" => number, "role" => "reviewer", "kind" => "artifact" } }
    context = base_context.merge("check_history" => {
      "eligibility" => "history facts only; not current completion eligibility",
      "current_input_digest" => "sha256:in", "current_artifact_digest" => "sha256:art",
      "total_checks" => 41,
      "anchor" => { "number" => 2, "terminal" => "stale", "stale_reasons" => ["workspace"] },
      "recent" => recent, "omitted_count" => 35, "omitted_numbers" => [1, 2],
      "amendments" => [{ "at" => "2026-09-30T05:10:00Z", "input_digest_after" => "sha256:a" }]
    })
    record = parsed(context).fetch("check_history")
    check(record["anchor"]["number"] == 2, "the current-input anchor survives context compression")
    check(record["recent"].last["number"] == 12 && record["recent"].length <= 6,
          "the recent window stays bounded and keeps the newest entries")
    check(record["recent_omitted"] == recent.length - record["recent"].length,
          "dropped recent entries are counted, never silently absent")
    check(record["omitted_count"] == 35 && record["omitted_numbers"] == [1, 2],
          "the omission facts stay traceable after compression")
    check(record["eligibility"].include?("not current completion eligibility"),
          "the channel keeps its history-only disclaimer")
    check(JSON.generate(compress(context)).bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT,
          "the check-history channel stays inside the 64KiB cap")
    over = base_context.merge("check_history" => {
      "eligibility" => "history facts only; not current completion eligibility",
      "current_input_digest" => "sha256:in", "current_artifact_digest" => "sha256:art", "total_checks" => 999,
      "anchor" => { "number" => 1, "terminal" => "stale" },
      "recent" => (1..200).map { |number| { "number" => number, "evidence" => long_text("h#{number}", 2_000) } },
      "omitted_count" => 800, "omitted_numbers" => (1..20).to_a, "amendments" => []
    })
    rendered = JSON.generate(compress(over))
    check(rendered.bytesize <= Orbit::CheckRunner::CONTEXT_BYTE_LIMIT && JSON.parse(rendered),
          "a huge check history still yields valid JSON inside the cap")
    check(JSON.parse(rendered).dig("check_history", "anchor", "number") == 1,
          "even under pressure the anchor is not dropped before the recent tail")
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
