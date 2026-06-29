# ---------------------------------------------------------------------------
# Slice 12: data-classification-and-retention acceptance tests
# ---------------------------------------------------------------------------

S12_TASK="$TMPROOT/s12-task.yaml"
"$CLI" new-task --target-role reviewer --task-type docs_improvement --output "$S12_TASK" >/dev/null

# ---- Group 1: evidence add preserves data_classification / retention_policy / trust_repair ----

S12_ADD_EVIDENCE="$TMPROOT/s12-add-evidence.json"
"$CLI" evidence init --output "$S12_ADD_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add \
  --file "$S12_ADD_EVIDENCE" \
  --kind command --status pass --summary "Command with classified artifact." \
  --data-classification '{"categories":["log","local_path"],"sensitivity":"medium","redaction":"recommended"}' \
  --retention-policy '{"mode":"short_lived","expires_at":"2026-12-31T00:00:00Z","user_approved":true}' \
  --trust-repair '{"incident_id":"INC-001","impact":"low","recovery":"rotated key","prevention":"added scanner"}' \
  --json >/dev/null
json_assert 'evidence add preserves data_classification' "$S12_ADD_EVIDENCE" \
  'j["records"].any? { |r| r["data_classification"].is_a?(Hash) && r["data_classification"]["sensitivity"] == "medium" }'
json_assert 'evidence add preserves retention_policy' "$S12_ADD_EVIDENCE" \
  'j["records"].any? { |r| r["retention_policy"].is_a?(Hash) && r["retention_policy"]["mode"] == "short_lived" }'
json_assert 'evidence add preserves trust_repair' "$S12_ADD_EVIDENCE" \
  'j["records"].any? { |r| r["trust_repair"].is_a?(Hash) && r["trust_repair"]["incident_id"] == "INC-001" }'
pass 'evidence add preserves data classification fields'

# validate accepts evidence with classification fields.
"$CLI" validate --task "$S12_TASK" --evidence "$S12_ADD_EVIDENCE" --json >"$TMPROOT/s12-add-validate.json" 2>/dev/null || true
json_assert 'validate accepts evidence with data_classification' "$TMPROOT/s12-add-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("data_classification") }'

# ---- Group 2: secret + raw_allowed/missing retention fails validate ----

S12_SECRET_RAW_EVIDENCE="$TMPROOT/s12-secret-raw-evidence.json"
"$CLI" evidence init --output "$S12_SECRET_RAW_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"secret raw content","created_at"=>"2026-06-29T10:00:00Z",
  "data_classification"=>{"categories"=>["secret"],"sensitivity"=>"secret"},
  "retention_policy"=>{"mode"=>"raw_allowed"}}
File.write(p, JSON.pretty_generate(j))' "$S12_SECRET_RAW_EVIDENCE"
expect_failure 'validate rejects secret with raw_allowed retention' "$CLI" validate --task "$S12_TASK" --evidence "$S12_SECRET_RAW_EVIDENCE" --json

# secret without retention_policy also fails validate.
S12_SECRET_NO_RP_EVIDENCE="$TMPROOT/s12-secret-no-rp-evidence.json"
"$CLI" evidence init --output "$S12_SECRET_NO_RP_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"secret no rp","created_at"=>"2026-06-29T10:00:00Z",
  "data_classification"=>{"categories"=>["secret"],"sensitivity"=>"secret"}}
File.write(p, JSON.pretty_generate(j))' "$S12_SECRET_NO_RP_EVIDENCE"
expect_failure 'validate rejects secret without retention_policy' "$CLI" validate --task "$S12_TASK" --evidence "$S12_SECRET_NO_RP_EVIDENCE" --json

# secret with hash_only retention passes validate.
S12_SECRET_HASH_EVIDENCE="$TMPROOT/s12-secret-hash-evidence.json"
"$CLI" evidence init --output "$S12_SECRET_HASH_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"secret hash_only","created_at"=>"2026-06-29T10:00:00Z",
  "data_classification"=>{"categories"=>["secret"],"sensitivity"=>"secret","redaction"=>"applied"},
  "retention_policy"=>{"mode"=>"hash_only","user_approved"=>true}}
