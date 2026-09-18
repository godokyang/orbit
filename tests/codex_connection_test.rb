# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "tmpdir"

require_relative "../lib/orbit/codex_connection"

module CodexConnectionTest
  THREAD_ID = "t-1"
  BRIDGE = File.expand_path("../scripts/codex-socket.cjs", __dir__)
  HELPER = File.expand_path("helpers/codex_socket_server.cjs", __dir__)

  module_function

  def run
    failures = []
    tests = [:test_connect_rejects_missing_socket_unloaded_and_historyless_threads,
             :test_state_and_busy_idle_message_routing,
             :test_stop_reports_unconfirmed_terminals,
             :test_member_creation_defaults_to_full_access]
    tests.each do |test|
      Dir.mktmpdir do |tmp|
        send(test, tmp)
        puts "ok #{test}"
      rescue StandardError => e
        failures << "#{test}: #{e.class}: #{e.message}\n  #{e.backtrace&.first(4)&.join("\n  ")}"
        puts "FAIL #{test}: #{e.message}"
      end
    end
    raise failures.join("\n") unless failures.empty?

    puts "codex_connection_test: #{tests.length} passed"
  end

  # 1. connect! must refuse an ordinary embedded TUI world explicitly: no
  # control socket; a reachable server whose loaded list does not contain
  # the thread; and a loaded thread without history capability (ephemeral
  # or not yet materialized). No silent queue fallback, no thread/resume.
  # The transport under test is the real bridge + real WebSocket fake
  # server in tests/helpers/codex_socket_server.cjs.
  def test_connect_rejects_missing_socket_unloaded_and_historyless_threads(tmp)
    missing = Orbit::CodexConnection.new(socket: File.join(tmp, "absent.sock"), thread_id: THREAD_ID)
    error = assert_raises(Orbit::CodexConnection::ConnectionError) { missing.connect! }
    assert(error.message.include?("no app-server control socket"), "socket error explains the ordinary TUI case")
    assert(!missing.connected?, "failed connection stays closed")

    server = FakeCodexServer.new(tmp, "case-unloaded", loaded: ["some-other-thread"])
    server.start
    begin
      conn = Orbit::CodexConnection.new(socket: server.path, thread_id: THREAD_ID, bridge: BRIDGE)
      error = assert_raises(Orbit::CodexConnection::ConnectionError) { conn.connect! }
      assert(error.message.include?("not loaded"), "unloaded thread error names the real cause")
      assert(error.message.include?("does not silently resume"), "error states no silent fallback")
      assert(!server.requests.any? { |r| r["method"] =~ /resume|thread\/start/ }, "connect! never resumes or starts the thread")
    ensure
      server.shutdown
    end

    server = FakeCodexServer.new(tmp, "case-historyless", loaded: [THREAD_ID], reject_history: true)
    server.start
    begin
      conn = Orbit::CodexConnection.new(socket: server.path, thread_id: THREAD_ID, bridge: BRIDGE)
      error = assert_raises(Orbit::CodexConnection::ConnectionError) { conn.connect! }
      assert(error.message.include?("does not expose turn history"), "historyless thread is rejected explicitly")
      assert(error.message.include?("does not bypass"), "rejection states there is no bypass")
      assert(!server.requests.any? { |r| r["method"] =~ /resume|thread\/start/ }, "no resume or start for historyless threads either")
    ensure
      server.shutdown
    end
  end

  # 2. state exposes native busy state for routing and real-tool
  # observations from the newest turn's actual items (the turns/list
  # summary view is proven not to be used); send_message steers the active
  # turn (expectedTurnId precondition, own clientUserMessageId, no
  # model/policy overrides) and starts a turn when idle; user_messages
  # returns only messages after the visible boundary, keyed so the
  # runtime can exclude its own injections, and never imports history
  # from before a missing boundary.
  def test_state_and_busy_idle_message_routing(tmp)
    scenario = {
      "status" => { "type" => "active", "activeFlags" => ["turn"] },
      "turns" => [
        # Summary items deliberately contain a decoy: observations must
        # come from the turn's real items, not the summary view.
        { "id" => "turn-2", "status" => "inProgress",
          "items" => [{ "type" => "agentMessage", "text" => "SUMMARY-DECOY" }] },
        { "id" => "turn-1", "status" => "completed", "items" => [] }
      ],
      # Newest-first thread-wide item page (wrapped, real shape):
      # user follow-up, an agent message, then the boundary message.
      "items" => [
        { "type" => "userMessage", "id" => "item-b", "clientId" => nil,
          "content" => [{ "type" => "text", "text" => "user follow-up" }] },
        { "type" => "agentMessage", "id" => "item-x", "content" => [] },
        { "type" => "userMessage", "id" => "item-boundary", "clientId" => nil,
          "content" => [{ "type" => "text", "text" => "original instruction" }] }
      ],
      # Real items of the active turn (asc), used for observations; native
      # agentMessage carries top-level text, commands carry real output.
      "turn_items" => [
        { "type" => "agentMessage", "id" => "a-1", "text" => "working", "phase" => "final_answer" },
        { "type" => "commandExecution", "id" => "c-1", "command" => "ruby tests", "status" => "completed",
          "exitCode" => 0, "aggregatedOutput" => "1 run, 47 assertions, 0 failures" }
      ],
      "turn_items_turn_id" => "turn-2"
    }
    server = FakeCodexServer.new(tmp, "case-routing", loaded: [THREAD_ID], scenario: scenario)
    server.start
    begin
      conn = Orbit::CodexConnection.new(socket: server.path, thread_id: THREAD_ID, bridge: BRIDGE).connect!
      assert_equal("/workspace/project", conn.cwd, "connect! captures the thread cwd")

      state = conn.state
      assert_equal("active", state.fetch("status"), "status is the native type string for runtime comparisons")
      assert_equal({ "type" => "active", "activeFlags" => ["turn"] }, state.fetch("status_detail"), "native status detail is preserved")
      assert_equal("turn-2", state.fetch("turn_id"), "active turn id comes from the in-progress turn")
      assert_equal("turn-1", state.fetch("last_turn_id"), "last terminal turn id")
      assert_equal("completed", state.fetch("last_turn_status"), "last terminal turn status")
      observations = state.fetch("observations")
      assert(observations.any? { |o| o["kind"] == "agent_message" && o["text"] == "working" && o["phase"] == "final_answer" },
             "observations carry the complete actual agent text from the newest turn's real items")
      assert(observations.any? { |o| o["kind"] == "command" && o["command"] == "ruby tests" && o["exit_code"] == 0 &&
                                  o["aggregated_output"]&.include?("47 assertions") },
             "observations carry bounded real command output, not just the exit code")
      assert(!observations.any? { |o| o["text"].to_s.include?("SUMMARY-DECOY") }, "summary view is never used for observations")

      sent = conn.send_message("fix the finding")
      steer = server.last_request("turn/steer")
      assert(!steer.nil?, "busy thread is steered, not started")
      assert_equal("turn-2", steer.fetch("params").fetch("expectedTurnId"), "steer carries the active turn precondition")
      assert_equal("fix the finding", steer.fetch("params").fetch("input").first.fetch("text"), "steer carries the text")
      assert_equal(sent.fetch("id"), steer.fetch("params").fetch("clientUserMessageId"), "send id is the clientUserMessageId")
      assert(sent.fetch("id").start_with?("orbit-"), "sent ids live in Orbit's own id space")
      assert_equal(%w[clientUserMessageId expectedTurnId input threadId], steer.fetch("params").keys.sort,
                   "steer sends no model/sandbox/approval overrides")
      assert_equal("steer", sent.fetch("action"), "busy send reports steer")
      assert_equal("turn-2", sent.fetch("turn_id"), "steer returns the steered turn")

      server.scenario = scenario.merge(
        "status" => { "type" => "idle", "activeFlags" => [] },
        "turns" => [{ "id" => "turn-1", "status" => "completed", "items" => [] }]
      )
      started = conn.send_message("next task")
      start = server.last_request("turn/start")
      assert(!start.nil?, "idle thread starts a turn")
      assert(!start.fetch("params").key?("expectedTurnId"), "start has no steer precondition")
      assert_equal("turn-3", started.fetch("turn_id"), "start returns the new turn id")
      assert_equal("start", started.fetch("action"), "idle send reports start")

      # The steered injection lands as a user message whose clientId is
      # exactly the id send_message returned: exclusion must work through
      # that key, and the user follow-up keeps its native id.
      server.scenario = scenario.merge(
        "status" => { "type" => "idle", "activeFlags" => [] },
        "items" => [
          { "type" => "userMessage", "id" => "item-orbit", "clientId" => sent.fetch("id"),
            "content" => [{ "type" => "text", "text" => "Orbit independent check" }] }
        ] + scenario.fetch("items")
      )
      messages = conn.user_messages(after_id: "item-boundary")
      assert_equal(["item-b", sent.fetch("id")], messages.map { |m| m.fetch("id") },
                   "messages after the boundary in chronological order: user follow-up by native id, own injection by sent id")
      assert_equal("item-b", messages.first.fetch("item_id"), "native item id stays available for traceability")
      assert_equal("user follow-up", messages.first.fetch("text"), "user text is the original input, not a summary")

      # Boundary invisible and not ours: explicit observation gap, never a
      # history import.
      gap = conn.user_messages(after_id: "pruned-long-ago")
      assert_equal([], gap, "invisible boundary imports nothing")
      assert_equal("pruned-long-ago", conn.observation_gap.fetch("after_id"), "gap is reported explicitly")
      assert_equal("boundary_not_visible", conn.observation_gap.fetch("reason"), "gap reason is explicit")

      # Boundary invisible but freshly sent by this connection: wait for
      # persistence, next observation retries.
      server.scenario = scenario
      pending = conn.user_messages(after_id: sent.fetch("id"))
      assert_equal([], pending, "own pending id returns nothing yet")
      assert_equal("pending_delivery", conn.observation_gap.fetch("reason"), "own pending id defers observation without importing old history")
      conn.close
    ensure
      server.shutdown
    end
  end

  # 3. stop! must not report success when a managed background terminal
  # fails to confirm termination or the thread is not idle; the interrupt
  # itself is still attempted and recorded.
  def test_stop_reports_unconfirmed_terminals(tmp)
    server = FakeCodexServer.new(
      tmp,
      "case-stop",
      loaded: [THREAD_ID],
      scenario: {
        "status" => { "type" => "active", "activeFlags" => ["turn"] },
        "turns" => [{ "id" => "turn-9", "status" => "inProgress", "items" => [] }],
        "items" => [],
        "terminals" => [
          { "processId" => "7", "itemId" => "item-7", "command" => "sleep 999", "cwd" => "/workspace/project" },
          { "processId" => "8", "itemId" => "item-8", "command" => "watch logs", "cwd" => "/workspace/project" }
        ],
        "terminate_result" => false
      }
    )
    server.start
    begin
      conn = Orbit::CodexConnection.new(socket: server.path, thread_id: THREAD_ID, bridge: BRIDGE).connect!
      error = assert_raises(Orbit::CodexConnection::StopNotConfirmed) { conn.stop! }
      report = error.report
      assert_equal(false, report.fetch("confirmed"), "unverified stop never reports confirmed")
      assert_equal(%w[7 8], report.fetch("terminals").map { |t| t.fetch("process_id") },
                   "both terminals across list pages are terminated and reported")
      assert(report.fetch("terminals").all? { |t| !t.fetch("terminated") }, "failed terminations are recorded as failed")
      assert_equal(%w[7 8], report.fetch("verified").fetch("remaining_terminals").map { |t| t.fetch("process_id") },
                   "re-check lists every surviving terminal across pages")
      assert_equal("active", report.fetch("verified").fetch("status"), "still-active thread is reported, not assumed idle")
      assert(error.message.include?("not idle") || error.message.include?("did not confirm"),
             "failure reasons are concrete")

      # A stop that lands on idle with all terminals confirmed reports
      # confirmed=true without closing the thread or the server.
      server.scenario = server.scenario.merge(
        "status" => { "type" => "idle", "activeFlags" => [] },
        "terminate_result" => true
      )
      report = conn.stop!
      assert_equal(true, report.fetch("confirmed"), "idle + empty terminal list confirms the stop")
      assert_equal(true, report.fetch("terminals").first.fetch("terminated"), "second attempt terminates")
      assert_equal([], report.fetch("verified").fetch("remaining_terminals"), "terminal list drains after confirmed termination")
      assert(conn.connected?, "stop! leaves the connection open")
      closed = server.requests.any? { |r| r["method"] =~ /unsubscribe|thread\/delete|close/ }
      assert(!closed, "stop! never closes or unsubscribes the thread")
      conn.close
    ensure
      server.shutdown
    end
  end

  # 4. Execution members default to full access without stalling on
  # approval; explicit stricter values win. The task-owned host must not
  # receive a partial Orbit MCP disable override.
  def test_member_creation_defaults_to_full_access(tmp)
    server = FakeCodexServer.new(tmp, "case-member", loaded: [THREAD_ID])
    server.start
    connection = Orbit::CodexConnection.new(socket: server.path, thread_id: THREAD_ID, bridge: BRIDGE).connect!
    id = connection.create_member(model: "gpt-test", cwd: "/workspace/project", disable_orbit_mcp: false)
    assert_equal("member-thread-1", id, "member thread id is returned")
    params = server.last_request("thread/start").fetch("params")
    assert_equal("danger-full-access", params["sandbox"], "members default to full access")
    assert_equal("never", params["approvalPolicy"], "members never stall on approval")
    assert_equal(false, params["ephemeral"], "member history is retained")
    assert(!params.key?("config"), "task-owned hosts receive no partial Orbit MCP override")

    connection.create_member(model: "gpt-test", cwd: "/workspace/project", disable_orbit_mcp: true,
                             sandbox: "workspace-write", approval_policy: "on-request")
    explicit = server.last_request("thread/start").fetch("params")
    assert_equal("workspace-write", explicit["sandbox"], "explicit stricter sandbox wins")
    assert_equal("on-request", explicit["approvalPolicy"], "explicit stricter approval policy wins")
    assert_equal({ "mcp_servers.orbit.enabled" => false }, explicit["config"], "root-owned members still disable Orbit MCP")
  ensure
    begin
      connection&.close
    rescue StandardError
      nil
    end
    server&.shutdown
  end

  # Harness: spawns the REAL WebSocket fake app-server
  # (tests/helpers/codex_socket_server.cjs, `ws` over a Unix socket) and a
  # Ruby relay that answers frames through the same canned handler the
  # earlier line-based fake used. Requests are recorded for assertions.
  class FakeCodexServer
    attr_reader :path, :requests
    attr_accessor :scenario

    def initialize(tmp, name, loaded: [], scenario: {}, reject_history: false)
      @path = File.join(tmp, "#{name}.sock")
      @loaded = loaded
      @scenario = scenario
      @reject_history = reject_history
      @requests = []
      @mutex = Mutex.new
    end

    def start
      @helper_in, @helper_out, helper_err, @helper_waiter = Open3.popen3("node", HELPER, @path)
      ready = Thread.new { helper_err.gets }
      raise "fake app-server helper did not become ready" unless ready.join(15)

      @relay = Thread.new do
        loop do
          line = begin
            @helper_out.gets
          rescue IOError
            nil
          end
          break if line.nil?

          message = JSON.parse(line)
          @mutex.synchronize { @requests << message }
          response = handle(message)
          begin
            @helper_in.write(JSON.generate(response) + "\n")
          rescue IOError, SystemCallError
            break
          end
        end
      end
      self
    end

    def last_request(method)
      @mutex.synchronize { @requests.reverse_each.find { |r| r["method"] == method } }
    end

    def shutdown
      @helper_in&.close
      @relay&.join(2)
      if @helper_waiter && !@helper_waiter.join(3)
        begin
          Process.kill("TERM", @helper_waiter.pid) if @helper_waiter.alive?
          @helper_waiter.join(2)
        rescue SystemCallError
          nil
        end
      end
      @helper_out&.close
      File.delete(@path) if File.exist?(@path)
    end

    private

    def handle(message)
      method = message.fetch("method")
      params = message.fetch("params", {})
      if @reject_history && method == "thread/turns/list"
        return error_response(message, "ephemeral thread does not support history listing")
      end

      result =
        case method
        when "initialize"
          { "userAgent" => "codex-test", "platformOs" => "test", "platformFamily" => "test", "codexHome" => "/tmp" }
        when "thread/loaded/list"
          { "data" => @loaded, "nextCursor" => nil }
        when "thread/read"
          { "thread" => { "id" => params.fetch("threadId"), "cwd" => "/workspace/project",
                          "status" => scenario_value("status", { "type" => "idle", "activeFlags" => [] }) } }
        when "thread/turns/list"
          { "data" => scenario_value("turns", []), "nextCursor" => nil }
        when "thread/items/list"
          if params["turnId"] == @scenario["turn_items_turn_id"]
            { "data" => wrap_items(@scenario.fetch("turn_items", []), params["turnId"]), "nextCursor" => nil }
          else
            { "data" => wrap_items(@scenario.fetch("items", []), params["turnId"]), "nextCursor" => nil }
          end
        when "turn/steer"
          { "turnId" => scenario_value("turns", []).first&.fetch("id", nil) }
        when "thread/start"
          { "thread" => { "id" => "member-thread-1", "status" => { "type" => "idle" } } }
        when "turn/start"
          { "turn" => { "id" => "turn-3", "status" => "inProgress", "items" => [] } }
        when "turn/interrupt"
          {}
        when "thread/backgroundTerminals/list"
          # Real interface paginates; one terminal per page to prove the
          # connection follows nextCursor.
          all = @scenario.fetch("terminals", [])
          if params["cursor"] == "p2"
            { "data" => all.drop(1), "nextCursor" => nil }
          else
            { "data" => all.take(1), "nextCursor" => all.length > 1 ? "p2" : nil }
          end
        when "thread/backgroundTerminals/terminate"
          if @scenario.fetch("terminate_result", true)
            @scenario["terminals"] = @scenario.fetch("terminals", [])
              .reject { |t| t["processId"] == params.fetch("processId") }
          end
          { "terminated" => @scenario.fetch("terminate_result", true) }
        else
          { "unexpected" => method }
        end
      { "id" => message.fetch("id"), "result" => result }
    end

    def error_response(message, text)
      { "id" => message.fetch("id"), "error" => { "code" => -32_600, "message" => text } }
    end

    def scenario_value(key, fallback)
      @scenario[key] || fallback
    end

    # Real native shape: thread/items/list data entries wrap the item.
    def wrap_items(items, turn_id)
      items.map { |item| { "turnId" => turn_id, "item" => item } }
    end
  end

  def assert(condition, message)
    raise message unless condition

    true
  end

  def assert_equal(expected, actual, message)
    assert(expected == actual, "#{message} (expected #{expected.inspect}, got #{actual.inspect})")
  end

  def assert_raises(error_class)
    yield
    raise "expected #{error_class} but nothing was raised"
  rescue error_class => e
    e
  end
end

CodexConnectionTest.run
