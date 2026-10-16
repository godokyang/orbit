# frozen_string_literal: true

require "json"

module Orbit
  # Read-only outward projections shared by the status surface and the
  # runtime: attention (a frozen phase enum), latest_check (the last FINISHED
  # check record, failures and stale records included) and session_binding
  # (the public session/launch boundary). The runtime's check identity
  # fallback (checks/<n>/scope.json) lives here as well so check_history and
  # latest_check always agree. Nothing in this module writes task state; the
  # runtime remains the sole writer and these fields are never persisted
  # (export keeps the raw state without them).
  module StatusProjection
    # Frozen for the integration contract; callers treat anything outside
    # this list as unknown.
    ATTENTION_PHASES = %w[starting implementing checking reworking stopping stopped needs_user failed unknown].freeze
    # Frozen launch-source vocabulary for the integration contract; callers
    # treat anything outside this list as unknown.
    LAUNCH_SOURCES = %w[native_user_message orbit_instruction].freeze

    module_function

    # Frozen precedence: terminal and starting statuses win outright; a
    # running task is stopping on a queued completion hand-off, checking
    # while a check is in flight or a manual final check is queued, reworking
    # on a rebind/open finding/pending recheck clue, and implementing
    # otherwise. A plain future timer is never checking, and needs_user is
    # true only for the needs_user terminal status — it never implies an
    # in-flight native question or resumability.
    def attention(state)
      status = state["status"]
      phase = case status
              when "needs_user" then "needs_user"
              when "failed" then "failed"
              when "stop_unconfirmed" then "stopping"
              when "complete", "paused" then "stopped"
              when "starting" then "starting"
              when "running"
                if state["completion_stop_pending"]
                  "stopping"
                elsif check_in_flight?(state) || state["next_check_manual"] == true
                  "checking"
                elsif reworking?(state)
                  "reworking"
                else
                  "implementing"
                end
              else "unknown"
              end
      { "phase" => phase, "needs_user" => status == "needs_user" }
    end

    # Read-only public session binding (integration contract 1.5): the real
    # provider session identity, the host-reported transcript path and the
    # stable launch message boundary — the one message that started this
    # task's supervision, never advanced by later corrections, reminders or
    # newer user messages. Unknown facts are null, never guessed: the
    # transcript path is only what the host actually reported (attach records
    # it, tick backfills it), and a legacy prompt-file record has no durable
    # delivery marker, so its launch stays unknown instead of borrowing
    # sent_message_ids[0] or the internal moving boundary.
    def session_binding(state)
      connection = state["connection"].is_a?(Hash) ? state["connection"] : {}
      launch =
        if nonempty_string?(state.dig("initial_delivery", "id"))
          [state.dig("initial_delivery", "id"), "orbit_instruction"]
        elsif user_message_source?(state.dig("continuation", "source"))
          [state.dig("continuation", "source", "id"), "native_user_message"]
        elsif user_message_source?(state["instruction_source"])
          [state["instruction_source"]["id"], "native_user_message"]
        end
      {
        "provider" => nonempty_string?(connection["provider"]) ? connection["provider"] : nil,
        "session_id" => nonempty_string?(connection["thread_id"]) ? connection["thread_id"] : nil,
        "session_file" => nonempty_string?(state["root_session_file"]) ? state["root_session_file"] : nil,
        "launch_message_id" => launch&.first,
        "launch_message_source" => launch&.last
      }
    end

    # A durable creation-time source naming a real native user message in the
    # host session ("omp_user_message" today; the runtime tests' generic
    # "native_user_message" shape shares the suffix). An explicit_text source
    # carries a file, not a message id — its boundary is only the program's
    # recorded delivery, never an internal mirror field.
    def user_message_source?(source)
      source.is_a?(Hash) && nonempty_string?(source["id"]) &&
        source["kind"].is_a?(String) && source["kind"].end_with?("_user_message")
    end

    def nonempty_string?(value)
      value.is_a?(String) && !value.empty?
    end

    # The last checks[] entry that actually finished (failed and stale
    # records included); a still-running check is not in checks[] at all.
    # Strict whitelist: no workspace paths, no conclusion/error text, no
    # provider response ids, no usage details — only deduped model identities
    # and input-vs-current consistency. Absent when nothing finished yet.
    def latest_check(record, state)
      entry = recorded_checks(state).reverse.find { |check| !check["finished_at"].to_s.empty? }
      return nil unless entry

      identity = check_identity(record, entry)
      input_digest = identity["input_digest"]
      current_input = current_input_digest(record, state)
      {
        "number" => entry["number"], "role" => entry["role"], "kind" => entry["kind"],
        "finished_at" => entry["finished_at"],
        "input_digest" => input_digest, "artifact_digest" => identity["artifact_digest"],
        "stale" => entry["stale"], "stale_reasons" => Array(entry["stale_reasons"]),
        "terminal" => entry["failed"] ? "failed" : entry["stale"] ? "stale" : entry.dig("result", "verdict"),
        "failure_kind" => entry.dig("result", "failure_kind"),
        "models" => check_models(entry),
        "input_current" => input_digest.nil? || current_input.nil? ? nil : input_digest == current_input
      }
    end

    # One check's durable identity, falling back to its own checks/<n>/scope.json
    # when it was recorded before the identity slice existed.
    def check_identity(record, entry)
      identity = entry.slice("artifact_root", "input_digest", "artifact_digest")
      return identity if identity.values_at("artifact_root", "input_digest", "artifact_digest").none?(&:nil?)

      check_scope_identity(record, entry["number"]).merge(identity) { |_key, fallback, value| value || fallback }
    end

    def check_scope_identity(record, number)
      return {} if number.nil?

      path = File.join(record.path, "checks", number.to_s, "scope.json")
      return {} unless File.file?(path)

      scope = JSON.parse(File.read(path))
      { "artifact_root" => scope["artifact_root"], "input_digest" => scope["input_digest"],
        "artifact_digest" => scope.dig("snapshot", "digest") }
    rescue JSON::ParserError, SystemCallError
      {}
    end

    # Actual checker identities from the recorded call receipts, normalized to
    # full provider/model: a bare model id (even one already containing a
    # slash) gets its receipt provider prefix; an already-complete identity is
    # kept verbatim, never double-prefixed. Only the receipt's own
    # requested_model falls back when no actual identity was recorded, and a
    # call with no model identity at all contributes nothing — task.review is
    # never borrowed to fabricate one.
    def check_models(entry)
      Array(entry.dig("usage", "calls")).filter_map do |call|
        next nil unless call.is_a?(Hash)

        model = call["model"] || call["requested_model"]
        next nil unless model.is_a?(String) && !model.empty?

        provider = call["provider"]
        if provider.is_a?(String) && !provider.empty? && !model.start_with?("#{provider}/")
          "#{provider}/#{model}"
        else
          model
        end
      end.uniq
    end

    def recorded_checks(state)
      checks = state["checks"]
      checks.is_a?(Array) ? checks.select { |check| check.is_a?(Hash) } : []
    end

    def check_in_flight?(state)
      observations = state["check_observations"]
      return false unless observations.is_a?(Hash)

      observations.each_value.any? { |entry| entry.is_a?(Hash) && entry["status"] == "in_flight" }
    end

    def reworking?(state)
      findings = state["findings"]
      open = findings.is_a?(Hash) && findings.each_value.any? { |finding| finding.is_a?(Hash) && finding["status"] == "open" }
      clues = state.dig("recheck", "findings")
      open || (clues.is_a?(Array) && !clues.empty?) || rebind_action?(state)
    end

    def rebind_action?(state)
      return false unless %w[starting running].include?(state["status"])

      state["next_check_trigger"] == "rebind" || state["next_check_basis"] == "工作区重新绑定" ||
        Array(recorded_checks(state).last&.[]("stale_reasons")).include?("workspace")
    end

    def current_input_digest(record, state)
      record.input_digest(state)
    rescue StandardError
      nil
    end
  end
end
