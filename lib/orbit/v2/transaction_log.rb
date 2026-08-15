# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

require_relative "canonical_json"
require_relative "errors"
require_relative "identifiers"

module Orbit
  module V2
    # Slice 6 increment 1: the durable atomic compare-and-append store seam
    # for canonical transaction records.
    #
    # One file-backed log per path. Every accepted transaction is one atomic
    # canonical record carrying `transaction_id`, `previous_tip_digest`
    # (null for the genesis record), `content_digest` (sha256 of the
    # canonical payload), and the canonical `payload`. Ordering authority is
    # exclusively the verified `previous_tip_digest` chain: records carry no
    # timestamps and array order is never an independent ordering fact.
    #
    # Public behavior:
    # - `append(transaction_id:, expected_tip_digest:, payload:)` returns
    #   `:appended` (new record committed), `:idempotent` (a record with the
    #   same transaction id and byte-identical canonical payload is already
    #   committed), or `:stale` (the transaction is new but expected tip is
    #   not the verified tip; bytes unchanged). `expected_tip_digest` is
    #   compare-and-append input for a NEW transaction only and never part
    #   of replay equivalence: a retry of an already-committed transaction
    #   returns `:idempotent` without requiring the pre-append tip. Same
    #   transaction id with different canonical payload content raises
    #   ContractError("transaction_log_reuse") and fails closed.
    # - transaction ids must be non-empty canonical NFC UTF-8 strings:
    #   invalid UTF-8 and composed/decomposed aliases fail closed with
    #   ContractError("transaction_log_argument_invalid") before any lock or
    #   write, so an append can never commit a record whose canonical id
    #   the reader would reject as a duplicate.
    # - `tip_digest` returns "sha256:<64-hex>" for the verified final record
    #   or nil for an empty log; `records` returns detached verified records
    #   in chain order. Both re-read and fully verify the file, failing
    #   closed with ContractError("transaction_log_corrupt") on corruption
    #   or truncation — never latest-wins.
    #
    # The file is a canonical envelope `{schema_version, records,
    # file_digest}` whose `file_digest` covers the canonical records array,
    # with closed key sets for both the envelope and every record. A read
    # additionally requires the committed bytes to byte-equal
    # `CanonicalJSON.dump(parsed)`, so any single-byte change to committed
    # bytes (bit rot, partial write, trailing whitespace, alternate JSON
    # spelling, duplicate keys, unknown authority-like fields, or tampering
    # without a full recompute) fails verification, including changes
    # confined to the final record that no successor link would otherwise
    # anchor. The payload itself stays generic (any canonical value); no
    # domain fields live outside it.
    #
    # The committed path must be one single-link regular file: a symlink,
    # hard-linked, or any other non-regular final path fails closed with
    # ContractError("transaction_log_path_invalid") so an alias path can
    # never split the log and bypass compare-and-append.
    #
    # Commit protocol (standard library only): a cross-process exclusive
    # flock covers the whole read-verify-append cycle; bytes are written to
    # a same-directory staged file created with O_CREAT|O_EXCL on a
    # securely randomized unpredictable name (never following or
    # pretruncating an existing symlink or regular file, so a planted
    # predictable staging path cannot overwrite user data or the committed
    # log), flushed and fsynced (a staged-file fsync failure aborts before
    # the rename and keeps the previous accepted state), atomically renamed
    # over the log, and the parent directory is fsynced strictly
    # best-effort afterwards. The rename is the commit boundary: a failure
    # before it leaves the previous accepted state readable, abandoned
    # staging files are never read and never become accepted truth, and the
    # post-commit directory fsync never surfaces as an ambiguous failure.
    #
    # There is no mutable "current tip" fact outside the verified chain, no
    # dual store, no fallback/backfill, and no clock/store abstraction.
    # Domain writers (control-id claim + active LeadSession binding + genesis
    # checkpoint as one transaction) are later Slice 6 increments and do not
    # exist here.
    class TransactionLog
      SCHEMA_VERSION = "orbit-transaction-log-v1".freeze
      ENVELOPE_KEYS = %w[file_digest records schema_version].freeze
      RECORD_KEYS = %w[content_digest payload previous_tip_digest schema_version transaction_id].freeze

      def initialize(path:)
        @path = File.expand_path(path)
      end

      def append(transaction_id:, expected_tip_digest:, payload:)
        validate_transaction_id!(transaction_id)
        validate_tip_digest!(expected_tip_digest)
        begin
          content = canonical_content_digest(payload)
        rescue ArgumentError => error
          raise ContractError.new(
            "transaction_log_argument_invalid",
            "payload is not canonical JSON: #{error.message}",
            path: "transaction_log.payload"
          )
        end

        with_exclusive_lock do
          current, tip = read_and_verify

          if (existing = current.find { |record| record["transaction_id"] == transaction_id })
            return :idempotent if existing["content_digest"] == content

            raise ContractError.new(
              "transaction_log_reuse",
              "transaction #{transaction_id} already exists with different canonical content",
              path: "transaction_log.#{transaction_id}"
            )
          end

          return :stale unless expected_tip_digest == tip

          record = {
            "schema_version" => SCHEMA_VERSION,
            "transaction_id" => transaction_id,
            "previous_tip_digest" => tip,
            "content_digest" => content,
            "payload" => payload
          }
          write_atomically(current + [record])
          :appended
        end
      end

      def tip_digest
        _, tip = read_and_verify
        tip
      end

      def records
        current, = read_and_verify
        current
      end

      private

      def validate_transaction_id!(transaction_id)
        return if transaction_id.is_a?(String) &&
                  !transaction_id.empty? &&
                  canonical_nfc_utf8?(transaction_id)

        raise ContractError.new(
          "transaction_log_argument_invalid",
          "transaction_id must be a non-empty canonical NFC UTF-8 string",
          path: "transaction_log.transaction_id"
        )
      end

      # The committed file stores the canonical NFC form of every string, so
      # two byte-different but canonically-equal transaction ids would
      # collapse into one id in the file and commit state the reader rejects
      # as a duplicate. The identity boundary is therefore fail-closed:
      # transaction ids must already be canonical NFC UTF-8 (invalid UTF-8
      # and composed/decomposed aliases are rejected before any lock or
      # write).
      def canonical_nfc_utf8?(value)
        value.encode(Encoding::UTF_8).unicode_normalize(:nfc) == value
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        false
      end

      def validate_tip_digest!(digest)
        return if digest.nil? || Identifiers.digest?(digest)

        raise ContractError.new(
          "transaction_log_argument_invalid",
          "expected_tip_digest must be nil or a sha256: digest",
          path: "transaction_log.expected_tip_digest"
        )
      end

      def canonical_content_digest(payload)
        "sha256:#{CanonicalJSON.sha256(payload)}"
      end

      def record_digest(record)
        "sha256:#{CanonicalJSON.sha256(record)}"
      end

      # Returns [records, tip_digest]. A missing log is an empty verified
      # chain. Any unreadable/inconsistent state fails closed rather than
      # resolving latest-wins.
      def read_and_verify
        verify_final_path!
        bytes = File.binread(@path)
        parsed = JSON.parse(bytes)
        unless parsed.is_a?(Hash) && parsed["schema_version"] == SCHEMA_VERSION
          raise corrupt("log is not a #{SCHEMA_VERSION} envelope")
        end
        unless parsed.keys.sort == ENVELOPE_KEYS
          raise corrupt("log envelope carries fields outside the closed key set")
        end
        begin
          canonical_bytes = CanonicalJSON.dump(parsed)
        rescue ArgumentError
          raise corrupt("log envelope is not canonical JSON")
        end
        unless bytes == canonical_bytes
          raise corrupt("committed bytes are not the canonical dump of the envelope")
        end

        records = parsed["records"]
        unless records.is_a?(Array)
          raise corrupt("log envelope has no canonical record array")
        end
        file_digest = parsed["file_digest"]
        unless Identifiers.digest?(file_digest)
          raise corrupt("log envelope has an invalid file_digest")
        end
        begin
          computed = "sha256:#{CanonicalJSON.sha256(records)}"
        rescue ArgumentError
          raise corrupt("log records are not canonical JSON")
        end
        unless computed == file_digest
          raise corrupt("log file_digest does not match the records array")
        end

        previous = nil
        seen_ids = {}
        records.each_with_index do |record, index|
          location = { "record_index" => index }
          unless record.is_a?(Hash) && record["schema_version"] == SCHEMA_VERSION
            raise corrupt("record has an invalid or missing schema_version", location)
          end
          unless record.keys.sort == RECORD_KEYS
            raise corrupt("record carries fields outside the closed key set", location)
          end
          transaction_id = record["transaction_id"]
          unless transaction_id.is_a?(String) && !transaction_id.empty?
            raise corrupt("record has an invalid transaction_id", location)
          end
          if seen_ids.key?(transaction_id)
            raise corrupt("transaction #{transaction_id} appears more than once", location)
          end

          seen_ids[transaction_id] = true
          previous_digest = record["previous_tip_digest"]
          if index.zero?
            raise corrupt("genesis record must have a null previous_tip_digest", location) unless previous_digest.nil?
          elsif !Identifiers.digest?(previous_digest) || previous_digest != previous
            raise corrupt("record does not extend the verified previous tip", location)
          end

          content_digest = record["content_digest"]
          unless Identifiers.digest?(content_digest)
            raise corrupt("record has an invalid content_digest", location)
          end
          begin
            unless canonical_content_digest(record["payload"]) == content_digest
              raise corrupt("record content_digest does not match its canonical payload", location)
            end
            previous = record_digest(record)
          rescue ArgumentError
            raise corrupt("record is not canonical JSON", location)
          end
        end
        [records, previous]
      rescue Errno::ENOENT
        [[], nil]
      rescue JSON::ParserError
        raise corrupt("log bytes are not valid JSON (truncated or corrupted)")
      end

      def corrupt(message, details = nil)
        ContractError.new("transaction_log_corrupt", message, path: "transaction_log", details: details)
      end

      # The committed log must be one single-link regular file. A symlink
      # (or any other non-regular path) would let an alias store rename its
      # staged file over the link, and a hard-linked path shares one inode
      # until a rename replaces only its own directory entry — either way
      # the log forks into two independently valid chains and bypasses
      # compare-and-append, so both fail closed.
      def verify_final_path!
        stat = File.lstat(@path)
        unless stat.file? && stat.nlink == 1
          raise ContractError.new(
            "transaction_log_path_invalid",
            "transaction log path must be a single-link regular file " \
              "(#{stat.ftype}, nlink #{stat.nlink})",
            path: "transaction_log"
          )
        end
      rescue Errno::ENOENT
        nil
      end

      def with_exclusive_lock
        lock_path = "#{@path}.lock"
        FileUtils.mkdir_p(File.dirname(lock_path))
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN) if lock
        end
      end

      def write_atomically(records)
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir)
        content = CanonicalJSON.dump(
          "schema_version" => SCHEMA_VERSION,
          "records" => records,
          "file_digest" => "sha256:#{CanonicalJSON.sha256(records)}"
        )
        tmp = create_staging_file(dir, content)
        # The rename is the commit boundary. The parent-directory fsync
        # afterwards is strictly best-effort and never surfaces, so a
        # directory-fsync failure cannot report an ambiguous "failed"
        # append after the transaction is already visible.
        File.rename(tmp, @path)
        fsync_directory(dir)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      # Securely randomized exclusive staging file in the same directory.
      # O_CREAT|O_EXCL on an unpredictable name never follows or
      # pretruncates an existing symlink or regular file, so a planted
      # predictable staging path is ignored and can never overwrite user
      # data or the committed log. Staged-file fsync is required: if the
      # payload bytes cannot be fsynced, fail before the rename and keep
      # the previous accepted state (the caller's ensure removes the
      # staging file). Orphaned exclusive staging files are never read and
      # never become accepted truth.
      def create_staging_file(dir, content)
        base = ".#{File.basename(@path)}.tmp."
        10.times do
          candidate = File.join(dir, "#{base}#{$$}.#{Thread.current.object_id}.#{SecureRandom.hex(8)}")
          begin
            File.open(candidate, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
              file.write(content)
              file.flush
              file.fsync
            end
            return candidate
          rescue Errno::EEXIST
            next
          end
        end
        raise Errno::EEXIST, "could not create an exclusive staging file in #{dir}"
      end

      def fsync_directory(path)
        Dir.open(path) do |dir|
          dir.fsync if dir.respond_to?(:fsync)
        end
      rescue IOError, SystemCallError, NotImplementedError
        nil
      end
    end
  end
end
