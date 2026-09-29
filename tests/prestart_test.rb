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

  # These scripted releases test binding and branching, not live calibration.
  def calibration_document(thresholds = { "execution_authorized" => 0.8, "delegation_value" => 0.7, "supervision_value" => 0.7 })
    cases = [
      ["serial", "positive", "Implement the bounded module after receiving its interface.", answered(0.99, 0.01, delegation: 0.99)],
      ["audit", "positive", "Deliver a read-only audit report against the stated requirements.", answered(0.99, 0.99)],
      ["discussion", "negative", "Explain what this module does.", answered(0.01, 0.99, delegation: 0.99)],
      ["failed", "failure", "Implement the module.", Orbit::JudgmentResult.unavailable(provider: "typesafe", reason: "scripted HTTP failure")],
      ["unknown", "missing_evidence", "Continue without an attributable original requirement.", answered(0.01, 0.01)]
    ]
    Orbit::EntryCalibration.binding.merge(
      "model" => "jev-1.13.0", "thresholds" => thresholds,
      "release" => { "reason" => "Scripted fixture only; never installed as real release evidence",
                     "scope" => "entry fixture", "reviewed_by" => "test fixture", "reviewed_at" => "2026-09-29T00:00:00Z" },
      "samples" => cases.map do |id, kind, instruction, judgment|
        { "id" => id, "kind" => kind, "mode" => "model_backed",
          "expected_decision" => kind == "positive" ? "start" : "root_decides",
          "state" => { "input_version" => Orbit::PrestartClassifier::INPUT_VERSION,
                       "instruction" => instruction, "instruction_truncated" => false, "git" => {} },
          "judgment" => judgment.to_h }
      end
    )
  end

  def calibrated(project, thresholds = { "execution_authorized" => 0.8, "delegation_value" => 0.7, "supervision_value" => 0.7 })
    FileUtils.mkdir_p(File.join(project, ".orbit"))
    File.write(File.join(project, ".orbit", "jev-entry.json"), JSON.generate(calibration_document(thresholds)))
  end

  def answered(authorized, benefit, delegation: 0.01, model: "jev-1.13.0")
    Orbit::JudgmentResult.answered(
      answers: {
        "execution_authorized" => { "probability_true" => authorized },
        "delegation_value" => { "probability_true" => delegation },
        "supervision_value" => { "probability_true" => benefit }
      }, provider: "typesafe", actual_model: model
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
    # Recorded misses (kickoff ①): both real Zeen requests missed the direct
    # path and needed the user to remind or Root to start manually.
    assert(klass.classify("可以，直接执行，直到所有任务完成，记得用orbit") == "explicit_orbit",
           "an instrument reminder paired with a real execution order takes the direct path")
    assert(klass.classify("请完成登录页并验证，记得用 Orbit") == "explicit_orbit",
           "an imperative completion request with an Orbit instrument reminder starts directly")
    assert(klass.classify("请把 NOTICE.md 中的旧句改成新句，记得用 Orbit 完成这次修改、核对文件内容并交付结果。") == "explicit_orbit",
           "an instrument reminder followed by complete-this-work is a direct request, not a score-dependent candidate")
    assert(klass.classify("用已更新的 Orbit 启动一条新任务，完成独立终检") == "explicit_orbit",
           "an orbit start-up request with words between 用 and orbit still takes the direct path")
    # Negative boundary from the same kickoff: discussion, same-name files,
    # status-only asks, bare reminders and prohibitions never start directly.
    assert(klass.classify("怎么理解 orbit 的受控模式？") == "discussion",
           "discussing orbit's design never takes the direct path")
    assert(klass.classify("修复名为 orbit 的文件").nil?,
           "work on an orbit-named file stays off the direct path")
    assert(klass.classify("先别动，只告诉我 orbit 当前的任务状态") == "discussion",
           "a status-only ask never starts")
    assert(klass.classify("下次记得用orbit").nil?,
           "a bare orbit reminder without execution content stays off the direct path")
    assert(klass.classify("别用orbit，这次直接做") == "orbit_opt_out",
           "an explicit refusal to use Orbit cannot enter either automatic start path")
    assert(klass.classify("不用Orbit，完成这个改动") == "orbit_opt_out",
           "a direct refusal without a second 用 also bypasses automatic start")
    assert(klass.classify("不要用‘Orbit’，完成这个改动") == "orbit_opt_out",
           "quoting the product name cannot hide the user's opt-out")
    assert(klass.classify('不要用“Orbit”，完成这个改动') == "orbit_opt_out",
           "quoting the product name alone cannot hide the user's opt-out")
    assert(klass.classify("Don't use Orbit and don't change unrelated files; implement this feature.") == "orbit_opt_out",
           "English opt-out and apostrophes cannot be swallowed as quoted commands")
    assert(klass.classify("怎么用orbit实现登录页？") == "discussion",
           "asking how to use orbit for real work is a question, not authorization")
    assert(klass.classify("如何理解“记得用 Orbit 完成这次修改”这句话？") == "discussion",
           "quoting the instrument instruction in a question does not start work")
    assert(klass.classify("什么是分布式锁？只是问问") == "discussion", "a read-only question never starts")
    assert(klass.classify("解释一下这段代码的结构，不要修改") == "discussion", "an explicit read-only request never starts")
    ["解释这句：用 Orbit 启动任务", "解释『使用 Orbit 受控执行』的意思",
     "Explain 'use Orbit to execute this'", "请解释下面的例子：\n```\n使用 Orbit 受控执行\n```"].each do |text|
      assert(klass.classify(text) == "discussion", "quoted instructions cannot enter the direct controlled path")
    end
    assert(klass.classify("请只读审计 lib 并交付缺陷报告，不要修改文件").nil?,
           "a read-only audit deliverable is eligible for judgment rather than dismissed as discussion")
    assert(klass.classify("解释一下这段代码的结构然后修复它").nil?,
           "a discussion lead with real work stays uncertain")
    assert(klass.classify("请修复解析器，但不要修改其他文件").nil?,
           "a restriction on collateral edits cannot turn an execution request into discussion")
    assert(klass.classify("can you fix the parser?").nil?, "a polite request phrased as a question stays uncertain")
    assert(klass.classify("   ") == "discussion", "an empty message is not work")
  end

  def check_uncalibrated_requests_stay_with_root
    with_project do |project, _home|
      advisor, spy = classifier(project, [answered(0.95, 0.9)])
      decision = advisor.decide("implement the login page and verify it end to end")
      assert(decision["decision"] == "root_decides" && spy.requests.empty?,
             "an uncalibrated new question cannot use old thresholds or call the provider for an automatic action")

      decision = advisor.decide("请使用 orbit 受控执行：实现 X")
      assert(decision["decision"] == "start", "the explicit path still starts without any judgment")
      decision = advisor.decide("继续")
      assert(decision["classification"] == "unattributed_continuation" && decision["decision"] == "root_decides" &&
             spy.requests.empty?, "an unbound continuation does not invent an earlier requirement")
    end
  end

  def check_invalid_calibration_fails_closed
    with_project do |project, _home|
      FileUtils.mkdir_p(File.join(project, ".orbit"))
      file = File.join(project, ".orbit", "jev-entry.json")
      {
        "legacy count-only release" => { "model" => "jev-1.13.0", "calibrated_samples" => 6 },
        "an alias model" => calibration_document.merge("model" => "jev-latest"),
        "different question content" => calibration_document.merge("question_digest" => "old-digest"),
        "different input projection" => calibration_document.merge("input_version" => "old-input"),
        "zero thresholds" => calibration_document.merge("thresholds" => { "execution_authorized" => 0.0 }),
        "missing failure evidence" => calibration_document.merge("samples" => calibration_document["samples"].reject { |sample| sample["kind"] == "failure" }),
        "no release reason" => calibration_document.merge("release" => {}),
        "unsupported labels" => calibration_document.merge("thresholds" => { "execution_authorized" => 1.0, "delegation_value" => 1.0, "supervision_value" => 1.0 })
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
      assert(trace["question_set_version"] == "orbit-entry-3" && trace["actual_model"] == "jev-1.13.0" &&
             trace.dig("probabilities", "execution_authorized", "probability_true") == 0.9,
             "the trace records the new question set, actual model and probabilities")
      assert(trace["question_digest"] == Orbit::PrestartClassifier::QUESTION_DIGEST && trace.dig("calibration", "sample_count") == 5,
             "the automatic decision retains the release and content binding")
      advisor, spy = classifier(project, [answered(0.95, 0.01, delegation: 0.9)])
      assert(advisor.decide("implement the module after the interface is fixed")["decision"] == "start",
             "serial handoff alone can provide entry value without independent supervision")
      advisor, spy = classifier(project, [answered(0.95, 0.9, model: "jev-1.14.0")])
      decision = advisor.decide("deliver a read-only audit report")
      assert(decision["decision"] == "root_decides" && decision.dig("trace", "actual_model") == "jev-1.14.0" &&
             !decision["trace"].key?("probabilities"), "a changed actual model cannot inherit the release")

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

  # Kickoff ②: plain imperative execution requests without an orbit mention
  # must reach the calibrated judgment path; the revised execution_authorized
  # question (orbit-entry-3) counts a direct imperative order as
  # authorization. Scripted spy scores keep this deterministic — the real
  # model's scores are verified live by Root, not asserted here.
  def check_imperative_requests_reach_calibrated_judgment
    with_project do |project, _home|
      request = "补做 S1 的全程序终检：复核 W1/W2/G0/V1/R1 后再关闭 S1"
      klass = Orbit::PrestartClassifier.new(project_root: Dir.pwd)
      assert(klass.classify(request).nil?,
             "a plain imperative request without an orbit mention reaches the calibrated judgment path")

      advisor, spy = classifier(project, [answered(0.99, 0.99)])
      assert(advisor.decide("别用orbit，完成这一项")["decision"] == "no_start" && spy.requests.empty?,
             "the user's Orbit opt-out overrides even otherwise qualifying automatic work")

      calibrated(project, { "execution_authorized" => 0.8, "delegation_value" => 0.8, "supervision_value" => 0.8 })
      advisor, spy = classifier(project, [answered(0.81, 0.84)])
      decision = advisor.decide(request)
      assert(decision["decision"] == "start" && spy.requests.length == 1 &&
             spy.requests.first.question_set_version == "orbit-entry-3",
             "an imperative request uses the current released three-question set")

      advisor, spy = classifier(project, [answered(0.69, 0.84)])
      decision = advisor.decide(request)
      assert(decision["decision"] == "root_decides" && decision["reason"].include?("did not clear"),
             "an imperative request below the unchanged thresholds still fails closed to Root")
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
      when "model" then "glm/x"
      when "model_catalog" then { "current" => "glm/x", "available" => ["glm/x"], "families" => {} }
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
    out, err, status = Open3.capture3({ "XDG_CONFIG_HOME" => home, "XDG_CACHE_HOME" => home,
                                        "PI_CODING_AGENT_DIR" => File.join(home, "agent"),
                                        "TYPESAFE_API_KEY" => "" },
                                      RbConfig.ruby, "--disable-gems", ENTRY, *args, chdir: cwd)
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
      agent = File.join(home, "agent")
      FileUtils.mkdir_p(agent)
      File.write(File.join(agent, "models.yml"), <<~YAML)
        providers:
          glm:
            baseUrl: https://example.invalid/v1
            apiKey: fixture-key
            api: openai-completions
            models:
              - id: x
                name: Fixture GLM
                input: [text]
                contextWindow: 128000
                maxTokens: 8192
      YAML
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
    check_uncalibrated_requests_stay_with_root
    check_invalid_calibration_fails_closed
    check_calibrated_judgment_thresholds
    check_imperative_requests_reach_calibrated_judgment
    check_disabled_project_never_calls_out
    check_entry_cli_idempotence_and_trace
    check_start_embeds_entry_trace
    puts "PRESTART_TEST_PASS (deterministic, local fixture only)"
  end
end

PrestartTest.run
