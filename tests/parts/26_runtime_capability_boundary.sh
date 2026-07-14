# ---------------------------------------------------------------------------
# Herdr public capability boundary: preview is real, trusted identity is not
# ---------------------------------------------------------------------------

BOUNDARY_PROJECT="$TMPROOT/runtime-capability-boundary-project"
BOUNDARY_FAKEBIN="$TMPROOT/runtime-capability-boundary-fakebin"
BOUNDARY_HERDR_LOG="$TMPROOT/runtime-capability-boundary-herdr.log"
BOUNDARY_ORIGINAL_DIR=$PWD
mkdir -p "$BOUNDARY_PROJECT" "$BOUNDARY_FAKEBIN"

cat >"$BOUNDARY_FAKEBIN/herdr" <<'HERDR'
#!/bin/sh
printf '%s\n' "$*" >>"$ORBIT_FAKE_HERDR_LOG"

if [ "$1" = "--version" ]; then
  printf 'herdr boundary fixture 1.0\n'
  exit 0
fi

case "$1 $2" in
  "orbit-proof status")
    # Deliberately advertise the removed imaginary contract. Orbit must never
    # call or trust this executable-controlled response.
    printf '{"schema_version":"orbit-runtime-proof-provider-status-v1","provider":"herdr","protocol":"orbit-runtime-proof-v1","controlled_issuance":true,"e2e":{"status":"pass","flow":["start","verified_identity","dispatch_ready","direct_dispatch","evidence_submit","wait_gate_ready"]}}\n'
    ;;
  "pane layout")
    printf '{"result":{"layout":{"tab_id":"lead-tab","workspace_id":"lead-workspace","panes":[{"pane_id":"lead-pane","focused":true,"rect":{"width":280,"height":60}}]}}}\n'
    ;;
  "agent list")
    ruby --disable-gems -rjson -e '
      project = ENV.fetch("ORBIT_FAKE_PROJECT")
      agents = %w[lead-main reviewer-main tester-main].map do |instance|
        {"pane_id"=>"preview-#{instance}", "agent"=>"codex", "agent_status"=>"idle", "cwd"=>project, "foreground_cwd"=>project}
      end
      puts JSON.generate({"result"=>{"agents"=>agents}})
    '
    ;;
  "agent start")
    printf '{"result":{"agent":{"pane_id":"preview-%s","agent":"codex"}}}\n' "$3"
    ;;
  "wait output")
    printf 'OpenAI Codex\n'
    ;;
  *)
    printf 'unexpected boundary fixture args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$BOUNDARY_FAKEBIN/herdr"

cd "$BOUNDARY_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB
"$CLI" init --operation-mode solo >/dev/null

env ORBIT_FAKE_PROJECT="$BOUNDARY_PROJECT" ORBIT_FAKE_HERDR_LOG="$BOUNDARY_HERDR_LOG" PATH="$BOUNDARY_FAKEBIN:$PATH" "$CLI" tools detect --json >capabilities.json
json_assert 'Herdr presence exposes automatic preview only' capabilities.json 'p=j["runtime_capabilities"]; p["mode"] == "automatic-preview" && p["automatic_start"] == "preview" && p["verified_identity"] == "unavailable" && p["direct_dispatch"] == "unavailable"'
json_assert 'capability report names the authenticated caller-pane gap' capabilities.json 'b=j.dig("runtime_capabilities", "identity_boundary"); b["schema_version"] == "orbit-herdr-runtime-identity-boundary-v1" && b["reason"] == "herdr_public_api_no_authenticated_caller_pane" && b["disabled_capabilities"].sort == ["direct.dispatch", "verified_identity"]'
json_assert 'Herdr detection never advertises direct dispatch' capabilities.json '!j["detected"].find { |tool| tool["name"] == "herdr" }["capabilities"].include?("direct.dispatch")'

env ORBIT_FAKE_PROJECT="$BOUNDARY_PROJECT" ORBIT_FAKE_HERDR_LOG="$BOUNDARY_HERDR_LOG" HERDR_SESSION_ID=preview-session HERDR_PANE_ID=lead-pane HERDR_TAB_ID=lead-tab HERDR_WORKSPACE_ID=lead-workspace PATH="$BOUNDARY_FAKEBIN:$PATH" "$CLI" start reviewer-main --json >reviewer-start.json
json_assert 'preview start creates only a pending runtime session' reviewer-start.json 's=j["runtime_session"]; j.dig("runtime_capabilities", "mode") == "automatic-preview" && s["state"] == "pending" && s.dig("identity", "verification") == "identity_pending" && !s.dig("identity").key?("proof_challenge")'
json_assert 'preview start directs the user to manual payload delivery' reviewer-start.json 'j["next"].any? { |step| step.key?("manual_payload") }'

BOUNDARY_SESSION=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "session_id")' reviewer-start.json)
BOUNDARY_LAUNCH=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "launch_id")' reviewer-start.json)
BOUNDARY_PANE=$(ruby --disable-gems -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("runtime_session", "herdr", "canonical_pane")' reviewer-start.json)

env ORBIT_FAKE_PROJECT="$BOUNDARY_PROJECT" ORBIT_FAKE_HERDR_LOG="$BOUNDARY_HERDR_LOG" ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$BOUNDARY_SESSION" ORBIT_LAUNCH_ID="$BOUNDARY_LAUNCH" HERDR_SESSION_ID=preview-session HERDR_PANE_ID="$BOUNDARY_PANE" PATH="$BOUNDARY_FAKEBIN:$PATH" "$CLI" runtime register --json >reviewer-register.json
json_assert 'preview registration remains pending and fail closed' reviewer-register.json 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j.dig("runtime_session", "state") == "pending" && j.dig("runtime_session", "identity", "verification") == "identity_pending"'
json_assert 'preview registration records the real trust boundary' reviewer-register.json 'j.dig("identity_boundary", "reason") == "herdr_public_api_no_authenticated_caller_pane" && j.dig("runtime_session", "identity", "identity_boundary", "status") == "unavailable" && !j.key?("trusted_caller_proof")'

if grep -q '^orbit-proof ' "$BOUNDARY_HERDR_LOG"; then
  printf 'FAIL Orbit invoked an Orbit-specific command on independent Herdr\n' >&2
  exit 1
fi
pass 'Orbit never invokes an Orbit-specific Herdr proof command'

expect_failure 'removed provider refresh command stays unavailable' env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID="$BOUNDARY_SESSION" ORBIT_LAUNCH_ID="$BOUNDARY_LAUNCH" HERDR_SESSION_ID=preview-session HERDR_PANE_ID="$BOUNDARY_PANE" PATH="$BOUNDARY_FAKEBIN:$PATH" "$CLI" runtime refresh-session --json

env ORBIT_FAKE_PROJECT="$BOUNDARY_PROJECT" ORBIT_FAKE_HERDR_LOG="$BOUNDARY_HERDR_LOG" PATH="$BOUNDARY_FAKEBIN:$PATH" "$CLI" instances status --json >preview-status.json
json_assert 'pending preview target never becomes dispatch ready' preview-status.json 'r=j["instances"].find { |entry| entry["instance"] == "reviewer-main" }; r["identity_verification"] == "pending" && r["dispatch_ready"] == false'

if grep -R -n 'orbit-proof' "$SKILL_ROOT/lib/orbit" >/dev/null; then
  printf 'FAIL production Orbit code still contains the imaginary Herdr command\n' >&2
  exit 1
fi
pass 'production runtime contains no orbit-proof dependency'

cd "$BOUNDARY_ORIGINAL_DIR"
