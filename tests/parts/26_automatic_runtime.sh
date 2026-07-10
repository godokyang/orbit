# ---------------------------------------------------------------------------
# Trusted provider handshake and complete automatic runtime E2E
# ---------------------------------------------------------------------------

AUTO_PROJECT="$TMPROOT/automatic-runtime-project"
AUTO_FAKEBIN="$TMPROOT/automatic-runtime-fakebin"
AUTO_PROOF_REGISTRY="$TMPROOT/automatic-runtime-proofs"
AUTO_DISPATCH_LOG="$TMPROOT/automatic-runtime-dispatch.log"
mkdir -p "$AUTO_PROJECT" "$AUTO_FAKEBIN" "$AUTO_PROOF_REGISTRY"
AUTO_ORIGINAL_DIR=$PWD

cat >"$AUTO_FAKEBIN/herdr" <<'HERDR'
#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'herdr automatic fixture 1.0\n'
  exit 0
fi

case "$1 $2" in
  "orbit-proof status")
    ruby --disable-gems -rjson -e '
      status = ENV["ORBIT_FAKE_PROOF_MODE"] == "e2e_fail" ? "fail" : "pass"
      puts JSON.generate({
        "schema_version"=>"orbit-runtime-proof-provider-status-v1",
        "provider"=>"herdr",
        "provider_version"=>"fixture-v1",
        "protocol"=>"orbit-runtime-proof-v1",
        "controlled_issuance"=>true,
        "e2e"=>{
          "status"=>status,
          "flow"=>%w[start verified_identity dispatch_ready direct_dispatch evidence_submit wait_gate_ready]
        }
      })
    '
    ;;
  "orbit-proof prove")
    ruby --disable-gems -rjson -rfileutils -e '
      challenge = JSON.parse(ARGV[0])
      registry = ARGV[1]
      mode = ENV["ORBIT_FAKE_PROOF_MODE"].to_s
      fields = %w[nonce session_id launch_id project_root_sha256 role_config_sha256 instance_config_sha256 instance role canonical_pane issued_at expires_at]
      proof = {"schema_version"=>"orbit-runtime-proof-v1", "provider"=>"herdr"}
      fields.each { |field| proof[field] = challenge[field] }
      proof["proof_id"] = "fixture-proof-#{challenge["nonce"]}"
      proof["nonce"] = "wrong-nonce" if mode == "nonce_mismatch"
      proof["project_root_sha256"] = "0" * 64 if mode == "project_mismatch"
      proof["instance_config_sha256"] = "f" * 64 if mode == "instance_mismatch"
      FileUtils.mkdir_p(registry)
      File.write(File.join(registry, "#{proof["proof_id"]}.json"), JSON.pretty_generate(proof) + "\n")
      puts JSON.generate(proof)
    ' "$4" "$ORBIT_FAKE_PROOF_REGISTRY"
    ;;
  "orbit-proof verify")
    ruby --disable-gems -rjson -e '
      proof = JSON.parse(ARGV[0])
      path = File.join(ARGV[1], "#{proof["proof_id"]}.json")
      valid = ENV["ORBIT_FAKE_PROOF_MODE"].to_s != "verify_fail" && File.file?(path) && JSON.parse(File.read(path)) == proof
      puts JSON.generate({"valid"=>valid, "provider"=>"herdr", "proof_id"=>proof["proof_id"]})
    ' "$4" "$ORBIT_FAKE_PROOF_REGISTRY"
    ;;
  "pane layout")
    printf '{"result":{"layout":{"tab_id":"lead-tab","workspace_id":"lead-workspace","panes":[{"pane_id":"lead-proof-pane","focused":true,"rect":{"width":280,"height":60}}]}}}\n'
    ;;
  "agent list")
    ruby --disable-gems -rjson -e '
      project = ENV.fetch("ORBIT_FAKE_PROJECT")
      status = ENV.fetch("ORBIT_FAKE_AGENT_STATUS", "idle")
      agents = %w[lead-main reviewer-main tester-main].map do |instance|
        {"pane_id"=>"proof-#{instance}", "agent"=>"codex", "agent_status"=>status, "cwd"=>project, "foreground_cwd"=>project}
      end
      puts JSON.generate({"result"=>{"agents"=>agents}})
    '
    ;;
  "agent start")
    printf '{"result":{"agent":{"pane_id":"proof-%s","agent":"codex"}}}\n' "$3"
    ;;
  "wait output")
    printf 'OpenAI Codex\n'
    ;;
  "pane run")
    printf '%s\n' "$3" >>"$ORBIT_FAKE_DISPATCH_LOG"
    printf 'sent\n'
    ;;
  *)
    printf 'unexpected automatic fixture args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$AUTO_FAKEBIN/herdr"

