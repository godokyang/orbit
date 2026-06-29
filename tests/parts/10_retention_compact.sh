# Slice 7: evidence-retention-and-compact-defaults
# Tests 443-468
# Prereqs (from 02_task_evidence.sh):
#   IMPL_TASK, IMPL_EVIDENCE
#   $TMPROOT/implementation-handoff.json
#   $TMPROOT/durable-summary.json  (compact-evidence output)

# ---- Group 1: compact_summary block in compact-evidence output ----

json_assert 'compact_summary block is present as a Hash' "$TMPROOT/durable-summary.json" \
  'j["compact_summary"].is_a?(Hash)'
json_assert 'compact_summary.task_sha256 is 64-char hex' "$TMPROOT/durable-summary.json" \
  'j["compact_summary"]["task_sha256"].is_a?(String) && j["compact_summary"]["task_sha256"].match?(/\A[0-9a-f]{64}\z/)'
json_assert 'compact_summary.evidence_sha256 is 64-char hex' "$TMPROOT/durable-summary.json" \
  'j["compact_summary"]["evidence_sha256"].is_a?(String) && j["compact_summary"]["evidence_sha256"].match?(/\A[0-9a-f]{64}\z/)'
json_assert 'compact_summary.handoff_sha256 is 64-char hex' "$TMPROOT/durable-summary.json" \
  'j["compact_summary"]["handoff_sha256"].is_a?(String) && j["compact_summary"]["handoff_sha256"].match?(/\A[0-9a-f]{64}\z/)'
json_assert 'compact_summary.latest_verdicts.review.status is pass' "$TMPROOT/durable-summary.json" \
  'j["compact_summary"]["latest_verdicts"]["review"]["status"] == "pass"'
json_assert 'compact_summary.artifact_refs is an Array' "$TMPROOT/durable-summary.json" \
  'j["compact_summary"]["artifact_refs"].is_a?(Array)'

# ---- Group 2: audit --compact-summary ----

# Build a dedicated state for retention audit tests pointing to IMPL task/evidence
S10_STATE="$TMPROOT/s10-state.yaml"
ruby --disable-gems -ryaml -e '
  File.write(ARGV[0], YAML.dump({
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "done",
    "current_task" => File.expand_path(ARGV[1]),
    "artifacts" => {
      "evidence_file" => File.expand_path(ARGV[2]),
      "handoff_packet" => File.expand_path(ARGV[3])
    },
    "history" => []
  }))' \
  "$S10_STATE" "$IMPL_TASK" "$IMPL_EVIDENCE" "$TMPROOT/implementation-handoff.json"

"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
  --state "$S10_STATE" \
  --compact-summary "$TMPROOT/durable-summary.json" \
  --json >"$TMPROOT/s10-audit-compact.json" 2>/dev/null
json_assert 'audit --compact-summary reports compact_summary_present true' "$TMPROOT/s10-audit-compact.json" \
  'j["retention_summary"]["compact_summary_present"] == true'
json_assert 'audit --compact-summary retention_summary has orbit_dir_size_kb' "$TMPROOT/s10-audit-compact.json" \
  'j["retention_summary"]["orbit_dir_size_kb"].is_a?(Integer)'

# Bad compact summary: remove compact_summary.task_sha256
S10_BAD_SUMMARY="$TMPROOT/s10-bad-compact-summary.json"
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["compact_summary"].delete("task_sha256")
  File.write(ARGV[1], JSON.pretty_generate(j))' \
  "$TMPROOT/durable-summary.json" "$S10_BAD_SUMMARY"

if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
     --state "$S10_STATE" \
     --compact-summary "$S10_BAD_SUMMARY" \
     --json >"$TMPROOT/s10-bad-summary-audit.json" 2>/dev/null; then
  printf 'FAIL audit rejects compact summary missing task_sha256: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit rejects compact summary missing task_sha256'
json_assert 'compact summary missing task_sha256 error references compact_summary.compact_summary.task_sha256' "$TMPROOT/s10-bad-summary-audit.json" \
  'j["blocking_findings"].any? { |e| e["source"].include?("task_sha256") }'

# Compact summary: missing file is a blocking finding
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
     --state "$S10_STATE" \
     --compact-summary "$TMPROOT/nonexistent-summary.json" \
     --json >"$TMPROOT/s10-missing-summary-audit.json" 2>/dev/null; then
  printf 'FAIL audit rejects missing compact summary file: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit rejects missing compact summary file as blocking finding'
