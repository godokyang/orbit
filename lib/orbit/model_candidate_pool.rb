# frozen_string_literal: true

require "fileutils"
require "json"

module Orbit
  # Cross-session store for the user-selected model candidate pool (ADR-009).
  #
  # The pool is the ordered list of `provider/id` identifiers the user confirms
  # from a current `orbit omp` session (`/orbit-models`). Every Orbit session
  # reads the same file and later intersects it with that session's
  # `ctx.models.list()`. It stores model identifiers and the schema version
  # only: never credentials, account details or provider connection config.
  #
  # Location: `${XDG_CONFIG_HOME:-$HOME/.config}/orbit/model-candidates.json`
  # (XDG_CONFIG_HOME counts only when absolute, as the XDG base directory
  # specification requires). The file shape is:
  #
  #   {
  #     "schema_version": "orbit-model-candidates-v1",
  #     "models": ["zhipu-coding-plan/glm-5.2", "zenmux/x-ai/grok-4.7"]
  #   }
  #
  # A model id may itself contain slashes: the provider is the first segment
  # and everything after it is the id.
  #
  # `read` returns the ordered, de-duplicated pool; `add` and `remove` do a
  # read-modify-write under an exclusive flock on a sibling `.lock` file, so two
  # sessions editing the pool cannot silently drop each other's entries. Each
  # mutation is written atomically (private temp file + fsync + rename), so a
  # reader never sees a torn file. A corrupt or wrong-schema file raises instead
  # of being silently discarded or overwritten.
  #
  # The path and environment are injectable: production callers use the
  # defaults, while tests pass a temporary path and never touch the real user
  # config.
  class ModelCandidatePool
    SCHEMA_VERSION = "orbit-model-candidates-v1"
    CONFIG_DIRECTORY = "orbit"
    FILE_NAME = "model-candidates.json"
    MAX_IDENTIFIER_LENGTH = 200

    # One provider segment followed by a non-empty id; the id may itself contain
    # slashes (e.g. zenmux/x-ai/grok-4.7). No whitespace in either part.
    IDENTIFIER_PATTERN = %r{\A[^\s/]+/[^\s]+\z}
    CONTROL_CHARS = /[\x00-\x1F\x7F]/

    class Error < StandardError; end

    class ValidationError < Error; end

    # XDG_CONFIG_HOME only counts when absolute; otherwise `home/.config`, as
    # the XDG base directory specification requires.
    def self.default_path(env: ENV, home: nil)
      config_home = env["XDG_CONFIG_HOME"].to_s
      base = config_home.start_with?("/") ? config_home : File.join(home_directory(env: env, home: home), ".config")
      File.join(base, CONFIG_DIRECTORY, FILE_NAME)
    end

    def self.home_directory(env:, home: nil)
      candidate = home.to_s.empty? ? env["HOME"].to_s : home.to_s
      candidate.empty? ? Dir.home : candidate
    end

    attr_reader :path

    def initialize(path: nil, env: ENV, home: nil)
      default = self.class.default_path(env: env, home: home)
      @path = File.expand_path(path.nil? || path.to_s.empty? ? default : path.to_s)
    end

    # Ordered, de-duplicated `provider/id` identifiers. A missing pool is empty.
    # Read-only: it never creates the directory or the file.
    def read
      stored_models
    end

    # Adds one or more identifiers (String or Array). Existing order is kept and
    # new identifiers are appended; a duplicate is a no-op. Returns the pool.
    def add(models)
      wanted = normalize(models)
      with_lock do
        current = stored_models
        additions = wanted.reject { |model| current.include?(model) }
        additions.empty? ? current : write(current + additions)
      end
    end

    # Removes one or more identifiers (String or Array); an absent identifier is
    # a no-op. Returns the pool.
    def remove(models)
      unwanted = normalize(models)
      with_lock do
        current = stored_models
        kept = current.reject { |model| unwanted.include?(model) }
        kept == current ? current : write(kept)
      end
    end

    class ConflictError < Error
      attr_reader :conflicts

      def initialize(conflicts)
        @conflicts = conflicts.freeze
        super("model candidate pool changed since the snapshot for: #{conflicts.sort.join(', ')}; " \
              "refresh the list and commit again")
      end
    end

    # Applies ONE net add/remove delta computed against `base`, the caller's
    # opening snapshot of the pool, in a single lock/read/write so a multi-
    # select commit is atomic: every identifier lands or none does. Edits other
    # sessions made to DIFFERENT identifiers in the meantime are preserved.
    # If any identifier this delta touches changed pool membership since the
    # snapshot (another session added an id this caller is adding, or removed
    # one it is removing), the whole commit is refused as ConflictError with
    # the conflicting identifiers — never silently overwritten. The caller
    # then re-reads the pool and re-selects.
    #
    # `base` may be empty (the pool was empty when the snapshot was taken);
    # `add`/`remove` must be disjoint, `add` must name identifiers absent from
    # `base` and `remove` identifiers present in it. An entirely empty delta
    # is a read-only no-op. Returns the resulting pool.
    def apply_delta(base:, add: [], remove: [])
      base_models = normalize_list(base)
      additions = normalize_list(add)
      removals = normalize_list(remove)
      raise ValidationError, "a model candidate cannot be both added and removed in one delta" unless (additions & removals).empty?
      raise ValidationError, "delta additions must not be in the snapshot pool" unless (additions & base_models).empty?
      raise ValidationError, "delta removals must be in the snapshot pool" unless (removals - base_models).empty?
      return read if additions.empty? && removals.empty?

      base_members = base_models.to_h { |model| [model, true] }
      with_lock do
        current = stored_models
        current_members = current.to_h { |model| [model, true] }
        conflicts = (additions | removals).select { |model| current_members.key?(model) != base_members.key?(model) }
        raise ConflictError, conflicts unless conflicts.empty?

        kept = current.reject { |model| removals.include?(model) }
        pending = additions.reject { |model| kept.include?(model) }
        pending.empty? && kept == current ? current : write(kept + pending)
      end
    end

    private

    def normalize(models)
      list = models.is_a?(Array) ? models : [models]
      raise ValidationError, "at least one model candidate is required" if list.empty?

      normalize_list(list)
    end

    # Same identifier normalization, but an empty list is allowed: a delta's
    # snapshot side may legitimately be the empty pool.
    def normalize_list(models)
      list = models.is_a?(Array) ? models : [models]
      list.map { |model| validate_identifier(model) }.uniq
    end

    def validate_identifier(value)
      text = value.to_s.strip
      unless text.length.between?(1, MAX_IDENTIFIER_LENGTH) &&
             text.match?(IDENTIFIER_PATTERN) && !text.match?(CONTROL_CHARS)
        # The rejected value is deliberately not echoed: a bad argument could
        # be a pasted credential, and this error reaches stdout/stderr.
        raise ValidationError,
              "model candidate must be provider/id with no whitespace (the id may contain slashes)"
      end

      text
    end

    def stored_models
      return [] unless File.exist?(@path)

      parsed =
        begin
          JSON.parse(File.read(@path))
        rescue JSON::ParserError
          raise Error, "model candidate pool is not valid JSON: #{@path}"
        end
      unless parsed.is_a?(Hash) && parsed["schema_version"] == SCHEMA_VERSION && parsed["models"].is_a?(Array)
        raise Error, "model candidate pool does not match #{SCHEMA_VERSION}: #{@path}"
      end

      parsed["models"].map { |model| stored_identifier(model) }.uniq
    rescue Errno::ENOENT
      raise Error, "model candidate pool disappeared while reading: #{@path}"
    end

    def stored_identifier(model)
      validate_identifier(model)
    rescue ValidationError
      raise Error, "model candidate pool contains a malformed identifier: #{@path}"
    end

    def write(models)
      directory = ensure_directory
      content = JSON.pretty_generate("schema_version" => SCHEMA_VERSION, "models" => models)
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
      models
    end

    # Serializes read-modify-write across processes on a sibling lock file. The
    # lock is always released, including when validation, reading or the write
    # itself raises.
    def with_lock
      directory = ensure_directory
      lock_path = File.join(directory, "#{File.basename(@path)}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        tighten(lock_path, 0o600)
        begin
          lock.flock(File::LOCK_EX)
        rescue SystemCallError => error
          raise Error, "model candidate pool lock failed: #{error.class}"
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
  end
end
