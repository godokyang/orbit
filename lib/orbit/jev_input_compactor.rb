# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

require_relative "jev_compaction_runner"
require_relative "judgment"
require_relative "type_safe_judgment"

module Orbit
  # On-demand compaction of over-long JEV material, used only by the member and
  # checker selection paths (docs/plan/jev-input-compaction-draft.md §7).
  #
  # Nothing here runs on a schedule and nothing here compacts a coding session:
  # the caller decides that one specific judgment's material is too long (its own
  # size check, or a JEV result that explicitly reported an input/token limit)
  # and asks for one shortened copy. Network, credential and other errors never
  # reach this class as a compaction trigger.
  #
  # What this class owns:
  # * the capacity gate. A candidate whose session context cannot hold this
  #   prompt in one pass (material + compaction instruction + output budget +
  #   a labelled allowance for the runner's own system prompt) is not selectable.
  #   That is the only thing the program filters; fidelity is judged, not
  #   pre-filtered.
  # * the compressor-model choice: JEV answers, per candidate, whether that
  #   candidate is the most suitable one-pass compressor under the stated
  #   priority (hold everything, keep the required items inside the budget, then
  #   prefer the fastest recorded candidate), plus an explicit "no listed
  #   candidate is suitable" option. Its input carries metadata only — purpose,
  #   sizes, language, content type, required-item roles, output budget,
  #   per-candidate capacity/capability and recorded speed — never the material
  #   text. The program takes that combined choice probability; recorded speed
  #   only breaks an exact tie, and unmeasured speed stays unknown.
  # * a durable cache keyed by material content version, purpose, required items,
  #   rule version and output budget, with single flight for one key. Within a
  #   process every asker of that key shares the one in-flight result, success or
  #   failure; across processes a successful result is shared through the cache
  #   and a failed one through a short-lived receipt, so a process already waiting
  #   on the same key does not pay for the same failed call twice. A failed
  #   compaction is never stored as a valid summary, so a later request retries.
  # * exactly one compaction call per ask, and `recover` retries the original
  #   judgment at most once with the compacted text.
  # * the real measurements of every completed compaction call and the full
  #   judgment/runner call facts (request, result, provider response, usage,
  #   evidence) for the caller that persists call records.
  #
  # Capacity unit: the judgment service documents 64k tokens per request and
  # 32k tokens per question including state (docs.typesafe.ai/models). Orbit
  # cannot count tokens exactly, so every comparison here uses UTF-8 bytes as a
  # conservative upper bound on the token count (a token never encodes fewer
  # than one byte) and every result labels that unit explicitly as
  # "utf8_bytes_as_token_upper_bound". Character counts are never used as a
  # token estimate. A byte length below a token capacity proves a fit; a byte
  # length above it proves nothing, so Orbit never reports its own byte count as
  # a measured token overflow and never turns that bound into a claimed service
  # refusal: the selection request is sent and a real service refusal is
  # reported as an unavailable judgment. The byte bound is used as a
  # conservative budget for the compaction output the judge will read.
  class JevInputCompactor
    UNIT = "utf8_bytes_as_token_upper_bound"
    # Bump when the compaction task wording, the output format/checks or the
    # cache material change: an older cached text must not be reused as if
    # nothing changed.
    RULE_VERSION = "orbit-jev-compaction-rule-v1"
    SELECTION_VERSION = "orbit-jev-compaction-selection-v1"
    # Conservative allowance for the runner session's own system prompt, which
    # Orbit does not author or measure. It is labelled here rather than hidden:
    # a real observation may replace it through the constructor.
    SYSTEM_OVERHEAD_BYTES = 8_192
    # How long a cross-process failure receipt stays readable. It exists only so
    # a process that was blocked on the same key's lock does not pay for the same
    # failed compaction again; a later request is a fresh attempt.
    FLIGHT_RECEIPT_TTL_SECONDS = 5
    SCHEMA_VERSION = 1
    MAX_CACHE_ENTRIES = 32
    MAX_SPEED_OBSERVATIONS = 5
    CANDIDATE_PATTERN = %r{\A[^\s/]+/[^\s]+\z}
    SECTIONS = %w[objective constraints background undetermined].freeze
    # The four required output groups, [key, heading] pairs. A group the material
    # has nothing for is empty, never invented.
    SECTION_LABELS = {
      "objective" => "objective and completion criteria",
      "constraints" => "necessary conditions and constraints",
      "background" => "background and dependency facts",
      "undetermined" => "undetermined or conflicting information"
    }.freeze
    # A compacted text that defers to the original has not preserved anything
    # the judge needs; that is a failed compaction, not a short one.
    DEFERRAL = /详见原文|见原文|参见原文|参考原文|见正文|as (?:described|stated) (?:above|in the original)|see (?:the )?(?:original|full) (?:text|document)|refer to the original/i

    class Error < ArgumentError; end

    class << self
      # Process-wide in-flight registry and its lock. Shared by every instance,
      # because a caller may build one compactor per ask.
      def flights
        @flights ||= {}
      end

      def flight_lock
        @flight_lock ||= Mutex.new
      end
    end

    def self.default_cache_dir(env: ENV)
      base = env["XDG_CACHE_HOME"].to_s.strip
      base = File.join(env["HOME"].to_s.strip, ".cache") if base.empty? && !env["HOME"].to_s.strip.empty?
      raise Error, "cannot resolve a cache directory without XDG_CACHE_HOME or HOME" if base.empty?

      File.join(base, "orbit", "jev-compaction-v1")
    end

    attr_reader :cache_dir

    # `provider` is the judgment channel (the existing TypeSafe adapter) used
    # only to select the compressor model. `runner` performs the single
    # compaction call; the default runs one no-tools local OMP session.
    def initialize(provider:, runner: nil, cache_dir: nil, clock: nil, rule_version: RULE_VERSION,
                   selection_version: SELECTION_VERSION, omp_version: nil, allowed_models: nil,
                   system_overhead_bytes: SYSTEM_OVERHEAD_BYTES)
      unless provider.respond_to?(:judge)
        raise Error, "a judgment provider that answers JudgmentRequest is required"
      end

      @provider = provider
      @runner = runner || JevCompactionRunner.new(omp_version: omp_version, allowed_models: allowed_models)
      @cache_dir = File.expand_path(cache_dir || self.class.default_cache_dir)
      @clock = clock || -> { Time.now.utc }
      @rule_version = rule_version
      @selection_version = selection_version
      @system_overhead_bytes = Integer(system_overhead_bytes)
      raise Error, "system prompt allowance must not be negative" if @system_overhead_bytes.negative?
    end

    # Compacts one judgment's material for one purpose. Returns:
    #
    #   {"status" => "compacted" | "cached" | "unavailable",
    #    "text" => String|nil, "sections" => Hash|nil, "reason" => String|nil,
    #    "key" => String, "cache" => "hit"|"miss", "model" => String|nil,
    #    "selection" => Hash|nil, "preserved" => Array, "call" => Hash|nil,
    #    "measurements" => Hash|nil, "unit" => UNIT, "rule_version" => String,
    #    "flight" => "leader" | "shared" | nil}
    #
    # Only "compacted" and "cached" carry text and sections. Every other outcome
    # is a failed compaction that the caller handles along its existing
    # no-judgment path.
    def compact(purpose:, material:, must_keep:, output_budget_bytes:, candidates:, language: nil, content_type: nil)
      request = build_request(purpose: purpose, material: material, must_keep: must_keep,
                              output_budget_bytes: output_budget_bytes, candidates: candidates,
                              language: language, content_type: content_type)
      reuse = cached(request)
      return reuse.merge("cache" => "hit", "flight" => nil) if reuse

      # Same-key concurrency: exactly one leader per key performs the work, and
      # askers that arrive while it runs consume that same result — including a
      # failed compaction, which is shared as a flight receipt but never stored
      # as a valid cached summary, so a later request can retry. The flight is
      # process-wide, so two compactor instances in one process share it too.
      asked_at = Time.now.utc
      run_flight(request.fetch("key")) do
        # The per-key file lock serializes this key across processes, re-checks
        # the cache inside, and consumes a fresh failure receipt from another
        # process instead of paying for the same failed compaction again.
        with_file_lock(File.join(lock_dir, "#{request.fetch('key')}.lock")) do
          reuse = cached(request)
          next reuse.merge("cache" => "hit", "flight" => nil) if reuse

          shared = cross_process_flight(request.fetch("key"), asked_at)
          next shared if shared

          result = produce(request)
          write_cross_process_flight(request.fetch("key"), result) unless %w[compacted cached].include?(result["status"])
          result
        end
      end
    end

    # Runs one original judgment attempt; when that attempt reports an explicit
    # input/token limit, compacts once and retries the same attempt exactly once
    # with the compacted text. The block receives the text to judge.
    #
    #   {"status" => "not_needed" | "retried" | "unavailable",
    #    "judgment" => <block result>, "first_judgment" => <block result>|nil,
    #    "compaction" => Hash|nil, "reason" => String|nil}
    def recover(purpose:, material:, must_keep:, output_budget_bytes:, candidates:, language: nil,
                content_type: nil, overflow: nil)
      first = yield(material)
      detector = overflow || self.class.method(:overflow?)
      unless detector.call(first)
        return { "status" => "not_needed", "judgment" => first, "first_judgment" => nil, "compaction" => nil }
      end

      compaction = compact(purpose: purpose, material: material, must_keep: must_keep,
                           output_budget_bytes: output_budget_bytes, candidates: candidates,
                           language: language, content_type: content_type)
      unless %w[compacted cached].include?(compaction["status"])
        return { "status" => "unavailable", "judgment" => first, "first_judgment" => nil,
                 "compaction" => compaction, "reason" => compaction["reason"] }
      end

      { "status" => "retried", "judgment" => yield(compaction.fetch("text")), "first_judgment" => first,
        "compaction" => compaction }
    end

    # Does this judgment outcome report that its input was too long? Only an
    # explicit capacity/token refusal qualifies: transport, credential, quota and
    # unknown failures must never start a compaction.
    def self.overflow?(outcome)
      text = flatten_outcome(outcome)
      return false if text.empty?

      text.match?(/max_tokens_exceeded|maximum context|context_length|context length|input is too long|input too long|too many tokens|request entity too large|\b413\b|payload too large/i)
    end

    # Every printable string an outcome carries, including the provider's own
    # base64 response body when the adapter kept one. Used only for the local
    # overflow decision above; never sent anywhere.
    def self.flatten_outcome(outcome, depth = 0)
      return "" if depth > 4
      return outcome.to_s if outcome.is_a?(String) || outcome.is_a?(Numeric)
      return "" if outcome.nil?
      return outcome.map { |item| flatten_outcome(item, depth + 1) }.join(" ") if outcome.is_a?(Array)

      facts = outcome.respond_to?(:to_h) && !outcome.is_a?(Hash) ? outcome.to_h : outcome
      return "" unless facts.is_a?(Hash)

      facts.flat_map do |key, value|
        if key.to_s == "body_base64" && value.is_a?(String)
          begin
            next value.unpack1("m0").force_encoding("UTF-8").scrub
          rescue StandardError
            next ""
          end
        end
        flatten_outcome(value, depth + 1)
      end.join(" ")
    end

    private

    # Validated, digest-bound request. The key carries exactly the replay basis
    # named by the confirmed plan: material content version, purpose, required
    # items, rule version and output budget.
    def build_request(purpose:, material:, must_keep:, output_budget_bytes:, candidates:, language:, content_type:)
      text = material.to_s
      raise Error, "material to compact is required" if text.strip.empty?

      purpose = purpose.to_s.strip
      raise Error, "compaction purpose is required" if purpose.empty?

      budget = output_budget_bytes
      unless budget.is_a?(Integer) && budget.positive?
        raise Error, "output budget must be a positive integer of UTF-8 bytes"
      end

      items = normalize_items(must_keep)
      raise Error, "required items are required: a compaction must know what to keep" if items.empty?

      list = normalize_candidates(candidates)
      raise Error, "at least one compaction candidate is required" if list.empty?

      {
        "purpose" => purpose, "material" => text, "material_bytes" => text.bytesize,
        "material_sha256" => Digest::SHA256.hexdigest(text), "must_keep" => items,
        "output_budget_bytes" => budget, "candidates" => list,
        "language" => language.to_s.strip.empty? ? "unknown" : language.to_s.strip,
        "content_type" => Array(content_type).map(&:to_s).reject { |value| value.strip.empty? }.uniq,
        "key" => Digest::SHA256.hexdigest(JSON.generate(
          "rule_version" => @rule_version, "selection_version" => @selection_version, "purpose" => purpose,
          "material_sha256" => Digest::SHA256.hexdigest(text), "must_keep" => items,
          "output_budget_bytes" => budget, "unit" => UNIT
        ))
      }
    end

    # Required items are role-labelled: the caller states which piece of content
    # must survive, and the program checks every stated item, not merely that a
    # few section headings are non-empty.
    def normalize_items(must_keep)
      list = Array(must_keep).map do |item|
        case item
        when String then { "role" => "required", "text" => item.strip }
        when Hash
          { "role" => item["role"].to_s.strip.empty? ? "required" : item["role"].to_s.strip,
            "text" => item["text"].to_s.strip }
        else
          raise Error, "required items must be strings or {role, text} hashes"
        end
      end
      list.reject { |item| item["text"].empty? }.uniq
    end

    def normalize_candidates(candidates)
      Array(candidates).map do |candidate|
        raise Error, "each candidate must be a hash with a model" unless candidate.is_a?(Hash)

        model = candidate["model"].to_s
        raise Error, "candidate model must be provider/id" unless model.match?(CANDIDATE_PATTERN)

        limit = candidate["context_limit_tokens"]
        unless limit.nil? || (limit.is_a?(Integer) && limit.positive?)
          raise Error, "candidate context_limit_tokens must be a positive integer when known"
        end
        { "model" => model, "context_limit_tokens" => limit,
          "capability" => candidate["capability"], "identity" => candidate["identity"] }
      end.uniq { |candidate| candidate["model"] }
    end

    # A cached compaction is reusable only while it still belongs to the same
    # rule version and still carries the required output format and every
    # required item inside the budget.
    def cached(request)
      entry = read_store("cache.json").dig("entries", request.fetch("key"))
      return nil unless entry.is_a?(Hash)
      return nil unless entry["rule_version"] == @rule_version && entry["selection_version"] == @selection_version

      sections = entry["sections"].is_a?(Hash) ? entry["sections"] : {}
      text = entry["text"].to_s
      return nil if text.empty? || text.bytesize > request.fetch("output_budget_bytes")
      return nil unless section_problem(sections).nil?
      return nil unless missing_items(sections, request.fetch("must_keep")).empty?

      {
        "status" => "cached", "text" => text, "sections" => sections, "reason" => nil,
        "key" => request.fetch("key"), "model" => entry["model"], "selection" => entry["selection"],
        "preserved" => preserved_items(sections, request.fetch("must_keep")),
        "call" => entry["call"], "measurements" => entry["measurements"],
        "unit" => UNIT, "rule_version" => @rule_version
      }
    end

    def produce(request)
      capacity = capacity_plan(request)
      if capacity.fetch("eligible").empty?
        return unavailable(request, "no authorized candidate can be verified to hold this material, the compaction " \
                                    "instruction, the output budget and the runner's own prompt in one pass " \
                                    "(needed at least #{capacity.fetch('needed_bytes')} #{UNIT}, which is an upper " \
                                    "bound on the token count, not a measured count; unknown capacity is not usable)")
      end

      selection, chosen = choose_model(request, capacity)
      return unavailable(request, selection.fetch("reason"), selection) if chosen.nil?

      outcome = run_runner(request, chosen)
      return unavailable(request, outcome["error"].to_s, selection, outcome["call"]) unless outcome["ok"]

      # The call happened, so its real measurements are recorded whatever the
      # output checks decide below.
      measured = outcome.fetch("measurements")
      record_speed(measured.fetch("model"), measured)
      parsed = parse_output(outcome.fetch("text"))
      problem = parsed.is_a?(String) ? parsed : output_problem(parsed, request)
      return unavailable(request, problem, selection, outcome["call"], measured) if problem

      text = render_sections(parsed.fetch("sections"))
      if text.bytesize > request.fetch("output_budget_bytes")
        return unavailable(request, "the rendered compaction is #{text.bytesize} #{UNIT} over the " \
                                    "#{request.fetch('output_budget_bytes')} budget", selection, outcome["call"], measured)
      end

      store(request, text, parsed.fetch("sections"), chosen, selection, outcome)
      {
        "status" => "compacted", "text" => text, "sections" => parsed.fetch("sections"), "reason" => nil,
        "key" => request.fetch("key"), "cache" => "miss", "model" => chosen.fetch("model"),
        "selection" => selection, "preserved" => preserved_items(parsed.fetch("sections"), request.fetch("must_keep")),
        "call" => outcome["call"], "measurements" => outcome.fetch("measurements"),
        "unit" => UNIT, "rule_version" => @rule_version
      }
    end

    # Capacity is a conservative program decision, not a measured token count:
    # the material, the compaction instruction, the output the judge will read
    # and the runner's own system prompt allowance must all be below one
    # candidate's documented token capacity. Because the byte length is an upper
    # bound on the token count, a candidate that passes really does fit, and a
    # candidate that fails is only unverifiable rather than provably too small.
    def capacity_plan(request)
      overhead = instruction_bytes(request)
      needed = request.fetch("material_bytes") + overhead + request.fetch("output_budget_bytes") + @system_overhead_bytes
      eligible = request.fetch("candidates").select do |candidate|
        limit = candidate["context_limit_tokens"]
        !limit.nil? && limit >= needed
      end
      { "needed_bytes" => needed, "instruction_bytes" => overhead, "eligible" => eligible }
    end

    # JEV makes the choice from metadata only. The material text is never part of
    # this request, and Orbit does not convert its own byte upper bound into a
    # claimed overflow: the request is sent, and a real service refusal becomes
    # an unavailable judgment through the ordinary failure path below.
    def choose_model(request, capacity)
      eligible = capacity.fetch("eligible")
      speeds = eligible.to_h { |candidate| [candidate["model"], speed_summary(candidate["model"])] }
      state = selection_state(request, eligible, speeds, capacity)
      questions = self.class.selection_questions(eligible)
      request_object = JudgmentRequest.new(state: state, questions: questions,
                                           question_set_version: @selection_version,
                                           provider: TypeSafeJudgment::PROVIDER, model: nil)
      result = @provider.judge(request_object)
      trace = selection_trace(request_object, result)
      unless result.is_a?(JudgmentResult) && result.complete_for?(request_object)
        reason = result.is_a?(JudgmentResult) ? result.error.to_s : "the judgment provider returned no usable result"
        return [selection_failure("compressor model selection failed: #{reason}", trace), nil]
      end

      choices = eligible.to_h do |candidate|
        [candidate["model"], result.probability_true("compaction_choice_#{eligible.index(candidate)}")]
      end
      none = result.probability_true("no_candidate_suitable")
      best = eligible.max_by { |candidate| [choices.fetch(candidate["model"]), tie_break(eligible, candidate, speeds)] }
      selection = {
        "question_set_version" => @selection_version, "unit" => UNIT,
        "choices" => choices, "no_candidate_suitable" => none,
        "speed" => speeds, "chosen" => best&.fetch("model"),
        "sizes" => selection_sizes(state, eligible),
        "provenance" => "program capacity filter only; JEV judged the combined choice under the stated priority " \
                        "order in each question; recorded speed broke exact ties and unknown speed was kept unknown",
        "trace" => trace
      }
      if best.nil? || none > choices.fetch(best.fetch("model"))
        return [selection.merge("reason" => "JEV judged that no listed candidate is a suitable one-pass compressor " \
                                           "for this material (no_candidate_suitable=#{none})"), nil]
      end

      [selection, best]
    end

    # One question per eligible candidate — the judge is asked for the combined
    # choice under the confirmed priority (capacity, then preservation inside the
    # budget, then the fastest recorded candidate) — plus one explicit "no listed
    # candidate is suitable" option so the material can legitimately stay
    # uncompacted. No absolute threshold is invented here: the program takes the
    # highest stated choice probability, and the real accuracy of that choice
    # still needs the sample verification the draft requires.
    def self.selection_questions(candidates)
      questions = {}
      candidates.each_with_index do |candidate, index|
        questions["compaction_choice_#{index}"] = {
          "instruction" => "Material for one Orbit judgment call is too long to send as it stands, so a model would " \
                           "have to shorten it in a single request for the stated purpose. Decide about candidate " \
                           "#{candidate['model']} in this order: (1) it must be able to hold the whole material and the " \
                           "compaction instruction in one request, (2) it must be able to keep every listed required " \
                           "item inside the output budget while adding no fact of its own, (3) among candidates that " \
                           "satisfy both, prefer the fastest one by the measured speed shown; treat unmeasured speed as " \
                           "unknown rather than fast or slow. Is this candidate the most suitable one-pass compressor " \
                           "among the listed candidates? Price is not a consideration.",
          "true_criterion" => "This candidate is the most suitable one-pass compressor among the listed candidates " \
                              "under that priority order",
          "false_criterion" => "Another listed candidate, or none of them, is more suitable"
        }
      end
      questions["no_candidate_suitable"] = {
        "instruction" => "Is no listed candidate suitable as a one-pass compressor for this material, for example " \
                         "because none can hold it in one request or none can preserve the required items inside the " \
                         "output budget?",
        "true_criterion" => "No listed candidate should shorten this material",
        "false_criterion" => "At least one listed candidate is suitable"
      }
      questions
    end

    def selection_state(request, eligible, speeds, capacity)
      {
        "unit" => UNIT, "purpose" => request.fetch("purpose"),
        "material" => { "utf8_bytes" => request.fetch("material_bytes"),
                        "material_sha256" => request.fetch("material_sha256"),
                        "language" => request.fetch("language"),
                        "content_type" => request.fetch("content_type") },
        "compaction_task" => { "one_pass" => true, "instruction_bytes" => capacity.fetch("instruction_bytes"),
                               "system_prompt_allowance_bytes" => @system_overhead_bytes,
                               "output_groups" => SECTIONS.map { |key| SECTION_LABELS.fetch(key) },
                               "must_not_add_facts" => true },
        "output_budget" => { "utf8_bytes" => request.fetch("output_budget_bytes"), "unit" => UNIT },
        "required_items" => request.fetch("must_keep").map do |item|
          { "role" => item["role"], "chars" => item["text"].length }
        end,
        "candidates" => eligible.each_with_index.map do |candidate, index|
          { "index" => index, "model" => candidate["model"], "identity" => candidate["identity"],
            "context_limit" => { "value" => candidate["context_limit_tokens"], "unit" => UNIT },
            "capability" => candidate["capability"], "measured_speed" => speeds.fetch(candidate["model"]) }
        end
      }
    end

    # The documented per-question capacity covers state plus that question's own
    # text. Orbit keeps the sizes visible to the caller but never converts them
    # into a claimed service refusal.
    def selection_sizes(state, eligible)
      encoded = JSON.generate(state).bytesize
      { "state_bytes" => encoded, "questions_bytes" => question_bytes(eligible), "unit" => UNIT }
    end

    def question_bytes(eligible)
      self.class.selection_questions(eligible).values.sum { |question| JSON.generate(question).bytesize }
    end

    # Recorded speed only breaks an exact tie: a measured candidate comes before
    # an unmeasured one, a higher recorded rate comes first, and the listed order
    # settles the rest. It never overrides the judge's choice.
    def tie_break(eligible, candidate, speeds)
      speed = speeds.fetch(candidate["model"])
      rate = speed["known"] ? speed["input_bytes_per_second"].to_f : 0.0
      [rate.positive? ? 0 : 1, -rate, -eligible.index(candidate)]
    end

    # The judgment request, its result and the provider's own response are kept
    # whole so the caller can persist the real call instead of only its scores.
    def selection_trace(request_object, result)
      {
        "request" => request_object.to_h,
        "result" => result.is_a?(JudgmentResult) ? result.to_h : nil,
        "provider_response" => @provider.respond_to?(:last_response) ? @provider.last_response : nil
      }.compact
    end

    def selection_failure(reason, trace = nil)
      { "reason" => reason, "choices" => {}, "provenance" => "program refusal before any judgment call",
        "trace" => trace }.compact
    end

    def run_runner(request, chosen)
      outcome = @runner.run(prompt: compaction_prompt(request), model: chosen.fetch("model"))
      unless outcome.is_a?(Hash)
        return { "ok" => false, "error" => "the compaction runner returned no facts" }
      end
      unless outcome["ok"]
        error = outcome["error"]
        detail = error.is_a?(Hash) ? error["detail"].to_s : error.to_s
        detail = Array(outcome["problems"]).join("; ") if detail.empty?
        return { "ok" => false, "call" => runner_call(outcome),
                 "error" => "the compaction call failed (#{detail.empty? ? 'no detail reported' : detail})" }
      end

      model = outcome["model"].to_s
      measurements = {
        "model" => model.empty? ? chosen.fetch("model") : model,
        "input_bytes" => outcome["input_bytes"], "output_bytes" => outcome["output_bytes"],
        "seconds" => outcome["seconds"], "recorded_at" => @clock.call.utc.iso8601
      }
      { "ok" => true, "text" => outcome["text"].to_s, "call" => runner_call(outcome),
        "measurements" => measurements }
    end

    # Everything the persisting caller needs to record this paid call: the local
    # attempt label, provider usage receipts with their own call ids and the
    # runner's evidence.
    def runner_call(outcome)
      {
        "attempt_id" => outcome["attempt_id"], "model" => outcome["model"],
        "requested_model" => outcome["requested_model"] || outcome.dig("evidence", "requested_model"),
        "usage" => outcome["usage"], "usage_gaps" => Array(outcome["usage_gaps"]),
        "evidence" => outcome["evidence"]
      }
    end

    # The compaction answer is one JSON object: a status, the four required
    # groups and nothing else. A "cannot_preserve" answer is an explicit failed
    # compaction, and a malformed answer is reported as such instead of being
    # substring-checked as prose.
    def parse_output(raw)
      body = raw.to_s.strip
      body = body.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      start = body.index("{")
      finish = body.rindex("}")
      return "the compaction output is not the required JSON object" if start.nil? || finish.nil? || finish < start

      parsed = begin
        JSON.parse(body[start..finish])
      rescue JSON::ParserError
        nil
      end
      return "the compaction output is not valid JSON" unless parsed.is_a?(Hash)
      return "the compaction model reported that it cannot preserve the required content inside the budget" if parsed["status"] == "cannot_preserve"

      sections = parsed["sections"]
      return "the compaction output is missing its sections object" unless sections.is_a?(Hash)

      problem = section_problem(sections)
      return problem if problem

      { "sections" => sections.to_h { |key, value| [key.to_s, value.to_s] } }
    end

    # The four groups must exist as strings with usable content, and the
    # required-items and deferral checks below decide preservation. These checks
    # do not prove the text is semantically lossless; the draft's real
    # long-material verification covers that separately.
    def section_problem(sections)
      missing = SECTIONS.reject { |key| sections.key?(key) && sections[key].is_a?(String) }
      return "the compaction output does not state all four required groups (missing #{missing.join(', ')})" unless missing.empty?
      return "the compaction output is empty" if SECTIONS.all? { |key| sections.fetch(key).strip.empty? }
      return "the compaction output defers to the original material instead of stating the required content" if SECTIONS.any? { |key| sections.fetch(key).match?(DEFERRAL) }

      nil
    end

    def output_problem(parsed, request)
      sections = parsed.fetch("sections")
      missing = missing_items(sections, request.fetch("must_keep"))
      return nil if missing.empty?

      "the compaction dropped required items: #{missing.map { |item| item['role'] }.uniq.join(', ')}"
    end

    # Required items are matched against the four groups as one body: the judge
    # receives the rendered text, so an item split across groups is still kept.
    def preserved_items(sections, items)
      haystack = squashed(sections.values.join("\n"))
      items.map { |item| { "role" => item["role"], "present" => haystack.include?(squashed(item["text"])) } }
    end

    def missing_items(sections, items)
      haystack = squashed(sections.values.join("\n"))
      items.reject { |item| haystack.include?(squashed(item["text"])) }
    end

    def squashed(value)
      value.to_s.gsub(/\s+/, " ").strip
    end

    def render_sections(sections)
      SECTIONS.filter_map do |key|
        body = sections.fetch(key).strip
        next if body.empty?

        "## #{SECTION_LABELS.fetch(key)}\n#{body}"
      end.join("\n\n")
    end

    def compaction_prompt(request)
      items = request.fetch("must_keep").map { |item| "- [#{item['role']}] #{item['text']}" }
      [
        "# Orbit JEV material compaction",
        "",
        "Purpose: #{request.fetch('purpose')}",
        "Output budget: at most #{request.fetch('output_budget_bytes')} UTF-8 bytes in total (unit: #{UNIT}: bytes",
        "are an upper bound on tokens, so staying inside the byte count also stays inside the token budget).",
        "Language: #{request.fetch('language')}  " \
        "Content type: #{request.fetch('content_type').empty? ? 'unknown' : request.fetch('content_type').join(', ')}",
        "",
        "Shorten the material below for the stated purpose. Keep every required item below verbatim. Never turn a",
        "possible or unverified statement into a fact, and never replace content the judge needs with a pointer such",
        "as \"see the original\".",
        "",
        "Required items to keep (each verbatim):",
        *items,
        "",
        "Answer with exactly one JSON object and no other text:",
        "{\"status\":\"compacted\"|\"cannot_preserve\",\"reason\":\"...\",\"sections\":{#{SECTIONS.map { |key| "\"#{key}\":\"...\"" }.join(',')}}}",
        "Put in sections.objective the objective and completion criteria, in sections.constraints the necessary",
        "conditions and constraints, in sections.background the background and dependency facts, and in",
        "sections.undetermined the undetermined or conflicting information. Use an empty string only when the",
        "material has nothing for that group. Do not invent content. If the required items cannot all be kept",
        "inside the budget, answer {\"status\":\"cannot_preserve\",\"reason\":\"<what does not fit>\"} instead of",
        "dropping anything.",
        "",
        "Material:",
        request.fetch("material")
      ].join("\n")
    end

    # The exact prompt the runner receives without the material: capacity
    # planning must not discover overhead it forgot to count.
    def instruction_bytes(request)
      compaction_prompt(request.merge("material" => "")).bytesize
    end

    def unavailable(request, reason, selection = nil, call = nil, measurements = nil)
      {
        "status" => "unavailable", "text" => nil, "sections" => nil, "reason" => reason,
        "key" => request.fetch("key"), "cache" => "miss", "model" => selection&.fetch("chosen", nil),
        "selection" => selection, "preserved" => [], "call" => call, "measurements" => measurements,
        "unit" => UNIT, "rule_version" => @rule_version
      }
    end

    # Process-wide single flight per key, shared by every instance in this
    # process (the caller may build a compactor per ask). The first asker leads;
    # askers that arrive while it runs wait for that one result and reuse it,
    # success or failure alike. The entry is removed once the result is
    # published, so a later request is a fresh attempt (a failed compaction is
    # never reused from the cache) and no waiter can be left with a second,
    # redundant leader.
    def run_flight(key)
      leader = false
      flight = self.class.flight_lock.synchronize do
        current = self.class.flights[key]
        if current.nil?
          current = { "mutex" => Mutex.new, "cond" => ConditionVariable.new, "done" => false, "result" => nil }
          self.class.flights[key] = current
          leader = true
        end
        current
      end

      unless leader
        shared = flight.fetch("mutex").synchronize do
          flight.fetch("cond").wait(flight.fetch("mutex")) until flight.fetch("done")
          flight.fetch("result")
        end
        raise shared.fetch("raised") if shared.is_a?(Hash) && shared.key?("raised")

        return shared.merge("flight" => "shared")
      end

      begin
        result = yield
        publish_flight(key, flight, result)
        # A receipt consumed from another process already reports itself as
        # shared; only a locally produced result is the leader's.
        result.merge("flight" => result["flight"] || "leader")
      rescue StandardError => error
        publish_flight(key, flight, "raised" => error)
        raise
      end
    end

    def publish_flight(key, flight, result)
      flight.fetch("mutex").synchronize do
        flight["result"] = result
        flight["done"] = true
        flight.fetch("cond").broadcast
      end
      self.class.flight_lock.synchronize do
        self.class.flights.delete(key) if self.class.flights[key].equal?(flight)
      end
    end

    # Cross-process flight receipt. A successful compaction is shared through the
    # cache; a failed one is not a valid summary, so the only thing shared is the
    # receipt itself, and only with a process that was already asking when it was
    # produced (`asked_at` at or before the failure's completion). A later
    # request is a fresh attempt and may pay again.
    def cross_process_flight(key, asked_at)
      path = flight_receipt_path(key)
      receipt = read_json_path(path)
      completed = receipt["completed_at"].to_s
      if receipt["result"].is_a?(Hash) && !completed.empty?
        produced = Time.parse(completed)
        fresh = Time.now.utc - produced <= FLIGHT_RECEIPT_TTL_SECONDS
        if fresh && asked_at <= produced
          return receipt["result"].merge("flight" => "shared", "reason" => receipt["result"]["reason"].to_s,
                                         "shared_receipt" => true)
        end
      end
      nil
    rescue ArgumentError
      nil
    end

    def write_cross_process_flight(key, result)
      write_json_path(flight_receipt_path(key),
                       "completed_at" => Time.now.utc.iso8601(9), "result" => result.merge("flight" => nil))
    rescue StandardError
      nil
    end

    def flight_receipt_path(key)
      File.join(lock_dir, "#{key}.flight.json")
    end

    def with_file_lock(path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def lock_dir
      File.join(@cache_dir, "locks")
    end

    def store(request, text, sections, chosen, selection, outcome)
      with_file_lock(File.join(@cache_dir, "store.lock")) do
        document = read_store("cache.json")
        entries = document["entries"].is_a?(Hash) ? document["entries"] : {}
        entries[request.fetch("key")] = {
          "rule_version" => @rule_version, "selection_version" => @selection_version,
          "purpose" => request.fetch("purpose"), "material_sha256" => request.fetch("material_sha256"),
          "must_keep" => request.fetch("must_keep"), "output_budget_bytes" => request.fetch("output_budget_bytes"),
          "unit" => UNIT, "text" => text, "sections" => sections, "text_bytes" => text.bytesize,
          "model" => chosen.fetch("model"), "selection" => selection, "call" => outcome["call"],
          "measurements" => outcome.fetch("measurements"), "created_at" => @clock.call.utc.iso8601
        }
        fresh = entries.sort_by { |_key, entry| entry.is_a?(Hash) ? entry["created_at"].to_s : "" }.last(MAX_CACHE_ENTRIES)
        write_store("cache.json", "schema_version" => SCHEMA_VERSION, "entries" => fresh.to_h)
      end
    end

    # The real measurements of a completed compaction call. Only measured bytes
    # and seconds are stored; an unmeasured call records nothing, and a later
    # selection reads "unknown" rather than a guessed rate.
    def record_speed(model, measured)
      return if measured["input_bytes"].to_i <= 0 || measured["seconds"].to_f <= 0

      with_file_lock(File.join(@cache_dir, "store.lock")) do
        document = read_store("speed.json")
        models = document["models"].is_a?(Hash) ? document["models"] : {}
        observations = Array(models[model])
        observations << { "input_bytes" => measured["input_bytes"], "output_bytes" => measured["output_bytes"],
                          "seconds" => measured["seconds"], "at" => measured["recorded_at"] }
        models[model] = observations.last(MAX_SPEED_OBSERVATIONS)
        write_store("speed.json", "schema_version" => SCHEMA_VERSION, "models" => models)
      end
    end

    def speed_summary(model)
      observations = Array(read_store("speed.json").dig("models", model))
        .select { |item| item.is_a?(Hash) && item["input_bytes"].to_i.positive? && item["seconds"].to_f.positive? }
      return { "known" => false, "observations" => observations.length } if observations.empty?

      rates = observations.map { |item| item["input_bytes"].to_f / item["seconds"].to_f }.sort
      seconds = observations.map { |item| item["seconds"].to_f }.sort
      { "known" => true, "observations" => observations.length,
        "median_seconds" => median(seconds).round(3), "input_bytes_per_second" => median(rates).round(2),
        "unit" => "utf8_bytes_per_second" }
    end

    def median(sorted)
      middle = sorted.length / 2
      sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def read_store(name)
      read_json_path(File.join(@cache_dir, name))
    end

    def write_store(name, document)
      write_json_path(File.join(@cache_dir, name), document)
    end

    def read_json_path(path)
      return {} unless File.file?(path)

      document = JSON.parse(File.read(path))
      document.is_a?(Hash) ? document : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    # One atomic, permission-tightened write; a failed write leaves the previous
    # document untouched.
    def write_json_path(path, document)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      temporary = "#{path}.#{Process.pid}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.generate(document))
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      rescue StandardError
        File.unlink(temporary) if File.exist?(temporary)
        raise
      end
    end
  end
end
