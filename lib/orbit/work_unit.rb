# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Orbit
  # Work units (main proposal §5.2, ADR-009 §6.3): the traceable handoff
  # object a Root declares before dispatching a native member. Each unit
  # carries a verifiable objective, requirement references, context and
  # confirmed decisions, the allowed paths/tools/commands scope, acceptance
  # criteria, dependencies and escalation conditions, plus the task input
  # version (input_digest) and the real artifact_root it was declared
  # against — the root is captured from the TaskRecord's current workspace,
  # never accepted from the submitter.
  #
  # Persisted per task in work-units.json under the same discipline as
  # members.json (temp file + fsync + rename + directory fsync, own lock,
  # separate from state.json whose sole writer is the runtime). A corrupt or
  # foreign file raises: a silently empty store would let a dispatch bind
  # against a fabricated unit. Format orbit-work-units-2 replaces the
  # undelivered v1, which had no workspace binding; a v1 file is rejected
  # explicitly rather than migrated by guesswork.
  #
  # This store only records and gates the handoff data. Actual tool/scope
  # interception at the member's tool entry is enforced by the host (Root's
  # seam), not by this class; a declared scope is a checked declaration, not
  # a permission system.
  class WorkUnitStore
    FILE_NAME = "work-units.json"
    LOCK_NAME = "work-units.lock"
    FORMAT = "orbit-work-units-2"
    STATUSES = %w[declared bound accepted rejected failed].freeze
    FINISH_STATUSES = %w[accepted rejected failed].freeze
    MAX_UNITS = 128
    MAX_UNIT_BYTES = 32 * 1024

    class Error < StandardError; end

    # record is an Orbit::TaskRecord (path, input_digest, durable_write,
    # event). The store never writes state.json.
    def initialize(record)
      @record = record
    end

    # Declare a new unit against the CURRENT task input version. Returns the
    # stored unit. spec (string or symbol keys):
    #   objective, acceptance, escalation   non-empty strings
    #   requirements                        non-empty array of references
    #   context, decisions                  optional string / array
    #   allowed_paths, allowed_tools,
    #   allowed_commands                    scope arrays; at least one non-empty
    #   dependencies                        existing unit ids, all declared earlier
    def declare(spec)
      fields = normalize_spec(spec)
      dependencies = fields.delete("dependencies")
      input_digest = @record.input_digest
      artifact_root = current_artifact_root
      raise Error, "task workspace source is missing; a work unit cannot be declared without the real artifact_root" if artifact_root.nil?

      with_lock do
        document = read_document
        units = document.fetch("units")
        raise Error, "work unit limit reached (#{MAX_UNITS})" if units.length >= MAX_UNITS

        unknown = dependencies.reject { |id| units.key?(id) }
        raise Error, "unknown work unit dependencies: #{unknown.join(', ')}" unless unknown.empty?

        unit = {
          "id" => "wu-#{SecureRandom.hex(8)}", "task_id" => task_id,
          "status" => "declared", "input_digest" => input_digest, "artifact_root" => artifact_root,
          "declared_at" => now,
          "dispatches" => [], "member_id" => nil, "tool_call_id" => nil, "model" => nil,
          "result" => nil, "verification" => nil, "finished_at" => nil
        }.merge(fields).merge("dependencies" => dependencies)
        raise Error, "work unit is too large" if JSON.generate(unit).bytesize > MAX_UNIT_BYTES

        units[unit.fetch("id")] = unit
        write_document(document)
        attach_event_error(unit, emit("work_unit_declared", unit))
      end
    end

    # Deep copy of one unit, or nil when absent.
    def read(id)
      with_lock { copy(read_document.fetch("units")[validate_id(id)]) }
    end

    # All units in declaration order (deep copies; mutating them changes
    # nothing).
    def list
      with_lock { read_document.fetch("units").values.map { |unit| copy(unit) } }
    end

    # Bind the unit to one actual native dispatch. Refuses when the task
    # input moved since declaration (stale requirement version — declare a
    # new unit instead of rebinding), when the workspace was rebound or its
    # source is gone (an old unit never dispatches against a new root),
    # when dependencies are not all accepted, or while a previous dispatch
    # of the same unit is still bound (a rejected/failed finish opens
    # re-dispatch as a new attempt recorded in `dispatches`). Returns the
    # full unit for the handoff.
    def bind(id, member_id:, tool_call_id:, model:, hint_signature: nil, hint_message_id: nil)
      member = text(member_id, "member id", 256)
      call = text(tool_call_id, "tool call id", 256)
      model = text(model, "model", 256)
      unless hint_signature.nil? && hint_message_id.nil?
        hint_signature = text(hint_signature, "hint signature", 256)
        hint_message_id = text(hint_message_id, "delivered hint message id", 256)
      end
      current_digest = @record.input_digest
      current_root = current_artifact_root
      with_lock do
        document = read_document
        unit = document.fetch("units")[validate_id(id)]
        raise Error, "unknown work unit: #{id}" unless unit
        unless %w[declared rejected failed].include?(unit.fetch("status"))
          raise Error, "work unit #{id} is #{unit.fetch('status')}; finish a bound unit before re-dispatch, and never re-dispatch an accepted one"
        end
        unless unit.fetch("input_digest") == current_digest
          raise Error, "work unit #{id} was declared against an older task input; declare a new unit for the current requirements"
        end
        unless !current_root.nil? && unit.fetch("artifact_root") == current_root
          raise Error, "work unit #{id} was declared against a different workspace; declare a new unit for the current artifact_root"
        end
        unfinished = unit.fetch("dependencies").reject do |dep|
          document.fetch("units").dig(dep, "status") == "accepted"
        end
        unless unfinished.empty?
          raise Error, "work unit #{id} has unaccepted dependencies: #{unfinished.join(', ')}"
        end

        # Older v2 records keep only the latest outcome at unit level. Save
        # that known outcome before resetting the active attempt; do not
        # invent results for any earlier dispatches.
        retain_dispatch_outcome(unit) if FINISH_STATUSES.include?(unit.fetch("status"))
        dispatch = { "member_id" => member, "tool_call_id" => call, "model" => model, "bound_at" => now }
        if hint_signature
          dispatch["hint_signature"] = hint_signature
          dispatch["hint_message_id"] = hint_message_id
        end
        unit["dispatches"] = unit.fetch("dispatches") + [dispatch]
        unit["member_id"] = member
        unit["tool_call_id"] = call
        unit["model"] = model
        unit["status"] = "bound"
        unit["result"] = nil
        unit["verification"] = nil
        unit["finished_at"] = nil
        write_document(document)
        attach_event_error(copy(unit), emit("work_unit_bound", unit))
      end
    end

    # Program-observed EXECUTION failure for one EXACT dispatch. The runtime
    # calls this only after a real native turn error on the member's current
    # attempt and only when the member is provably idle (non-streaming, zero
    # active tools and a real empty owner-scoped async running list; any
    # unknown keeps the manual Root finish path). The source is always the
    # native turn error and the timestamp is program-generated: no caller may
    # supply either. Atomicity and ownership rules, all checked inside the
    # lock:
    #   - only a unit that is CURRENTLY bound can be re-marked,
    #   - its LATEST dispatch must match member id + tool call id exactly
    # (both real values; the member's model is recorded, never inferred),
    #   - nothing a Root verdict produced is overwritten (accepted/rejected/
    #     failed units are skipped entirely).
    # The attempt keeps the real native error, its source and finished time;
    # history, prior attempts and the resource ledger are untouched. This is
    # NOT a Root business verdict: no accepted_at, no verification of delivery.
    def record_execution_failure(member_id:, tool_call_id:, error:, model: nil)
      member = text(member_id, "member id", 256)
      call = text(tool_call_id, "tool call id", 256)
      raise Error, "execution failure needs the real native error fact" unless error.is_a?(Hash)
      stamp = now
      with_lock do
        document = read_document
        candidates = document.fetch("units").values.select do |unit|
          unit.fetch("status") == "bound" &&
            (last = unit.fetch("dispatches").last).is_a?(Hash) &&
            last["member_id"] == member && last["tool_call_id"] == call
        end
        # Ambiguity is refused, never guessed: zero matches means the caller's
        # identity is stale/foreign; more than one means the store cannot say
        # which attempt failed.
        return nil unless candidates.length == 1

        unit = candidates.first
        reason = ["native turn error"]
        reason << "HTTP #{error['error_status']}" if error["error_status"].is_a?(Integer)
        reason << error["error_message"].to_s
        unit["status"] = "failed"
        unit["result"] = reason.join(": ").strip[0, 8000]
        unit["verification"] = "program-observed execution failure (native_turn_error); no Root business verdict was written"
        unit["finished_at"] = stamp
        retain_dispatch_outcome(unit)
        failure = unit["dispatches"].last
        failure["failure_source"] = "native_turn_error"
        failure["failure_error"] = error
        failure["failure_model"] = model if model.is_a?(String) && !model.empty?
        write_document(document)
        attach_event_error(copy(unit), emit("work_unit_execution_failed", unit))
      end
    end

    # Record the outcome of a bound unit. `accepted` marks the unit verified
    # against its acceptance criteria and is refused when the task input or
    # the workspace moved during execution: an old-version artifact can be
    # recorded as `rejected`/`failed` (kept as evidence for the next attempt
    # or escalation) but must never masquerade as accepted under the new
    # version. verification is the concrete evidence gathered (what was
    # checked and where) and must be non-empty — "done" without evidence is
    # not an accepted result.
    def finish(id, status:, result:, verification:)
      outcome = status.to_s
      raise Error, "invalid finish status: #{outcome}" unless FINISH_STATUSES.include?(outcome)

      result = text(result, "result", 8000)
      evidence = text(verification, "verification", 2000)
      with_lock do
        document = read_document
        unit = document.fetch("units")[validate_id(id)]
        raise Error, "unknown work unit: #{id}" unless unit
        unless unit.fetch("status") == "bound"
          raise Error, "work unit #{id} is #{unit.fetch('status')}; only a bound unit can finish"
        end
        if outcome == "accepted" && unit.fetch("input_digest") != @record.input_digest
          raise Error, "work unit #{id} ran against an older task input; record the outcome as rejected/failed and declare a new unit"
        end
        current_root = current_artifact_root
        if outcome == "accepted" && (current_root.nil? || unit.fetch("artifact_root") != current_root)
          raise Error, "work unit #{id} ran against a different workspace; record the outcome as rejected/failed and declare a new unit"
        end

        unit["status"] = outcome
        unit["result"] = result
        unit["verification"] = evidence
        unit["finished_at"] = now
        retain_dispatch_outcome(unit)
        write_document(document)
        attach_event_error(copy(unit), emit("work_unit_finished", unit))
      end
    end

    private

    # Attempt identities remain available for joining the unchanged resource
    # ledger. Keep each result with that identity so retries and escalation
    # handoffs cannot erase the evidence of previous failures.
    def retain_dispatch_outcome(unit)
      attempts = unit.fetch("dispatches")
      raise Error, "finished work unit has no dispatch to retain its outcome" if attempts.empty?

      attempts[-1] = attempts.last.merge(unit.slice("status", "result", "verification", "finished_at"))
    end

    def task_id
      File.basename(@record.path)
    end

    # The real artifact_root from the TaskRecord's current workspace
    # (WorkspaceBinding record), or nil when the source is missing. Callers
    # never supply this value.
    def current_artifact_root
      root = @record.state.dig("workspace", "artifact_root")
      root.is_a?(String) && !root.empty? ? root : nil
    end

    def now
      Time.now.utc.iso8601
    end

    def normalize_spec(spec)
      unless spec.is_a?(Hash)
        raise Error, "work unit spec must be a hash"
      end

      spec = spec.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      unknown = spec.keys - %w[objective requirements context decisions allowed_paths allowed_tools
                               allowed_commands acceptance dependencies escalation model_requirements]
      raise Error, "unknown work unit fields: #{unknown.join(', ')}" unless unknown.empty?

      {
        "objective" => text(spec["objective"], "objective", 2000),
        "requirements" => string_list(spec["requirements"], "requirements", 64, 1000, min: 1),
        "context" => spec["context"].nil? ? nil : text(spec["context"], "context", 8000),
        "decisions" => string_list(spec["decisions"] || [], "decisions", 64, 1000),
        "scope" => {
          "allowed_paths" => string_list(spec["allowed_paths"] || [], "allowed_paths", 128, 500),
          "allowed_tools" => tool_list(spec["allowed_tools"] || []),
          "allowed_commands" => string_list(spec["allowed_commands"] || [], "allowed_commands", 128, 500)
        },
        "acceptance" => text(spec["acceptance"], "acceptance", 2000),
        "dependencies" => id_list(spec["dependencies"] || []),
        "escalation" => text(spec["escalation"], "escalation", 2000),
        "model_requirements" => model_requirements(spec["model_requirements"])
      }.tap do |fields|
        scope = fields.fetch("scope")
        if scope.values.all?(&:empty?)
          raise Error, "work unit scope is empty: declare at least one of allowed_paths, allowed_tools, allowed_commands"
        end
      end
    end

    INDICES = %w[coding_index agentic_index intelligence_index].freeze

    # §6 task-side model requirements: declared facts the dispatcher needs
    # (which quality indices matter for this unit, context size, modalities,
    # parameters, whether a measurement date is required). Never inferred
    # from the unit name, never defaulted to "all indices"; absence means no
    # requirement, stored as {}.
    def model_requirements(value)
      return {} if value.nil?
      unless value.is_a?(Hash)
        raise Error, "work unit model_requirements must be a hash"
      end

      value = value.each_with_object({}) { |(key, item), out| out[key.to_s] = item }
      unknown = value.keys - %w[relevant_indices required_context_tokens required_input_modalities
                                required_output_modalities required_parameters require_measurement_date]
      raise Error, "unknown model_requirements fields: #{unknown.join(', ')}" unless unknown.empty?

      normalized = {}
      if value.key?("relevant_indices")
        indices = string_list(value["relevant_indices"], "model_requirements.relevant_indices", 3, 64).uniq
        invalid = indices - INDICES
        raise Error, "unknown model_requirements.relevant_indices: #{invalid.join(', ')}" unless invalid.empty?

        normalized["relevant_indices"] = indices
      end
      if value.key?("required_context_tokens")
        tokens = value["required_context_tokens"]
        unless tokens.is_a?(Integer) && tokens.between?(1, 10_000_000)
          raise Error, "model_requirements.required_context_tokens must be an integer in 1..10000000"
        end

        normalized["required_context_tokens"] = tokens
      end
      %w[required_input_modalities required_output_modalities required_parameters].each do |field|
        next unless value.key?(field)

        normalized[field] = string_list(value[field], "model_requirements.#{field}", 8, 64).uniq
      end
      if value.key?("require_measurement_date")
        flag = value["require_measurement_date"]
        unless flag == true || flag == false
          raise Error, "model_requirements.require_measurement_date must be a boolean"
        end

        normalized["require_measurement_date"] = flag
      end
      normalized
    end

    def text(value, label, limit)
      unless value.is_a?(String) && !value.strip.empty?
        raise Error, "work unit #{label} must be a non-empty string"
      end

      stripped = value.strip
      raise Error, "work unit #{label} exceeds #{limit} characters" if stripped.length > limit

      stripped
    end

    def string_list(value, label, max_items, limit, min: 0)
      unless value.is_a?(Array) && value.length >= min && value.length <= max_items
        raise Error, "work unit #{label} must be an array of #{min}..#{max_items} strings"
      end

      value.map { |item| text(item, "#{label} item", limit) }
    end

    def tool_list(value)
      string_list(value, "allowed_tools", 128, 100).map do |name|
        unless name.match?(/\A[a-z][a-z0-9_-]*\z/)
          raise Error, "work unit allowed_tools item is not a tool name: #{name.inspect}"
        end

        name
      end
    end

    def id_list(value)
      unless value.is_a?(Array)
        raise Error, "work unit dependencies must be an array of unit ids"
      end

      value.map { |id| validate_id(id) }.uniq
    end

    def validate_id(id)
      unless id.is_a?(String) && id.match?(/\Awu-[0-9a-f]{16}\z/)
        raise Error, "invalid work unit id: #{id.inspect}"
      end

      id
    end

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def with_lock(&block)
      File.open(File.join(@record.path, LOCK_NAME), "w", 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def read_document
      file = File.join(@record.path, FILE_NAME)
      unless File.exist?(file)
        return { "format" => FORMAT, "task_id" => task_id, "units" => {} }
      end

      document = JSON.parse(File.read(file))
      if document.is_a?(Hash) && document["format"].is_a?(String) && document["format"] != FORMAT
        raise Error, "work unit store format #{document['format']} is not supported by #{FORMAT}; the undelivered v1 had no workspace binding and is invalidated — re-declare the units"
      end
      unless document.is_a?(Hash) && document["format"] == FORMAT &&
             document["task_id"] == task_id && document["units"].is_a?(Hash) &&
             document["units"].all? { |id, unit| id == unit["id"] && unit["task_id"] == task_id }
        raise Error, "work unit store is corrupt or belongs to another task"
      end

      document
    rescue JSON::ParserError, SystemCallError => failure
      raise Error, "work unit store could not be read (#{failure.class})"
    end

    def write_document(document)
      @record.durable_write(FILE_NAME, JSON.pretty_generate(document) + "\n")
    rescue StandardError => failure
      raise Error, "work unit store could not be saved (#{failure.class})"
    end

    # Audit trail into events.jsonl (same multi-appender precedent as member
    # registration). The unit is already durable when this runs, so an event
    # failure is surfaced as "event_error" on the returned copy — never as a
    # failed declare/bind/finish, and never silently dropped.
    def emit(type, unit)
      @record.event(type, "unit_id" => unit.fetch("id"), "status" => unit.fetch("status"),
                    "member_id" => unit["member_id"], "tool_call_id" => unit["tool_call_id"])
      nil
    rescue StandardError => failure
      "#{type} event could not be recorded for #{unit.fetch('id')}: #{failure.class}"
    end

    def attach_event_error(unit, event_error)
      event_error ? unit.merge("event_error" => event_error) : unit
    end
  end
end
