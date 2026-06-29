# frozen_string_literal: true

# Slice 16: Landing governance and calibration.
#
# Provides compatibility policy enforcement, multi-user ownership summary,
# self-review guard for protocol changes, and backup/migration validation.

ALLOWED_COMPAT_MODES = %w[warn_legacy enforce_current opt_in_strict migration_period].freeze

# Default compatibility_policy skeleton.
def default_compatibility_policy
  {
    "mode" => "warn_legacy",
    "applies_to" => [],
    "breaking_change" => false,
    "migration_path" => ""
  }
end

# Default multi_user_ownership skeleton.
def default_multi_user_ownership
  {
    "file_owner" => "",
    "artifact_owner" => "",
    "pane_owner" => "",
    "evidence_access" => ""
  }
end

# Default self_review_guard skeleton.
def default_self_review_guard
  {
    "protocol_changed" => false,
    "independent_check_required" => true,
    "same_system_self_approval_allowed" => false
  }
end

# Default quality_calibration skeleton.
def default_quality_calibration
  {
    "sample_rate" => "",
    "metrics" => {
      "false_pass" => 0,
      "false_block" => 0,
      "user_corrections" => 0,
      "median_gate_wait" => ""
    }
  }
end

# Default backup_migration skeleton.
def default_backup_migration
  {
    "export_format" => "",
    "restore_check" => "",
    "evidence_index" => ""
  }
end

# Validate compatibility_policy structure when present on a task.
def validate_compatibility_policy(result, task)
  return unless task.key?("compatibility_policy")
  cp = task["compatibility_policy"]
  unless cp.is_a?(Hash)
    validation_error(result, "task_file.compatibility_policy", "compatibility_policy must be a mapping.")
    return
  end
  mode = cp["mode"]
  if mode && !(mode.is_a?(String) && ALLOWED_COMPAT_MODES.include?(mode))
    validation_error(result, "task_file.compatibility_policy.mode",
      "compatibility_policy.mode must be one of #{ALLOWED_COMPAT_MODES.join('|')}.")
  end
  applies_to = cp["applies_to"]
  if applies_to && !(applies_to.is_a?(Array) && applies_to.all? { |item| item.is_a?(String) && !item.strip.empty? })
    validation_error(result, "task_file.compatibility_policy.applies_to",
      "compatibility_policy.applies_to must be a list of non-empty strings when present.")
  end
  # Breaking change without migration_path is a gap.
  if cp["breaking_change"] == true
    migration = cp["migration_path"]
    unless migration.is_a?(String) && !migration.strip.empty?
      validation_error(result, "task_file.compatibility_policy.migration_path",
        "compatibility_policy.breaking_change is true but migration_path is missing; breaking changes require a migration path.")
    end
  end
end

# Validate multi_user_ownership when present so handoff can name owners.
def validate_multi_user_ownership(result, task)
  return unless task.key?("multi_user_ownership")
  muo = task["multi_user_ownership"]
  unless muo.is_a?(Hash)
    validation_error(result, "task_file.multi_user_ownership", "multi_user_ownership must be a mapping.")
    return
  end

  %w[file_owner artifact_owner pane_owner evidence_access].each do |field|
    value = muo[field]
    unless value.is_a?(String) && !value.strip.empty?
      validation_error(result, "task_file.multi_user_ownership.#{field}",
        "multi_user_ownership.#{field} must be a non-empty string.")
    end
  end
end

# Validate self_review_guard: protocol change under strict/release requires independent check or waiver.
def validate_self_review_guard(result, task)
  return unless task.key?("self_review_guard")
  guard = task["self_review_guard"]
  unless guard.is_a?(Hash)
    validation_error(result, "task_file.self_review_guard", "self_review_guard must be a mapping.")
    return
  end

  protocol_changed = guard["protocol_changed"] == true
  independent_required = guard["independent_check_required"] != false
  self_approval = guard["same_system_self_approval_allowed"] == true
  waiver = guard["waiver"]

  return unless protocol_changed

  risk_level = task.is_a?(Hash) ? task.dig("task_risk", "level") : nil
  is_strict = %w[strict release].include?(risk_level)

  if is_strict && independent_required && !self_approval
    unless waiver.is_a?(String) && !waiver.strip.empty?
      validation_error(result, "task_file.self_review_guard",
        "Protocol change under #{risk_level} risk requires independent_check or explicit waiver; self-review alone is blocked.")
    end
  end
end

# Validate backup_migration: restore_check required when export_format is present.
def validate_backup_migration(result, task)
  return unless task.key?("backup_migration")
  bm = task["backup_migration"]
  unless bm.is_a?(Hash)
    validation_error(result, "task_file.backup_migration", "backup_migration must be a mapping.")
    return
  end

  export_format = bm["export_format"]
  restore_check = bm["restore_check"]

  if export_format.is_a?(String) && !export_format.strip.empty?
    unless restore_check.is_a?(String) && !restore_check.strip.empty?
      validation_error(result, "task_file.backup_migration.restore_check",
        "backup_migration.export_format is set but restore_check is missing; backup requires a restore verification path.")
    end
  end
end

