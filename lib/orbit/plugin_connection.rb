# frozen_string_literal: true

require "json"
require "socket"
require "timeout"
require_relative "connection"

module Orbit
  # The official Native plugin supplies the native client and owns this
  # private socket. No public port, guessed session or replacement Root.
  class PluginConnection
    Error = Connection::Error
    attr_reader :thread_id, :cwd, :observation_gap

    def initialize(provider:, socket:, thread_id:, deadline: 15)
      @provider, @socket, @thread_id, @deadline = provider, socket, thread_id, deadline
      @sent_ids = []
    end

    def connect!
      @connect_state = state
      @cwd = @connect_state.fetch("cwd")
      self
    end

    # The full session state observed by the connect handshake. The explicit
    # stop retry uses it as its pre-stop session re-read instead of issuing a
    # second request between connect and stop.
    def connect_state
      @connect_state
    end

    def close; end

    def state = request("state")
    def configured_model = request("model")

    # ADR-009 session catalog: the models OMP considers selectable in this
    # session (`ctx.models.list()`), the current writing model, the ephemeral
    # family map used only for family-diversity comparison, and the ephemeral
    # Agent-name map (`agents`, provider/id => non-empty OMP Agent name) that
    # TaskRuntime can use directly instead of recomputing names in Ruby. Ids may
    # contain slashes (provider/id, the id may include `/`). The raw host value
    # is not trusted: malformed ids, empty families and empty agent names are
    # dropped. This reads no credentials.
    def model_catalog
      raw = request("model_catalog")
      raise Error, "native model catalog is malformed" unless raw.is_a?(Hash)

      families = {}
      if raw["families"].is_a?(Hash)
        raw["families"].each do |model, family|
          id = catalog_identifier(model)
          name = family.to_s.strip
          families[id] = name if id && !name.empty?
        end
      end
      agents = {}
      if raw["agents"].is_a?(Hash)
        raw["agents"].each do |model, agent|
          id = catalog_identifier(model)
          name = agent.to_s.strip
          agents[id] = name if id && !name.empty?
        end
      end
      {
        "current" => catalog_identifier(raw["current"]),
        "available" => Array(raw["available"]).filter_map { |model| catalog_identifier(model) }.uniq,
        "families" => families,
        "agents" => agents
      }
    end

    # No memoization: the delegation decision and its signature must reflect
    # the current @task role/model/route resolution at each assessment.
    def member_model_resolution
      request("member_model")
    end
    def default_member_model
      resolved = member_model_resolution
      provider = resolved["provider"].to_s.strip
      id = resolved["id"].to_s.strip
      raise Error, "native task model is unresolved" if provider.empty? || id.empty?

      "#{provider}/#{id}"
    end
    # Sanitized typed billing route from the host's resolved model endpoint
    # (direct_api / subscription_quota / unknown). Older hosts return no field;
    # nil stays unknown and the cost gate fails closed.
    def default_member_route
      resolved = member_model_resolution
      route = resolved["billing_route"].to_s.strip
      route.empty? ? nil : route
    end
    def instruction_source_kind = "#{@provider}_user_message"
    def events = []
    def send_message(text)
      result = request("send", "text" => text)
      @sent_ids << result.fetch("id")
      result
    end
    def stop! = request("stop")
    # Native task members are addressed by durable agent id. session stays the
    # Root thread id so the plugin can check task ownership.
    def member_state(id) = request("member_state", "id" => id)
    def member_result(id) = request("member_result", "id" => id)
    def send_member(id, text) = request("send_member", "id" => id, "text" => text)
    def stop_member(id) = request("stop_member", "id" => id)
    def native_member_roster = request("members")
    def hub_events = request("hub_events")

    def user_message(id: nil)
      messages = request("messages")
      id ? messages.find { |message| message["id"] == id || message["item_id"] == id } : messages.reject { |message| message["internal"] }.last
    end

    def user_messages(after_id:)
      messages = request("messages")
      index = messages.index { |message| message["id"] == after_id }
      @observation_gap = index ? nil : { "reason" => "boundary_not_visible", "detail" => "Original message boundary is absent from native session history" }
      @observation_gap = { "reason" => "pending_delivery", "after_id" => after_id } if !index && @sent_ids.include?(after_id)
      index ? messages.drop(index + 1) : []
    end

    private

    # provider/id with no whitespace; the id may itself contain slashes.
    CATALOG_IDENTIFIER = %r{\A[^\s/]+/[^\s]+\z}

    def catalog_identifier(value)
      text = value.to_s.strip
      text.match?(CATALOG_IDENTIFIER) ? text : nil
    end

    def request(method, params = {})
      Timeout.timeout(@deadline) do
        UNIXSocket.open(@socket) do |socket|
          socket.puts(JSON.generate(params.merge("method" => method, "session" => @thread_id)))
          response = JSON.parse(socket.gets || raise(Error, "Native plugin disconnected"))
          raise Error, response["error"] if response["error"]
          response.fetch("result")
        end
      end
    rescue Timeout::Error, SystemCallError, JSON::ParserError, IOError => error
      raise Error, "#{@provider} connection: #{error.message}"
    end
  end
end
