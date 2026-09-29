# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "shellwords"

module Orbit
  # Optional one-time shell setup for the OpenRouter model overview. It keeps
  # JevSetup's safe-write conventions but an independent credential: the file
  # only exports OPENROUTER_API_KEY, is private to the user (0600, directory
  # 0700) and is loaded by zsh/bash startup files only when the environment
  # does not already provide the variable. The TypeSafe key, project `.env`
  # files and Orbit task records are never read or written here, and no Orbit
  # output prints the key. Saving the key proves nothing about API validity or
  # model coverage; the first refresh is what contacts OpenRouter.
  class OpenRouterSetup
    ENV_FILE = File.join("openrouter", "env")

    def self.configure(value, env: ENV, home: Dir.home)
      key = value.to_s.strip
      raise ArgumentError, "OpenRouter key cannot be empty" if key.empty?
      raise ArgumentError, "OpenRouter key must be one line" if key.match?(/[\r\n\0]/)

      files = shell_files(env: env, home: home)
      base = env["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : env["XDG_CONFIG_HOME"]
      path = File.expand_path(File.join(base, ENV_FILE))
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.chmod(0o700, File.dirname(path))
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("export OPENROUTER_API_KEY=#{key.shellescape}\n")
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end

      source = path.shellescape
      block = "# OpenRouter environment for Orbit\n" \
              "if [ -z \"${OPENROUTER_API_KEY:-}\" ] && [ -f #{source} ]; then . #{source}; fi\n"
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
        raise ArgumentError, "orbit openrouter setup currently supports zsh and bash (SHELL=#{env['SHELL'].inspect})"
      end
    end
  end
end