cd "$AUTO_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB
"$CLI" init --operation-mode solo >/dev/null
mkdir -p .orbit/tasks
"$CLI" task draft --task-type implementation --output .orbit/tasks/automatic.yaml >/dev/null
ruby --disable-gems -ryaml -e '
  path=ARGV[0]; task=YAML.safe_load(File.read(path), aliases:true)
  task["gates"] << {"kind"=>"test", "roles"=>["tester"], "required"=>true, "pass_condition"=>"provider E2E test passes"}
  task["test_level"]="repo_regression"
  File.write(path, YAML.dump(task))
' .orbit/tasks/automatic.yaml
make_task_execution_ready .orbit/tasks/automatic.yaml
ORBIT_INSTANCE=lead-main "$CLI" task start --task .orbit/tasks/automatic.yaml >/dev/null
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file .orbit/evidence/automatic.json --kind implementation --status pass --summary 'Automatic runtime fixture implementation.' --task .orbit/tasks/automatic.yaml --changed-file lib/automatic-fixture.rb --verification 'fixture prepared' >/dev/null

env ORBIT_FAKE_PROOF_MODE=e2e_fail ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" tools detect --json >automatic-preview.json
json_assert 'provider without passing E2E remains automatic preview' automatic-preview.json 'j.dig("runtime_capabilities", "mode") == "automatic-preview" && j.dig("runtime_capabilities", "direct_dispatch") == "unavailable"'

env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" tools detect --json >automatic-capabilities.json
json_assert 'trusted provider with complete E2E enables automatic capability' automatic-capabilities.json 'j.dig("runtime_capabilities", "mode") == "automatic" && j.dig("runtime_capabilities", "trusted_proof_provider") == "available" && j.dig("runtime_capabilities", "provider_e2e") == "pass" && j.dig("runtime_capabilities", "direct_dispatch") == "available" && j["detected"].find { |t| t["name"] == "herdr" }["capabilities"].include?("direct.dispatch")'

auto_start_and_register() {
  local instance="$1"
  local role="$2"
  local start_json="$3"
  local register_json="$4"
  env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" HERDR_SESSION_ID=proof-session HERDR_PANE_ID=lead-proof-pane HERDR_TAB_ID=lead-tab HERDR_WORKSPACE_ID=lead-workspace PATH="$AUTO_FAKEBIN:$PATH" "$CLI" start "$instance" --json >"$start_json"
  local session_id launch_id pane
  session_id=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "session_id")' "$start_json")
  launch_id=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "launch_id")' "$start_json")
  pane=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "herdr", "canonical_pane")' "$start_json")
  env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE="$instance" ORBIT_ROLE="$role" ORBIT_SESSION_ID="$session_id" ORBIT_LAUNCH_ID="$launch_id" HERDR_SESSION_ID=proof-session HERDR_PANE_ID="$pane" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime register --json >"$register_json"
}