File.write(p, JSON.pretty_generate(j))' "$S12_SECRET_HASH_EVIDENCE"
"$CLI" validate --task "$S12_TASK" --evidence "$S12_SECRET_HASH_EVIDENCE" --json >"$TMPROOT/s12-secret-hash-validate.json"
json_assert 'validate accepts secret with hash_only retention' "$TMPROOT/s12-secret-hash-validate.json" \
  'j["valid"] == true'
pass 'secret with hash_only retention passes validate'

# ---- Group 3: audit warns on unclassified screenshot ----

S12_SCREENSHOT_EVIDENCE="$TMPROOT/s12-screenshot-evidence.json"
"$CLI" evidence init --output "$S12_SCREENSHOT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"screenshot taken","created_at"=>"2026-06-29T10:00:00Z",
  "artifacts"=>["screenshots/error.png"]}
File.write(p, JSON.pretty_generate(j))' "$S12_SCREENSHOT_EVIDENCE"
S12_SCREENSHOT_STATE="$TMPROOT/s12-screenshot-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S12_TASK" "$S12_SCREENSHOT_EVIDENCE" "$S12_SCREENSHOT_STATE"
"$CLI" audit --task "$S12_TASK" --evidence "$S12_SCREENSHOT_EVIDENCE" --state "$S12_SCREENSHOT_STATE" --json >"$TMPROOT/s12-screenshot-audit.json" 2>/dev/null || true
json_assert 'audit warns on unclassified screenshot' "$TMPROOT/s12-screenshot-audit.json" \
  'j["warnings"].any? { |w| w["source"].include?("data_classification") }'
pass 'audit warns on unclassified screenshot'

# ---- Group 4: audit includes data_classification_summary ----

"$CLI" audit --task "$S12_TASK" --evidence "$S12_SECRET_HASH_EVIDENCE" --state "$S12_SCREENSHOT_STATE" --json >"$TMPROOT/s12-dc-audit.json" 2>/dev/null || true
json_assert 'audit includes data_classification_summary' "$TMPROOT/s12-dc-audit.json" \
  'j.key?("data_classification_summary") && j["data_classification_summary"]["has_secret"] == true'

# ---- Group 5: audit includes trust_repair_summary ----

S12_TR_EVIDENCE="$TMPROOT/s12-tr-evidence.json"
"$CLI" evidence init --output "$S12_TR_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"incident logged","created_at"=>"2026-06-29T10:00:00Z",
  "trust_repair"=>{"incident_id"=>"INC-002","impact":"medium","recovery":"patched","prevention":"added check","follow_up_verification":"re-audit"}}
File.write(p, JSON.pretty_generate(j))' "$S12_TR_EVIDENCE"
"$CLI" audit --task "$S12_TASK" --evidence "$S12_TR_EVIDENCE" --state "$S12_SCREENSHOT_STATE" --json >"$TMPROOT/s12-tr-audit.json" 2>/dev/null || true
json_assert 'audit includes trust_repair_summary with incidents' "$TMPROOT/s12-tr-audit.json" \
  'j["trust_repair_summary"]["has_incidents"] == true && j["trust_repair_summary"]["incidents"].any? { |i| i["incident_id"] == "INC-002" }'

# ---- Group 6: compact-evidence excludes secret raw content ----

S12_COMPACT_EVIDENCE="$TMPROOT/s12-compact-evidence.json"
"$CLI" evidence init --output "$S12_COMPACT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"SECRET_API_KEY=abc123","created_at"=>"2026-06-29T10:00:00Z",
  "artifacts"=>["secret.log"],
  "data_classification"=>{"categories"=>["secret"],"sensitivity"=>"secret"},
  "retention_policy"=>{"mode"=>"hash_only","user_approved"=>true}}
File.write(p, JSON.pretty_generate(j))' "$S12_COMPACT_EVIDENCE"
"$CLI" compact-evidence --task "$S12_TASK" --evidence "$S12_COMPACT_EVIDENCE" --output "$TMPROOT/s12-compact.json" --json >"$TMPROOT/s12-compact-stdout.json" 2>/dev/null || true
json_assert 'compact summary excludes literal secret content' "$TMPROOT/s12-compact-stdout.json" \
  '!JSON.dump(j).include?("SECRET_API_KEY=abc123")'
