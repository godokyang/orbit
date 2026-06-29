# ---------------------------------------------------------------------------
# Slice 4: Destructive Action And Scope Guard
# ---------------------------------------------------------------------------

S4_TASK="$TMPROOT/s4-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S4_TASK" >/dev/null

# new-task seeds artifact_policy and destructive_actions from template
yaml_assert 'new-task seeds artifact_policy' "$S4_TASK" \
  'j["artifact_policy"].is_a?(Hash) && j["artifact_policy"]["generated"] == "exclude_by_default"'
yaml_assert 'new-task seeds destructive_actions' "$S4_TASK" \
  'j["destructive_actions"].is_a?(Hash) && j["destructive_actions"]["required_protocol"] == true'

# new-task includes destructive_action_scope in schema_semantics feature_versions
yaml_assert 'new-task includes destructive_action_scope in feature_versions' "$S4_TASK" \
  'j.dig("schema_semantics","feature_versions","destructive_action_scope") == "v1"'

# validate passes for task with scope.include empty (no changed-files given)
"$CLI" validate --task "$S4_TASK" --json >"$TMPROOT/s4-validate-nofiles.json" 2>/dev/null || true
json_assert 'validate passes task with empty scope.include without --changed-files' \
  "$TMPROOT/s4-validate-nofiles.json" \
  'j["errors"].none? { |e| e["source"].include?("scope") }'

# validate with --changed-files passes when scope.include is empty (no restriction)
"$CLI" validate --task "$S4_TASK" --changed-files "src/foo.rb,lib/bar.rb" --json \
  >"$TMPROOT/s4-validate-empty-scope.json" 2>/dev/null || true
json_assert 'validate passes when scope.include is empty (no pattern restriction)' \
  "$TMPROOT/s4-validate-empty-scope.json" \
  'j["errors"].none? { |e| e["source"] == "task_file.scope.include" }'

# Build a task with scope.include restricted to src/**
S4_SCOPED_TASK="$TMPROOT/s4-scoped-task.yaml"
cp "$S4_TASK" "$S4_SCOPED_TASK"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["scope"]["include"]=["src/**"]
   File.write(p, YAML.dump(y))' \
  "$S4_SCOPED_TASK"

# changed file inside scope.include passes
"$CLI" validate --task "$S4_SCOPED_TASK" --changed-files "src/foo.rb" --json \
  >"$TMPROOT/s4-inside-scope.json" 2>/dev/null || true
json_assert 'validate passes for changed file inside scope.include' \
  "$TMPROOT/s4-inside-scope.json" \
  'j["errors"].none? { |e| e["source"] == "task_file.scope.include" }'

# changed file outside scope.include causes validate failure
if "$CLI" validate --task "$S4_SCOPED_TASK" --changed-files "lib/outside.rb" --json \
     >"$TMPROOT/s4-outside-scope.json" 2>/dev/null; then
  printf 'FAIL validate rejects changed file outside scope.include: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects changed file outside scope.include'
json_assert 'validate scope error references task_file.scope.include source' \
  "$TMPROOT/s4-outside-scope.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.scope.include" }'

# .orbit/** file outside scope.include causes validate failure (runtime file guard)
if "$CLI" validate --task "$S4_SCOPED_TASK" --changed-files ".orbit/loop-state.yaml" --json \
     >"$TMPROOT/s4-orbit-runtime.json" 2>/dev/null; then
  printf 'FAIL validate rejects .orbit runtime file outside scope.include: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects .orbit runtime file outside scope.include'

# validate artifact_policy: non-hash value is rejected
S4_BAD_POLICY_TASK="$TMPROOT/s4-bad-policy-task.yaml"
cp "$S4_TASK" "$S4_BAD_POLICY_TASK"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["artifact_policy"]="not-a-hash"; File.write(p, YAML.dump(y))' \
  "$S4_BAD_POLICY_TASK"
if "$CLI" validate --task "$S4_BAD_POLICY_TASK" --json >"$TMPROOT/s4-bad-policy.json" 2>/dev/null; then
  printf 'FAIL validate rejects malformed artifact_policy: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects malformed artifact_policy (non-hash)'
json_assert 'validate artifact_policy error references task_file.artifact_policy' \
  "$TMPROOT/s4-bad-policy.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.artifact_policy" }'

# validate destructive_actions: non-bool required_protocol is rejected
S4_BAD_DA_TASK="$TMPROOT/s4-bad-da-task.yaml"
cp "$S4_TASK" "$S4_BAD_DA_TASK"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["destructive_actions"]["required_protocol"]="yes"
   File.write(p, YAML.dump(y))' \
  "$S4_BAD_DA_TASK"