json_assert 'missing compact summary file error references compact_summary source' "$TMPROOT/s10-missing-summary-audit.json" \
  'j["blocking_findings"].any? { |e| e["source"] == "compact_summary" }'

# Compact summary: missing evidence_sha256 is a blocking finding
S10_BAD_SUMMARY_NOEV="$TMPROOT/s10-bad-compact-summary-noev.json"
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["compact_summary"].delete("evidence_sha256")
  File.write(ARGV[1], JSON.pretty_generate(j))' \
  "$TMPROOT/durable-summary.json" "$S10_BAD_SUMMARY_NOEV"
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
     --state "$S10_STATE" \
     --compact-summary "$S10_BAD_SUMMARY_NOEV" \
     --json >"$TMPROOT/s10-bad-summary-noev-audit.json" 2>/dev/null; then
  printf 'FAIL audit rejects compact summary missing evidence_sha256: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit rejects compact summary missing evidence_sha256'
json_assert 'missing evidence_sha256 error references evidence_sha256 source' "$TMPROOT/s10-bad-summary-noev-audit.json" \
  'j["blocking_findings"].any? { |e| e["source"].include?("evidence_sha256") }'

# Compact summary: missing handoff_sha256 when --handoff is provided is a blocking finding
S10_BAD_SUMMARY_NOHF="$TMPROOT/s10-bad-compact-summary-nohf.json"
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["compact_summary"].delete("handoff_sha256")
  File.write(ARGV[1], JSON.pretty_generate(j))' \
  "$TMPROOT/durable-summary.json" "$S10_BAD_SUMMARY_NOHF"
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
     --state "$S10_STATE" \
     --handoff "$TMPROOT/implementation-handoff.json" \
     --compact-summary "$S10_BAD_SUMMARY_NOHF" \
     --json >"$TMPROOT/s10-bad-summary-nohf-audit.json" 2>/dev/null; then
  printf 'FAIL audit rejects compact summary missing handoff_sha256 when --handoff given: unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit rejects compact summary missing handoff_sha256 when --handoff given'
json_assert 'missing handoff_sha256 error references handoff_sha256 source' "$TMPROOT/s10-bad-summary-nohf-audit.json" \
  'j["blocking_findings"].any? { |e| e["source"].include?("handoff_sha256") }'

# Compact summary: matching SHA values are part of the proof chain, not just schema shape
S10_BAD_SUMMARY_TASK_MISMATCH="$TMPROOT/s10-bad-compact-summary-task-mismatch.json"
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["compact_summary"]["task_sha256"] = "a" * 64
  File.write(ARGV[1], JSON.pretty_generate(j))' \
  "$TMPROOT/durable-summary.json" "$S10_BAD_SUMMARY_TASK_MISMATCH"
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
     --state "$S10_STATE" \
     --compact-summary "$S10_BAD_SUMMARY_TASK_MISMATCH" \
     --json >"$TMPROOT/s10-bad-summary-task-mismatch-audit.json" 2>/dev/null; then
  printf 'FAIL audit rejects compact summary task_sha256 mismatch: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit rejects compact summary task_sha256 mismatch'
json_assert 'task_sha256 mismatch error references task_sha256 source' "$TMPROOT/s10-bad-summary-task-mismatch-audit.json" \
  'j["blocking_findings"].any? { |e| e["source"].include?("task_sha256") && e["message"].include?("must match") }'

S10_BAD_SUMMARY_EVIDENCE_MISMATCH="$TMPROOT/s10-bad-compact-summary-evidence-mismatch.json"
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["compact_summary"]["evidence_sha256"] = "a" * 64
  File.write(ARGV[1], JSON.pretty_generate(j))' \
  "$TMPROOT/durable-summary.json" "$S10_BAD_SUMMARY_EVIDENCE_MISMATCH"
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
     --state "$S10_STATE" \
     --compact-summary "$S10_BAD_SUMMARY_EVIDENCE_MISMATCH" \
     --json >"$TMPROOT/s10-bad-summary-evidence-mismatch-audit.json" 2>/dev/null; then
  printf 'FAIL audit rejects compact summary evidence_sha256 mismatch: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit rejects compact summary evidence_sha256 mismatch'
json_assert 'evidence_sha256 mismatch error references evidence_sha256 source' "$TMPROOT/s10-bad-summary-evidence-mismatch-audit.json" \
  'j["blocking_findings"].any? { |e| e["source"].include?("evidence_sha256") && e["message"].include?("must match") }'

