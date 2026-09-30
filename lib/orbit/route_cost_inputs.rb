# frozen_string_literal: true

require "json"
require "time"

require_relative "resource_call_ledger"
require_relative "route_resource_store"
require_relative "task_record"
require_relative "work_unit"
module Orbit
  # Task-scoped predicted route cost inputs for member/checker selection. One
  # 0600 file per task declares, per candidate, the exact four-key route, the
  # verifiable account_scope/plan and a bounded usage composition for THIS
  # unit or review only. `similar_unit` is a traceable forecast whose
  # reference call ids are verified against THIS task's ResourceCallLedger
  # (completed, same role, exact same four-key identity and reported usage;
  # member scope also requires attribution to an accepted WorkUnitStore
  # record). Its usage tuple must be the per-category mean of those calls, so
  # a reference cannot launder an invented token mix; it is never a
  # settlement; `declared_workload` is Root's stated assumption, never
  # disguised as measured usage or used for automatic cost ordering. Tokens
  # are never invented here; both kinds
  # report usage_source "prediction:*" and keep basis/applies_to/references
  # on the built input, so the recorded selection shows the forecast's basis,
  # applicability scope and uncertainty instead of a bare usage hash.
  #
  # `build` binds the file to this task (task id, artifact_root, input_digest;
  # member scope also work_unit_id) and prices each candidate through
  # RouteResourceStore.select: an exact-identity, in-window, imported fact,
  # never an OpenRouter catalog price. The result feeds ModelQualityPolicy's
  # {fact, observed_route, usage, account_scope, usage_source, at} validation.
  # A missing file, broken binding, unverifiable account/plan, expired or
  # unknown-route fact or untrusted composition yields no input for that
  # candidate: cost stays unknown, quality judgment and Root's own dispatch
  # continue, no admission/budget gate is created, unknown is never free, and
  # subscription quota facts stay rule displays, never API amounts.
  class RouteCostInputs
    SCHEMA_VERSION = "orbit-route-cost-inputs-v1"
    FILE_NAME = "route-cost-inputs.json"
    LOCK_NAME = "route-cost-inputs.lock"
    SCOPES = %w[member review].freeze
    PREDICTION_KINDS = %w[similar_unit declared_workload].freeze
    SCOPE_ROLES = { "member" => "member", "review" => "checker" }.freeze
    FACT_SCOPE = "omp_route"
    MAX_BYTES = 64 * 1024
    MAX_CANDIDATES = 32
    MAX_USAGE_CATEGORIES = 8
    MAX_REFERENCES = 16

    class Error < StandardError; end

    def initialize(record:, store:, clock: nil)
      raise Error, "record must be an Orbit::TaskRecord" unless record.is_a?(TaskRecord)

      @record = record
      @store = store
      @clock = clock || -> { Time.now.utc }
    end

    def path
      File.join(@record.path, FILE_NAME)
    end

    # Read the stored document, or nil when absent/unreadable. Hand-edited or
    # corrupt content is treated as "no inputs", never as a selection blocker.
    def read
      return nil unless File.file?(path)
      return nil if File.size(path) > MAX_BYTES

      document = JSON.parse(File.read(path))
      document.is_a?(Hash) ? document : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # Validate and persist the inputs atomically (flock held across the
    # temp+fsync+rename, mode 0600). Binding fields come from the task record
    # at write time; a member scope additionally names its work unit.
    def record_inputs(scope:, candidates:, work_unit_id: nil)
      raise Error, "scope must be one of #{SCOPES.join(', ')}" unless SCOPES.include?(scope)
      if scope == "member"
        raise Error, "a member-scope input requires its work_unit_id" if work_unit_id.to_s.empty?
        # The named unit must be a real record of this task, not a guess.
        unit = begin
          WorkUnitStore.new(@record).read(work_unit_id)
        rescue WorkUnitStore::Error
          nil
        end
        raise Error, "work unit #{work_unit_id} does not exist in this task" if unit.nil?
      elsif !work_unit_id.nil?
        raise Error, "a review-scope input covers the review, not one work unit"
      end

      document = {
        "schema_version" => SCHEMA_VERSION, "task_id" => File.basename(@record.path),
        "scope" => scope, "work_unit_id" => work_unit_id,
        **current_binding, "recorded_at" => @clock.call.utc.iso8601,
        "candidates" => validate_candidates(candidates)
      }
      write_atomic(JSON.pretty_generate(document) + "\n")
      document
    end

    # The validated per-candidate policy inputs for one scope, or {} when
    # nothing credible is available. Member scope must name the unit and pass
    # the unit's own binding, so a whole-task or other-unit prediction can
    # never stand in for this member's future calls.
    def build(scope:, work_unit_id: nil, artifact_root: nil, input_digest: nil)
      document = read
      return {} unless document.is_a?(Hash) && document["schema_version"] == SCHEMA_VERSION
      return {} unless document["task_id"] == File.basename(@record.path) && document["scope"] == scope
      return {} unless document["work_unit_id"] == work_unit_id

      expected = artifact_root && input_digest ? { "artifact_root" => artifact_root, "input_digest" => input_digest }
                                               : current_binding
      if scope == "member"
        # The recorded unit must still exist and still carry the binding this
        # file was written for; a rebound or removed unit degrades to unknown.
        unit = begin
          WorkUnitStore.new(@record).read(work_unit_id)
        rescue WorkUnitStore::Error
          nil
        end
        return {} if unit.nil? || unit["input_digest"] != document["input_digest"] ||
                     unit["artifact_root"] != document["artifact_root"]
      end
      return {} unless document["artifact_root"] == expected["artifact_root"] &&
                       document["input_digest"] == expected["input_digest"]

      candidates = document["candidates"]
      return {} unless candidates.is_a?(Hash)

      now = @clock.call.utc
      candidates.each_with_object({}) do |(key, candidate), out|
        input = build_candidate(candidate, scope, now)
        out[key] = input if input
      end
    rescue Error
      # An unreadable or stale task binding degrades to cost unknown; it never
      # aborts the selection itself.
      {}
    end

    private

    def current_binding
      state = @record.state
      root = state.dig("workspace", "artifact_root")
      root = state["project_root"].to_s unless root.is_a?(String) && !root.empty?
      { "artifact_root" => root, "input_digest" => @record.input_digest(state) }
    rescue JSON::ParserError, SystemCallError, TaskRecord::Error
      raise Error, "task record binding is unreadable; cost inputs cannot be scoped"
    end

    def build_candidate(candidate, scope, now)
      return nil unless candidate.is_a?(Hash)

      route = candidate["route"]
      account_scope = candidate["account_scope"].to_s.strip
      plan = candidate["plan"]
      prediction = candidate["prediction"]
      return nil unless valid_route?(route) && route["billing_route"] != "unknown"
      return nil if account_scope.empty? || account_scope == "unknown"
      return nil unless plan.nil? || (plan.is_a?(String) && !plan.strip.empty?)
      return nil unless valid_prediction?(prediction) && references_verified?(prediction, route, scope)

      fact = @store.select(scope: FACT_SCOPE, route: route, account_scope: account_scope,
                           plan: plan&.strip, at: now)
      return nil unless fact

      { "fact" => fact.document, "observed_route" => route, "usage" => prediction["usage"],
        "account_scope" => account_scope, "usage_source" => "prediction:#{prediction['kind']}",
        "at" => now.iso8601,
        "prediction" => { "kind" => prediction["kind"], "basis" => prediction["basis"],
                          "applies_to" => prediction["applies_to"],
                          "reference_call_ids" => prediction["reference_call_ids"] } }
    rescue RouteResourceStore::Error, RouteResourceFacts::Error
      nil
    end

    # A similar-unit forecast is credible only when every referenced call is
    # in THIS task's ledger: completed, recorded under the role this scope
    # dispatches, the exact same four-key identity as the candidate, complete
    # reported usage with the same categories, and (for member scope)
    # attributed to an accepted work unit. The stated tuple must be the mean
    # of those samples. No cross-task scans or invented token mixes.
    def references_verified?(prediction, route, scope)
      ids = prediction["reference_call_ids"]
      return true unless prediction["kind"] == "similar_unit"

      calls = ResourceCallLedger.new(task_path: @record.path, task_id: File.basename(@record.path),
                                     clock: @clock).calls
      accepted = scope == "member" ? WorkUnitStore.new(@record).list.select { |unit| unit["status"] == "accepted" }
                                                 .map { |unit| unit["id"] } : nil
      samples = ids.filter_map do |id|
        call = calls.find { |entry| entry["call_id"] == id }
        identity = call.is_a?(Hash) ? call["actual_identity"] : nil
        next unless call && call["status"] == "completed" && call["role"] == SCOPE_ROLES.fetch(scope)
        next unless identity.is_a?(Hash) &&
                    %w[provider model reasoning billing_route].all? { |key| identity[key] == route[key] }
        next if accepted && !accepted.include?(call["work_unit_id"])

        usage = call["usage"]
        next unless call["usage_status"] == "reported" && usage.is_a?(Hash) &&
                    usage.keys.sort == prediction["usage"].keys.sort

        usage
      end
      return false unless samples.length == ids.length

      prediction["usage"].all? do |name, count|
        mean = samples.sum { |usage| usage.fetch(name) }.to_f / samples.length
        (count.to_f - mean).abs <= 1e-9 * [1.0, mean.abs].max
      end
    rescue ResourceCallLedger::Error, WorkUnitStore::Error
      false
    end

    def validate_candidates(candidates)
      unless candidates.is_a?(Hash) && candidates.length.between?(1, MAX_CANDIDATES)
        raise Error, "candidates must be a non-empty object keyed by provider/model"
      end

      candidates.to_h do |key, candidate|
        provider, model = key.to_s.split("/", 2)
        route = candidate.is_a?(Hash) ? candidate["route"] : nil
        plan = candidate.is_a?(Hash) ? candidate["plan"] : nil
        account_scope = candidate.is_a?(Hash) ? candidate["account_scope"].to_s.strip : ""
        valid = !provider.to_s.empty? && !model.to_s.empty? && valid_route?(route) &&
                route["provider"] == provider && route["model"] == model &&
                valid_prediction?(candidate["prediction"]) &&
                !account_scope.empty? && account_scope != "unknown" && account_scope.length <= 200 &&
                (plan.nil? || plan.is_a?(String))
        raise Error, "candidate #{key}: need an exact four-key route matching the key, " \
                     "a valid prediction and a verifiable account_scope" unless valid

        [key.to_s, { "route" => route, "account_scope" => account_scope,
                     "plan" => plan&.strip, "prediction" => candidate["prediction"] }]
      end
    end

    def valid_route?(route)
      route.is_a?(Hash) &&
        %w[provider model reasoning].all? { |field| route[field].is_a?(String) && !route[field].strip.empty? } &&
        RouteResourceFacts::BILLING_ROUTES.include?(route["billing_route"])
    end


    def valid_prediction?(prediction)
      return false unless prediction.is_a?(Hash) && PREDICTION_KINDS.include?(prediction["kind"])

      usage = prediction["usage"]
      return false unless usage.is_a?(Hash) && usage.length.between?(1, MAX_USAGE_CATEGORIES)
      return false unless usage.all? { |name, count|
        name.to_s.strip.length.between?(1, 32) && count.is_a?(Numeric) && count.to_f.finite? && count >= 0 }
      return false if prediction["basis"].to_s.strip.empty? || prediction["basis"].to_s.length > 500
      return false if prediction["applies_to"].to_s.strip.empty? || prediction["applies_to"].to_s.length > 200

      references = prediction["reference_call_ids"]
      if prediction["kind"] == "similar_unit"
        references.is_a?(Array) && references.length.between?(1, MAX_REFERENCES) &&
          references.uniq.length == references.length &&
          references.all? { |id| id.is_a?(String) && !id.strip.empty? }
      else
        references.nil?
      end
    end

    # The lock file is fixed and separate: flocking the data file itself would
    # let a second writer lock the NEW inode after a rename and interleave.
    def write_atomic(payload)
      File.open(File.join(@record.path, LOCK_NAME), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        stage = "#{path}.tmp-#{Process.pid}"
        begin
          File.open(stage, "w", 0o600) do |file|
            file.write(payload)
            file.flush
            file.fsync
          end
          File.rename(stage, path)
          File.chmod(0o600, path)
        ensure
          File.unlink(stage) if File.exist?(stage)
        end
      end
    end
  end
end
