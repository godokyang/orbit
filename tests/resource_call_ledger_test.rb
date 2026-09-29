# frozen_string_literal: true

# The task call ledger must not lose or double count a call. These fixtures pin
# success/failure/pending/retry attribution, unknown-vs-zero usage and the
# refusal to add reported categories into one cost. No model is called.
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/orbit/resource_call_ledger"

module ResourceCallLedgerTest
  module_function

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition
  end

  def with_ledger
    Dir.mktmpdir("orbit-resource-ledger-") do |root|
      yield Orbit::ResourceCallLedger.new(task_path: root, task_id: "task-1",
                                          clock: -> { Time.utc(2026, 9, 29, 12, 0, 0) })
    end
  end

  def judgment_receipt(call_id, usage:, status: "answered", model: "jev-actual")
    { "call_id" => call_id, "provider" => "typesafe", "actual_model" => model,
      "requested_model" => "jev-requested", "status" => status, "usage" => usage,
      "question_set_version" => "jev-candidates-1" }
  end

  def check_failed_and_pending_calls_are_recorded_once
    with_ledger do |ledger|
      failed = judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000001",
                                usage: { "input_tokens" => 120, "output_tokens" => 0 }, status: "unavailable")
      pending = judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000002",
                                 usage: { "input_tokens" => 80, "output_tokens" => 5 })
      check(ledger.record_judgment(failed, phase: "jev_stage2"), "a failed judgment is a recorded call")
      check(ledger.record_judgment(pending, phase: "jev_stage2"), "a pending judgment is a recorded call")
      check(ledger.record_judgment(failed, phase: "jev_stage2") == false,
            "replaying the same receipt is idempotent instead of adding a second call")

      summary = ledger.summary
      check(summary["call_count"] == 2, "both calls are counted once")
      check(summary["status_counts"] == { "completed" => 1, "failed" => 1, "unknown" => 0 },
            "a pending (answered) call is completed and a service failure is failed")
      group = summary["groups"].fetch(0)
      check(summary["groups"].length == 1 && group["call_count"] == 2,
            "calls of the same role, phase, identity and units aggregate together")
      check(group["usage_fields"]["input_tokens"]["reported_sum"] == 200 &&
            group["usage_fields"]["input_tokens"]["missing_calls"] == 0,
            "reported input usage from both calls is aggregated with full coverage")
      check(group["usage_fields"]["output_tokens"]["reported_sum"] == 5 &&
            group["usage_fields"]["output_tokens"]["reported_calls"] == 2,
            "a reported zero is included in the sum and still counted as reported")
      check(summary["cost"].nil? && summary["quota_consumption"].nil?,
            "the ledger never derives money or quota consumption from tokens")
    end
  end

  def check_retry_is_a_new_call
    with_ledger do |ledger|
      first = judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000010",
                               usage: { "input_tokens" => 100, "output_tokens" => 1 }, status: "unavailable")
      retry_receipt = judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000011",
                                       usage: { "input_tokens" => 100, "output_tokens" => 2 })
      ledger.record_judgment(first, phase: "jev_stage1")
      ledger.record_judgment(retry_receipt, phase: "jev_stage1")

      summary = ledger.summary
      check(summary["call_count"] == 2, "a retry is its own call, not a replacement")
      check(summary["groups"].fetch(0)["status_counts"] == { "completed" => 1, "failed" => 1, "unknown" => 0 },
            "both the failed attempt and its retry stay visible")
    end
  end

  def check_unusable_usage_is_unknown_and_zero_is_kept
    with_ledger do |ledger|
      ledger.record_judgment(judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000020", usage: {}),
                             phase: "jev_entry")
      ledger.record_judgment(judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000021",
                                              usage: { "input_tokens" => "many", "output_tokens" => 3 }),
                             phase: "jev_entry")
      ledger.record_judgment(judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000022",
                                              usage: { "input_tokens" => 0, "output_tokens" => 0 }),
                             phase: "jev_entry")

      calls = ledger.calls
      check(calls[0]["usage"].nil?, "a missing report stays unknown")
      check(calls[1]["usage"] == { "output_tokens" => 3 }, "a partially usable report keeps only the usable fields")
      check(calls[1]["usage_note"].to_s.include?("input_tokens"), "the dropped field is named, not silently zeroed")
      check(calls[2]["usage"] == { "input_tokens" => 0, "output_tokens" => 0 },
            "a reported zero stays a reported zero")
      check(calls.map { |call| call["usage_status"] } == %w[unknown partial reported],
            "partial reported fields remain usable while their completeness is explicit")

      summary = ledger.summary
      check(summary["unknown_usage_calls"] == 1 && summary["noted_usage_calls"] == 1,
            "unknown usage and noted usage are counted separately")
      check(summary["partial_usage_calls"] == 1,
            "a call with only some usable fields cannot read as complete usage")
      group = summary["groups"].find { |item| item["usage_fields"].key?("output_tokens") }
      field = group["usage_fields"]["input_tokens"]
      check(field["reported_sum"] == 0 && field["reported_calls"] == 1 && field["missing_calls"] == 1,
            "a partially reported field reports its own coverage instead of a complete sum")
    end
  end

  def check_conflicting_replay_is_refused
    with_ledger do |ledger|
      id = "orbit-judgment-00000000-0000-4000-8000-000000000030"
      ledger.record_judgment(judgment_receipt(id, usage: { "input_tokens" => 10, "output_tokens" => 1 }), phase: "jev_entry")
      raised = false
      begin
        ledger.record_judgment(judgment_receipt(id, usage: { "input_tokens" => 999, "output_tokens" => 1 }), phase: "jev_entry")
      rescue Orbit::ResourceCallLedger::Error => error
        raised = error.message.include?("conflicting receipt")
      end
      check(raised, "a different payload for the same call id is an accounting conflict, not a second call")
      check(ledger.calls.fetch(0)["usage"]["input_tokens"] == 10, "the stored receipt is never overwritten")
    end
  end

  def check_missing_identity_is_not_the_requested_model
    with_ledger do |ledger|
      ledger.record(call_id: "orbit-check-1", role: "checker", phase: "check", status: "failed",
                    provider: "zhipu", actual_model: nil, usage: nil, usage_source: "provider_response",
                    usage_units: {}, requested_model: "glm-5.2", billing_route: "subscription_quota",
                    error: "provider returned 401")
      call = ledger.calls.fetch(0)
      check(call.dig("actual_identity", "model").nil? && call["requested_model"] == "glm-5.2",
            "the requested model never fills in for a missing actual model")
      check(call["status"] == "failed" && call["usage"].nil?,
            "a failed call without reported usage is recorded as failed and unknown")
      summary = ledger.summary
      check(summary["unknown_actual_model_calls"] == 1 && summary["unknown_usage_calls"] == 1,
            "unknown identity and unknown usage are both visible")
    end
  end

  def check_identities_and_phases_are_not_mixed
    with_ledger do |ledger|
      ledger.record(call_id: "orbit-check-2", role: "checker", phase: "check", status: "completed",
                    provider: "zhipu", actual_model: "glm-5.2", usage: { "input_tokens" => 40, "output_tokens" => nil },
                    usage_source: "provider_response", usage_units: { "input_tokens" => "token" },
                    requested_model: "glm-5.2", billing_route: "direct_api")
      ledger.record(call_id: "orbit-check-3", role: "checker", phase: "check", status: "completed",
                    provider: "zhipu", actual_model: "glm-5.2", usage: { "input_tokens" => 5, "output_tokens" => 1 },
                    usage_source: "provider_response", usage_units: { "input_tokens" => "token", "output_tokens" => "token" },
                    requested_model: "glm-5.2", billing_route: "direct_api")
      ledger.record(call_id: "orbit-check-4", role: "checker", phase: "check", status: "completed",
                    provider: "zhipu", actual_model: "glm-5.2", usage: { "input_tokens" => 7, "output_tokens" => 2 },
                    usage_source: "provider_response", usage_units: { "input_tokens" => "token", "output_tokens" => "token" },
                    requested_model: "glm-5.2", billing_route: "subscription_quota")

      summary = ledger.summary
      check(summary["groups"].length == 3,
            "a different billing route or a different unit declaration is never merged into one total")
      check(summary["call_count"] == 3 && summary["status_counts"]["completed"] == 3,
            "every completed check is recorded")
      route_group = summary["groups"].find { |item| item["actual_identity"]["billing_route"] == "subscription_quota" }
      check(route_group["usage_fields"]["input_tokens"]["reported_sum"] == 7,
            "the subscription-route group keeps only its own calls")
    end
  end

  def check_attempt_id_never_replaces_a_call_id
    with_ledger do |ledger|
      raised = false
      begin
        ledger.record_check({ "status" => "failed", "attempt_id" => "orbit-check-attempt-1",
                              "usage" => { "input" => 1, "output" => 1, "cacheRead" => 0 } }, phase: "check")
      rescue Orbit::ResourceCallLedger::Error => error
        raised = error.message.include?("check attempt id is not one")
      end
      check(raised, "a check attempt id is never accepted in place of an observed provider call id")

      check(ledger.record_check({ "call_id" => "orbit-call-1", "origin" => "local_provider_invocation",
                                  "attempt_id" => "orbit-check-attempt-1", "provider_response_id" => "req_9",
                                  "status" => "failed", "provider" => "zenmux", "actual_model" => "x-ai/grok-4.7",
                                  "requested_model" => "zenmux/x-ai/grok-4.7", "upstream_provider" => "Together",
                                  "usage" => { "input" => 120, "output" => 3, "cacheRead" => 0 } }, phase: "check"),
            "a failed provider call with its own id is recorded")
      call = ledger.calls.fetch(0)
      check(call["call_id"] == "orbit-call-1" && call["attempt_id"] == "orbit-check-attempt-1",
            "the call id keys the receipt and the attempt id only links the calls of that attempt")
      check(call["call_id_origin"] == "local_provider_invocation" && call["provider_response_id"] == "req_9",
            "a local boundary id is marked as such and the provider's own id is kept separately")
      check(call["actual_identity"]["model"] == "x-ai/grok-4.7" && call["requested_model"] == "zenmux/x-ai/grok-4.7",
            "the executed model and the requested name are recorded as different facts")
      check(call["upstream_identity"] == { "provider" => "Together", "model" => nil },
            "an unreported upstream model stays unknown instead of borrowing the executed model")
      check(call["category_relationships"] == "not_inferred" && call["relationship_note"].nil?,
            "without a declaration the field relationship stays unknown and no total is inferred")
      summary = ledger.summary
      check(summary["attempt_count"] == 1 && summary["calls_without_attempt"] == 0,
            "attempt linkage and its coverage are visible in the summary")
      check(summary["call_id_origins"] == { "local_provider_invocation" => 1 } &&
            summary["unknown_upstream_model_calls"] == 1,
            "the summary states how call ids were obtained and where the upstream model is unknown")

      ledger.record_check({ "call_id" => "resp-2", "attempt_id" => "orbit-check-attempt-1", "status" => "completed",
                            "provider" => "zenmux", "actual_model" => "x-ai/grok-4.7",
                            "usage" => { "input" => 10, "cacheRead" => 0, "output" => 1 },
                            "category_relationships" => "source_declared",
                            "relationship_note" => "OMP SDK Usage: reasoningTokens is a subset of output" }, phase: "check")
      declared = ledger.calls.fetch(1)
      check(declared["category_relationships"] == "source_declared" &&
            declared["relationship_note"].to_s.include?("subset"),
            "a caller-declared relationship is stored verbatim beside the reported fields, never as a total")

      raised = false
      begin
        ledger.record_check({ "call_id" => "resp-3", "status" => "completed", "usage" => { "input" => 1, "cacheRead" => 0, "output" => 1 },
                              "category_relationships" => "assumed_equals_total" }, phase: "check")
      rescue Orbit::ResourceCallLedger::Error => error
        raised = error.message.include?("category relationship")
      end
      check(raised, "an unlisted category-relationship claim is refused")
    end
  end

  def check_foreign_or_corrupt_ledger_is_refused
    Dir.mktmpdir("orbit-resource-ledger-") do |root|
      path = File.join(root, "resource-calls.json")
      File.write(path, JSON.generate(
        "schema_version" => Orbit::ResourceCallLedger::SCHEMA_VERSION, "task_id" => "other-task", "calls" => {}
      ))
      ledger = Orbit::ResourceCallLedger.new(task_path: root, task_id: "task-1")
      raised = false
      begin
        ledger.record_judgment(judgment_receipt("orbit-judgment-00000000-0000-4000-8000-000000000040",
                                                usage: { "input_tokens" => 1, "output_tokens" => 1 }), phase: "jev_entry")
      rescue Orbit::ResourceCallLedger::Error => error
        raised = error.message.include?("corrupt or belongs to another task")
      end
      check(raised, "another task's ledger is never adopted")
      check(JSON.parse(File.read(path))["task_id"] == "other-task",
            "a refused read leaves the foreign file untouched")
    end
  end

  def run
    check_failed_and_pending_calls_are_recorded_once
    check_retry_is_a_new_call
    check_unusable_usage_is_unknown_and_zero_is_kept
    check_conflicting_replay_is_refused
    check_missing_identity_is_not_the_requested_model
    check_identities_and_phases_are_not_mixed
    check_attempt_id_never_replaces_a_call_id
    check_foreign_or_corrupt_ledger_is_refused
    puts "PASS resource call ledger"
  end
end

ResourceCallLedgerTest.run
