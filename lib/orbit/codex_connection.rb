# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "socket"
require "thread"

module Orbit
  # Orbit task runtime R5a: minimal native connection to an EXISTING Codex
  # session hosted on a shared app-server (daemon or --remote unix socket).
  #
  # TRANSPORT: codex's `--listen unix://…` endpoint is WebSocket over the
  # Unix socket (RFC 6455, one JSON-RPC message per text frame; verified
  # against codex 0.154.0 source, transport/unix_socket.rs). This class
  # therefore spawns `node scripts/codex-socket.cjs <socket>` (the `ws`
  # dependency) and speaks plain newline-delimited JSON-RPC over the
  # bridge's stdin/stdout; no WebSocket handling lives in Ruby.
  #
  # The connection attaches to a thread that is already loaded on that
  # server; it never calls thread/start or thread/resume, never starts a
  # daemon, and never falls back to the durable queue. An ordinary
  # embedded TUI session exposes no control socket, a thread not loaded on
  # the reachable server is not controllable, and a thread without
  # history capability (ephemeral, or not yet materialized before its
  # first user message) cannot be checked; all surface as ConnectionError
  # instead of silent degradation.
  #
  # Server-to-client requests (approval prompts, elicitation) are never
  # answered by this connection; they stay with the owning client.
  # Request deadlines detect protocol failure (no response in time), they
  # are not a task budget.
  #
  # Correlation note: `send_message` passes clientUserMessageId, and the
  # resulting native user-message item carries it back as `clientId`
  # (verified against codex 0.154.0 protocol source: CoreTurnItem::
  # UserMessage.client_id -> UserMessageThreadItem.clientId). Message ids
  # exposed by user_message/user_messages are clientId-when-present so a
  # send_message id and a later message id are the same value; native
  # item ids (a different server-side space) are preserved as "item_id".
  class CodexConnection
    CLIENT_NAME = "orbit"
    CLIENT_VERSION = "0.1.0"
    DEFAULT_DEADLINE = 10.0
    DEFAULT_BRIDGE = File.expand_path("../../scripts/codex-socket.cjs", __dir__)
    PAGE_SIZE = 50
    OBSERVATION_ITEM_LIMIT = 40
    OBSERVATION_TEXT_LIMIT = 2_000

    class Error < StandardError; end

    # Socket missing, connect failed, or the target thread is not hosted on
    # the reachable app-server (for example an ordinary embedded TUI).
    class ConnectionError < Error; end

    # The server answered a request with a JSON-RPC error. Code and message
    # are preserved; nothing is swallowed.
    class RPCError < Error
      attr_reader :code, :method_name, :data

      def initialize(message, code:, method_name:, data: nil)
        super(message)
        @code = code
        @method_name = method_name
        @data = data
      end
    end

    # Deadline exceeded, malformed line, or the socket died mid-request.
    class ProtocolError < Error; end

    # stop! could not verify the full confirmed scope. The unconfirmed
    # report (with "confirmed" => false) rides along in `report`.
    class StopNotConfirmed < Error
      attr_reader :report

      def initialize(message, report:)
        super(message)
        @report = report
      end
    end

    def initialize(socket:, thread_id:, deadline: DEFAULT_DEADLINE,
                   bridge: DEFAULT_BRIDGE, node: "node")
      @socket_path = socket.to_s
      @thread_id = thread_id.to_s
      @deadline = deadline
      @bridge = bridge
      @node = node
      @stdin = nil
      @stdout_pipe = nil
      @stderr_pipe = nil
      @bridge_waiter = nil
      @stderr_reader = nil
      @stderr_tail = []
      @reader = nil
      @events = Queue.new
      @waiters = {}
      @waiters_mutex = Mutex.new
      @write_mutex = Mutex.new
      @next_id = 0
      @sent_client_ids = []
      @observation_gap = nil
      @cwd = nil
      @connected = false
    end

    attr_reader :thread_id, :cwd

    def connected?
      @connected && !@stdin.nil? && !@stdin.closed? && !@bridge_waiter.nil? && @bridge_waiter.alive?
    end

    # Connects through the codex-socket bridge (real WebSocket transport)
    # and verifies the thread is loaded, readable and history-capable on
    # this exact server. Raises ConnectionError when the socket is missing
    # (the ordinary TUI case), the thread is not in thread/loaded/list, or
    # the thread lacks history capability (ephemeral, or not yet
    # materialized before its first user message).
    def connect!
      raise ConnectionError, "already connected" if connected?

      unless File.socket?(@socket_path)
        raise ConnectionError,
              "no app-server control socket at #{@socket_path}; an ordinary " \
              "embedded TUI session exposes none (host the session under the " \
              "shared app-server daemon or start it with --remote)"
      end

      begin
        @stdin, @stdout_pipe, @stderr_pipe, @bridge_waiter =
          Open3.popen3(@node, @bridge, @socket_path)
      rescue StandardError => e
        raise ConnectionError, "cannot start codex socket bridge #{@bridge}: #{e.message}"
      end
      drain_stderr
      start_reader
      begin
        request(
          "initialize",
          "clientInfo" => { "name" => CLIENT_NAME, "version" => CLIENT_VERSION },
          "capabilities" => { "experimentalApi" => true }
        )
        ensure_thread_loaded!
        read_thread_metadata!
      rescue ConnectionError
        close
        raise
      rescue Error => e
        detail = bridge_failure_detail
        close
        raise ConnectionError, "handshake with the app-server failed: #{e.message}#{detail}"
      end
      @connected = true
      self
    end

    # Current native state plus a bounded observation summary of the newest
    # turn (assistant messages and command outcomes), so checks need neither
    # full history nor code-only delivery detection.
    #
    # Returns:
    #   "thread_id", "cwd", "status" (native status type string:
    #     "idle" | "active" | "notLoaded" | "systemError"),
    #   "status_detail" (full native status hash, e.g. activeFlags),
    #   "turn_id" (id of the in-progress turn, nil when idle),
    #   "last_turn_id" / "last_turn_status" (newest terminal turn),
    #   "observations" (bounded newest-turn item summary).
    def state
      thread = request("thread/read", "threadId" => @thread_id, "includeTurns" => false).fetch("thread")
      status = thread["status"]
      turns = latest_turns(limit: 2)
      active = turns.find { |turn| turn["status"] == "inProgress" }
      terminal = turns.find { |turn| turn["status"] != "inProgress" }

      {
        "thread_id" => @thread_id,
        "cwd" => thread["cwd"],
        "status" => status.is_a?(Hash) ? status["type"] : status,
        "status_detail" => status,
        "turn_id" => active && active["id"],
        "last_turn_id" => terminal && terminal["id"],
        "last_turn_status" => terminal && terminal["status"],
        "observations" => observations_for(active || terminal)
      }
    end

    # Non-blocking drain of notifications already received for this thread.
    # Each entry: {"method" => ..., "params" => ...} (native notifications
    # only; nothing synthetic is injected).
    def events
      ensure_connected
      drained = []
      loop do
        drained << @events.pop(true)
      rescue ThreadError
        break
      end
      drained
    end

    # Details of the most recent user_messages observation gap, or nil. A
    # gap means the requested boundary id was not visible in item history;
    # the runtime should treat amendments as unobserved rather than
    # importing older history as this task's changes.
    attr_reader :observation_gap

    # Fetches one native user-message item: the given message id when
    # provided, otherwise the newest user message. Returns
    # {"id","item_id","text","content","client_id"} or nil. Text is the
    # original user input concatenated, never an assistant summary.
    def user_message(id: nil)
      ensure_connected
      each_item_page("desc") do |items|
        found = items.find do |item|
          item["type"] == "userMessage" && (id.nil? || message_identifier(item) == id || item["id"] == id)
        end
        return user_message_hash(found) if found
      end
      nil
    end

    # Native user messages strictly after the given message identifier, in
    # chronological order, as an Array (empty when none). The scan walks
    # newest-first and stops at the boundary, so it never imports history
    # from before it. When the boundary id is NOT visible:
    #   - if it is a client id this connection sent, the message may simply
    #     not be persisted yet; returns [] and retries happen on the next
    #     observation;
    #   - otherwise the boundary is lost (compaction/pruning) and []
    #     is returned with observation_gap set describing the gap. Older
    # visible user messages are deliberately NOT returned as this task's
    # amendments in either case.
    def user_messages(after_id:)
      ensure_connected
      collected = []
      boundary_found = false
      each_item_page("desc") do |items|
        items.each do |item|
          next unless item["type"] == "userMessage"

          if message_identifier(item) == after_id || item["id"] == after_id
            boundary_found = true
            break
          end
          collected << user_message_hash(item)
        end
        boundary_found
      end
      if boundary_found
        @observation_gap = nil
        return collected.reverse
      end
      if @sent_client_ids.include?(after_id)
        @observation_gap = { "reason" => "pending_delivery", "after_id" => after_id }
        return []
      end

      @observation_gap = {
        "reason" => "boundary_not_visible",
        "after_id" => after_id,
        "detail" => "the boundary message is not present in visible item " \
                    "history (compacted or pruned); user amendments after " \
                    "it are unobserved until a visible boundary is restored"
      }
      []
    end

    # Sends text into the existing session as a native turn: turn/steer with
    # an expectedTurnId precondition while a turn is active, otherwise
    # turn/start. No model, sandbox, approval or permission overrides are
    # sent; the thread keeps its current settings. Returns
    # {"id", "action" => "steer"|"start", "turn_id", "client_user_message_id"}.
    # "id" is the clientUserMessageId; the resulting native user-message
    # item carries it back as clientId (verified against codex 0.154.0
    # protocol source), so it matches the "id" of that message in
    # user_message/user_messages. Native item ids and client ids are
    # different server-side spaces; this connection never pretends they
    # are equal, it just always supplies a clientId for its own sends.
    def send_message(text)
      input = [{ "type" => "text", "text" => text.to_s }]
      client_message_id = "orbit-#{SecureRandom.uuid}"
      @sent_client_ids << client_message_id
      active = active_turn_id

      if active
        response = request(
          "turn/steer",
          "threadId" => @thread_id,
          "input" => input,
          "expectedTurnId" => active,
          "clientUserMessageId" => client_message_id
        )
        { "id" => client_message_id, "action" => "steer", "turn_id" => response["turnId"], "client_user_message_id" => client_message_id }
      else
        response = request(
          "turn/start",
          "threadId" => @thread_id,
          "input" => input,
          "clientUserMessageId" => client_message_id
        )
        { "id" => client_message_id, "action" => "start", "turn_id" => response.dig("turn", "id"), "client_user_message_id" => client_message_id }
      end
    end

    # Interrupts the active turn (the interrupt response is only sent once
    # the server confirmed the turn aborted), terminates every managed
    # background terminal it can see, then re-reads state and the terminal
    # list to verify. The thread and server stay open.
    #
    # Returns {"confirmed" => true, "turn_interrupted", "terminals",
    # "verified", "scope"} ONLY when the post-check passed: the thread
    # status is exactly "idle" (notLoaded/systemError/unknown prove
    # nothing) and the managed terminal list is empty. Anything
    # unconfirmed raises StopNotConfirmed carrying the full report
    # (report["confirmed"] stays false) — this connection never claims a
    # stop it did not verify. Confirmed scope covers the interrupted turn
    # plus terminals the app-server manages; detached processes outside
    # that registry are outside the scope and are not claimed stopped.
    def stop!
      ensure_connected
      active = active_turn_id
      report = {
        "confirmed" => false,
        "turn_interrupted" => nil,
        "terminals" => [],
        "verified" => {},
        "scope" =>
          "confirmed scope: active turn interrupt + managed background " \
          "terminals listed by the app-server; detached/unmanaged processes " \
          "are not covered"
      }

      if active
        request("turn/interrupt", "threadId" => @thread_id, "turnId" => active)
        report["turn_interrupted"] = true
      end

      list_background_terminals.each do |terminal|
        terminated = request(
          "thread/backgroundTerminals/terminate",
          "threadId" => @thread_id,
          "processId" => terminal["processId"]
        )["terminated"]
        report["terminals"] << {
          "process_id" => terminal["processId"],
          "command" => terminal["command"],
          "terminated" => terminated == true
        }
      end

      remaining = list_background_terminals
      status = request("thread/read", "threadId" => @thread_id, "includeTurns" => false)
        .dig("thread", "status")
      status_type = status.is_a?(Hash) ? status["type"] : status
      report["verified"] = {
        "status" => status_type,
        "status_detail" => status,
        "remaining_terminals" => remaining.map { |t| { "process_id" => t["processId"], "command" => t["command"] } }
      }

      unconfirmed = []
      unconfirmed << "thread status is #{status_type.inspect}, not idle; only idle proves the stop" unless status_type == "idle"
      report["terminals"].each do |t|
        unconfirmed << "background terminal #{t['process_id']} (#{t['command']}) did not confirm termination" unless t["terminated"]
      end
      remaining.each { |t| unconfirmed << "background terminal #{t['processId']} still listed" }

      if unconfirmed.empty?
        report["confirmed"] = true
        report
      else
        raise StopNotConfirmed.new("stop not confirmed: #{unconfirmed.join('; ')}", report: report)
      end
    end

    # Closes this connection and the bridge subprocess it owns. The thread
    # and the app-server are left running. Idempotent.
    def close
      @connected = false
      stdin = @stdin
      out_pipe = @stdout_pipe
      err_pipe = @stderr_pipe
      waiter = @bridge_waiter
      reader = @reader
      stderr_reader = @stderr_reader
      @stdin = @stdout_pipe = @stderr_pipe = nil
      @reader = @stderr_reader = nil
      @bridge_waiter = nil

      stdin&.close
      reader&.join(1)
      stderr_reader&.join(1)
      out_pipe&.close
      err_pipe&.close
      if waiter && !waiter.join(2)
        begin
          Process.kill("TERM", waiter.pid) if waiter.alive?
          waiter.join(2)
        rescue SystemCallError
          nil
        end
      end
      fail_waiters(ProtocolError.new("connection closed"))
      true
    end

    private

    def ensure_connected
      raise Error, "not connected (call connect! first)" unless connected?
    end

    def ensure_thread_loaded!
      cursor = nil
      loop do
        params = { "limit" => PAGE_SIZE }
        params["cursor"] = cursor if cursor
        response = request("thread/loaded/list", params)
        return if response.fetch("data", []).include?(@thread_id)

        cursor = response["nextCursor"]
        raise ConnectionError,
              "thread #{@thread_id} is not loaded on the app-server at " \
              "#{@socket_path}; an ordinary embedded TUI session is not " \
              "reachable (host the session under the shared daemon or " \
              "--remote), and Orbit does not silently resume or queue it" if cursor.nil?
      end
    end

    def read_thread_metadata!
      thread = request("thread/read", "threadId" => @thread_id, "includeTurns" => false).fetch("thread")
      status = thread["status"]
      if status.is_a?(Hash) && status["type"] == "notLoaded"
        raise ConnectionError, "thread #{@thread_id} reported notLoaded on the app-server"
      end

      @cwd = thread["cwd"]
      begin
        request(
          "thread/turns/list",
          "threadId" => @thread_id, "limit" => 1, "sortDirection" => "desc", "itemsView" => "summary"
        )
      rescue RPCError => e
        raise ConnectionError,
              "thread #{@thread_id} does not expose turn history on this " \
              "app-server (ephemeral threads and threads not yet " \
              "materialized before their first user message are rejected); " \
              "Orbit does not bypass this: #{e.message}"
      end
    end

    def active_turn_id
      latest_turns(limit: 1).find { |turn| turn["status"] == "inProgress" }&.fetch("id", nil)
    end

    def latest_turns(limit:)
      response = request(
        "thread/turns/list",
        "threadId" => @thread_id,
        "limit" => limit,
        "sortDirection" => "desc",
        "itemsView" => "summary"
      )
      response.fetch("data", [])
    end

    def list_background_terminals
      terminals = []
      cursor = nil
      loop do
        params = { "threadId" => @thread_id }
        params["cursor"] = cursor if cursor
        response = request("thread/backgroundTerminals/list", params)
        terminals.concat(response.fetch("data", []))
        cursor = response["nextCursor"]
        break if cursor.nil?
      end
      terminals
    end

    # Real observations come from the newest turn's actual items via
    # thread/items/list: the turns/list summary view deliberately carries
    # only user + final agent messages (verified against the real
    # app-server), never tool executions, so summary items are not used.
    #
    # Native agentMessage items carry their text at the TOP LEVEL
    # ({"type" => "agentMessage", "text" => ..., "phase" => ...}; verified
    # against the real app-server), not in a content array. Final-delivery
    # text is kept complete — silently truncating an answer could let a
    # check pass on partial output. Command summaries are bounded but carry
    # the actual aggregatedOutput (truncation is always marked), not just
    # the exit code.
    def observations_for(turn)
      return [] if turn.nil?

      response = request(
        "thread/items/list",
        "threadId" => @thread_id,
        "turnId" => turn["id"],
        "sortDirection" => "desc",
        "limit" => OBSERVATION_ITEM_LIMIT
      )
      observations = unwrap_item_entries(response.fetch("data", [])).reverse.filter_map do |item|
        case item["type"]
        when "agentMessage"
          text = item["text"].to_s
          next if text.empty?

          { "kind" => "agent_message", "text" => text, "phase" => item["phase"] }
        when "commandExecution"
          {
            "kind" => "command",
            "command" => truncate_text(item["command"].to_s),
            "status" => item["status"],
            "exit_code" => item["exitCode"],
            "aggregated_output" => item["aggregatedOutput"].nil? ? nil : truncate_text(item["aggregatedOutput"])
          }
        end
      end
      observations.unshift({ "kind" => "observation_scope", "earlier_items_omitted" => true }) if response["nextCursor"]
      observations
    end

    # Yields each page of unwrapped items (page order preserved) until the
    # block returns truthy or pages run out. thread/items/list data entries
    # are {"turnId" => ..., "item" => {...}} wrappers (verified against the
    # real app-server); the block sees the inner item hashes.
    def each_item_page(direction, extra = {}, &block)
      cursor = nil
      loop do
        params = { "threadId" => @thread_id, "sortDirection" => direction, "limit" => PAGE_SIZE }.merge(extra)
        params["cursor"] = cursor if cursor
        response = request("thread/items/list", params)
        items = unwrap_item_entries(response.fetch("data", []))
        return if items.empty?

        return if block.call(items)

        cursor = response["nextCursor"]
        return if cursor.nil?
      end
    end

    def unwrap_item_entries(entries)
      entries.map { |entry| entry["item"] }
    end

    def user_message_hash(item)
      content = item.fetch("content", [])
      {
        "id" => message_identifier(item),
        "item_id" => item["id"],
        "text" => content.map { |c| c["text"] if c.is_a?(Hash) }.compact.join,
        "content" => content,
        "client_id" => item["clientId"]
      }
    end

    def message_identifier(item)
      item["clientId"] || item["id"]
    end

    def truncate_text(text)
      return text if text.length <= OBSERVATION_TEXT_LIMIT

      "#{text[0, OBSERVATION_TEXT_LIMIT]}…[truncated #{text.length - OBSERVATION_TEXT_LIMIT} chars]"
    end

    # -- JSON-RPC plumbing ---------------------------------------------------

    def request(method, params = {})
      raise @broken if @broken
      raise ProtocolError, "connection is closed" if @stdin.nil?

      id = @next_id += 1
      waiter = Queue.new
      @waiters_mutex.synchronize { @waiters[id.to_s] = waiter }
      line = JSON.generate({ "id" => id, "method" => method, "params" => params })
      begin
        @write_mutex.synchronize do
          @stdin.write(line)
          @stdin.write("\n")
          @stdin.flush
        end
      rescue SystemCallError, IOError => e
        @waiters_mutex.synchronize { @waiters.delete(id.to_s) }
        break_connection!(ProtocolError.new("write failed for #{method}: #{e.message}"))
      end

      payload = waiter.pop(timeout: @deadline)
      if payload.nil?
        @waiters_mutex.synchronize { @waiters.delete(id.to_s) }
        raise ProtocolError, "deadline (#{@deadline}s) exceeded waiting for #{method} response"
      end
      status, body = payload
      if status == :error
        raise RPCError.new(
          "#{method} failed: #{body['message']}",
          code: body["code"], method_name: method, data: body["data"]
        )
      end

      body
    end

    def start_reader
      @reader = Thread.new do
        loop do
          line = begin
            @stdout_pipe&.gets
          rescue IOError, EOFError, SystemCallError
            nil
          end
          break if line.nil?

          handle_line(line)
        end
      end
    end

    # Keeps the bridge's stderr drained (a full pipe would wedge the child)
    # and retains the tail for failure reports.
    def drain_stderr
      @stderr_reader = Thread.new do
        loop do
          line = begin
            @stderr_pipe&.gets
          rescue IOError, SystemCallError
            nil
          end
          break if line.nil?

          @stderr_tail << line.strip
          @stderr_tail.shift while @stderr_tail.length > 20
        end
      end
    end

    def bridge_failure_detail
      return "" unless @bridge_waiter && !@bridge_waiter.alive?

      tail = @stderr_tail.last(5).join("; ")
      tail.empty? ? " (bridge process exited)" : " (bridge process exited: #{tail})"
    end

    def handle_line(line)
      message = begin
        JSON.parse(line)
      rescue JSON::ParserError
        break_connection!(ProtocolError.new("malformed JSON-RPC line from app-server"))
        return
      end

      if message.key?("id") && (message.key?("result") || message.key?("error"))
        resolve_waiter(message)
      elsif message.key?("id") && message["method"]
        # Server-to-client request (approval, elicitation, dynamic tool call).
        # Deliberately never answered here: approvals stay with the owning
        # client; Orbit must not auto-approve provider requests.
        nil
      elsif message["method"]
        params = message["params"] || {}
        @events << { "method" => message["method"], "params" => params } if params["threadId"] == @thread_id
      end
    rescue StandardError => e
      break_connection!(ProtocolError.new("reader failed: #{e.message}"))
    end

    def resolve_waiter(message)
      waiter = @waiters_mutex.synchronize { @waiters.delete(message["id"].to_s) }
      return if waiter.nil?

      if (error = message["error"])
        waiter << [:error, error]
      else
        waiter << [:ok, message["result"]]
      end
    end

    def break_connection!(error)
      @broken = error
      fail_waiters(error)
    end

    def fail_waiters(error)
      @waiters_mutex.synchronize do
        waiters = @waiters.values
        @waiters.clear
        waiters
      end.each { |waiter| waiter << [:error, { "code" => -32_600, "message" => error.message }] }
    end
  end
end
