# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/orbit/task_runtime"
require_relative "../lib/orbit/connection"

# TaskRuntime roster reconciliation does not call the member bridge.
ENV["XDG_CONFIG_HOME"] = Dir.mktmpdir("orbit-native-member-config-")

class NativeHost
  attr_reader :messages, :stop_calls, :created, :started

  def initialize(root)
    @root = root
    @messages = []
    @stop_calls = 0
    @created = []
    @started = []
    @state = { "thread_id" => "root", "cwd" => root, "status" => "idle",
               "last_turn_id" => "turn-1", "last_turn_status" => "completed", "observations" => [] }
  end

  def state = @state.dup
  def connect! = self
  def close = true
  def events = []
  def user_messages(after_id:) = []
  def configured_model = "zhipu-coding-plan/glm-5.2"
  def default_member_model = configured_model

  def send_message(text)
    @messages << text
    { "id" => "sent-#{@messages.length}" }
  end

  def stop!
    @stop_calls += 1
    { "confirmed" => true, "scope" => "root double" }
  end

  def create_member(model:, cwd:)
    @created << [model, cwd]
    raise "create_member must not be called"
  end

  def start_member(id, _text)
    @started << id
    raise "start_member must not be called"
  end

  def member_connection(_id)
    raise "old member connection must not be used for a native task id"
  end
end

class BridgedHost < NativeHost
  attr_reader :order, :member_stops, :sent_members
  attr_accessor :stop_result

  def initialize(root)
    super
    @order = []
    @member_stops = []
    @sent_members = []
    @stop_result = { "confirmed" => true, "active_tools_after" => 0, "async_jobs_settled" => true }
    @registry_status = "idle"
    @accepted_at = nil
    @output_path = "/tmp/member-out"
    @output_text = "native task finished"
  end

  def stop!
    @order << :root
    super
  end

  def stop_member(id)
    @order << :member
    @member_stops << id
    @stop_result.merge("id" => id)
  end

  def member_state(id)
    lifecycle = @accepted_at ? { "acceptedAt" => @accepted_at } : nil
    { "id" => id, "model" => "zhipu-coding-plan/glm-5.2", "registry_status" => @registry_status || "idle",
      "output_path" => @output_path, "lifecycle" => lifecycle }
  end

  def member_result(id)
    { "id" => id, "output_text" => @output_text, "output_path" => @output_path }
  end

  def hub_events
    @hub_events || { "events" => [], "dropped_oldest" => 0, "next_seq" => 1, "buffer_cap" => 500 }
  end

  attr_writer :hub_events

  attr_accessor :fail_send

  def send_member(id, text)
    raise Orbit::Connection::Error, "delivery rejected" if @fail_send

    @sent_members << [id, text]
    { "id" => id, "action" => "native_custom_message" }
  end
end

class NativeChecker
  def start(**) = nil
  def poll = nil
  def stop! = nil
  def usage = nil
end

module OmpNativeMemberTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def events(record)
    File.readlines(File.join(record.path, "events.jsonl")).map { |line| JSON.parse(line) }
  end

  def open_task(host_class = NativeHost)
    root = Dir.mktmpdir("orbit-native-member-")
    File.write(File.join(root, "artifact.txt"), "work")
    record = Orbit::TaskRecord.create(
      project_root: root, instruction: "Do the native task.\n",
      source: { "id" => "original", "kind" => "omp_user_message" },
      connection: { "provider" => "omp", "thread_id" => "root", "socket" => File.join(root, "host.sock") },
      review: { "interval_seconds" => 300 }, estimate: {}
    )
    host = host_class.new(root)
    runtime = Orbit::TaskRuntime.new(record: record, connection: host, checker: NativeChecker.new)
    [root, record, host, runtime]
  end

  def register(record, id, status: "registered", **extra)
    result = record.register_member(id, requested_name: id, status: status, **extra)
    raise result.inspect unless result["ok"]
  end

  def reconciles_persistent_ids_without_creating_members
    root, record, host, runtime = open_task
    register(record, "orbit-native-1", model: "zhipu-coding-plan/glm-5.2")
    register(record, "orbit-refused-1", status: "refused", reason: "registration_failed")
    runtime.tick(now: Time.now.to_f)
    ids = record.state["members"].map { |member| member["thread_id"] }
    assert(ids.sort == %w[orbit-native-1 orbit-refused-1], "crash-visible members.json ids are adopted: #{ids}")
    assert(host.created.empty? && host.started.empty?, "reconciliation does not create or start members")
    assert(host.messages.none? { |text| text.include?("Orbit execution member result") },
           "a native task result already delivered to Root is not privately repeated")
    runtime.tick(now: Time.now.to_f + 1)
    assert(record.state["members"].length == 2, "a second tick does not duplicate ids")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def records_hint_follow_for_a_reconciled_native_task
    root, record, _host, runtime = open_task
    signature = runtime.send(:delegation_signature, runtime.send(:fingerprint_artifact), runtime.send(:delegation_options))
    state = runtime.instance_variable_get(:@state)
    state["delegation_hint"] = { "signature" => signature, "followed" => false, "kind" => "omp" }
    record.save(state)
    register(record, "orbit-hinted")
    runtime.tick(now: Time.now.to_f)
    member = record.state["members"].find { |entry| entry["thread_id"] == "orbit-hinted" }
    assert(member["delegation_basis"] == "orbit_hint", "a current hint is the basis of the native task")
    assert(events(record).any? { |event| event["type"] == "delegation_hint_followed" && event["thread_id"] == "orbit-hinted" },
           "following the hint is recorded")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def does_not_confirm_stop_without_an_accepted_member_bridge
    root, record, host, runtime = open_task
    register(record, "orbit-live")
    runtime.retry_stop("explicit stop after crash")
    state = record.state
    assert(state["members"].any? { |member| member["thread_id"] == "orbit-live" }, "stop retry rediscovers the persistent id")
    assert(state["status"] == "stop_unconfirmed", "unconfirmed member execution stays stop_unconfirmed")
    assert(state["error"].to_s.include?("native member stop bridge is unreachable"), state["error"].to_s)
    assert(host.stop_calls == 1, "Root stop is still attempted")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def refused_label_does_not_confirm_stop
    root, record, host, runtime = open_task
    register(record, "orbit-refused-only", status: "refused", reason: "id_drift")
    runtime.retry_stop("stop with only a refused id")
    state = record.state
    assert(state["status"] == "stop_unconfirmed", "a refused label is not stop evidence: #{state['status']} #{state['error']}")
    assert(state["error"].to_s.include?("native member stop bridge is unreachable"), state["error"].to_s)
    assert(state["members"].first["stop_confirmation"].nil?, "refusal must not be rewritten as confirmed stop")
    assert(host.stop_calls == 1, "Root stop is still attempted")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def malformed_roster_entry_fails_closed
    root, record, _host, runtime = open_task
    File.write(File.join(record.path, "members.json"), JSON.generate([{ "status" => "registered" }]))
    runtime.retry_stop("stop with a malformed roster")
    state = record.state
    assert(state["status"] == "stop_unconfirmed", "a roster entry without thread_id cannot be skipped")
    assert(state["error"].to_s.include?("missing a thread_id"), state["error"].to_s)
    assert(state.fetch("members", []).empty?, "a malformed roster must not be partially adopted")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def corrupt_roster_still_stops_known_ids_as_unconfirmed
    root, record, host, runtime = open_task
    runtime.instance_variable_get(:@state)["members"] << {
      "kind" => "omp", "adapter" => "omp_native_task", "thread_id" => "orbit-known", "status" => "registered"
    }
    File.write(File.join(record.path, "members.json"), "{not json")
    runtime.retry_stop("stop with a corrupt roster")
    state = record.state
    assert(state["status"] == "stop_unconfirmed", "a corrupt roster cannot become failed or paused: #{state['status']}")
    assert(state["error"].to_s.include?("not a reliable roster") && state["error"].include?("orbit-known"), state["error"].to_s)
    assert(host.stop_calls == 1, "Root stop is still attempted when the roster cannot be read")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def unknown_status_is_not_treated_as_registered
    root, record, host, runtime = open_task
    File.write(File.join(record.path, "members.json"), JSON.generate([
      { "thread_id" => "orbit-a", "requested_name" => "orbit-a", "status" => "aborted" },
      { "thread_id" => "orbit-a", "requested_name" => "orbit-a", "status" => "registered" }
    ]))
    runtime.retry_stop("stop with an uncertain roster")
    state = record.state
    assert(state["status"] == "stop_unconfirmed", "an unknown status is uncertain, not registered")
    assert(state["error"].to_s.include?("unknown status"), state["error"].to_s)
    assert(state.fetch("members", []).none? { |member| member["thread_id"] == "orbit-a" }, "an uncertain roster is not adopted")
    assert(host.stop_calls == 1, "Root stop is still attempted")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def confirmed_member_stop_precedes_root_stop
    root, record, host, runtime = open_task(BridgedHost)
    register(record, "orbit-live")
    runtime.retry_stop("stop after measured member exit")
    state = record.state
    assert(host.order == [:member, :root], "native members are confirmed before Root abort: #{host.order}")
    assert(host.member_stops == ["orbit-live"], "stop uses the persistent id")
    assert(state["status"] == "paused", state["error"].to_s)
    assert(state["members"].first["stop_confirmation"]["active_tools_after"] == 0, "confirmation keeps the measured tool count")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def partial_stop_member_reply_stays_unconfirmed
    root, record, host, runtime = open_task(BridgedHost)
    host.stop_result = { "confirmed" => true }
    register(record, "orbit-live")
    runtime.retry_stop("stop with an incomplete bridge reply")
    state = record.state
    assert(state["status"] == "stop_unconfirmed", "confirmed without measured tools is not a stop")
    assert(state["error"].to_s.include?("did not confirm idle tools"), state["error"].to_s)
    assert(host.order == [:member, :root], "Root is still stopped after the member attempt")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def native_result_is_recorded_without_a_private_message
    root, record, host, runtime = open_task(BridgedHost)
    register(record, "orbit-done", model: "pending/model")
    runtime.tick(now: Time.now.to_f)
    member = record.state["members"].find { |entry| entry["thread_id"] == "orbit-done" }
    assert(member["model"] == "zhipu-coding-plan/glm-5.2", "state takes the bridge model")
    assert(member["output_path"] == "/tmp/member-out" && member["status"] == "registered",
           "output path is only the result location")
    assert(member["result_delivery"].nil?, "an unaccepted path is not recorded as delivered")
    assert(host.messages.none? { |text| text.include?("Orbit execution member result") }, "Root is not privately sent the native result")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def idle_without_acceptance_does_not_settle
    root, record, host, runtime = open_task(BridgedHost)
    host.instance_variable_set(:@output_path, nil)
    host.instance_variable_set(:@output_text, nil)
    host.instance_variable_set(:@accepted_at, nil)
    register(record, "orbit-idle")
    runtime.tick(now: Time.now.to_f)
    member = record.state["members"].find { |entry| entry["thread_id"] == "orbit-idle" }
    assert(member["status"] == "registered", "idle without acceptedAt or outputPath is not finished")
    assert(runtime.send(:members_settled?) == false, "an unsettled native member blocks finalization")
    assert(runtime.send(:member_blocks_new_hint?, member), "registered without terminal evidence stays active for hints")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def accepted_or_parked_with_output_settles
    root, record, host, runtime = open_task(BridgedHost)
    host.instance_variable_set(:@output_path, "/tmp/still-running")
    host.instance_variable_set(:@accepted_at, 1_700_000_000_000)
    host.instance_variable_set(:@registry_status, "running")
    register(record, "orbit-running")
    runtime.tick(now: Time.now.to_f)
    running = record.state["members"].find { |entry| entry["thread_id"] == "orbit-running" }
    assert(running["status"] == "registered" && running["result_delivery"].nil?,
           "acceptedAt while running is not a delivered result")
    host.instance_variable_set(:@registry_status, "idle")
    host.instance_variable_set(:@output_path, nil)
    register(record, "orbit-accepted")
    runtime.tick(now: Time.now.to_f + 1)
    accepted = record.state["members"].find { |entry| entry["thread_id"] == "orbit-accepted" }
    assert(accepted["status"] == "completed" && accepted["result_delivery"] == "native_task",
           "nested lifecycle.acceptedAt while not running is the delivery boundary")
    runtime.tick(now: Time.now.to_f + 1.5)
    recorded = events(record).count { |event| event["type"] == "member_result_recorded" && event["thread_id"] == "orbit-accepted" }
    assert(recorded == 1, "a repeated accepted observation does not append another event")
    host.instance_variable_set(:@registry_status, "parked")
    host.instance_variable_set(:@accepted_at, 1_700_000_000_001)
    register(record, "orbit-parked")
    runtime.tick(now: Time.now.to_f + 2)
    parked = record.state["members"].find { |entry| entry["thread_id"] == "orbit-parked" }
    assert(parked["status"] == "completed", "parked after acceptance is a finished release")
    host.instance_variable_set(:@registry_status, "aborted")
    host.instance_variable_set(:@accepted_at, nil)
    register(record, "orbit-aborted")
    runtime.tick(now: Time.now.to_f + 3)
    aborted = record.state["members"].find { |entry| entry["thread_id"] == "orbit-aborted" }
    assert(aborted["status"] == "failed" && aborted["result_delivery"].nil?, "aborted is failed and not a native delivery")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def amendment_delivery_failure_stays_visible
    root, record, host, runtime = open_task(BridgedHost)
    host.fail_send = true
    register(record, "orbit-active")
    runtime.tick(now: Time.now.to_f)
    runtime.send(:add_amendment, "use the new limit", { "kind" => "omp_user_message", "id" => "m2" })
    failed = events(record).find { |event| event["type"] == "member_amendment_failed" && event["thread_id"] == "orbit-active" }
    assert(failed && failed["error"].include?("delivery rejected"), "a rejected send_member is visible")
    state = record.state
    assert(state["error"].to_s.include?("did not receive the amendment"), state["error"].to_s)
    assert(state["members"].first["amendment_delivery"] == "pending", "the member is not treated as having received the change")
    assert(runtime.send(:members_settled?) == false, "a missed amendment must not advance completion")
    assert(host.sent_members.empty?, "a failed send is not recorded as delivered")
    assert(host.messages.any? { |text| text.include?("could not deliver") }, "Root is told the delivery failed")
    queue = state["amendment_delivery_queue"]
    assert(queue.length == 1 && queue.first["source_id"] == "m2", "the failed amendment stays queued by member and source")
    before = events(record).count { |event| event["type"] == "member_amendment_failed" }
    runtime.tick(now: Time.now.to_f + 1)
    after = events(record).count { |event| event["type"] == "member_amendment_failed" }
    assert(after == before, "the same delivery error is not recorded again on the next tick")
    assert(record.state["status"] != "needs_user", "an active member keeps retrying instead of a fixed attempt cap")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def delivered_amendment_clears_and_terminal_member_needs_user
    root, record, host, runtime = open_task(BridgedHost)
    host.fail_send = true
    register(record, "orbit-active")
    runtime.tick(now: Time.now.to_f)
    runtime.send(:add_amendment, "use the new limit", { "kind" => "omp_user_message", "id" => "m2" })
    host.fail_send = false
    runtime.tick(now: Time.now.to_f + 1)
    state = record.state
    assert(Array(state["amendment_delivery_queue"]).empty?, "a later successful send clears the pending amendment")
    assert(state["members"].first["amendment_delivery"] == "sent", "the member is marked as having received it")
    host.fail_send = true
    runtime.send(:add_amendment, "one more limit", { "kind" => "omp_user_message", "id" => "m3" })
    host.instance_variable_set(:@accepted_at, 1_700_000_000_000)
    host.instance_variable_set(:@registry_status, "idle")
    runtime.tick(now: Time.now.to_f + 2)
    final = record.state
    assert(final["status"] == "needs_user", "a finished member with an undelivered amendment needs the user: #{final['error']}")
    assert(Array(final["amendment_delivery_queue"]).any? { |item| item["source_id"] == "m3" }, "the pending amendment evidence is kept")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def persists_task_scoped_hub_events_once
    root, record, host, runtime = open_task(BridgedHost)
    host.hub_events = {
      "events" => [
        { "id" => "collab-1", "seq" => 1, "kind" => "hub_call", "op" => "send", "from" => "root", "to" => "orbit-a", "agent_id" => "root", "message" => "please check the limit" },
        { "id" => "collab-2", "seq" => 2, "kind" => "hub_call", "op" => "wait", "from" => "orbit-a", "await_reply" => true },
        { "id" => "collab-3", "seq" => 3, "kind" => "hub_result", "agent_id" => "orbit-a", "ok" => true, "text" => "done" }
      ],
      "dropped_oldest" => 0, "next_seq" => 4, "buffer_cap" => 500
    }
    runtime.tick(now: Time.now.to_f)
    runtime.tick(now: Time.now.to_f + 1)
    recorded = events(record).select { |event| event["type"] == "native_collaboration" }
    assert(recorded.length == 3, "each hub event is recorded once")
    assert(recorded.map { |event| event["op"] } == ["send", "wait", nil], "message, wait, and result stay attributable")
    assert(recorded.first["from"] == "root" && recorded.first["to"] == "orbit-a", "attribution is kept")
    assert(record.state["native_collaboration"].length == 3, "the collaboration is visible in task state")
    assert(record.state["native_collaboration_observation_gap"].nil?, "a contiguous first read is not a gap")
    assert(record.state["hub_last_seq"] == 3, "the per-task cursor is persisted")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def native_collaboration_gap_follows_per_task_seq
    root, record, host, runtime = open_task(BridgedHost)
    host.hub_events = { "events" => [{ "id" => "collab-2", "seq" => 2, "kind" => "hub_call", "op" => "send" }],
                        "dropped_oldest" => 1, "next_seq" => 3, "buffer_cap" => 500 }
    runtime.tick(now: Time.now.to_f)
    possible = record.state["native_collaboration_observation_gap"]
    assert(possible["status"] == "possible_loss" && possible["first_seq"] == 2 && possible["dropped_oldest"] == 1,
           "a first read past seq 1 is a possible loss")
    assert(record.state["hub_last_seq"] == 2, "last seq is kept after the possible loss")
    host.hub_events = { "events" => [{ "id" => "collab-4", "seq" => 4, "kind" => "hub_result", "ok" => true }],
                        "dropped_oldest" => 1, "next_seq" => 5, "buffer_cap" => 500 }
    runtime.tick(now: Time.now.to_f + 1)
    confirmed = record.state["native_collaboration_observation_gap"]
    assert(confirmed["status"] == "confirmed_gap" && confirmed["first_new_seq"] == 4, "a jumped new seq is a confirmed gap")
    host.hub_events = { "events" => [], "dropped_oldest" => 0, "next_seq" => 1, "buffer_cap" => 500 }
    runtime.tick(now: Time.now.to_f + 2)
    reset = record.state["native_collaboration_observation_gap"]
    assert(reset["status"] == "reset_unconfirmed" && reset["next_seq"] == 1, "a rolled-back cursor is not treated as no activity")
    assert(record.state["hub_last_seq"] == 4, "a restart does not rewind the persisted cursor")
    before = events(record).count { |event| event["type"] == "native_collaboration_observation_gap" }
    runtime.tick(now: Time.now.to_f + 3)
    after = events(record).count { |event| event["type"] == "native_collaboration_observation_gap" }
    assert(after == before, "the same reset is not recorded again")
  ensure
    FileUtils.remove_entry(root) if root
  end

  def run
    reconciles_persistent_ids_without_creating_members
    records_hint_follow_for_a_reconciled_native_task
    does_not_confirm_stop_without_an_accepted_member_bridge
    confirmed_member_stop_precedes_root_stop
    partial_stop_member_reply_stays_unconfirmed
    native_result_is_recorded_without_a_private_message
    idle_without_acceptance_does_not_settle
    accepted_or_parked_with_output_settles
    refused_label_does_not_confirm_stop
    malformed_roster_entry_fails_closed
    corrupt_roster_still_stops_known_ids_as_unconfirmed
    unknown_status_is_not_treated_as_registered
    amendment_delivery_failure_stays_visible
    delivered_amendment_clears_and_terminal_member_needs_user
    persists_task_scoped_hub_events_once
    native_collaboration_gap_follows_per_task_seq
    puts "PASS omp native member reconciliation"
  end
end

OmpNativeMemberTest.run