if "$CLI" validate --task "$S4_BAD_DA_TASK" --json >"$TMPROOT/s4-bad-da.json" 2>/dev/null; then
  printf 'FAIL validate rejects destructive_actions with non-bool required_protocol: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects destructive_actions with non-bool required_protocol'
json_assert 'validate destructive_actions error references task_file.destructive_actions.required_protocol' \
  "$TMPROOT/s4-bad-da.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.destructive_actions.required_protocol" }'

# Evidence record with valid destructive_action_plan (dry_run: true, recoverability present) passes validate
S4_EVIDENCE="$TMPROOT/s4-evidence.json"
"$CLI" evidence init --output "$S4_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Destructive plan validated.","created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "destructive_action_plan"=>{
       "action"=>"delete","dry_run"=>true,
       "targets"=>[{"path"=>"tmp/build","tracked"=>false,"owner"=>"agent","recoverability"=>"none","evidence_impact"=>"none"}],
       "user_confirmation"=>{"required"=>false,"received"=>false}
     }}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_EVIDENCE"
"$CLI" validate --task "$S4_TASK" --evidence "$S4_EVIDENCE" --json >"$TMPROOT/s4-valid-plan.json" 2>/dev/null || true
json_assert 'validate passes evidence with valid destructive_action_plan' \
  "$TMPROOT/s4-valid-plan.json" \
  'j["errors"].none? { |e| e["source"].include?("destructive_action_plan") }'

# Evidence record with destructive_action_plan missing dry_run fails validate
S4_NO_DRYRUN_EV="$TMPROOT/s4-no-dryrun-evidence.json"
"$CLI" evidence init --output "$S4_NO_DRYRUN_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Plan without dry_run.","created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "destructive_action_plan"=>{
       "action"=>"delete","dry_run"=>false,
       "targets"=>[{"path"=>"x","tracked"=>false,"owner"=>"agent","recoverability"=>"none","evidence_impact"=>"none"}]
     }}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_NO_DRYRUN_EV"
if "$CLI" validate --task "$S4_TASK" --evidence "$S4_NO_DRYRUN_EV" --json >"$TMPROOT/s4-no-dryrun.json" 2>/dev/null; then
  printf 'FAIL validate rejects destructive_action_plan missing dry_run: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects destructive_action_plan with dry_run: false'
json_assert 'validate dry_run error references .dry_run source' \
  "$TMPROOT/s4-no-dryrun.json" \
  'j["errors"].any? { |e| e["source"].include?("dry_run") }'

# Evidence record with target missing recoverability fails validate
S4_NO_RECOVER_EV="$TMPROOT/s4-no-recover-evidence.json"
"$CLI" evidence init --output "$S4_NO_RECOVER_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Target missing recoverability.","created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "destructive_action_plan"=>{
       "action"=>"delete","dry_run"=>true,
       "targets"=>[{"path"=>"x","tracked"=>false,"owner"=>"agent","evidence_impact"=>"none"}]
     }}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_NO_RECOVER_EV"
if "$CLI" validate --task "$S4_TASK" --evidence "$S4_NO_RECOVER_EV" --json >"$TMPROOT/s4-no-recover.json" 2>/dev/null; then
  printf 'FAIL validate rejects destructive_action_plan target missing recoverability: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects destructive_action_plan target missing recoverability'
json_assert 'validate recoverability error references .recoverability source' \
  "$TMPROOT/s4-no-recover.json" \
  'j["errors"].any? { |e| e["source"].include?("recoverability") }'

# Evidence-affecting target without hash recoverability fails validate
S4_EVIDENCE_IMPACT_EV="$TMPROOT/s4-evidence-impact-evidence.json"
"$CLI" evidence init --output "$S4_EVIDENCE_IMPACT_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Evidence-affecting target without hash.","created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "destructive_action_plan"=>{
       "action"=>"delete","dry_run"=>true,
       "targets"=>[{"path"=>"evidence/e.json","tracked"=>true,"owner"=>"agent","recoverability"=>"none","evidence_impact"=>"full_loss"}]
     }}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_EVIDENCE_IMPACT_EV"
if "$CLI" validate --task "$S4_TASK" --evidence "$S4_EVIDENCE_IMPACT_EV" --json >"$TMPROOT/s4-evidence-impact.json" 2>/dev/null; then
  printf 'FAIL validate rejects evidence-affecting target without hash recoverability: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects evidence-affecting destructive target without hash recoverability'
