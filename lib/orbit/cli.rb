# frozen_string_literal: true

require "optparse"
require "rbconfig"
require_relative "version"
require_relative "task_record"
require_relative "task_runtime"
require_relative "codex_connection"
require_relative "check_runner"

module Orbit
  module CLI
    module_function

    HELP = <<~TEXT
      Orbit — independent execution checks for an existing coding session

      orbit --version
      orbit version [--json]
      orbit start --review-model MODEL [--thread ID] [--socket PATH]
                  [--message-id ID | --prompt-file FILE|-] [--project DIR]
                  [--basis FILE] [--check-in SECONDS] [--foreground]
                  [--estimate-minutes N] [--estimate-tokens N] [--deadline ISO8601]
      orbit status TASK_DIRECTORY
      orbit stop TASK_DIRECTORY [--reason TEXT]
      orbit check TASK_DIRECTORY
      orbit amend TASK_DIRECTORY --file FILE|-
      orbit dispute TASK_DIRECTORY --reason TEXT

      Root means the coding agent already responsible for the whole user task.
      start binds a session already loaded on the supplied Codex app-server.
      It never creates/resumes a Root, starts a daemon, or falls back to queue-only
      control. The invoking agent's CODEX_THREAD_ID is the default thread.
      Without --prompt-file, the selected/latest native user message is the basis.
      --basis may repeat. Estimates are advisory; only --deadline is a hard limit.
      Reviewer model may also be set with ORBIT_REVIEW_MODEL.
      Records and fixed inputs live under PROJECT/.orbit/tasks/<id>.
    TEXT

    def run(argv)
      command = argv.shift
      case command
      when "version", "--version", "-v"
        raise ArgumentError, "usage: orbit version [--json]" unless argv.empty? || argv == ["--json"]

        puts(argv == ["--json"] ? JSON.pretty_generate(Orbit.version_info) : "orbit #{Orbit::VERSION}")
        0
      when nil, "help", "--help", "-h"
        puts HELP
        0
      when "start"
        start(argv)
      when "run"
        task = TaskRecord.new(required_argument!(argv, "task directory"))
        raise ArgumentError, "unexpected arguments" unless argv.empty?

        run_task(task)
      when "status"
        task = TaskRecord.new(required_argument!(argv, "task directory"))
        raise ArgumentError, "unexpected arguments" unless argv.empty?

        puts JSON.pretty_generate(task.state)
        0
      when "stop", "check", "amend", "dispute"
        submit(command, argv)
      else
        raise ArgumentError, "unknown command #{command.inspect}; run orbit --help"
      end
    rescue ArgumentError, OptionParser::ParseError, SystemCallError, CodexConnection::Error, CheckRunner::Error => error
      warn "orbit: #{error.message}"
      1
    end

    def start(argv)
      codex_directory = ENV.fetch("CODEX_HOME", File.join(Dir.home, ".codex"))
      options = {
        project: Dir.pwd, thread: ENV["CODEX_THREAD_ID"], model: ENV["ORBIT_REVIEW_MODEL"],
        socket: File.join(codex_directory, "app-server-control", "app-server-control.sock"),
        basis: [], interval: 300, estimate: { "seconds" => nil, "tokens" => nil }
      }
      parser = OptionParser.new do |opts|
        opts.on("--project DIR") { |value| options[:project] = value }
        opts.on("--thread ID") { |value| options[:thread] = value }
        opts.on("--socket PATH") { |value| options[:socket] = value }
        opts.on("--review-model MODEL") { |value| options[:model] = value }
        opts.on("--message-id ID") { |value| options[:message_id] = value }
        opts.on("--prompt-file FILE") { |value| options[:prompt_file] = value }
        opts.on("--basis FILE") { |value| options[:basis] << value }
        opts.on("--check-in SECONDS", Integer) { |value| options[:interval] = value }
        opts.on("--estimate-minutes N", Float) { |value| options[:estimate]["seconds"] = value * 60 }
        opts.on("--estimate-tokens N", Integer) { |value| options[:estimate]["tokens"] = value }
        opts.on("--deadline ISO8601") { |value| options[:deadline] = Time.iso8601(value).utc.iso8601 }
        opts.on("--foreground") { options[:foreground] = true }
      end
      parser.parse!(argv)
      raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      raise ArgumentError, "--thread or CODEX_THREAD_ID is required" if options[:thread].to_s.empty?
      raise ArgumentError, "configure --review-model or ORBIT_REVIEW_MODEL" if options[:model].to_s.empty?
      raise ArgumentError, "--check-in must be positive" unless options[:interval].positive?
      raise ArgumentError, "choose --message-id or --prompt-file" if options[:message_id] && options[:prompt_file]
      if options[:estimate].values.compact.any? { |value| !value.positive? || !value.finite? }
        raise ArgumentError, "estimates must be positive finite numbers"
      end

      connection = CodexConnection.new(socket: options[:socket], thread_id: options[:thread])
      begin
        connection.connect!
        unless File.realpath(connection.state.fetch("cwd")) == File.realpath(options[:project])
          raise ArgumentError, "Root session belongs to a different project"
        end
        if options[:prompt_file]
          instruction = read_input(options[:prompt_file])
          source = { "kind" => "explicit_text", "file" => options[:prompt_file] }
        else
          message = connection.user_message(id: options[:message_id])
          raise ArgumentError, "the selected native user message was not found" unless message
          instruction = message.fetch("text")
          source = { "kind" => "codex_user_message", "id" => message.fetch("id") }
        end
      ensure
        connection.close
      end
      raise ArgumentError, "execution instruction is empty" if instruction.strip.empty?

      record = TaskRecord.create(
        project_root: options[:project], instruction: instruction, source: source,
        connection: { "socket" => File.expand_path(options[:socket]), "thread_id" => options[:thread] },
        review: { "model" => options[:model], "interval_seconds" => options[:interval] },
        basis: options[:basis], estimate: options[:estimate]
      )
      state = record.state
      state["hard_deadline"] = options[:deadline] if options[:deadline]
      state["needs_initial_delivery"] = true if options[:prompt_file]
      record.save(state)
      if options[:foreground]
        puts JSON.generate({ "task_directory" => record.path, "status" => "starting" })
        $stdout.flush
        run_task(record)
      else
        entry = File.expand_path("../../scripts/orbit", __dir__)
        log = File.join(record.path, "runtime.log")
        pid = Process.spawn(RbConfig.ruby, "--disable-gems", entry, "run", record.path,
                            in: File::NULL, out: log, err: [:child, :out], pgroup: true)
        Process.detach(pid)
        puts JSON.generate({ "task_directory" => record.path, "status" => "starting", "pid" => pid })
        0
      end
    end

    def run_task(record)
      state = record.state
      connection = CodexConnection.new(socket: state.dig("connection", "socket"), thread_id: state.dig("connection", "thread_id"))
      checker = CheckRunner.new(model: state.dig("review", "model"))
      runtime = TaskRuntime.new(record: record, connection: connection, checker: checker)
      %w[INT TERM].each { |signal| Signal.trap(signal) { runtime.request_stop } }
      result = runtime.run
      puts JSON.generate({ "task_directory" => record.path, "status" => result.fetch("status") })
      %w[complete paused needs_user].include?(result["status"]) ? 0 : 1
    end

    def submit(command, argv)
      record = TaskRecord.new(required_argument!(argv, "task directory"))
      options = {}
      OptionParser.new do |parser|
        parser.on("--reason TEXT") { |value| options["reason"] = value }
        parser.on("--file FILE") { |value| options["file"] = value }
      end.parse!(argv)
      raise ArgumentError, "unexpected arguments" unless argv.empty?
      if TaskRuntime::TERMINAL.include?(record.state["status"])
        raise ArgumentError, "task process has ended; records are retained, no action was queued"
      end
      if command == "amend"
        file = options.fetch("file") { raise ArgumentError, "--file is required" }
        options = { "text" => read_input(file), "source" => { "kind" => "explicit_text", "file" => file } }
      elsif command == "dispute" && options["reason"].to_s.strip.empty?
        raise ArgumentError, "--reason is required"
      end
      id = record.submit(command, options)
      puts JSON.generate({ "task_directory" => record.path, "command_id" => id, "status" => "queued" })
      0
    end

    def read_input(file)
      file == "-" ? $stdin.read : File.read(file)
    end

    def required_argument!(argv, label)
      argv.shift || raise(ArgumentError, "#{label} is required")
    end
  end
end
