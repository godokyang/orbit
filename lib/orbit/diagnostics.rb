# frozen_string_literal: true

require "open3"
require_relative "version"
require_relative "codex_connection"
require_relative "plugin_connection"
require_relative "check_runner"
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
        "connection" => connection,
        "review_model" => model_check(connection),
        "credentials" => { "verified" => false, "detail" => "未请求模型；登录、模型可用性和额度未验证。" }
      }
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
      connection = report.fetch("connection")
      lines << "会话连接：#{connection['detail']}"
      lines << "项目：#{connection['project']}" if connection["project"]
      lines << "下一步：#{connection['next_step']}" if connection["next_step"]
      model = report.fetch("review_model")
      lines << "检查模型：#{model['model'] || '未指定'}（#{model['detail']}）"
      lines << "下一步：#{model['next_step']}" if model["next_step"]
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
      %w[npm codex].each do |name|
        path = executable(name)
        item = { "name" => name, "ready" => !path.nil?, "detail" => path || "PATH 中未找到" }
        item["next_step"] = "安装 #{name == 'codex' ? 'Codex CLI（独立检查需要）' : 'npm（随 Node.js 安装）'}，并加入 PATH。" unless path
        checks << item
      end
      checks << package_check(node_ready)
      checks
    end

    def package_check(node_ready)
      item = { "name" => "运行包依赖", "ready" => false }
      if node_ready
        script = "require('ws'); require('@modelcontextprotocol/sdk/server/index.js'); " \
                 "require('@modelcontextprotocol/sdk/server/stdio.js'); require('@modelcontextprotocol/sdk/types.js')"
        _output, error, status = Open3.capture3("node", "-e", script, chdir: ROOT)
        item.merge!("ready" => status.success?, "detail" => status.success? ? "ws 和 MCP SDK 可加载" : error.lines.first.to_s.strip)
      else
        item["detail"] = "Node.js 不可用，尚未检查 ws 和 MCP SDK"
      end
      item["next_step"] = "先修复 Node.js，再重新运行 install.sh；源码目录开发可运行 npm ci。" unless item["ready"]
      item
    rescue SystemCallError => error
      item.merge("detail" => error.message, "next_step" => "重新运行 install.sh；源码目录开发可运行 npm ci。")
    end

    def installation_check
      root = File.realpath(ROOT)
      unless File.file?(File.join(root, OrbitInstall::RELEASE))
        return { "kind" => "checkout", "ready" => nil, "detail" => "当前从源码目录运行，未核验全局安装或扩展。", "extensions" => [] }
      end
      runtime = Orbit.installed_runtime
      owner = OrbitInstall.read_json(File.join(runtime, OrbitInstall::MARKER))
      raise "安装记录格式不受支持" unless owner["format"] == OrbitInstall::FORMAT
      entries = OrbitInstall.endpoints(runtime: runtime, bin: owner.fetch("bin_dir"), opencode: owner["opencode_dir"], omp: owner["omp_dir"])
      extensions = entries.select { |_, _, kind| kind == :symlink }.map do |path, target, kind|
        matched = OrbitInstall.matching?(path, target, kind) && File.file?(path)
        name = File.basename(target, ".mjs")
        item = { "name" => name, "path" => path, "ready" => matched,
                 "detail" => matched ? "入口指向当前版本；是否已加载需验证会话连接" : "扩展入口缺失或未指向当前版本" }
        item["next_step"] = "检查 #{path}，用 install.sh 修复后重新启动 #{name}。" unless matched
        item
      end
      { "kind" => "installed", "ready" => extensions.all? { |item| item["ready"] }, "runtime" => runtime,
        "detail" => "#{runtime}；只核验本安装登记的扩展，skill 由 npx skills 管理。", "extensions" => extensions }
    rescue StandardError => error
      { "kind" => "installed", "ready" => false, "detail" => error.message, "extensions" => [],
        "next_step" => "检查当前运行安装记录，再按 README 重新安装；doctor 不自动修改安装。" }
    end

    def connection_check(record)
      unless record
        return { "ready" => nil, "detail" => "未验证（未提供已有会话）",
                 "next_step" => "用 orbit codex、opencode 或 omp 启动，在会话中调用 Orbit context；已有任务可运行 orbit doctor TASK。" }
      end
      result = record.slice("provider", "socket", "thread_id").merge("ready" => false)
      raise ArgumentError, "缺少已有会话 ID" if record["thread_id"].to_s.empty?
      connection = Connection.open(record)
      connection.connect!
      state = connection.state
      project = state.fetch("cwd")
      raise Connection::Error, "原生接口未返回项目目录" if project.to_s.empty?
      result.merge!("ready" => true, "project" => project, "status" => state["status"], "detail" => "已通过原生接口读回已有会话")
      if record.fetch("provider", "codex") == "codex"
        begin
          result["configured_model"] = connection.configured_model
        rescue StandardError => error
          result["model_error"] = error.message
        end
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

    def model_check(connection)
      model = ENV["ORBIT_REVIEW_MODEL"]
      source = "ORBIT_REVIEW_MODEL"
      if model.to_s.empty?
        model = connection["configured_model"]
        source = "当前 Codex 会话配置"
      end
      if model.to_s.empty?
        model = CheckRunner.configured_model
        source = "Codex 顶层配置；profile 请显式指定 ORBIT_REVIEW_MODEL"
      end
      item = { "model" => model, "detail" => source }
      item["next_step"] = "设置 ORBIT_REVIEW_MODEL 为可用的 Codex 检查模型。" if model.to_s.empty?
      item["connection_config_error"] = connection["model_error"] if connection["model_error"]
      item
    rescue StandardError => error
      { "model" => nil, "detail" => "读取 Codex 配置失败：#{error.message}", "next_step" => "修复 Codex 配置或显式设置 ORBIT_REVIEW_MODEL。" }
    end
  end
end