# Validate quality_calibration metrics when present.
def validate_quality_calibration(result, task)
  return unless task.key?("quality_calibration")
  qc = task["quality_calibration"]
  unless qc.is_a?(Hash)
    validation_error(result, "task_file.quality_calibration", "quality_calibration must be a mapping.")
    return
  end

  sample_rate = qc["sample_rate"]
  if sample_rate && !(sample_rate.is_a?(String) && !sample_rate.strip.empty?)
    validation_error(result, "task_file.quality_calibration.sample_rate",
      "quality_calibration.sample_rate must be a non-empty string when present.")
  end

  metrics = qc["metrics"]
  unless metrics.is_a?(Hash)
    validation_error(result, "task_file.quality_calibration.metrics",
      "quality_calibration.metrics must be a mapping.")
    return
  end

  %w[false_pass false_block user_corrections].each do |field|
    value = metrics[field]
    unless value.is_a?(Integer) && value >= 0
      validation_error(result, "task_file.quality_calibration.metrics.#{field}",
        "quality_calibration.metrics.#{field} must be a non-negative integer.")
    end
  end
  wait = metrics["median_gate_wait"]
  unless wait.is_a?(String)
    validation_error(result, "task_file.quality_calibration.metrics.median_gate_wait",
      "quality_calibration.metrics.median_gate_wait must be a string.")
  end
end

# Summarize compatibility_policy for audit output.
def compatibility_policy_summary(task)
  cp = task.is_a?(Hash) ? task["compatibility_policy"] : nil
  return nil unless cp
  {
    "mode" => cp["mode"],
    "breaking_change" => cp["breaking_change"],
    "applies_to" => cp["applies_to"],
    "migration_path" => cp["migration_path"],
    "has_legacy_gap" => cp["mode"] == "warn_legacy"
  }
end

# Summarize multi_user_ownership for handoff output.
def multi_user_ownership_summary(task)
  muo = task.is_a?(Hash) ? task["multi_user_ownership"] : nil
  return nil unless muo
  {
    "file_owner" => muo["file_owner"],
    "artifact_owner" => muo["artifact_owner"],
    "pane_owner" => muo["pane_owner"],
    "evidence_access" => muo["evidence_access"],
    "ownership_assumptions" => "Handoff assumes the receiving role has access to referenced files, panes, and evidence."
  }
end

# Summarize self_review_guard for audit/handoff.
def self_review_guard_summary(task)
  guard = task.is_a?(Hash) ? task["self_review_guard"] : nil
  return nil unless guard
  {
    "protocol_changed" => guard["protocol_changed"],
    "independent_check_required" => guard["independent_check_required"],
    "same_system_self_approval_allowed" => guard["same_system_self_approval_allowed"],
    "waiver" => guard["waiver"]
  }
end

def quality_calibration_summary(task)
  qc = task.is_a?(Hash) ? task["quality_calibration"] : nil
  return nil unless qc.is_a?(Hash)
  metrics = qc["metrics"].is_a?(Hash) ? qc["metrics"] : {}
  {
    "sample_rate" => qc["sample_rate"],
    "metrics" => {
      "false_pass" => metrics["false_pass"],
      "false_block" => metrics["false_block"],
      "user_corrections" => metrics["user_corrections"],
      "median_gate_wait" => metrics["median_gate_wait"]
    }
  }
end

def risk_level_tradeoff_summary(task)
  return nil unless task.is_a?(Hash) && task["task_risk"].is_a?(Hash)
  level = task.dig("task_risk", "level").to_s
  tradeoffs = {
    "light" => {
      "speed" => "fastest",
      "rigor" => "minimal gates",
      "tradeoff" => "Use for low-impact docs or formatting work where review/test gates would add more delay than risk reduction."
    },
    "standard" => {
      "speed" => "balanced",
      "rigor" => "review and test gates",
      "tradeoff" => "Use for normal behavior changes where review/test evidence is worth the added cycle time."
    },
    "strict" => {
      "speed" => "slower",
      "rigor" => "strict write policy plus review/test gates",
      "tradeoff" => "Use for high-risk changes where preventing false pass matters more than turnaround speed."
    },
    "release" => {
      "speed" => "slowest",
      "rigor" => "release readiness plus review/test gates",
      "tradeoff" => "Use for publishing or deployable artifacts where CI, package, remote, and release evidence are required."
    }
  }
  (tradeoffs[level] || tradeoffs["standard"]).merge("level" => level.empty? ? "standard" : level)
end

# Governance audit findings: compatibility gaps, self-review violations, backup issues.
def governance_audit_findings(task)
  findings = []
  return findings unless task.is_a?(Hash)

  cp = task["compatibility_policy"]
  if cp.is_a?(Hash) && cp["mode"] == "warn_legacy"
    findings << {
      "source" => "task_file.compatibility_policy.mode",
      "severity" => "medium",
      "message" => "compatibility_policy.mode is warn_legacy; legacy evidence may not be fully enforced by new strict rules."
    }
  end

  guard = task["self_review_guard"]
  if guard.is_a?(Hash) && guard["protocol_changed"] == true
    risk_level = task.dig("task_risk", "level")
    if %w[strict release].include?(risk_level) && guard["independent_check_required"] != false && guard["same_system_self_approval_allowed"] != true
      waiver = guard["waiver"]
      unless waiver.is_a?(String) && !waiver.strip.empty?
        findings << {
          "source" => "task_file.self_review_guard",
          "severity" => "high",
          "message" => "Protocol change under #{risk_level} risk lacks independent check or waiver; self-review is blocked."
        }
      end
    end
  end

  bm = task["backup_migration"]
  if bm.is_a?(Hash) && bm["export_format"].is_a?(String) && !bm["export_format"].empty?
    unless bm["restore_check"].is_a?(String) && !bm["restore_check"].empty?
      findings << {
        "source" => "task_file.backup_migration.restore_check",
        "severity" => "high",
        "message" => "backup_migration.export_format is set but restore_check is missing; backup without restore verification is a governance gap."
      }
    end
  end

  findings
end
