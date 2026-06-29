# frozen_string_literal: true

# Slice 9: gate lease metadata + stale verdict arbitration.
#
# A gate verdict record may carry a top-level `gate_lease` mapping describing who owns the
# gate work and when the claim expires. Arbitration picks the accepted verdict among multiple
# records for the same gate by preferring records whose task_sha256 matches the current task
# revision, and among matching revisions the latest by created_at. Older-revision verdicts are
# marked stale and cannot pass the gate; superseded records (older within the same revision) are
# reported separately.

# Stable record id used across arbitration output. Falls back to source_message_id, then index.
def gate_record_id(record, index)
  return record["record_id"] if record.is_a?(Hash) && record["record_id"].is_a?(String) && !record["record_id"].empty?
  return record["source_message_id"] if record.is_a?(Hash) && record["source_message_id"].is_a?(String) && !record["source_message_id"].empty?

  "record_#{index}"
end

# Parses a record's created_at; nil if unparseable.
def gate_record_created_at(record)
  return nil unless record.is_a?(Hash)
  return nil unless record["created_at"].is_a?(String) && !record["created_at"].empty?

  Time.iso8601(record["created_at"])
rescue ArgumentError
  nil
end

# Returns true iff the record's stored task_sha256 is present and matches current_task_sha256.
def record_matches_task_revision?(record, current_task_sha256)
  return false unless current_task_sha256.is_a?(String) && !current_task_sha256.empty?
  stored = record_task_sha256_from(record)
  stored.is_a?(String) && !stored.empty? && stored == current_task_sha256
end

# Returns true iff the record's stored task_sha256 is present and differs from current_task_sha256.
def record_is_stale_revision?(record, current_task_sha256)
  return false unless current_task_sha256.is_a?(String) && !current_task_sha256.empty?
  stored = record_task_sha256_from(record)
  stored.is_a?(String) && !stored.empty? && stored != current_task_sha256
end

# Collects structured submit records of the evidence_record_kind for a gate kind.
def gate_kind_candidate_records(records, gate_kind)
  evidence_record_kind = GATE_KIND_EVIDENCE_RECORD_KIND[gate_kind] || gate_kind
  return [] unless records.is_a?(Array)
  return [] unless STRUCTURED_SUBMIT_KINDS.include?(evidence_record_kind)

  records.each_with_index.map do |record, index|
    next unless record.is_a?(Hash)
    next unless record["kind"] == evidence_record_kind
    next unless record["structured_submit"] == true
    next if record["status"] == "invalid"

    created_at = gate_record_created_at(record)
    next unless created_at

    { record: record, index: index, created_at: created_at }
  end.compact
end

# Computes verdict arbitration for one gate kind against the current task revision.
#
# conflict_resolution: latest_valid_for_task_revision — the accepted record is the latest record
# whose stored task_sha256 matches current_task_sha256 (or the latest record overall when no
# current_task_sha256 is supplied, preserving legacy behavior). Records for older revisions are
# stale; earlier records superseded by a newer record within the accepted revision are superseded.
def verdict_arbitration_for_gate(records, gate_kind, current_task_sha256 = nil)
  candidates = gate_kind_candidate_records(records, gate_kind)
  result = {
    "gate" => gate_kind,
    "conflict_resolution" => VERDICT_ARBITRATION_CONFLICT_RESOLUTION,
    "accepted_record_id" => nil,
    "accepted_record" => nil,
    "superseded_records" => [],
    "stale_records" => [],
    "conflict_detected" => false,
    "has_stale" => false
  }
  return result if candidates.empty?

  current_revision, stale =
    if current_task_sha256
      # Records without a stored task_sha256 predate Slice 9 identity capture; treat them as
      # current-revision candidates so legacy evidence still arbitrates normally.
      partition = candidates.partition do |c|
        stored = record_task_sha256_from(c[:record])
        stored.nil? || stored.empty? || stored == current_task_sha256
      end
      [partition[0], partition[1]]
    else
      [candidates, []]
    end

  # Fallback: when no records match the current revision, arbitration has no accepted record.
  accepted = current_revision.max_by { |c| [c[:created_at], c[:index]] }

  if accepted
    accepted_id = gate_record_id(accepted[:record], accepted[:index])
    result["accepted_record_id"] = accepted_id
    result["accepted_record"] = accepted[:record]

    superseded = current_revision.reject { |c| c[:index] == accepted[:index] }
    result["superseded_records"] = superseded.map { |c| gate_record_id(c[:record], c[:index]) }

    # Conflict: two records with different pass/fail outcomes for the accepted revision.
    outcomes = current_revision.map { |c| c[:record]["status"] }.compact.uniq
    result["conflict_detected"] = outcomes.length > 1
  end

  result["stale_records"] = stale.map { |c| gate_record_id(c[:record], c[:index]) }
  result["has_stale"] = !stale.empty?
  result
