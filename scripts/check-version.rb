# frozen_string_literal: true

require_relative "../lib/orbit/version"

package = JSON.parse(File.read(File.join(Orbit::ROOT, "package.json")))
lock = JSON.parse(File.read(File.join(Orbit::ROOT, "npm-shrinkwrap.json")))
raise "invalid package version" unless Orbit::VERSION.match?(/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/)
raise "lockfile version differs from package.json" unless [lock["version"], lock.dig("packages", "", "version")].all? { |v| v == Orbit::VERSION }
raise "lockfile dependencies differ from package.json" unless lock.dig("packages", "", "dependencies") == package["dependencies"]
puts "Version and lockfile consistent: #{Orbit::VERSION}"
