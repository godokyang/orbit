#!/bin/sh
# Orbit DSH host probes. Needs: DSH 0.2.1-rc.2 `dsh` on PATH (desktop CLI), Node 24.
# Usage: DSH_HOME=/tmp/orbit-dsh-probe ./run-probe.sh <probe> [more probes...]
# Probes: smoke p7-credentials p1-registration p2-toolgate p3-projection p4-archive p5-answerer
#         s1-stop-member s2-stop-job s3-s5-fence s4-resume-fence s6-kill-host s6-after p6-checker
set -u
PROBE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
: "${DSH_HOME:?set DSH_HOME to an isolated directory}"
export DSH_HOME
CHECKER_HOME="$DSH_HOME-checker"
DSH_CLI_JS="${DSH_CLI_JS:-/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js}"
mkdir -p "$DSH_HOME/results" "$CHECKER_HOME"
[ -f "$DSH_HOME/profiles/orbit-probe/package.json" ] || dsh --profile orbit-probe --from-default-profile sdk --dump-config > /dev/null
[ -f "$CHECKER_HOME/profiles/orbit-checker/package.json" ] || DSH_HOME="$CHECKER_HOME" dsh --profile orbit-checker --from-default-profile sdk --dump-config > /dev/null
# A plugin outside a profile directory cannot resolve @deepseek-ai/* packages; run from a copy inside the profile.
PROBE_RUN="$DSH_HOME/profiles/orbit-probe/probe"
mkdir -p "$PROBE_RUN" && cp "$PROBE_DIR/index.js" "$PROBE_DIR/package.json" "$PROBE_RUN/"
sed -e "s#__PROBE_DIR__#$PROBE_RUN#g" -e "s#__DSH_HOME__#$DSH_HOME#g" -e "s#__CHECKER_HOME__#$CHECKER_HOME#g" -e "s#__DSH_CLI_JS__#$DSH_CLI_JS#g" "$PROBE_DIR/probe.patch.yml.tmpl" > "$DSH_HOME/probe.patch.yml"
sed -e "s#__PROBE_DIR__#$PROBE_RUN#g" "$PROBE_DIR/child.patch.yml.tmpl" > "$CHECKER_HOME/child.patch.yml"
for PROBE in "$@"; do
  export ORBIT_PROBE="$PROBE" ORBIT_PROBE_OUT="$DSH_HOME/results/$PROBE.out"
  rm -f "$ORBIT_PROBE_OUT"
  ( cd "$DSH_HOME" && sleep 180 | dsh --profile orbit-probe --patch "$DSH_HOME/probe.patch.yml" > "$DSH_HOME/results/$PROBE.stdout" 2> "$DSH_HOME/results/$PROBE.log" ) &
  PID=$!; i=0
  while [ $i -lt 170 ]; do
    sleep 1; i=$((i+1))
    kill -0 $PID 2>/dev/null || break
    grep -q '"phase":"done"\|"phase":"error"' "$ORBIT_PROBE_OUT" 2>/dev/null && { sleep 4; break; }
  done
  pkill -f "dsh --profile orbit-probe" 2>/dev/null; pkill -f "sleep 180" 2>/dev/null
  echo "=== $PROBE ==="; cat "$ORBIT_PROBE_OUT" 2>/dev/null | cut -c1-1500
  grep -vE "MODULE_TYPELESS|Reparsing|To eliminate|trace-warnings" "$DSH_HOME/results/$PROBE.log" | tail -5
done
