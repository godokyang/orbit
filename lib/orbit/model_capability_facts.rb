# frozen_string_literal: true

require_relative "model_evidence_cache"
require_relative "openrouter_model_overview"

module Orbit
  # Shared read-only projection of task-relevant model capability facts for
  # member selection, checker selection and Root review (主方案 §8/§10, 审计
  # B02/B05/B08/B10/B11). It combines, per exact OMP execution identity, the
  # two evidence classes that already exist locally:
  #
  #   catalog (OpenRouterModelOverview): model-catalog scope facts and, only
  #     when the task names relevant benchmark indices, a weak model-level
  #     prior. Benchmark values are third-party Artificial Analysis numbers
  #     with no measurement date and no method version; the 72-hour snapshot
  #     TTL is a fetch freshness, never a measurement date.
  #   precise evidence (ModelEvidenceCache): exact-identity facts submitted by
  #     Root with their own retrieval/validity dates, including recorded
  #     "unavailable" states.
  #
  # Both classes are always presented together when both exist — never an
  # if/else — each labeled with the question it answers, its configuration and
  # its dates. A same-identity, same-index numeric divergence beyond the
  # documented flag threshold is marked as a POTENTIAL conflict lead: the two
  # measurements carry no comparable unit, method version or measurement date,
  # so the divergence alone is not a verdict on which side is true. The
  # candidate's automatic positive recommendation is held
  # (recommendation_hold=true) and resolution is explicitly "root_review". A
  # recorded exact-identity unavailability next to a model-level prior, or a
  # below-threshold divergence, is a contrast: both sides stay visible, but
  # per ADR-009 §6.1 that difference is not automatically a contradiction and
  # nothing is auto-resolved by source name. No catalog score ever silently
  # covers a precise record.
  #
  # Task requirements are explicit input: relevant benchmark indices,
  # context/modality/supported-parameter needs and an optional measurement-
  # date requirement. An unclassified task (no indices) receives facts only.
  # Eligibility results are catalog-scope judgments: a catalog context length
  # is the model-level upper bound and never covers a possibly smaller actual
  # route limit (e.g. a 256K route variant under a 1M catalog row), and a
  # catalog parameter listing is not proof the host grants that tool at
  # runtime; both distinctions stay in the notes.
  #
  # Selection-input hygiene: metrics whose names carry time or local-sample
  # signals (speed/latency/elapsed/duration/throughput/ttft/per_second/
  # seconds/time/local_sample, matched anywhere, so names like
  # local_sample_latency_ms or end_to_end_seconds are covered) are stripped
  # from projected evidence entries so new selection inputs never consume
  # them (审计 C04); the archived cache entries on disk are unchanged.
  # cost.*/quota.* metrics and cost_tier are excluded outright: trusted route
  # resource facts live in the independent RouteResourceFacts layer, and this
  # projection never re-presents the raw cache cost fields as verified. The
  # projection performs no network I/O and no writes; all bounds are fixed
  # constants.
  class ModelCapabilityFacts
    VERSION = "orbit-capability-facts-v1"

    BENCHMARK_KEYS = Orbit::OpenRouterModelOverview::BENCHMARK_KEYS

    MAX_CANDIDATES = 64
    MAX_REQUIREMENT_ITEMS = 8
    MAX_REQUIREMENT_NAME_LENGTH = 64
    MAX_CONTEXT_TOKENS = 10_000_000
    MAX_NOTE_LENGTH = 300

    IDENTIFIER_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:+@\/-]*\z/
    REASONING_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
    BILLING_ROUTES = %w[direct_api subscription_quota unknown].freeze

    # Deterministic flag policy, not a measurement verdict: a same-name
    # benchmark value diverging from the catalog value by more than 25%
    # relative and more than one index point absolute is surfaced as a
    # POTENTIAL conflict lead for Root review. The two measurements carry no
    # comparable unit, method version or measurement date, so the divergence
    # alone proves neither side wrong; both sides stay visible, the
    # candidate's automatic positive recommendation is held and nothing is
    # resolved by source name.
    CONFLICT_RELATIVE_DIVERGENCE = 0.25
    CONFLICT_ABSOLUTE_FLOOR = 1.0

    # The selection-time denylist and the resource namespace live in the cache,
    # which is also the submission gate; this projection re-applies the same
    # predicates so an archived metric can never enter a new selection input.

    EVIDENCE_QUESTION = "该精确身份（provider/model/reasoning/billing_route）的可得事实或记录的不可用状态；提交者检索，含检索日期与有效期"
    CATALOG_QUESTION = "模型级第三方基准指数与目录能力；无测量日期与方法版本，不代表本执行路由的限制、价格或耗时"

    class Error < StandardError; end

    def initialize(overview:, evidence_cache:)
      @overview = overview
      @evidence_cache = evidence_cache
    end

    # Bounded projection for one candidate identity. `identity` carries the
    # four explicit identity fields; `task` carries the explicit task
    # requirements. Returns the Hash documented above.
    def candidate_facts(identity:, task:, project_root:, execution_limits: nil)
      who = normalize_identity(identity)
      needs = normalize_task(task)

      catalog = catalog_projection(who, needs, project_root)
      precise = precise_projection(who)
      eligibility = eligibility_projection(needs, catalog["facts"])
      execution = execution_eligibility(needs, execution_limits)
      conflicts, contrasts = evidence_relations(catalog, precise, needs)

      execution_gaps = execution.values.select { |item| %w[unmet unknown].include?(item["status"]) }
      date = measurement_date_eligibility(needs, catalog, precise)
      held_date = %w[hold unknown].include?(date["status"]) && needs["require_measurement_date"]
      hold = conflicts.any? || execution_gaps.any? || held_date
      {
        "identity" => who,
        "task" => needs,
        "catalog" => catalog,
        "precise_evidence" => precise,
        "eligibility" => eligibility,
        "execution_eligibility" => execution,
        "measurement_date" => date,
        "conflicts" => conflicts,
        "contrasts" => contrasts,
        "recommendation_hold" => hold,
        "hold_reason" => if conflicts.any?
                           "精确证据与目录先验出现同名指标潜在冲突线索（测量单位/方法/日期不明，非真伪裁定）；暂停该候选自动正向推荐，交 Root 复核"
                         elsif execution_gaps.any?
                           "本 OMP 路由的执行限制不满足或尚未核实当前要求；目录上限不代替实际限制，交 Root 复核"
                         elsif held_date
                           "任务要求已知基准测量日期，但没有任何可核验来源提供测量日期；抓取日期不能代替测量日期，交 Root 复核"
                         end
      }
    end

    # Projection for a bounded candidate list, preserving the input order
    # (which is a caller-chosen stable order, never a quality or cost rank).
    def pool_facts(identities:, task:, project_root:)
      list = identities.is_a?(Array) ? identities : [identities]
      raise Error, "候选身份列表必须非空" if list.empty?
      raise Error, "候选身份最多 #{MAX_CANDIDATES} 个" if list.length > MAX_CANDIDATES

      {
        "version" => VERSION,
        "task" => normalize_task(task),
        "candidates" => list.map { |identity| candidate_facts(identity: identity, task: task, project_root: project_root) }
      }
    end

    private

    # The host has resolved this exact execution identity. Unknown fields
    # stay unknown; a model-level catalog row cannot fill them in.
    def execution_eligibility(task, limits)
      known = limits.is_a?(Hash) && limits["source"] == "omp_model_registry" ? limits : {}
      required = task["required_context_tokens"]
      window = known["context_window"]
      window = nil unless window.is_a?(Integer) && window.positive?
      modalities = known["input_modalities"]
      input = Array(task["required_input_modalities"])
      output = Array(task["required_output_modalities"])
      output_values = known["output_modalities"]
      parameters = Array(task["required_parameters"])
      {
        "context" => { "status" => required.nil? ? "not_required" : (window.nil? ? "unknown" : (window >= required ? "met" : "unmet")),
                       "requirement" => required, "configured_limit" => window, "source" => known["source"] },
        "input_modalities" => { "status" => input.empty? ? "not_required" : (!modalities.is_a?(Array) || modalities.empty? ? "unknown" : ((input - modalities).empty? ? "met" : "unmet")),
                                "requirement" => input, "configured_values" => modalities },
        "output_modalities" => { "status" => output.empty? ? "not_required" : (!output_values.is_a?(Array) || output_values.empty? ? "unknown" : ((output - output_values).empty? ? "met" : "unmet")),
                                 "requirement" => output, "configured_values" => output_values },
        "parameters" => { "status" => if parameters.empty?
                                        "not_required"
                                      elsif parameters == ["tools"] && [true, false].include?(known["supports_tools"])
                                        known["supports_tools"] ? "met" : "unmet"
                                      else
                                        "unknown"
                                      end,
                          "requirement" => parameters, "note" => "模型工具支持不代替成员实际工具授权" }
      }
    end

    def normalize_identity(identity)
      raise Error, "候选身份必须是对象" unless identity.is_a?(Hash)

      fields = identity.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      unknown = fields.keys - %w[provider model reasoning billing_route]
      raise Error, "候选身份含不支持的字段：#{unknown.sort.join(', ')}" unless unknown.empty?

      provider = identifier(fields["provider"], "provider", 64)
      model = identifier(fields["model"], "model", 200)
      reasoning = fields["reasoning"].to_s.strip
      unless reasoning.length.between?(1, 64) && reasoning.match?(REASONING_PATTERN)
        raise Error, "reasoning 必须是显式的短标签（unknown 与 default 不互换）"
      end
      billing_route = fields["billing_route"].to_s.strip
      raise Error, "billing_route 必须是 #{BILLING_ROUTES.join('、')} 之一" unless BILLING_ROUTES.include?(billing_route)

      { "provider" => provider, "model" => model, "reasoning" => reasoning, "billing_route" => billing_route }
    end

    def identifier(value, field, max)
      text = value.to_s.strip
      unless text.length.between?(1, max) && text.match?(IDENTIFIER_PATTERN)
        raise Error, "#{field} 必须是有效标识符"
      end

      text
    end

    def normalize_task(task)
      raise Error, "任务需求必须是对象" unless task.is_a?(Hash)

      fields = task.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      unknown = fields.keys - %w[relevant_indices required_context_tokens required_input_modalities
                                 required_output_modalities required_parameters require_measurement_date]
      raise Error, "任务需求含不支持的字段：#{unknown.sort.join(', ')}" unless unknown.empty?

      indices = requirement_list(fields["relevant_indices"], "relevant_indices", allow_empty: true)
      unless (indices - BENCHMARK_KEYS).empty?
        raise Error, "任务指标必须明确选自 #{BENCHMARK_KEYS.join('、')}"
      end

      context = fields["required_context_tokens"]
      if context.nil?
        context = nil
      elsif context.is_a?(Integer) && context.positive? && context <= MAX_CONTEXT_TOKENS
        context = context
      else
        raise Error, "required_context_tokens 必须是 1..#{MAX_CONTEXT_TOKENS} 的整数或省略"
      end

      require_date = fields["require_measurement_date"]
      require_date = false if require_date.nil?
      raise Error, "require_measurement_date 必须是布尔值" unless [true, false].include?(require_date)

      {
        "relevant_indices" => indices.uniq,
        "required_context_tokens" => context,
        "required_input_modalities" => requirement_list(fields["required_input_modalities"], "required_input_modalities", allow_empty: true).uniq,
        "required_output_modalities" => requirement_list(fields["required_output_modalities"], "required_output_modalities", allow_empty: true).uniq,
        "required_parameters" => requirement_list(fields["required_parameters"], "required_parameters", allow_empty: true).uniq,
        "require_measurement_date" => require_date
      }
    end

    def requirement_list(value, field, allow_empty:)
      return [] if value.nil?
      unless value.is_a?(Array) && value.length <= MAX_REQUIREMENT_ITEMS &&
             value.all? { |entry| entry.is_a?(String) && entry.length.between?(1, MAX_REQUIREMENT_NAME_LENGTH) }
        raise Error, "#{field} 必须是最多 #{MAX_REQUIREMENT_ITEMS} 个短字符串"
      end
      raise Error, "#{field} 不能为空" if value.empty? && !allow_empty

      value
    end

    # The overview lookup stays the single owner of mapping, drift, benchmark
    # and measurement-date gates; this projection never re-implements them.
    def catalog_projection(identity, task, project_root)
      result = @overview.lookup(model: "#{identity.fetch('provider')}/#{identity.fetch('model')}",
                                reasoning: identity.fetch("reasoning"),
                                billing_route: identity.fetch("billing_route"),
                                project_root: project_root,
                                indices: task.fetch("relevant_indices"),
                                require_measurement_date: task.fetch("require_measurement_date"))
      projection = {
        "status" => result.fetch("status"),
        "question" => CATALOG_QUESTION,
        "facts" => result["facts"],
        "prior" => result["prior"],
        "provenance" => nil
      }
      if result["facts"] || result["prior"]
        provenance = @overview.mapping_provenance(model: "#{identity.fetch('provider')}/#{identity.fetch('model')}",
                                                  reasoning: identity.fetch("reasoning"),
                                                  billing_route: identity.fetch("billing_route"),
                                                  project_root: project_root)
        projection["provenance"] = provenance
      end
      projection
    rescue Orbit::OpenRouterModelOverview::Error => error
      { "status" => "error", "question" => CATALOG_QUESTION, "facts" => nil, "prior" => nil,
        "provenance" => nil, "detail" => bounded(error.message) }
    end

    def precise_projection(identity)
      entry = begin
        @evidence_cache.lookup(provider: identity.fetch("provider"), model: identity.fetch("model"),
                               reasoning: identity.fetch("reasoning"), billing_route: identity.fetch("billing_route"))
      rescue Orbit::ModelEvidenceCache::Error => error
        return { "status" => "error", "question" => EVIDENCE_QUESTION, "entry" => nil, "detail" => bounded(error.message) }
      end
      return { "status" => "none", "question" => EVIDENCE_QUESTION, "entry" => nil } unless entry.is_a?(Hash)

      measured_at = entry["measured_at"]
      projected = {
        "identity" => identity,
        "status" => entry.fetch("status"),
        "sources" => entry["sources"],
        "retrieved_at" => entry.fetch("retrieved_at"),
        "valid_until" => entry.fetch("valid_until"),
        "evidence_scope" => "exact_identity",
        # The measurement date of the reported values is stated explicitly and
        # never filled in from the retrieval date; the method version is stated
        # as the submitter recorded it. An omitted version or date stays unknown.
        "measurement_date" => measured_at,
        "measurement_date_status" => measured_at.is_a?(String) ? "known" : "unknown",
        "method_version" => entry["method_version"]
      }
      if entry.fetch("status") == Orbit::ModelEvidenceCache::STATUS_EVIDENCE
        projected["metrics"] = (entry["metrics"] || {}).reject do |name, _|
          Orbit::ModelEvidenceCache.legacy_selection_metric?(name) || Orbit::ModelEvidenceCache.resource_metric?(name)
        end
      else
        projected["reason"] = entry["reason"]
      end
      { "status" => entry.fetch("status"), "question" => EVIDENCE_QUESTION, "entry" => projected }
    end

    # A required, known benchmark measurement date is satisfied only by a
    # verifiable precise measurement date. Precise evidence without one is held,
    # exactly as a catalog row that carries no date is; a catalog fetch date is
    # never a measurement date. When neither class carries any fact, there is
    # nothing to qualify and the facts are simply shown.
    def measurement_date_eligibility(task, catalog, precise)
      required = task["require_measurement_date"] == true
      entry = precise["entry"]
      precise_status = precise["status"]
      # The projection states the measurement date under measurement_date; there
      # is no other source, and a fetch date never substitutes for it.
      measured_at = entry.is_a?(Hash) ? entry["measurement_date"] : nil
      status =
        if !required
          "not_required"
        elsif measured_at.is_a?(String)
          "met_by_exact_evidence"
        elsif precise_status == Orbit::ModelEvidenceCache::STATUS_EVIDENCE
          "hold"
        elsif catalog["status"] == "measurement_date_unknown"
          "hold"
        else
          "unknown"
        end
      { "requirement" => required, "status" => status, "catalog_status" => catalog["status"],
        "exact_evidence_status" => precise_status, "exact_evidence_measured_at" => measured_at }
    end

    def eligibility_projection(task, facts)
      {
        "context" => context_eligibility(task.fetch("required_context_tokens"), facts),
        "input_modalities" => modality_eligibility(task.fetch("required_input_modalities"), facts, "input_modalities"),
        "output_modalities" => modality_eligibility(task.fetch("required_output_modalities"), facts, "output_modalities"),
        "parameters" => parameter_eligibility(task.fetch("required_parameters"), facts)
      }
    end

    def context_eligibility(required, facts)
      return { "status" => "not_required", "requirement" => nil, "catalog_value" => catalog_context(facts) } if required.nil?

      catalog = catalog_context(facts)
      base = { "requirement" => required, "catalog_value" => catalog }
      if catalog.nil?
        base.merge("status" => "unknown",
                   "note" => "目录缺少上下文长度事实；实际路由上限未知，须运行时核对")
      elsif catalog >= required
        base.merge("status" => "met_by_catalog",
                   "note" => "目录上限是模型级事实，不覆盖实际路由可能更小的上下文限制；实际路由上限须运行时核对")
      else
        base.merge("status" => "unmet_by_catalog",
                   "note" => "目录上限低于任务需求；目录事实不构成路由资格，实际路由限制仍须运行时核对")
      end
    end

    def catalog_context(facts)
      facts.is_a?(Hash) && facts["context_length"].is_a?(Integer) ? facts["context_length"] : nil
    end

    def modality_eligibility(required, facts, key)
      return { "status" => "not_required", "requirement" => [], "catalog_value" => catalog_modalities(facts, key) } if required.empty?

      catalog = catalog_modalities(facts, key)
      base = { "requirement" => required, "catalog_value" => catalog }
      if catalog.nil?
        base.merge("status" => "unknown", "note" => "目录缺少模态事实；实际路由模态限制未知")
      elsif (required - catalog).empty?
        base.merge("status" => "met_by_catalog",
                   "note" => "目录模态是模型级事实，不覆盖实际路由可能的模态缩减（如仅图像输入的变体）；须运行时核对")
      else
        base.merge("status" => "unmet_by_catalog", "missing" => required - catalog,
                   "note" => "目录模态未覆盖任务需求")
      end
    end

    def catalog_modalities(facts, key)
      value = facts.is_a?(Hash) ? facts.dig("architecture", key) : nil
      value.is_a?(Array) ? value : nil
    end

    def parameter_eligibility(required, facts)
      catalog = facts.is_a?(Hash) && facts["supported_parameters"].is_a?(Array) ? facts["supported_parameters"] : nil
      return { "status" => "not_required", "requirement" => [], "catalog_value" => catalog } if required.empty?

      base = { "requirement" => required, "catalog_value" => catalog }
      if catalog.nil?
        base.merge("status" => "unknown", "note" => "目录缺少支持参数事实；宿主实际工具授予未知")
      elsif (required - catalog).empty?
        base.merge("status" => "met_by_catalog",
                   "note" => "目录支持参数是模型级事实，不等于宿主在运行时授予对应工具；须在工具入口核对")
      else
        base.merge("status" => "unmet_by_catalog", "missing" => required - catalog,
                   "note" => "目录支持参数未覆盖任务需求")
      end
    end

    # Every separately reported catalog value for one task index. Each variant
    # keeps its own display_name; a single-variant prior stays exactly one
    # candidate, so its original one-comparison behavior is unchanged. No
    # highest or average value is ever invented.
    def benchmark_candidates(prior, index)
      variants = Array(prior["benchmark_variants"]).select do |variant|
        variant.is_a?(Hash) && variant[index].is_a?(Numeric)
      end
      unless variants.empty?
        return variants.map do |variant|
          { "value" => variant[index].to_f, "display_name" => variant["display_name"] }
        end
      end

      value = prior[index]
      value.is_a?(Numeric) ? [{ "value" => value.to_f, "display_name" => prior["benchmark_display_name"] }] : []
    end

    def benchmark_side(index:, candidate:, recorded:, evidence:, prior:, evidence_value:, divergence:)
      {
        "index" => index,
        "catalog_value" => candidate.fetch("value"),
        "catalog_display_name" => candidate["display_name"],
        "catalog_fetched_at" => prior["fetched_at"],
        "catalog_measurement_date_status" => prior["measurement_date_status"],
        "catalog_benchmark_as_of" => prior["benchmark_as_of"],
        "evidence_value" => evidence_value,
        "evidence_unit" => recorded["unit"],
        "evidence_basis" => recorded["basis"],
        "evidence_retrieved_at" => evidence.fetch("retrieved_at"),
        "divergence" => divergence,
        "measurement_note" => "测量单位、方法版本、测量日期与实际 reasoning 归属未核实"
      }
    end

    # Substantive conflicts (hold + root review) vs contrasts (simultaneous
    # presentation, not auto-contradiction). Nothing is resolved by source
    # name; both sides always keep their values, scope and dates.
    def evidence_relations(catalog, precise, task)
      conflicts = []
      contrasts = []
      prior = catalog["prior"]
      evidence = precise["entry"]
      return [conflicts, contrasts] unless prior.is_a?(Hash) && evidence.is_a?(Hash)

      if precise["status"] == Orbit::ModelEvidenceCache::STATUS_UNAVAILABLE
        contrasts << {
          "type" => "exact_identity_unavailable_vs_catalog_prior",
          "question_catalog" => CATALOG_QUESTION,
          "question_evidence" => EVIDENCE_QUESTION,
          "catalog_side" => { "relevant_indices" => prior.fetch("relevant_indices"), "fetched_at" => prior["fetched_at"] },
          "evidence_side" => { "status" => "unavailable", "reason" => evidence["reason"],
                               "retrieved_at" => evidence.fetch("retrieved_at") },
          "note" => "精确身份记录了不可用/未核实状态；模型级指数回答不同问题，不自动构成矛盾，但目录分不得覆盖该记录"
        }
        return [conflicts, contrasts]
      end

      metrics = evidence["metrics"].is_a?(Hash) ? evidence["metrics"] : {}
      task.fetch("relevant_indices").each do |index|
        recorded = metrics[index]
        next unless recorded.is_a?(Hash) && recorded["value"].is_a?(Numeric)

        candidates = benchmark_candidates(prior, index)
        next if candidates.empty?

        evidence_value = recorded["value"]
        judged = candidates.map do |candidate|
          divergence = (evidence_value - candidate.fetch("value")).abs
          [candidate, divergence, divergence / [candidate.fetch("value").abs, 1.0].max]
        end
        sides = judged.map do |candidate, divergence, _relative|
          benchmark_side(index: index, candidate: candidate, recorded: recorded, evidence: evidence,
                         prior: prior, evidence_value: evidence_value, divergence: divergence)
        end
        exceeds = judged.each_with_index.select do |(_candidate, divergence, relative), _position|
          relative > CONFLICT_RELATIVE_DIVERGENCE && divergence > CONFLICT_ABSOLUTE_FLOOR
        end.map { |_entry, position| position }

        if judged.length == 1
          side = sides.first
          if exceeds.any?
            conflicts << side.merge(
              "type" => "potential_benchmark_conflict",
              "question_catalog" => CATALOG_QUESTION,
              "question_evidence" => EVIDENCE_QUESTION,
              "resolution" => "root_review",
              "note" => "同名指标与目录值分歧超过阈值；两次测量的单位、方法版本与测量日期不明，分歧本身不证明任何一方失真——这是供 Root 复核的潜在冲突线索，不是测量真伪裁定"
            )
          elsif judged.first[1].positive?
            contrasts << side.merge(
              "type" => "same_index_minor_divergence",
              "question_catalog" => CATALOG_QUESTION,
              "question_evidence" => EVIDENCE_QUESTION,
              "note" => "同名指标两次测量存在阈值内差异；同时呈现，不视为矛盾"
            )
          end
        elsif exceeds.length == judged.length
          # Every separately reported variant disagrees with the exact value.
          # No variant is selected, averaged or promoted: all of them are shown
          # with their own labels and the hold stays for Root review.
          conflicts << {
            "type" => "potential_benchmark_variant_conflict",
            "index" => index,
            "variants" => sides,
            "variant_count" => sides.length,
            "question_catalog" => CATALOG_QUESTION,
            "question_evidence" => EVIDENCE_QUESTION,
            "resolution" => "root_review",
            "note" => "该模型报告的每个基准变体都与精确值分歧超过阈值；变体各自的单位、方法版本、测量日期与实际 reasoning 归属不明，无法判定哪一变体对应本 OMP 路由——供 Root 复核，这不是测量真伪或变体归属的裁定"
          }
        elsif exceeds.any?
          contrasts << {
            "type" => "benchmark_variant_divergence_unresolved",
            "index" => index,
            "variants" => sides,
            "divergent_variant_count" => exceeds.length,
            "variant_count" => sides.length,
            "question_catalog" => CATALOG_QUESTION,
            "question_evidence" => EVIDENCE_QUESTION,
            "note" => "部分基准变体与精确值分歧超过阈值，其余变体在阈值内；实际 reasoning 归属未知，无法判定分歧是否已解决——双方变体并列呈现，不视为矛盾已解决，也不据此暂停推荐"
          }
        else
          judged.each_with_index do |(candidate, divergence, _relative), position|
            next unless divergence.positive?

            contrasts << sides[position].merge(
              "type" => "same_index_minor_divergence",
              "question_catalog" => CATALOG_QUESTION,
              "question_evidence" => EVIDENCE_QUESTION,
              "note" => "同名指标两次测量存在阈值内差异；同时呈现，不视为矛盾"
            )
          end
        end
      end
      [conflicts, contrasts]
    end

    def bounded(text)
      text.to_s.slice(0, MAX_NOTE_LENGTH)
    end
  end
end
