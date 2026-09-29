# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module Orbit
  # Task-owned provider receipts. One call id identifies one actual invocation:
  # replaying its receipt is idempotent, a retry is a new id and therefore its
  # own possible charge, and a failed call is still a call. Reported usage stays
  # field by field — input, cache, reasoning and total may overlap, so this
  # ledger never adds different categories into one token total, never invents a
  # missing field as zero, and never converts anything to money or to
  # subscription quota. Money and quota consumption are priced elsewhere from a
  # verified route fact, not inferred here.
  class ResourceCallLedger
    SCHEMA_VERSION = "orbit-resource-calls-v1"
    FILE_NAME = "resource-calls.json"
    # root: the Root session itself; member: a registered execution member;
    # judgment: an Orbit judgment call; checker/arbiter: independent check or
    # adjudication sessions.
    ROLES = %w[root member judgment checker arbiter].freeze
    STATUSES = %w[completed failed unknown].freeze
    USAGE_STATUSES = %w[reported partial unknown].freeze
    # judgment_service receipts describe the judgment provider route; omp_route
    # receipts describe an OMP execution/check route. They are never mixed,
    # because the same model name can be a different billed route.
    SCOPES = %w[judgment_service omp_route].freeze
    SOURCES = %w[provider_response native_message].freeze
    BILLING_ROUTES = %w[direct_api subscription_quota unknown].freeze
    # How the recorded usage fields relate to each other. `not_inferred` means
    # Orbit has no verified relationship for these fields, so no total may be
    # derived from them; `source_declared` means the caller attached the
    # provider/source definition in relationship_note. Neither value authorises
    # price settlement — that uses a verified route fact with its own category
    # definitions.
    RELATIONSHIPS = %w[not_inferred source_declared].freeze
    # Where a call id came from. A local id minted at the observed provider call
    # boundary is a real invocation label, not a provider id; the provider's own
    # id is kept separately when it exists.
    CALL_ID_ORIGINS = %w[local_provider_invocation provider_response].freeze
    JUDGMENT_UNITS = "token"
    MAX_BYTES = 8 * 1024 * 1024
    MAX_CALL_BYTES = 16 * 1024
    MAX_USAGE_FIELDS = 64
    MAX_TEXT = 256
    MAX_ERROR = 1000

    class Error < StandardError; end

    def initialize(task_path:, task_id:, clock: nil)
      @task_id = text(task_id, "task id")
      @path = File.join(File.realpath(task_path), FILE_NAME)
      @clock = clock || -> { Time.now.utc }
    end

    attr_reader :path

    # Records one actual invocation. Returns true when this call id was new and
    # false when an identical receipt was already stored (idempotent replay).
    # A replay with a different payload is an accounting conflict: the stored
    # receipt is never overwritten, silently amended or counted twice.
    def record(call_id:, role:, phase:, status:, provider:, actual_model:, usage:, usage_source:,
               usage_units: {}, requested_model: nil, reasoning: nil, billing_route: "unknown",
               identity_scope: "omp_route", member_id: nil, work_unit_id: nil, attempt_id: nil,
               question_set_version: nil, error: nil, category_relationships: "not_inferred",
               relationship_note: nil, call_id_origin: nil, provider_response_id: nil,
               upstream_provider: nil, upstream_model: nil, usage_status: nil,
               started_at: nil, completed_at: nil)
      reported, usage_note = normalized_usage(usage)
      completeness = usage_status || (reported.nil? ? "unknown" : (usage_note ? "partial" : "reported"))
      completeness = "unknown" if reported.nil?
      fact = {
        "call_id" => text(call_id, "call id"), "task_id" => @task_id,
        "role" => enum(role, ROLES, "role"), "phase" => text(phase, "phase"),
        "status" => enum(status, STATUSES, "status"),
        "actual_identity" => {
          "provider" => optional_text(provider), "model" => optional_text(actual_model),
          "reasoning" => optional_text(reasoning),
          "billing_route" => enum(billing_route, BILLING_ROUTES, "billing route"),
          "scope" => enum(identity_scope, SCOPES, "identity scope")
        },
        "requested_model" => optional_text(requested_model),
        # The attempt that contained this call, when it is not the call itself
        # (one check session can make several provider calls). It is a linkage
        # label only and never substitutes for a call id.
        "attempt_id" => optional_text(attempt_id),
        # How this call id was obtained, and the provider's own id when it
        # reported one. A local boundary id is not presented as a provider id.
        "call_id_origin" => call_id_origin.nil? ? nil : enum(call_id_origin, CALL_ID_ORIGINS, "call id origin"),
        "provider_response_id" => optional_text(provider_response_id),
        # The upstream supplier's actual model is recorded only when it was
        # reported; it is never filled from the requested or executed OMP model.
        "upstream_identity" => {
          "provider" => optional_text(upstream_provider), "model" => optional_text(upstream_model)
        },
        "member_id" => optional_text(member_id), "work_unit_id" => optional_text(work_unit_id),
        "question_set_version" => optional_text(question_set_version), "error" => optional_text(error, MAX_ERROR),
        # Actual invocation observations, never the time this receipt was saved.
        # Missing times remain unknown; prices cannot be applied at recorded_at.
        "started_at" => observed_time(started_at), "completed_at" => observed_time(completed_at),
        "usage" => reported, "usage_note" => usage_note,
        "usage_status" => enum(completeness, USAGE_STATUSES, "usage status"),
        "usage_source" => enum(usage_source, SOURCES, "usage source"),
        "usage_units" => normalized_units(usage_units),
        # Reported fields stay as they were reported: this declares whether a
        # relationship between them is known, never a derived total.
        "category_relationships" => enum(category_relationships, RELATIONSHIPS, "category relationship"),
        "relationship_note" => optional_text(relationship_note, MAX_TEXT)
      }
      if fact["started_at"] && fact["completed_at"] && Time.iso8601(fact["completed_at"]) < Time.iso8601(fact["started_at"])
        raise Error, "call completion precedes its observed start"
      end
      %w[started_at completed_at].each { |key| fact.delete(key) if fact[key].nil? }
      raise Error, "resource call receipt is too large" if JSON.generate(fact).bytesize > MAX_CALL_BYTES

      with_lock do
        document = read
        existing = document.fetch("calls")[fact["call_id"]]
        if existing
          unless existing.reject { |key, _| key == "recorded_at" } == fact
            raise Error, "conflicting receipt for resource call #{fact['call_id']}"
          end
          next false
        end

        document.fetch("calls")[fact["call_id"]] = fact.merge("recorded_at" => @clock.call.utc.iso8601)
        write(document)
        true
      end
    rescue SystemCallError, JSON::GeneratorError => failure
      raise Error, "resource call receipt could not be saved (#{failure.class})"
    end

    # A judgment receipt may be recorded once per call even when it produced no
    # recommendation, and a failed judgment is still possible consumption.
    # `answered` is a completed call; an unavailable/errored response is
    # `failed`; an unclassifiable receipt is `unknown` and is never reported as
    # a success. A receipt without a call id belongs to no single invocation and
    # is refused instead of being attributed to another call.
    def record_judgment(receipt, phase:)
      raise Error, "judgment receipt has no call id" unless receipt.is_a?(Hash) && receipt["call_id"]

      record(
        call_id: receipt["call_id"], role: "judgment", phase: phase,
        status: judgment_status(receipt["status"]), provider: receipt["provider"],
        actual_model: receipt.key?("actual_model") ? receipt["actual_model"] : receipt["model"],
        requested_model: receipt["requested_model"],
        identity_scope: "judgment_service", usage_source: "provider_response",
        usage: receipt["usage"], usage_units: token_units(receipt["usage"]),
        usage_status: receipt_completeness(receipt["usage"], %w[input_tokens output_tokens]),
        call_id_origin: "local_provider_invocation",
        question_set_version: receipt["question_set_version"], error: receipt["error"]
      )
    end

    # One provider call inside a reviewer/adjudicator check attempt.
    #
    # The call id is the id observed for that provider call: Orbit's own id for
    # the observed call boundary (call_id_origin local_provider_invocation) or
    # the provider's own response id (call_id_origin provider_response). The
    # check attempt id is only stored as a linkage label and is refused as a
    # substitute, because one attempt can make several provider calls. A retry
    # is a new attempt whose calls have their own ids, so it can never be
    # mistaken for the attempt it replaced, and the failed attempt keeps
    # whatever usage the provider actually reported.
    def record_check(receipt, phase: "check", role: "checker")
      unless receipt.is_a?(Hash) && receipt["call_id"]
        raise Error, "check receipt needs the id observed for its own provider call; a check attempt id is not one"
      end

      record(
        call_id: receipt["call_id"], role: enum(role, ROLES, "role"), phase: phase,
        status: enum(receipt["status"], STATUSES, "status"),
        provider: receipt["provider"], actual_model: receipt["actual_model"],
        requested_model: receipt["requested_model"], reasoning: receipt["reasoning"],
        billing_route: receipt["billing_route"] || "unknown",
        identity_scope: "omp_route", usage_source: receipt["usage_source"] || "provider_response",
        usage: receipt["usage"], usage_units: token_units(receipt["usage"]),
        usage_status: receipt_completeness(receipt["usage"], %w[input output cacheRead],
                                            incomplete: receipt["usage_status"] == "unknown"),
        member_id: receipt["member_id"], work_unit_id: receipt["work_unit_id"],
        attempt_id: receipt["attempt_id"], error: receipt["error"],
        # The provider's own field names are stored as reported. The caller may
        # attach the source definition it used; it still never authorises a
        # derived total or price settlement here.
        category_relationships: receipt["category_relationships"] || "not_inferred",
        relationship_note: receipt["relationship_note"],
        call_id_origin: receipt["origin"], provider_response_id: receipt["provider_response_id"],
        upstream_provider: receipt["upstream_provider"], upstream_model: receipt["upstream_model"],
        started_at: receipt["started_at"], completed_at: receipt["completed_at"]
      )
    end

    # Every stored receipt, for audits and exports. The returned structure is a
    # detached copy; mutating it never changes the ledger.
    def calls
      JSON.parse(JSON.generate(read.fetch("calls").values))
    end

    # Aggregates only matching roles, phases, execution identities, sources and
    # units. Each field keeps its own reported/missing counts, so a partially
    # reported call cannot read as a complete total and reported zero stays
    # distinguishable from an absent report.
    def summary
      calls = read.fetch("calls").values
      groups = calls.group_by do |call|
        [call["role"], call["phase"], call["actual_identity"], call["usage_source"], call["usage_units"]]
      end.map do |(role, phase, identity, source, units), records|
        fields = (units.keys + records.flat_map { |call| (call["usage"] || {}).keys }).uniq.sort
        {
          "role" => role, "phase" => phase, "actual_identity" => identity, "usage_source" => source,
          "call_count" => records.length,
          "status_counts" => STATUSES.to_h { |status| [status, records.count { |call| call["status"] == status }] },
          "usage_fields" => fields.to_h do |field|
            values = records.filter_map { |call| call["usage"]&.[](field) }
            [field, { "reported_sum" => values.empty? ? nil : values.sum,
                      "unit" => units.fetch(field, "unknown"), "reported_calls" => values.length,
                      "missing_calls" => records.length - values.length }]
          end
        }
      end
      {
        "schema_version" => SCHEMA_VERSION, "coverage" => "recorded_calls_only", "call_count" => calls.length,
        "status_counts" => STATUSES.to_h { |status| [status, calls.count { |call| call["status"] == status }] },
        "unknown_usage_calls" => calls.count { |call| call["usage"].nil? },
        "partial_usage_calls" => calls.count { |call| call["usage_status"] == "partial" },
        "usage_status_counts" => USAGE_STATUSES.to_h { |status| [status, calls.count { |call| call["usage_status"] == status }] },
        "noted_usage_calls" => calls.count { |call| call["usage_note"] },
        "unknown_actual_model_calls" => calls.count { |call| call.dig("actual_identity", "model").nil? },
        "attempt_count" => calls.filter_map { |call| call["attempt_id"] }.uniq.length,
        "calls_without_attempt" => calls.count { |call| call["attempt_id"].nil? },
        "call_id_origins" => calls.filter_map { |call| call["call_id_origin"] }.tally,
        "calls_without_call_id_origin" => calls.count { |call| call["call_id_origin"].nil? },
        "unknown_upstream_model_calls" => calls.count { |call| call.dig("upstream_identity", "model").nil? },
        "groups" => groups, "cost" => nil, "quota_consumption" => nil,
        "note" => "reported fields are never summed across categories; cost and quota stay unknown here"
      }
    end

    private

    def judgment_status(value)
      case value
      when "answered" then "completed"
      when "unavailable" then "failed"
      else "unknown"
      end
    end

    def receipt_completeness(usage, fields, incomplete: false)
      reported, note = normalized_usage(usage)
      return "unknown" if reported.nil?

      incomplete || note || fields.any? { |field| !reported.key?(field) } ? "partial" : "reported"
    end

    # Reported token fields are declared as tokens under the provider's own
    # field names. Fields the provider did not report are not declared, so a
    # missing bucket is visible instead of being read as zero.
    def token_units(usage)
      return {} unless usage.is_a?(Hash)

      usage.keys.select { |key| key.is_a?(String) && !key.strip.empty? && key.length <= 64 }
           .to_h { |field| [field, JUDGMENT_UNITS] }
    end

    def read
      return { "schema_version" => SCHEMA_VERSION, "task_id" => @task_id, "calls" => {} } unless File.exist?(@path)

      raise Error, "resource call ledger is too large" if File.size(@path) > MAX_BYTES

      data = JSON.parse(File.read(@path, MAX_BYTES + 1))
      unless data.is_a?(Hash) && data["schema_version"] == SCHEMA_VERSION && data["task_id"] == @task_id &&
             data["calls"].is_a?(Hash) && data["calls"].all? { |id, call| valid_stored_call?(id, call) }
        raise Error, "resource call ledger is corrupt or belongs to another task"
      end

      data
    rescue JSON::ParserError, SystemCallError => failure
      raise Error, "resource call ledger could not be read (#{failure.class})"
    end

    def valid_stored_call?(id, call)
      return false unless call.is_a?(Hash) && call["call_id"] == id && call["task_id"] == @task_id
      return false unless ROLES.include?(call["role"]) && STATUSES.include?(call["status"])
      return false unless call["actual_identity"].is_a?(Hash) && SCOPES.include?(call.dig("actual_identity", "scope")) &&
                          BILLING_ROUTES.include?(call.dig("actual_identity", "billing_route"))
      return false unless SOURCES.include?(call["usage_source"]) && call["usage_units"].is_a?(Hash) &&
                          normalized_units(call["usage_units"]) == call["usage_units"]
      return false unless USAGE_STATUSES.include?(call["usage_status"])
      return false unless RELATIONSHIPS.include?(call["category_relationships"]) && call["recorded_at"].is_a?(String)
      return false unless call["usage_note"].nil? ||
                          (call["usage_note"].is_a?(String) && call["usage_note"].length <= MAX_TEXT)
      return false unless call["relationship_note"].nil? ||
                          (call["relationship_note"].is_a?(String) && call["relationship_note"].length <= MAX_TEXT)
      return false if call["attempt_id"] && !(call["attempt_id"].is_a?(String) && call["attempt_id"].length <= MAX_TEXT)
      return false if call["call_id_origin"] && !CALL_ID_ORIGINS.include?(call["call_id_origin"])
      return false unless call["upstream_identity"].is_a?(Hash)
      return false unless observed_time(call["started_at"]) == call["started_at"] &&
                          observed_time(call["completed_at"]) == call["completed_at"]

      reported, _note = normalized_usage(call["usage"])
      reported == call["usage"]
    rescue Error
      false
    end

    # Provider usage is kept as reported. A field that is not a finite
    # nonnegative number is dropped with an explicit note rather than turning
    # the value into zero; a report that yields no usable field at all stays
    # unknown. The call itself is always recorded, because losing the receipt
    # would hide a real invocation and its charge.
    def normalized_usage(usage)
      return [nil, nil] if usage.nil? || (usage.is_a?(Hash) && usage.empty?)
      return [nil, "reported usage is not a bounded field map"] unless usage.is_a?(Hash) && usage.length <= MAX_USAGE_FIELDS

      kept = {}
      dropped = []
      usage.each do |key, value|
        if usable_field?(key, value)
          kept[key] = value
        else
          dropped << key.to_s.gsub(/[^\x20-\x7e]/, "?").slice(0, 32)
        end
      end
      return [nil, "reported usage fields are unusable: #{dropped.join(', ')}".slice(0, MAX_TEXT)] if kept.empty?

      note = dropped.empty? ? nil : "unusable usage fields dropped: #{dropped.join(', ')}".slice(0, MAX_TEXT)
      [kept, note]
    end

    def usable_field?(key, value)
      key.is_a?(String) && !key.strip.empty? && key.length <= 64 && !key.match?(/[\x00-\x1f\x7f]/) &&
        value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def normalized_units(units)
      raise Error, "usage units must be bounded" unless units.is_a?(Hash) && units.length <= MAX_USAGE_FIELDS

      units.to_h { |key, unit| [text(key, "usage field", 64), text(unit, "usage unit", 64)] }
    end

    def observed_time(value)
      return nil if value.nil?

      unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        raise Error, "observed call time needs an explicit timezone"
      end
      Time.iso8601(value)
      value
    rescue ArgumentError
      raise Error, "observed call time is not ISO-8601"
    end

    def text(value, label, limit = MAX_TEXT)
      unless value.is_a?(String) && !value.strip.empty? && value.length <= limit && !value.match?(/[\x00-\x1f\x7f]/)
        raise Error, "invalid #{label}"
      end
      value
    end

    def optional_text(value, limit = MAX_TEXT)
      value.nil? ? nil : text(value, "receipt text", limit)
    end

    def enum(value, values, label)
      raise Error, "invalid #{label}" unless values.include?(value)

      value
    end

    def with_lock
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.chmod(0o600)
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def write(document)
      bytes = JSON.generate(document) + "\n"
      raise Error, "resource call ledger exceeds its storage limit" if bytes.bytesize > MAX_BYTES

      temporary = "#{@path}.#{SecureRandom.hex(8)}.tmp"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(temporary, @path)
      File.open(File.dirname(@path), File::RDONLY) { |directory| directory.fsync }
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end
  end
end
