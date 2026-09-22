# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "uri"

module Orbit
  # User-level cache for the model evidence that Root retrieves on demand and
  # submits through the future `model_evidence` control operation (JEV
  # delegation plan, "模型证据由 Root 按需检索"). It is regenerable run
  # evidence, not configuration and not part of the released package.
  #
  # The default location is
  # `${XDG_CACHE_HOME:-$HOME/.cache}/orbit/model-evidence-v1.json` so the
  # same facts can be reused across projects. Only the frozen, bounded fact
  # schema is stored:
  #
  #   provider, model, reasoning  identity; any change is a miss
  #   status "evidence":         sources[] plus metrics{name => {value, unit, basis}}
  #   status "unavailable":      reason
  #   retrieved_at, valid_until  UTC ISO-8601 validity window
  #
  # `lookup` returns the stored entry inside its validity window and `nil`
  # when it is missing, expired or malformed. A concrete model version is
  # valid for seven days; an alias containing `latest` or `preview` for 24
  # hours. A submission may shorten that window but not extend it.
  #
  # Submissions are validated in full before one atomic, permission-tightened
  # write (directory 0700, file 0600). Unknown fields are rejected, so web
  # page text, credentials or other extra material never reach disk. The
  # read-merge-write in `record_all` runs under an exclusive flock on a
  # sibling `.lock` file (0600), so two tasks sharing this cross-project
  # cache cannot drop each other's entries; the lock is released on every
  # exit path. A write whose final JSON would exceed the readable file limit
  # is refused with the previous cache untouched, and a cache file that is
  # corrupt or written by another schema version raises instead of being
  # silently discarded or overwritten.
  #
  # Path and clock are injectable: production callers use the defaults, while
  # tests pass a temporary path and a fixed clock and never touch the real
  # user cache.
  class ModelEvidenceCache
    SCHEMA_VERSION = "orbit-model-evidence-v1"
    CACHE_DIRECTORY = "orbit"
    FILE_NAME = "model-evidence-v1.json"

    STATUS_EVIDENCE = "evidence"
    STATUS_UNAVAILABLE = "unavailable"
    STATUSES = [STATUS_EVIDENCE, STATUS_UNAVAILABLE].freeze

    VERSION_TTL_SECONDS = 7 * 24 * 60 * 60
    FLOATING_ALIAS_TTL_SECONDS = 24 * 60 * 60
    FLOATING_ALIAS_PATTERN = /\b(?:latest|preview)\b/i
    CLOCK_SKEW_SECONDS = 300
    DEFAULT_REASONING = "default"

    EVIDENCE_KEYS = %w[provider model reasoning status retrieved_at valid_until sources metrics].freeze
    UNAVAILABLE_KEYS = %w[provider model reasoning status retrieved_at valid_until sources reason].freeze
    METRIC_KEYS = %w[value unit basis].freeze

    MAX_PROVIDER_LENGTH = 64
    MAX_MODEL_LENGTH = 200
    MAX_REASONING_LENGTH = 64
    MAX_URL_LENGTH = 2048
    MAX_SOURCES = 5
    MAX_METRICS = 24
    MAX_METRIC_NAME_LENGTH = 64
    MAX_UNIT_LENGTH = 32
    MAX_BASIS_LENGTH = 300
    MAX_REASON_LENGTH = 500
    MAX_ENTRY_BYTES = 16 * 1024
    MAX_FILE_BYTES = 512 * 1024
    MAX_ENTRIES = 200

    IDENTIFIER_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:+@\/-]*\z/
    REASONING_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
    METRIC_NAME_PATTERN = /\A[A-Za-z][A-Za-z0-9_.-]*\z/
    TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
    CONTROL_CHARS = /[\x00-\x1F\x7F]/

    class Error < StandardError; end

    class ValidationError < Error; end

    # XDG_CACHE_HOME only counts when absolute; otherwise `home/.cache` is
    # used, as the XDG base directory specification requires.
    def self.default_path(env: ENV, home: nil)
      cache_home = env["XDG_CACHE_HOME"].to_s
      base = cache_home.start_with?("/") ? cache_home : File.join(home_directory(env: env, home: home), ".cache")
      File.join(base, CACHE_DIRECTORY, FILE_NAME)
    end

    def self.home_directory(env:, home: nil)
      candidate = home.to_s.empty? ? env["HOME"].to_s : home.to_s
      candidate.empty? ? Dir.home : candidate
    end

    def self.validity_seconds(model:)
      model.to_s.match?(FLOATING_ALIAS_PATTERN) ? FLOATING_ALIAS_TTL_SECONDS : VERSION_TTL_SECONDS
    end

    attr_reader :path

    def initialize(path: nil, clock: nil, env: ENV, home: nil)
      default = self.class.default_path(env: env, home: home)
      @path = File.expand_path(path.nil? || path.to_s.empty? ? default : path.to_s)
      @clock = clock || -> { Time.now.utc }
    end

    # Normalized identity used as the cache key. An omitted reasoning effort
    # means the provider default.
    def identity(provider:, model:, reasoning: nil)
      {
        "provider" => identifier(provider, "provider", MAX_PROVIDER_LENGTH),
        "model" => identifier(model, "model", MAX_MODEL_LENGTH),
        "reasoning" => reasoning_effort(reasoning)
      }
    end

    # Returns the stored entry while it is inside its validity window, even
    # when it records `unavailable` (the caller must not re-request those).
    # Missing, expired or malformed entries return nil.
    def lookup(provider:, model:, reasoning: nil)
      wanted = identity(provider: provider, model: model, reasoning: reasoning)
      entry = stored_entries.find { |candidate| stored_identity(candidate) == wanted }
      return nil unless entry

      expires_at = parse_time(entry["valid_until"])
      return nil if expires_at.nil? || now >= expires_at

      entry
    end

    def stored_entries
      document.fetch("entries")
    end

    # Validates and stores one submitted fact; returns the normalized entry.
    def record(payload)
      record_all([payload]).first
    end

    # Validates every payload before writing anything, so an invalid
    # submission leaves the existing cache unchanged. Returns the normalized
    # entries that were written. Duplicate identities in one batch keep the
    # last submission. The read-merge-write is exclusive across processes.
    def record_all(payloads)
      submitted = payloads.is_a?(Array) ? payloads : [payloads]
      raise ValidationError, "at least one model evidence entry is required" if submitted.empty?

      normalized = dedupe_by_identity(submitted.map { |payload| normalize_entry(payload) })
      with_lock { write(merge(stored_entries, normalized)) }
      normalized
    end

    private

    def document
      return { "schema_version" => SCHEMA_VERSION, "entries" => [] } unless File.exist?(@path)

      if File.size(@path) > MAX_FILE_BYTES
        raise Error, "model evidence cache is unexpectedly large: #{@path}"
      end

      parsed =
        begin
          JSON.parse(File.read(@path))
        rescue JSON::ParserError
          raise Error, "model evidence cache is not valid JSON: #{@path}"
        end
      unless parsed.is_a?(Hash) && parsed["schema_version"] == SCHEMA_VERSION && parsed["entries"].is_a?(Array)
        raise Error, "model evidence cache does not match #{SCHEMA_VERSION}: #{@path}"
      end

      parsed
    rescue Errno::ENOENT
      raise Error, "model evidence cache disappeared while reading: #{@path}"
    end

    def normalize_entry(payload)
      raise ValidationError, "model evidence entry must be a JSON object" unless payload.is_a?(Hash)

      entry = stringify(payload)
      status = entry["status"].to_s
      raise ValidationError, "status must be #{STATUSES.join(' or ')}" unless STATUSES.include?(status)

      unknown = entry.keys - (status == STATUS_EVIDENCE ? EVIDENCE_KEYS : UNAVAILABLE_KEYS)
      raise ValidationError, "unsupported model evidence fields: #{unknown.sort.join(', ')}" unless unknown.empty?

      normalized = identity(provider: entry["provider"], model: entry["model"], reasoning: entry["reasoning"])
      retrieved_at = parse_time(entry["retrieved_at"])
      raise ValidationError, "retrieved_at must be an ISO-8601 timestamp with a zone" if retrieved_at.nil?

      current = now
      raise ValidationError, "retrieved_at is in the future" if retrieved_at > current + CLOCK_SKEW_SECONDS

      ttl = self.class.validity_seconds(model: normalized.fetch("model"))
      valid_until = entry["valid_until"].nil? ? retrieved_at + ttl : parse_time(entry["valid_until"])
      raise ValidationError, "valid_until must be an ISO-8601 timestamp with a zone" if valid_until.nil?
      raise ValidationError, "valid_until must be after retrieved_at" unless valid_until > retrieved_at
      if valid_until > retrieved_at + ttl
        raise ValidationError, "valid_until exceeds the #{ttl / 3600}-hour validity of this model identifier"
      end
      raise ValidationError, "valid_until is already in the past" if valid_until <= current

      normalized["status"] = status
      normalized["retrieved_at"] = format_time(retrieved_at)
      normalized["valid_until"] = format_time(valid_until)
      if status == STATUS_EVIDENCE
        normalized["sources"] = normalize_sources(entry["sources"], required: true)
        normalized["metrics"] = normalize_metrics(entry["metrics"])
      else
        sources = normalize_sources(entry["sources"], required: false)
        normalized["sources"] = sources if sources
        normalized["reason"] = validate_text(entry["reason"], "reason", MAX_REASON_LENGTH)
      end
      if JSON.generate(normalized).bytesize > MAX_ENTRY_BYTES
        raise ValidationError, "model evidence entry is too large"
      end

      normalized
    end

    def normalize_sources(value, required:)
      return nil if value.nil? && !required

      if !value.is_a?(Array) || value.empty? || value.length > MAX_SOURCES
        raise ValidationError, "sources must be a non-empty array of at most #{MAX_SOURCES} URLs"
      end

      value.map { |url| validate_source(url) }
    end

    def validate_source(value)
      text = value.to_s.strip
      unless text.length.between?(1, MAX_URL_LENGTH) && !text.match?(CONTROL_CHARS)
        raise ValidationError, "source must be an absolute http(s) URL of at most #{MAX_URL_LENGTH} characters"
      end

      parsed =
        begin
          URI.parse(text)
        rescue URI::InvalidURIError
          nil
        end
      unless parsed.is_a?(URI::HTTP) && !parsed.host.to_s.empty? && parsed.userinfo.nil?
        raise ValidationError, "source must be an absolute http(s) URL without credentials"
      end

      text
    end

    def normalize_metrics(value)
      unless value.is_a?(Hash) && !value.empty?
        raise ValidationError, "metrics must be a non-empty object of named measurements"
      end
      if value.length > MAX_METRICS
        raise ValidationError, "at most #{MAX_METRICS} metrics are stored per entry"
      end

      value.to_h do |name, raw|
        key = name.to_s.strip
        unless key.length.between?(1, MAX_METRIC_NAME_LENGTH) && key.match?(METRIC_NAME_PATTERN)
          raise ValidationError, "metric names must be short identifiers: #{name.inspect}"
        end

        [key, normalize_metric(key, raw)]
      end
    end

    def normalize_metric(name, raw)
      raise ValidationError, "metric #{name} must be an object with value, unit and basis" unless raw.is_a?(Hash)

      fields = stringify(raw)
      unknown = fields.keys - METRIC_KEYS
      raise ValidationError, "unsupported fields for metric #{name}: #{unknown.sort.join(', ')}" unless unknown.empty?

      value = fields["value"]
      unless value.is_a?(Numeric) && value.to_f.finite?
        raise ValidationError, "metric #{name} value must be a finite number"
      end

      {
        "value" => value,
        "unit" => validate_text(fields["unit"], "metric #{name} unit", MAX_UNIT_LENGTH),
        "basis" => validate_text(fields["basis"], "metric #{name} basis", MAX_BASIS_LENGTH)
      }
    end

    def validate_text(value, field, max)
      text = value.to_s.strip
      raise ValidationError, "#{field} is required" if text.empty?

      if text.length > max || text.match?(CONTROL_CHARS)
        raise ValidationError, "#{field} must be at most #{max} printable characters"
      end

      text
    end

    def identifier(value, field, max)
      text = value.to_s.strip
      unless text.length.between?(1, max) && text.match?(IDENTIFIER_PATTERN)
        raise ValidationError, "#{field} must be a model/provider identifier of at most #{max} characters"
      end

      text
    end

    def reasoning_effort(value)
      text = value.to_s.strip
      return DEFAULT_REASONING if text.empty?

      unless text.length <= MAX_REASONING_LENGTH && text.match?(REASONING_PATTERN)
        raise ValidationError, "reasoning must be a short effort label of at most #{MAX_REASONING_LENGTH} characters"
      end

      text
    end

    def stored_identity(entry)
      return nil unless entry.is_a?(Hash) && STATUSES.include?(entry["status"])

      identity(provider: entry["provider"], model: entry["model"], reasoning: entry["reasoning"])
    rescue ValidationError
      nil
    end

    def entry_identity(entry)
      entry.slice("provider", "model", "reasoning")
    end

    def dedupe_by_identity(entries)
      entries.each_with_object([]) do |entry, out|
        out.reject! { |existing| entry_identity(existing) == entry_identity(entry) }
        out << entry
      end
    end

    # Entries that no longer carry a valid identity are dropped here rather
    # than kept forever.
    def merge(existing, normalized)
      kept = existing.select do |entry|
        known = stored_identity(entry)
        known && normalized.none? { |replacement| entry_identity(replacement) == known }
      end
      merged = kept + normalized
      raise ValidationError, "model evidence cache would exceed #{MAX_ENTRIES} entries" if merged.length > MAX_ENTRIES

      merged
    end

    def write(entries)
      directory = ensure_directory
      content = JSON.pretty_generate("schema_version" => SCHEMA_VERSION, "entries" => entries)
      if content.bytesize > MAX_FILE_BYTES
        raise Error, "model evidence cache would exceed #{MAX_FILE_BYTES} bytes; the existing cache is unchanged"
      end

      temporary = File.join(directory, ".#{File.basename(@path)}.tmp-#{Process.pid}-#{format('%08x', rand(2**32))}")
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(content)
          file.flush
          file.fsync
        end
        tighten(temporary, 0o600)
        File.rename(temporary, @path)
      rescue StandardError
        File.delete(temporary) if File.exist?(temporary)
        raise
      end
      sync_directory(directory)
    end

    # Serializes read-merge-write across processes on a sibling lock file.
    # The lock is always released, including when validation, merging or the
    # write itself raises.
    def with_lock
      directory = ensure_directory
      lock_path = File.join(directory, "#{File.basename(@path)}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        tighten(lock_path, 0o600)
        begin
          lock.flock(File::LOCK_EX)
        rescue SystemCallError => error
          raise Error, "model evidence cache lock failed: #{error.class}"
        end
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end

    def ensure_directory
      directory = File.dirname(@path)
      FileUtils.mkdir_p(directory, mode: 0o700)
      tighten(directory, 0o700)
      directory
    end

    def tighten(path, mode)
      File.chmod(mode, path)
    rescue SystemCallError
      nil
    end

    def sync_directory(directory)
      File.open(directory, File::RDONLY) { |handle| handle.fsync }
    rescue SystemCallError, IOError, NotImplementedError
      nil
    end

    def now
      value = @clock.call
      raise Error, "model evidence clock must return a Time" unless value.is_a?(Time)

      value.utc
    end

    def parse_time(value)
      return nil unless value.is_a?(String) && value.match?(TIMESTAMP_PATTERN)

      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def format_time(value)
      value.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def stringify(hash)
      hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
    end
  end
end