auto_start_and_register reviewer-main reviewer reviewer-start.json reviewer-register.json
json_assert 'start issues a one-time short-TTL identity challenge' reviewer-start.json 'c=j.dig("runtime_session", "identity", "proof_challenge"); j.dig("runtime_capabilities", "mode") == "automatic" && c["schema_version"] == "orbit-runtime-proof-challenge-v1" && c["nonce"].match?(/\A[0-9a-f]{48}\z/) && c["ttl_seconds"] == 60 && c["project_root_sha256"].match?(/\A[0-9a-f]{64}\z/) && c["instance_config_sha256"].match?(/\A[0-9a-f]{64}\z/)'
json_assert 'provider proof promotes reviewer identity and dispatch readiness' reviewer-register.json 'j["identity_verification"] == "verified" && j["dispatch_ready"] == true && j.dig("runtime_session", "state") == "active" && j.dig("runtime_session", "identity", "verification") == "herdr_verified" && j.dig("trusted_caller_proof", "verified") == true'

REVIEW_SESSION=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["session_id"]' reviewer-register.json)
REVIEW_LAUNCH=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "launch_id")' reviewer-register.json)
OLD_REVIEW_HEARTBEAT=$(ruby --disable-gems -rjson -rtime -e 'p=ARGV[0]; s=JSON.parse(File.read(p)); old=(Time.now.utc-240).iso8601; s["heartbeat"]["last_seen_at"]=old; File.write(p, JSON.pretty_generate(s)+"\n"); puts old' ".orbit/runtime/sessions/$REVIEW_SESSION.json")
env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$REVIEW_SESSION" ORBIT_LAUNCH_ID="$REVIEW_LAUNCH" HERDR_SESSION_ID=proof-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" whoami --json >reviewer-heartbeat.json
json_assert 'verified commands refresh session heartbeat without replaying the challenge' ".orbit/runtime/sessions/$REVIEW_SESSION.json" 'j.dig("heartbeat", "last_seen_at") != ARGV[2] && j.dig("identity", "proof_challenge", "used_proof_id") == j.dig("identity", "trusted_caller_proof", "proof_id")' "$OLD_REVIEW_HEARTBEAT"
ruby --disable-gems -rjson -rtime -e 'p=ARGV[0]; s=JSON.parse(File.read(p)); a=s.dig("identity", "trusted_caller_proof"); a["attestation_issued_at"]=(Time.now.utc-600).iso8601; a["attestation_expires_at"]=(Time.now.utc-300).iso8601; s["heartbeat"]["last_seen_at"]=Time.now.utc.iso8601; File.write(p, JSON.pretty_generate(s)+"\n")' ".orbit/runtime/sessions/$REVIEW_SESSION.json"
env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" instances status --json >expired-attestation-status.json
json_assert 'stored provider proof cannot remain trusted after local attestation expiry' expired-attestation-status.json 'r=j["instances"].find { |i| i["instance"] == "reviewer-main" }; r["identity_verification"] == "mismatch" && r["dispatch_ready"] == false'
env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$REVIEW_SESSION" ORBIT_LAUNCH_ID="$REVIEW_LAUNCH" HERDR_SESSION_ID=proof-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime refresh-session --json >reviewer-refresh.json
json_assert 'controlled refresh exchanges a new challenge for an active session attestation' reviewer-refresh.json 'j["schema_version"] == "orbit-runtime-refresh-v1" && j["identity_verification"] == "verified" && j["dispatch_ready"] == true && j.dig("trusted_caller_proof", "attestation_expires_at").match?(/Z\z/) && j.dig("trusted_caller_proof", "credential_type") == "renewable_session_attestation"'
if env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$REVIEW_SESSION" ORBIT_LAUNCH_ID="$REVIEW_LAUNCH" HERDR_SESSION_ID=proof-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime register --json >replay.json 2>replay.err; then
  printf 'FAIL consumed provider challenge was replayed\n' >&2
  exit 1
fi
pass 'provider challenge is one-time and rejects replay'

auto_start_and_register tester-main tester tester-start.json tester-register.json
TEST_SESSION=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["session_id"]' tester-register.json)
TEST_LAUNCH=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "launch_id")' tester-register.json)
json_assert 'provider proof promotes tester identity and dispatch readiness' tester-register.json 'j["identity_verification"] == "verified" && j["dispatch_ready"] == true && j.dig("trusted_caller_proof", "proof_id").start_with?("fixture-proof-")'

