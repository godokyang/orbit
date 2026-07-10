# frozen_string_literal: true

TRIAL_METRIC_EVENT_SCHEMA = "orbit-trial-metric-event-v1"
TRIAL_METRICS_REPORT_SCHEMA = "orbit-trial-metrics-report-v1"
TRIAL_METRIC_NAMES = %w[
  task_snapshot
  workflow_failure
  independent_defect
  post_gate_defect
  status_question
  automatic_session
].freeze

def default_trial_metrics_file
  File.join(".orbit", "metrics", "trial-events.jsonl")
end

def trial_metrics_integer(value, option, positive: false)
  text = value.to_s
  usage_error("#{option} must be an integer.") unless text.match?(/\A\d+\z/)
  number = text.to_i
  usage_error("#{option} must be positive.") if positive && !number.positive?
  number
end

def parse_trial_metrics_args(args)
  subcommand = args.shift
  usage_error("metrics requires capture, record, or report subcommand.") unless %w[capture record report].include?(subcommand)
  options = {
    "subcommand" => subcommand,
    "file" => default_trial_metrics_file,
    "json" => false,
    "stage" => "after",
    "window_days" => 30
  }
  until args.empty?
    arg = args.shift
    case arg
    when "--json" then options["json"] = true
    when "--file" then options["file"] = option_value(args, "--file")
    when /\A--file=(.+)\z/ then options["file"] = Regexp.last_match(1)
    when "--task" then options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/ then options["task"] = Regexp.last_match(1)
    when "--evidence" then options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/ then options["evidence"] = Regexp.last_match(1)
    when "--stage" then options["stage"] = option_value(args, "--stage")
    when /\A--stage=(.+)\z/ then options["stage"] = Regexp.last_match(1)
    when "--duration-seconds" then options["duration_seconds"] = trial_metrics_integer(option_value(args, "--duration-seconds"), "--duration-seconds")
    when /\A--duration-seconds=(.+)\z/ then options["duration_seconds"] = trial_metrics_integer(Regexp.last_match(1), "--duration-seconds")
    when "--tokens" then options["tokens"] = trial_metrics_integer(option_value(args, "--tokens"), "--tokens")
    when /\A--tokens=(.+)\z/ then options["tokens"] = trial_metrics_integer(Regexp.last_match(1), "--tokens")
    when "--metric" then options["metric"] = option_value(args, "--metric")
    when /\A--metric=(.+)\z/ then options["metric"] = Regexp.last_match(1)
    when "--failure-kind" then options["failure_kind"] = option_value(args, "--failure-kind")
    when /\A--failure-kind=(.+)\z/ then options["failure_kind"] = Regexp.last_match(1)
    when "--severity" then options["severity"] = option_value(args, "--severity")
    when /\A--severity=(.+)\z/ then options["severity"] = Regexp.last_match(1)
    when "--source" then options["source"] = option_value(args, "--source")
    when /\A--source=(.+)\z/ then options["source"] = Regexp.last_match(1)
    when "--topic" then options["topic"] = option_value(args, "--topic")
    when /\A--topic=(.+)\z/ then options["topic"] = Regexp.last_match(1)
    when "--outcome" then options["outcome"] = option_value(args, "--outcome")
    when /\A--outcome=(.+)\z/ then options["outcome"] = Regexp.last_match(1)
    when "--window-days" then options["window_days"] = trial_metrics_integer(option_value(args, "--window-days"), "--window-days", positive: true)
    when /\A--window-days=(.+)\z/ then options["window_days"] = trial_metrics_integer(Regexp.last_match(1), "--window-days", positive: true)
    else usage_error("Unknown metrics #{subcommand} option: #{arg}")
    end
  end
  usage_error("metrics #{subcommand} requires --json.") unless options["json"]
  if subcommand == "capture"
    usage_error("metrics capture requires --task and --evidence.") if options["task"].to_s.empty? || options["evidence"].to_s.empty?
    usage_error("--stage must be baseline or after.") unless %w[baseline after].include?(options["stage"])
  elsif subcommand == "record"
    usage_error("metrics record requires --metric.") unless TRIAL_METRIC_NAMES.include?(options["metric"]) && options["metric"] != "task_snapshot"
  end
  options
end

def trial_metric_event(metric, task: nil, dimensions: {})
  event = {
    "schema_version" => TRIAL_METRIC_EVENT_SCHEMA,
    "event_id" => "otm_#{SecureRandom.hex(12)}",
    "created_at" => Time.now.utc.iso8601,
    "project" => File.basename(Dir.pwd),
    "metric" => metric,
    "dimensions" => dimensions.compact
  }
  event["task"] = project_relative_persisted_path(task, field: "metrics task", strict: true) if task
  event
end

def append_trial_metric_event(path, event)
  expanded = File.expand_path(path)
  FileUtils.mkdir_p(File.dirname(expanded))
  lock_path = "#{expanded}.lock"
  File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
    lock.flock(File::LOCK_EX)
    File.open(expanded, "a", 0o644) do |file|
      file.write("#{JSON.generate(event)}\n")
      file.flush
      file.fsync
    end
  ensure
    lock.flock(File::LOCK_UN) if lock
  end
  event
