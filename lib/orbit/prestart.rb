# frozen_string_literal: true

require "json"

require_relative "jev_advisor"
require_relative "judgment"

module Orbit
  # Bounded pre-start entry classification for the latest native user message
  # of a session that has no bound Orbit task (ADR-008 2026-09-26 supplement;
  # contracts/task-runtime.md「已确认、待实现：启动前 JEV 入口判定」).
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
    SCHEMA_VERSION = 1
    # Deterministic classification rules; bump when wording or patterns move.
    RULE_VERSION = "orbit-entry-rules-1"
    QUESTION_SET_VERSION = "orbit-entry-1"
    CALIBRATION_RELATIVE_PATH = ".orbit/jev-entry.json"
    PROMPT_BUDGET = 8000
    EXCERPT_LIMIT = 300

    # Entry judgment questions (first version, binary only). Wording follows
    # the contract; thresholds come only from a calibrated configuration and
    # are never invented here.
    ENTRY_QUESTIONS = {
      "execution_authorized" => {
        "instruction" => "Has the user already authorized executing this request now, rather than merely discussing, comparing or asking about options? A question, a hypothetical, a request for an opinion or an explanation is not authorization to execute.",
        "true_criterion" => "The message asks for this work to actually be done now",
        "false_criterion" => "The message discusses, asks about or compares options without authorizing execution now"
      },
      "independent_check_benefit" => {
        "instruction" => "Would an independent review of the resulting artifact against this request likely provide real value for this request? Trivial, purely informational or read-only requests gain nothing from an artifact review.",
        "true_criterion" => "An independent artifact review would likely find real omissions or errors for this request",
        "false_criterion" => "The request is read-only, trivial or has no meaningful artifact to review"
      }
    }.freeze

    # High-precision markers only: a false "explicit" starts a task nobody
    # asked for, so the word orbit alone is never enough and neither is an
    # orbit mention inside other work ("fix the orbit bug in parser.rb").
    EXPLICIT_PATTERNS = [
      /orbit[ \t]*受控/i,
      /\borbit[- ]controlled\b/i,
      /用[ \t]*orbit[ \t]*(来)?[ \t]*(启动|开始|创建|开|建|跑)/i,
      /使用[ \t]*orbit[ \t]*(来)?[ \t]*(启动|开始|创建|开|建|跑|受控|控制|执行)/i,
      /^(?:请|麻烦|帮我)?[ \t]*(?:用|使用)[ \t]*orbit[ \t]*(?:来[ \t]*)?完成(?!了?[吗么])/i,
      /交给[ \t]*orbit/i,
      /orbit[ \t]*(启动|创建|开)[ \t]*一[个條]?[ \t]*任务/i,
      /\b(start|create|open|begin)[ \t]+an?[ \t]+orbit[ \t]+task\b/i,
      /\buse[ \t]+orbit[ \t]+to[ \t]+(start|run|execute|control)\b/i,
      /\brun[ \t]+this[ \t]+([a-z]+[ \t]+)?under[ \t]+orbit\b/i
    ].freeze

    # Execution verbs that turn a leading "explain …" into real work.
    EXECUTION_MARKERS = [
      /修复|实现|修改|创建|添加|删除|重构|部署|写[一个个]|跑[一一]|执行/,
      /\b(implement|fix|modify|create|add|delete|remove|refactor|deploy|write|build|migrate)\b/i
    ].freeze

    # A clearly-discussion message asks an interrogative question or asks for
    # read-only treatment. A question mark alone is NOT sufficient, and a
    # polite request phrased as a question is left uncertain, not discussion.
    DISCUSSION_LEADS = [
      /^(what|why|how|when|who|where|which|explain|clarify|describe)\b/i,
      /^(什么|为什么|为何|怎么(?:理解|用)|怎样(?:理解|用)|如何(?:理解|用)|哪个|哪些|是否|是不是|有没有)/,
      /^(解释|说明|介绍|帮我理解)/
    ].freeze
    READ_ONLY_MARKERS = [
      /(不要|别|无需|不用|不需要)[^。！？\n]{0,12}(修改|改动|改变|执行|运行|写入|创建|动)/,
      /\b(just|only)[ \t]+(answer|explain|describe|summarize|tell me)\b/i,
      /\b(read[ \t-]?only|don'?t change anything)\b/i,
      /(仅供参考|只是问问|只是想(了解|知道|问一下))/
    ].freeze
    READ_ONLY_REGEX = Regexp.union(*READ_ONLY_MARKERS)

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
      prompt = text.to_s
      return "discussion" if prompt.strip.empty?

      return "explicit_orbit" if EXPLICIT_PATTERNS.any? { |pattern| pattern.match?(prompt) }

      compact = prompt.gsub(/\s+/, " ").strip
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
      when "discussion"
        outcome("discussion", "no_start", "clear discussion or read-only question")
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
        return outcome("uncertain", "root_decides", "entry judgment unavailable: #{result.error}")
      end

      probabilities = result.answers.transform_values { |value| { "probability_true" => value } }
      passed = calibration.fetch("thresholds").all? do |question_id, threshold|
        result.probability_true(question_id) >= threshold
      end
      if passed
        outcome("uncertain", "start", "calibrated entry judgment cleared both thresholds",
                probabilities: probabilities, provider: result.provider, actual_model: result.actual_model,
                usage: result.usage, calibration: calibration)
      else
        outcome("uncertain", "root_decides", "calibrated entry judgment did not clear both thresholds",
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

      EXECUTION_MARKERS.none? { |pattern| pattern.match?(compact) }
    end

    def entry_state(text)
      {
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
      trace = { "rule_version" => RULE_VERSION }
      if probabilities
        trace.merge!("question_set_version" => QUESTION_SET_VERSION, "provider" => provider,
                     "actual_model" => actual_model, "probabilities" => probabilities,
                     "thresholds" => calibration.fetch("thresholds"))
        trace["usage"] = usage if usage
      end
      {
        "schema_version" => SCHEMA_VERSION, "classification" => classification, "decision" => decision,
        "reason" => reason, "trace" => trace
      }
    end
  end

  # Calibrated entry-gate configuration. The built-in default below comes from
  # the first three labeled REAL request originals (2026-09-26, pinned
  # jev-1.13.0): positives 0.95/0.90 and 0.55/0.75, discussion negative
  # 0.07/0.67 (execution_authorized/independent_check_benefit). Three samples
  # are tiny: the thresholds are deliberately conservative so only clear
  # authorization auto-starts (0.95 passes, the softer 0.55 positive stays
  # with Root, the negative never starts). `.orbit/jev-entry.json` overrides
  # the built-in explicitly; `.orbit/jev-disabled` still stops all outbound.
  # A versioned model id is always required — an alias such as "jev-latest"
  # would let a silent upstream upgrade change the calibrated thresholds.
  module EntryCalibration
    MODEL_PATTERN = /\Ajev-\d+(\.\d+)*(-[0-9A-Za-z.\-]+)?\z/
    THRESHOLD_QUESTIONS = %w[execution_authorized independent_check_benefit].freeze
    BUILT_IN = {
      "model" => "jev-1.13.0",
      "thresholds" => { "execution_authorized" => 0.80, "independent_check_benefit" => 0.70 },
      "calibrated_samples" => 3,
      "source" => "built-in default calibrated 2026-09-26 on three labeled real requests (tiny sample; conservative)"
    }.freeze

    def self.load(project_root)
      file = File.join(project_root, PrestartClassifier::CALIBRATION_RELATIVE_PATH)
      return BUILT_IN unless File.file?(file)

      data = JSON.parse(File.read(file))
      return "entry calibration must be a JSON object" unless data.is_a?(Hash)
      unless data["calibrated_samples"].is_a?(Integer) && data["calibrated_samples"].positive?
        return "entry calibration needs a positive calibrated_samples count from real requests"
      end

      model = data["model"].to_s
      return "entry calibration model must be a versioned id; aliases like jev-latest are rejected" unless model.match?(MODEL_PATTERN)

      thresholds = data["thresholds"]
      unless thresholds.is_a?(Hash) && THRESHOLD_QUESTIONS.all? { |question| thresholds[question].is_a?(Numeric) }
        return "entry calibration thresholds must cover #{THRESHOLD_QUESTIONS.join(' and ')}"
      end

      thresholds.each_value do |value|
        return "entry calibration thresholds must be finite numbers in (0, 1]" unless value.finite? && value.positive? && value <= 1
      end

      { "model" => model, "thresholds" => thresholds.slice(*THRESHOLD_QUESTIONS),
        "calibrated_samples" => data["calibrated_samples"] }
    rescue JSON::ParserError, SystemCallError
      "entry calibration file is unreadable or not valid JSON"
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
