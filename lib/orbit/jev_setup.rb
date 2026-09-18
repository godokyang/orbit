# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "shellwords"

module Orbit
  # One-time shell setup. The task runtime still receives Jev's key only from
  # TYPESAFE_API_KEY; no Orbit configuration or task record stores it.
  class JevSetup
    ENV_FILE = File.join("typesafe-ai", "env")

    def self.configure(value, env: ENV, home: Dir.home)
      key = value.to_s.strip
      raise ArgumentError, "TypeSafe key cannot be empty" if key.empty?
      raise ArgumentError, "TypeSafe key must be one line" if key.match?(/[\r\n\0]/)

      files = shell_files(env: env, home: home)
      base = env["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : env["XDG_CONFIG_HOME"]
      path = File.expand_path(File.join(base, ENV_FILE))
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("export TYPESAFE_API_KEY=#{key.shellescape}\n")
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end

      source = path.shellescape
      block = "# TypeSafe environment for Orbit\n" \
              "if [ -z \"${TYPESAFE_API_KEY:-}\" ] && [ -f #{source} ]; then . #{source}; fi\n"
      files.each do |file|
        content = File.file?(file) ? File.read(file) : ""
        next if content.include?(block)

        FileUtils.mkdir_p(File.dirname(file))
        File.open(file, "a", 0o600) { |handle| handle.write("\n" + block) }
      end
      { "env_file" => path, "shell_files" => files }
    end

    def self.shell_files(env:, home:)
      case File.basename(env["SHELL"].to_s)
      when "zsh"
        [File.join(env["ZDOTDIR"].to_s.empty? ? home : File.expand_path(env["ZDOTDIR"]), ".zshrc")]
      when "bash"
        profiles = %w[.bash_profile .bash_login .profile].map { |name| File.join(home, name) }
        [File.join(home, ".bashrc"), profiles.find { |path| File.file?(path) } || File.join(home, ".profile")]
      else
        raise ArgumentError, "orbit jev setup currently supports zsh and bash (SHELL=#{env['SHELL'].inspect})"
      end
    end
  end
end
