# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "judgment"
require_relative "route_resource_facts"

module Orbit
  # Task-fit questions, selection input, and ranking for pool members and
  # independent checkers. Jev reads exact evidence and a catalog prior as
  # separate facts; this module never adds those numbers to a probability.
  #
  # A positive rank exists only for a release bound to the current question
  # text, input, decision, versioned model, scope, and labeled samples.
  # Structural validation does not prove those samples are real. With no
  # release, callers keep facts and a stable order; unknown route cost is
  # neither free nor a reason to drop a candidate.
  #
  # Integration surface for consumers that still call the old questions:
  #   deleted observation key: delegatable
  #   deleted score keys: time, member_fit, parallel_gain, cost_appropriate
  #   deleted wire ids: candidate_N_time, candidate_N_quality
  #   candidate wire id: candidate_N_task_fit, returned as scores[N]["quality"]
  #   delegation wire ids: handoff_fit, member_task_fit
  #   checker wire id: quality_N, and the result has no "time" key
  #   positive order binds release:, state:, judgment: and route_costs:.
  #   Route cost inputs retain the audited fact and usage composition.
  module ModelQualityPolicy
    INPUT_VERSION = "jev-selection-input-2"
    DECISION_VERSION = "orbit-quality-decision-2"
    OBSERVATION_QUESTION_SET = "jev-observation-2"
    DELEGATION_QUESTION_SET = "jev-delegation-4"
    CANDIDATE_QUESTION_SET = "jev-candidates-4"
    CHECKER_QUESTION_SET = "jev-checker-task-fit-5"
    SCHEMA_VERSION = "orbit-selection-calibration-v2"
    DEFAULT_PATH = File.join(__dir__, "data", "jev-selection-calibration.json")
    SUPPORTED_PROFILE = "bounded_git_delivery_v1"

    GATING_QUESTIONS = %w[candidate_task_fit checker_task_fit handoff_fit member_task_fit].freeze
    QUESTION_SET_VERSIONS = {
      "observation" => OBSERVATION_QUESTION_SET,
      "delegation" => DELEGATION_QUESTION_SET,
      "candidates" => CANDIDATE_QUESTION_SET,
      "checker_quality" => CHECKER_QUESTION_SET
    }.freeze
    GATING_QUESTION_SETS = {
      "candidate_task_fit" => CANDIDATE_QUESTION_SET,
      "checker_task_fit" => CHECKER_QUESTION_SET,
      "handoff_fit" => DELEGATION_QUESTION_SET,
      "member_task_fit" => DELEGATION_QUESTION_SET
    }.freeze
    SAMPLE_KINDS = %w[positive negative failure missing_evidence].freeze
    MODEL_PATTERN = /\Ajev-\d+(?:\.\d+)*(?:-[0-9A-Za-z.\-]+)?\z/
    MAX_BYTES = 256 * 1024
    MAX_SAMPLES = 64
    MAX_TEXT = 4000

    HANDOFF_TEXT = "Is there a bounded work unit in the effective requirements or remaining work that an authorized member could deliver by handoff, including a serial handoff where the main agent waits and then integrates? Do not require simultaneous work on another surface. Use the instruction, basis, amendments and any supplied work unit; do not invent a work unit that is not in the input. Count only a clear result whose dependencies the handoff can satisfy. Do not count trivial, overlapping, preference-only or dependency-blocked work. Do not use speed, latency, elapsed time, tokens per second or price. Member availability is enforced separately, so unknown availability does not lower this probability."
    MEMBER_TASK_FIT_TEXT = "Do the supplied task-related quality facts support including at least one callable member as a reasonable option for this bounded, verifiable work unit? Judge the relationship between the work and each option's sourced exact evidence or labeled model-level catalog prior. A relevant mapped catalog prior can support an initial handoff without exact-route success samples. Record unknown reasoning variants and measurement dates as limitations; they do not by themselves erase model-level support. An observed unmet task requirement or unresolved relevant conflict prevents positive support. This judges an evidence-supported option, not future delivery success or a reliability certificate. Do not infer capability from names, add indices to the answer, or judge speed or price."
    CANDIDATE_TASK_FIT_TEXT = "Do the supplied task-related quality facts support including THIS candidate as a reasonable option for the bounded, verifiable work unit? Judge the relationship between the work and this candidate's sourced exact evidence or labeled model-level catalog prior. A relevant mapped catalog prior can support an initial handoff without exact-route success samples. Serial handoff is valid. Unknown reasoning variants and measurement dates remain limitations; they do not by themselves erase model-level support. An observed unmet task requirement or unresolved relevant conflict prevents positive support. This judges an evidence-supported option, not future delivery success or a reliability certificate. Do not infer capability from names, add indices to the answer, or judge speed or price."
    CHECKER_TASK_FIT_TEXT = "Do the supplied task-related quality facts support including THIS checker as a reasonable option for independent read-only review of the bounded current task? Judge the relationship between the review requirements and sourced exact evidence or a labeled model-level catalog prior. Relevant mapped coding, agentic or intelligence facts may support an initial review without exact-route success samples. Unknown reasoning variants and measurement dates remain limitations. An observed unmet review requirement or unresolved relevant conflict prevents positive support. This judges an evidence-supported review option, not future defect detection or a reliability certificate. Do not infer capability from names, add indices to the answer, or judge speed or price."

    HANDOFF_TRUE = "The input describes a concrete work unit with its own result that can be handed off serially or while other work continues"
    HANDOFF_FALSE = "The remaining work is coupled, trivial, dependency-blocked, or no bounded handoff is described"
    FIT_TRUE = "Usable task-related catalog evidence or exact sourced quality evidence supports a reasonable handoff for this bounded, verifiable work unit. Exact route success samples are optional; this is a heuristic, not a reliability certificate."
    FIT_FALSE = "Neither usable task-related catalog support nor exact sourced quality support is supplied, relevant sources conflict, or an observed capability cannot meet the task. Missing exact route evidence alone does not establish this outcome."
    CHECKER_TRUE = "Usable task-related catalog evidence or exact sourced quality evidence supports a useful independent review of this bounded task. Exact route success samples are optional; this is a heuristic, not a reliability certificate."
    CHECKER_FALSE = "Neither usable task-related catalog support nor exact sourced quality support is supplied, relevant sources conflict, or the model cannot review this task. Missing exact route evidence alone does not establish this outcome."

    PRIOR_KEYS = %w[model_overview_prior catalog_prior overview_prior].freeze
    EVIDENCE_KEYS = %w[evidence exact_evidence].freeze
    OMITTED_STATE_KEYS = %w[elapsed_seconds time_variance_seconds local_samples comparison usage resource_calls route_costs].freeze
    SPEED_METRIC_NAME = /
      latency | elapsed | tokens?_per_s | tokens?\/s | throughput |
      time_to_first | ttft | time_tier | critical_path | e2e_time | end_to_end | duration | speed |
      (?:\A|_)time(?:_|\z) | local_samples? | parallel_gain | seconds? | wall_clock
    /ix
    PRICE_KEY = /\A(?:cost|price|pricing|quota)(?:\z|[._])/i

    module_function

    # Instruction, both criteria, and the question-set versions. A criterion
    # or version change moves the digest even when the four bodies stay put.
    def question_templates
      { "versions" => QUESTION_SET_VERSIONS,
        "handoff_fit" => handoff_question,
        "member_task_fit" => noul_question(MEMBER_TASK_FIT_TEXT, FIT_TRUE, FIT_FALSE),
        "candidate_task_fit" => noul_question(CANDIDATE_TASK_FIT_TEXT, FIT_TRUE, FIT_FALSE),
        "checker_task_fit" => noul_question(CHECKER_TASK_FIT_TEXT, CHECKER_TRUE, CHECKER_FALSE) }
    end

    def question_digest
      Digest::SHA256.hexdigest(JSON.generate(question_templates))
    end

    def binding
      { "schema_version" => SCHEMA_VERSION,
        "question_set_versions" => QUESTION_SET_VERSIONS,
        "question_digest" => question_digest,
        "input_version" => INPUT_VERSION,
        "decision_version" => DECISION_VERSION }
    end

    def noul_question(instructions, true_criterion, false_criterion)
      { "type" => "noul", "instructions" => instructions,
        "criteria" => { "true" => true_criterion, "false" => false_criterion } }
    end

    def handoff_question
      noul_question(HANDOFF_TEXT, HANDOFF_TRUE, HANDOFF_FALSE)
    end

    def delegation_questions
      {
        "handoff_fit" => handoff_question,
        "member_task_fit" => noul_question(MEMBER_TASK_FIT_TEXT, FIT_TRUE, FIT_FALSE)
      }
    end

    def candidate_questions(candidates)
      Array(candidates).each_with_index.to_h do |candidate, index|
        agent = candidate.is_a?(Hash) ? candidate["agent"] : nil
        provider = candidate.is_a?(Hash) ? (candidate["provider"] || candidate.dig("identity", "provider")) : nil
        model = candidate.is_a?(Hash) ? candidate["model"] : nil
        model_id = provider.to_s.empty? || model.to_s.start_with?("#{provider}/") ? model : "#{provider}/#{model}"
        label = "candidate #{index} (agent #{agent}, model #{model_id}): "
        ["candidate_#{index}_task_fit", noul_question(label + CANDIDATE_TASK_FIT_TEXT, FIT_TRUE, FIT_FALSE)]
      end
    end

    def checker_questions(candidates)
      Array(candidates).each_with_index.to_h do |candidate, index|
        model = candidate.is_a?(Hash) ? candidate["model"] : candidate
        label = "Checker candidate #{model}: "
        ["quality_#{index}", noul_question(label + CHECKER_TASK_FIT_TEXT, CHECKER_TRUE, CHECKER_FALSE)]
      end
    end

    # Judgment input for selection questions. Catalog priors and exact facts
    # are labeled once. Every call strips speed, elapsed time, coarse tiers
    # and prices, including an envelope that already claims to be projected.
    def project_selection_state(state)
      return empty_projection unless state.is_a?(Hash)

      omitted = []
      if envelope?(state)
        omitted.concat(Array(state["omitted_from_judgment"]).map(&:to_s))
        context = strip_tree(state["task_context"], omitted)
        priors = Array(state["catalog_priors"]).map { |item| label_prior(item, omitted) }
        exact = Array(state["exact_evidence"]).map { |item| label_evidence(item, omitted) }
      else
        priors = []
        exact = []
        context = strip_tree(sanitize(state, omitted, priors, exact), omitted)
      end
      { "input_version" => INPUT_VERSION, "combination" => "none",
        "task_context" => context, "catalog_priors" => priors, "exact_evidence" => exact,
        "omitted_from_judgment" => omitted.uniq.sort }
    end

    def load(path = DEFAULT_PATH)
      return nil unless File.file?(path)
      return "selection calibration exceeds the bounded release size" if File.size(path) > MAX_BYTES

      validate(JSON.parse(File.read(path, MAX_BYTES + 1)))
    rescue JSON::ParserError, SystemCallError
      "selection calibration file is unreadable or not valid JSON"
    end

    # A finite structure profile, derived from task facts rather than copied
    # from the release. Concrete paths and acceptance text remain in the
    # judgment input; they do not turn every task into its own profile.
    def profile_for(state)
      return nil unless state.is_a?(Hash)

      context = envelope?(state) ? state["task_context"] : state
      return nil unless context.is_a?(Hash)

      workspace = context["workspace"]
      return nil unless workspace.is_a?(Hash) && workspace.dig("project", "git") == true

      unit = context["work_unit"]
      acceptance = unit.is_a?(Hash) ? unit["acceptance"] : context["acceptance"]
      return nil unless bounded_text?(acceptance) ||
                        (acceptance.is_a?(Array) && !acceptance.empty? && acceptance.all? { |item| bounded_text?(item) })

      paths = unit.is_a?(Hash) && unit.dig("scope", "allowed_paths")
      bounded_unit = unit.is_a?(Hash) && bounded_text?(unit["objective"]) &&
        paths.is_a?(Array) && !paths.empty? && paths.all? { |item| bounded_text?(item) }
      bounded_artifact = %w[reviewer process_reviewer adjudicator].include?(context["review_role"]) &&
        workspace["artifact_root"].is_a?(String) && !workspace["artifact_root"].empty?
      bounded_unit || bounded_artifact ? SUPPORTED_PROFILE : nil
    end

    # Why a release cannot activate, for diagnosis: "no_reviewed_release",
    # "task_profile_mismatch" or "judgment_mismatch". nil means the release
    # activates. This is the single activation rule; activated_release is a
    # thin wrapper so the two can never disagree.
    def activation_block(release:, judgment:, state:)
      active = ranking_release(release)
      return "no_reviewed_release" unless active
      return "task_profile_mismatch" unless profile_for(state) == active["scope"]
      return "judgment_mismatch" unless judgment.is_a?(Hash) && judgment["status"] == "answered" &&
                                        judgment["provider"] == active["provider"] &&
                                        judgment["model"] == active["model"] &&
                                        judgment["input_version"] == INPUT_VERSION &&
                                        QUESTION_SET_VERSIONS.values.include?(judgment["question_set_version"])

      nil
    end

    def activated_release(release:, judgment:, state:)
      activation_block(release: release, judgment: judgment, state: state).nil? ? ranking_release(release) : nil
    end

    # A matching document is a release binding. It does not prove the embedded
    # samples happened, and this method never invents a release.
    def validate(data)
      return "selection calibration must be a JSON object" unless data.is_a?(Hash)
      unless binding.all? { |key, value| data[key] == value }
        return "selection calibration does not match the current questions, input and decision"
      end

      model = data["model"].to_s
      return "selection calibration model must be a versioned id; jev-latest is rejected" unless model.match?(MODEL_PATTERN)
      return "selection calibration provider must be typesafe" unless data["provider"] == "typesafe"

      thresholds = data["thresholds"]
      unless thresholds.is_a?(Hash) && thresholds.keys.sort == GATING_QUESTIONS &&
             thresholds.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? && value <= 1 }
        return "selection calibration needs exactly the current finite thresholds in (0, 1]"
      end

      release = data["release"]
      unless release.is_a?(Hash) && %w[reason scope reviewed_by reviewed_at].all? { |field| bounded_text?(release[field]) }
        return "selection calibration needs its scope, review and release reason"
      end
      return "selection calibration needs a supported observable task profile" unless release["scope"] == SUPPORTED_PROFILE
      Time.iso8601(release.fetch("reviewed_at"))

      samples = data["samples"]
      unless samples.is_a?(Array) && samples.length.between?(SAMPLE_KINDS.length, MAX_SAMPLES)
        return "selection calibration needs labeled positive, negative, failure and missing-evidence samples"
      end
      unless (SAMPLE_KINDS - samples.filter_map { |sample| sample["kind"] if sample.is_a?(Hash) }).empty?
        return "selection calibration needs labeled positive, negative, failure and missing-evidence samples"
      end
      ids = samples.map { |sample| sample.is_a?(Hash) && sample["id"] }
      unless ids.all? { |id| id.is_a?(String) && !id.strip.empty? } && ids.uniq.length == ids.length &&
             samples.all? { |sample| valid_sample?(sample, model, thresholds, release["scope"]) } &&
             GATING_QUESTIONS.all? { |question| covered?(samples, question) }
        return "selection calibration samples do not support the released model and decision rule"
      end

      { "model" => model, "provider" => "typesafe", "thresholds" => thresholds,
        "scope" => release["scope"],
        "question_set_versions" => QUESTION_SET_VERSIONS,
        "question_digest" => question_digest,
        "input_version" => INPUT_VERSION,
        "decision_version" => DECISION_VERSION,
        "structural_validation" => "passed",
        "proves_samples_real" => false,
        "allows_positive_ranking" => true,
        "release" => release.slice("reason", "scope", "reviewed_by", "reviewed_at").merge(
          "sample_count" => samples.length,
          "sample_digest" => Digest::SHA256.hexdigest(JSON.generate(samples))
        ) }
    rescue ArgumentError
      "selection calibration has an invalid review date"
    end

    # Clear the released task-fit bar, then use comparable route estimates.
    # Tiny probability differences are not a reliability certificate. Without
    # comparable estimates the judgment is a heuristic preference only.
    def order(candidates, release: nil, route_costs: nil, state: nil, judgment: nil)
      list = Array(candidates).each_with_index.map { |candidate, index| annotate(candidate, index) }
      active = activated_release(release: release, judgment: judgment, state: state)
      list.each do |item|
        item["positive"] = !!(active && !item["recommendation_hold"] &&
                              GATING_QUESTION_SETS[item["question"]] == judgment["question_set_version"] &&
                              released_score?(item, active))
      end
      positives = list.select { |item| item["positive"] }
      if positives.empty?
        reason = case active.nil? ? activation_block(release: release, judgment: judgment, state: state) : nil
                 when "no_reviewed_release"
                   "no reviewed release; scores and route cost are not a positive ranking"
                 when "task_profile_mismatch"
                   "a reviewed release exists but this task is outside its released profile; scores and route cost are not a positive ranking"
                 when "judgment_mismatch"
                   "a reviewed release covers this task profile but the judgment is unanswered or from another provider, model, input version or question set"
                 else
                   if judgment.is_a?(Hash) &&
                      list.none? { |item| GATING_QUESTION_SETS[item["question"]] == judgment["question_set_version"] }
                     "the judgment answered a different question set than these candidates"
                   else
                     "no candidate cleared a release for this task profile and actual judgment model"
                   end
                 end
        return order_result(list.sort_by { |item| item["index"] }, positive: false, basis: "pool_order_unreleased",
                            cost_comparison: "not_applied", positive_ids: [], reason: reason)
      end

      relation = cost_relation(positives, route_costs.is_a?(Hash) ? route_costs : {})
      ranked = positives.sort_by do |item|
        estimate = relation["estimates"][item["id"]]
        cost_key = relation["comparable"] && estimate ? estimate["amount"] : 0
        relation["comparable"] ? [cost_key, -item["quality"], item["index"]] : [-item["quality"], item["index"]]
      end
      tail = list.reject { |item| item["positive"] }.sort_by { |item| item["index"] }
      basis = relation["comparable"] ? "released_task_fit_then_route_cost_heuristic" : "released_task_fit"
      comparison = if relation["comparable"]
                     "heuristic"
                   elsif relation["notes"].all? { |note| note.end_with?("cost unknown") }
                     "unknown"
                   else
                     "incomparable"
                   end
      order_result(ranked + tail, positive: true, basis: basis, cost_comparison: comparison,
                   cost_notes: relation["notes"], positive_ids: ranked.map { |item| item["id"] },
                   cost_estimates: relation["estimates"],
                   reason: relation["comparable"] ?
                     "released task-fit signal; comparable route estimates prefer lower resource cost, without treating a probability as measured reliability" :
                     "released task-fit signal; route costs are not comparable, so task fit determines the order")
    end

    def ranking_release(release)
      return nil unless release.is_a?(Hash)
      return nil unless release["allows_positive_ranking"] == true && release["proves_samples_real"] == false
      return nil unless release["decision_version"] == DECISION_VERSION && release["input_version"] == INPUT_VERSION
      return nil unless release["question_digest"] == question_digest
      return nil unless release["question_set_versions"] == QUESTION_SET_VERSIONS
      return nil unless release["structural_validation"] == "passed" && release["provider"] == "typesafe"
      return nil unless release["model"].is_a?(String) && release["model"].match?(MODEL_PATTERN)
      return nil unless release["thresholds"].is_a?(Hash) && release["thresholds"].keys.sort == GATING_QUESTIONS &&
                        release["thresholds"].values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? && value <= 1 }
      return nil unless release["scope"] == SUPPORTED_PROFILE

      release
    end

    def envelope?(state)
      state["input_version"] == INPUT_VERSION && state["combination"] == "none" && state.key?("task_context")
    end

    def strip_tree(value, omitted)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          name = key.to_s
          if OMITTED_STATE_KEYS.include?(name) || name.match?(PRICE_KEY) || name.match?(SPEED_METRIC_NAME)
            omitted << name
          else
            out[name] = strip_tree(item, omitted)
          end
        end
      when Array
        value.map { |item| strip_tree(item, omitted) }
      else
        value
      end
    end

    def empty_projection
      { "input_version" => INPUT_VERSION, "combination" => "none", "task_context" => {},
        "catalog_priors" => [], "exact_evidence" => [], "omitted_from_judgment" => [] }
    end

    def sanitize(value, omitted, priors, exact)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          name = key.to_s
          if OMITTED_STATE_KEYS.include?(name) || name.match?(PRICE_KEY) || name.match?(SPEED_METRIC_NAME)
            omitted << name
          elsif PRIOR_KEYS.include?(name)
            priors << label_prior(item, omitted)
            out[name] = { "see" => "catalog_priors", "index" => priors.length - 1 }
          elsif EVIDENCE_KEYS.include?(name)
            exact << label_evidence(item, omitted)
            out[name] = { "see" => "exact_evidence", "index" => exact.length - 1 }
          elsif name == "metrics" && item.is_a?(Hash)
            out[name] = filter_metrics(item, omitted)
          else
            out[name] = sanitize(item, omitted, priors, exact)
          end
        end
      when Array
        value.map { |item| sanitize(item, omitted, priors, exact) }
      else
        value
      end
    end

    def label_prior(value, omitted)
      facts = value.is_a?(Hash) ? value : {}
      kept = {}
      facts.each do |key, item|
        name = key.to_s
        if name.match?(PRICE_KEY) || name.match?(SPEED_METRIC_NAME)
          omitted << "catalog_prior.#{name}"
        else
          kept[name] = strip_tree(item, omitted)
        end
      end
      kept.merge("role" => "model_level_catalog_prior", "not_an_omp_route_price" => true,
                 "not_a_weighted_input" => true)
    end

    def label_evidence(value, omitted)
      entry = value.is_a?(Hash) ? value : {}
      entry.each_key do |key|
        name = key.to_s
        omitted << "exact_evidence.#{name}" if name.match?(PRICE_KEY) || name.match?(SPEED_METRIC_NAME)
      end
      metrics = entry["metrics"].is_a?(Hash) ? filter_metrics(entry["metrics"], omitted) : {}
      entry.slice("provider", "model", "reasoning", "billing_route", "identity", "status", "sources",
                  "retrieved_at", "valid_until", "measurement_date", "methodology", "reason").merge(
        "role" => "exact_evidence", "metrics" => metrics, "not_a_weighted_input" => true
      )
    end

    def filter_metrics(metrics, omitted)
      metrics.each_with_object({}) do |(key, metric), out|
        name = key.to_s
        if name.match?(SPEED_METRIC_NAME) || name.match?(PRICE_KEY)
          omitted << "metrics.#{name}"
        else
          out[name] = strip_tree(metric, omitted)
        end
      end
    end

    def annotate(candidate, index)
      item = candidate.is_a?(Hash) ? candidate : {}
      score = item["quality"]
      score = nil unless score.is_a?(Numeric) && score.finite? && score.between?(0, 1)
      { "id" => item["id"].to_s, "index" => index, "quality" => score,
        "question" => item["question"].to_s, "positive" => false,
        "recommendation_hold" => item["recommendation_hold"] == true, "identity" => item["identity"] }
    end

    def released_score?(item, release)
      threshold = release["thresholds"][item["question"]]
      item["quality"].is_a?(Numeric) && threshold.is_a?(Numeric) && item["quality"] >= threshold
    end

    def cost_relation(items, route_costs)
      estimates = {}
      notes = []
      comparison_eligible = true
      items.each do |item|
        input = route_costs[item["id"]]
        estimate, note = resolve_route_cost(input)
        if estimate && item["identity"].is_a?(Hash) && estimate["route"] != item["identity"]
          estimate, note = nil, "priced route does not match this candidate identity"
        end
        # A Root-declared token mix is an explicit what-if estimate, not
        # attributable usage. Keep its arithmetic visible, but do not turn it
        # into an automatic preference between crossed input/output prices.
        if estimate && input.is_a?(Hash) && input.dig("prediction", "kind") == "declared_workload"
          comparison_eligible = false
          note = "declared workload has no attributed usage sample; estimate is conditional only"
        end
        estimates[item["id"]] = estimate
        notes << "#{item['id']}: #{note}" if note
      end
      comparable = comparison_eligible && items.length > 1 && items.combination(2).all? do |left, right|
        RouteResourceFacts.compare(estimates[left["id"]], estimates[right["id"]])["verdict"] != "indeterminate"
      end
      comparable &&= items.all? { |item| estimates[item["id"]].is_a?(Hash) && estimates[item["id"]]["status"] == "priced" }
      { "comparable" => comparable, "estimates" => estimates, "notes" => notes }
    end

    # Recalculate from the retained audited route fact and usage composition.
    # A hash merely labeled "priced" has no provenance to validate.
    def resolve_route_cost(value)
      return [nil, "cost unknown"] if value.nil?
      return [nil, "route cost is not a validated resource estimate"] unless value.is_a?(Hash)
      return estimate_from_fact(value) if value.key?("fact")
      return [nil, "a stated total without a RouteResourceFacts estimate is not comparable"] if value["total"] || value["source"] || value["band"] || value["tier"]

      [nil, "a priced-looking total without its verifiable route fact cannot be compared"]
    end

    def estimate_from_fact(value)
      fact = RouteResourceFacts.from(value["fact"])
      at = value["at"] ? Time.iso8601(value["at"]) : nil
      result = fact.estimate(route: value["observed_route"] || value["route"], usage: value["usage"],
                             account_scope: value["account_scope"],
                             usage_source: value["usage_source"] || "recorded_calls", at: at)
      return [nil, "route estimate is #{result['status']}: #{result['reason']}"] unless result["status"] == "priced"

      [result.merge("source_fact" => fact.document, "prediction" => value["prediction"]), nil]
    rescue RouteResourceFacts::Error, ArgumentError => error
      [nil, "route fact did not validate: #{error.message}"]
    end

    def order_result(items, positive:, basis:, cost_comparison:, reason:, cost_notes: [], positive_ids: [], cost_estimates: {})
      visible = cost_estimates.filter_map do |id, estimate|
        next unless estimate.is_a?(Hash) && estimate["status"] == "priced"
        [id, estimate.slice("status", "amount", "currency", "account_scope", "route", "valid_at", "usage_source", "categories",
                            "source_fact", "prediction")]
      end.to_h
      { "version" => DECISION_VERSION, "positive" => positive, "basis" => basis,
        "ordered_ids" => items.map { |item| item["id"] }, "positive_ids" => positive_ids,
        "cost_comparison" => cost_comparison, "cost_notes" => cost_notes, "cost_estimates" => visible,
        "reason" => reason, "proves_samples_real" => false, "cost_is_capability_measurement" => false }
    end

    def covered?(samples, question)
      %w[positive negative].all? do |kind|
        samples.any? { |sample| sample.is_a?(Hash) && sample["kind"] == kind && sample["question"] == question }
      end
    end

    def valid_sample?(sample, model, thresholds, scope)
      return false unless sample.is_a?(Hash) && SAMPLE_KINDS.include?(sample["kind"]) && sample["mode"] == "model_backed"
      return false unless GATING_QUESTIONS.include?(sample["question"])
      return false unless [true, false].include?(sample["expected_positive"])
      return false unless projected_sample_state?(sample["state"], scope)
      return false unless sample["requested_model"] == model
      return false unless sample["question_set_version"] == GATING_QUESTION_SETS[sample["question"]]
      questions = sample_questions(sample)
      wire = sample["wire_question"]
      return false unless questions && sample["questions"] == questions && questions.key?(wire)

      judgment = sample["judgment"]
      return false unless judgment.is_a?(Hash) && judgment["schema_version"] == JudgmentResult::SCHEMA_VERSION &&
                          judgment.dig("source", "provider") == "typesafe"
      return false unless judgment["call_id"].is_a?(String) && !judgment["call_id"].empty?
      actual = judgment.dig("source", "actual_model")
      if sample["kind"] == "failure"
        return sample["expected_positive"] == false && judgment["status"] == "unavailable" &&
               [nil, model].include?(actual) && (judgment["answers"].nil? || judgment["answers"] == {}) &&
               judgment["error"].is_a?(String) && !judgment["error"].empty?
      end
      return false unless judgment["status"] == "answered" && actual == model

      return false unless questions.keys.all? do |id|
        answer = judgment.dig("answers", id, "probability_true")
        answer.is_a?(Numeric) && answer.finite? && answer.between?(0, 1)
      end
      score = judgment.dig("answers", wire, "probability_true")
      return false unless score.is_a?(Numeric) && score.finite? && score.between?(0, 1)
      passed = score >= thresholds.fetch(sample["question"])
      evidence = sample.dig("state", "exact_evidence")
      case sample["kind"]
      when "missing_evidence"
        return false unless evidence.empty? && sample.dig("state", "catalog_priors").empty? && !passed
      when "positive"
        return false unless passed
      when "negative"
        return false unless !passed
      end

      passed == sample["expected_positive"]
    end

    # Retain the exact input, dynamic wire question id and full questions.
    # Renaming quality_0 to checker_task_fit would falsify the API receipt.
    def sample_questions(sample)
      candidates = sample.dig("state", "task_context", "candidates")
      case sample["question"]
      when "candidate_task_fit"
        return nil unless candidates.is_a?(Array) && !candidates.empty? && sample["wire_question"].to_s.match?(/\Acandidate_\d+_task_fit\z/)
        candidate_questions(candidates)
      when "checker_task_fit"
        return nil unless candidates.is_a?(Array) && !candidates.empty? && sample["wire_question"].to_s.match?(/\Aquality_\d+\z/)
        checker_questions(candidates)
      else
        return nil unless sample["wire_question"] == sample["question"]
        delegation_questions
      end
    end

    def projected_sample_state?(state, scope)
      return false unless state.is_a?(Hash) && profile_for(state) == scope
      allowed = %w[catalog_priors combination exact_evidence input_version omitted_from_judgment task_context]
      return false unless (state.keys - allowed).empty?
      sent = project_selection_state(state)
      %w[input_version combination task_context catalog_priors exact_evidence omitted_from_judgment].all? do |key|
        sent[key] == state[key]
      end
    end

    def bounded_text?(value)
      value.is_a?(String) && !value.strip.empty? && value.length <= MAX_TEXT
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
