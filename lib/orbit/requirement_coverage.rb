# frozen_string_literal: true

require "json"
require "time"

require_relative "task_record"

module Orbit
  # Persistent per-requirement coverage for one task: which requirement was
  # verified by what evidence, at which input/artifact version, by which
  # check. One 0600 current projection with bounded recent history per task;
  # complete historical results remain in the task's checks. Every entry keeps the original
  # role and the exact binding (input_digest, artifact_digest, artifact_root)
  # of the moment it was recorded.
  #
  # `complete` only means the CHECKER claims it enumerated every requirement;
  # it is never inferred from an empty finding list. `ready` requires the
  # latest current (non-stale, exactly version-matched) ARTIFACT-scope
  # REVIEWER record to be complete with every item verified; a newer failing
  # or partial artifact review of the same version overrides an earlier pass,
  # and process checks never grant, replace or erase delivery coverage.
  # Stale records remain as history but never release the current version. The
  # program never fabricates local verification receipts, and a Jev sample is
  # not outcome coverage.
  class RequirementCoverage
    SCHEMA_VERSION = "orbit-requirement-coverage-1"
    FILE_NAME = "requirement-coverage.json"
    LOCK_NAME = "requirement-coverage.lock"
    ELIGIBLE_KIND = "artifact"
    ELIGIBLE_ROLE = "reviewer"
    KINDS = %w[artifact process].freeze
    ITEM_STATUSES = %w[verified unverified].freeze
    MAX_BYTES = 2 * 1024 * 1024
    MAX_RECORDS = 256
    MAX_ITEMS = 64
    MAX_TEXT = 1000
    MAX_REQUIREMENT = 300
    MAX_LABEL = 128

    class Error < StandardError; end

    def initialize(record:)
      raise Error, "record must be an Orbit::TaskRecord" unless record.is_a?(TaskRecord)

      @record = record
    end

    def path
      File.join(@record.path, FILE_NAME)
    end

    # Append one validated coverage record atomically. Raises Error on invalid
    # content or an unreadable existing file; existing history is never
    # repaired or silently replaced.
    def record(check_id:, kind:, role:, coverage:, input_digest:, artifact_digest:, artifact_root:, stale: false)
      raise Error, "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind)

      entry = {
        "check_id" => label(check_id, "check_id"), "kind" => kind, "role" => label(role, "role"),
        "recorded_at" => Time.now.utc.iso8601,
        "input_digest" => label(input_digest, "input_digest"),
        "artifact_digest" => label(artifact_digest, "artifact_digest"),
        "artifact_root" => label(artifact_root, "artifact_root"),
        "stale" => stale == true,
        "coverage" => validate_coverage(coverage)
      }
      with_lock do
        records = read_records
        write(records + [entry])
      end
      entry
    end

    # Coverage status for one exact binding. Never raises: any gap is data.
    # Only artifact-scope reviewer records participate; the LATEST one for
    # this binding decides, so a newer incomplete or unverified review
    # overrides an earlier pass instead of being skipped.
    def status(input_digest:, artifact_digest:, artifact_root:)
      records =
        begin
          read_records
        rescue Error
          return gap("the coverage file is missing or unreadable")
        end
      current = records.reverse.find do |entry|
        entry["kind"] == ELIGIBLE_KIND && entry["role"] == ELIGIBLE_ROLE &&
          entry["stale"] == false && entry["input_digest"] == input_digest &&
          entry["artifact_digest"] == artifact_digest && entry["artifact_root"] == artifact_root
      end
      return gap("no artifact-review coverage record for this input, artifact and root version") if current.nil?

      items = current["coverage"]["items"]
      verified = items.count { |item| item["status"] == "verified" }
      base = {
        "current" => true, "complete" => current["coverage"]["complete"],
        "kind" => current["kind"], "role" => current["role"],
        "check_id" => current["check_id"], "recorded_at" => current["recorded_at"],
        "verified" => verified, "unverified" => items.length - verified, "items" => items
      }
      return base.merge("ready" => false, "gap" => "the checker did not claim complete requirement enumeration") unless current["coverage"]["complete"]
      return base.merge("ready" => false, "gap" => "#{items.length - verified} requirement(s) remain unverified") unless items.length == verified

      base.merge("ready" => true, "gap" => nil)
    end

    private

    def gap(reason)
      { "current" => false, "complete" => false, "kind" => nil, "role" => nil, "check_id" => nil,
        "verified" => 0, "unverified" => 0, "items" => [], "ready" => false, "gap" => reason }
    end

    def validate_coverage(coverage)
      raise Error, "coverage must be an object with complete and items" unless coverage.is_a?(Hash)
      raise Error, "coverage must contain exactly complete and items" unless coverage.keys.sort == %w[complete items]
      raise Error, "coverage.complete must be a boolean" unless [true, false].include?(coverage["complete"])

      items = coverage["items"]
      unless items.is_a?(Array) && items.length.between?(1, MAX_ITEMS)
        raise Error, "coverage items must be 1..#{MAX_ITEMS} entries"
      end

      seen = {}
      cleaned = items.map do |item|
        raise Error, "each coverage item must be an object" unless item.is_a?(Hash)
        raise Error, "each item must contain exactly requirement, status and evidence" unless item.keys.sort == %w[evidence requirement status]
        raise Error, "requirement and evidence must be strings" unless item["requirement"].is_a?(String) && item["evidence"].is_a?(String)

        requirement = item["requirement"].to_s.strip
        if requirement.empty? || requirement.length > MAX_REQUIREMENT
          raise Error, "each requirement must be 1..#{MAX_REQUIREMENT} characters"
        end
        raise Error, "duplicate requirement: #{requirement.inspect}" if seen[requirement]

        seen[requirement] = true
        status = item["status"]
        raise Error, "item status must be one of #{ITEM_STATUSES.join(', ')}" unless ITEM_STATUSES.include?(status)

        evidence = item["evidence"].to_s
        raise Error, "evidence must be at most #{MAX_TEXT} characters" if evidence.length > MAX_TEXT
        raise Error, "a verified item needs its evidence" if status == "verified" && evidence.strip.empty?

        { "requirement" => requirement, "status" => status, "evidence" => evidence }
      end
      { "complete" => coverage["complete"], "items" => cleaned }
    end

    def label(value, name)
      text = value.to_s
      raise Error, "#{name} must be 1..#{MAX_LABEL} characters" if text.empty? || text.length > MAX_LABEL

      text
    end

    def read_records
      return [] unless File.file?(path)
      raise Error, "coverage file exceeds #{MAX_BYTES} bytes" if File.size(path) > MAX_BYTES

      document = JSON.parse(File.read(path))
      unless document.is_a?(Hash) && document["schema_version"] == SCHEMA_VERSION && document["records"].is_a?(Array)
        raise Error, "coverage file does not match #{SCHEMA_VERSION}"
      end

      document["records"].each do |entry|
        raise Error, "coverage history contains an invalid record" unless entry.is_a?(Hash) &&
          KINDS.include?(entry["kind"]) && [true, false].include?(entry["stale"])
        %w[check_id role recorded_at input_digest artifact_digest artifact_root].each do |key|
          raise Error, "coverage history has an invalid #{key}" unless entry[key].is_a?(String)
          label(entry[key], key)
        end
        validate_coverage(entry["coverage"])
      end
      document["records"]
    rescue JSON::ParserError, SystemCallError => failure
      raise Error, "coverage file is unreadable: #{failure.message}"
    end

    def write(records)
      compacted = false
      loop do
        payload = JSON.pretty_generate("schema_version" => SCHEMA_VERSION, "records" => records,
          "history_compacted" => compacted) + "\n"
        break if records.length <= MAX_RECORDS && payload.bytesize <= MAX_BYTES

        # Never impose a lifetime check budget. Keep the newest record and
        # the last applicable artifact reviewer; older details are already in
        # the runtime's version-bound checks, not silently treated as verified.
        protected = records.rindex { |entry| entry["kind"] == ELIGIBLE_KIND && entry["role"] == ELIGIBLE_ROLE && !entry["stale"] }
        discard = records.each_index.find { |index| index != records.length - 1 && index != protected }
        raise Error, "current coverage cannot fit the readable file bound" unless discard

        records.delete_at(discard)
        compacted = true
      end
      payload = JSON.pretty_generate("schema_version" => SCHEMA_VERSION, "records" => records,
        "history_compacted" => compacted) + "\n"

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

    # The lock file is fixed and separate: flocking the data file itself would
    # let a second writer lock the new inode after a rename and interleave.
    def with_lock
      File.open(File.join(@record.path, LOCK_NAME), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
