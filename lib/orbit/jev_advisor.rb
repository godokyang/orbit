# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

require_relative "judgment"
require_relative "model_quality_policy"
require_relative "type_safe_judgment"

module Orbit
  # A bounded semantic observation. Jev supplies probabilities; TaskRuntime
  # owns every check, correction and stop decision. All external judgment
  # calls go through the unified JudgmentRequest/JudgmentResult model
  # (ADR-008 2026-09-26 supplement): the TypeSafe adapter owns transport and
  # response mapping only. Selection questions and their score keys are the
  # ModelQualityPolicy versions; stuck, off_track and artifact_ready keep
  # their previous wording. Check and stop gates are not decided here.
  class JevAdvisor
    ENDPOINT = TypeSafeJudgment::ENDPOINT
    MODEL = TypeSafeJudgment::DEFAULT_MODEL
    QUESTIONS = {
      "stuck" => {
        "type" => "noul",
        "instructions" => "Is the coding agent likely unable to make useful progress on the current task now? Do not infer this from elapsed time alone; ordinary exploration or a single failed command is not stuckness.",
        "criteria" => { "true" => "Repeated failure or inactivity without a useful new approach", "false" => "Useful work is continuing or the evidence is insufficient" }
      },
      "off_track" => {
        "type" => "noul",
        "instructions" => "Is recent work likely outside or contrary to the latest effective user request? Normal investigation, tests and necessary setup can be relevant work.",
        "criteria" => { "true" => "Concrete recent activity appears unrelated or contrary to the request", "false" => "Activity appears relevant or the evidence is insufficient" }
      },
      "artifact_ready" => {
        "type" => "noul",
        "instructions" => "Would a full independent review of the current artifact now likely provide useful, current feedback? Consider whether the agent is actively changing it and the review would quickly become stale.",
        "criteria" => { "true" => "A meaningful artifact checkpoint is available now", "false" => "The artifact is still too early or actively changing" }
      },
    }.freeze

    # Runtime supervision is separate from model selection. Bounded handoff
    # and member fit are judged over explicit work-unit facts below.
    QUESTION_SET_VERSIONS = ModelQualityPolicy::QUESTION_SET_VERSIONS

    # No-pool second stage. handoff_fit allows a serial handoff. member_task_fit
    # reads exact evidence and a catalog prior as separate inputs. There is no
    # time question and no coarse cost question; route cost stays in the policy.
    DELEGATION_QUESTIONS = ModelQualityPolicy.delegation_questions.freeze

    class Error < StandardError
      attr_reader :receipt

      def initialize(message = nil, receipt: nil)
        @receipt = receipt
        super(message)
      end

      def judgment
        facts = receipt.is_a?(Hash) ? receipt : {}
        source = facts["source"].is_a?(Hash) ? facts["source"] : {}
        { "provider" => source["provider"], "model" => source["actual_model"],
          "question_set_version" => facts["question_set_version"], "usage" => facts["usage"],
          "call_id" => facts["call_id"], "requested_model" => facts["requested_model"],
          "status" => "unavailable", "error" => facts["error"] }
      end
    end

    AMENDMENT_BUDGET = 8000
    AMENDMENT_TEXT_LIMIT = 1200
    BASIS_BUDGET = 4000
    BASIS_TEXT_LIMIT = 1500
    BASIS_DOCUMENT_LIMIT = 3

    def self.for_project(project_root, env: ENV)
      return nil if File.exist?(File.join(project_root, ".orbit", "jev-disabled"))

      key = env["TYPESAFE_API_KEY"].to_s.strip
      return nil if key.empty?

      release = ModelQualityPolicy.load
      new(api_key: key, model: release.is_a?(Hash) ? release.fetch("model") : MODEL)
    end

    def initialize(api_key:, endpoint: ENDPOINT, model: MODEL)
      @api_key = api_key.to_s
      @endpoint = endpoint
      @model = model
    end

    # Provider-level judgment channel with this advisor's credentials and an
    # explicitly chosen model; the calibrated entry gate pins a versioned id
    # instead of the in-task jev-latest alias.
    def judgment_provider(model: @model)
      TypeSafeJudgment.new(api_key: @api_key, endpoint: @endpoint, model: model)
    end

    def assess(state:)
      post_questions(state: state, questions: QUESTIONS,
                     question_set_version: QUESTION_SET_VERSIONS.fetch("observation"))
    end

    # No-pool second stage. Asks handoff_fit and member_task_fit only. The
    # state is projected first so speed, elapsed time and coarse price are not
    # selection inputs. The advisor does not gather evidence or invent facts.
    def assess_delegation(state:)
      post_questions(state: ModelQualityPolicy.project_selection_state(state), questions: DELEGATION_QUESTIONS,
                     question_set_version: QUESTION_SET_VERSIONS.fetch("delegation"))
    end

    # Per-candidate task fit. The returned quality key is the new task-fit
    # probability. There is no time score. Speed and coarse price are removed
    # from the state before the question is sent.
    def assess_candidates(state:, candidates:)
      questions = ModelQualityPolicy.candidate_questions(candidates)
      result = post_questions(state: ModelQualityPolicy.project_selection_state(state), questions: questions,
                              question_set_version: QUESTION_SET_VERSIONS.fetch("candidates"))
      scores = candidates.each_index.to_h do |index|
        [index.to_s, { "quality" => result["scores"].fetch("candidate_#{index}_task_fit") }]
      end
      result.merge("scores" => scores)
    end

    # Checker task fit only. Exact evidence and a catalog prior both stay in
    # the projected input; neither is added to the probability, and no time
    # score is returned.
    def assess_checker_quality(state:, candidates:)
      list = Array(candidates)
      raise Error, "at least one checker candidate is required" if list.empty?

      questions = ModelQualityPolicy.checker_questions(list)
      result = post_questions(state: ModelQualityPolicy.project_selection_state(state), questions: questions,
                              question_set_version: QUESTION_SET_VERSIONS.fetch("checker_quality"))
      scores = list.each_with_index.to_h do |candidate, index|
        [candidate.fetch("model").to_s, { "quality" => result.fetch("scores").fetch("quality_#{index}") }]
      end
      result.merge("scores" => scores)
    end

    private

    # Unified-model poster: builds a JudgmentRequest, judges through the
    # TypeSafe adapter, validates completeness against the requested ids and
    # re-raises as JevAdvisor::Error on any unavailable result so existing
    # fail-closed callers keep their behavior. Checker question changes use a
    # distinct version while retaining the same validated wire shape.
    def post_questions(state:, questions:, question_set_version:)
      request = JudgmentRequest.new(
        state: state, questions: self.class.model_questions(questions),
        question_set_version: question_set_version, provider: TypeSafeJudgment::PROVIDER, model: @model
      )
      result = judgment_provider.judge(request)
      unless result.complete_for?(request)
        failure = if result.unavailable?
                    result
                  else
                    JudgmentResult.unavailable(
                      provider: result.provider, reason: "the judgment did not answer every requested question",
                      actual_model: result.actual_model, usage: result.usage
                    )
                  end
        failure = failure.with_call_id(result.call_id) if result.call_id && !failure.call_id
        receipt = failure.to_h.merge("question_set_version" => question_set_version, "requested_model" => @model)
        raise Error.new(failure.error, receipt: receipt)
      end

      {
        "provider" => result.provider, "model" => result.actual_model,
        "question_set_version" => question_set_version,
        "scores" => questions.to_h { |name, _question| [name, result.probability_true(name)] },
        "usage" => result.usage, "call_id" => result.call_id, "requested_model" => @model, "status" => result.status,
        "input_version" => state.is_a?(Hash) ? state["input_version"] : nil
      }
    rescue Error
      raise
    rescue JudgmentRequest::Error, JudgmentResult::Error, TypeSafeJudgment::Error => error
      raise Error, error.message
    rescue StandardError => error
      raise Error, "TypeSafe assessment failed: #{error.class}"
    end

    # The frozen question constants use the TypeSafe wire shape
    # (type/instructions/criteria); the unified model carries the same wording
    # as instruction/true_criterion/false_criterion and the adapter maps it
    # back, byte-identically, on the wire.
    def self.model_questions(questions)
      questions.to_h do |id, question|
        [id, { "instruction" => question.fetch("instructions"),
               "true_criterion" => question.fetch("criteria").fetch("true"),
               "false_criterion" => question.fetch("criteria").fetch("false") }]
      end
    end

    def self.observation(inputs:, host:, members:, project_root:, artifact_digest:, elapsed_seconds:, member_options: nil, member_blocks: nil)
      amendments, omitted = bounded_amendments(inputs.fetch("amendments", []))
      basis, basis_omitted = bounded_basis(inputs.fetch("basis", []))
      {
        "instruction" => limit(inputs.fetch("instruction"), 4000),
        "basis" => basis,
        "basis_omitted" => basis_omitted,
        "amendments" => amendments,
        "amendments_omitted" => omitted,
        "member_options" => member_options,
        "member_blocks" => member_blocks_projection(member_blocks),
        "host" => host.slice("status", "turn_id", "last_turn_id", "last_turn_status", "active_tools"),
        "recent_observations" => observation_tail(host["observations"]),
        "members" => members.last(5).map do |member|
          { "status" => member["status"], "error" => limit(member["error"], 300),
            "result_excerpt" => tail_text(JSON.generate(member["result"]), 1000) }
        end,
        "artifact_digest" => artifact_digest,
        "changes" => git_changes(project_root),
        "elapsed_seconds" => elapsed_seconds.to_i
      }
    end

    def self.limit(value, size)
      text = value.to_s
      text.length > size ? "#{text[0, size]}…[truncated]" : text
    end

    def self.member_blocks_projection(blocks)
      return nil unless blocks.is_a?(Hash)

      classes = Array(blocks["classes"])
      { "scope" => blocks["scope"], "total" => blocks["total"], "stall" => blocks["stall"],
        "evicted_classes" => blocks["evicted_classes"], "omitted_classes" => [classes.length - 8, 0].max,
        "classes" => classes.last(8).map do |entry|
          entry.slice("tool", "reason", "count", "agents", "units", "dispatches", "dispatches_omitted", "first_at", "last_at", "stalled")
        end }
    end

    # Newest effective amendments are kept under a character budget. When
    # older ones do not fit, the omitted range is explicit: Jev must not treat
    # missing earlier context as evidence that work went off track.
    def self.bounded_amendments(amendments, budget: AMENDMENT_BUDGET)
      selected = []
      remaining = budget
      amendments.reverse_each do |entry|
        text = limit(entry.fetch("text"), AMENDMENT_TEXT_LIMIT)
        break if text.length > remaining

        selected.unshift(text)
        remaining -= text.length
      end
      omitted = amendments.length - selected.length
      omitted_info = if omitted.positive?
                       { "count" => omitted, "included_range" => "#{omitted + 1}-#{amendments.length}",
                         "note" => "Older effective user changes were omitted by the input budget; " \
                                   "missing earlier context is not evidence of going off track." }
                     end
      [selected, omitted_info]
    end

    def self.bounded_basis(documents)
      remaining = BASIS_BUDGET
      included = []
      truncated_paths = []
      documents.first(BASIS_DOCUMENT_LIMIT).each_with_index do |document, index|
        path = document["path"] || File.basename(document.fetch("source", "basis-#{index + 1}"))
        text = document.fetch("text").to_s
        allowance = [BASIS_TEXT_LIMIT, remaining].min
        truncated = text.length > allowance
        excerpt = if truncated
                    marker = "…[truncated]"
                    text[0, allowance - marker.length] + marker
                  else
                    text
                  end
        included << { "path" => path, "text" => excerpt }
        truncated_paths << path if truncated
        remaining -= excerpt.length
      end
      omitted_count = documents.length - included.length
      omitted_info = if omitted_count.positive? || !truncated_paths.empty?
                       { "count" => omitted_count, "truncated_paths" => truncated_paths,
                         "note" => "Specified task documents were truncated or omitted by the input budget; " \
                                   "missing text is not evidence that a requirement is absent." }
                     end
      [included, omitted_info]
    end

    def self.observation_tail(observations)
      return tail_text(JSON.generate(observations), 5000) unless observations.is_a?(Array)

      remaining = 5000
      latest = []
      observations.reverse_each do |item|
        break if remaining < 200

        text = tail_text(JSON.generate(item), [remaining, 1800].min)
        latest.unshift(text)
        remaining -= text.length
      end
      { "omitted_older_entries" => observations.length - latest.length, "latest_entries_json" => latest }
    end

    def self.tail_text(value, size)
      return value if value.length <= size

      prefix = "[older content truncated]…"
      "#{prefix}#{value[-(size - prefix.length), size - prefix.length]}"
    end

    def self.git_changes(root)
      status = git_read(root, ["status", "--short", "--untracked-files=normal"], 2000)
      diff = git_read(root, ["diff", "--no-ext-diff", "--no-textconv", "--unified=0", "HEAD", "--"], 4000)
      { "status" => status, "diff_excerpt" => diff }
    end

    def self.git_read(root, args, limit)
      bytes = IO.popen(["git", "-C", root, *args], err: File::NULL) { |io| io.read(limit) }.to_s
      utf8_excerpt(bytes)
    rescue Errno::ENOENT, IOError, SystemCallError
      ""
    end

    # IO#read(limit) returns raw bytes, so the byte budget can cut the last
    # UTF-8 character in half; JSON generation then rejects the whole payload
    # (the observed `TypeSafe assessment failed: JSON::GeneratorError`). Drop
    # only that incomplete trailing sequence (at most three bytes) so the
    # excerpt ends on a character boundary within the same byte budget. Bytes
    # before the cut stay untouched, and genuinely invalid content beyond the
    # boundary is not silently replaced: the string is left invalid so the
    # caller's existing fail-closed degradation applies.
    def self.utf8_excerpt(bytes)
      text = +bytes # unfrozen, so re-tagging as UTF-8 costs no copy
      text.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?

      1.upto(3) do |dropped|
        candidate = text.byteslice(0, text.bytesize - dropped)
        return candidate if candidate&.valid_encoding?
      end
      text
    end
  end
end
