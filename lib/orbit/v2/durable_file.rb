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
        reset_lock_registry_after_fork!
        state = Thread.current[:orbit_v2_exclusive_locks]
        if state && state[:pid] != Process.pid
          state = nil
        end
        unless state
          state = { pid: Process.pid, locks: {} }
          Thread.current[:orbit_v2_exclusive_locks] = state
        end
        held = state.fetch(:locks)
        if (entry = held[lock_path])
          entry[:depth] += 1
          begin
            return yield
          ensure
            entry[:depth] -= 1
          end
        end

        begin
          FileUtils.mkdir_p(File.dirname(lock_path))
          owner_pid = Process.pid
          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            register_lock_io(lock)
            begin
              lock.flock(File::LOCK_EX)
              held[lock_path] = { depth: 1, io: lock }
              yield
            ensure
              if Process.pid == owner_pid
                lock.flock(File::LOCK_UN) unless lock.closed?
                held.delete(lock_path)
                unregister_lock_io(lock)
              else
                # A no-block fork may unwind the inherited Ruby stack in
                # the child. It must never LOCK_UN the parent's shared
                # open-file-description lock. Closing the child's inherited
                # descriptor is safe because the parent still owns its copy.
                reset_lock_registry_after_fork!
              end
            end
          end
        ensure
          held.delete(lock_path)
          current = Thread.current[:orbit_v2_exclusive_locks]
          Thread.current[:orbit_v2_exclusive_locks] = nil if current.equal?(state) && held.empty?
        end
      end

      # Reentrancy is Fiber-local, but inherited descriptor cleanup must be
      # process-wide: a fork from Fiber A also inherits locks held by every
      # suspended Fiber/thread. The first DurableFile lock call in the child
      # closes every inherited registered IO without LOCK_UN, then starts a
      # registry owned by the child PID. Parent IO objects are unaffected by
      # copy-on-write process isolation.
      def reset_lock_registry_after_fork!
        pid = Process.pid
        return if @exclusive_lock_registry_pid == pid

        inherited = @exclusive_lock_ios || {}
        @exclusive_lock_registry_pid = pid
        @exclusive_lock_ios = {}
        inherited.each_key do |io|
          io.close unless io.closed?
        rescue IOError, SystemCallError
          nil
        end
      end

      def register_lock_io(io)
        reset_lock_registry_after_fork!
        @exclusive_lock_ios[io] = true
      end

      def unregister_lock_io(io)
        reset_lock_registry_after_fork!
        @exclusive_lock_ios.delete(io)
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

      private_class_method :reset_lock_registry_after_fork!, :register_lock_io,
                           :unregister_lock_io, :create_staging_file, :fsync_directory
    end
  end
end