json_assert 'compact summary has artifact refs' "$TMPROOT/s12-compact-stdout.json" \
  'j["compact_summary"]["artifact_refs"].is_a?(Array)'

# ---- Group 7: handoff excludes secret raw content but includes trust_repair_summary ----

S12_HANDOFF_EVIDENCE="$TMPROOT/s12-handoff-evidence.json"
"$CLI" evidence init --output "$S12_HANDOFF_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"SECRET_TOKEN=xyz789","created_at"=>"2026-06-29T10:00:00Z",
  "artifacts"=>["secret-output.log"],
  "data_classification"=>{"categories"=>["secret"],"sensitivity"=>"secret"},
  "retention_policy"=>{"mode"=>"hash_only","user_approved"=>true},
  "trust_repair"=>{"incident_id"=>"INC-003","impact":"high","recovery":"revoked token","prevention":"scanner added"}}
File.write(p, JSON.pretty_generate(j))' "$S12_HANDOFF_EVIDENCE"
S12_HANDOFF_STATE="$TMPROOT/s12-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S12_TASK" "$S12_HANDOFF_EVIDENCE" "$S12_HANDOFF_STATE"
"$CLI" handoff --task "$S12_TASK" --evidence "$S12_HANDOFF_EVIDENCE" --state "$S12_HANDOFF_STATE" --json >"$TMPROOT/s12-handoff.json" 2>/dev/null || true
json_assert 'handoff excludes literal secret raw content' "$TMPROOT/s12-handoff.json" \
  '!JSON.dump(j).include?("SECRET_TOKEN=xyz789")'
json_assert 'handoff includes trust_repair_summary' "$TMPROOT/s12-handoff.json" \
  'j.key?("trust_repair_summary") && j["trust_repair_summary"]["has_incidents"] == true'
json_assert 'handoff evidence_summary latest is redacted for secret' "$TMPROOT/s12-handoff.json" \
  'ls = j["evidence_summary"]["latest"]; ls.is_a?(Hash) && ls["summary"] == "[redacted: sensitive data classification]"'

# ---- Group 8: evidence submit rejects invalid data_classification ----

S12_BAD_DC_EVIDENCE="$TMPROOT/s12-bad-dc-evidence.json"
"$CLI" evidence init --output "$S12_BAD_DC_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"bad dc","created_at"=>"2026-06-29T10:00:00Z",
  "data_classification"=>"not-a-hash"}
File.write(p, JSON.pretty_generate(j))' "$S12_BAD_DC_EVIDENCE"
expect_failure 'validate rejects non-Hash data_classification' "$CLI" validate --task "$S12_TASK" --evidence "$S12_BAD_DC_EVIDENCE" --json

# validate rejects invalid category enum.
S12_BAD_CAT_EVIDENCE="$TMPROOT/s12-bad-cat-evidence.json"
"$CLI" evidence init --output "$S12_BAD_CAT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"bad cat","created_at"=>"2026-06-29T10:00:00Z",
  "data_classification"=>{"categories"=>["totally_invalid_category"],"sensitivity"=>"low"}}
File.write(p, JSON.pretty_generate(j))' "$S12_BAD_CAT_EVIDENCE"
expect_failure 'validate rejects invalid data_classification category' "$CLI" validate --task "$S12_TASK" --evidence "$S12_BAD_CAT_EVIDENCE" --json

# ---- Group 9: old evidence without new fields still validates ----

S12_LEGACY_EVIDENCE="$TMPROOT/s12-legacy-evidence.json"
"$CLI" evidence init --output "$S12_LEGACY_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$S12_LEGACY_EVIDENCE" --kind command --status pass --summary "legacy record" >/dev/null
"$CLI" validate --task "$S12_TASK" --evidence "$S12_LEGACY_EVIDENCE" --json >"$TMPROOT/s12-legacy-validate.json"
json_assert 'old evidence without classification fields validates' "$TMPROOT/s12-legacy-validate.json" \
  'j["valid"] == true'
pass 'legacy evidence without classification fields is compatible'
