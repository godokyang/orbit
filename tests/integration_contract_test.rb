# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/orbit/cli"

# Integration contract (contracts/integration.md + integration.json): a fake
# external caller, which only uses Orbit's public commands and the declared
# fields, drives the real CLI, task record, command queue, TaskRuntime tick,
# coverage store, stop path, status and export. The OMP Root session and the
# checker model are the two stand-ins at the boundary, so this proves the
# contract surface and its field shapes, not model behaviour or a real session.
module IntegrationContractTest
  ROOT = File.expand_path("..", __dir__)
  CONTRACT = JSON.parse(File.read(File.join(ROOT, "contracts/integration.json")))
  CHOSEN = "zhipu-coding-plan/glm-5.2"
  module_function

  def assert(value, message)
    raise "ASSERTION FAILED: #{message}" unless value
  end

  # The only door the fake caller has: the CLI, stdout JSON in, exit code out.
  def orbit(*argv)
    out, err = StringIO.new, StringIO.new
    previous = [$stdout, $stderr]
    $stdout, $stderr = out, err
    code = Orbit::CLI.run(argv.dup)
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = previous
  end

  def orbit_json(*argv)
    code, out, err = orbit(*argv)
    raise "orbit #{argv.first} failed (#{code}): #{err}" unless code == 0

    out.lstrip.start_with?("{\n") ? JSON.parse(out) : JSON.parse(out.lines.first)
  end

  # Stand-in for the OMP Root session: native messages and a model catalog.
  def session(cwd, messages)
    connection = Object.new
    connection.define_singleton_method(:connect!) { self }
    connection.define_singleton_method(:close) { nil }
    connection.define_singleton_method(:state) { { "cwd" => cwd, "status" => "idle" } }
    connection.define_singleton_method(:configured_model) { "other/model" }
    connection.define_singleton_method(:model_catalog) { { "current" => "other/model", "available" => ["other/model", CHOSEN], "families" => {} } }
    connection.define_singleton_method(:instruction_source_kind) { "omp_user_message" }
    connection.define_singleton_method(:user_message) { |id: nil| messages[id] && { "id" => id, "text" => messages[id], "internal" => false } }
    connection
  end

  class Host
    def initialize(root)
      @state = { "thread_id" => "root-session", "cwd" => root, "status" => "idle", "last_turn_id" => "t1",
                 "last_turn_status" => "completed", "observations" => ["t1"] }
    end

    def state = @state.dup
    def connect! = self
    def close = true
    def configured_model = "other/model"
    def default_member_model = configured_model
    def default_member_route = "direct_api"
    def events = []
    def user_messages(after_id:) = []
    def send_message(_text, **) = { "id" => "sent-1" }
    def stop! = { "confirmed" => true, "scope" => "contract test host" }
    def stop_member(_id) = { "confirmed" => true, "active_tools_after" => 0, "async_jobs_settled" => true }
  end

  class Checker
    attr_accessor :result

    def start(**) = (@result = nil)
    def poll = @result
    def stop! = true
  end

  def with_world
    Dir.mktmpdir("orbit-integration-contract-") do |tmp|
      project = File.join(tmp, "project")
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "artifact.txt"), "delivered")
      messages = { "m1" => "实现并验证 S12、S13", "m2" => "用户答复：继续", "m3" => "第三个独立要求", "m4" => "第四个独立要求" }
      connection = session(File.realpath(project), messages)
      env = %w[XDG_CONFIG_HOME XDG_CACHE_HOME].to_h { |key| [key, ENV[key]] }
      ENV["XDG_CONFIG_HOME"] = File.join(tmp, "xdg-config")
      ENV["XDG_CACHE_HOME"] = File.join(tmp, "xdg-cache")
      original_open = Orbit::Connection.method(:open)
      original_probe = Orbit::OmpCheckRunner.method(:probe_models)
      Orbit::Connection.define_singleton_method(:open) { |_record| connection }
      Orbit::OmpCheckRunner.define_singleton_method(:probe_models) { |models:, **_| { "resolvable" => models, "unresolvable" => [] } }
      stub = Module.new { define_method(:run) { { "status" => "paused" } } } # start --foreground must not loop
      Orbit::TaskRuntime.prepend(stub)
      yield tmp, project, connection
    ensure
      env&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      Orbit::Connection.define_singleton_method(:open, original_open) if original_open
      Orbit::OmpCheckRunner.define_singleton_method(:probe_models, original_probe) if original_probe
    end
  end

  def start(project, message, *extra)
    orbit_json("start", "--provider", "omp", "--project", project, "--thread", "root-session",
               "--socket", File.join(project, "unused.sock"), "--message-id", message,
               "--review-model", CHOSEN, "--foreground", *extra)
  end

  def runtime_for(dir, project, checker)
    Orbit::TaskRuntime.new(record: Orbit::TaskRecord.new(dir), connection: Host.new(File.realpath(project)), checker: checker)
  end

  def dig_all(value, path)
    path.split(".").reduce([value]) do |nodes, key|
      list = key.end_with?("[]")
      name = key.delete_suffix("[]")
      nodes.flat_map { |node| node.is_a?(Hash) && node.key?(name) ? (list ? Array(node[name]) : [node[name]]) : [] }
    end
  end

  # Every declared status field of the given presence classes must be there.
  def assert_declared_fields(status, *presences)
    CONTRACT.fetch("status_fields").select { |field| presences.include?(field["present"]) }.each do |field|
      assert(!dig_all(status, field["path"]).empty?, "declared status field #{field['path']} (#{field['present']}) is present")
    end
  end

  def checked(requirement, status, evidence, **extra)
    { "requirement" => requirement, "status" => status, "evidence" => evidence }.merge(extra.transform_keys(&:to_s))
  end

  # Contract: capabilities are served from integration.json; the contract
  # version is its own; declared limits equal what Orbit enforces.
  def strict_task_authorization_is_public_and_cannot_expand_on_resume
    with_world do |_tmp, project, connection|
      connection.define_singleton_method(:configured_model) { CHOSEN }
      connection.define_singleton_method(:model_catalog) do
        { "current" => CHOSEN, "available" => [CHOSEN, "other/model"], "families" => {},
          "allowed_models" => [CHOSEN], "authorization_guard" => true }
      end
      created = start(project, "m1", "--allowed-model", CHOSEN)
      record = Orbit::TaskRecord.new(created.fetch("task_directory"))
      status = orbit_json("status", record.path, "--json")
      assert(status.dig("model_authorization", "allowed_models") == [CHOSEN], "public status reports the frozen authorization")
      assert(status.dig("model_authorization", "auxiliary_judgments") == "disabled", "strict tasks do not call auxiliary models")
      state = record.state
      state["status"] = "paused"
      state["stop_confirmation"] = { "confirmed" => true }
      record.save(state)
      resumed = start(project, "m2", "--resume-from", record.path)
      assert(orbit_json("status", resumed.fetch("task_directory"), "--json").dig("model_authorization", "allowed_models") == [CHOSEN],
             "resume inherits the hard boundary without requiring a repeated flag")
      code, _, error = orbit("start", "--project", project, "--thread", "root-session", "--socket", "unused.sock",
                            "--message-id", "m3", "--allowed-model", "other/model", "--resume-from", record.path)
      assert(code != 0 && error.include?("exceed"), "resume refuses expanded authorization before starting")
    end
  end

  def capabilities_declare_what_orbit_enforces
    report = orbit_json("capabilities", "--json")
    capabilities = report.fetch("capabilities")
    assert(capabilities == CONTRACT.fetch("capabilities") && report.dig("integration_contract", "version") == CONTRACT.fetch("version") &&
           report.dig("integration_contract", "major") == CONTRACT.fetch("major"), "capabilities come from integration.json")
    assert(report.dig("orbit", "version") == Orbit::VERSION && CONTRACT.fetch("version") != Orbit::VERSION,
           "the contract version is independent of the software version")
    assert(File.read(File.join(ROOT, "contracts/integration.md")).include?("合同版本：#{CONTRACT.fetch('version')}"),
           "the prose contract states the same version as the machine-readable one")
    schema = JSON.parse(File.read(File.join(ROOT, "contracts/check-result.schema.json")))
    ref = schema.dig("properties", "coverage", "properties", "items", "items", "properties", "ref")
    assert(capabilities.dig("check_coverage_ref", "max_length") == ref.fetch("maxLength"), "declared ref bound is the schema bound")
    assert(capabilities.dig("start_external_refs", "max_length") == Orbit::TaskRecord::EXTERNAL_REF_MAX &&
           capabilities.dig("start_external_refs", "max_refs") == Orbit::TaskRecord::EXTERNAL_REFS_MAX, "declared external ref limits are enforced limits")
    assert(CONTRACT.fetch("status_values").sort == %w[complete failed needs_user paused running starting stop_unconfirmed],
           "declared status vocabulary")
    assert(Orbit::TaskRuntime::TERMINAL.sort == CONTRACT.fetch("terminal_status_values").sort, "declared terminal statuses are the runtime's")
  end

  # Contract: start → check → coverage with refs → status → stop receipt →
  # resume_from → export, through public commands only.
  def fake_caller_runs_the_whole_lifecycle
    with_world do |tmp, project|
      started = start(project, "m1", "--external-ref", "loom:p1/d2/run-3", "--external-ref", "tracker#9")
      dir = started.fetch("task_directory")
      assert(started["status"] == "starting", "start reports starting")
      status = orbit_json("status", dir, "--json")
      assert_declared_fields(status, "always", "when_provided")
      assert(status["external_refs"] == ["loom:p1/d2/run-3", "tracker#9"], "external references are returned verbatim, in order")

      checker = Checker.new
      runtime = runtime_for(dir, project, checker)
      queued = orbit_json("check", dir)
      assert(queued["status"] == "queued" && queued["command_id"], "check is queued, not answered")
      result = { "verdict" => "continue", "reason" => "fixture", "findings" => [], "resolved_ids" => [], "next_check_seconds" => 60,
                 "delivery" => { "ready" => true, "reason" => "delivered answer is visible" },
                 "coverage" => { "complete" => true, "items" => [
                   checked("S12 exact cents", "verified", "artifact.txt read", ref: "S12"),
                   checked("S13 reject empty", "unverified", "", ref: "S13"),
                   checked("closing report", "unverified", "", scope: "lifecycle", ref: "  ")
                 ] } }
      normalized = Orbit::CheckRunner.new(model: CHOSEN, executable: "unused").send(:validate_result, result)
      assert(normalized.dig("coverage", "items").map { |item| item["ref"] } == ["S12", "S13", nil] &&
             !normalized.dig("coverage", "items").last.key?("ref"), "a blank ref is accepted as omitted and dropped; others are kept")
      now = Time.now.to_f
      runtime.tick(now: now)
      checker.result = result
      runtime.tick(now: now + 1)
      status = orbit_json("status", dir, "--json")
      assert_declared_fields(status, "always", "when_provided", "after_check", "when_reported")
      refs = status.dig("requirement_coverage", "items").to_h { |item| [item["requirement"], item["ref"]] }
      assert(refs == { "S12 exact cents" => "S12", "S13 reject empty" => "S13", "closing report" => nil },
             "each reported ref is returned on its own coverage item and an unlabelled item has none")
      assert(status.dig("requirement_coverage", "ready") == false, "an unverified delivery item keeps the delivery unready")

      receipt = orbit_json("stop", dir, "--json")
      assert(receipt["status"] == "queued" && !receipt.key?("stop_confirmation"), "stop --json is only a queued receipt")
      assert(orbit_json("status", dir, "--json")["status"] != "paused", "queued is not stopped")
      runtime.tick(now: now + 2)
      status = orbit_json("status", dir, "--json")
      assert(status["status"] == "paused" && status.dig("stop_confirmation", "confirmed") == true, "stopped is established by stop_confirmation.confirmed")
      assert_declared_fields(status, "always", "after_stop")

      resumed = start(project, "m2", "--resume-from", dir, "--external-ref", "loom:p1/d2/run-4")
      resumed_status = orbit_json("status", resumed.fetch("task_directory"), "--json")
      assert_declared_fields(resumed_status, "always", "when_provided", "when_resumed")
      assert(resumed_status.dig("continuation", "previous_task") == status["id"] && resumed_status["external_refs"] == ["loom:p1/d2/run-4"],
             "resume links the stopped task and carries only the references passed again")

      archive = File.join(tmp, "evidence.tar.gz")
      exported = orbit_json("export", dir, "--output", archive)
      CONTRACT.dig("commands", "export", "stdout_fields").each { |field| assert(exported.key?(field), "export reports #{field}") }
      packed, error, wait = Open3.capture3("tar", "-xzOf", archive, "task/state.json")
      assert(wait.success? && JSON.parse(packed)["external_refs"] == ["loom:p1/d2/run-3", "tracker#9"], "export carries the references unchanged: #{error}")
    end
  end

  # Contract (G8): status --external-ref always answers {"tasks":[...]} —
  # exact match including terminal states, newest first, exit 0 with an empty
  # array on no match, validation and scan errors stay non-zero errors (never
  # disguised as an empty array), and the option is mutually exclusive with a
  # positional TASK.
  def status_by_external_ref_returns_a_fixed_tasks_array
    with_world do |tmp, project|
      older = start(project, "m1", "--external-ref", "loom:p1/d2/run-3", "--external-ref", "tracker#9")
      newer = start(project, "m3", "--external-ref", "loom:p1/d2/run-3")
      plain = start(project, "m4")
      older_id = Orbit::TaskRecord.new(older.fetch("task_directory")).state.fetch("id")
      newer_id = Orbit::TaskRecord.new(newer.fetch("task_directory")).state.fetch("id")
      record = Orbit::TaskRecord.new(older.fetch("task_directory"))
      record.save(record.state.merge("created_at" => "2026-01-01T00:00:00Z", "status" => "paused",
                                     "stop_confirmation" => { "confirmed" => true }))

      matched = Dir.chdir(tmp) { orbit_json("status", "--external-ref", "loom:p1/d2/run-3", "--project", project) }
      tasks = matched.fetch("tasks")
      assert(tasks.map { |task| task.fetch("id") } == [newer_id, older_id] &&
             tasks.last.fetch("status") == "paused", "exact match returns all tasks with the ref, newest first, terminal states included")
      alone = Dir.chdir(project) { orbit_json("status", "--external-ref", "tracker#9", "--json") }
      assert(alone.fetch("tasks").map { |task| task.fetch("id") } == [older_id], "the second ref matches only its own task; cwd project discovery works")
      code, out, = orbit("status", "--external-ref", "loom:p1", "--project", project)
      assert(code == 0 && JSON.parse(out) == { "tasks" => [] }, "a prefix is not an exact match; no match is exit 0 with an empty array")

      code, out, err = orbit("status", "--external-ref", " ", "--project", project)
      assert(code == 1 && err.include?("external") && !out.include?("tasks"), "an invalid ref is refused, not an empty result")
      code, _out, err = orbit("status", "whatever", "--external-ref", "loom:p1/d2/run-3", "--project", project)
      assert(code == 1 && err.include?("usage"), "--external-ref is mutually exclusive with a positional TASK")
      code, out, err = orbit("status", "--external-ref", "tracker#9", "--project", File.join(project, "artifact.txt"))
      assert(code == 1 && !err.empty? && !out.include?("tasks"), "a file is not a project directory; validation failure is not an empty result")

      File.write(File.join(plain.fetch("task_directory"), "state.json"), "{corrupted")
      code, out, err = orbit("status", "--external-ref", "loom:p1/d2/run-3", "--project", project)
      assert(code == 1 && !err.empty? && !out.include?("tasks"),
             "a scan error over the project's records stays a non-zero error, never an empty tasks array")
    end
  end

  def revision_advances_only_on_visible_change
    with_world do |_tmp, project|
      dir = start(project, "m1").fetch("task_directory")
      record = Orbit::TaskRecord.new(dir)
      first = orbit_json("status", dir, "--json")
      assert(first["revision"] == 1 && first["updated_at"].is_a?(String), "creation initializes revision=1 with updated_at")

      record.save(record.state.merge("revision" => 0, "updated_at" => "forged"))
      again = record.state
      assert(again["revision"] == 1 && again["updated_at"] == first["updated_at"], "unchanged saves preserve authoritative metadata")

      noisy = again.merge("usage" => { "tokens" => 42 }, "next_check_at" => "2030-01-01T00:00:00Z")
      record.save(noisy)
      assert(record.state["revision"] == 1, "usage and pure scheduling time do not count")

      record.save(record.state.merge("status" => "paused", "stop_confirmation" => { "confirmed" => true }))
      bumped = record.state
      assert(bumped["revision"] == 2 && bumped["updated_at"].is_a?(String), "a visible change bumps revision and refreshes updated_at")
      reloaded = Orbit::TaskRecord.new(dir)
      reloaded.save(reloaded.state)
      assert(reloaded.state["revision"] == 2, "a restart continues from the persisted counter, never backwards")

      legacy = reloaded.state.reject { |key, _| %w[revision updated_at].include?(key) }
      File.write(File.join(dir, "state.json"), JSON.pretty_generate(legacy) + "\n")
      assert(!orbit_json("status", dir, "--json").key?("revision"), "a pre-1.3 record reports no revision instead of synthesizing one")
      record.save(record.state)
      assert(record.state["revision"] == 1, "the first save of a legacy record initializes the counter")
      record.save(record.state.merge("requirement_coverage" => { "complete" => true, "current" => true, "ready" => true }))
      before = record.state
      record.save(before.merge("requirement_coverage" => before["requirement_coverage"].merge("current" => false, "ready" => false, "gap" => "read-time")))
      assert(record.state["revision"] == before["revision"], "read-time coverage fields do not count")
      record.save(record.state.merge("checks" => [{ "number" => 1, "usage" => { "tokens" => 1 } }]))
      before = record.state
      record.save(before.merge("checks" => [{ "number" => 1, "usage" => { "tokens" => 2 } }]))
      assert(record.state["revision"] == before["revision"], "check receipt usage-only refreshes do not count")
      File.write(File.join(dir, "state.json"), "null")
      begin; record.save(legacy); raise "accepted invalid old state"; rescue ArgumentError; end
      assert(File.read(File.join(dir, "state.json")) == "null", "invalid old state is not overwritten or reset")
    end
  end

  def attention_maps_the_frozen_phase_enum
    cases = [
      [{ "status" => "starting" }, "starting", false],
      [{ "status" => "running" }, "implementing", false],
      [{ "status" => "running", "completion_stop_pending" => { "at" => "t" } }, "stopping", false],
      [{ "status" => "running", "check_observations" => { "k" => { "status" => "in_flight" } } }, "checking", false],
      [{ "status" => "running", "next_check_manual" => true }, "checking", false],
      [{ "status" => "running", "findings" => { "f1" => { "status" => "open" } } }, "reworking", false],
      [{ "status" => "running", "recheck" => { "findings" => [{ "id" => "f1" }] } }, "reworking", false],
      [{ "status" => "running", "next_check_at" => "2030-01-01T00:00:00Z" }, "implementing", false],
      [{ "status" => "needs_user" }, "needs_user", true],
      [{ "status" => "failed" }, "failed", false],
      [{ "status" => "paused" }, "stopped", false],
      [{ "status" => "stop_unconfirmed" }, "stopping", false],
      [{ "status" => "bogus" }, "unknown", false]
    ]
    cases.each do |state, phase, needs_user|
      assert(Orbit::StatusProjection.attention(state) == { "phase" => phase, "needs_user" => needs_user },
             "attention for #{state} is #{phase}/#{needs_user}")
    end
  end

  def latest_check_projects_the_last_finished_record
    with_world do |_tmp, project|
      dir = start(project, "m1").fetch("task_directory")
      record = Orbit::TaskRecord.new(dir)
      state = record.state
      assert(!orbit_json("status", dir, "--json").key?("latest_check"), "no completed check means no projection")
      digest = record.input_digest(state)
      good = { "number" => 1, "role" => "reviewer", "kind" => "artifact", "finished_at" => "2026-01-01T00:00:00Z",
               "input_digest" => digest, "artifact_digest" => "artifact-v1", "stale" => true, "stale_reasons" => ["input"],
               "result" => { "verdict" => "continue", "reason" => "private text" }, "usage" => { "calls" => [
                 { "provider" => "zenmux", "model" => "x-ai/grok-4.7" }, { "provider" => "zenmux", "model" => "zenmux/x-ai/grok-4.7" },
                 { "requested_model" => "req/fallback" }, { "provider" => "missing" } ] } }
      record.save(state.merge("checks" => [good]))
      latest = orbit_json("status", dir, "--json").fetch("latest_check")
      assert(latest["terminal"] == "stale" && latest["stale_reasons"] == ["input"] && latest["input_current"] == true &&
             latest["models"] == ["zenmux/x-ai/grok-4.7", "req/fallback"], "stale completion and normalized deduplicated receipt identities are retained")
      scope = File.join(dir, "checks", "2", "scope.json")
      FileUtils.mkdir_p(File.dirname(scope))
      File.write(scope, JSON.generate("input_digest" => digest, "snapshot" => { "digest" => "artifact-v2" }, "artifact_root" => project))
      failed = { "number" => 2, "role" => "process_reviewer", "finished_at" => "2026-01-02T00:00:00Z", "failed" => true,
                 "result" => { "failure_kind" => "invalid_result", "error" => "private error" } }
      record.save(record.state.merge("checks" => [good, failed, { "number" => 3 }]))
      latest = orbit_json("status", dir, "--json").fetch("latest_check")
      assert(latest["number"] == 2 && latest["terminal"] == "failed" && latest["failure_kind"] == "invalid_result" &&
             latest["artifact_digest"] == "artifact-v2" && latest["input_current"] == true && latest["models"] == [] && latest["stale"].nil?,
             "last finished failure wins over adoptable history and unfinished entries; legacy identity falls back, missing facts stay unknown")
      assert((latest.keys & %w[artifact_root result usage reason error provider_response_id]).empty?, "private text, paths and usage are outside the projection")
      record.write("amendments/new.txt", "changed input")
      state = record.state; state["amendments"] << { "path" => "amendments/new.txt" }; record.save(state)
      assert(orbit_json("status", dir, "--json").dig("latest_check", "input_current") == false, "input changes invalidate input consistency")
    end
  end

  # Contract: resume_from.from_status is the truth, and a bad reference never creates a task.
  def declared_limits_hold_at_the_boundary
    with_world do |_tmp, project|
      stopped = start(project, "m1")
      record = Orbit::TaskRecord.new(stopped.fetch("task_directory"))
      state = record.state
      state.merge!("status" => "needs_user", "stop_confirmation" => { "confirmed" => true })
      record.save(state)
      resumed = start(project, "m2", "--resume-from", record.path)
      resumed_state = Orbit::TaskRecord.new(resumed.fetch("task_directory")).state
      assert(resumed_state.dig("continuation", "previous_task") == state["id"],
             "a legacy needs_user record is resumed through a new task boundary")
      assert(CONTRACT.dig("capabilities", "resume_from", "from_status").include?("needs_user"),
             "the capability declares the additive legacy needs_user source")

      before = Dir.glob(File.join(project, ".orbit/tasks/*")).length
      too_many = (1..17).flat_map { |index| ["--external-ref", "r#{index}"] }
      [["--external-ref", " "], ["--external-ref", "a\nb"], ["--external-ref", "x" * 257],
       ["--external-ref", "dup", "--external-ref", "dup"], too_many].each do |args|
        code, _out, err = orbit("start", "--provider", "omp", "--project", project, "--thread", "root-session",
                                "--socket", File.join(project, "unused.sock"), "--message-id", "m1x", "--review-model", CHOSEN, *args)
        assert(code == 1 && err.include?("external"), "invalid external references are refused: #{args.first(2)}")
      end
      assert(Dir.glob(File.join(project, ".orbit/tasks/*")).length == before, "a refused reference creates no task")
    end
  end
end

IntegrationContractTest.capabilities_declare_what_orbit_enforces
IntegrationContractTest.fake_caller_runs_the_whole_lifecycle
IntegrationContractTest.status_by_external_ref_returns_a_fixed_tasks_array
IntegrationContractTest.revision_advances_only_on_visible_change
IntegrationContractTest.attention_maps_the_frozen_phase_enum
IntegrationContractTest.latest_check_projects_the_last_finished_record
IntegrationContractTest.declared_limits_hold_at_the_boundary
puts "INTEGRATION_CONTRACT_TEST_PASS (fake caller and fake OMP host against the real CLI, runtime and stores)"

IntegrationContractTest.strict_task_authorization_is_public_and_cannot_expand_on_resume
