# frozen_string_literal: true

require "json"
require "digest"
require "time"

require_relative "jev_advisor"
require_relative "judgment"

module Orbit
  # Bounded pre-start entry classification for the latest native user message
  # of a session that has no bound Orbit task (ADR-008 2026-09-26 supplement;
  # contracts/task-runtime.md「角色与主动调用」).
  #
  # The classifier answers one question per native message id — should this
  # request enter the controlled start path now? — and it never creates a
  # task, dispatches members or bypasses the existing `start` preflight:
  # `decision: "start"` only tells the caller to use the normal start path.
  # Explicit requests for Orbit-controlled execution take the direct path;
  # clear discussion or read-only questions never start; everything else is a
  # bounded judgment question that may auto-start ONLY under a calibrated
  # entry configuration built from real request samples. Without calibration,
  # on a provider failure, missing credentials or a project outbound disable,
  # the uncertain path fails closed to an explicit Root decision with one
  # short prompt.
  class PrestartClassifier
    SCHEMA_VERSION = 2
    # Deterministic classification rules; bump when wording or patterns move.
    RULE_VERSION = "orbit-entry-rules-3"
    QUESTION_SET_VERSION = "orbit-entry-3"
    INPUT_VERSION = "orbit-entry-input-2"
    DECISION_VERSION = "orbit-entry-decision-1"
    CALIBRATION_RELATIVE_PATH = ".orbit/jev-entry.json"
    PROMPT_BUDGET = 8000
    EXCERPT_LIMIT = 300

    # Entry judgment questions (binary). Wording follows the contract; thresholds
    # come only from a calibrated configuration and are never invented here.
    # Entry value has two independent paths: bounded handoff OR supervision.
    # No model speed, duration or presumed price appears in these questions.
    ENTRY_QUESTIONS = {
      "execution_authorized" => {
        "instruction" => "Does the user's current message ask the agent to carry out concrete work or deliver a verifiable result now? Direct commands and polite action requests such as 'can you fix this' authorize the requested work without permission words. A requested read-only audit with a report is work. Discussion, hypothetical options, quoted commands, product mentions and code examples do not authorize their contents. A bare 'continue' without an attributable earlier requirement is insufficient; do not infer a goal from Git changes.",
        "true_criterion" => "The current user request authorizes concrete work or a verifiable deliverable now",
        "false_criterion" => "The message only discusses or quotes work, or the requested work cannot be attributed to an authorized requirement"
      },
      "delegation_value" => {
        "instruction" => "Does this request contain substantive work with a bounded result and handoff that a suitable execution member could perform instead of part of Root's work? Serial handoff can qualify; Root need not continue another task in parallel. Consider necessary context, dependencies, integration and verification. Do not infer member capability from its name, require every model to have local success samples, predict elapsed time or assume token or cash savings. Candidate availability, fit and real route resources are evaluated separately when selecting a member.",
        "true_criterion" => "Substantive bounded work could replace part of Root's execution through a practical handoff",
        "false_criterion" => "Work is trivial, overlapping, lacks a usable handoff or cannot yet satisfy its dependencies"
      },
      "supervision_value" => {
        "instruction" => "Would persistent requirements, scope control and independent verification provide material value for this requested deliverable by detecting omissions, unsupported claims, drift, boundary violations or forgotten constraints? A single execution surface or a read-only audit report can qualify. Conceptual discussion and low-risk reversible edits with clear program verification usually do not. Do not judge by model speed, elapsed time or the need for parallel work.",
        "true_criterion" => "The deliverable has substantive verification or scope risks that controlled supervision could help address",
        "false_criterion" => "There is no requested deliverable, or supervision adds little value over direct verifiable work"
      }
    }.freeze
    QUESTION_DIGEST = Digest::SHA256.hexdigest(JSON.generate(ENTRY_QUESTIONS)).freeze

    # High-precision markers only: a false "explicit" starts a task nobody
    # asked for, so the word orbit alone is never enough and neither is an
    # orbit mention inside other work ("fix the orbit bug in parser.rb").
    # A bounded run of non-punctuation between 用/使用 and orbit admits real
    # requests like「用已更新的 Orbit 启动…」(kickoff ①) without letting a
    # filename ("用orbit.rb 导出") through — the verb must still directly
    # follow orbit.
    EXPLICIT_PATTERNS = [
      /orbit[ \t]*受控/i,
      /\borbit[- ]controlled\b/i,
      /用[ \t]*[^\p{P}\n]{0,10}?orbit[ \t]*(?:来)?[ \t]*(?:启动|开始|创建|开|建|跑)/i,
      /使用[ \t]*[^\p{P}\n]{0,10}?orbit[ \t]*(?:来)?[ \t]*(?:启动|开始|创建|开|建|跑|受控|控制|执行)/i,
      /^(?:请|麻烦|帮我)?[ \t]*(?:用|使用)[ \t]*orbit[ \t]*(?:来[ \t]*)?完成(?!了?[吗么])/i,
      /(?:\A|[，,；;\n])[ \t]*(?:记得|请)[ \t]*(?:用|使用)[ \t]*orbit[ \t]*(?:来[ \t]*)?完成(?!了?[吗么])/i,
      /交给[ \t]*orbit/i,
      /orbit[ \t]*(?:启动|创建|开)[ \t]*一[\p{Han}]{0,8}?任务/i,
      /\b(start|create|open|begin)[ \t]+an?[ \t]+orbit[ \t]+task\b/i,
      /\buse[ \t]+orbit[ \t]+to[ \t]+(start|run|execute|control)\b/i,
      /\brun[ \t]+this[ \t]+([a-z]+[ \t]+)?under[ \t]+orbit\b/i
    ].freeze

    # Orbit named as the instrument at a clause boundary —「记得用orbit」,
    # 「……，用orbit」— counts as explicit ONLY when the same message carries
    # real execution content (kickoff ①: 「可以，直接执行，直到所有任务完成，
    # 记得用orbit」 scored 0.94/0.74 and never reached the direct path). A
    # bare reminder ("下次记得用orbit"), a question about using orbit or a
    # filename never does: the boundary lookahead excludes "." and "," and
    # the lookbehinds keep 怎么/如何/怎样 questions out.
    INSTRUMENT_PATTERNS = [
      /(?<!怎么)(?<!如何)(?<!怎样)(?:用|使用)[ \t]*[^\p{P}\n]{0,10}?orbit(?=[ \t\n]*(?:[，。！？；：、?!;]|$))/i
    ].freeze

    # A message that forbids Orbit use is a user opt-out: do not send it
    # through the automatic gate even if the requested work would qualify.
    PROHIBITED_ORBIT_USE = Regexp.union(
      /(?:(?:不要|别|无需|不再|别再)[ \t]*(?:再|来)?[ \t]*(?:用|使用)|不用)[ \t]*[^\p{P}\n]{0,10}?orbit(?![A-Za-z0-9_.-])/i,
      /\b(?:don['’]t|do[ \t]+not|never)[ \t]+(?:use|run)[ \t]+orbit(?![A-Za-z0-9_.-])/i
    ).freeze

    # Execution verbs that turn a leading "explain …" into real work.
    EXECUTION_MARKERS = [
      /修复|实现|修改|创建|添加|删除|重构|部署|完成|交付|写[一个个]|跑[一一]|执行|审计|复核|审查|核验/,
      /\b(implement|fix|modify|create|add|delete|remove|refactor|deploy|write|build|migrate|audit|review|verify)\b/i
    ].freeze

    # A clearly-discussion message asks an interrogative question or asks for
    # read-only treatment. A question mark alone is NOT sufficient, and a
    # polite request phrased as a question is left uncertain, not discussion.
    DISCUSSION_LEADS = [
      /^(?:please[ \t]+)?(what|why|how|when|who|where|which|explain|clarify|describe)\b/i,
      /^(什么|为什么|为何|怎么(?:理解|用)|怎样(?:理解|用)|如何(?:理解|用)|哪个|哪些|是否|是不是|有没有)/,
      /^(?:请|麻烦)?[ \t]*(解释|说明|介绍|帮我理解)/
    ].freeze
    READ_ONLY_MARKERS = [
      /(不要|别|无需|不用|不需要)[^。！？\n]{0,12}(修改|改动|改变|执行|运行|写入|创建|动)/,
      /\b(just|only)[ \t]+(answer|explain|describe|summarize|tell me)\b/i,
      /\b(read[ \t-]?only|don'?t change anything)\b/i,
      /(仅供参考|只是问问|只是想(了解|知道|问一下))/
    ].freeze
    READ_ONLY_REGEX = Regexp.union(*READ_ONLY_MARKERS)
    CONTINUATION_ONLY = /\A(?:请)?\s*(?:继续|接着|继续吧|continue|resume|go on)\s*[。.!！]?\z/i.freeze

    class Error < StandardError; end

    attr_reader :project_root

    # `provider_for` (test seam) receives the calibration model id and returns
    # an object answering #judge(JudgmentRequest) — normally built from the
    # project-gated JevAdvisor credentials.
    def initialize(project_root:, provider_for: nil, calibration_loader: nil)
      @project_root = project_root
      @provider_for = provider_for
      @calibration_loader = calibration_loader
    end

    # Deterministic first pass: "explicit_orbit" enters the controlled start
    # path directly; "discussion" never starts; nil means uncertain.
    def classify(text)
      # Only the user's surrounding instruction is eligible for the direct
      # rule path. The full original remains in the semantic input and ledger.
      prompt = intent_text(text)
      return "discussion" if prompt.strip.empty?
      return "orbit_opt_out" if PROHIBITED_ORBIT_USE.match?(prompt)
      return "unattributed_continuation" if CONTINUATION_ONLY.match?(prompt)

      compact = prompt.gsub(/\s+/, " ").strip
      return "discussion" if discussion_lead?(compact)

      return "explicit_orbit" if explicit_request?(prompt)

      remaining = compact.gsub(READ_ONLY_REGEX, "") if READ_ONLY_REGEX.match?(compact)
      if discussion_lead?(compact)
        "discussion"
      elsif remaining && EXECUTION_MARKERS.none? { |pattern| pattern.match?(remaining) }
        "discussion"
      end
    end

    # Full decision for one native message.
    def decide(text)
      case classify(text)
      when "explicit_orbit"
        outcome("explicit_orbit", "start", "the user explicitly requested Orbit-controlled execution")
      when "orbit_opt_out"
        outcome("orbit_opt_out", "no_start", "the user explicitly requested not to use Orbit")
      when "discussion"
        outcome("discussion", "no_start", "clear discussion or read-only question")
      when "unattributed_continuation"
        outcome("unattributed_continuation", "root_decides",
                "no active task or attributable original requirement was provided; Root must resolve the continuation")
      else
        decide_uncertain(text)
      end
    end

    def excerpt(text)
      JevAdvisor.limit(text.to_s, EXCERPT_LIMIT)
    end

    private

    def decide_uncertain(text)
      calibration = load_calibration
      return outcome("uncertain", "root_decides", calibration) if calibration.is_a?(String)
      if calibration.nil?
        return outcome("uncertain", "root_decides",
                       "entry judgment thresholds are not calibrated with real request samples; Root decides explicitly")
      end

      model = calibration.fetch("model")
      provider = resolved_provider(model)
      if provider.nil?
        return outcome("uncertain", "root_decides",
                       "judgment provider unavailable: outbound disabled by the project or credentials missing")
      end

      request = JudgmentRequest.new(state: entry_state(text), questions: ENTRY_QUESTIONS,
                                    question_set_version: QUESTION_SET_VERSION, provider: "typesafe", model: model)
      result = provider.judge(request)
      if result.unavailable?
        return outcome("uncertain", "root_decides", "entry judgment unavailable: #{result.error}",
                       provider: result.provider, actual_model: result.actual_model,
                       usage: result.usage, calibration: calibration)
      end

      probabilities = result.answers.transform_values { |value| { "probability_true" => value } }
      unless result.complete_for?(request) && result.provider == request.provider && result.actual_model == model
        return outcome("uncertain", "root_decides", "entry judgment is incomplete or the actual model differs from calibration",
                       provider: result.provider, actual_model: result.actual_model,
                       usage: result.usage, calibration: calibration)
      end
      passed = EntryCalibration.passes?(result.answers, calibration.fetch("thresholds"))
      if passed
        outcome("uncertain", "start", "calibrated entry judgment supports execution and delegation or supervision",
                probabilities: probabilities, provider: result.provider, actual_model: result.actual_model,
                usage: result.usage, calibration: calibration)
      else
        outcome("uncertain", "root_decides", "calibrated entry judgment did not clear execution and either value path",
                probabilities: probabilities, provider: result.provider, actual_model: result.actual_model,
                usage: result.usage, calibration: calibration)
      end
    rescue JudgmentRequest::Error, JudgmentResult::Error => error
      outcome("uncertain", "root_decides", "entry judgment failed: #{error.message}")
    rescue StandardError => error
      outcome("uncertain", "root_decides", "entry judgment failed: #{error.class}")
    end

    def discussion_lead?(compact)
      return false unless DISCUSSION_LEADS.any? { |pattern| pattern.match?(compact) }
      # "How to use Orbit to complete X?" is still a how-to question. The
      # embedded outcome verb does not turn an interrogative into an order.
      return true if /\A(?:怎么|如何|怎样)(?:理解|用)/.match?(compact)

      EXECUTION_MARKERS.none? { |pattern| pattern.match?(compact) }
    end

    def intent_text(text)
      text.to_s.gsub(/"\s*orbit\s*"|'\s*orbit\s*'|“\s*orbit\s*”|‘\s*orbit\s*’|「\s*orbit\s*」|『\s*orbit\s*』/i, "Orbit")
          .gsub(/```.*?(?:```|\z)/m, " ")
          .gsub(/`[^`\n]*`|“[^”]*”|‘[^’]*’|「[^」]*」|『[^』]*』|"[^"\n]*"|(?<!\w)'(?:[^'\n]|(?<=\w)'(?=\w))*'(?!\w)/m, " ")
    end

    # The direct controlled path: a high-precision explicit request, or an
    # orbit-as-instrument mention that the same message pairs with real
    # execution content. A message forbidding orbit use never takes it.
    def explicit_request?(prompt)
      return false if PROHIBITED_ORBIT_USE.match?(prompt)
      return true if EXPLICIT_PATTERNS.any? { |pattern| pattern.match?(prompt) }

      INSTRUMENT_PATTERNS.any? { |pattern| pattern.match?(prompt) } &&
        EXECUTION_MARKERS.any? { |pattern| pattern.match?(prompt) }
    end

    def entry_state(text)
      {
        "input_version" => INPUT_VERSION,
        "instruction" => JevAdvisor.limit(text.to_s, PROMPT_BUDGET),
        "instruction_truncated" => text.to_s.length > PROMPT_BUDGET,
        "git" => JevAdvisor.git_changes(@project_root)
      }
    end

    def resolved_provider(model)
      return @provider_for.call(model) if @provider_for

      advisor = JevAdvisor.for_project(@project_root)
      advisor && advisor.judgment_provider(model: model)
    end

    def load_calibration
      @calibration_loader&.call || EntryCalibration.load(@project_root)
    end

    def outcome(classification, decision, reason, probabilities: nil, provider: nil,
                actual_model: nil, usage: nil, calibration: nil)
      trace = { "rule_version" => RULE_VERSION, "input_version" => INPUT_VERSION,
                "decision_version" => DECISION_VERSION }
      if provider
        trace.merge!("question_set_version" => QUESTION_SET_VERSION, "provider" => provider,
                     "actual_model" => actual_model,
                     "thresholds" => calibration.fetch("thresholds"),
                     "question_digest" => QUESTION_DIGEST, "calibration" => calibration["release"])
        trace["probabilities"] = probabilities if probabilities
        trace["usage"] = usage if usage
      end
      {
        "schema_version" => SCHEMA_VERSION, "classification" => classification, "decision" => decision,
        "reason" => reason, "trace" => trace
      }
    end
  end

  # A release belongs to this exact question/input/decision definition and
  # service-reported model, not to a sample count or a previous entry gate.
  # Real release evidence is reviewed and retained with the configuration;
  # this structural validator cannot prove that a submitted log is genuine.
  # No built-in release is supplied until the new live calibration is done.
  module EntryCalibration
    SCHEMA_VERSION = "orbit-entry-calibration-v2"
    MODEL_PATTERN = /\Ajev-\d+(\.\d+)*(-[0-9A-Za-z.\-]+)?\z/
    THRESHOLD_QUESTIONS = PrestartClassifier::ENTRY_QUESTIONS.keys.freeze
    DEFAULT_PATH = File.join(__dir__, "data", "jev-entry-calibration.json")
    MAX_BYTES = 256 * 1024
    MAX_SAMPLES = 64
    SAMPLE_KINDS = %w[positive negative failure missing_evidence].freeze

    def self.binding
      { "schema_version" => SCHEMA_VERSION,
        "rule_version" => PrestartClassifier::RULE_VERSION,
        "question_set_version" => PrestartClassifier::QUESTION_SET_VERSION,
        "question_digest" => PrestartClassifier::QUESTION_DIGEST,
        "input_version" => PrestartClassifier::INPUT_VERSION,
        "decision_version" => PrestartClassifier::DECISION_VERSION }
    end

    def self.passes?(scores, thresholds)
      scores.fetch("execution_authorized") >= thresholds.fetch("execution_authorized") &&
        (scores.fetch("delegation_value") >= thresholds.fetch("delegation_value") ||
         scores.fetch("supervision_value") >= thresholds.fetch("supervision_value"))
    end

    def self.load(project_root)
      file = File.join(project_root, PrestartClassifier::CALIBRATION_RELATIVE_PATH)
      file = DEFAULT_PATH unless File.file?(file)
      return nil unless File.file?(file)
      return "entry calibration exceeds the bounded release size" if File.size(file) > MAX_BYTES

      validate(JSON.parse(File.read(file, MAX_BYTES + 1)))
    rescue JSON::ParserError, SystemCallError
      "entry calibration file is unreadable or not valid JSON"
    end

    def self.validate(data)
      return "entry calibration must be a JSON object" unless data.is_a?(Hash)
      unless binding.all? { |key, value| data[key] == value }
        return "entry calibration does not match the current rules, questions, input and decision versions"
      end

      model = data["model"].to_s
      return "entry calibration model must be a versioned id; aliases like jev-latest are rejected" unless model.match?(MODEL_PATTERN)

      thresholds = data["thresholds"]
      unless thresholds.is_a?(Hash) && thresholds.keys.sort == THRESHOLD_QUESTIONS.sort &&
             thresholds.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? && value <= 1 }
        return "entry calibration needs exactly the current finite thresholds in (0, 1]"
      end

      release = data["release"]
      unless release.is_a?(Hash) && %w[reason scope reviewed_by reviewed_at].all? do |field|
               release[field].is_a?(String) && !release[field].strip.empty? && release[field].length <= 1000
             end
        return "entry calibration needs its scope, review and release reason"
      end
      Time.iso8601(release.fetch("reviewed_at"))

      samples = data["samples"]
      unless samples.is_a?(Array) && samples.length.between?(SAMPLE_KINDS.length, MAX_SAMPLES) &&
             (SAMPLE_KINDS - samples.filter_map { |sample| sample["kind"] if sample.is_a?(Hash) }).empty?
        return "entry calibration needs labeled positive, negative, failure and missing-evidence samples"
      end
      ids = samples.map { |sample| sample.is_a?(Hash) && sample["id"] }
      unless ids.all? { |id| id.is_a?(String) && !id.strip.empty? } && ids.uniq.length == ids.length &&
             samples.all? { |sample| valid_sample?(sample, model, thresholds) }
        return "entry calibration samples do not support the released model and decision rule"
      end

      { "model" => model, "thresholds" => thresholds,
        "release" => release.slice("reason", "scope", "reviewed_by", "reviewed_at").merge(
          binding.merge("sample_count" => samples.length,
                        "sample_digest" => Digest::SHA256.hexdigest(JSON.generate(samples)))
        ) }
    rescue ArgumentError
      "entry calibration has an invalid review date"
    end

    def self.valid_sample?(sample, model, thresholds)
      return false unless SAMPLE_KINDS.include?(sample["kind"]) && sample["mode"] == "model_backed"
      state = sample["state"]
      return false unless state.is_a?(Hash) && state["input_version"] == PrestartClassifier::INPUT_VERSION &&
                          state["instruction"].is_a?(String) && !state["instruction"].strip.empty? &&
                          state["instruction"].length <= PrestartClassifier::PROMPT_BUDGET &&
                          [true, false].include?(state["instruction_truncated"]) && state["git"].is_a?(Hash)

      judgment = sample["judgment"]
      return false unless judgment.is_a?(Hash) && judgment["schema_version"] == JudgmentResult::SCHEMA_VERSION &&
                          judgment["source"].is_a?(Hash) && judgment.dig("source", "provider") == "typesafe"
      actual_model = judgment.dig("source", "actual_model")
      expected = sample["kind"] == "positive" ? "start" : "root_decides"
      return false unless sample["expected_decision"] == expected
      if sample["kind"] == "failure"
        return judgment["status"] == "unavailable" && [nil, model].include?(actual_model) &&
               (judgment["answers"].nil? || judgment["answers"] == {}) &&
               judgment["error"].is_a?(String) && !judgment["error"].empty?
      end
      return false unless judgment["status"] == "answered" && actual_model == model

      answers = judgment["answers"]
      return false unless answers.is_a?(Hash)
      scores = THRESHOLD_QUESTIONS.to_h do |question|
        answer = answers[question]
        value = answer.is_a?(Hash) ? answer["probability_true"] : nil
        return false unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)

        [question, value]
      end
      passes?(scores, thresholds) == (expected == "start")
    end
  end

  # Project-level entry ledger: one decision per native message id, written
  # atomically before the caller acts on it. Decisions are idempotent — a
  # repeated classification of the same message costs nothing external — and
  # a task that already exists for the message is reported instead of being
  # created twice.
  class PrestartLedger
    LEDGER_NAME = "prestart-decisions.json"
    ENTRY_DIRECTORY = "entry"

    class Error < StandardError; end

    def initialize(project_root)
      @project_root = project_root
      @orbit_directory = File.join(project_root, ".orbit")
    end

    def lookup(message_id)
      read_entries[message_id]
    end

    # Newest task directory whose recorded instruction source is this native
    # message, regardless of status: the same message must never create a
    # second task.
    def task_for(message_id)
      Dir.glob(File.join(@orbit_directory, "tasks/*/state.json")).filter_map do |path|
        state = JSON.parse(File.read(path))
        [File.dirname(path), state] if state.dig("instruction_source", "id") == message_id
      rescue JSON::ParserError, SystemCallError
        nil
      end.max_by { |_directory, state| state["created_at"].to_s }&.first
    end

    # Serialize concurrent sessions in the same project. Writing the entry
    # file before publishing the ledger means a recorded "start" decision
    # always has its trace ready for the existing start preflight.
    def record(message_id, document)
      FileUtils.mkdir_p(@orbit_directory, mode: 0o700)
      entry_file = File.join(@orbit_directory, ENTRY_DIRECTORY, "#{sanitize(message_id)}.json")
      File.open("#{ledger_path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        entries = read_entries
        raise Error, "native message was already classified" if entries.key?(message_id)

        atomic_write(entry_file, JSON.pretty_generate(document) + "\n")
        entries[message_id] = document
        atomic_write(ledger_path, JSON.pretty_generate(sort_recursively(entries)) + "\n")
      ensure
        lock.flock(File::LOCK_UN)
      end
      entry_file
    end

    private

    def read_entries
      return {} unless File.file?(ledger_path)

      data = JSON.parse(File.read(ledger_path))
      raise Error, "the prestart decision ledger is not a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise Error, "the prestart decision ledger is unreadable"
    end

    def ledger_path
      File.join(@orbit_directory, LEDGER_NAME)
    end

    def sanitize(message_id)
      message_id.to_s.gsub(/[^A-Za-z0-9._-]/, "_")[0, 120]
    end

    def sort_recursively(value)
      case value
      when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key, sort_recursively(item)] }
      when Array then value.map { |item| sort_recursively(item) }
      else value
      end
    end

    def atomic_write(destination, bytes)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      temporary = "#{destination}.#{Process.pid}.#{rand(1_000_000)}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.rename(temporary, destination)
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end
    end
  end
end