S10_BAD_SUMMARY_HANDOFF_MISMATCH="$TMPROOT/s10-bad-compact-summary-handoff-mismatch.json"
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["compact_summary"]["handoff_sha256"] = "a" * 64
  File.write(ARGV[1], JSON.pretty_generate(j))' \
  "$TMPROOT/durable-summary.json" "$S10_BAD_SUMMARY_HANDOFF_MISMATCH"
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
     --state "$S10_STATE" \
     --handoff "$TMPROOT/implementation-handoff.json" \
     --compact-summary "$S10_BAD_SUMMARY_HANDOFF_MISMATCH" \
     --json >"$TMPROOT/s10-bad-summary-handoff-mismatch-audit.json" 2>/dev/null; then
  printf 'FAIL audit rejects compact summary handoff_sha256 mismatch: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit rejects compact summary handoff_sha256 mismatch'
json_assert 'handoff_sha256 mismatch error references handoff_sha256 source' "$TMPROOT/s10-bad-summary-handoff-mismatch-audit.json" \
  'j["blocking_findings"].any? { |e| e["source"].include?("handoff_sha256") && e["message"].include?("must match") }'

# ---- Group 3: audit --handoff drift detection ----

# Audit without drift: verdicts in evidence match handoff
"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
  --state "$S10_STATE" \
  --handoff "$TMPROOT/implementation-handoff.json" \
  --json >"$TMPROOT/s10-audit-no-drift.json" 2>/dev/null || true
json_assert 'audit --handoff no drift reports has_drift false' "$TMPROOT/s10-audit-no-drift.json" \
  'j["retention_drift_summary"]["has_drift"] == false'

# Create a drifted handoff: change review verdict to "fail" in handoff but evidence still has "pass"
S10_DRIFTED_HANDOFF="$TMPROOT/s10-drifted-handoff.json"
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["latest_gate_verdicts"]["review"]["status"] = "fail"
  File.write(ARGV[1], JSON.pretty_generate(j))' \
  "$TMPROOT/implementation-handoff.json" "$S10_DRIFTED_HANDOFF"

"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" \
  --state "$S10_STATE" \
  --handoff "$S10_DRIFTED_HANDOFF" \
  --json >"$TMPROOT/s10-audit-drift.json" || true
json_assert 'audit --handoff with drift reports has_drift true' "$TMPROOT/s10-audit-drift.json" \
  'j["retention_drift_summary"]["has_drift"] == true'
json_assert 'audit drift emits warning for retention.handoff_drift' "$TMPROOT/s10-audit-drift.json" \
  'j["warnings"].any? { |w| w["source"] == "retention.handoff_drift" }'

# Regression: out-of-order records (older fail appended after newer pass) must not trigger drift
# Build evidence: review pass (newer timestamp) then review fail (older timestamp)
S10_OOO_EVIDENCE="$TMPROOT/s10-ooo-evidence.json"
"$CLI" evidence init --output "$S10_OOO_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["records"] ||= []
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"newer pass.",
    "created_at"=>"2026-06-29T12:00:00Z" }
  j["records"] << { "kind"=>"review","status"=>"fail","summary"=>"older fail (appended late).",
    "created_at"=>"2026-06-29T10:00:00Z" }
  j["records"] << { "kind"=>"test","status"=>"pass","summary"=>"test pass.",
    "created_at"=>"2026-06-29T12:00:00Z" }
  File.write(ARGV[0], JSON.pretty_generate(j))' "$S10_OOO_EVIDENCE"

# Handoff records review.status=pass (matching the semantically latest record)
S10_OOO_HANDOFF="$TMPROOT/s10-ooo-handoff.json"
ruby --disable-gems -rjson -e '
  h = { "latest_gate_verdicts" => {
    "review" => { "status" => "pass" },
    "test"   => { "status" => "pass" }
  }}
  File.write(ARGV[0], JSON.pretty_generate(h))' "$S10_OOO_HANDOFF"

"$CLI" audit --task "$IMPL_TASK" --evidence "$S10_OOO_EVIDENCE" \
  --state "$S10_STATE" \
  --handoff "$S10_OOO_HANDOFF" \
  --json >"$TMPROOT/s10-ooo-drift.json" 2>/dev/null || true
json_assert 'drift uses created_at latest semantics not array-last: no drift for ooo records' "$TMPROOT/s10-ooo-drift.json" \
  'j["retention_drift_summary"]["has_drift"] == false'
