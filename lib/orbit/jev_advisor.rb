# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

require_relative "judgment"
require_relative "type_safe_judgment"

module Orbit
  # A bounded semantic observation. Jev supplies probabilities; TaskRuntime
  # owns every check, correction and stop decision. All external judgment
  # calls go through the unified JudgmentRequest/JudgmentResult model
  # (ADR-008 2026-09-26 supplement): the TypeSafe adapter owns transport and
  # response mapping only, and these public methods keep their existing
  # signatures and result shapes so calibrated callers are unchanged.
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
      "delegatable" => {
        "type" => "noul",
        "instructions" => "Is there likely a bounded, independent subtask in the effective task requirements or remaining work that an authorized execution member could deliver now while the main agent continues? Prioritize the instruction, basis and amendments over whether the main agent has already mentioned or started that subtask in recent activity. Explicit disjoint files, modules or acceptance surfaces are strong evidence. Count only separable work with a clear result; do not count trivial, overlapping, preference-only or dependency-blocked work. Member availability is enforced separately by the caller, so do not lower this task-structure probability merely because availability is unknown.",
        "criteria" => { "true" => "The effective requirements or remaining work expose a concrete, substantive and separable subtask with its own result", "false" => "The remaining work is coupled, trivial, dependency-blocked or has no clear separable result" }
      }
    }.freeze

    # Question-set versions for traceability; the wording above is frozen
    # with docs/plan/jev-delegation-optimization.md and ADR-009. Bump on any
    # wording change so recorded judgments stay interpretable.
    QUESTION_SET_VERSIONS = {
      "observation" => "jev-observation-1",
      "delegation" => "jev-delegation-1",
      "candidates" => "jev-candidates-1",
      "checker_quality" => "jev-checker-quality-1"
    }.freeze

    # Second-stage delegation judgment, asked only after the caller's own
    # structural checks pass. The member_fit and parallel_gain wording is
    # frozen in docs/plan/jev-delegation-optimization.md; cost_appropriate
    # follows the ADR-009 coarse cost tiers. The caller supplies member
    # options and the bounded evidence comparison inside state.
    DELEGATION_QUESTIONS = {
      "member_fit" => {
        "type" => "noul",
        "instructions" => "Given the callable member options and the supplied model evidence, is at least one member likely to meet the best bounded subtask's acceptance bar using only information that can be passed in a bounded handoff? Do not assume a handoff already exists, and do not assume the member can see Root's context. Do not treat a matching provider, model or reasoning identity as direct evidence of capability parity. Treat missing or stale evidence as unknown and do not infer capability from a model name alone. Handoff, rework and integration time overhead belong only to parallel_gain.",
        "criteria" => { "true" => "A callable member is likely to meet the acceptance bar using only information that can be passed in a bounded handoff",
                        "false" => "No member is likely to meet the acceptance bar from a bounded handoff, or missing or stale evidence leaves the fit unknown" }
      },
      "parallel_gain" => {
        "type" => "noul",
        "instructions" => "Given the remaining task dependencies and the supplied execution evidence, would delegating the best bounded subtask now likely shorten the overall critical path after handoff, expected rework, integration, shared-resource contention, and verification are included? Output speed alone is not task completion speed.",
        "criteria" => { "true" => "Delegating the best bounded subtask likely shortens the overall critical path once handoff, rework, integration, contention and verification are included",
                        "false" => "Delegation is unlikely to shorten the critical path, or the evidence is insufficient" }
      },
      "cost_appropriate" => {
        "type" => "noul",
        "instructions" => "Given the submitter-provided coarse cost tier (low, medium, high, or unknown) with its source and confidence annotation for the callable member option, is that cost burden proportionate to the best bounded subtask? Judge the candidate's coarse price or subscription/quota burden tier against the size and value of the bounded subtask; the program checks only that a submitted tier carries a source and confidence annotation, not exact numbers against the vendor page. A clearly labeled low-confidence estimate from vendor or model positioning is acceptable evidence. Per-use API pricing and subscription quota must never be converted into a single fake per-token price or compared as if interchangeable. Do not convert currencies, compare it with the caller's own billing route, or rank providers by name or brand. Treat a missing, stale or unevaluated tier as unknown; unknown cost is not free and must not raise this score, and an unknown tier alone must not lower this score when the candidate already meets the quality and time bars. Any user-set hard budget is enforced separately by the calling program's runtime code, not by this question.",
        "criteria" => { "true" => "A known coarse cost tier is proportionate for this bounded subtask",
                        "false" => "A known coarse cost tier is disproportionate for this bounded subtask" }
      }
    }.freeze

    class Error < StandardError; end

    # Per-candidate ADR-009 §3 questions for the pool recommendation stage.
    # Quality must clear the line from sourced evidence and the task
    # requirements alone — never from a model, provider or brand name. Time
    # must survive handoff, rework, integration, contention and verification.
    # Cost tiers are program-read from validated cache entries, not judged
    # here and never guessed by brand.
    CANDIDATE_QUALITY_TEXT = "Is this candidate model likely to meet the best bounded subtask's acceptance bar using only information that can be passed in a bounded handoff, judged from the supplied sourced evidence for THIS candidate and the task requirements? Do not infer capability from the model, provider or brand name alone, and do not treat a matching identity with the caller as evidence of parity. Treat missing, stale or unsourced evidence as unknown and do not raise this score without sourced support."
    CANDIDATE_TIME_TEXT = "Would delegating the best bounded subtask to THIS candidate now likely shorten the overall critical path once handoff, expected rework, integration, shared-resource contention and verification are included? Output speed alone is not task completion speed."

    AMENDMENT_BUDGET = 8000
    AMENDMENT_TEXT_LIMIT = 1200
    BASIS_BUDGET = 4000
    BASIS_TEXT_LIMIT = 1500
    BASIS_DOCUMENT_LIMIT = 3

    def self.for_project(project_root, env: ENV)
      return nil if File.exist?(File.join(project_root, ".orbit", "jev-disabled"))

      key = env["TYPESAFE_API_KEY"].to_s.strip
      return nil if key.empty?

      new(api_key: key)
    end

    def initialize(api_key:, endpoint: ENDPOINT)
      @api_key = api_key.to_s
      @endpoint = endpoint
    end

    # Provider-level judgment channel with this advisor's credentials and an
    # explicitly chosen model; the calibrated entry gate pins a versioned id
    # instead of the in-task jev-latest alias.
    def judgment_provider(model: MODEL)
      TypeSafeJudgment.new(api_key: @api_key, endpoint: @endpoint, model: model)
    end

    def assess(state:)
      post_questions(state: state, questions: QUESTIONS,
                     question_set_version: QUESTION_SET_VERSIONS.fetch("observation"))
    end

    # Second-stage delegation judgment. The caller supplies the full bounded
    # state, including member options and the evidence comparison; the advisor
    # only asks member_fit and parallel_gain. It does not gather evidence, read
    # caches, or infer model names, and a missing key is the caller's fact to
    # structure around, not something this stage fabricates.
    def assess_delegation(state:)
      post_questions(state: state, questions: DELEGATION_QUESTIONS,
                     question_set_version: QUESTION_SET_VERSIONS.fetch("delegation"))
    end

    # Per-candidate pool judgment (ADR-009 §3): one quality-line and one
    # end-to-end-time noul question per candidate, each labeled by index and
    # naming the candidate's agent and model. Cost tiers are not asked here;
    # the caller reads them from validated cache entries.
    def assess_candidates(state:, candidates:)
      questions = {}
      candidates.each_with_index do |candidate, index|
        label = "candidate #{index} (agent #{candidate['agent']}, model #{candidate['provider']}/#{candidate['model']}): "
        questions["candidate_#{index}_quality"] = {
          "type" => "noul",
          "instructions" => label + CANDIDATE_QUALITY_TEXT,
          "criteria" => { "true" => "This candidate is likely to meet the acceptance bar from a bounded handoff, supported by the supplied sourced evidence",
                          "false" => "This candidate is unlikely to meet the bar, or the sourced evidence is missing, stale or insufficient" }
        }
        questions["candidate_#{index}_time"] = {
          "type" => "noul",
          "instructions" => label + CANDIDATE_TIME_TEXT,
          "criteria" => { "true" => "Delegating to this candidate likely shortens the overall critical path once handoff, rework, integration, contention and verification are included",
                          "false" => "Delegation to this candidate is unlikely to shorten the critical path, or the evidence is insufficient" }
        }
      end
      result = post_questions(state: state, questions: questions,
                              question_set_version: QUESTION_SET_VERSIONS.fetch("candidates"))
      scores = candidates.each_index.to_h do |index|
        [index.to_s, { "quality" => result["scores"].fetch("candidate_#{index}_quality"),
                       "time" => result["scores"].fetch("candidate_#{index}_time") }]
      end
      result.merge("scores" => scores)
    end

    # ADR-009 checker quality and time gate. The caller supplies the current
    # task instruction and each candidate's already-bounded cached evidence;
    # this asks two typed noul questions per candidate in one request — quality
    # fit and expected end-to-end independent-check time including rework — and
    # maps the answers back to provider/id. It does not read caches, infer from
    # a model or provider name, and never treats a credential, a single
    # benchmark number or output speed as capability or task time.
    def assess_checker_quality(state:, candidates:)
      list = Array(candidates)
      raise Error, "at least one checker candidate is required" if list.empty?

      questions = {}
      list.each_with_index do |candidate, index|
        model = candidate.fetch("model").to_s
        questions["quality_#{index}"] = {
          "type" => "noul",
          "instructions" => "Checker candidate #{model}: given the current task instruction and this candidate's bounded cached model " \
                            "evidence (sources and metrics such as quality and local_samples), is that evidence sufficient to judge the " \
                            "model can meet the quality bar for an independent read-only review of this task's artifact? A credential, a " \
                            "matching model or provider name, or a single benchmark number is not capability evidence. Missing, stale or empty " \
                            "evidence is unknown. Answer true only when the supplied evidence is verifiable and specifically supports quality " \
                            "for this kind of task.",
          "criteria" => {
            "true" => "Verifiable cached evidence supports quality for this kind of task",
            "false" => "Evidence is missing, stale, unsupported or insufficient for this kind of task"
          }
        }
        questions["time_#{index}"] = {
          "type" => "noul",
          "instructions" => "Checker candidate #{model}: given the current task artifact and this candidate's bounded evidence, would an " \
                            "independent read-only check by this model most likely finish end-to-end quickly, counting the check itself, any " \
                            "rework after a weak or failed earlier check, and Root's follow-up? Output tokens per second alone is not " \
                            "end-to-end task time. Answer true only when the supplied evidence gives a concrete basis to expect a fast " \
                            "end-to-end check; no basis is unknown.",
          "criteria" => {
            "true" => "Concrete evidence supports a fast end-to-end independent check including rework",
            "false" => "No concrete basis, or the evidence suggests a slower end-to-end check"
          }
        }
      end
      result = post_questions(state: state, questions: questions,
                              question_set_version: QUESTION_SET_VERSIONS.fetch("checker_quality"))
      scores = list.each_with_index.to_h do |candidate, index|
        [candidate.fetch("model").to_s,
         { "quality" => result.fetch("scores").fetch("quality_#{index}"),
           "time" => result.fetch("scores").fetch("time_#{index}") }]
      end
      result.merge("scores" => scores)
    end

    private

    # Unified-model poster: builds a JudgmentRequest, judges through the
    # TypeSafe adapter, validates completeness against the requested ids and
    # re-raises as JevAdvisor::Error on any unavailable result so existing
    # fail-closed callers keep their behavior. The wire format and the frozen
    # question wording are unchanged.
    def post_questions(state:, questions:, question_set_version:)
      request = JudgmentRequest.new(
        state: state, questions: self.class.model_questions(questions),
        question_set_version: question_set_version, provider: TypeSafeJudgment::PROVIDER, model: MODEL
      )
      result = judgment_provider.judge(request)
      raise Error, result.error if result.unavailable?
      raise Error, "the judgment did not answer every requested question" unless result.complete_for?(request)

      {
        "provider" => result.provider, "model" => result.actual_model,
        "question_set_version" => question_set_version,
        "scores" => questions.to_h { |name, _question| [name, result.probability_true(name)] },
        "usage" => result.usage
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

    def self.observation(inputs:, host:, members:, project_root:, artifact_digest:, elapsed_seconds:, member_options: nil)
      amendments, omitted = bounded_amendments(inputs.fetch("amendments", []))
      basis, basis_omitted = bounded_basis(inputs.fetch("basis", []))
      {
        "instruction" => limit(inputs.fetch("instruction"), 4000),
        "basis" => basis,
        "basis_omitted" => basis_omitted,
        "amendments" => amendments,
        "amendments_omitted" => omitted,
        "member_options" => member_options,
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
