# frozen_string_literal: true

require "json"
require "socket"
require "tmpdir"
require_relative "../lib/orbit/plugin_connection"

# Deterministic socket fixture for PluginConnection#model_catalog: the host
# reply is untrusted, so malformed ids, empty families and empty agent names are
# dropped while valid provider/id keys (including ids with slashes) and the
# Agent-name map are kept for TaskRuntime.
module PluginConnectionTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def with_server(result)
    Dir.mktmpdir("orbit-plugin-conn-") do |dir|
      socket = File.join(dir, "host.sock")
      server = UNIXServer.new(socket)
      requests = []
      worker = Thread.new do
        peer = server.accept
        requests << JSON.parse(peer.gets)
        peer.puts(JSON.generate("result" => result))
        peer.close
      end
      yield Orbit::PluginConnection.new(provider: "omp", socket: socket, thread_id: "root"), requests
      worker.join(3)
      server.close
    end
  end

  def model_catalog_normalizes_and_filters
    result = {
      "current" => "root/model",
      "available" => ["zenmux/x-ai/grok-4.7", "not-a-model", "provider/nocred"],
      "families" => { "zenmux/x-ai/grok-4.7" => "x", "junk" => "y", "provider/nocred" => "  " },
      "agents" => { "zenmux/x-ai/grok-4.7" => "orbit-m-1", "junk" => "orbit-m-2", "provider/nocred" => "  " }
    }
    with_server(result) do |connection, requests|
      catalog = connection.model_catalog
      assert(requests.first["method"] == "model_catalog" && requests.first["session"] == "root",
             "model_catalog is a session-scoped host request")
      assert(catalog["current"] == "root/model", "the current writing model is kept")
      assert(catalog["available"] == ["zenmux/x-ai/grok-4.7", "provider/nocred"],
             "available keeps only valid provider/id, including ids with slashes")
      assert(catalog["families"] == { "zenmux/x-ai/grok-4.7" => "x" },
             "families drop malformed ids and empty family names")
      assert(catalog["agents"] == { "zenmux/x-ai/grok-4.7" => "orbit-m-1" },
             "agents keep only valid provider/id keys with a non-empty Agent name")
    end
  end

  def run
    model_catalog_normalizes_and_filters
    puts "PLUGIN_CONNECTION_TEST_PASS"
  end
end

PluginConnectionTest.run
