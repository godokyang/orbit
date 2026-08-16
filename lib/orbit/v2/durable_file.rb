# frozen_string_literal: true

require "fileutils"
require "securerandom"

require_relative "errors"

module Orbit
  module V2
    # Shared durable single-file commit primitives used by the v2 store
    # seams (TransactionLog, ProtocolRoot marker). This is the exact commit
    # machinery, not a generalized filesystem framework: exclusive
    # cross-process lock, securely randomized exclusive same-directory
    # staging, required fsync before an atomic rename that is the commit
    # boundary, and a strictly best-effort post-commit parent-directory
    # fsync that never surfaces as an ambiguous failure.
    module DurableFile
      module_function

      # Fails closed unless +path+ is one single-link regular file. A
      # symlink, hard-linked, or other non-regular path would let an alias
      # rename its staged file over the link and fork/redirect the artifact,
      # so it is rejected before any read or write.
      def verify_single_link!(path, code:, label:)
        stat = File.lstat(path)
        unless stat.file? && stat.nlink == 1
          raise ContractError.new(
            code,
            "#{label} path must be a single-link regular file " \
              "(#{stat.ftype}, nlink #{stat.nlink})",
            path: label
          )
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      # Exclusive cross-process lock on "<path>.lock" covering the whole
      # read-verify-write cycle. Nested store composition may reacquire the
      # same lock on the same thread; only the outermost acquisition owns
      # the flock descriptor, so cross-process exclusion remains intact.
      def with_exclusive_lock(path)
        lock_path = File.expand_path("#{path}.lock")
        held = Thread.current[:orbit_v2_exclusive_locks]
        if held&.key?(lock_path)
          held[lock_path] += 1
          begin
            return yield
          ensure
            held[lock_path] -= 1
          end
        end

        held ||= {}
        Thread.current[:orbit_v2_exclusive_locks] = held
        held[lock_path] = 1
        begin
          FileUtils.mkdir_p(File.dirname(lock_path))
          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          ensure
            lock.flock(File::LOCK_UN) if lock
          end
        ensure
          held.delete(lock_path)
          Thread.current[:orbit_v2_exclusive_locks] = nil if held.empty?
        end
      end

      # Atomically replaces +path+ with +content+ via a same-directory
      # staged file created with O_CREAT|O_EXCL on a securely randomized
      # unpredictable name (never following or pretruncating an existing
      # symlink or regular file, so a planted predictable staging path
      # cannot overwrite user data or the committed artifact). The staged
      # bytes are flushed and fsynced (a staging fsync failure aborts before
      # the rename and keeps the previous accepted state), then atomically
      # renamed over the artifact; the parent directory is fsynced strictly
      # best-effort afterwards. Orphaned exclusive staging files are never
      # read and never become accepted truth.
      def atomic_write(path, content)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp = create_staging_file(dir, File.basename(path), content)
        File.rename(tmp, path)
        fsync_directory(dir)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def create_staging_file(dir, basename, content)
        prefix = ".#{basename}.tmp."
        10.times do
          candidate = File.join(dir, "#{prefix}#{$$}.#{Thread.current.object_id}.#{SecureRandom.hex(8)}")
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

      private_class_method :create_staging_file, :fsync_directory
    end
  end
end