json_assert 'validate evidence-impact recoverability error references .recoverability source' \
  "$TMPROOT/s4-evidence-impact.json" \
  'j["errors"].any? { |e| e["source"].include?("recoverability") }'

# Evidence-affecting target WITH hash_only recoverability passes validate
S4_HASH_RECOVER_EV="$TMPROOT/s4-hash-recover-evidence.json"
"$CLI" evidence init --output "$S4_HASH_RECOVER_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Evidence-affecting target with hash.","created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "destructive_action_plan"=>{
       "action"=>"delete","dry_run"=>true,
       "targets"=>[{"path"=>"evidence/e.json","tracked"=>true,"owner"=>"agent","recoverability"=>"hash_only","evidence_impact"=>"full_loss"}]
     }}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_HASH_RECOVER_EV"
"$CLI" validate --task "$S4_TASK" --evidence "$S4_HASH_RECOVER_EV" --json >"$TMPROOT/s4-hash-recover.json" 2>/dev/null || true
json_assert 'validate passes evidence-affecting target with hash_only recoverability' \
  "$TMPROOT/s4-hash-recover.json" \
  'j["errors"].none? { |e| e["source"].include?("destructive_action_plan") }'

# User-owned target without user_confirmation.received fails validate
S4_USER_OWNED_EV="$TMPROOT/s4-user-owned-evidence.json"
"$CLI" evidence init --output "$S4_USER_OWNED_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"User-owned target no confirmation.","created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "destructive_action_plan"=>{
       "action"=>"delete","dry_run"=>true,
       "targets"=>[{"path"=>"user-data/file","tracked"=>true,"owner"=>"user","recoverability"=>"git_revert","evidence_impact"=>"none"}],
       "user_confirmation"=>{"required"=>true,"received"=>false}
     }}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_USER_OWNED_EV"
if "$CLI" validate --task "$S4_TASK" --evidence "$S4_USER_OWNED_EV" --json >"$TMPROOT/s4-user-owned.json" 2>/dev/null; then
  printf 'FAIL validate rejects user-owned destructive target without confirmation: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects user-owned destructive target without user_confirmation.received'
json_assert 'validate user-owned confirmation error references user_confirmation.received source' \
  "$TMPROOT/s4-user-owned.json" \
  'j["errors"].any? { |e| e["source"].include?("user_confirmation.received") }'

# audit includes destructive_action_summary (present: false when no plan)
S4_AUDIT_TASK="$TMPROOT/s4-audit-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S4_AUDIT_TASK" >/dev/null
S4_AUDIT_EV="$TMPROOT/s4-audit-evidence.json"
"$CLI" evidence init --output "$S4_AUDIT_EV" >/dev/null
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S4_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="done"; s["status"]="done"; File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml
"$CLI" audit --task "$S4_AUDIT_TASK" --evidence "$S4_AUDIT_EV" \
  --state .orbit/loop-state.yaml --json >"$TMPROOT/s4-audit.json" 2>/dev/null || true
json_assert 'audit includes destructive_action_summary field' \
  "$TMPROOT/s4-audit.json" \
  'j.key?("destructive_action_summary")'
json_assert 'audit destructive_action_summary present=false when no plan in evidence' \
  "$TMPROOT/s4-audit.json" \
  'j["destructive_action_summary"]["present"] == false'

# audit destructive_action_summary present=true and plan_count correct when plan exists
S4_AUDIT_PLAN_EV="$TMPROOT/s4-audit-plan-evidence.json"
"$CLI" evidence init --output "$S4_AUDIT_PLAN_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Destructive plan in audit.","created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "destructive_action_plan"=>{
       "action"=>"delete","dry_run"=>true,
       "targets"=>[{"path"=>"tmp/build","tracked"=>false,"owner"=>"agent","recoverability"=>"none","evidence_impact"=>"none"}]
     }}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_AUDIT_PLAN_EV"
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S4_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="done"; s["status"]="done"; File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml
"$CLI" audit --task "$S4_AUDIT_TASK" --evidence "$S4_AUDIT_PLAN_EV" \
  --state .orbit/loop-state.yaml --json >"$TMPROOT/s4-audit-plan.json" 2>/dev/null || true
json_assert 'audit destructive_action_summary present=true when evidence has plan' \
  "$TMPROOT/s4-audit-plan.json" \
  'j["destructive_action_summary"]["present"] == true && j["destructive_action_summary"]["plan_count"] == 1'