end

def trial_collect_artifact_refs(value, refs = [])
  case value
  when Hash
    is_ref = value["schema_version"] == "orbit-artifact-ref-v1" ||
             %w[id path sha256 producer_command created_at git_head task_revision lifecycle].all? { |field| value.key?(field) }
    refs << (value["artifact"].is_a?(Hash) ? value["artifact"] : value) if is_ref
    value.each_value { |child| trial_collect_artifact_refs(child, refs) }
  when Array
    value.each { |child| trial_collect_artifact_refs(child, refs) }
  end
  refs
end

def trial_artifact_snapshot(evidence)
  refs = trial_collect_artifact_refs(evidence).each_with_object({}) do |ref, unique|
    key = [ref["path"], ref["sha256"]]
    unique[key] = ref
  end.values
  bytes = refs.sum do |ref|
    path = ref["path"].to_s
    expanded = File.expand_path(path)
    expanded.start_with?("#{File.realpath(Dir.pwd)}/") && File.file?(expanded) ? File.size(expanded) : 0
  rescue StandardError
    0
  end
  {
    "artifact_count" => refs.length,
    "artifact_bytes" => bytes,
    "structured_refs_only" => true
  }
end

def trial_implementation_to_gate_wait(task, evidence)
  records = Array(evidence["records"]).select { |record| record.is_a?(Hash) }
  implementation = records.select { |record| record["kind"] == "implementation" && record["status"] == "pass" }
                          .map { |record| runtime_time(record["created_at"]) }.compact.max
  return nil unless implementation
  gate_times = required_evidence_kinds(task).reject { |kind| kind == "implementation" }.map do |kind|
    records.select { |record| record["kind"] == kind && record["status"] == "pass" }
           .map { |record| runtime_time(record["created_at"]) }.compact.max
  end
  return nil if gate_times.empty? || gate_times.any?(&:nil?)

  [(gate_times.max - implementation).round, 0].max
end

def capture_trial_metrics(options)
  task_path = File.expand_path(options["task"])
  evidence_path = File.expand_path(options["evidence"])
  task = load_yaml(task_path)
  evidence = load_yaml(evidence_path)
  usage_error("metrics capture task must be orbit-task-v1.") unless task.is_a?(Hash) && task["schema_version"] == "orbit-task-v1"
  usage_error("metrics capture evidence must be orbit-evidence-v1.") unless evidence.is_a?(Hash) && evidence["schema_version"] == "orbit-evidence-v1"
  dimensions = {
    "stage" => options["stage"],
    "task_type" => task["task_type"],
    "risk_level" => task.dig("task_risk", "level"),
    "duration_seconds" => options["duration_seconds"],
    "tokens" => options["tokens"],
    "implementation_to_gate_seconds" => trial_implementation_to_gate_wait(task, evidence)
  }.merge(trial_artifact_snapshot(evidence))
  event = trial_metric_event("task_snapshot", task: task_path, dimensions: dimensions)
  append_trial_metric_event(options["file"], event)
end

def record_trial_metric(options)
  metric = options["metric"]
  dimensions = case metric
               when "workflow_failure"
                 usage_error("workflow_failure requires --failure-kind identity|schema|revision.") unless %w[identity schema revision].include?(options["failure_kind"])
                 { "failure_kind" => options["failure_kind"] }
               when "independent_defect"
                 usage_error("independent_defect requires --source reviewer|tester.") unless %w[reviewer tester].include?(options["source"])
                 usage_error("independent_defect requires --severity high|medium|low.") unless %w[high medium low].include?(options["severity"])
                 { "source" => options["source"], "severity" => options["severity"] }
               when "post_gate_defect"
                 usage_error("post_gate_defect requires --severity P0|P1|P2.") unless %w[P0 P1 P2].include?(options["severity"])
                 { "severity" => options["severity"] }
               when "status_question"
                 usage_error("status_question requires --topic status|next|who.") unless %w[status next who].include?(options["topic"])
                 { "topic" => options["topic"] }
               when "automatic_session"
                 usage_error("automatic_session requires --outcome verified|pending|manual.") unless %w[verified pending manual].include?(options["outcome"])
                 { "outcome" => options["outcome"] }
               end
  event = trial_metric_event(metric, task: options["task"] && File.expand_path(options["task"]), dimensions: dimensions)
  append_trial_metric_event(options["file"], event)
end

def load_trial_metric_events(path, start_time)
  expanded = File.expand_path(path)
  return [] unless File.file?(expanded)
  File.readlines(expanded).each_with_index.each_with_object([]) do |(line, index), events|
    next if line.strip.empty?
    event = JSON.parse(line)
    usage_error("metrics event line #{index + 1} has unsupported schema.") unless event["schema_version"] == TRIAL_METRIC_EVENT_SCHEMA
    created_at = runtime_time(event["created_at"])
    usage_error("metrics event line #{index + 1} has invalid created_at.") unless created_at
    events << event if created_at >= start_time
  end
