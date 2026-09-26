# frozen_string_literal: true

# Deterministic tests for the bounded pre-start entry classifier, its
# calibration gate and the `orbit entry` CLI bridge. No TypeSafe call is made
# and no real key is read; the provider is a spy and the native session is a
# local UNIX socket fixture. Run:
#   ruby --disable-gems tests/prestart_test.rb

require "json"
require "socket"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require "rbconfig"

require_relative "../lib/orbit/cli"

module PrestartTest
  ENTRY = File.expand_path("../scripts/orbit", __dir__)
  module_function

  def assert(value, message)
    raise message unless value
  end

  def with_project
    Dir.mktmpdir("orbit-entry") do |root|
      system("git", "-C", root, "init", "-q", out: File::NULL, err: File::NULL)
      home = File.join(root, "home")
      FileUtils.mkdir_p(home)
      yield root, home
    end
  end

  # A provider spy recording requests; answers are scripted per call.
  class ProviderSpy
    attr_reader :requests

    def initialize(results)
      @results = results.dup
      @requests = []
    end

    def judge(request)
      @requests << request
      @results.shift || Orbit::JudgmentResult.unavailable(provider: "typesafe", reason: "no scripted result")
    end
  end

  def classifier(project, spy_results = [])
    spy = ProviderSpy.new(spy_results)
    [Orbit::PrestartClassifier.new(project_root: project, provider_for: ->(_model) { spy }), spy]
  end

  def calibrated(project, thresholds = { "execution_authorized" => 0.8, "independent_check_benefit" => 0.7 })
    FileUtils.mkdir_p(File.join(project, ".orbit"))
    File.write(File.join(project, ".orbit", "jev-entry.json"), JSON.generate(
      "model" => "jev-1.13.0", "thresholds" => thresholds, "calibrated_samples" => 3
    ))
  end

  def answered(authorized, benefit)
    Orbit::JudgmentResult.answered(
      answers: {
        "execution_authorized" => { "probability_true" => authorized },
        "independent_check_benefit" => { "probability_true" => benefit }
      }, provider: "typesafe", actual_model: "jev-1.13.0"
    )
  end

  def check_classification_boundaries
    klass = Orbit::PrestartClassifier.new(project_root: Dir.pwd)
    assert(klass.classify("请使用 orbit 受控执行：实现 key-setup 命令并验证") == "explicit_orbit",
           "an explicit Chinese orbit request takes the direct path")
    assert(klass.classify("用orbit 完成 docs/plan/任务.md") == "explicit_orbit",
           "the user's direct 'use Orbit to complete' request starts without requiring a Jev credential")
    assert(klass.classify("怎么用 Orbit 完成这项工作？") == "discussion",
           "asking how to use Orbit is not authorization to run a task")
    assert(klass.classify("Start an orbit task for the migration and verify it") == "explicit_orbit",
           "an explicit English orbit request takes the direct path")
    assert(klass.classify("fix the orbit bug in parser.rb and add tests").nil?,
           "an orbit mention inside other work stays uncertain")
    assert(klass.classify("什么是分布式锁？只是问问") == "discussion", "a read-only question never starts")
    assert(klass.classify("解释一下这段代码的结构，不要修改") == "discussion", "an explicit read-only request never starts")
    assert(klass.classify("解释一下这段代码的结构然后修复它").nil?,
           "a discussion lead with real work stays uncertain")
    assert(klass.classify("请修复解析器，但不要修改其他文件").nil?,
           "a restriction on collateral edits cannot turn an execution request into discussion")
    assert(klass.classify("can you fix the parser?").nil?, "a polite request phrased as a question stays uncertain")
    assert(klass.classify("   ") == "discussion", "an empty message is not work")
  end

  def check_uncertain_uses_built_in_calibration
    with_project do |project, _home|
      # No .orbit/jev-entry.json: the built-in default applies (Root-directed
      # calibration from three labeled real requests; conservative).
      advisor, spy = classifier(project, [answered(0.95, 0.9)])
      decision = advisor.decide("implement the login page and verify it end to end")
      assert(decision["decision"] == "start", "a clear positive auto-starts under the built-in calibration")
      assert(spy.requests.length == 1 && spy.requests.first.model == Orbit::EntryCalibration::BUILT_IN.fetch("model"),
             "the built-in default pins the calibrated versioned model")

      advisor, spy = classifier(project, [answered(0.79, 0.9)])
      assert(advisor.decide("implement the login page")["decision"] == "root_decides",
             "below the 0.80 authorization threshold stays with Root")
      advisor, spy = classifier(project, [answered(0.9, 0.69)])
      assert(advisor.decide("implement the login page")["decision"] == "root_decides",
             "below the 0.70 benefit threshold stays with Root")

      advisor, spy = classifier(project)
      decision = advisor.decide("implement the login page")
      assert(decision["decision"] == "root_decides" && decision["reason"].include?("unavailable") &&
             spy.requests.length == 1, "an unavailable judgment fails closed to Root")

      decision = advisor.decide("请使用 orbit 受控执行：实现 X")
      assert(decision["decision"] == "start", "the explicit path still starts without any judgment")
    end
  end

  def check_invalid_calibration_fails_closed
    with_project do |project, _home|
      FileUtils.mkdir_p(File.join(project, ".orbit"))
      file = File.join(project, ".orbit", "jev-entry.json")
      {
        "an alias model" => { "model" => "jev-latest", "thresholds" => { "execution_authorized" => 0.8, "independent_check_benefit" => 0.7 }, "calibrated_samples" => 5 },
        "zero thresholds" => { "model" => "jev-1.13.0", "thresholds" => { "execution_authorized" => 0.0, "independent_check_benefit" => 0.7 }, "calibrated_samples" => 5 },
        "missing threshold question" => { "model" => "jev-1.13.0", "thresholds" => { "execution_authorized" => 0.8 }, "calibrated_samples" => 5 },
        "no sample count" => { "model" => "jev-1.13.0", "thresholds" => { "execution_authorized" => 0.8, "independent_check_benefit" => 0.7 } }
      }.each do |label, document|
        File.write(file, JSON.generate(document))
        advisor, spy = classifier(project)
        decision = advisor.decide("implement the login page and verify it end to end")
        assert(decision["decision"] == "root_decides" && spy.requests.empty?,
               "invalid calibration (#{label}) fails closed without an external call")
      end
      File.write(file, "{not json")
      advisor, spy = classifier(project)
      assert(advisor.decide("implement X")["decision"] == "root_decides" && spy.requests.empty?,
             "an unreadable calibration file fails closed")
    end
  end

  def check_calibrated_judgment_thresholds
    with_project do |project, _home|
      calibrated(project)
      advisor, spy = classifier(project, [answered(0.9, 0.8)])
      decision = advisor.decide("implement the login page and verify it end to end")
      assert(decision["decision"] == "start", "a calibrated judgment clearing both thresholds starts")
      assert(spy.requests.length == 1 && spy.requests.first.model == "jev-1.13.0",
             "the judgment uses the pinned versioned model")
      trace = decision.fetch("trace")
      assert(trace["question_set_version"] == "orbit-entry-1" && trace["actual_model"] == "jev-1.13.0" &&
             trace.dig("probabilities", "execution_authorized", "probability_true") == 0.9,
             "the trace records the question set, actual model and probabilities")

      advisor, spy = classifier(project, [answered(0.95, 0.4)])
      decision = advisor.decide("implement the login page and verify it end to end")
      assert(decision["decision"] == "root_decides" && decision["reason"].include?("did not clear"),
             "failing one threshold does not start")

      advisor, spy = classifier(project)
      decision = advisor.decide("implement the login page and verify it end to end")
      assert(decision["decision"] == "root_decides" && decision["reason"].include?("unavailable") &&
             spy.requests.length == 1, "an unavailable judgment fails closed to Root")
    end
  end

  def check_disabled_project_never_calls_out
    with_project do |project, _home|
      calibrated(project)
      FileUtils.mkdir_p(File.join(project, ".orbit"))
      File.write(File.join(project, ".orbit", "jev-disabled"), "")
      advisor = Orbit::PrestartClassifier.new(project_root: project, provider_for: ->(_model) { nil })
      decision = advisor.decide("implement the login page and verify it end to end")
      assert(decision["decision"] == "root_decides" && decision["reason"].include?("unavailable"),
             "a project that disables outbound never starts from a judgment")
    end
  end

  # A fake native session socket serving the same protocol as the extension
  # host bridge: state, then messages with the two fixture user entries.
  class FakeSession
    attr_reader :requests

    def initialize(project, socket)
      @project = File.realpath(project)
      @server = UNIXServer.new(socket)
      @requests = []
      @thread = Thread.new do
        loop do
          peer = @server.accept
          request = JSON.parse(peer.gets)
          @requests << request
          peer.puts(JSON.generate("result" => handle(request)))
          peer.close
        end
      rescue IOError
        nil
      end
    end

    def handle(request)
      case request["method"]
      when "state" then { "cwd" => @project, "status" => "idle" }
      when "model" then "zhipu/glm-5.2"
      when "messages"
        [{ "id" => "m1", "item_id" => "m1", "text" => "请使用 orbit 受控执行：实现 key-setup 命令并验证", "internal" => false },
         { "id" => "m2", "item_id" => "m2", "text" => "什么是分布式锁？只是问问", "internal" => false }]
      else {}
      end
    end

    def close
      @thread.kill
      @server.close unless @server.closed?
    end
  end

  def cli(*args, cwd:, home:, success: true)
    out, err, status = Open3.capture3({ "XDG_CONFIG_HOME" => home, "XDG_CACHE_HOME" => home, "TYPESAFE_API_KEY" => "" },
                                      RbConfig.ruby, "--disable-gems", ENTRY, *args, chdir: cwd)
    assert(status.success? == success, "#{args.inspect}\n#{out}\n#{err}")
    out.strip.empty? ? nil : JSON.parse(out)
  end

  def check_entry_cli_idempotence_and_trace
    with_project do |project, home|
      socket = File.join(project, "host.sock")
      session = FakeSession.new(project, socket)
      begin
        first = cli("entry", "--project", project, "--thread", "t1", "--socket", socket, "--message-id", "m1", cwd: project, home: home)
        assert(first["decision"] == "start" && first["classification"] == "explicit_orbit" &&
               File.file?(first.fetch("entry_file")), "an explicit message decides start and writes the entry file")
        assert(File.file?(File.join(project, ".orbit", "prestart-decisions.json")), "the decision is persisted")

        second = cli("entry", "--project", project, "--thread", "t1", "--socket", socket, "--message-id", "m1", cwd: project, home: home)
        assert(second["decision"] == "duplicate" && second["previous_decision"] == "start",
               "the same native message id is never classified twice")

        discussion = cli("entry", "--project", project, "--thread", "t1", "--socket", socket, "--message-id", "m2",
                         cwd: project, home: home)
        assert(discussion["decision"] == "no_start", "a discussion message does not start")

        missing = cli("entry", "--project", project, "--thread", "t1", "--socket", socket, "--message-id", "gone",
                      cwd: project, home: home, success: false)
        assert(missing.nil? || true, "an unknown message id exits non-zero")
      ensure
        session.close
      end
    end
  end

  # `start --entry-file` embeds the entry decision trace into the created task
  # record through the real CLI; the spawned runtime is stopped afterwards.
  def check_start_embeds_entry_trace
    with_project do |project, home|
      socket = File.join(project, "host.sock")
      session = FakeSession.new(project, socket)
      begin
        document = { "schema_version" => 1, "message_id" => "m1", "decision" => "start",
                     "classification" => "explicit_orbit", "reason" => "explicit" }
        entry_file = File.join(project, "entry.json")
        File.write(entry_file, JSON.generate(document))
        result = cli("start", "--project", project, "--thread", "t1", "--socket", socket, "--message-id", "m1",
                     "--entry-file", entry_file, cwd: project, home: home)
        state = JSON.parse(File.read(File.join(result.fetch("task_directory"), "state.json")))
        assert(state["entry"] == document, "the task record carries the entry decision verbatim")
        assert(state.dig("instruction_source", "id") == "m1", "the task is bound to the native message id")
        assert(result.key?("pid"), "the runtime process is launched as usual")

        ledger = Orbit::PrestartLedger.new(File.realpath(project))
        assert(ledger.task_for("m1") == result.fetch("task_directory"),
               "a task created for a message makes later entry calls duplicates")

        # The spawned runtime is real; stop its process group and wait for it
        # so the test leaves no stray task process behind.
        pid = result.fetch("pid")
        Process.kill("TERM", -pid) if Process.kill(0, -pid) rescue nil
        30.times { break unless Process.kill(0, pid) rescue break; sleep 0.1 }
      ensure
        session.close
      end
    end
  end

  def run
    check_classification_boundaries
    check_uncertain_uses_built_in_calibration
    check_invalid_calibration_fails_closed
    check_calibrated_judgment_thresholds
    check_disabled_project_never_calls_out
    check_entry_cli_idempotence_and_trace
    check_start_embeds_entry_trace
    puts "PRESTART_TEST_PASS (deterministic, local fixture only)"
  end
end

PrestartTest.run