# handoff includes destructive_actions_summary
S4_HANDOFF_TASK="$TMPROOT/s4-handoff-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S4_HANDOFF_TASK" >/dev/null
S4_HANDOFF_EV="$TMPROOT/s4-handoff-evidence.json"
"$CLI" evidence init --output "$S4_HANDOFF_EV" >/dev/null
S4_HANDOFF_STATE="$TMPROOT/s4-handoff-state.yaml"
cp .orbit/loop-state.yaml "$S4_HANDOFF_STATE"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true)
   s["current_task"]=ARGV[1]; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=ARGV[2]
   s["phase"]="working"; s["status"]="working"
   File.write(p, YAML.dump(s))' \
  "$S4_HANDOFF_STATE" "$S4_HANDOFF_TASK" "$S4_HANDOFF_EV"
ORBIT_INSTANCE=lead "$CLI" handoff --task "$S4_HANDOFF_TASK" --state "$S4_HANDOFF_STATE" \
  --evidence "$S4_HANDOFF_EV" --json >"$TMPROOT/s4-handoff.json" 2>/dev/null || true
json_assert 'handoff includes destructive_actions_summary' \
  "$TMPROOT/s4-handoff.json" \
  'j.key?("destructive_actions_summary")'
json_assert 'handoff destructive_actions_summary present=false when no plan' \
  "$TMPROOT/s4-handoff.json" \
  'j["destructive_actions_summary"]["present"] == false'


# ---------------------------------------------------------------------------
# Regression: scope.exclude must block files even when scope.include is broad
# ---------------------------------------------------------------------------

S4_EXCL_TASK="$TMPROOT/s4-excl-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S4_EXCL_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["scope"]["include"]=["**/*"]; y["scope"]["exclude"]=[".orbit/**"]
   File.write(p, YAML.dump(y))' \
  "$S4_EXCL_TASK"
if "$CLI" validate --task "$S4_EXCL_TASK" --changed-files ".orbit/evidence.json" --json \
     >"$TMPROOT/s4-excl.json" 2>/dev/null; then
  printf 'FAIL validate rejects file matched by scope.include but excluded by scope.exclude: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects file matched by scope.include but excluded by scope.exclude'
json_assert 'scope.exclude error references task_file.scope.exclude source' \
  "$TMPROOT/s4-excl.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.scope.exclude" }'

# file not in exclude still passes
"$CLI" validate --task "$S4_EXCL_TASK" --changed-files "src/allowed.rb" --json \
  >"$TMPROOT/s4-excl-allowed.json" 2>/dev/null || true
json_assert 'validate passes file in scope.include that is not in scope.exclude' \
  "$TMPROOT/s4-excl-allowed.json" \
  'j["errors"].none? { |e| e["source"].include?("scope") }'

# ---------------------------------------------------------------------------
# Regression: destructive_action_plan without targets must be rejected
# ---------------------------------------------------------------------------

S4_NOTARGETS_EV="$TMPROOT/s4-notargets-evidence.json"
"$CLI" evidence init --output "$S4_NOTARGETS_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"No targets plan.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "identity"=>{"resolved_role"=>"lead"},
     "destructive_action_plan"=>{"action"=>"delete","dry_run"=>true}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_NOTARGETS_EV"
if "$CLI" validate --task "$S4_TASK" --evidence "$S4_NOTARGETS_EV" --json \
     >"$TMPROOT/s4-notargets.json" 2>/dev/null; then
  printf 'FAIL validate rejects destructive_action_plan with no targets field: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects destructive_action_plan with no targets field'
json_assert 'no-targets error references .targets source' \
  "$TMPROOT/s4-notargets.json" \
  'j["errors"].any? { |e| e["source"].include?(".targets") }'

S4_EMPTYTARGETS_EV="$TMPROOT/s4-emptytargets-evidence.json"
"$CLI" evidence init --output "$S4_EMPTYTARGETS_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Empty targets.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "identity"=>{"resolved_role"=>"lead"},
     "destructive_action_plan"=>{"action"=>"delete","dry_run"=>true,"targets"=>[]}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S4_EMPTYTARGETS_EV"
if "$CLI" validate --task "$S4_TASK" --evidence "$S4_EMPTYTARGETS_EV" --json \
     >"$TMPROOT/s4-emptytargets.json" 2>/dev/null; then
  printf 'FAIL validate rejects destructive_action_plan with empty targets array: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects destructive_action_plan with empty targets array'
json_assert 'empty-targets error references .targets source' \
  "$TMPROOT/s4-emptytargets.json" \
  'j["errors"].any? { |e| e["source"].include?(".targets") }'