rescue JSON::ParserError => e
  usage_error("metrics event file is invalid JSONL: #{e.message}")
end

def trial_group_counts(events, metric, field)
  events.select { |event| event["metric"] == metric }
        .each_with_object(Hash.new(0)) { |event, counts| counts[event.dig("dimensions", field).to_s] += 1 }
        .reject { |key, _value| key.empty? }
end

def trial_median(values)
  sorted = values.compact.sort
  return nil if sorted.empty?
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2.0)
end

def trial_metrics_report(options)
  now = Time.now.utc
  start_time = now - options["window_days"] * 86_400
  events = load_trial_metric_events(options["file"], start_time)
  snapshots = events.select { |event| event["metric"] == "task_snapshot" }
  durations = snapshots.map { |event| event.dig("dimensions", "duration_seconds") }.compact
  tokens = snapshots.map { |event| event.dig("dimensions", "tokens") }.compact
  waits = snapshots.map { |event| event.dig("dimensions", "implementation_to_gate_seconds") }.compact
  artifact_counts = snapshots.map { |event| event.dig("dimensions", "artifact_count") }.compact
  artifact_bytes = snapshots.map { |event| event.dig("dimensions", "artifact_bytes") }.compact
  automatic = trial_group_counts(events, "automatic_session", "outcome")
  automatic_total = automatic.values.sum
  verified = automatic.fetch("verified", 0)
  metrics = {
    "task_cost" => {
      "samples" => snapshots.length,
      "duration_seconds_total" => durations.sum,
      "duration_seconds_median" => trial_median(durations),
      "tokens_total" => tokens.sum,
      "tokens_median" => trial_median(tokens),
      "by_task_type" => trial_group_counts(snapshots, "task_snapshot", "task_type"),
      "by_risk_level" => trial_group_counts(snapshots, "task_snapshot", "risk_level")
    },
    "artifact_footprint" => {
      "samples" => artifact_counts.length,
      "count_total" => artifact_counts.sum,
      "bytes_total" => artifact_bytes.sum,
      "count_median" => trial_median(artifact_counts),
      "bytes_median" => trial_median(artifact_bytes)
    },
    "implementation_to_gate_wait" => { "samples" => waits.length, "median_seconds" => trial_median(waits) },
    "workflow_failures" => trial_group_counts(events, "workflow_failure", "failure_kind"),
    "independent_defects" => {
      "total" => events.count { |event| event["metric"] == "independent_defect" },
      "by_source" => trial_group_counts(events, "independent_defect", "source"),
      "by_severity" => trial_group_counts(events, "independent_defect", "severity")
    },
    "post_gate_user_defects" => trial_group_counts(events, "post_gate_defect", "severity"),
    "status_questions" => trial_group_counts(events, "status_question", "topic"),
    "automatic_verified_ratio" => {
      "verified" => verified,
      "total" => automatic_total,
      "ratio" => automatic_total.positive? ? (verified.to_f / automatic_total).round(4) : nil,
      "outcomes" => automatic
    }
  }
  coverage = {
    "task_cost" => snapshots.empty? ? "missing" : "observed",
    "artifact_footprint" => artifact_counts.empty? ? "missing" : "observed",
    "implementation_to_gate_wait" => waits.empty? ? "missing" : "observed",
    "workflow_failures" => metrics["workflow_failures"].empty? ? "missing" : "observed",
    "independent_defects" => metrics.dig("independent_defects", "total").zero? ? "missing" : "observed",
    "post_gate_user_defects" => metrics["post_gate_user_defects"].empty? ? "missing" : "observed",
    "status_questions" => metrics["status_questions"].empty? ? "missing" : "observed",
    "automatic_verified_ratio" => automatic_total.zero? ? "missing" : "observed"
  }
  {
    "schema_version" => TRIAL_METRICS_REPORT_SCHEMA,
    "project" => File.basename(Dir.pwd),
    "window" => { "days" => options["window_days"], "start_at" => start_time.iso8601, "end_at" => now.iso8601 },
    "privacy" => { "prompt_content_stored" => false, "free_text_stored" => false, "dimensions_only" => true },
    "metrics" => metrics,
    "coverage" => coverage,
    "observation_status" => coverage.values.all? { |state| state == "observed" } ? "ready_for_trial_decision" : "collect_more_data",
    "event_count" => events.length,
    "events_file" => project_relative_persisted_path(options["file"], field: "metrics file", strict: true)
  }
end

def trial_metrics(args)
  options = parse_trial_metrics_args(args)
  result = case options["subcommand"]
           when "capture" then capture_trial_metrics(options)
           when "record" then record_trial_metric(options)
           when "report" then trial_metrics_report(options)
           end
  puts JSON.pretty_generate(result)
end