env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" dispatch --task .orbit/tasks/automatic.yaml --to reviewer-main --reply-to lead-proof-pane --json >reviewer-dispatch.json
env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" dispatch --task .orbit/tasks/automatic.yaml --to tester-main --reply-to lead-proof-pane --json >tester-dispatch.json
json_assert 'verified reviewer receives direct Herdr dispatch' reviewer-dispatch.json 'j["action"] == "sent" && j.dig("delivery", "mode") == "herdr_direct" && j.dig("target_runtime_resolution", "dispatch_ready") == true && j.dig("adapter_result", "success") == true'
json_assert 'verified tester receives direct Herdr dispatch' tester-dispatch.json 'j["action"] == "sent" && j.dig("target_runtime_resolution", "identity_verification") == "verified" && j.dig("adapter_result", "success") == true'
test "$(wc -l <"$AUTO_DISPATCH_LOG" | tr -d ' ')" -ge 2
pass 'automatic provider E2E executes real direct dispatch adapter calls'

write_review_pass_report automatic-review.yaml 'Automatic provider reviewer pass.' 'herdr:reviewer:automatic-provider'
env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$REVIEW_SESSION" ORBIT_LAUNCH_ID="$REVIEW_LAUNCH" HERDR_SESSION_ID=proof-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" evidence submit --file .orbit/evidence/automatic.json --report automatic-review.yaml --task .orbit/tasks/automatic.yaml --json >automatic-review-submit.json
write_test_pass_report automatic-test.yaml 'Automatic provider tester pass.' 'herdr:tester:automatic-provider'
env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=tester-main ORBIT_ROLE=tester ORBIT_SESSION_ID="$TEST_SESSION" ORBIT_LAUNCH_ID="$TEST_LAUNCH" HERDR_SESSION_ID=proof-session HERDR_PANE_ID=proof-tester-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" evidence submit --file .orbit/evidence/automatic.json --report automatic-test.yaml --task .orbit/tasks/automatic.yaml --json >automatic-test-submit.json
json_assert 'review evidence carries provider-verifiable Herdr identity' automatic-review-submit.json 'r=j["record"]; r.dig("runtime_identity", "verification") == "herdr_verified" && r.dig("runtime_identity", "proof_id").start_with?("fixture-proof-") && r.dig("runtime_identity", "instance") == "reviewer-main"'
json_assert 'test evidence carries provider-verifiable Herdr identity' automatic-test-submit.json 'r=j["record"]; r.dig("runtime_identity", "verification") == "herdr_verified" && r.dig("runtime_identity", "instance") == "tester-main"'

env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" wait-gate --task .orbit/tasks/automatic.yaml --evidence .orbit/evidence/automatic.json --json >automatic-gate.json
json_assert 'provider-backed review and test evidence close the complete gate E2E' automatic-gate.json 'j["ready"] == true && j.dig("gate_summary", "passed").sort == ["review", "test"]'

auto_start_and_register lead-main lead lead-start.json lead-register.json
LEAD_SESSION=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["session_id"]' lead-register.json)
LEAD_LAUNCH=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "launch_id")' lead-register.json)
env ORBIT_FAKE_AGENT_STATUS=done ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID="$LEAD_SESSION" ORBIT_LAUNCH_ID="$LEAD_LAUNCH" HERDR_SESSION_ID=proof-session HERDR_PANE_ID=proof-lead-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime ack-session reviewer-main --json >automatic-ack.json
json_assert 'provider-verified owner acknowledgment makes a done target reusable' automatic-ack.json 'j["action"] == "acknowledged" && j["ack_written"] == true && j["dispatch_ready"] == true && j.dig("runtime_resolution", "availability") == "available"'

