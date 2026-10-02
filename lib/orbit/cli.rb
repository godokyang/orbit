# frozen_string_literal: true

require "optparse"
require "rbconfig"
require "io/console"
require_relative "version"
require_relative "task_record"
require_relative "task_runtime"
require_relative "task_evidence"
require_relative "plugin_connection"
require_relative "check_runner"
require_relative "omp_check_runner"
require_relative "jev_advisor"
require_relative "jev_setup"
require_relative "openrouter_setup"
require_relative "omp_entry"
require_relative "prestart"
require_relative "task_view"
require_relative "session_summary"
require_relative "workspace_binding"
require_relative "workspace_snapshot"
require_relative "model_evidence_cache"
require_relative "model_candidate_pool"
require_relative "checker_model_selection"
require_relative "checker_model_selector"
require_relative "diagnostics"
require_relative "release_lease"
require_relative "work_unit"
require_relative "route_resource_store"
require_relative "route_cost_inputs"

module Orbit
  module CLI
    module_function

    # A checker model is `provider/id`; the id may itself contain slashes
    # (e.g. zenmux/x-ai/grok-4.7), matching the pool and OmpCheckRunner.
    CHECKER_MODEL_PATTERN = %r{\A[^\s/]+/[^\s]+\z}

    # Selection thresholds, bounded traceability limits and the shared selector
    # live in CheckerModelSelector (ADR-009); this module only keeps the model
    # identifier shape used by `start`, `build_checker` and `review-model`.

    HELP = <<~TEXT
      Orbit — 执行期间的独立检查与纠偏

      日常使用：
        orbit omp [原生参数]       启动原版 OMP 并加载 Orbit 扩展；普通 omp 不接入
        orbit status [TASK]       查看当前项目任务，TASK 可用 ID 前缀或目录
        orbit session-summary --thread ID [--project DIR]  本地只读汇总同一原生 OMP 会话的任务事实
        orbit stop [TASK]         停止当前项目任务；多任务须指定 TASK
        orbit export TASK --output FILE  打包任务证据为本地自足归档（不上传）
        orbit doctor [TASK]       检查环境与已有会话连接
        orbit jev setup           输入 TypeSafe key，配置新终端环境
        orbit openrouter setup  输入 OpenRouter API key，配置新终端环境（可选）
        orbit update [--ref REF]  更新当前安装，沿用来源与安装目录
        orbit uninstall           卸载当前运行程序
        orbit version [--json]    查看版本与安装来源

      OMP 用 orbit omp 启动受控会话，普通 omp 不加载 Orbit 扩展。
      具体参数：orbit <命令> --help（omp 用 orbit help omp）；状态的机器输出：orbit status --json。
      Agent 执行接口：start / check / amend / dispute / rebind-workspace / takeover-scope / work-unit / route-resources / model-evidence / model-candidates / model-status / review-model（各自 --help）。
    TEXT

    COMMAND_HELP = {
      "omp" => "orbit omp [OMP 原生参数]\n启动原版 OMP 并用 -e 显式加载 Orbit 扩展；模型、profile、工具、权限、恢复与消息参数原样交给 OMP，其他扩展照常加载，退出码照常返回。普通 omp 不加载 Orbit。",
      "status" => "orbit status [TASK] [--json]\n省略 TASK 时查当前项目；多任务列出 ID。没有待处理任务时显示最近结束记录。",
      "session-summary" => "orbit session-summary --thread ID [--project DIR]\n只读汇总该项目同一原生 OMP 会话下的任务与检查/纠偏/Jev 次数；JSON 输出。缺失事件日志或用量保持 unknown/null，不读或导出原生会话正文，不调用模型、不修改任务。",
      "stop" => "orbit stop [TASK] [--reason TEXT] [--json]\n只定位唯一待处理任务；多任务先用 orbit status 查看，再传 ID。请求入队不代表停止已确认。",
      "doctor" => "orbit doctor [TASK] [--json]\n只读检查环境、安装和已有任务记录；通过所选已有任务或当前会话验证连接，不调用模型，不验证登录或额度。",
      "jev" => "orbit jev setup\n交互输入 TypeSafe key，配置 zsh／bash 新终端的 TYPESAFE_API_KEY；不写入 Orbit 配置。",
      "openrouter" => "orbit openrouter setup\n交互输入 OpenRouter API key（无回显），写入 ${XDG_CONFIG_HOME:-$HOME/.config}/openrouter/env（0600，仅当前用户可读），并为 zsh／bash 新终端加入受环境变量优先级保护的加载语句；已有 OPENROUTER_API_KEY 的终端优先沿用。仅保存凭据：不验证 API、不代表任一模型已有基准覆盖；不读取项目 .env，不借用 TYPESAFE_API_KEY，不打印密钥。",
      "update" => "orbit update [--ref REF]\n更新当前安装，默认沿用远程 ref 或本地源码目录；--ref 显式从 GitHub 选择版本。新版本登记的运行任务与宿主引用的旧 release 会保留，待其退出后的下一次安装清理。",
      "uninstall" => "orbit uninstall\n先结束使用本安装的任务和 Coding Agent 会话；仍有存活 lease 时拒绝卸载且保留原安装。卸载会清掉本安装拥有的旧全局入口，保留项目资料。",
      "export" => "orbit export TASK --output FILE\n把一个任务的本地证据打包成单个 tar.gz：导出时的 state、事实时间线（events.jsonl 与协作记录 collaboration.jsonl 按时间合并并标注来源、行号与缺口）、检查快照与产物、basis/amendments、含 sha256 的文件清单与缺失清单。只读导出：不上传、不调用模型、不改变任务状态或完成门；运行中任务按导出时刻截取并标注在途与未定检查。TASK 为任务目录或唯一 ID 前缀；--output 不能位于任务目录内部。归档内 manifest.json 说明全部内容与未包含项。",
      "version" => "orbit version [--json]",
      "check" => "orbit check TASK_DIRECTORY",
      "amend" => "orbit amend TASK_DIRECTORY --file FILE|-",
      "dispute" => "orbit dispute TASK_DIRECTORY --reason TEXT",
      "rebind-workspace" => "orbit rebind-workspace TASK_DIRECTORY PATH [--reason TEXT]\n把产物目录改到同一 Git 仓库中的工作区。命令入队后由任务进程记录来源、原因和历史；amend / dispute 的文字不会切换路径。",
      "takeover-scope" => "orbit takeover-scope TASK_DIRECTORY --file FILE|-\n对已有 takeover 任务补交后来声明的 prior_scope（JSON：prior_scope 必填非空文本，reason 可选）。命令只入队；runtime 作为唯一写入者 append-only 记录声明文本、理由、实际声明时间与提交者来源，创建时的 prior_scope 不覆写，不追认旧执行也不授予完成。非接管任务、已终态或坏载荷拒绝；同内容重试不重复追加。",
      "model-evidence" => <<~TEXT,
        orbit model-evidence [TASK_DIRECTORY] --file FILE|-
        提交 Root 从一手来源核实的任务相关模型质量事实（一个 JSON object 或 array），也可先写缓存。逐候选采用真实 provider、model、reasoning 与 billing_route；必须与实际 OMP 路由匹配，不得改成另一条路由取数。缺失身份或测量日期如实未知；省略 reasoning 表示 provider 默认档，与显式 unknown 不同。一个候选的事实不要求 Root 或全池同时补齐；提交事实不代表 Jev 已推荐或成员已派发。
        占位结构（尖括号处必须替换为真实检索结果）：
          [{"provider":"<真实 provider>","model":"<真实 model>","reasoning":"<实际档位或 unknown>",
            "billing_route":"<实际 direct_api|subscription_quota|unknown>",
            "status":"evidence","retrieved_at":"<ISO8601，含时区>",
            "valid_until":"<ISO8601，可省略，受型号有效期约束>",
            "sources":["https://<一手来源 URL>"],
            "metrics":{"<任务相关质量指标>":{"value":0,"unit":"<单位>","basis":"<测量口径>"}},
            "measured_at":"<实际测量时间，可未知省略>","method_version":"<方法版本，可未知省略>"}]
        sources 为 1–5 个无凭据的绝对 http(s) URL；指标 value 为有限数字，unit/basis 为文本。抓取时效不代表测量时效，measured_at 不能晚于 retrieved_at；未知日期不能用抓取日期填补。
        新补证不接收速度、时间、local_samples 或粗费用 cost_tier；本路由价格与订阅规则由独立资源事实流核验，OpenRouter 报价不能冒充 OMP 价格。缺少可信 token 构成时，不由交叉输入／输出单价判总成本；未知不等于免费。
        无法取得证据时用 status "unavailable" 并给出 reason（不得编造证据）：
          [{"provider":"…","model":"…","reasoning":"…","billing_route":"<已核实的 route 或任务请求标注>",
            "status":"unavailable","retrieved_at":"…","reason":"<为什么无法取得>"}]
        校验后原子写入用户级缓存：带 TASK_DIRECTORY 时向任务进程入队（status "queued"），省略时只写缓存（status "cached"）。后续成员／检查者判断重新读取精确身份事实；不改实际路由，不中断在途检查。精确证据与目录先验同时呈现，有冲突交 Root 复核；未校准只显示事实，不能自动正向推荐。
      TEXT
      "review-model" => "orbit review-model TASK_DIRECTORY --model provider/id [--reason TEXT]\nRoot 可从当前 OMP 可用目录指定检查模型；任务进程在下一次检查前再次核对隔离目录与凭据。已结束任务不接受；在途检查不切换。池外选择记录来源，不要求用户逐型号授权。",
      "work-unit" => <<~TEXT,
        orbit work-unit TASK_DIRECTORY declare|read|list|finish|select --file FILE|-
        Root 持久记录可交接工作单元；read/list 只读，declare/finish 不修改原始用户要求。
        declare 输入 {"spec":{"objective":"目标","requirements":["有效要求引用"],"allowed_paths":["路径"],"allowed_tools":["工具名"],"allowed_commands":["完整命令"],"acceptance":"验收方式","escalation":"何时停止并报 Root"}}，可加 context、decisions、dependencies、execution（root|delegate，默认 delegate）和任务相关 model_requirements。select 输入 {"id":"wu-..."}，返回运行时缓存或当前依据的成员推荐；declare 的原生工具回执在派发前自动返回选型。
        allowed_paths 是成员全部可访问路径（读写共用）：规格／测试／依赖需要访问时也必须列出，或把必要事实放入 context；它不提供自动只读保护。allowed_commands 必须是完整命令，逐字精确匹配，不是前缀。
        read 输入 {"id":"wu-…"}，list 输入 {}；finish 输入 {"id":"wu-…","status":"accepted|rejected|failed","result":"实际结果","verification":"实际核验证据"}。
        单元绑定当前要求版本和实际产物工作区；修订／重新绑定使旧单元不能继续派发或登记 accepted。本命令只记录单元，不派发或登记成员。实际派发须另经原生宿主绑定，Root 不能通过本命令伪造派发。accepted 是 Root 核验记录，不替代独立最终检查或停止确认。已结束任务仅可 read/list。
      TEXT
      "route-resources" => <<~TEXT,
        orbit route-resources import|list|report|forecast [TASK_DIRECTORY] [--project DIR] [--file FILE|-]

        import 读取一个或一组完整 RouteResourceFacts，保存来源、核验窗口、实际路由、账号／计划、币种及原单位；--file 必需。结构验证不证明来源真实，提交者须核对一手依据。
        list 只读显示当前项目私有事实；可用 --file 提供精确过滤字段。report 需要任务目录，优先使用逐调用实际账户；可用 --file 补充实际观察的 account_scope／plan（也可逐路由映射），与回执冲突时保持未知，不从价格文档反填账号。
        forecast 需要活动任务目录及 --file，输入 {"scope":"member|review","work_unit_id":"成员单元 id；review 省略","candidates":{"provider/model":{"route":{"provider":"…","model":"…","reasoning":"unknown","billing_route":"direct_api"},"account_scope":"已核实账户","plan":null,"prediction":{"kind":"declared_workload","usage":{"input":1000,"output":200},"basis":"明确的工作量假设，示例数字不可直接沿用","applies_to":"本单元或本次检查"}}}}。similar_unit 还需可追溯 reference_call_ids；不代替实测用量。预测绑定当前要求和工作区，修订后失效；仅使用已导入的可信本路由价格参与选型，缺失继续按质量依据选择。
        金额只核算有实际调用时刻及完整用量构成的已归属调用；额度保留原规则，不换算金额。OpenRouter 目录报价不能作为 OMP 价格，未知不等于免费，不增加硬预算。
      TEXT
      "model-candidates" => <<~TEXT,
        orbit model-candidates list
        orbit model-candidates add <provider/id>
        orbit model-candidates remove <provider/id>
        orbit model-candidates apply-delta --base LIST --add LIST --remove LIST
        内部桥：读写用户长期候选池（provider/id，id 可含斜杠）。每次 stdout 输出一行 JSON {"models":[...]}；
        出错时非零退出且只输出错误信息，不输出凭据、账号或连接配置。
        apply-delta 供扩展多选界面一次提交净增删差量：LIST 为逗号分隔的 provider/id；base 为打开界面时的池快照，
        任一差量 ID 的入池状态与快照不同则整体拒绝（退出 1），不覆盖其他会话对不同 ID 的修改。
      TEXT
      "model-status" => <<~TEXT,
        orbit model-status [--project DIR] [--thread ID --socket PATH]
        只读诊断：当前长期候选池逐项状态——是否在本 OMP 会话可选目录（需 --thread/--socket）、精确身份的缓存证据是有效／缺失／过期／无法取得还是结构无效，以及质量判定与隔离环境解析的“未探测”标记。不调用 JEV、不探测隔离环境、不建任务、不写文件。
        stdout 输出一行 JSON（pool_empty、session_catalog、evidence_cache、candidates[]，无候选池时报告 OMP 会话当前型号；实际检查从 OMP 可用目录选并预检）。
      TEXT
      "start" => <<~TEXT,
        orbit start [--provider omp] [--project DIR]
                    [--review-model MODEL] [--takeover-file FILE|-]
                    [--thread ID] [--socket PATH] [--message-id ID | --prompt-file FILE|-] [--basis FILE]
                    [--check-in SECONDS] [--estimate-minutes N] [--estimate-tokens N]
                    [--deadline ISO8601] [--foreground]
        仅绑定已有可控 OMP 会话，不创建或替换主执行 Agent。
        project 默认为当前目录；thread 与 socket 来自当前受控 OMP 会话。
        原文来自指定或最近的原生用户消息；--basis 可重复，--prompt-file - 从 stdin 读取。
        候选池有可运行型号时优先池内选模；池空或池内均不可运行时从 OMP 当前会话目录选。经真实任务校准并匹配实际输入／题义／Jev 型号的质量判断才可正向推荐；未放行时呈现事实并保留可运行候选。start 尚无工作单元上下文时不猜验收。model-evidence 可补充精确质量事实；无法取得如实记录 unavailable。Root 也可用 --review-model 指定 OMP 可用型号，不要求原生用户逐型号授权；所有选择均预检隔离检查者目录与凭据。
        --check-in 首次默认 300 秒，后续由检查者约定；预估不是硬上限。
        只有用户明确设置的 --deadline 才形成截止。--foreground 在当前终端运行任务进程。
        --takeover-file - 传接管请求（JSON：reason 必填，prior_scope 可选声明），对已执行的原始要求申请接管；
        必须复用其原生消息（--message-id 或最近的原生用户消息），不接收任何调用方自报的摘要／日期：
        接管时把真实工作区快照存进该任务私有目录（记摘要与相对路径），摘要与监督开始时刻均由程序采集，
        不接受调用方自报；旧执行不被追认为受控，其用量／成员／检查不迁入本任务。
      TEXT
      "entry" => <<~TEXT,
        orbit entry --provider omp --project DIR --thread ID --socket PATH --message-id ID
        Internal bridge for the OMP extension's pre-start hook: classify the latest unbound native
        user message (by its native message id) into start / no_start / root_decides. Never creates
        a task; decision "start" tells the caller to use the normal start path with the returned
        entry file. One JSON object on stdout; idempotent per message id.
      TEXT
    }.freeze

    # `orbit help <command>` explains the wrapper, but a launcher that keeps the
    # native CLI surface must not swallow the native --help/-h. Commands here
    # forward --help/-h to their native binary; `orbit help <command>` still
    # prints COMMAND_HELP.
    NATIVE_HELP_PASSTHROUGH = %w[omp].freeze

    def run(argv)
      command = argv.shift
      wrapper_help = false
      if command == "help" && argv.length == 1
        command = argv.shift
        argv = ["--help"]
        wrapper_help = true
      end
      if COMMAND_HELP.key?(command) && (["--help"] == argv || ["-h"] == argv) &&
         (wrapper_help || !NATIVE_HELP_PASSTHROUGH.include?(command))
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
      when "openrouter"
        setup_openrouter(argv)
      when "omp"
        OmpEntry.launch(argv)
      when "uninstall"
        raise ArgumentError, "usage: orbit uninstall" unless argv.empty?
        runtime = installed_runtime
        exec RbConfig.ruby, "--disable-gems", File.join(Orbit::ROOT, "scripts/manage-install.rb"),
             "uninstall", "--runtime-dir", runtime
      when "update"
        update(argv)
      when "start"
        start(argv)
      when "entry"
        entry(argv)
      when "run"
        task = TaskRecord.new(required_argument!(argv, "task directory"))
        raise ArgumentError, "unexpected arguments" unless argv.empty?

        run_task(task)
      when "status"
        status(argv)
      when "rebind-workspace"
        rebind_workspace(argv)
      when "takeover-scope"
        takeover_scope(argv)
      when "session-summary"
        session_summary(argv)
      when "model-evidence"
        model_evidence(argv)
      when "model-candidates"
        model_candidates(argv)
      when "model-status"
        model_status(argv)
      when "review-model"
        review_model(argv)
      when "work-unit"
        work_unit(argv)
      when "route-resources"
        route_resources(argv)
      when "stop", "check", "amend", "dispute"
        submit(command, argv)
      when "export"
        export(argv)
      else
        raise ArgumentError, "unknown command #{command.inspect}; run orbit --help"
      end
    rescue ArgumentError, OptionParser::ParseError, SystemCallError, Connection::Error, CheckRunner::Error,
           WorkspaceBinding::Error, ModelEvidenceCache::Error, ModelCandidatePool::Error, JSON::ParserError,
           PrestartClassifier::Error, PrestartLedger::Error, JevAdvisor::Error, TaskEvidence::Error, WorkUnitStore::Error,
           RouteResourceStore::Error, RouteResourceFacts::Error, ResourceCallLedger::Error, RouteCostInputs::Error => error
      warn "orbit: #{error.message}"
      1
    end

    def status(argv)
      json = false
      OptionParser.new { |parser| parser.on("--json") { json = true } }.parse!(argv)
      raise ArgumentError, "usage: orbit status [TASK] [--json]" if argv.length > 1
      records = TaskView.select(argv.first, settled: true)
      if json
        puts JSON.pretty_generate(records.length == 1 ? TaskView.current_state(records.first) :
                                  { "tasks" => records.map { |record| TaskView.current_state(record) } })
      elsif records.empty?
        puts "当前项目还没有 Orbit 任务。进入项目，向 Agent 提出执行要求即可。"
      elsif records.length == 1
        puts TaskView.format(records.first)
      else
        puts "当前项目有多个待处理任务：\n#{TaskView.list(records)}\n查看或停止一个任务：orbit status ID / orbit stop ID（ID 可用唯一前缀）。"
      end
      0
    end
    def session_summary(argv)
      options = { project: Dir.pwd }
      OptionParser.new do |parser|
        parser.on("--thread ID") { |value| options[:thread] = value }
        parser.on("--project DIR") { |value| options[:project] = value }
      end.parse!(argv)
      unless argv.empty? && options[:thread].is_a?(String) && !options[:thread].empty?
        raise ArgumentError, "usage: orbit session-summary --thread ID [--project DIR]"
      end
      puts JSON.pretty_generate(SessionSummary.report(project: options[:project], thread: options[:thread]))
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

    def setup_openrouter(argv)
      raise ArgumentError, "usage: orbit openrouter setup" unless argv == ["setup"]

      warn "输入 OpenRouter API key（输入时不显示）："
      value = $stdin.tty? ? $stdin.noecho(&:gets) : $stdin.gets
      warn if $stdin.tty?
      raise ArgumentError, "未输入 OpenRouter API key" unless value

      result = OpenRouterSetup.configure(value)
      puts "已配置新终端的 OPENROUTER_API_KEY；OpenRouter 环境文件：#{result.fetch('env_file')}（仅当前用户可读）。"
      puts "重新打开终端后从该终端启动 Coding Agent；当前终端和已运行任务不会自动改变。"
      puts "仅保存凭据：不代表 API 已认证，也不代表任一候选模型已有基准覆盖。"
      warn "当前环境已有 OPENROUTER_API_KEY；新终端会优先沿用已有环境变量。" unless ENV["OPENROUTER_API_KEY"].to_s.empty?
      0
    end

    def doctor(argv)
      json = false
      OptionParser.new { |parser| parser.on("--json") { json = true } }.parse!(argv)
      raise ArgumentError, "usage: orbit doctor [TASK] [--json]" if argv.length > 1
      record = if argv.first
                 TaskView.single!(argv.first).state.fetch("connection")
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
      puts "更新程序（含 orbit omp 入口）；旧全局入口由安装器按记录安全清理。"
      $stdout.flush
      exec({ "ORBIT_REF" => nil }, "sh", entry, *source_args, *args)
    end

    def start(argv)
      options = {
        project: Dir.pwd, provider: "omp", thread: nil, model: nil,
        socket: nil,
        basis: [], interval: 300, estimate: { "seconds" => nil, "tokens" => nil }
      }
      parser = OptionParser.new do |opts|
        opts.on("--project DIR") { |value| options[:project] = value }
        opts.on("--provider NAME", %w[omp]) { |value| options[:provider] = value }
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
        opts.on("--entry-file FILE") { |value| options[:entry_file] = value }
        opts.on("--takeover-file FILE") { |value| options[:takeover_file] = value }
      end
      parser.parse!(argv)
      raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      raise ArgumentError, "--thread is required" if options[:thread].to_s.empty?
      raise ArgumentError, "--socket is required" if options[:socket].to_s.empty?
      raise ArgumentError, "--check-in must be positive" unless options[:interval].positive?
      raise ArgumentError, "choose --message-id or --prompt-file" if options[:message_id] && options[:prompt_file]
      takeover = options[:takeover_file] ? TaskRecord.parse_takeover(read_input(options[:takeover_file])) : nil
      if takeover && options[:prompt_file]
        raise ArgumentError, "takeover reuses the requirement's original native message; --prompt-file cannot take over"
      end
      entry_document = entry_trace(options[:entry_file]) if options[:entry_file]
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
        if options[:prompt_file]
          instruction = read_input(options[:prompt_file])
          source = { "kind" => "explicit_text", "file" => options[:prompt_file] }
        else
          message = connection.user_message(id: options[:message_id])
          raise ArgumentError, "the selected native user message was not found" unless message
          instruction = message.fetch("text")
          source = { "kind" => connection.instruction_source_kind, "id" => message.fetch("id") }
          if entry_document && (entry_document["decision"] != "start" || entry_document["message_id"] != message.fetch("id"))
            raise ArgumentError, "entry decision does not authorize this native message"
          end
          previous = PrestartLedger.new(File.realpath(options[:project])).task_for(message.fetch("id"))
          raise ArgumentError, "this native message already has an Orbit task: #{previous}" if previous
        end
        options[:model], options[:selection] = select_checker_model(options[:model], connection, options[:project], instruction)
      ensure
        connection.close
      end
      raise ArgumentError, "execution instruction is empty" if instruction.strip.empty?

      # The takeover boundary is captured by the program (real preserved
      # workspace snapshot, process clock) inside the new record's private
      # directory, before its state is written: a boundary that cannot be
      # captured removes the half-created record and no task claims supervision.
      record =
        begin
          TaskRecord.create(
            project_root: options[:project], instruction: instruction, source: source,
            connection: connection_record,
            review: { "model" => options[:model], "interval_seconds" => options[:interval], "selection" => options[:selection] },
            basis: options[:basis], estimate: options[:estimate], takeover: takeover
          )
        rescue WorkspaceSnapshot::Error => error
          raise ArgumentError, "the takeover boundary could not be captured (#{error.message}); no task was created"
        end
      state = record.state
      takeover_block = state["takeover"]
      state["hard_deadline"] = options[:deadline] if options[:deadline]
      # The pre-start entry decision that led here (orbit entry → extension
      # start): stored verbatim so the task record carries its own trace of
      # why the entry path started it.
      state["entry"] = entry_document if entry_document
      state["needs_initial_delivery"] = true if options[:prompt_file]
      record.save(state)
      record.event("checker_model_selected", "model" => options[:model],
                   "source" => options[:selection]["source"], "selected_for" => "start",
                   "selection" => options[:selection])
      response = { "task_directory" => record.path, "status" => "starting",
                   "review_model" => options[:model],
                   "selection_tier" => options[:selection]["selection_tier"] }
      response["notice"] = options[:selection]["notice"] if options[:selection]["notice"]
      if takeover_block
        response["takeover"] = {
          "format" => takeover_block["format"], "supervision_started_at" => takeover_block.dig("supervision", "starts_at"),
          "artifact_digest" => takeover_block.dig("artifact", "digest"), "artifact_root" => takeover_block.dig("artifact", "root"),
          "artifact_snapshot" => takeover_block.dig("artifact", "snapshot_path"),
          "native_message_id" => takeover_block.dig("requirement", "native_message_id"),
          "prior_scope" => takeover_block.dig("prior_scope", "status")
        }
        response["takeover_notice"] = "supervision starts at this takeover (" \
          "#{takeover_block.dig('supervision', 'starts_at')}); the earlier execution of this requirement was not controlled and its usage, " \
          "members and checks are not imported. If that execution still has running work, resources or unregistered members, wind it " \
          "down yourself: Orbit does not register or claim retroactive members, async work or usage."
      end
      if options[:selection]["evidence_needed"]&.any?
        response["evidence_needed"] = options[:selection]["evidence_needed"]
        response["evidence_action"] = "可选：只有精确事实会改变当前任务的模型判断时，Root 才从一手来源核查并用 " \
                                      "orbit model-evidence --file - 提交（检查者补证不传任务目录）；" \
                                      "逐项保留 evidence_needed 的真实 model、reasoning、billing_route，" \
                                      "model 仅按首个 / 拆成 provider 与其余 model id。" \
                                      "不得为命中缓存把订阅路由改成 unknown，无法核实就保持未知；" \
                                      "已选可运行检查者与当前交付不以补齐其它候选为前置。"
      end
      if options[:foreground]
        puts JSON.generate(response)
        $stdout.flush
        run_task(record)
      else
        entry = File.expand_path("../../scripts/orbit", __dir__)
        log = File.join(record.path, "runtime.log")
        pid = Process.spawn(RbConfig.ruby, "--disable-gems", entry, "run", record.path,
                            in: File::NULL, out: log, err: [:child, :out], pgroup: true)
        Process.detach(pid)
        puts JSON.generate(response.merge("pid" => pid))
        0
      end
    end

    # Internal bridge for the OMP extension's pre-start hook
    # (before_provider_request, main session, no bound task). Reads the native
    # user message by its id through the same socket protocol as `start`,
    # classifies it once per message id and reports what the caller should do.
    # This command never creates a task and never dispatches members; a
    # "start" decision instructs the caller to use the normal start path with
    # the returned entry file so the task record keeps its own trace.
    def entry(argv)
      options = { project: Dir.pwd, provider: "omp", thread: nil, socket: nil, message_id: nil }
      OptionParser.new do |opts|
        opts.on("--project DIR") { |value| options[:project] = value }
        opts.on("--provider NAME", %w[omp]) { |value| options[:provider] = value }
        opts.on("--thread ID") { |value| options[:thread] = value }
        opts.on("--socket PATH") { |value| options[:socket] = value }
        opts.on("--message-id ID") { |value| options[:message_id] = value }
      end.parse!(argv)
      raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      raise ArgumentError, "--thread is required" if options[:thread].to_s.empty?
      raise ArgumentError, "--socket is required" if options[:socket].to_s.empty?
      raise ArgumentError, "--message-id is required" if options[:message_id].to_s.empty?

      project = File.realpath(options[:project])
      connection_record = { "provider" => options[:provider], "socket" => File.expand_path(options[:socket]),
                            "thread_id" => options[:thread] }
      ledger = PrestartLedger.new(project)
      connection = Connection.open(connection_record)
      begin
        connection.connect!
        unless File.realpath(connection.state.fetch("cwd")) == project
          raise ArgumentError, "Root session belongs to a different project"
        end
        message = connection.user_message(id: options[:message_id])
        raise ArgumentError, "the selected native user message was not found" unless message

        message_id = message.fetch("id")
        task_directory = ledger.task_for(message_id)
        previous = ledger.lookup(message_id)
        if previous || task_directory
          # Idempotence: the same native message is classified and started at
          # most once. An existing task wins over any recorded decision.
          puts JSON.generate(
            "schema_version" => 1, "message_id" => message_id, "decision" => "duplicate",
            "previous_decision" => previous && previous["decision"], "task_directory" => task_directory,
            "reason" => "this native message was already classified or already has an Orbit task"
          )
          return 0
        end

        classifier = PrestartClassifier.new(project_root: project)
        decision = classifier.decide(message.fetch("text"))
        document = decision.merge(
          "message_id" => message_id, "at" => Time.now.utc.iso8601,
          "prompt_excerpt" => classifier.excerpt(message.fetch("text"))
        )
        entry_file = ledger.record(message_id, document)
        document["entry_file"] = entry_file if document["decision"] == "start"
        if document["decision"] == "root_decides"
          document["prompt"] = "本条入口判定不确定（#{decision.fetch('reason')}）；是否启动 Orbit 由 Root 显式决定，" \
                               "按有效执行要求核对实质交接或独立监督价值后用 orbit 工具 start；" \
                               "串行交接与有成果要求的只读审计也可适用，无需用户逐次确认。"
        end
        puts JSON.generate(document)
        0
      ensure
        connection.close
      end
    end

    # Loads and validates the entry trace document for `start --entry-file`.
    def entry_trace(path)
      document = JSON.parse(read_input(path))
      raise ArgumentError, "the entry file must be one JSON object" unless document.is_a?(Hash)
      raise ArgumentError, "the entry file has no decision" unless document["decision"].is_a?(String)

      document
    end

    # ADR-009 selection is shared with TaskRuntime so that `orbit start` and
    # every later check apply exactly the same rules (pool ∩ session catalog,
    # reviewed task-fit judgment and actual model facts, then isolated resolvability
    # order). See CheckerModelSelector for the full contract.
    def select_checker_model(explicit, connection, project, instruction)
      CheckerModelSelector.new(connection: connection, project_root: project)
                          .select(explicit: explicit, instruction: instruction, selected_for: "start")
    end

    # Root may choose any model in the current OMP catalog. This command
    # preflights availability before queueing; the runtime rechecks before
    # starting a new independent review.
    def work_unit(argv)
      options = { file: "-" }
      OptionParser.new { |parser| parser.on("--file FILE") { |value| options[:file] = value } }.parse!(argv)
      directory, operation = argv
      unless argv.length == 2 && %w[declare read list finish select].include?(operation)
        raise ArgumentError, "usage: orbit work-unit TASK_DIRECTORY declare|read|list|finish|select --file FILE|-"
      end
      record = TaskRecord.new(File.realpath(directory))
      if %w[declare finish select].include?(operation) && TaskRuntime::TERMINAL.include?(record.state["status"])
        raise ArgumentError, "task process has ended; work units are retained read-only"
      end
      payload = JSON.parse(read_input(options[:file]))
      raise ArgumentError, "work-unit input must be one JSON object" unless payload.is_a?(Hash)

      store = WorkUnitStore.new(record)
      result = case operation
               when "declare" then { "unit" => store.declare(payload["spec"]) }
               when "read" then { "unit" => store.read(payload["id"]) }
               when "list" then { "units" => store.list }
               when "finish"
                 { "unit" => store.finish(payload["id"], status: payload["status"], result: payload["result"],
                                           verification: payload["verification"]) }
               when "select" then select_work_unit(record, store, payload)
               end
      puts JSON.generate(result.merge("ok" => true, "task_directory" => record.path))
      0
    end

    # Runtime remains the sole selection/state writer. The native tool awaits
    # this bounded response before the Root can issue its member model call.
    def select_work_unit(record, store, payload)
      unit = store.read(payload["id"])
      raise ArgumentError, "unknown work unit; declare a bounded unit before selecting" unless unit

      pid = record.state["runtime_pid"]
      raise ArgumentError, "task runtime is not running; selection cannot precede dispatch" unless pid.is_a?(Integer) && pid.positive?
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        raise ArgumentError, "task runtime has exited; selection cannot precede dispatch"
      end
      request_id = SecureRandom.uuid
      response_path = File.join(record.path, "member-selection-responses", "#{request_id}.json")
      record.submit("member_selection", "request_id" => request_id, "work_unit_id" => unit.fetch("id"))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      loop do
        if File.file?(response_path)
          response = JSON.parse(File.read(response_path))
          raise ArgumentError, response["reason"] || "member selection failed" unless response["ok"] == true

          return { "selection" => response.fetch("selection"), "request_id" => request_id }
        end
        if TaskRuntime::TERMINAL.include?(record.state["status"])
          raise ArgumentError, "task stopped before member selection returned (request #{request_id})"
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise ArgumentError, "member selection is still pending (request #{request_id}); inspect the existing request before retrying"
        end
        sleep 0.1
      end
    end

    def route_resources(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--project DIR") { |value| options[:project] = value }
        parser.on("--file FILE") { |value| options[:file] = value }
      end.parse!(argv)
      action, directory = argv.shift, argv.shift
      unless %w[import list report forecast].include?(action) && argv.empty? && (%w[report forecast].include?(action) || directory.nil?)
        raise ArgumentError, "usage: orbit route-resources import|list|report|forecast [TASK_DIRECTORY] [--project DIR] [--file FILE|-]"
      end
      record = TaskRecord.new(directory) if %w[report forecast].include?(action) && directory
      raise ArgumentError, "#{action} needs a task directory" if %w[report forecast].include?(action) && !record

      root = File.realpath(options[:project] || record&.state&.fetch("project_root") || TaskView.project(Dir.pwd))
      store = RouteResourceStore.new(project_root: root)
      payload = options[:file] ? JSON.parse(read_input(options[:file])) : {}
      result = case action
               when "import"
                 raise ArgumentError, "import needs --file FILE|-" unless options[:file]
                 store.import(payload)
               when "list"
                 raise ArgumentError, "filters must be an object" unless payload.is_a?(Hash)
                 { "facts" => store.list(**payload.slice("scope", "route", "account_scope", "plan", "source_kind").transform_keys(&:to_sym)) }
               when "report"
                 raise ArgumentError, "actual resource context must be an object" unless payload.is_a?(Hash)
                 store.report(task_path: record.path, account_scope: payload["account_scope"], plan: payload["plan"])
               when "forecast"
                 raise ArgumentError, "forecast needs --file FILE|-" unless options[:file]
                 raise ArgumentError, "forecast must be an object" unless payload.is_a?(Hash)
                 raise ArgumentError, "settled tasks cannot accept a new forecast" if TaskRuntime::TERMINAL.include?(record.state["status"])
                 { "forecast" => RouteCostInputs.new(record: record, store: store).record_inputs(
                     scope: payload["scope"], candidates: payload["candidates"], work_unit_id: payload["work_unit_id"]),
                   "note" => "bounded prediction only; no measured consumption or budget guarantee" }
               end
      puts JSON.generate(result.merge("ok" => true))
      0
    end

    def review_model(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--model MODEL") { |value| options["model"] = value }
        parser.on("--reason TEXT") { |value| options["reason"] = value }
      end.parse!(argv)
      directory = argv.shift
      raise ArgumentError, "usage: orbit review-model TASK_DIRECTORY --model provider/id" if directory.nil? || !argv.empty?

      model = options["model"].to_s.strip
      raise ArgumentError, "OMP review model must be provider/id" unless model.match?(CHECKER_MODEL_PATTERN)
      record = TaskRecord.new(directory)
      state = record.state
      raise ArgumentError, "task process has ended; records are retained" if TaskRuntime::TERMINAL.include?(state["status"])

      connection = Connection.open(state.fetch("connection"))
      begin
        connection.connect!
        raise ArgumentError, "Root session belongs to a different project" unless
          File.realpath(connection.state.fetch("cwd")) == state.fetch("project_root")
        CheckerModelSelector.new(connection: connection, project_root: state.fetch("project_root"))
                            .select(explicit: model, instruction: record.inputs(state).fetch("instruction"),
                                    selected_for: "review_model")
      ensure
        connection.close
      end
      reason = options["reason"].to_s.strip
      reason = "Root selected another OMP checker model" if reason.empty?
      id = record.submit("review_model", "model" => model, "reason" => reason)
      puts JSON.generate({ "task_directory" => record.path, "command_id" => id, "status" => "queued", "model" => model })
      0
    end

    def build_checker(state)
      raise ArgumentError, "unsupported session provider" unless state.dig("connection", "provider") == "omp"

      model = state.dig("review", "model").to_s
      raise ArgumentError, "OMP review model must be provider/id" unless model.match?(CHECKER_MODEL_PATTERN)

      OmpCheckRunner.new(model: model, source_agent_dir: state.dig("review", "selection", "source_agent_dir"),
                         source_project_dir: state.fetch("project_root"))
    end

    def run_task(record)
      # A task process resolves check rules and other files from its release
      # for its whole lifetime; the lease keeps an update from deleting it.
      ReleaseLease.hold!
      state = record.state
      connection = Connection.open(state.fetch("connection"))
      checker = build_checker(state)
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

    # Later prior_scope declarations for an existing takeover boundary. This
    # command only enqueues: the runtime is the sole state writer and appends
    # the declaration to takeover.prior_scope_declarations without touching
    # the created boundary. The declaration is the submitter's statement, not
    # a program observation and not a new native user message.
    def takeover_scope(argv)
      options = { file: "-" }
      OptionParser.new do |parser|
        parser.on("--file FILE") { |value| options[:file] = value }
      end.parse!(argv)
      directory = argv.shift
      raise ArgumentError, "usage: orbit takeover-scope TASK_DIRECTORY --file FILE|-" if directory.nil? || !argv.empty?

      record = TaskRecord.new(File.realpath(directory))
      if TaskRuntime::TERMINAL.include?(record.state["status"])
        raise ArgumentError, "task process has ended; records are retained, no declaration will be queued"
      end
      unless record.state["takeover"].is_a?(Hash)
        raise ArgumentError, "task is not a takeover task; there is no prior-execution boundary to declare toward"
      end

      payload = begin
        JSON.parse(read_input(options[:file]))
      rescue JSON::ParserError
        raise ArgumentError, "the declaration must be one JSON object"
      end
      raise ArgumentError, "the declaration must be one JSON object" unless payload.is_a?(Hash)
      unknown = payload.keys - %w[prior_scope reason]
      unless unknown.empty?
        raise ArgumentError, "the declaration only accepts prior_scope and reason; these cannot take effect: #{unknown.join(', ')}"
      end
      scope = payload["prior_scope"]
      raise ArgumentError, "prior_scope must be a non-empty string" unless scope.is_a?(String) && !scope.strip.empty?
      reason = payload["reason"]
      raise ArgumentError, "reason must be text when present" unless reason.nil? || reason.is_a?(String)

      source = { "kind" => "submitter_declaration", "via" => "cli", "command" => "takeover-scope" }
      details = { "prior_scope" => scope, "source" => source }
      details["reason"] = reason unless reason.nil? || reason.strip.empty?
      id = record.submit("takeover_scope", details)
      puts JSON.generate({ "task_directory" => record.path, "command_id" => id, "status" => "queued" })
      0
    end

    def model_evidence(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--file FILE") { |value| options["file"] = value }
      end.parse!(argv)
      directory = argv.shift
      taskless = directory.nil? && argv.empty?
      raise ArgumentError, "usage: orbit model-evidence [TASK_DIRECTORY] --file FILE|-" unless taskless || (directory && argv.empty?)

      # A taskless submission updates the user cache both before startup and
      # during a running task's checker-evidence request. Checker re-selection
      # reads it before the next check; no member-evidence command is queued.
      record = nil
      unless taskless
        # The record and its terminal state are resolved before the cache is
        # touched, so a missing or finished task cannot leave new evidence.
        record = TaskRecord.new(directory)
        if TaskRuntime::TERMINAL.include?(record.state["status"])
          raise ArgumentError, "task process has ended; records are retained, no action was queued"
        end
      end

      payload = JSON.parse(read_input(options.fetch("file") { raise ArgumentError, "--file is required" }))
      unless payload.is_a?(Hash) || (payload.is_a?(Array) && !payload.empty?)
        raise ArgumentError, "model evidence must be one JSON object or a non-empty array of objects"
      end

      # Full validation and the atomic write happen before queueing; a
      # rejected submission is never queued. The queue carries the typed
      # identity (including billing_route) and status only, and the runtime
      # re-reads the validated cache instead of trusting a copy of metrics,
      # sources or page text; dropping billing_route would make every
      # direct_api submission look like an unknown-route mismatch.
      entries = ModelEvidenceCache.new.record_all(payload)
      identities = entries.map { |entry| entry.slice("provider", "model", "reasoning", "billing_route") }
      if taskless
        puts JSON.generate({ "status" => "cached", "count" => entries.length, "identities" => identities })
        return 0
      end

      summary = entries.map { |entry| entry.slice("provider", "model", "reasoning", "billing_route", "status") }
      id = record.submit("model_evidence", "entries" => summary,
                         "source" => { "kind" => "cli", "command" => "model-evidence" })
      puts JSON.generate({ "task_directory" => record.path, "command_id" => id, "status" => "queued",
                           "count" => entries.length, "identities" => identities })
      0
    end

    # Internal bridge for the `orbit omp` extension: read and edit the shared
    # model candidate pool (ADR-009), reusing ModelCandidatePool instead of a
    # second store. Each call prints one JSON document to stdout; failures go
    # through the top-level handler, exit non-zero and never print credentials.
    def model_candidates(argv)
      subcommand = argv.shift
      case subcommand
      when "list"
        raise ArgumentError, "usage: orbit model-candidates list" unless argv.empty?

        report_model_candidates(ModelCandidatePool.new.read)
      when "add"
        model = required_argument!(argv, "provider/id")
        raise ArgumentError, "usage: orbit model-candidates add <provider/id>" unless argv.empty?

        report_model_candidates(ModelCandidatePool.new.add(model))
      when "remove"
        model = required_argument!(argv, "provider/id")
        raise ArgumentError, "usage: orbit model-candidates remove <provider/id>" unless argv.empty?
        report_model_candidates(ModelCandidatePool.new.remove(model))
      when "apply-delta"
        # One atomic net-delta commit for the extension's multi-select picker:
        # `base` is the snapshot the caller took when its picker opened, and
        # identifiers are comma-separated (a provider/id never contains a
        # comma). A same-ID change since the snapshot refuses the whole commit
        # (exit 1 via the top-level handler) instead of overwriting it.
        options = { "base" => [], "add" => [], "remove" => [] }
        OptionParser.new do |parser|
          options.each_key do |flag|
            parser.on("--#{flag} LIST") { |value| options[flag] = value.split(",") }
          end
        end.parse!(argv)
        raise ArgumentError, "usage: orbit model-candidates apply-delta --base LIST --add LIST --remove LIST" unless argv.empty?

        report_model_candidates(ModelCandidatePool.new.apply_delta(
                                  base: options.fetch("base"), add: options.fetch("add"), remove: options.fetch("remove")
                                ))
      else
        raise ArgumentError, "usage: orbit model-candidates list|add <provider/id>|remove <provider/id>|apply-delta --base LIST --add LIST --remove LIST"
      end
    end

    def report_model_candidates(models)
      puts JSON.generate("models" => models)
      0
    end

    # Read-only per-candidate diagnostics (ADR-009 2026-09-27 supplement)
    # for the candidate UX and for Root explaining a blocked start: pool
    # membership in the session catalog (when a session is given) and the
    # cached evidence status per exact identity. Never probes the isolated
    # checker profile, never calls JEV, never creates a task and never
    # writes anything. Without --thread/--socket the session catalog is
    # reported "not_provided" rather than guessed.
    def model_status(argv)
      options = { project: Dir.pwd, provider: "omp", thread: nil, socket: nil }
      OptionParser.new do |parser|
        parser.on("--project DIR") { |value| options[:project] = value }
        parser.on("--provider NAME", %w[omp]) { |value| options[:provider] = value }
        parser.on("--thread ID") { |value| options[:thread] = value }
        parser.on("--socket PATH") { |value| options[:socket] = value }
      end.parse!(argv)
      raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      if options[:thread].to_s.empty? != options[:socket].to_s.empty?
        raise ArgumentError, "--thread and --socket must be given together"
      end

      report =
        if options[:thread] && options[:socket]
          record = { "provider" => options[:provider], "socket" => File.expand_path(options[:socket]),
                     "thread_id" => options[:thread] }
          opened = Connection.open(record)
          begin
            opened.connect!
            unless File.realpath(opened.state.fetch("cwd")) == File.realpath(options[:project])
              raise ArgumentError, "Root session belongs to a different project"
            end
            CheckerModelSelector.new(connection: opened, project_root: options[:project]).candidate_statuses
          ensure
            opened.close
          end
        else
          CheckerModelSelector.new(connection: nil, project_root: options[:project]).candidate_statuses
        end
      puts JSON.generate(report)
      0
    end

    def submit(command, argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--reason TEXT") { |value| options["reason"] = value }
        parser.on("--file FILE") { |value| options["file"] = value }
        parser.on("--json") { options["json"] = true } if command == "stop"
        # Internal: the Orbit Root tool marks a deliberate post-finalization
        # completion hand-off. Plain CLI stops never set it.
        parser.on("--complete") { options["complete"] = true } if command == "stop"
      end.parse!(argv)
      argument = argv.shift
      raise ArgumentError, "unexpected arguments" unless argv.empty?
      record = command == "stop" ? TaskView.single!(argument) : TaskRecord.new(argument || raise(ArgumentError, "task directory is required"))
      json = command != "stop" || options.delete("json")
      # A completion intent is adjudicated synchronously, before anything is
      # queued and before the cleanup retry: the record keeps running and the
      # caller gets a structured receipt (exit 0) with the one next action. A
      # record whose runtime is gone (or already failed) cannot be completed at
      # all -- only an explicit ordinary stop can clean it up -- so it is never
      # silently recorded paused through retry_stop. A plain stop keeps that
      # retry path untouched.
      if command == "stop" && options["complete"] == true
        refusal = if retryable_stop?(record)
                    [TaskRuntime::RUNTIME_UNAVAILABLE_REASON,
                     "the recorded task runtime is gone or already failed; an explicit ordinary stop performs the confirmed cleanup"]
                  elsif !TaskRuntime::TERMINAL.include?(record.state["status"])
                    TaskRuntime.completion_refusal(record)
                  end
        if refusal
          code, detail = refusal
          record.event("completion_stop_rejected", "source" => "cli", "reason" => code, "detail" => detail)
          payload = { "task_directory" => record.path, "status" => "rejected", "reason" => code, "detail" => detail,
                      "next_action" => TaskRuntime.completion_next_action(code) }
          puts(json ? JSON.generate(payload) : "完成请求未被接受：#{detail}\n#{payload['next_action']}")
          return 0
        end
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
      if command == "check" && %w[check_failure selection_undecided].include?(record.state.dig("review", "blocked", "type"))
        payload = {
          "task_directory" => record.path, "status" => "rejected", "reason" => "checker_model_blocked",
          "next_action" => "No runnable OMP checker remains. Root can inspect OMP availability and run orbit review-model TASK_DIRECTORY --model provider/id after credentials or models change"
        }
        puts JSON.generate(payload)
        return 0
      end
      if command == "amend"
        file = options.fetch("file") { raise ArgumentError, "--file is required" }
        options = { "text" => read_input(file), "source" => { "kind" => "explicit_text", "file" => file } }
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
        payload["next_action"] = "排队后直接结束当前轮次，检查者的 finalization_notice 或纠正会唤醒当前助手；不要为等待结论调用 wait、sleep、poll、status 或查询 CLI 帮助。在收到之前不要把交付当作完成，也不要主动 stop（用户明确中断除外）。"
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

    # User-invoked, local-only evidence export:
    # resolves one task, refuses unsafe destinations, and leaves the task record
    # untouched. All completeness facts live in the archive's manifest.json.
    def export(argv)
      output = nil
      OptionParser.new { |parser| parser.on("--output FILE") { |value| output = value } }.parse!(argv)
      argument = argv.shift
      if argument.nil? || !argv.empty? || output.to_s.strip.empty?
        raise ArgumentError, "usage: orbit export TASK --output FILE"
      end

      matches = TaskView.select(argument)
      raise ArgumentError, "找不到任务 #{argument}；在项目中运行 orbit status 查看任务。" if matches.empty?
      if matches.length > 1
        raise ArgumentError, "存在多个任务，请指定任务 ID 或目录：\n#{TaskView.list(matches)}"
      end

      puts JSON.generate(TaskEvidence.export(record: matches.first, output: output))
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
