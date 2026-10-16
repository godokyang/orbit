# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

require_relative "judgment"
require_relative "model_quality_policy"
require_relative "type_safe_judgment"
require_relative "jev_input_compactor"

module Orbit
  # A bounded semantic observation. Jev supplies probabilities; TaskRuntime
  # owns every check, correction and stop decision. All external judgment
  # calls go through the unified JudgmentRequest/JudgmentResult model
  # (ADR-008 2026-09-26 supplement): the TypeSafe adapter owns transport and
  # response mapping only. Selection questions and their score keys are the
  # ModelQualityPolicy versions; observation asks only stuck and off_track.
  # Root requests final review; check and stop gates are not decided here.
  class JevAdvisor
    ROOT_VERIFICATION_FIELDS = %w[
      kind source tool_call_id tool status is_error async exit_code exit_code_source
      at at_ms start_observed_at start_observed_at_ms start_observed_at_source
      execution_cwd artifact_root input_digest artifact_root_at_completion artifact_digest
      fingerprint_status artifact_matches input_matches targets targets_status control_targets
      effect content_saved diff_saved output_saved scope coverage
    ].freeze

    SELECTION_PER_QUESTION_UTF8_UPPER_BOUND_BYTES = 32_768
    SELECTION_REQUEST_UTF8_UPPER_BOUND_BYTES = 65_536
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

    # The task runtime uses this to persist the exact request and the
    # normalized result for each actual call. It is deliberately separate
    # from status projections, which keep only a compact latest summary.
    attr_reader :last_trace

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
    def assess_delegation(state:, compaction: nil)
      post_questions(state: ModelQualityPolicy.project_selection_state(state), questions: DELEGATION_QUESTIONS,
                     question_set_version: QUESTION_SET_VERSIONS.fetch("delegation"), compaction: compaction)
    end

    # Per-candidate task fit. The returned quality key is the new task-fit
    # probability. There is no time score. Speed and coarse price are removed
    # from the state before the question is sent.
    def assess_candidates(state:, candidates:, compaction: nil)
      questions = ModelQualityPolicy.candidate_questions(candidates)
      result = post_questions(state: ModelQualityPolicy.project_selection_state(state), questions: questions,
                              question_set_version: QUESTION_SET_VERSIONS.fetch("candidates"), compaction: compaction)
      scores = candidates.each_index.to_h do |index|
        [index.to_s, { "quality" => result["scores"].fetch("candidate_#{index}_task_fit") }]
      end
      result.merge("scores" => scores)
    end

    # Checker task fit only. Exact evidence and a catalog prior both stay in
    # the projected input; neither is added to the probability, and no time
    # score is returned.
    def assess_checker_quality(state:, candidates:, compaction: nil)
      list = Array(candidates)
      raise Error, "at least one checker candidate is required" if list.empty?

      questions = ModelQualityPolicy.checker_questions(list)
      result = post_questions(state: ModelQualityPolicy.project_selection_state(state), questions: questions,
                              question_set_version: QUESTION_SET_VERSIONS.fetch("checker_quality"), compaction: compaction)
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
    def post_questions(state:, questions:, question_set_version:, compaction: nil)
      return recover_selection(state: state, questions: questions, question_set_version: question_set_version,
                               compaction: compaction) { |selected_state|
        post_questions(state: selected_state, questions: questions, question_set_version: question_set_version)
      } if compaction

      @last_trace = nil
      request = JudgmentRequest.new(
        state: state, questions: self.class.model_questions(questions),
        question_set_version: question_set_version, provider: TypeSafeJudgment::PROVIDER, model: @model
      )
      @last_trace = {
        "metadata" => { "provider" => request.provider,
                        "question_set_version" => request.question_set_version },
        "request" => {
          "model" => @model, "state" => request.state,
          "questions" => request.questions.transform_values do |question|
            { "type" => "noul", "instructions" => question.fetch("instruction"),
              "criteria" => { "true" => question.fetch("true_criterion"),
                              "false" => question.fetch("false_criterion") } }
          end
        }
      }
      provider = judgment_provider
      result = provider.judge(request)
      @last_trace["provider_response"] = provider.last_response if provider.respond_to?(:last_response) && provider.last_response
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
        @last_trace["result"] = failure.to_h
        receipt = failure.to_h.merge("question_set_version" => question_set_version, "requested_model" => @model)
        raise Error.new(failure.error, receipt: receipt)
      end

      @last_trace["result"] = result.to_h

      {
        "provider" => result.provider, "model" => result.actual_model,
        "question_set_version" => question_set_version,
        "scores" => questions.to_h { |name, _question| [name, result.probability_true(name)] },
        "usage" => result.usage, "call_id" => result.call_id, "requested_model" => @model, "status" => result.status,
        "input_version" => state.is_a?(Hash) ? state["input_version"] : nil
      }
    rescue Error => error
      @last_trace["provider_response"] = provider.last_response if @last_trace.is_a?(Hash) && provider && provider.respond_to?(:last_response) && provider.last_response
      @last_trace["result"] ||= error.receipt if error.receipt
      raise
    rescue JudgmentRequest::Error, JudgmentResult::Error, TypeSafeJudgment::Error => error
      @last_trace["provider_response"] = provider.last_response if @last_trace.is_a?(Hash) && provider && provider.respond_to?(:last_response) && provider.last_response
      @last_trace["result"] ||= { "status" => "unavailable", "error" => error.message }
      raise Error, error.message
    rescue StandardError => error
      @last_trace["provider_response"] = provider.last_response if @last_trace.is_a?(Hash) && provider && provider.respond_to?(:last_response) && provider.last_response
      @last_trace["result"] ||= { "status" => "unavailable", "error" => "TypeSafe assessment failed: #{error.class}" }
      raise Error, "TypeSafe assessment failed: #{error.class}"
    end

    def recover_selection(state:, questions:, question_set_version:, compaction:)
      material = compaction.fetch(:material).to_s
      budget = compaction_output_budget(state: state, questions: questions,
                                        replace: compaction.fetch(:replace))
      compactor = JevInputCompactor.new(provider: judgment_provider, runner: JevCompactionRunner.new)
      attempt_traces = []
      original_judgment = nil
      run_attempt = lambda do |text|
        selected_state = if text == material
                           state
                         else
                           ModelQualityPolicy.project_selection_state(compaction.fetch(:replace).call(text))
                         end
        begin
          judgment = post_questions(state: selected_state, questions: questions, question_set_version: question_set_version)
          original_judgment = judgment if text == material
          judgment
        rescue Error => error
          original_judgment = error if text == material
          error
        ensure
          attempt_traces << JSON.parse(JSON.generate(@last_trace)) if @last_trace
        end
      end
      recovery = begin
        compactor.recover(
        purpose: compaction.fetch(:purpose), material: material, must_keep: compaction.fetch(:must_keep),
        output_budget_bytes: budget, candidates: compaction.fetch(:candidates),
        language: compaction[:language], content_type: compaction[:content_type],
        overflow: lambda { |_outcome|
          TypeSafeJudgment.max_tokens_exceeded?(@last_trace&.dig("provider_response"))
        }
        ) { |text| run_attempt.call(text) }
      rescue JevInputCompactor::Error => error
        # recover makes the original request before validating a compaction
        # budget. A zero remainder means that explicit overflow cannot fit a retry.
        raise unless budget.zero? && original_judgment

        { "status" => "unavailable", "judgment" => original_judgment,
          "first_judgment" => nil, "reason" => error.message,
          "compaction" => { "status" => "unavailable", "reason" => "no selection capacity remains" } }
      end
      result = recovery["judgment"]
      @last_trace["compaction"] = recovery["compaction"] if @last_trace.is_a?(Hash) && recovery["compaction"]
      if @last_trace.is_a?(Hash) && recovery["compaction"] && attempt_traces.first
        @last_trace["first_overflow_trace"] = attempt_traces.first
      end
      if recovery["status"] == "unavailable"
        first = recovery["first_judgment"] || recovery["judgment"]
        reason = recovery["reason"] || recovery.dig("compaction", "reason") || "JEV input compaction is unavailable"
        raise Error.new("JEV input compaction is unavailable: #{reason}", receipt: first.receipt) if first.is_a?(Error)
      end
      raise result if result.is_a?(Error)

      result
    end

    def compaction_output_budget(state:, questions:, replace:)
      empty_state = ModelQualityPolicy.project_selection_state(replace.call(""))
      wire = self.class.model_questions(questions)
      wire = wire.transform_values do |question|
        { "type" => "noul", "instructions" => question.fetch("instruction"),
          "criteria" => { "true" => question.fetch("true_criterion"),
                          "false" => question.fetch("false_criterion") } }
      end
      single = questions.keys.map do |id|
        JSON.generate("model" => @model, "state" => empty_state,
                      "questions" => { id => wire.fetch(id) }).bytesize
      end.max || 0
      total = JSON.generate("model" => @model, "state" => empty_state, "questions" => wire).bytesize
      remaining = [[SELECTION_PER_QUESTION_UTF8_UPPER_BOUND_BYTES - single,
                    SELECTION_REQUEST_UTF8_UPPER_BOUND_BYTES - total].min, 0].max
      # JSON can encode one control byte as a six-byte escape. The output
      # budget therefore reserves that worst-case expansion for the unknown
      # compactor result. This bound only sizes a retry after explicit overflow.
      remaining / 6
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

    def self.observation(inputs:, host:, members:, project_root:, artifact_digest:, elapsed_seconds:,
                         member_options: nil, member_blocks: nil, work_units: [], root_verifications: [],
                         recent_check: nil, history_cursor: nil)
      amendments = inputs.fetch("amendments", []).map { |entry| entry.fetch("text").to_s }
      user_messages = Array(inputs["jev_user_messages"])
      units = Array(work_units).select { |unit| unit.is_a?(Hash) }
      {
        "input_version" => ModelQualityPolicy::INPUT_VERSION,
        "instruction" => inputs.fetch("instruction").to_s,
        "basis_paths" => Array(inputs["basis"]).filter_map { |item| item["path"] if item.is_a?(Hash) },
        "amendments" => amendments,
        # Newly observed native user text is sent verbatim, with its task
        # relation made explicit. Seeing a message does not amend the task.
        "new_user_messages" => user_messages.map do |message|
          message.slice("id", "text", "task_relation", "observed_at")
        end,
        "member_options" => member_options,
        "member_blocks" => member_blocks_projection(member_blocks),
        "host" => host.slice("status", "turn_id", "last_turn_id", "last_turn_status", "active_tools", "async_jobs"),
        "recent_observations" => recent_execution(host["observations"], history_cursor),
        "members" => members.map do |member|
          member.slice("thread_id", "agent_id", "id", "agent", "requested_name", "kind", "adapter", "parent_id",
                       "model", "status", "work_unit_id", "tool_call_id", "error", "started_at", "finished_at",
                       "result", "result_source", "result_delivery", "settled_at", "registry_status", "activity")
        end,
        "work_units" => units.map do |unit|
          unit.slice("id", "artifact_root", "status", "objective", "requirements", "scope", "acceptance", "dependencies",
                     "member_id", "dispatches", "result", "verification", "execution")
        end,
        "root_verifications" => root_verifications_projection(root_verifications, host["observations"]),
        "recent_check" => recent_check,
        "artifact_digest" => artifact_digest,
        "changes" => scoped_changes(project_root, units, artifact_root: host["artifact_root"]),
        "elapsed_seconds" => elapsed_seconds.to_i
      }
    end

    # JEV needs to know what Root verified and whether those checks still match
    # this input/artifact version. The native receipt remains intact for the
    # checker; this projection deliberately excludes command/script and output
    # bodies from the observation judgment.
    def self.root_verifications_projection(receipts, observations)
      intents = Array(observations).flat_map do |entry|
        next [] unless entry.is_a?(Hash)

        Array(entry["tool_calls"]).filter_map do |call|
          next unless call.is_a?(Hash)

          id = call["id"].to_s
          next if id.empty?

          [id, call["declared_intent"].to_s.strip.empty? ? "unknown" : call["declared_intent"]]
        end
      end.to_h

      Array(receipts).filter_map do |receipt|
        next unless receipt.is_a?(Hash) && receipt["source"] == "omp_native_tool_result"

        projected = receipt.slice(*ROOT_VERIFICATION_FIELDS)
        call_id = receipt["tool_call_id"].to_s
        projected["intent"] = call_id.empty? ? "unknown" : intents.fetch(call_id, "unknown")
        projected
      end
    end

    # Process supervision needs the actual native intent and tool result state,
    # not Root prose, shell/eval bodies, or tool output. Keep complete records
    # supplied by OMP and preserve its omission markers.
    def self.recent_execution(observations, cursor = nil)
      source = Array(observations)
      results = source.select { |entry|
        entry.is_a?(Hash) && %w[command prior_command].include?(entry["kind"]) &&
          entry["tool_call_id"].is_a?(String) && !entry["tool_call_id"].empty?
      }.to_h { |entry| [entry["tool_call_id"], entry] }
      operations = source.flat_map do |entry|
        next [] unless entry.is_a?(Hash)

        Array(entry["tool_calls"]).filter_map do |call|
          next unless call.is_a?(Hash)

          projection = call.slice("id", "name", "declared_intent", "target", "started_at", "finished_at",
                                  "duration_ms", "status")
          result = results[projection["id"]]
          projection["status"] = result["status"] if result && result["status"]
          { "kind" => "tool_call", "turn_id" => entry["turn_id"], "message_id" => entry["message_id"],
            "tool_call" => projection }
        end
      end
      known_ids = operations.filter_map { |entry| entry.dig("tool_call", "id") }
      gaps = source.select do |entry|
        entry.is_a?(Hash) && %w[omitted_older_history history_gap].include?(entry["kind"])
      end
      if cursor.is_a?(Hash)
        cursor_id = cursor["tool_call_id"]
        cursor_index = operations.index { |entry| entry.dig("tool_call", "id") == cursor_id } if cursor_id
        if cursor_index
          operations = operations.drop(cursor_index + 1)
          gaps.reject! { |entry| entry["kind"] == "omitted_older_history" }
        else
          gaps << { "kind" => "history_gap", "reason" => cursor_id ?
            "the last checked tool call is outside the available OMP operation window" :
            "the saved checker cursor has no native tool call id" }
        end
      end
      unmatched_results = results.keys.reject { |id| known_ids.include?(id) }
      if unmatched_results.any?
        gaps << { "kind" => "operation_gap", "count" => unmatched_results.length,
                  "reason" => "tool results have no matching native tool calls in available history" }
      end
      omitted = [operations.length - 20, 0].max
      retained = operations.last(20)
      retained.unshift({ "kind" => "omitted_older_operations", "count" => omitted,
                         "count_basis" => "native tool call ids" }) if omitted.positive?
      retained.unshift(*gaps)
      retained
    end

    def self.scoped_changes(root, units, artifact_root: nil)
      scopes = Hash.new { |hash, key| hash[key] = { "paths" => [], "labels" => [] } }
      Array(units).each do |unit|
        next unless unit.is_a?(Hash)

        workspace = unit["artifact_root"].to_s
        label = unit.dig("scope", "label") || unit.dig("scope", "name") || unit["id"] || "work_unit"
        if workspace.empty?
          scopes[[nil, "work_unit_allowed_paths"]]["labels"] << label
          next
        end
        group = scopes[[workspace, "work_unit_allowed_paths"]]
        group["labels"] << label
        group["paths"].concat(Array(unit.dig("scope", "allowed_paths")).map(&:to_s).reject(&:empty?))
      end
      root_workspace = artifact_root.to_s.empty? ? root.to_s : artifact_root.to_s
      root_workspace = nil if root_workspace.empty?
      scopes[[root_workspace, "root_bound_artifact_root"]]["labels"] << "root_execution"

      { "groups" => scopes.map do |(workspace, scope), details|
          paths = details["paths"].uniq
          entry = { "scope" => workspace ? scope : "work_unit_root_unknown",
                    "scope_labels" => details["labels"].uniq }
          entry["artifact_root"] = workspace if workspace
          entry["paths"] = paths if scope == "work_unit_allowed_paths"
          if workspace && (scope == "root_bound_artifact_root" || paths.any?)
            args = scope == "root_bound_artifact_root" ? [] : paths
            entry["status"] = git_read(workspace, ["status", "--short", "--untracked-files=normal", "--", *args], 4000)
            entry["diff_stat"] = git_read(workspace, ["diff", "--no-ext-diff", "--no-textconv", "--stat", "HEAD", "--", *args], 4000)
          else
            entry["status"] = "unknown"
            entry["diff_stat"] = "unknown"
            entry["reason"] = workspace ? "no_allowed_paths_declared" : "artifact_root_unavailable"
          end
          entry
        end }
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
