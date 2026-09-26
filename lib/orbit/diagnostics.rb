# frozen_string_literal: true

require "open3"
require_relative "version"
require_relative "plugin_connection"
require_relative "check_runner"
require_relative "omp_entry"
require_relative "../../scripts/manage-install"

module Orbit
  module Diagnostics
    module_function

    def report(connection_record: nil)
      dependencies = dependency_checks
      connection = connection_check(connection_record)
      installation = installation_check
      environment_ready = dependencies.all? { |item| item["ready"] }
      {
        "version" => VERSION,
        "ready" => environment_ready && installation["ready"] != false && connection["ready"] == true,
        "environment_ready" => environment_ready,
        "dependencies" => dependencies,
        "installation" => installation,
        "omp_entry" => omp_entry_check,
        "connection" => connection,
        "checker" => checker_check(connection),
        "migration" => migration_status,
        "credentials" => { "verified" => false, "detail" => "未请求模型；登录、模型可用性和额度未验证。" }
      }
    end

    # The implemented single-host entry: orbit omp loads this release's
    # extension for the selected session. OMP versions below the floor are
    # refused at launch. This section states only what is wired today; the
    # native task/hub team, registration
    # gate and independent OMP checker are implemented alongside it, with the
    # target-path end-to-end acceptance still in progress (see the migration
    # status and docs/plan/omp-native-migration.md).
    def omp_entry_check
      extension = File.join(File.realpath(ROOT), "plugins/omp.mjs")
      ready = File.file?(extension)
      omp = executable("omp")
      version = nil
      version_error = nil
      if omp
        begin
          version = OmpEntry.detected_version(omp)
        rescue StandardError => error
          version_error = error.message
        end
      end
      version_ready = version && OmpEntry.supported_version?(version)
      item = {
        "entry" => "orbit omp",
        "extension" => extension,
        "extension_ready" => ready,
        "omp_path" => omp,
        "version" => version,
        "minimum_version" => OmpEntry::MINIMUM_OMP_VERSION,
        # Preserve the old doctor field for callers; its value is now the floor.
        "pinned_version" => OmpEntry::PINNED_OMP_VERSION,
        "version_ready" => version.nil? ? nil : version_ready
      }
      if omp.nil?
        item["detail"] = ready ? "orbit omp 显式加载当前安装目录的扩展；普通 omp 不加载 Orbit 扩展。" : "Orbit 扩展缺失；orbit omp 无法加载。"
        item["omp_next_step"] = "未在 PATH 中找到 omp；安装 Oh My Pi #{OmpEntry::MINIMUM_OMP_VERSION} 或更新版本后使用 orbit omp。"
      elsif version.nil?
        item["detail"] = "无法确定 OMP 版本；orbit omp 会拒绝启动。"
        item["version_next_step"] = version_error.to_s
      elsif version_ready
        item["detail"] = "orbit omp 显式加载当前安装目录的扩展；普通 omp 不加载 Orbit 扩展（OMP #{version} 满足最低版本要求）。"
      else
        item["detail"] = "OMP #{version} 低于最低支持版本 #{OmpEntry::MINIMUM_OMP_VERSION}；orbit omp 会拒绝启动。"
        item["version_next_step"] = "升级到 OMP #{OmpEntry::MINIMUM_OMP_VERSION} 或更新版本。"
      end
      item["next_step"] = "用 install.sh 修复当前安装后重试 orbit omp。" unless ready
      item
    end

    def migration_status
      {
        "phase" => "M4",
        "detail" => "单宿主安装与 orbit omp 显式入口、原生 task/hub 执行成员（登记门、成员桥与协作观察）、独立 OMP 检查组件、旧宿主移除与合同同步均已实现；目标路径端到端真实验收进行中，未验收前不视为通过。"
      }
    end

    # The independent check runs in a separate read-only OMP session. This
    # section reports that component and the model it will use; it never
    # presents another host's configuration as the checker.
    def checker_check(connection)
      model = ENV["ORBIT_REVIEW_MODEL"]
      source = "ORBIT_REVIEW_MODEL"
      if model.to_s.empty?
        model = connection["configured_model"]
        source = "当前 OMP 会话模型"
      end
      item = {
        "component" => "omp-reviewer",
        "status" => "active",
        "detail" => "独立检查由单独的 OMP 只读会话执行（runners/omp-reviewer，固定快照）；不进入执行团队。"
      }
      item["model"] = model
      item["source"] = source
      item["next_step"] = "显式设置 ORBIT_REVIEW_MODEL，或使用会话内的 provider/id 模型。" if model.to_s.empty?
      item["connection_config_error"] = connection["model_error"] if connection["model_error"]
      item
    rescue StandardError => error
      { "component" => "omp-reviewer", "status" => "active", "model" => nil,
        "detail" => "读取检查模型失败：#{error.message}",
        "next_step" => "显式设置 ORBIT_REVIEW_MODEL。" }
    end

    def format(report)
      lines = ["Orbit #{report.fetch('version')} 诊断", "运行依赖：#{report['environment_ready'] ? '通过' : '需要处理'}"]
      report.fetch("dependencies").each do |item|
        lines << "  #{item['ready'] ? '✓' : '✗'} #{item['name']}：#{item['detail']}"
        lines << "    下一步：#{item['next_step']}" if item["next_step"]
      end
      installation = report.fetch("installation")
      lines << "安装：#{installation['detail']}"
      installation.fetch("extensions", []).each do |entry|
        lines << "  #{entry['ready'] ? '✓' : '✗'} #{entry['name']}：#{entry['detail']}"
        lines << "    下一步：#{entry['next_step']}" if entry["next_step"]
      end
      lines << "下一步：#{installation['next_step']}" if installation["next_step"]
      omp_entry = report.fetch("omp_entry")
      lines << "OMP 显式入口：#{omp_entry['detail']}"
      lines << "  版本：#{omp_entry['version'] || '未检测'}（最低：#{omp_entry['minimum_version']}）"
      lines << "  下一步：#{omp_entry['version_next_step']}" if omp_entry["version_next_step"]
      lines << "下一步：#{omp_entry['next_step']}" if omp_entry["next_step"]
      lines << "下一步：#{omp_entry['omp_next_step']}" if omp_entry["omp_next_step"]
      connection = report.fetch("connection")
      lines << "会话连接：#{connection['detail']}"
      lines << "项目：#{connection['project']}" if connection["project"]
      lines << "下一步：#{connection['next_step']}" if connection["next_step"]
      checker = report.fetch("checker")
      lines << "检查组件：#{checker['component']}（#{checker['status']}）"
      lines << "  #{checker['detail']}"
      lines << "  模型：#{checker['model'] || '未指定'}（来源：#{checker['source'] || '未指定'}）"
      lines << "  下一步：#{checker['next_step']}" if checker["next_step"]
      lines << "  连接配置错误：#{checker['connection_config_error']}" if checker["connection_config_error"]
      lines << "迁移状态：#{report.fetch('migration').fetch('detail')}"
      lines << report.fetch("credentials").fetch("detail")
      lines.join("\n")
    end

    def executable(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }
         .find { |path| File.executable?(path) && !File.directory?(path) }
    end

    def dependency_checks
      ruby_ready = (RUBY_VERSION.split(".").map(&:to_i) <=> [3, 2]) >= 0
      checks = [{ "name" => "Ruby", "ready" => ruby_ready, "detail" => RUBY_VERSION }]
      checks[0]["next_step"] = "安装 Ruby 3.2 或更新版本，并在 PATH 中优先使用它。" unless ruby_ready
      node_ready = false
      begin
        output, error, status = Open3.capture3("node", "-p", "process.versions.node")
        node_ready = status.success? && output.split(".").first.to_i >= 18
        detail = status.success? ? output.strip : error.strip
      rescue SystemCallError => error
        detail = error.message
      end
      checks << { "name" => "Node.js", "ready" => node_ready, "detail" => detail }
      checks.last["next_step"] = "安装 Node.js 18 或更新版本，并加入 PATH。" unless node_ready
      %w[npm bun].each do |name|
        path = executable(name)
        item = { "name" => name, "ready" => !path.nil?, "detail" => path || "PATH 中未找到" }
        unless path
          item["next_step"] = name == "bun" ? "安装 bun >= 1.3.14（独立检查组件需要），并加入 PATH。" : "安装 npm（随 Node.js 安装），并加入 PATH。"
        end
        checks << item
      end
      checks
    end

    def installation_check
      root = File.realpath(ROOT)
      unless File.file?(File.join(root, OrbitInstall::RELEASE))
        return { "kind" => "checkout", "ready" => nil, "detail" => "当前从源码目录运行，未核验全局安装。", "extensions" => [] }
      end
      runtime = Orbit.installed_runtime
      owner = OrbitInstall.read_json(File.join(runtime, OrbitInstall::MARKER))
      raise "安装记录格式不受支持" unless OrbitInstall::SUPPORTED_FORMATS.include?(owner["format"])
      entries = installation_entries(runtime: runtime, owner: owner)
      { "kind" => "installed", "ready" => entries.all? { |item| item["ready"] }, "runtime" => runtime,
        "detail" => "#{runtime}；单宿主安装只管理 CLI 与 orbit omp 显式入口。", "extensions" => entries }
    rescue StandardError => error
      { "kind" => "installed", "ready" => false, "detail" => error.message, "extensions" => [],
        "next_step" => "检查当前运行安装记录，再按 README 重新安装；doctor 不自动修改安装。" }
    end

    # The CLI wrapper is the only installed entry. A format 3 installation
    # recorded host directories; an owned leftover there means the switch has
    # not completed, and an unowned same-named entry means plain `omp`
    # passivity cannot be claimed either way.
    def installation_entries(runtime:, owner:)
      entries = []
      path, expected, kind = OrbitInstall.endpoints(runtime: runtime, bin: owner.fetch("bin_dir")).first
      matched = OrbitInstall.matching?(path, expected, kind)
      entries << { "name" => "orbit CLI", "path" => path, "ready" => matched,
                   "detail" => matched ? "入口指向当前版本" : "CLI 入口缺失或未指向当前版本" }
      entries.last["next_step"] = "检查 #{path}，用 install.sh 修复。" unless matched

      legacy_entries = []
      if (directory = owner["omp_dir"])
        legacy_entries << ["omp 全局扩展（旧）", File.join(directory, "extensions/orbit.js"), File.join(runtime, "current/plugins/omp.mjs")]
      end
      if (directory = owner["opencode_dir"])
        legacy_entries << ["opencode 插件（旧）", File.join(directory, "plugins/orbit.js"), File.join(runtime, "current/plugins/opencode.mjs")]
      end
      legacy_entries.each do |name, legacy_path, legacy_target|
        if OrbitInstall.matching?(legacy_path, legacy_target, :symlink)
          entries << { "name" => name, "path" => legacy_path, "ready" => false,
                       "detail" => "旧全局入口仍指向本安装；普通 omp 会加载 Orbit" }
          entries.last["next_step"] = "重新运行 install.sh 清理 #{legacy_path}。"
        elsif OrbitInstall.present?(legacy_path)
          entries << { "name" => name, "path" => legacy_path, "ready" => false,
                       "detail" => "存在同名但不是本安装创建的入口；普通 omp 是否加载 Orbit 未确认" }
          entries.last["next_step"] = "检查 #{legacy_path} 并自行处理；Orbit 不会删除非本安装的入口。"
        else
          entries << { "name" => name, "path" => legacy_path, "ready" => true, "detail" => "已清理或不存在" }
        end
      end
      entries
    end

    def connection_check(record)
      unless record
        return { "ready" => nil, "detail" => "未验证（未提供已有会话）",
                 "next_step" => "用 orbit omp 启动受控会话，在会话中调用 Orbit context；已有任务可运行 orbit doctor TASK。" }
      end
      result = record.slice("provider", "socket", "thread_id").merge("ready" => false)
      raise ArgumentError, "缺少已有会话 ID" if record["thread_id"].to_s.empty?
      connection = Connection.open(record)
      connection.connect!
      state = connection.state
      project = state.fetch("cwd")
      raise Connection::Error, "原生接口未返回项目目录" if project.to_s.empty?
      result.merge!("ready" => true, "project" => project, "status" => state["status"], "detail" => "已通过原生接口读回已有会话")
      begin
        result["configured_model"] = connection.configured_model
      rescue StandardError => error
        result["model_error"] = error.message
      end
      result
    rescue StandardError => error
      result.merge!("ready" => false, "detail" => error.message,
                    "next_step" => "确认原会话仍在对应的 Orbit 原生入口运行；在会话中调用 context 核对连接，旧任务不自动恢复。")
    ensure
      begin
        connection&.close
      rescue StandardError => error
        result.merge!("ready" => false, "detail" => "诊断连接关闭失败：#{error.message}",
                      "next_step" => "检查诊断桥接进程是否仍运行，再重试 doctor。")
      end
    end

  end
end