REVIEW_PROOF_ID=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("trusted_caller_proof", "proof_id")' reviewer-refresh.json)
rm "$AUTO_PROOF_REGISTRY/$REVIEW_PROOF_ID.json"
env ORBIT_FAKE_PROJECT="$AUTO_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" PATH="$AUTO_FAKEBIN:$PATH" "$CLI" instances status --json >provider-revoked.json
json_assert 'resolver fails closed when provider can no longer verify a stored proof' provider-revoked.json 'r=j["instances"].find { |i| i["instance"] == "reviewer-main" }; r["dispatch_ready"] == false && r["identity_verification"] == "mismatch"'

AUTO_NEG_PROJECT="$TMPROOT/automatic-runtime-negative-project"
mkdir -p "$AUTO_NEG_PROJECT"
cd "$AUTO_NEG_PROJECT"
"$CLI" init --operation-mode solo >/dev/null
env ORBIT_FAKE_PROJECT="$AUTO_NEG_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" HERDR_SESSION_ID=negative-session HERDR_PANE_ID=lead-proof-pane HERDR_TAB_ID=lead-tab PATH="$AUTO_FAKEBIN:$PATH" "$CLI" start reviewer-main --json >negative-start.json
NEG_SESSION=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "session_id")' negative-start.json)
NEG_LAUNCH=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "launch_id")' negative-start.json)
env ORBIT_FAKE_PROOF_MODE=nonce_mismatch ORBIT_FAKE_PROJECT="$AUTO_NEG_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$NEG_SESSION" ORBIT_LAUNCH_ID="$NEG_LAUNCH" HERDR_SESSION_ID=negative-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime register --json >nonce-mismatch.json
json_assert 'nonce mismatch cannot promote pending identity' nonce-mismatch.json 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j.dig("trusted_caller_proof", "verified") == false && j.dig("trusted_caller_proof", "reason") == "proof_nonce_mismatch"'
env ORBIT_FAKE_PROOF_MODE=project_mismatch ORBIT_FAKE_PROJECT="$AUTO_NEG_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$NEG_SESSION" ORBIT_LAUNCH_ID="$NEG_LAUNCH" HERDR_SESSION_ID=negative-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime register --json >project-mismatch.json
json_assert 'project hash mismatch cannot promote pending identity' project-mismatch.json 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j.dig("trusted_caller_proof", "reason") == "proof_project_root_sha256_mismatch"'
env ORBIT_FAKE_PROOF_MODE=instance_mismatch ORBIT_FAKE_PROJECT="$AUTO_NEG_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$NEG_SESSION" ORBIT_LAUNCH_ID="$NEG_LAUNCH" HERDR_SESSION_ID=negative-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime register --json >instance-mismatch.json
json_assert 'instance hash mismatch cannot promote pending identity' instance-mismatch.json 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j.dig("trusted_caller_proof", "reason") == "proof_instance_config_sha256_mismatch"'
ruby --disable-gems -rjson -rtime -e '
  path=ARGV[0]; s=JSON.parse(File.read(path)); issued=Time.now.utc-120; s["identity"]["proof_challenge"]["issued_at"]=issued.iso8601; s["identity"]["proof_challenge"]["expires_at"]=(issued+60).iso8601; File.write(path, JSON.pretty_generate(s)+"\n")
' ".orbit/runtime/sessions/$NEG_SESSION.json"
env ORBIT_FAKE_PROJECT="$AUTO_NEG_PROJECT" ORBIT_FAKE_PROOF_REGISTRY="$AUTO_PROOF_REGISTRY" ORBIT_FAKE_DISPATCH_LOG="$AUTO_DISPATCH_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$NEG_SESSION" ORBIT_LAUNCH_ID="$NEG_LAUNCH" HERDR_SESSION_ID=negative-session HERDR_PANE_ID=proof-reviewer-main PATH="$AUTO_FAKEBIN:$PATH" "$CLI" runtime register --json >expired-proof.json
json_assert 'expired challenge cannot promote pending identity' expired-proof.json 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j.dig("trusted_caller_proof", "reason") == "proof_challenge_expired"'

cd "$AUTO_ORIGINAL_DIR"
