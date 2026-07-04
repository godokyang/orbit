# frozen_string_literal: true

require "socket"
require "fileutils"

RUNTIME_SESSION_SCHEMA = "orbit-runtime-session-v1"
RUNTIME_INSTANCE_SCHEMA = "orbit-runtime-instance-v1"
RUNTIME_REPLACEMENT_SCHEMA = "orbit-start-replacement-v1"
DEFAULT_RUNTIME_HEARTBEAT_TTL_SECONDS = 300

def orbit_runtime_root
  File.join(Dir.pwd, ".orbit", "runtime")
end

def orbit_runtime_sessions_dir
  File.join(orbit_runtime_root, "sessions")
end

def orbit_runtime_instances_dir
  File.join(orbit_runtime_root, "instances")
end

def orbit_runtime_replacements_dir
  File.join(orbit_runtime_root, "replacements")
end

def orbit_runtime_locks_dir
  File.join(orbit_runtime_root, "locks")
end

def runtime_safe_name(value)
  value.to_s.gsub(/[^A-Za-z0-9_.-]+/, "_")
end

def runtime_session_path(session_id)
  File.join(orbit_runtime_sessions_dir, "#{runtime_safe_name(session_id)}.json")
end

def runtime_instance_path(instance)
  File.join(orbit_runtime_instances_dir, "#{runtime_safe_name(instance)}.json")
end

def runtime_replacement_path(instance)
  File.join(orbit_runtime_replacements_dir, "#{runtime_safe_name(instance)}.json")
end

def runtime_instance_lock_path(instance)
  File.join(orbit_runtime_locks_dir, "#{runtime_safe_name(instance)}.lock")
end

def runtime_session_lock_path(session_id)
  File.join(orbit_runtime_locks_dir, "session-#{runtime_safe_name(session_id)}.lock")
end

def runtime_with_instance_lock(instance)
  FileUtils.mkdir_p(orbit_runtime_locks_dir)
  File.open(runtime_instance_lock_path(instance), File::RDWR | File::CREAT, 0o644) do |lock|
    lock.flock(File::LOCK_EX)
    yield
  ensure
    lock.flock(File::LOCK_UN) if lock
  end
end

def runtime_with_session_lock(session_id)
  FileUtils.mkdir_p(orbit_runtime_locks_dir)
  File.open(runtime_session_lock_path(session_id), File::RDWR | File::CREAT, 0o644) do |lock|
    lock.flock(File::LOCK_EX)
    yield
  ensure
    lock.flock(File::LOCK_UN) if lock
  end
end

def runtime_load_json_file(path)
  return nil unless File.file?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError
  nil
end

def runtime_write_json_file!(path, payload)
  write_file_atomically(path, "#{JSON.pretty_generate(payload)}\n")
  path
end

def runtime_read_session(session_id)
  runtime_load_json_file(runtime_session_path(session_id))
end

def runtime_write_session_unlocked!(session)
  session_id = session["session_id"].to_s
  usage_error("runtime session missing session_id") if session_id.empty?

  now = Time.now.utc.iso8601
  session["schema_version"] ||= RUNTIME_SESSION_SCHEMA
  session["created_at"] ||= now
  session["updated_at"] = now
  session["heartbeat"] ||= {}
  session["heartbeat"]["last_seen_at"] ||= now
  session["heartbeat"]["ttl_seconds"] ||= DEFAULT_RUNTIME_HEARTBEAT_TTL_SECONDS
  runtime_write_json_file!(runtime_session_path(session_id), session)
end

def runtime_write_session!(session)
  session_id = session["session_id"].to_s
  usage_error("runtime session missing session_id") if session_id.empty?

  runtime_with_session_lock(session_id) do
    runtime_write_session_unlocked!(session)
  end
end

def runtime_update_session!(session_id)
  runtime_with_session_lock(session_id) do
    current = runtime_read_session(session_id)
    updated = yield(current)
    runtime_write_session_unlocked!(updated || current) if (updated || current).is_a?(Hash)
  end
