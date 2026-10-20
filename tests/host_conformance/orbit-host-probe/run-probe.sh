#!/bin/sh
# Orbit DSH host T1 probe. Boots an isolated DSH_HOME, loads the built host
# plugin and a scripted fake-model driver, then drives the `orbit` tool.
# Needs the desktop DSH CLI (0.2.1-rc.2) and a built packages/dsh-host.
set -eu
PROBE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO=$(CDPATH= cd -- "$PROBE_DIR/../../.." && pwd -P)
DSH_HOME=${DSH_HOME:-/tmp/orbit-host-probe}
export DSH_HOME
PROFILE=${PROFILE:-orbit-t1}
DSH_BIN=${DSH_BIN:-/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh}
DSH_CLI_JS=${DSH_CLI_JS:-/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js}
CHECKER_HOME="${DSH_HOME}-checker"
HOST_DIST="$REPO/packages/dsh-host/dist/index.mjs"
CLI_DIST="$REPO/packages/cli/dist/cli.mjs"

[ -f "$HOST_DIST" ] || { echo "missing $HOST_DIST; run pnpm --filter @orbit/dsh-host build" >&2; exit 1; }
[ -f "$CLI_DIST" ] || { echo "missing $CLI_DIST; run pnpm --filter @orbit/cli build" >&2; exit 1; }
mkdir -p "$DSH_HOME/results"
rm -rf "$DSH_HOME/project"

if [ ! -f "$DSH_HOME/profiles/$PROFILE/package.json" ]; then
  "$DSH_BIN" --profile "$PROFILE" --from-default-profile sdk --dump-config > /dev/null
fi
if [ ! -d "$DSH_HOME/profiles/$PROFILE/node_modules/@deepseek-ai/dsh-subagent-dsh-sdk" ]; then
  echo "missing dsh-sdk provider; run: DSH_HOME=$DSH_HOME dsh plugin --profile $PROFILE add @deepseek-ai/dsh-subagent-dsh-sdk@0.2.1-rc.2 @deepseek-ai/dsh-sdk-client@0.2.1-rc.2" >&2
  exit 1
fi
mkdir -p "$CHECKER_HOME"
if [ ! -f "$CHECKER_HOME/profiles/orbit-checker/package.json" ]; then
  DSH_HOME="$CHECKER_HOME" "$DSH_BIN" --profile orbit-checker --from-default-profile sdk --dump-config > /dev/null
fi

HOST_RUN="$DSH_HOME/profiles/$PROFILE/orbit-host"
PROBE_RUN="$DSH_HOME/profiles/$PROFILE/orbit-host-probe"
mkdir -p "$HOST_RUN" "$PROBE_RUN"
cp "$HOST_DIST" "$HOST_RUN/index.mjs"
printf '{"type":"module"}\n' > "$HOST_RUN/package.json"
cp "$PROBE_DIR/index.js" "$PROBE_RUN/index.js"
printf '{"type":"module"}\n' > "$PROBE_RUN/package.json"

CHILD_RUN="$CHECKER_HOME/profiles/orbit-checker/orbit-checker-probe"
mkdir -p "$CHILD_RUN"
cp "$PROBE_DIR/checker-child.js" "$CHILD_RUN/index.js"
printf '{"type":"module"}\n' > "$CHILD_RUN/package.json"
cat > "$CHECKER_HOME/child.patch.yml" <<EOF
- insert:
    - id: orbit-checker-probe
      name: '$CHILD_RUN/index.js'
- id: session-log-deepseek
  disabled: true
EOF

cat > "$DSH_HOME/probe.patch.yml" <<EOF
- insert:
    - id: orbit-host
      name: '$HOST_RUN/index.mjs'
    - id: orbit-host-probe
      name: '$PROBE_RUN/index.js'
    - id: subagent-dsh-sdk
      name: '@deepseek-ai/dsh-subagent-dsh-sdk'
      config:
        dshBin: '$DSH_CLI_JS'
        profile: orbit-checker
        dshHome: '$CHECKER_HOME'
        patches:
          - '$CHECKER_HOME/child.patch.yml'
        provider: probe
        model: probe-1
        env:
          ELECTRON_RUN_AS_NODE: '1'
EOF

OUT="$DSH_HOME/results/orbit-host.out"
rm -f "$OUT" "$DSH_HOME/results/orbit-host.stdout" "$DSH_HOME/results/orbit-host.log"
export ORBIT_PROBE_OUT="$OUT"
export ORBIT_CLI="$CLI_DIST"

( cd "$DSH_HOME" && sleep 120 | "$DSH_BIN" --profile "$PROFILE" --patch "$DSH_HOME/probe.patch.yml" \
    > "$DSH_HOME/results/orbit-host.stdout" 2> "$DSH_HOME/results/orbit-host.log" ) &
PID=$!
i=0
while [ $i -lt 100 ]; do
  sleep 1; i=$((i+1))
  kill -0 $PID 2>/dev/null || break
  grep -q '"phase":"done"\|"phase":"error"' "$OUT" 2>/dev/null && { sleep 2; break; }
done
pkill -f "dsh --profile $PROFILE" 2>/dev/null || true
pkill -f "sleep 120" 2>/dev/null || true
echo "=== orbit-host probe ==="
cat "$OUT" 2>/dev/null || true
echo "=== stderr tail ==="
grep -vE "MODULE_TYPELESS|Reparsing|To eliminate|trace-warnings" "$DSH_HOME/results/orbit-host.log" 2>/dev/null | tail -20 || true
