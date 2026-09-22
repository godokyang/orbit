# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "time"
require_relative "workspace_binding"

module Orbit
  # Task-local records. The runtime is the sole state writer; other clients
  # submit commands through the inbox. Original instruction bytes are kept.
  class TaskRecord
    attr_reader :path

    def self.create(project_root:, instruction:, source:, connection:, review:, basis: [], estimate: {})
      root = File.realpath(project_root)
      workspace = WorkspaceBinding.bind(project_root: root).merge("history" => [])
      path = File.join(root, ".orbit", "tasks", SecureRandom.uuid)
      FileUtils.mkdir_p(File.join(path, "inbox"), mode: 0o700)
      record = new(path)
      record.write("instruction.txt", instruction)
      documents = basis.map.with_index do |file, index|
        original = File.realpath(file)
        raise ArgumentError, "basis must be a file: #{file}" unless File.file?(original)

        bytes = File.binread(original)
        stored = "basis/#{index}-#{File.basename(original)}"
        record.write(stored, bytes)
        { "source" => original, "path" => stored, "sha256" => Digest::SHA256.hexdigest(bytes) }
      end
      record.save({
        "format" => "orbit-task-1", "id" => File.basename(path), "project_root" => root,
        "workspace" => workspace,
        "created_at" => Time.now.utc.iso8601, "status" => "starting",
        "instruction_source" => source, "basis" => documents, "amendments" => [],
        "connection" => connection, "review" => review, "estimate" => estimate,
        "checks" => [], "decisions" => [], "usage" => { "tokens" => nil }
      })
      record
    end

    def initialize(path)
      @path = File.realpath(path)
    end

    def state
      JSON.parse(File.read(File.join(path, "state.json")))
    end

    def save(value)
      write("state.json", JSON.pretty_generate(value) + "\n")
    end

    def write(relative, bytes)
      destination = File.join(path, relative)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      temporary = "#{destination}.#{SecureRandom.hex(8)}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.rename(temporary, destination)
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end
    end

    def event(type, details = {})
      File.open(File.join(path, "events.jsonl"), "a", 0o600) do |file|
        file.puts(JSON.generate({ "at" => Time.now.utc.iso8601, "type" => type }.merge(details)))
        file.flush
      end
    end

    def with_runtime_lock
      File.open(File.join(path, "runtime.lock"), "w", 0o600) do |file|
        raise ArgumentError, "this task already has a runtime" unless file.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def with_root_lock(thread_id)
      directory = File.join(state.fetch("project_root"), ".orbit", "session-locks")
      FileUtils.mkdir_p(directory, mode: 0o700)
      lock_path = File.join(directory, "#{Digest::SHA256.hexdigest(thread_id)}.lock")
      File.open(lock_path, "w", 0o600) do |file|
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          raise ArgumentError, "this Root session already has an Orbit task process"
        end

        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def submit(type, details = {})
      id = "#{Time.now.utc.strftime('%Y%m%d%H%M%S%6N')}-#{SecureRandom.hex(6)}"
      write("inbox/#{id}.json", JSON.generate(details.merge("type" => type)))
      id
    end

    def commands
      Dir.glob(File.join(path, "inbox", "*.json")).sort.each do |file|
        yield JSON.parse(File.read(file))
        File.unlink(file)
      end
    end

    def inputs(current_state = state)
      {
        "instruction" => File.read(File.join(path, "instruction.txt")),
        "amendments" => current_state.fetch("amendments").map do |item|
          item.merge("text" => File.read(File.join(path, item.fetch("path"))))
        end,
        "basis" => current_state.fetch("basis").map do |item|
          item.merge("text" => File.read(File.join(path, item.fetch("path"))))
        end
      }
    end

    def input_digest(current_state = state)
      Digest::SHA256.hexdigest(JSON.generate(inputs(current_state)))
    end
  end
end
