# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "fileutils"

module Orbit
  # Shared independent-check plumbing: prompt construction, bounded program
  # context, schema validation, usage and process-group stop handling.
  # OmpCheckRunner is the production subclass and owns the actual reviewer
  # process. `stop!`
  # terminates only this runner's process group and confirms exit, keeping
  # diagnostics. `close` releases the run, stopping it first if needed.
  #
  # The program never relaxes the sandbox, never falls back to another model,
  # never guesses prices, and never turns a failed or malformed model response
  # into a pass.
  #
  # The program context handed to an independent check is deterministically
  # bounded (see CONTEXT_BYTE_LIMIT): history facts that can still change a
  # verdict are kept, unbounded accumulation is not. The original instruction,
  # amendments and named basis are separate prompt sections and stay verbatim.
  class CheckRunner
    ROLES = %w[reviewer process_reviewer adjudicator].freeze
    VERDICTS = %w[continue correct pause complete needs_user].freeze
    FINDING_KEYS = %w[id requirement evidence action].freeze
    RESULT_KEYS = %w[verdict reason findings resolved_ids next_check_seconds].freeze
    DEFAULT_STOP_GRACE_SECONDS = 5

    # Program-context compression. An independent check judges the current
    # artifact and the facts that can still change a verdict, not an unbounded
    # history. Long strings keep a bounded prefix plus `…[original
    # length:sha256]` (never a silent tail cut), growing lists keep a bounded
    # newest tail, and the rendered JSON is hard-capped. Instruction,
    # amendments and named basis are never compressed.
    CONTEXT_BYTE_LIMIT = 65_536
    CONTEXT_STRING_CAP = 2_000
    CONTEXT_EVENT_CAP = 500
    CONTEXT_MEMBER_RESULT_CAP = 600
    CONTEXT_CAPS = {
      string_cap: CONTEXT_STRING_CAP,
      list_limit: 40,
      root_observation_limit: 8,
      event_limit: 12,
      finding_limit: 200,
      recheck_limit: 200,
      review_focus_limit: 200,
      decision_limit: 3,
      decision_finding_limit: 30,
      member_limit: 25,
      member_result_list_limit: 10,
      omitted_id_limit: 50
    }.freeze
    # Ordered budget pressure at the hard byte cap: each level is cumulative
    # and drops data that cannot still change a verdict before newer findings,
    # decisions and root facts shrink.
    CONTEXT_DEGRADATIONS = [
      nil,
      "uncopied entries dropped",
      "member results dropped",
      "recent events dropped",
      "decision findings dropped"
    ].freeze
    CONTEXT_KEYS = %w[
      root review_focus findings recent_events recheck execution_members decisions dispute estimate hard_deadline
      elapsed_seconds project_rules uncopied_entries
    ].freeze
    CONTEXT_FINDING_FIELDS = %w[id requirement evidence action status check].freeze
    # review_focus is a current-input clue from the fixed snapshot diff, not
    # history: the bounded added/modified/deleted path lists the runtime
    # derives from the snapshot manifest.
    CONTEXT_FOCUS_KEYS = %w[added modified deleted].freeze
    CONTEXT_MEMBER_FIELDS = %w[kind adapter host model thread_id status registered_at reported_turn delegation_basis].freeze
    CONTEXT_DECISION_FIELDS = %w[
      check dispute reason resolved_ids finding_ids input_digest artifact_root artifact_digest decided_at
    ].freeze
    CONTEXT_OPEN = "open"

    class Error < StandardError; end

    Run = Struct.new(:pid, :pgid, :directory, :output_dir, :role, :model, :schema_path,
                     :prompt_path, :events_path, :stderr_path, :last_message_path,
                     :started_at, keyword_init: true)

    def initialize(model:, executable:, schema: nil, stop_grace_seconds: DEFAULT_STOP_GRACE_SECONDS)
      raise Error, "model is required (no automatic model fallback)" if model.to_s.strip.empty?
      raise Error, "executable is required" if executable.to_s.strip.empty?
      raise Error, "stop_grace_seconds must be a positive number" unless stop_grace_seconds.to_f.positive?

      @model = model.to_s
      @executable = executable.to_s
      @schema = schema ? File.expand_path(schema.to_s) : default_schema_path
      @stop_grace_seconds = stop_grace_seconds.to_f
      @run = nil
      @result = nil
      @failure = nil
      @reaped = false
      @stopped = false
      @closed = false
    end

    attr_reader :model, :executable

    def stop!(grace: @stop_grace_seconds)
      raise Error, "runner is closed" if @closed
      raise Error, "no check run" unless @run
      return if @reaped && !group_alive?

      @stopped = true
      signal_group("TERM")
      return if wait_for_exit(grace)

      signal_group("KILL")
      return if wait_for_exit(grace)

      raise Error, "could not confirm exit of check process group #{@run.pgid}"
    end

    def close
      return if @closed

      stop! if active?
      @closed = true
    end

    def usage
      return nil unless @run && File.file?(@run.events_path)

      observed = nil
      File.foreach(@run.events_path) do |line|
        event = JSON.parse(line)
        observed = event["usage"] if event["type"] == "turn.completed"
      rescue JSON::ParserError
        next
      end
      observed
    end

    private

    def active?
      @run && (!@reaped || group_alive?)
    end

    def default_schema_path
      File.expand_path("../../contracts/check-result.schema.json", __dir__)
    end

    def validate_snapshot!(directory)
      path = File.realpath(directory.to_s)
      raise Error, "snapshot directory is not a directory: #{directory}" unless File.directory?(path)

      path
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error, "snapshot directory does not exist: #{directory}"
    end

    def validate_output_dir!(output_dir, snapshot)
      path = File.expand_path(output_dir.to_s)
      FileUtils.mkdir_p(path)
      path = File.realpath(path)
      raise Error, "output_dir must not be inside the fixed snapshot: #{path}" if within?(snapshot, path)
      raise Error, "output_dir is not a directory: #{path}" unless File.directory?(path)

      path
    rescue Errno::EEXIST, Errno::ENOTDIR
      raise Error, "output_dir is not usable: #{output_dir}"
    end

    def build_prompt(snapshot:, inputs:, context:, role:)
      instruction = fetch_instruction(inputs)
      amendments = input_items(inputs, "amendments")
      basis = input_items(inputs, "basis")
      program_context = compress_context(context)
      context_text = render_context(program_context)

      parts = [role_prompt(role, focus: review_focus_present?(program_context))]
      parts << "## Original instruction (verbatim)\n\n#{instruction}"
      unless amendments.empty?
        parts << "## Amendments (latest valid input, apply in order)\n\n#{render_items(amendments, 'Amendment')}"
      end
      unless basis.empty?
        parts << "## Named basis (verbatim)\n\n#{render_items(basis, 'Basis')}"
      end
      recheck = program_context.is_a?(Hash) ? program_context["recheck"] : nil
      if recheck.is_a?(Hash) && recheck["findings"].is_a?(Array) && !recheck["findings"].empty?
        parts << "## Pending clues from a check that went stale\n\n" \
                 "The program record below carries these findings under recheck (check #{recheck['check']}); they " \
                 "were reported against an older version and were not applied. Verify each clue against the " \
                 "current fixed snapshot: if it still holds, include it in findings and reuse its id; if it no " \
                 "longer holds, list its id in resolved_ids and explain. Every listed id must appear in either " \
                 "findings or resolved_ids; do not silently ignore a clue. Clue ids dropped at the byte cap are " \
                 "recorded in recheck_omitted."
      end
      parts << "## Current execution context (program record)\n\n" \
               "This record is deterministic and bounded: long strings keep a prefix plus " \
               "`…[original length:sha256]`, growing lists keep their newest entries, and " \
               "context_compression, findings_omitted, recheck_omitted and review_focus_omitted " \
               "record what was trimmed. The original instruction, amendments and named basis " \
               "above are complete and are not compressed.\n\n" \
               "```json\n#{context_text}\n```"
      parts << "## Fixed artifact snapshot\n\n" \
               "Your working root is the fixed snapshot directory selected by --cd: a read-only copy of the " \
               "delivered workspace plus project rules. The original workspace is not your input. Do not write " \
               "anywhere. If a command would modify a repository, do not run it; report the concrete gap that " \
               "needs isolated verification instead."
      parts << "## Output\n\n" \
               "Return exactly one JSON object matching the attached output schema: verdict, reason, findings, " \
               "resolved_ids, next_check_seconds. verdict is one of: #{VERDICTS.join(', ')}. findings is a list " \
               "of objects with id, requirement, evidence, action. resolved_ids is a list of strings. " \
               "next_check_seconds is a positive integer. No markdown, no code fences, no extra text."
      parts.join("\n\n")
    end

    def fetch_instruction(inputs)
      raise Error, "inputs must be a Hash with instruction/amendments/basis" unless inputs.is_a?(Hash)

      instruction = inputs["instruction"]
      unless instruction.is_a?(String) && !instruction.empty?
        raise Error, "inputs.instruction must be a non-empty string"
      end

      instruction
    end

    def input_items(inputs, key)
      items = inputs[key] || []
      raise Error, "inputs.#{key} must be an array" unless items.is_a?(Array)

      items.map do |item|
        case item
        when String
          { "text" => item, "label" => nil }
        when Hash
          text = item["text"]
          raise Error, "inputs.#{key} entries must carry a text string" unless text.is_a?(String)

          label = [item["source"], item["path"]].compact.join(" - ")
          { "text" => text, "label" => label.empty? ? nil : label }
        else
          raise Error, "inputs.#{key} entries must be strings or objects with text"
        end
      end
    end

    def render_items(items, title)
      items.each_with_index.map do |item, index|
        heading = item["label"] ? "#{title} #{index + 1} (#{item['label']})" : "#{title} #{index + 1}"
        "### #{heading}\n\n#{item['text']}"
      end.join("\n\n")
    end

    # --- Deterministic program-context compression -----------------------

    def compress_context(context)
      case context
      when Hash
        compress_program_context(context)
      when Array
        # Non-runtime fallback shape: bounded, no degradation ladder.
        compressed = bound_value(context, CONTEXT_CAPS.merge(string_cap: 500, list_limit: 20))
        return compressed if context_bytes(compressed) <= CONTEXT_BYTE_LIMIT

        { "context_compression" => "context array exceeded #{CONTEXT_BYTE_LIMIT} bytes" }
      when String
        bound_raw_context(context)
      else
        raise Error, "context must be a Hash, Array or String"
      end
    rescue JSON::JSONError, TypeError => e
      raise Error, "context must be JSON-serializable: #{e.message}"
    end

    def compress_program_context(context)
      CONTEXT_DEGRADATIONS.each_index do |level|
        compressed = build_compressed_context(context, CONTEXT_CAPS, level)
        return compressed if context_bytes(compressed) <= CONTEXT_BYTE_LIMIT
      end
      caps = CONTEXT_CAPS
      last = CONTEXT_DEGRADATIONS.length - 1
      loop do
        caps = reduce_caps(caps)
        compressed = build_compressed_context(context, caps, last)
        return compressed if context_bytes(compressed) <= CONTEXT_BYTE_LIMIT
        break if reduce_caps(caps) == caps
      end

      # Last resort: still a valid JSON object, never a partial document.
      { "context_compression" => "program context omitted: it did not fit in #{CONTEXT_BYTE_LIMIT} bytes" }
    end

    def build_compressed_context(context, caps, level)
      compressed = { "root" => compress_root(context["root"], caps) }
      focus, focus_omitted = compress_review_focus(context["review_focus"], caps)
      unless focus.nil?
        compressed["review_focus"] = focus
        compressed["review_focus_omitted"] = focus_omitted if focus_omitted
      end
      findings, findings_omitted = compress_open_findings(context["findings"], caps)
      compressed["findings"] = findings
      compressed["findings_omitted"] = findings_omitted if findings_omitted
      events = level < 3 ? recent_tail(context["recent_events"], caps[:event_limit]) : []
      compressed["recent_events"] = events.map do |event|
        bound_value(event, caps, string_cap: [caps[:string_cap], CONTEXT_EVENT_CAP].min)
      end
      recheck, recheck_omitted = compress_recheck(context["recheck"], caps)
      compressed["recheck"] = recheck
      compressed["recheck_omitted"] = recheck_omitted if recheck_omitted
      compressed["execution_members"] = compress_members(context["execution_members"], caps, level.zero?)
      compressed["decisions"] = recent_tail(context["decisions"], caps[:decision_limit]).map do |decision|
        compress_decision(decision, caps, level < 4)
      end
      compressed["dispute"] = bound_value(context["dispute"], caps)
      compressed["estimate"] = bound_value(context["estimate"], caps)
      compressed["hard_deadline"] = bound_value(context["hard_deadline"], caps)
      compressed["elapsed_seconds"] = context["elapsed_seconds"]
      compressed["project_rules"] = bound_rule_paths(context["project_rules"], 500)
      compressed["uncopied_entries"] = level.zero? ? bound_value(context["uncopied_entries"], caps) : []
      (context.keys - CONTEXT_KEYS).each { |key| compressed[key] = bound_value(context[key], caps) }
      if level.positive? || caps != CONTEXT_CAPS
        compressed["context_compression"] = {
          "string_cap" => caps[:string_cap],
          "degraded" => CONTEXT_DEGRADATIONS[1..level].compact
        }
      end
      compressed
    end

    def compress_root(root, caps)
      return bound_value(root, caps) unless root.is_a?(Hash)

      root.each_with_object({}) do |(key, value), compressed|
        compressed[key] = if key == "observations" && value.is_a?(Array)
                            recent_tail(value, caps[:root_observation_limit]).map { |entry| bound_value(entry, caps) }
                          else
                            bound_value(value, caps)
                          end
      end
    end

    # review_focus is a priority clue, not history: the runtime's bounded
    # added/modified/deleted path lists from the fixed snapshot manifest. It is
    # normalized (de-duplicated, sorted) so equal inputs render identically and
    # trimming is stable, kept at every degradation level, and bounded per
    # category with an explicit omission record. Unrecognized shapes are still
    # preserved through the generic bounded rendering; neither form is dropped.
    def compress_review_focus(focus, caps)
      return nil if focus.nil?

      categories = normalize_review_focus(focus)
      return [bound_value(focus, caps), nil] unless categories

      limit = caps[:review_focus_limit]
      kept = {}
      omitted = []
      CONTEXT_FOCUS_KEYS.each do |key|
        paths = categories.fetch(key)
        kept[key] = paths.first(limit)
        omitted.concat(paths.drop(limit))
      end
      [kept, omission_record(omitted, caps)]
    end

    def normalize_review_focus(focus)
      return nil unless focus.is_a?(Hash) && (focus.keys - CONTEXT_FOCUS_KEYS).empty?

      CONTEXT_FOCUS_KEYS.each_with_object({}) do |key, normalized|
        value = focus[key]
        return nil unless value.nil? || value.is_a?(Array)

        paths = value.map { |entry| focus_path(entry) }
        return nil unless paths.all? { |path| path.is_a?(String) }

        normalized[key] = paths.reject(&:empty?).uniq.sort
      end
    end

    def focus_path(entry)
      return entry if entry.is_a?(String)
      return entry["path"] if entry.is_a?(Hash) && entry["path"].is_a?(String)

      nil
    end

    def compress_open_findings(findings, caps)
      entries =
        case findings
        when Hash then findings.map { |key, finding| [finding_id(finding, key), finding] }
        when Array then findings.each_with_index.map { |finding, index| [finding_id(finding, "finding-#{index}"), finding] }
        when nil then []
        else return [bound_value(findings, caps), nil]
        end
      ordered = entries.select { |_id, finding| open_finding?(finding) }
                       .sort_by { |id, finding| [finding["check"].to_i, id.to_s] }
      kept = recent_tail(ordered, caps[:finding_limit])
      [kept.to_h { |id, finding| [id.to_s, compress_finding_fields(finding, caps)] },
       omission_record(ordered[0...(ordered.length - kept.length)].map { |id, _| id.to_s }, caps)]
    end

    def compress_recheck(recheck, caps)
      return [bound_value(recheck, caps), nil] unless recheck.is_a?(Hash)

      list = recheck["findings"].is_a?(Array) ? recheck["findings"] : []
      kept = recent_tail(list, caps[:recheck_limit])
      omitted = list[0...(list.length - kept.length)].each_with_index.map do |finding, index|
        finding_id(finding, "clue-#{index}")
      end
      [{ "check" => recheck["check"], "at" => recheck["at"],
         "findings" => kept.map { |finding| compress_finding_fields(finding, caps) } },
       omission_record(omitted, caps)]
    end

    def compress_members(members, caps, keep_results)
      recent_tail(members, caps[:member_limit]).map do |member|
        next bound_value(member, caps) unless member.is_a?(Hash)

        compressed = CONTEXT_MEMBER_FIELDS.each_with_object({}) do |field, fields|
          fields[field] = bound_string_field(member[field], caps[:string_cap]) if member.key?(field)
        end
        if member["stop_confirmation"].is_a?(Hash)
          compressed["stop_confirmed"] = member.dig("stop_confirmation", "confirmed")
        end
        if keep_results && member.key?("result")
          compressed["result"] = bound_value(
            member["result"], caps,
            string_cap: [caps[:string_cap], CONTEXT_MEMBER_RESULT_CAP].min,
            list_limit: caps[:member_result_list_limit]
          )
        end
        compressed
      end
    end

    def compress_decision(decision, caps, keep_findings)
      return bound_value(decision, caps) unless decision.is_a?(Hash)

      result = decision["result"].is_a?(Hash) ? decision["result"] : {}
      findings = keep_findings ? recent_tail(result["findings"], caps[:decision_finding_limit]) : []
      compressed = CONTEXT_DECISION_FIELDS.each_with_object({}) do |field, fields|
        next unless decision.key?(field)

        fields[field] = bound_value(decision[field], caps, string_cap: caps[:string_cap])
      end
      compressed["result"] = {
        "verdict" => result["verdict"],
        "reason" => bound_string_field(result["reason"], caps[:string_cap]),
        "findings" => findings.map { |finding| compress_finding_fields(finding, caps) },
        "resolved_ids" => bound_value(result["resolved_ids"], caps, string_cap: caps[:string_cap]),
        "next_check_seconds" => result["next_check_seconds"]
      }
      compressed
    end

    def compress_finding_fields(finding, caps)
      return bound_value(finding, caps) unless finding.is_a?(Hash)

      CONTEXT_FINDING_FIELDS.each_with_object({}) do |field, compressed|
        next unless finding.key?(field)

        compressed[field] = if field == "status" || field == "check"
                              finding[field]
                            else
                              bound_string_field(finding[field], caps[:string_cap])
                            end
      end
    end

    def finding_id(finding, fallback)
      id = finding.is_a?(Hash) ? finding["id"] : nil
      id.nil? || id.to_s.empty? ? fallback.to_s : id.to_s
    end

    def open_finding?(finding)
      finding.is_a?(Hash) && (finding["status"].nil? || finding["status"] == CONTEXT_OPEN)
    end

    # Omitted stable ids stay traceable: the ids that fit plus a digest over
    # every omitted id, so nothing disappears silently at the byte cap.
    def omission_record(omitted_ids, caps)
      return nil if omitted_ids.empty?

      { "count" => omitted_ids.length,
        "ids_sha256" => Digest::SHA256.hexdigest(JSON.generate(omitted_ids)),
        "ids" => omitted_ids.last(caps[:omitted_id_limit]) }
    end

    def bound_value(value, caps, string_cap: nil, list_limit: nil)
      cap = string_cap || caps[:string_cap]
      limit = list_limit || caps[:list_limit]
      case value
      when Hash
        value.sort_by { |key, _| key.to_s }.to_h do |key, entry|
          [key.to_s, bound_value(entry, caps, string_cap: cap, list_limit: limit)]
        end
      when Array
        recent_tail(value, limit).map { |entry| bound_value(entry, caps, string_cap: cap, list_limit: limit) }
      when String then bound_string(value, cap)
      when Numeric, TrueClass, FalseClass, NilClass then value
      else bound_string(value.to_s, cap)
      end
    end

    def bound_string_field(value, cap)
      value.is_a?(String) ? bound_string(value, cap) : value
    end

    # Project rule paths are contract input, not history: every path is kept,
    # only an oversized path itself is bounded.
    def bound_rule_paths(value, cap)
      case value
      when Array then value.map { |entry| bound_rule_paths(entry, cap) }
      when String then bound_string(value, cap)
      when Numeric, TrueClass, FalseClass, NilClass then value
      else bound_string(value.to_s, cap)
      end
    end

    def bound_string(value, cap)
      text = value.to_s
      return text if text.length <= cap

      "#{text[0, cap]}…[#{text.length}:#{Digest::SHA256.hexdigest(text)}]"
    end

    # Raw (non-JSON) contexts are byte-bounded too, with the same prefix plus
    # original length and SHA-256.
    def bound_raw_context(text)
      return text if text.bytesize <= CONTEXT_BYTE_LIMIT

      prefix = text.byteslice(0, CONTEXT_BYTE_LIMIT - 256).to_s.scrub
      "#{prefix}…[#{text.length}:#{Digest::SHA256.hexdigest(text)}]"
    end

    def recent_tail(value, limit)
      value.is_a?(Array) ? value.last(limit) : []
    end

    def context_bytes(value)
      JSON.pretty_generate(value).bytesize
    end

    def reduce_caps(caps)
      caps.to_h { |key, value| [key, key == :omitted_id_limit ? value : [value / 2, 1].max] }
    end

    def render_context(context)
      case context
      when Hash, Array
        JSON.pretty_generate(context)
      when String
        context
      else
        raise Error, "context must be a Hash, Array or String"
      end
    rescue JSON::JSONError, TypeError => e
      raise Error, "context must be JSON-serializable: #{e.message}"
    end

    def role_prompt(role, focus: false)
      if role == "adjudicator"
        "You are an independent Orbit adjudicator session. The program, not you, owns messages, timing and " \
          "stop control. Decide only the real disputes listed in the context: weigh both sides' concrete " \
          "evidence and issue an executable conclusion within the original goal and authorization. Do not " \
          "vote, do not require the parties to agree, and do not change requirements, acceptance or scope. " \
          "You may overturn the Root or the reviewer on a disputed point when the evidence supports it; list " \
          "the reviewed ids in resolved_ids and explain the decision in reason. Read the relevant AGENTS.md " \
          "files inside the fixed snapshot; project rules apply to your judgment too."
      elsif role == "process_reviewer"
        "You are the existing independent Orbit checker, focused on a suspected execution-process issue. " \
          "Read the original instruction, amendments, recent host observations and events, and only the " \
          "snapshot files needed to verify a concrete concern. Jev's probability is a scheduling signal, " \
          "not evidence. Determine whether the Root is actually stuck or off track and give a specific " \
          "correction only when supported by current evidence. Do not resolve prior artifact findings or " \
          "declare the task complete; return continue when no actionable issue is established. Pause only " \
          "for an authorization boundary or a concrete adjudicated correction that stays unimplemented. " \
          "A pending model_evidence_request in the context is part of the authorized workflow: research " \
          "responsive to it is relevant work, not off-track solely because the original user instruction " \
          "did not mention it. Still judge concrete task progress. " \
          "Work strictly read-only and follow relevant AGENTS.md rules in the fixed snapshot."
      else
        prompt = "You are an independent Orbit check session, separate from the Root session that produced the " \
          "artifact. Work strictly read-only: never modify the snapshot or the shared project. Judge the " \
          "fixed artifact against the original instruction, amendments and named basis: find work that is " \
          "missing, wrong or extra; judge whether continuing the current work is worthwhile from the " \
          "instruction and concrete evidence. Do not require or run the full test suite, and do not treat " \
          "test counts or elapsed time as failure; name specific gaps that need isolated verification " \
          "instead. Verify every explicit input shape, field-count, validation or rejection rule against the " \
          "code that enforces it: a rule the implementation does not actually enforce, including accepting " \
          "the wrong shape or count or input that must be rejected, is a finding even when the provided " \
          "tests pass. Do not change requirements, do not invent acceptance criteria, and do not turn an " \
          "engineering preference into a blocker. Read the relevant AGENTS.md files inside the fixed " \
          "snapshot; project rules apply to your judgment too. Only reuse a history finding id when it is " \
          "the same real problem. The program record is your decision memory: it carries prior decisions and " \
          "settled findings. Reuse the existing finding id for the same problem, and do not re-raise a point " \
          "that a decision, a resolution or an earlier withdrawal already settled unless the fixed artifact, " \
          "the check input or concrete new evidence differs from what that decision saw; the same point on " \
          "unchanged artifact, input and evidence is not a new finding. If a finding or a previously " \
          "withdrawn conclusion no longer applies, list its id in resolved_ids and explain in reason; a " \
          "finding withdrawn by an independent adjudication is not an unresolved problem. Verdict rules: " \
          "complete only when the instruction is actually satisfied and known problems are resolved. While Root " \
          "is still executing, never " \
          "declare complete; use correct when an actionable current finding needs attention, otherwise " \
          "continue. Choose pause only for an authorization boundary or a concrete adjudicated correction " \
          "that stays unimplemented, never for estimate overruns, test counts or preference; choose " \
          "needs_user only when the next step needs a decision only the user can make."
        focus ? "#{prompt} #{review_focus_note}" : prompt
      end
    end

    # The reviewer starts from the bounded snapshot changes the runtime selected
    # and then must keep checking everything the original requirement demands:
    # review_focus is a priority clue, never a scope limit. The note is added
    # only when the program record actually carries paths.
    def review_focus_present?(program_context)
      return false unless program_context.is_a?(Hash)

      focus = program_context["review_focus"]
      case focus
      when Hash then focus.any? { |_key, value| value.is_a?(Array) && !value.empty? }
      when Array then !focus.empty?
      else false
      end
    end

    def review_focus_note
      "The program record's review_focus lists the paths the fixed snapshot added, modified or deleted. " \
        "Check those paths and their direct dependencies first, then extend to whatever the original " \
        "instruction, amendments and named basis require. review_focus is a priority clue, not a scope " \
        "limit: never ignore a requirement because its files are not listed, and never treat the listed " \
        "files as the only work to check."
    end

    def write_run_record(run)
      record = {
        "format" => "orbit-check-run-1",
        "model" => run.model,
        "role" => run.role,
        "pid" => run.pid,
        "pgid" => run.pgid,
        "started_at" => run.started_at,
        "snapshot" => run.directory,
        "output_dir" => run.output_dir,
        "schema" => run.schema_path,
        "executable" => @executable
      }
      write_file(File.join(run.output_dir, "run.json"), JSON.pretty_generate(record) + "\n")
    end

    def write_file(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(bytes)
        file.flush
      end
    end

    def wait_nonblock
      return nil if @reaped

      result = Process.waitpid2(@run.pid, Process::WNOHANG)
      return nil unless result

      @reaped = true
      result.last
    rescue Errno::ECHILD
      @reaped = true
      nil
    end

    def wait_for_exit(grace)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
      loop do
        wait_nonblock unless @reaped
        return true if @reaped && !group_alive?
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
    end

    def group_alive?
      return false unless @run

      Process.kill(0, -@run.pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def signal_group(signal)
      Process.kill(signal, -@run.pgid)
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM
      raise Error, "not permitted to signal check process group #{@run.pgid}"
    end

    def validate_result(value)
      problems = []
      unless value.is_a?(Hash)
        raise Error, "check result must be a JSON object, got #{value.class}"
      end

      extra = value.keys - RESULT_KEYS
      missing = RESULT_KEYS - value.keys
      problems << "unexpected keys: #{extra.join(', ')}" unless extra.empty?
      problems << "missing keys: #{missing.join(', ')}" unless missing.empty?
      problems << "verdict must be one of: #{VERDICTS.join(', ')}" unless VERDICTS.include?(value["verdict"])
      unless value["reason"].is_a?(String) && !value["reason"].empty?
        problems << "reason must be a non-empty string"
      end
      problems.concat(validate_findings(value["findings"]))
      unless value["resolved_ids"].is_a?(Array) && value["resolved_ids"].all? { |id| id.is_a?(String) && !id.empty? }
        problems << "resolved_ids must be an array of non-empty strings"
      end
      unless value["next_check_seconds"].is_a?(Integer) && value["next_check_seconds"].positive?
        problems << "next_check_seconds must be a positive integer"
      end
      return value if problems.empty?

      raise Error, "check result does not match contracts/check-result.schema.json: #{problems.join('; ')}"
    end

    def validate_findings(findings)
      unless findings.is_a?(Array)
        return ["findings must be an array"]
      end

      findings.each_with_index.flat_map do |finding, index|
        unless finding.is_a?(Hash) && finding.keys.sort == FINDING_KEYS.sort
          next ["findings[#{index}] must be an object with exactly: #{FINDING_KEYS.join(', ')}"]
        end

        FINDING_KEYS.filter_map do |key|
          value = finding[key]
          unless value.is_a?(String) && !value.empty?
            "findings[#{index}].#{key} must be a non-empty string"
          end
        end
      end
    end

    def failure_message(status)
      code = status.exitstatus || "signal #{status.termsig}"
      parts = ["check run failed (exit #{code})"]
      details = tail(@run.stderr_path, 4096)
      parts << "stderr:\n#{details}" unless details.strip.empty?
      parts << "events: #{@run.events_path}"
      parts << "output_dir: #{@run.output_dir}"
      parts.join("\n")
    end

    def tail(path, limit)
      return "" unless File.file?(path)

      File.open(path, "rb") do |file|
        file.seek([File.size(path) - limit, 0].max)
        file.read.to_s
      end
    end

    def within?(root, path)
      path == root || path.start_with?("#{root}/")
    end
  end
end
