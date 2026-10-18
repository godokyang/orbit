# frozen_string_literal: true

require "json"
require_relative "../lib/orbit/hosts/omp/plugin_connection"

# Static consistency of the host-port contract with the adapter that serves it.
# Real behavior is covered by the probes under tests/host_conformance/.
module HostConformanceTest
  ROOT = File.expand_path("..", __dir__)
  CONTRACT = File.join(ROOT, "contracts", "host-port.json")
  RUBY = File.join(ROOT, "lib", "orbit", "hosts", "omp", "plugin_connection.rb")
  JS = File.join(ROOT, "plugins", "omp-host.mjs")
  REQUIRED = %w[host_port session_state session_abort session_prompt ask_requests answer_ask current_model model_catalog default_member_route
                messages send_message stop_root member_roster member_state member_result
                send_member stop_member collaboration_events bind_task].freeze

  module_function

  def assert(value, message)
    raise "ASSERTION FAILED: #{message}" unless value
  end

  def run
    contract = JSON.parse(File.read(CONTRACT))
    assert(contract["contract"] == "orbit-host-port", "contract name")
    assert(contract["version"] == "1.0", "contract version")
    methods = contract["methods"]
    REQUIRED.each { |name| assert(methods[name], "method #{name} is declared") }

    ruby = File.read(RUBY)
    used = ruby.scan(/request\("([a-z_]+)"/).flatten.uniq
    (used - ["host_port"]).each do |name|
      assert(methods[name], "Ruby request(#{name}) has a contract entry")
    end

    js = File.read(JS)
    REQUIRED.each do |name|
      next if name == "host_port"
      assert(js.include?("case '#{name}'"), "adapter serves #{name}")
    end
    assert(js.include?("case 'host_port': return { version: '1.0' }"), "adapter declares the version")

    obligations = contract["obligations"]
    assert(obligations["required"] == %w[H2 H3 H4 H5 H6 H7], "required obligations")
    assert(obligations["optional"] == %w[H1 O1 O2 O3 O4], "optional obligations")
    obligations["definitions"].each_key do |key|
      assert(obligations["required"].include?(key) || obligations["optional"].include?(key),
             "obligation #{key} has a level")
    end
    puts "host_conformance_test: ok"
  end
end

HostConformanceTest.run
