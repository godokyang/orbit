# frozen_string_literal: true

def parse_audit_args(args)
  options = {
    "json" => false
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--state"
      options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/
      options["state"] = Regexp.last_match(1)
    when "--evidence"
      options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      options["evidence"] = Regexp.last_match(1)
    when "--handoff"
      options["handoff"] = option_value(args, "--handoff")
    when /\A--handoff=(.+)\z/
      options["handoff"] = Regexp.last_match(1)
    when "--compact-summary"
      options["compact_summary"] = option_value(args, "--compact-summary")
    when /\A--compact-summary=(.+)\z/
      options["compact_summary"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown audit option: #{arg}")
    end
  end

  %w[task state evidence].each do |name|
    usage_error("Missing required option: --#{name}") if options[name].nil? || options[name].empty?
  end
  usage_error("audit currently requires --json") unless options["json"]

  options
end

def orbit_dir_size_kb
  orbit_dir = File.join(Dir.pwd, ".orbit")
  return nil unless File.directory?(orbit_dir)

  total = 0
  Dir.glob(File.join(orbit_dir, "**", "*")).each do |f|
    total += File.size(f) if File.file?(f)
  end
  (total / 1024.0).ceil
rescue
  nil
end

def add_compact_summary_hash_error(result, source, message)
  result["errors"] << { "source" => "compact_summary.compact_summary.#{source}", "message" => message }
end

def validate_compact_summary_hash(result, cs, key, expected_path)
  actual = sha256_file(expected_path)
  return unless actual.is_a?(String)
  return if cs[key] == actual

  add_compact_summary_hash_error(
    result,
    key,
    "compact_summary.#{key} must match the current #{key.sub("_sha256", "")} file SHA256."
  )
end

def validate_compact_summary_schema(path, task_path: nil, evidence_path: nil, handoff_path: nil)
  result = { "errors" => [], "warnings" => [] }
  return result unless path

  unless File.file?(path)
    result["errors"] << { "source" => "compact_summary", "message" => "compact summary file not found: #{path}" }
    return result
  end

  begin
    summary = load_yaml(path)
  rescue RuntimeError => e
    result["errors"] << { "source" => "compact_summary", "message" => "compact summary could not be parsed: #{e.message}" }
    return result
  end

  unless summary.is_a?(Hash)
    result["errors"] << { "source" => "compact_summary", "message" => "compact summary must be a mapping." }
    return result
  end

  unless summary["schema_version"].to_s.start_with?("orbit-durable-evidence-summary")
    result["errors"] << { "source" => "compact_summary.schema_version", "message" => "compact summary schema_version must start with 'orbit-durable-evidence-summary'." }
  end

  cs = summary["compact_summary"]
  unless cs.is_a?(Hash)
    result["errors"] << { "source" => "compact_summary.compact_summary", "message" => "compact summary must contain a compact_summary block." }
    return result
  end

  hex64 = /\A[0-9a-f]{64}\z/

  unless cs["task_sha256"].is_a?(String) && cs["task_sha256"].match?(hex64)
    result["errors"] << { "source" => "compact_summary.compact_summary.task_sha256", "message" => "compact_summary.task_sha256 must be a 64-char lowercase hex string." }
  end

  unless cs["evidence_sha256"].is_a?(String) && cs["evidence_sha256"].match?(hex64)
    result["errors"] << { "source" => "compact_summary.compact_summary.evidence_sha256", "message" => "compact_summary.evidence_sha256 must be a 64-char lowercase hex string." }
  end

  require_handoff_sha256 = !handoff_path.nil? || cs.key?("handoff_sha256")
  if require_handoff_sha256 && !(cs["handoff_sha256"].is_a?(String) && cs["handoff_sha256"].match?(hex64))
    add_compact_summary_hash_error(result, "handoff_sha256", "compact_summary.handoff_sha256 must be a 64-char lowercase hex string.")
  end

  validate_compact_summary_hash(result, cs, "task_sha256", task_path) if cs["task_sha256"].is_a?(String) && cs["task_sha256"].match?(hex64)
  validate_compact_summary_hash(result, cs, "evidence_sha256", evidence_path) if cs["evidence_sha256"].is_a?(String) && cs["evidence_sha256"].match?(hex64)
  validate_compact_summary_hash(result, cs, "handoff_sha256", handoff_path) if cs["handoff_sha256"].is_a?(String) && cs["handoff_sha256"].match?(hex64)

  result
end

def retention_drift_summary(evidence, handoff_path)
  return nil unless handoff_path && File.file?(handoff_path)

  handoff = load_yaml(handoff_path)
  return nil unless handoff.is_a?(Hash)

  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  latest_by_kind = latest_records_by_kind(records)
  evidence_verdicts = %w[review test].each_with_object({}) do |kind, memo|
    latest = latest_by_kind[kind]
    memo[kind] = latest ? latest["status"] : "missing"
  end

  handoff_verdicts = handoff["latest_gate_verdicts"].is_a?(Hash) ? handoff["latest_gate_verdicts"] : {}
  drift = %w[review test].each_with_object({}) do |kind, memo|
    ev_status = evidence_verdicts[kind]
    ho_status = handoff_verdicts.dig(kind, "status") || "missing"
    memo[kind] = { "evidence" => ev_status, "handoff" => ho_status, "match" => ev_status == ho_status }
  end

  {
    "handoff_path" => handoff_path,
    "has_drift" => drift.values.any? { |d| !d["match"] },
    "gate_verdict_drift" => drift
  }
end

def runtime_reconcile_summary(evidence)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []

  bindings_list = records.select { |r| r.is_a?(Hash) && r["runtime_binding"].is_a?(Hash) }
                         .map { |r| r["runtime_binding"] }

  # Stale artifact paths (from runtime_binding.build.artifact_paths)
  all_paths = bindings_list.flat_map { |b|
    b["build"].is_a?(Hash) && b["build"]["artifact_paths"].is_a?(Array) ? b["build"]["artifact_paths"] : []
  }.uniq
  stale = all_paths.select { |p| !File.exist?(p) }

  # Model drift
  model_identities = bindings_list.map { |b| b["model_service"] }.compact.uniq
  model_drift = model_identities.size > 1

  # Build drift (git_head + artifact_hash together as identity)
  build_identities = bindings_list.map { |b| b["build"] }.compact.uniq
  build_drift = build_identities.size > 1

  # Blocker classification: top-level field + findings.failure_class
  blocker_classes = {}
  records.each do |r|
    next unless r.is_a?(Hash)
    bc = r["blocker_classification"]
    if bc.is_a?(Hash) && bc["kind"].is_a?(String)
      fc = bc["kind"]
      blocker_classes[fc] = (blocker_classes[fc] || 0) + 1
    end
    if r["findings"].is_a?(Array)
      r["findings"].each do |f|
        next unless f.is_a?(Hash) && f["failure_class"].is_a?(String)
        fc = f["failure_class"]
        blocker_classes[fc] = (blocker_classes[fc] || 0) + 1
      end
    end
  end

  {
    "stale_artifact_paths" => stale,
    "model_identities" => model_identities,
    "model_drift_detected" => model_drift,
    "build_identities" => build_identities,
    "build_drift_detected" => build_drift,
    "blocker_classes" => blocker_classes,
    "has_issues" => !stale.empty? || model_drift || build_drift
  }
end

def orbit_retention_summary(evidence, compact_summary_path)
  size_kb = orbit_dir_size_kb
  records_count = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"].length : 0
  compact_present = !!(compact_summary_path && File.file?(compact_summary_path))

  recommendations = []
  if size_kb && size_kb > 1024
    recommendations << {
      "code" => "orbit_dir_large",
      "message" => ".orbit is #{size_kb}KB; run compact-evidence to preserve a durable summary before archiving transient artifacts."
    }
  end
  unless compact_present
    if records_count > 20
      recommendations << {
        "code" => "compact_summary_missing",
        "message" => "#{records_count} evidence records without a compact summary; run compact-evidence to create one."
      }
    end
  end

  {
    "orbit_dir_size_kb" => size_kb,
    "evidence_records_count" => records_count,
    "compact_summary_present" => compact_present,
    "recommendations" => recommendations,
    "recommendations_count" => recommendations.length
  }.compact
end

def audit_validation_result(task_path, evidence_path, state_path)
  result = {
    "schema_version" => "orbit-validate-v1",
    "project" => File.basename(Dir.pwd),
    "checked" => [],
    "valid" => false,
    "errors" => [],
    "warnings" => []
  }

  validate_project_config(result)
  result["checked"] << "project_config"
  task = validate_task(result, task_path)
  result["checked"] << "task"
  evidence = validate_evidence(result, evidence_path, task, task_sha256: sha256_file(task_path))
  result["checked"] << "evidence"
  state = validate_state_file(result, state_path)
  result["checked"] << "state"
  result["valid"] = result["errors"].empty?

  [result, task, evidence, state]
end

def audit_remediation(source)
  case source
  when /\Astate_file\.current_task/
    "重新执行 `orbit state start --task ...` 或修正 loop state，让 current_task 指向本次审计的 task。"
  when /\Astate_file\.artifacts\.evidence_file/
    "重新执行 `orbit state transition --to done --evidence ...`，或修正 loop state 的 evidence_file 指向本次审计的 evidence。"
  when /\Astate_file\.artifacts\.handoff_packet/
    "运行 `orbit handoff --task ... --state ... --evidence ... --json` 并在发布前记录 handoff artifact。"
  when /\Aevidence_file/
    "补充或修正 evidence manifest，确保至少有一个可支持当前 gate 的 pass evidence。"
  when /\Atask_file/
    "修正 task contract 的必填字段后重新运行 validate/audit。"
  when /\Aproject_config/
    "修正 .orbit 项目配置后重新运行 validate/audit。"
  else
    "补齐对应协议文件或重新运行相关 Orbit 命令后再审计。"
  end
end

def quality_outcome_summary(task, evidence)
  return nil unless task.is_a?(Hash)

  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  required_kinds = required_evidence_kinds(task)

  gate_verdicts = required_kinds.each_with_object({}) do |kind, memo|
    evidence_kind = GATE_KIND_EVIDENCE_RECORD_KIND[kind] || kind
    # quality_outcome_verdict is only meaningful for review evidence (review / design_readiness gates).
    # test and release gates use test evidence which has no quality_outcome_verdict; mark them not_applicable.
    unless evidence_kind == "review"
      memo[kind] = { "satisfied" => "not_applicable" }
      next
    end
    candidates = records.select { |r| r.is_a?(Hash) && r["kind"] == evidence_kind && r["structured_submit"] == true }
    latest = candidates.last
    qov = latest&.fetch("quality_outcome_verdict", nil)
    memo[kind] = { "quality_outcome_verdict" => qov, "satisfied" => qov == "pass" }.compact
  end

  # all_satisfied only considers gates that have a quality_outcome_verdict (review-evidence gates).
  review_gates = gate_verdicts.reject { |_k, v| v["satisfied"] == "not_applicable" }

  guards = task["invalid_completion_guards"]
  guard_summary = if guards.is_a?(Array) && !guards.empty?
                    review_record = records.select { |r| r.is_a?(Hash) && r["kind"] == "review" && r["structured_submit"] == true }.last
                    counterexamples_pass = review_record&.fetch("quality_question_answers", nil)&.any? do |a|
                      a.is_a?(Hash) && a["id"] == "counterexamples" && a["verdict"] == "pass"
                    end

                    guards.map { |g|
                      next unless g.is_a?(Hash)

                      guard_id = g["id"]
                      specific = review_record&.fetch("quality_question_answers", nil)&.find do |a|
                        a.is_a?(Hash) && a["id"] == guard_id
                      end
                      if specific
                        specific_pass = specific["verdict"] == "pass"
                        {
                          "id" => guard_id,
                          "description" => g["description"],
                          "addressed" => specific_pass,
                          "coverage" => "guard_specific",
                          "addressed_via" => specific_pass ? "guard-specific answer verdict: pass" : "guard-specific answer verdict: #{specific["verdict"]}"
                        }
                      else
                        # No guard-specific answer: report general counterexamples coverage but mark addressed=false
                        # so it cannot be treated as explicit per-guard closure.
                        {
                          "id" => guard_id,
                          "description" => g["description"],
                          "addressed" => false,
                          "coverage" => counterexamples_pass ? "general_only" : "none",
                          "addressed_via" => counterexamples_pass ? "general counterexamples verdict: pass (no guard-specific answer; add quality_question_answers entry with id: #{guard_id} to explicitly close)" : "counterexamples question not passed in latest review"
                        }
                      end
                    }.compact
                  end

  result = {
    "gate_quality_outcomes" => gate_verdicts,
    "all_satisfied" => review_gates.values.all? { |v| v["satisfied"] == true }
  }
  result["invalid_completion_guards"] = guard_summary if guard_summary
  result
end

def audit_finding(source, message, severity = "high", remediation = nil)
  {
    "source" => source,
    "message" => message,
    "severity" => severity,
    "summary" => message,
    "remediation" => remediation || audit_remediation(source)
  }
end

def audit_trust_level
  {
    "mode" => "audit_only",
    "meaning" => "Orbit reports whether files are consistent and evidence-backed; it does not prevent users from editing files.",
    "known_bypasses" => [
      "Users or agents with filesystem access can manually edit task, evidence, or loop state files.",
      "Audit can report drift, but local files remain the source being inspected."
    ],
    "required_before_done" => [
      "orbit validate passes for project config, task, evidence, and state.",
      "Loop state points at the audited task and evidence files.",
      "Evidence contains a pass signal for done state."
    ]
  }
end

def write_policy_audit(evidence, task)
  return nil unless evidence.is_a?(Hash)

  records = evidence["records"].is_a?(Array) ? evidence["records"] : []
  enforcement = task.is_a?(Hash) ? (task["write_policy_enforcement"] || "standard").to_s : "standard"
  gate_role_writes = {}
  legacy_count = 0

  records.each do |record|
    next unless record.is_a?(Hash)

    kind = record["kind"]
    next unless EVIDENCE_EXPECTED_GATE_ROLES.key?(kind)

    if record["structured_submit"] == true && record_task_sha256_from(record).nil?
      legacy_count += 1
    end

    wp = record["write_policy"]
    next unless wp.is_a?(Hash)

    role = record_resolved_role(record) || kind
    gate_role_writes[role] ||= { "changed_files" => [], "violations" => [] }
    if wp["changed_files"].is_a?(Array)
      gate_role_writes[role]["changed_files"].concat(wp["changed_files"].select { |f| f.is_a?(String) })
    end
    if wp["violations"].is_a?(Array)
      gate_role_writes[role]["violations"].concat(wp["violations"].select { |v| v.is_a?(String) })
    end
  end

  total_violations = gate_role_writes.values.sum { |v| v["violations"].length }

  {
    "enforcement" => enforcement,
    "gate_role_writes" => gate_role_writes,
    "legacy_records_without_hash" => legacy_count,
    "has_violations" => total_violations > 0,
    "total_violations" => total_violations
  }
end

def stale_records_audit(evidence, task_sha256)
  return nil unless evidence.is_a?(Hash) && task_sha256

  records = evidence["records"].is_a?(Array) ? evidence["records"] : []
  stale = []
  records.each_with_index do |record, idx|
    next unless record.is_a?(Hash) && record["structured_submit"] == true

    stored = record_task_sha256_from(record)
    next unless stored && stored != task_sha256

    stale << {
      "index" => idx,
      "kind" => record["kind"],
      "created_at" => record["created_at"],
      "stored_task_sha256" => stored
    }.compact
  end
  {
    "task_sha256" => task_sha256,
    "stale_count" => stale.length,
    "stale_records" => stale
  }
end

def parent_goal_audit(task, evidence)
  return nil unless task.is_a?(Hash)

  parent_goal = task["parent_goal"]
  unless parent_goal.is_a?(Hash) && parent_goal["required"] == true
    return { "state" => "not_applicable", "message" => "Task does not require parent goal tracking." }
  end

  status = task["parent_goal_status"]
  current_state = status.is_a?(Hash) ? status["state"] : nil
  done_criteria = parent_goal["done_criteria"].is_a?(Array) ? parent_goal["done_criteria"] : []
  criteria_status = status.is_a?(Hash) && status["done_criteria_status"].is_a?(Array) ? status["done_criteria_status"] : []

  evidenced_criteria = criteria_status.select { |cs| cs.is_a?(Hash) && cs["evidenced"] == true }.map { |cs| cs["criterion"] }
  unevidenced = done_criteria.reject { |c| evidenced_criteria.include?(c) }

  blocking = []
  if current_state == "parent_done" && !unevidenced.empty?
    blocking << {
      "source" => "parent_goal_status.done_criteria",
      "message" => "parent_goal_status.state is parent_done but #{unevidenced.length} done criteria lack evidence.",
      "unevidenced" => unevidenced
    }
  end

  {
    "required" => true,
    "objective" => parent_goal["objective"],
    "current_state" => current_state,
    "done_criteria_count" => done_criteria.length,
    "evidenced_count" => evidenced_criteria.length,
    "unevidenced_criteria" => unevidenced,
    "blocking" => blocking,
    "user_next_action" => status.is_a?(Hash) ? status["user_next_action"] : nil
  }.compact
end

def audit_state_consistency(task_path, evidence_path, state, evidence, task = nil, task_sha256: nil)
  blocking_findings = []
  warnings = []
  phase = state.is_a?(Hash) ? state["phase"] : nil

  if state.is_a?(Hash)
    current_task = state["current_task"]
    if current_task.nil? || current_task.empty?
      blocking_findings << audit_finding("state_file.current_task", "Loop state must reference the audited task.")
    elsif File.expand_path(current_task) != task_path
      blocking_findings << audit_finding("state_file.current_task", "Loop state current_task does not match audited task.")
    end

    artifacts = state["artifacts"]
    evidence_ref = artifacts.is_a?(Hash) ? artifacts["evidence_file"] : nil
    if evidence_ref.nil? || evidence_ref.empty?
      finding = audit_finding("state_file.artifacts.evidence_file", "Loop state does not reference the audited evidence file.")
      if phase == "done"
        blocking_findings << finding
      else
        warnings << audit_finding(
          "state_file.artifacts.evidence_file",
          "Loop state does not reference the audited evidence file.",
          "medium"
        )
      end
    elsif File.expand_path(evidence_ref) != evidence_path
      blocking_findings << audit_finding("state_file.artifacts.evidence_file", "Loop state evidence_file does not match audited evidence.")
    end

    handoff_ref = artifacts.is_a?(Hash) ? artifacts["handoff_packet"] : nil
    if phase == "done" && (handoff_ref.nil? || handoff_ref.empty?)
      warnings << audit_finding(
        "state_file.artifacts.handoff_packet",
        "Done state does not reference a handoff packet; release trust remains incomplete.",
        "medium"
      )
    end
  end

  if phase == "done" && !evidence_has_done_signal?(evidence)
    blocking_findings << audit_finding("evidence_file", "Done state requires at least one pass evidence signal.")
  end

  if phase == "done" && task.is_a?(Hash)
    records = evidence.is_a?(Hash) ? evidence["records"] : []
    required_evidence_kinds(task).each do |kind|
      next if gate_passed?(records, kind, task_sha256: task_sha256)

      blocking_findings << audit_finding(
        "evidence_file.records.#{kind}",
        "Done state requires latest #{kind} gate evidence to be pass.",
        "high",
        "让 #{kind == "review" ? "reviewer" : "tester"} 提交 pass evidence，或显式记录 waiver/residual risk 后重新审计。"
      )
    end
  end

  [blocking_findings, warnings]
end

def audit_trust_flags(phase, blocking_findings, warnings)
  trusted_for_handoff = blocking_findings.empty?
  trusted_for_done = phase == "done" && trusted_for_handoff
  trusted_for_release = trusted_for_done && warnings.empty?
  {
    "trusted_for_handoff" => trusted_for_handoff,
    "trusted_for_done" => trusted_for_done,
    "trusted_for_release" => trusted_for_release
  }
end

def audit(args)
  options = parse_audit_args(args)
  task_path = File.expand_path(options["task"])
  evidence_path = File.expand_path(options["evidence"])
  state_path = File.expand_path(options["state"])
  current_task_sha256 = sha256_file(task_path)
  validation, task, evidence, state = audit_validation_result(task_path, evidence_path, state_path)
  blocking_findings = validation["errors"].map { |error| audit_finding(error["source"], error["message"], "high") }
  warnings = validation["warnings"].map { |warning| audit_finding(warning["source"], warning["message"], "medium") }
  state_blocking, state_warnings = audit_state_consistency(task_path, evidence_path, state, evidence, task, task_sha256: current_task_sha256)
  blocking_findings.concat(state_blocking)
  warnings.concat(state_warnings)

  phase = state.is_a?(Hash) ? state["phase"] : nil
  trust_flags = audit_trust_flags(phase, blocking_findings, warnings)
  issues = blocking_findings + warnings

  schema_summary = evidence_schema_version_summary(evidence, task)
  if schema_summary
    # Prose/structured conflicts are blocking: structured verdict wins per global compatibility policy.
    schema_summary["prose_conflicts"].each do |conflict|
      blocking_findings << audit_finding(
        conflict["source"] || "evidence_file.records",
        conflict["message"],
        "high",
        "Correct the report so the summary derives from the structured verdict field. Structured verdict takes precedence."
      )
    end
    # Unknown future versions are blocking: do not silently treat as current semantics.
    schema_summary["unknown_versions"].each do |uv|
      blocking_findings << audit_finding(
        uv["source"],
        uv["message"],
        "high",
        uv["action"]
      )
    end
    # Re-derive issues list with any newly added blocking_findings.
    issues = blocking_findings + warnings
  end

  trust_flags = audit_trust_flags(phase, blocking_findings, warnings)

  # Merge parent_goal_summary.blocking into blocking_findings BEFORE building packet
  # so that issues and trust_flags reflect parent_done violations consistently
  pg_summary = parent_goal_audit(task, evidence)
  if pg_summary.is_a?(Hash) && pg_summary["blocking"].is_a?(Array)
    pg_summary["blocking"].each { |b| blocking_findings << b unless blocking_findings.include?(b) }
  end
  # Compact summary schema validation (optional --compact-summary)
  compact_summary_path = options["compact_summary"] ? File.expand_path(options["compact_summary"]) : nil
  # Handoff drift detection (optional --handoff)
  handoff_path = options["handoff"] ? File.expand_path(options["handoff"]) : nil
  if compact_summary_path
    cs_validation = validate_compact_summary_schema(
      compact_summary_path,
      task_path: task_path,
      evidence_path: evidence_path,
      handoff_path: handoff_path
    )
    cs_validation["errors"].each { |e| blocking_findings << audit_finding(e["source"], e["message"], "high") }
    cs_validation["warnings"].each { |w| warnings << audit_finding(w["source"], w["message"], "medium") }
  end

  drift_summary = retention_drift_summary(evidence, handoff_path)
  if drift_summary && drift_summary["has_drift"]
    warnings << audit_finding(
      "retention.handoff_drift",
      "Handoff latest_gate_verdicts differs from current evidence manifest latest records; handoff may need to be regenerated.",
      "medium"
    )
  end

  reconcile = runtime_reconcile_summary(evidence)
  unless reconcile["stale_artifact_paths"].empty?
    warnings << audit_finding(
      "runtime.stale_artifacts",
      "Evidence records reference #{reconcile["stale_artifact_paths"].size} artifact path(s) that no longer exist on disk.",
      "medium"
    )
  end
  if reconcile["model_drift_detected"]
    warnings << audit_finding(
      "runtime.model_drift",
      "Evidence records reference #{reconcile["model_identities"].size} distinct model identities; model may have changed during work.",
      "medium"
    )
  end
  if reconcile["build_drift_detected"]
    warnings << audit_finding(
      "runtime.build_drift",
      "Evidence records reference #{reconcile["build_identities"].size} distinct build identities; build may have changed during work.",
      "medium"
    )
  end

  # Slice 12: data classification audit findings.
  dc_findings = data_classification_audit(evidence)
  dc_findings.each do |finding|
    if finding["severity"] == "high"
      blocking_findings << audit_finding(finding["source"], finding["message"], "high")
    else
      warnings << audit_finding(finding["source"], finding["message"], finding["severity"] || "medium")
    end
  end

  # Slice 13: release readiness blockers are blocking findings (separate from implementation blockers).
  if release_risk?(task)
    release_readiness_blockers(task["release_readiness"]).each do |blocker|
      blocking_findings << audit_finding(blocker["source"], blocker["message"], "high")
    end
  end

  issues = blocking_findings + warnings
  trust_flags = audit_trust_flags(phase, blocking_findings, warnings)

  packet = {
    "schema_version" => "orbit-audit-v1",
    "project" => task.is_a?(Hash) && task["project"] ? task["project"] : File.basename(Dir.pwd),
    "inputs" => {
      "task" => task_path,
      "evidence" => evidence_path,
      "state" => state_path
    },
    "trust_level" => audit_trust_level,
    "validation" => validation,
    "state_phase" => phase,
    "trusted_for_handoff" => trust_flags["trusted_for_handoff"],
    "trusted_for_done" => trust_flags["trusted_for_done"],
    "trusted_for_release" => trust_flags["trusted_for_release"],
    "done_ready" => trust_flags["trusted_for_done"],
    "evidence_summary" => evidence_summary(evidence),
    "quality_outcome_summary" => quality_outcome_summary(task, evidence),
    "parent_goal_summary" => pg_summary,
    "write_policy_summary" => write_policy_audit(evidence, task),
    "stale_records_summary" => stale_records_audit(evidence, current_task_sha256),
    "worktree_safety_summary" => worktree_safety_summary(evidence),
    "destructive_action_summary" => destructive_action_audit(evidence),
    "rule_resolution_summary" => rule_resolution_summary(evidence, evidence_path),
    "schema_version_summary" => schema_summary,
    "retention_summary" => orbit_retention_summary(evidence, compact_summary_path),
    "retention_drift_summary" => drift_summary,
    "runtime_reconcile_summary" => reconcile,
    "verdict_arbitration_summary" => verdict_arbitration_summary(task, evidence, current_task_sha256),
    "gate_lease_summary" => gate_lease_summary(evidence),
    "decision_record_summary" => decision_record_summary(evidence),
    "task_risk_summary" => task_risk_summary(task),
    "data_classification_summary" => data_classification_summary(evidence),
    "trust_repair_summary" => trust_repair_summary(evidence),
    "release_readiness_summary" => release_readiness_summary(task),
    "release_blockers" => release_risk?(task) ? release_readiness_blockers(task["release_readiness"]) : [],
    "issues" => issues,
    "blocking_findings" => blocking_findings,
    "warnings" => warnings
  }

  puts JSON.pretty_generate(packet)
  exit(blocking_findings.empty? ? 0 : 1)
end

def parse_tools_args(args)
  subcommand = args.shift
  usage_error("Missing tools subcommand.") unless subcommand

  options = {
    "subcommand" => subcommand,
    "json" => false
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown tools #{subcommand} option: #{arg}")
    end
  end

  case subcommand
  when "detect", "doctor"
    usage_error("tools #{subcommand} currently requires --json") unless options["json"]
  else
    usage_error("Unknown tools subcommand: #{subcommand}")
  end

  options
end

def command_path(command)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    next if dir.empty?

    candidate = File.join(dir, command)
    return candidate if File.file?(candidate) && File.executable?(candidate)
  end

  nil
end

def ci_environment
  {
    "CI" => ENV["CI"],
    "GITHUB_ACTIONS" => ENV["GITHUB_ACTIONS"],
    "GITLAB_CI" => ENV["GITLAB_CI"],
    "BUILDKITE" => ENV["BUILDKITE"],
    "CIRCLECI" => ENV["CIRCLECI"],
    "JENKINS_URL" => ENV["JENKINS_URL"]
  }.select { |_name, value| value && !value.empty? }
end

def detected_tool(name, available, capabilities, reason = nil, metadata = {})
  tool = {
    "name" => name,
    "available" => available,
    "capabilities" => available ? capabilities : []
  }
  tool["reason"] = reason if reason
  metadata.each { |key, value| tool[key] = value unless value.nil? }
  tool
end

def detect_tools
  shell = ENV["SHELL"]
  shell_path = shell && !shell.empty? && File.executable?(shell) ? shell : nil
  shell_path ||= "/bin/sh" if File.executable?("/bin/sh")
  herdr_path = command_path("herdr")
  tmux_path = command_path("tmux")
  git_path = command_path("git")
  ci_env = ci_environment

  [
    detected_tool(
      "local_shell",
      !shell_path.nil?,
      %w[command.run file.read file.write],
      shell_path ? nil : "no executable shell found",
      "path" => shell_path
    ),
    detected_tool(
      "herdr",
      !herdr_path.nil?,
      %w[agent.start pane.message pane.capture review.request],
      herdr_path ? nil : "command not found",
      "path" => herdr_path
    ),
    detected_tool(
      "tmux",
      !tmux_path.nil?,
      %w[pane.message pane.capture session.manage],
      tmux_path ? nil : "command not found",
      "path" => tmux_path
    ),
    detected_tool(
      "ci",
      !ci_env.empty?,
      %w[command.run gate.report artifact.collect],
      ci_env.empty? ? "CI environment variables not set" : nil,
      "env" => ci_env.keys
    ),
    detected_tool(
      "git",
      !git_path.nil?,
      %w[status.read diff.inspect commit.read],
      git_path ? nil : "command not found",
      "path" => git_path
    )
  ]
end

def tools_detect_packet
  {
    "schema_version" => "orbit-tools-v1",
    "project" => File.basename(Dir.pwd),
    "generated_at" => Time.now.utc.iso8601,
    "detected" => detect_tools
  }
end

def tools_doctor_packet
  detected = detect_tools
  by_name = detected.to_h { |tool| [tool["name"], tool] }
  findings = []

  unless by_name.fetch("local_shell")["available"]
    findings << {
      "severity" => "error",
      "source" => "tools.local_shell",
      "message" => "No executable shell was found; local command execution is unavailable."
    }
  end

  %w[herdr tmux ci].each do |name|
    next if by_name.fetch(name)["available"]

    findings << {
      "severity" => "warning",
      "source" => "tools.#{name}",
      "message" => "#{name} is unavailable; generic JSON/file handoff remains valid."
    }
  end

  unless by_name.fetch("git")["available"]
    findings << {
      "severity" => "warning",
      "source" => "tools.git",
      "message" => "git is unavailable; audit cannot rely on git status or diff evidence."
    }
  end

  health = if findings.any? { |finding| finding["severity"] == "error" }
             "fail"
           elsif findings.any? { |finding| finding["severity"] == "warning" }
             "warn"
           else
             "pass"
           end

  preferred_transport = if by_name.fetch("herdr")["available"]
                          "herdr"
                        elsif by_name.fetch("tmux")["available"]
                          "tmux"
                        else
                          "generic"
                        end

  {
    "schema_version" => "orbit-tools-doctor-v1",
    "project" => File.basename(Dir.pwd),
    "generated_at" => Time.now.utc.iso8601,
    "health" => health,
    "preferred_transport" => preferred_transport,
    "detected" => detected,
    "findings" => findings
  }
end

def tools(args)
  options = parse_tools_args(args)
  packet = case options["subcommand"]
           when "detect"
             tools_detect_packet
           when "doctor"
             tools_doctor_packet
           end

  puts JSON.pretty_generate(packet)
  if options["subcommand"] == "doctor" && packet["health"] == "fail"
    exit 1
  end
end
