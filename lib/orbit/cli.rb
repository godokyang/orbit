# frozen_string_literal: true

require "optparse"
require "rbconfig"
require "io/console"
require_relative "version"
require_relative "task_record"
require_relative "task_runtime"
require_relative "codex_connection"
require_relative "plugin_connection"
require_relative "check_runner"
require_relative "jev_advisor"
require_relative "jev_setup"
require_relative "member_policy"
require_relative "session_entry"
require_relative "task_view"
require_relative "workspace_binding"
require_relative "model_evidence_cache"
require_relative "diagnostics"
require_relative "release_lease"

module Orbit
  module CLI
    module_function

    HELP = <<~TEXT
      Orbit — 执行期间的独立检查与纠偏

      日常使用：
        orbit codex [原生参数]     打开支持接入的 Codex；恢复用 orbit codex resume
        orbit status [TASK]       查看当前项目任务，TASK 可用 ID 前缀或目录
        orbit stop [TASK]         停止当前项目任务；多任务须指定 TASK
        orbit doctor [TASK]       检查环境与已有会话连接
        orbit jev setup           输入 TypeSafe key，配置新终端环境
        orbit update [--ref REF]  更新当前安装，沿用来源与安装目录
        orbit uninstall           卸载当前运行程序和原生连接扩展
        orbit version [--json]    查看版本与安装来源

      OpenCode / OMP 继续直接运行 opencode / omp。
      skill 独立安装与维护：npx skills install godokyang/orbit --skill orbit --global
      具体参数：orbit <命令> --help；状态的机器输出：orbit status --json。
      Agent 执行接口：start / check / amend / dispute / delegate / rebind-workspace / model-evidence（各自 --help）。
    TEXT

    COMMAND_HELP = {
      "status" => "orbit status [TASK] [--json]\n省略 TASK 时查当前项目；多任务列出 ID。没有待处理任务时显示最近结束记录。",
      "stop" => "orbit stop [TASK] [--reason TEXT] [--json]\n只定位唯一待处理任务；多任务先用 orbit status 查看，再传 ID。请求入队不代表停止已确认。",
      "doctor" => "orbit doctor [TASK] [--json]\n只读检查环境和扩展；通过当前 Codex 会话或所选已有任务验证连接，不调用模型，不验证登录或额度。",
      "jev" => "orbit jev setup\n交互输入 TypeSafe key，配置 zsh／bash 新终端的 TYPESAFE_API_KEY；不写入 Orbit 配置。",
      "update" => "orbit update [--ref REF]\n更新当前安装，默认沿用远程 ref 或本地源码目录；--ref 显式从 GitHub 选择版本。新版本登记的运行任务与宿主引用的旧 release 会保留，待其退出后的下一次安装清理。skill 用 npx skills update orbit --global 单独更新。",
      "uninstall" => "orbit uninstall\n先结束使用本安装的任务和 Coding Agent 会话；仍有存活 lease 时拒绝卸载且保留原安装。卸载保留项目资料与独立 skill。",
      "version" => "orbit version [--json]",
      "check" => "orbit check TASK_DIRECTORY",
      "amend" => "orbit amend TASK_DIRECTORY --file FILE|-",
      "dispute" => "orbit dispute TASK_DIRECTORY --reason TEXT",
      "delegate" => "orbit delegate TASK_DIRECTORY --file FILE|- [--kind codex] [--model MODEL] [--member THREAD_ID]",
      "rebind-workspace" => "orbit rebind-workspace TASK_DIRECTORY PATH [--reason TEXT]\n把产物目录改到同一 Git 仓库中的工作区。命令入队后由任务进程记录来源、原因和历史；amend / dispute 的文字不会切换路径。",
      "model-evidence" => "orbit model-evidence TASK_DIRECTORY --file FILE|-\n提交 Root 检索到的模型事实证据（JSON object 或 array）。Orbit 校验模型标识、来源 URL、取得时间、有效期和指标口径后原子写入用户级缓存，再通知任务进程重查；不修改用户要求，不保存网页正文或凭据。",
      "start" => <<~TEXT
        orbit start [--provider codex|opencode|omp] [--project DIR]
                    [--review-model MODEL] [--thread ID] [--socket PATH]
                    [--message-id ID | --prompt-file FILE|-] [--basis FILE]
                    [--check-in SECONDS] [--estimate-minutes N] [--estimate-tokens N]
                    [--deadline ISO8601] [--foreground]
        仅绑定已有可控会话，不创建或替换主执行 Agent。
        project 默认为当前目录；Codex thread / socket 默认来自当前会话环境。
        原文来自指定或最近的原生用户消息；--basis 可重复，--prompt-file - 从 stdin 读取。
        检查模型沿用 ORBIT_REVIEW_MODEL 或现有 Codex 模型配置。
        --check-in 首次默认 300 秒，后续由检查者约定；预估不是硬上限。
        只有用户明确设置的 --deadline 才形成截止。--foreground 在当前终端运行任务进程。
      TEXT
    }.freeze

    def run(argv)
      command = argv.shift
      if command == "help" && argv.length == 1
        command = argv.shift
        argv = ["--help"]
      end
      if COMMAND_HELP.key?(command) && (["--help"] == argv || ["-h"] == argv)
        puts COMMAND_HELP.fetch(command)
        return 0
      end
      case command
      when "version", "--version", "-v"
        raise ArgumentError, "usage: orbit version [--json]" unless argv.empty? || argv == ["--json"]

        puts(argv == ["--json"] ? JSON.pretty_generate(Orbit.version_info) : "orbit #{Orbit::VERSION}")
        0
      when nil, "help", "--help", "-h"
        puts HELP
        0
      when "doctor"
        doctor(argv)
      when "jev"
        setup_jev(argv)
      when "codex"
        SessionEntry.launch(argv)
      when "uninstall"
        raise ArgumentError, "usage: orbit uninstall" unless argv.empty?
        runtime = installed_runtime
        exec RbConfig.ruby, "--disable-gems", File.join(Orbit::ROOT, "scripts/manage-install.rb"),
             "uninstall", "--runtime-dir", runtime
      when "update"
        update(argv)
      when "start"
        start(argv)
      when "run"
        task = TaskRecord.new(required_argument!(argv, "task directory"))
        raise ArgumentError, "unexpected arguments" unless argv.empty?

        run_task(task)
      when "status"
        status(argv)
      when "rebind-workspace"
        rebind_workspace(argv)
      when "model-evidence"
        model_evidence(argv)
      when "stop", "check", "amend", "dispute", "delegate"
        submit(command, argv)
      else
        raise ArgumentError, "unknown command #{command.inspect}; run orbit --help"
      end
    rescue ArgumentError, OptionParser::ParseError, SystemCallError, Connection::Error, CheckRunner::Error,
           MemberPolicy::Error, WorkspaceBinding::Error, ModelEvidenceCache::Error, JSON::ParserError => error
      warn "orbit: #{error.message}"
      1
    end

    def status(argv)
      json = false
      OptionParser.new { |parser| parser.on("--json") { json = true } }.parse!(argv)
      raise ArgumentError, "usage: orbit status [TASK] [--json]" if argv.length > 1
      records = TaskView.select(argv.first, settled: true)
      if json
        puts JSON.pretty_generate(records.length == 1 ? records.first.state : { "tasks" => records.map(&:state) })
      elsif records.empty?
        puts "当前项目还没有 Orbit 任务。进入项目，向 Agent 提出执行要求即可。"
      elsif records.length == 1
        puts TaskView.format(records.first)
      else
        puts "当前项目有多个待处理任务：\n#{TaskView.list(records)}\n查看或停止一个任务：orbit status ID / orbit stop ID（ID 可用唯一前缀）。"
      end
      0
    end

    def setup_jev(argv)
      raise ArgumentError, "usage: orbit jev setup" unless argv == ["setup"]

      warn "输入 TypeSafe key（输入时不显示）："
      value = $stdin.tty? ? $stdin.noecho(&:gets) : $stdin.gets
      warn if $stdin.tty?
      raise ArgumentError, "未输入 TypeSafe key" unless value

      result = JevSetup.configure(value)
      puts "已配置新终端的 TYPESAFE_API_KEY；TypeSafe 环境文件：#{result.fetch('env_file')}（仅当前用户可读）。"
      puts "重新打开终端后直接启动 Coding Agent；当前终端和已运行任务不会自动改变。"
      warn "当前环境已有 TYPESAFE_API_KEY；新终端会优先沿用已有环境变量。" unless ENV["TYPESAFE_API_KEY"].to_s.empty?
      0
    end

    def doctor(argv)
      json = false
      OptionParser.new { |parser| parser.on("--json") { json = true } }.parse!(argv)
      raise ArgumentError, "usage: orbit doctor [TASK] [--json]" if argv.length > 1
      record = if argv.first
                 TaskView.single!(argv.first).state.fetch("connection")
               elsif !ENV["CODEX_THREAD_ID"].to_s.empty?
                 { "provider" => "codex", "thread_id" => ENV["CODEX_THREAD_ID"], "socket" => SessionEntry.socket_path }
               else
                 candidates = TaskView.select
                 candidates.first.state.fetch("connection") if candidates.length == 1
               end
      report = Diagnostics.report(connection_record: record)
      puts(json ? JSON.pretty_generate(report) : Diagnostics.format(report))
      report["environment_ready"] && report.dig("installation", "ready") != false && report.dig("connection", "ready") != false ? 0 : 2
    end

    def installed_runtime
      Orbit.installed_runtime
    end

    def update(argv)
      ref = nil
      OptionParser.new { |parser| parser.on("--ref REF") { |value| ref = value } }.parse!(argv)
      raise ArgumentError, "usage: orbit update [--ref REF]" unless argv.empty?
      runtime = installed_runtime
      owner = JSON.parse(File.read(File.join(runtime, ".orbit-install.json")))
      source = Orbit.version_info.fetch("source")
      if ref || source["kind"] == "github"
        ref ||= source.fetch("ref")
        entry = File.join(Orbit::ROOT, "install.sh")
        source_args = ["--ref", ref]
      else
        path = source["path"]
        unless path && File.file?(File.join(path, "install.sh"))
          raise ArgumentError, "本地源码目录不可用；从源码目录重新安装，或用 orbit update --ref main 明确改用远程来源。"
        end
        entry = File.join(path, "install.sh")
        source_args = []
      end
      args = ["--runtime-dir", runtime, "--bin-dir", owner.fetch("bin_dir")]
      %w[opencode omp].each do |host|
        directory = owner["#{host}_dir"]
        args.concat(directory ? ["--#{host}-dir", directory] : ["--no-#{host}"])
      end
      puts "更新程序及原生连接扩展；skill 请用 npx skills update orbit --global 单独更新。"
      $stdout.flush
      exec({ "ORBIT_REF" => nil }, "sh", entry, *source_args, *args)
    end

    def start(argv)
      options = {
        project: Dir.pwd, provider: "codex", thread: ENV["CODEX_THREAD_ID"], model: ENV["ORBIT_REVIEW_MODEL"],
        socket: SessionEntry.socket_path,
        basis: [], interval: 300, estimate: { "seconds" => nil, "tokens" => nil }
      }
      parser = OptionParser.new do |opts|
        opts.on("--project DIR") { |value| options[:project] = value }
        opts.on("--provider NAME", %w[codex opencode omp]) { |value| options[:provider] = value }
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
      raise ArgumentError, "--check-in must be positive" unless options[:interval].positive?
      raise ArgumentError, "choose --message-id or --prompt-file" if options[:message_id] && options[:prompt_file]
      if options[:estimate].values.compact.any? { |value| !value.positive? || !value.finite? }
        raise ArgumentError, "estimates must be positive finite numbers"
      end

      connection_record = { "provider" => options[:provider], "socket" => File.expand_path(options[:socket]), "thread_id" => options[:thread] }
      connection = Connection.open(connection_record)
      begin
        connection.connect!
        unless File.realpath(connection.state.fetch("cwd")) == File.realpath(options[:project])
          raise ArgumentError, "Root session belongs to a different project"
        end
        options[:model] ||= options[:provider] == "codex" ? connection.configured_model : CheckRunner.configured_model
        raise ArgumentError, "configure --review-model or ORBIT_REVIEW_MODEL" if options[:model].to_s.empty?
        if options[:prompt_file]
          instruction = read_input(options[:prompt_file])
          source = { "kind" => "explicit_text", "file" => options[:prompt_file] }
        else
          message = connection.user_message(id: options[:message_id])
          raise ArgumentError, "the selected native user message was not found" unless message
          instruction = message.fetch("text")
          source = { "kind" => connection.instruction_source_kind, "id" => message.fetch("id") }
        end
      ensure
        connection.close
      end
      raise ArgumentError, "execution instruction is empty" if instruction.strip.empty?

      record = TaskRecord.create(
        project_root: options[:project], instruction: instruction, source: source,
        connection: connection_record,
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
      # A task process resolves check rules and other files from its release
      # for its whole lifetime; the lease keeps an update from deleting it.
      ReleaseLease.hold!
      state = record.state
      connection = Connection.open(state.fetch("connection"))
      checker = CheckRunner.new(model: state.dig("review", "model"))
      advisor = JevAdvisor.for_project(state.fetch("project_root"))
      runtime = TaskRuntime.new(record: record, connection: connection, checker: checker, advisor: advisor,
                                evidence_cache: ModelEvidenceCache.new)
      %w[INT TERM].each { |signal| Signal.trap(signal) { runtime.request_stop } }
      result = runtime.run
      puts JSON.generate({ "task_directory" => record.path, "status" => result.fetch("status") })
      %w[complete paused needs_user].include?(result["status"]) ? 0 : 1
    end

    def rebind_workspace(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--reason TEXT") { |value| options["reason"] = value }
      end.parse!(argv)
      directory = argv.shift
      path = argv.shift
      raise ArgumentError, "usage: orbit rebind-workspace TASK_DIRECTORY PATH [--reason TEXT]" if directory.nil? || path.nil? || !argv.empty?

      record = TaskRecord.new(directory)
      if TaskRuntime::TERMINAL.include?(record.state["status"])
        raise ArgumentError, "task process has ended; records are retained, no action was queued"
      end

      reason = options["reason"].to_s.strip
      reason = "explicit workspace rebind" if reason.empty?
      source = { "kind" => "cli", "command" => "rebind-workspace" }
      current = record.state["workspace"]
      current = WorkspaceBinding.bind(project_root: record.state.fetch("project_root")) unless current.is_a?(Hash)
      canonical = WorkspaceBinding.rebind(current, artifact_root: path).fetch("artifact_root")
      id = record.submit("rebind_workspace", "path" => canonical, "reason" => reason, "source" => source)
      puts JSON.generate({ "task_directory" => record.path, "command_id" => id, "status" => "queued" })
      0
    end

    def model_evidence(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--file FILE") { |value| options["file"] = value }
      end.parse!(argv)
      directory = argv.shift
      raise ArgumentError, "usage: orbit model-evidence TASK_DIRECTORY --file FILE|-" if directory.nil? || !argv.empty?

      # The record and its terminal state are resolved before the cache is
      # touched, so a missing or finished task cannot leave new evidence.
      record = TaskRecord.new(directory)
      if TaskRuntime::TERMINAL.include?(record.state["status"])
        raise ArgumentError, "task process has ended; records are retained, no action was queued"
      end

      payload = JSON.parse(read_input(options.fetch("file") { raise ArgumentError, "--file is required" }))
      unless payload.is_a?(Hash) || (payload.is_a?(Array) && !payload.empty?)
        raise ArgumentError, "model evidence must be one JSON object or a non-empty array of objects"
      end

      # Full validation and the atomic write happen before queueing; a
      # rejected submission is never queued. The queue carries identity and
      # status only, and the runtime re-reads the validated cache instead of
      # trusting a copy of metrics, sources or page text.
      entries = ModelEvidenceCache.new.record_all(payload)
      summary = entries.map { |entry| entry.slice("provider", "model", "reasoning", "status") }
      id = record.submit("model_evidence", "entries" => summary,
                         "source" => { "kind" => "cli", "command" => "model-evidence" })
      puts JSON.generate({ "task_directory" => record.path, "command_id" => id, "status" => "queued",
                           "count" => entries.length, "identities" => summary.map { |entry| entry.slice("provider", "model", "reasoning") } })
      0
    end

    def submit(command, argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--reason TEXT") { |value| options["reason"] = value }
        parser.on("--file FILE") { |value| options["file"] = value }
        parser.on("--kind KIND") { |value| options["kind"] = value }
        parser.on("--model MODEL") { |value| options["model"] = value }
        parser.on("--member THREAD_ID") { |value| options["member"] = value }
        parser.on("--json") { options["json"] = true } if command == "stop"
      end.parse!(argv)
      argument = argv.shift
      raise ArgumentError, "unexpected arguments" unless argv.empty?
      record = command == "stop" ? TaskView.single!(argument) : TaskRecord.new(argument || raise(ArgumentError, "task directory is required"))
      json = command != "stop" || options.delete("json")
      # New members are checked against the allowlist and the verified
      # adapters before anything is queued or created.
      if command == "delegate" && options["member"].to_s.empty?
        provider = record.state.dig("connection", "provider")
        policy = MemberPolicy.load
        kind = policy.resolve_kind(options["kind"] || "native", provider)
        policy.check!(kind)
        MemberAdapters.require!(kind, provider)
      end
      if command == "stop" && retryable_stop?(record)
        state = record.state
        connection = Connection.open(state.fetch("connection"))
        result = TaskRuntime.new(record: record, connection: connection, checker: nil).retry_stop(
          options.fetch("reason", "The user requested cleanup after runtime exit")
        )
        puts(json ? JSON.generate({ "task_directory" => record.path, "status" => result.fetch("status") }) : TaskView.format(record))
        return result["status"] == "paused" ? 0 : 1
      end
      if TaskRuntime::TERMINAL.include?(record.state["status"])
        raise ArgumentError, "task process has ended; records are retained, no action was queued"
      end
      if %w[amend delegate].include?(command)
        file = options.fetch("file") { raise ArgumentError, "--file is required" }
        options = options.slice("model", "member", "kind").merge("text" => read_input(file), "source" => { "kind" => "explicit_text", "file" => file })
        raise ArgumentError, "instruction is empty" if options["text"].strip.empty?
      elsif command == "dispute" && options["reason"].to_s.strip.empty?
        raise ArgumentError, "--reason is required"
      end
      id = record.submit(command, options)
      payload = { "task_directory" => record.path, "command_id" => id, "status" => "queued" }
      # A manual check is queued work. Unless the user already required an
      # independent state change, the caller should end this turn; polling only
      # to wait wastes a Root turn and creates another observation.
      if command == "check"
        payload["next_action"] = "若无用户已明确要求且不依赖检查结果的后续状态变更，结束当前轮次并等待 Orbit 通知；不要仅为等待检查结论而 sleep、poll 或 status"
      end
      puts(json ? JSON.generate(payload) : "已提交停止请求，尚未确认停止。用 orbit status #{record.state.fetch('id')} 查看结果。")
      0
    end

    # failed/stop_unconfirmed always accept an explicit stop retry; a task
    # whose recorded runtime process is gone is treated the same way instead
    # of queueing a command no process will ever consume.
    def retryable_stop?(record)
      status = record.state["status"]
      return true if %w[failed stop_unconfirmed].include?(status)
      return false unless %w[starting running].include?(status)

      TaskView.runtime_abandoned?(record.state)
    end

    def read_input(file)
      file == "-" ? $stdin.read : File.read(file)
    end

    def required_argument!(argv, label)
      argv.shift || raise(ArgumentError, "#{label} is required")
    end
  end
end
