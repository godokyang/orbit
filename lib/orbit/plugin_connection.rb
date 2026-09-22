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
      @cwd = state.fetch("cwd")
      self
    end

    def close; end

    def state = request("state")
    def configured_model = request("model")
    def default_member_model = configured_model
    def instruction_source_kind = "#{@provider}_user_message"
    def events = []
    def send_message(text)
      result = request("send", "text" => text)
      @sent_ids << result.fetch("id")
      result
    end
    def stop! = request("stop")
    def create_member(model:, cwd:)
      request("create_member", "model" => model, "cwd" => member_cwd(cwd))
    end
    def start_member(id, instruction) = request("start_member", "member" => id, "text" => instruction)

    def member_connection(id)
      self.class.new(provider: @provider, socket: @socket, thread_id: id, deadline: @deadline).connect!
    end

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

    def member_cwd(cwd)
      raise Error, "member creation requires a project directory" if cwd.to_s.strip.empty?

      directory = File.realpath(cwd.to_s)
      raise Error, "member cwd is not a directory: #{cwd}" unless File.directory?(directory)

      directory
    rescue Errno::ENOENT
      raise Error, "member cwd does not exist: #{cwd}"
    rescue Errno::ENOTDIR
      raise Error, "member cwd is not a directory: #{cwd}"
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