end

def runtime_blank_instance_record(instance)
  {
    "schema_version" => RUNTIME_INSTANCE_SCHEMA,
    "instance" => instance,
    "current_session_id" => nil,
    "current_state" => "absent",
    "previous_sessions" => [],
    "replacement_diagnostics" => [],
    "ack" => nil
  }
end

def runtime_normalize_instance_record(instance, record)
  base = runtime_blank_instance_record(instance)
  return base unless record.is_a?(Hash)

  if record["schema_version"] == RUNTIME_REPLACEMENT_SCHEMA
    base["replacement_diagnostics"] = [record]
    return base
  end

  base.merge(record).tap do |merged|
    merged["schema_version"] = RUNTIME_INSTANCE_SCHEMA
    merged["instance"] = instance
    merged["previous_sessions"] = Array(merged["previous_sessions"])
    merged["replacement_diagnostics"] = Array(merged["replacement_diagnostics"])
  end
end

def runtime_read_instance(instance)
  runtime_normalize_instance_record(instance, runtime_load_json_file(runtime_instance_path(instance)))
end

def runtime_write_instance!(instance, record)
  normalized = runtime_normalize_instance_record(instance, record)
  normalized["updated_at"] = Time.now.utc.iso8601
  runtime_write_json_file!(runtime_instance_path(instance), normalized)
  normalized
end

def runtime_update_instance!(instance)
  runtime_with_instance_lock(instance) do
    current = runtime_read_instance(instance)
    updated = yield(current)
    runtime_write_instance!(instance, updated || current)
  end
end

def runtime_set_current_session!(instance, session_id, state)
  runtime_update_instance!(instance) do |record|
    previous = record["current_session_id"].to_s
    if !previous.empty? && previous != session_id.to_s
      record["previous_sessions"] << previous
      record["previous_sessions"] = record["previous_sessions"].uniq
    end
    record["current_session_id"] = session_id
    record["current_state"] = state
    record
  end
end

def runtime_record_replacement!(instance, diagnostic)
  runtime_update_instance!(instance) do |record|
    replacement_targets = Array(record["previous_sessions"]).map(&:to_s)
    replacement_targets << record["current_session_id"].to_s
    replacement_targets.uniq.reject(&:empty?).each do |session_id|
      next if diagnostic.is_a?(Hash) && session_id == diagnostic["new_session_id"].to_s

      runtime_mark_session_replaced!(session_id, diagnostic)
    end
    record["replacement_diagnostics"] << diagnostic
    record
  end
  runtime_write_json_file!(runtime_replacement_path(instance), diagnostic) if diagnostic.is_a?(Hash)
end

def runtime_mark_session_replaced!(session_id, diagnostic = nil)
  runtime_update_session!(session_id) do |session|
    return nil unless session.is_a?(Hash)

    now = Time.now.utc.iso8601
    session["state"] = "replaced"
    session["updated_at"] = now
    session["heartbeat"] ||= {}
    session["heartbeat"]["last_seen_at"] = now
    session["replacement"] = diagnostic if diagnostic.is_a?(Hash)
    session
  end
end

def runtime_project_config_present?
  File.file?(File.join(Dir.pwd, ".orbit", "roles.yaml")) &&
    File.file?(File.join(Dir.pwd, ".orbit", "instances.yaml"))
end

def runtime_sha256_for_value(value)
  Digest::SHA256.hexdigest(JSON.generate(value))
end

def runtime_project_root_sha256(path = Dir.pwd)
  Digest::SHA256.hexdigest(File.expand_path(path))
end

def runtime_host_id
  ENV["HOSTNAME"].to_s.strip.empty? ? Socket.gethostname : ENV["HOSTNAME"].to_s.strip
rescue StandardError
  "unknown"
end

def runtime_user
  ENV["USER"].to_s.strip.empty? ? "unknown" : ENV["USER"].to_s.strip
end