end

# Returns the accepted record for a gate per arbitration, or nil.
def accepted_gate_record(records, gate_kind, current_task_sha256 = nil)
  verdict_arbitration_for_gate(records, gate_kind, current_task_sha256)["accepted_record"]
end

# Parses and validates a gate_lease mapping carried by a record. Returns nil when absent or malformed.
def normalize_gate_lease(value)
  return nil unless value.is_a?(Hash)

  gate = value["gate"]
  return nil unless gate.is_a?(String) && !gate.empty?

  result = { "gate" => gate }
  %w[owner_instance task_sha256 claimed_at expires_at].each do |f|
    next unless value[f].is_a?(String) && !value[f].empty?
    result[f] = value[f]
  end
  result["evidence_revision"] = value["evidence_revision"] if value["evidence_revision"].is_a?(Integer) && value["evidence_revision"] >= 0
  status = value["status"]
  result["status"] = status if status.is_a?(String) && ALLOWED_GATE_LEASE_STATUSES.include?(status)
  policy = value["replacement_policy"]
  result["replacement_policy"] = policy if policy.is_a?(String) && ALLOWED_GATE_LEASE_REPLACEMENT_POLICIES.include?(policy)
  result
end

# Computes the effective lease status, transitioning claimed -> expired when expires_at has passed.
def gate_lease_effective_status(lease, now = Time.now.utc)
  return nil unless lease.is_a?(Hash)
  return lease["status"] unless lease["status"] == "claimed"

  expires_at = lease["expires_at"]
  return "claimed" unless expires_at.is_a?(String) && !expires_at.empty?

  begin
    exp = Time.iso8601(expires_at)
  rescue ArgumentError
    return "claimed"
  end
  exp < now ? "expired" : "claimed"
end

# Replacement is allowed when the lease policy permits and the claim is no longer active.
def gate_lease_replaceable?(lease, now = Time.now.utc)
  return false unless lease.is_a?(Hash)
  policy = lease["replacement_policy"] || GATE_LEASE_DEFAULT_REPLACEMENT_POLICY
  return false unless ALLOWED_GATE_LEASE_REPLACEMENT_POLICIES.include?(policy)
  return true if policy == "allow_after_expiry" && gate_lease_effective_status(lease, now) == "expired"
  return false if policy == "deny"

  policy == "owner_only"
end

# Aggregates gate leases across evidence records for audit/handoff.
# Picks the latest lease per gate kind (by claimed_at) and partitions by effective status.
def gate_lease_summary(evidence, now = Time.now.utc)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  latest_by_gate = {}
  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)
    lease = normalize_gate_lease(record["gate_lease"])
    next unless lease

    gate = lease["gate"]
    current = latest_by_gate[gate]
    claimed = lease["claimed_at"]
    claimed_time = claimed.is_a?(String) ? (begin; Time.iso8601(claimed); rescue ArgumentError; nil; end) : nil
    next if current && current[:claimed_time] && (!claimed_time || claimed_time < current[:claimed_time])

    latest_by_gate[gate] = { lease: lease, claimed_time: claimed_time, record_id: gate_record_id(record, index) }
  end

  active = []
  expired = []
  latest_by_gate.each_value do |entry|
    lease = entry[:lease]
    augmented = lease.merge("record_id" => entry[:record_id], "effective_status" => gate_lease_effective_status(lease, now), "replaceable" => gate_lease_replaceable?(lease, now))
    if augmented["effective_status"] == "expired"
      expired << augmented
    else
      active << augmented
    end
  end

  {
    "active_leases" => active,
    "expired_leases" => expired,
    "active_count" => active.length,
    "expired_count" => expired.length,
    "any_replaceable" => expired.any? { |l| l["replaceable"] }
  }
end

# Aggregates verdict arbitration across all required gate kinds for a task.
def verdict_arbitration_summary(task, evidence, current_task_sha256 = nil)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  required = required_evidence_kinds(task).map do |kind|
    arb = verdict_arbitration_for_gate(records, kind, current_task_sha256)
    {
      "gate" => kind,
      "accepted_record_id" => arb["accepted_record_id"],
      "accepted_status" => arb["accepted_record"] ? arb["accepted_record"]["status"] : nil,
      "superseded_records" => arb["superseded_records"],
      "stale_records" => arb["stale_records"],
      "conflict_detected" => arb["conflict_detected"],
      "has_stale" => arb["has_stale"],
      "conflict_resolution" => arb["conflict_resolution"]
    }
  end
  {
    "conflict_resolution" => VERDICT_ARBITRATION_CONFLICT_RESOLUTION,
    "gates" => required,
    "any_stale" => required.any? { |g| g["has_stale"] },
    "any_conflict" => required.any? { |g| g["conflict_detected"] }
  }
end
