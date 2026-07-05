ruby --disable-gems -c "$CLI"
pass 'script syntax'

ruby --disable-gems -c "$SKILL_ROOT/lib/orbit/cli.rb"
ruby --disable-gems -c "$SKILL_ROOT/lib/orbit/runtime_store.rb"
ruby --disable-gems -c "$SKILL_ROOT/lib/orbit/herdr_probe.rb"
ruby --disable-gems -c "$SKILL_ROOT/lib/orbit/runtime_resolver.rb"
ruby --disable-gems -c "$SKILL_ROOT/lib/orbit/runtime_commands.rb"
pass 'runtime module syntax'

test -x "$CLI"
pass 'script executable'

EXPECTED_VERSION=$(ruby --disable-gems -rjson -e 'print JSON.parse(File.read(File.join(ARGV[0], "package.json"))).fetch("version")' "$SKILL_ROOT")

mkdir -p "$TMPROOT/install-no-herdr-bin"
cat >"$TMPROOT/install-no-herdr-bin/ruby" <<'RUBY'
#!/usr/bin/env sh
printf 'ruby fake\n'
RUBY
chmod +x "$TMPROOT/install-no-herdr-bin/ruby"
if PATH="$TMPROOT/install-no-herdr-bin" /bin/sh "$SKILL_ROOT/install.sh" --bin-dir "$TMPROOT/install-no-herdr-out-bin" --runtime-dir "$TMPROOT/install-no-herdr-runtime" >"$TMPROOT/install-no-herdr.out" 2>"$TMPROOT/install-no-herdr.err"; then
  printf 'FAIL installer without herdr: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'Herdr is required for Orbit automatic runtime' "$TMPROOT/install-no-herdr.err"
pass 'installer fails clearly when Herdr is absent'

mkdir -p "$TMPROOT/install-bad-herdr-bin"
cat >"$TMPROOT/install-bad-herdr-bin/ruby" <<'RUBY'
#!/usr/bin/env sh
printf 'ruby fake\n'
RUBY
cat >"$TMPROOT/install-bad-herdr-bin/herdr" <<'HERDR'
#!/usr/bin/env sh
exit 42
HERDR
chmod +x "$TMPROOT/install-bad-herdr-bin/ruby" "$TMPROOT/install-bad-herdr-bin/herdr"
if PATH="$TMPROOT/install-bad-herdr-bin" /bin/sh "$SKILL_ROOT/install.sh" --bin-dir "$TMPROOT/install-bad-herdr-out-bin" --runtime-dir "$TMPROOT/install-bad-herdr-runtime" >"$TMPROOT/install-bad-herdr.out" 2>"$TMPROOT/install-bad-herdr.err"; then
  printf 'FAIL installer with bad herdr: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'Herdr was found but `herdr --version` failed' "$TMPROOT/install-bad-herdr.err"
pass 'installer fails when Herdr version check fails'

mkdir -p "$TMPROOT/install-fakebin"
cat >"$TMPROOT/install-fakebin/herdr" <<'HERDR'
#!/usr/bin/env sh
case "$1" in
  --version) printf 'herdr fake\n' ;;
  *) printf '{"agents":[]}\n' ;;
esac
HERDR
chmod +x "$TMPROOT/install-fakebin/herdr"
PATH="$TMPROOT/install-fakebin:$PATH"

"$SKILL_ROOT/install.sh" --help >"$TMPROOT/install-help.txt" 2>"$TMPROOT/install-help.err"
test ! -s "$TMPROOT/install-help.err"
! grep -qiE -- 'token|github-token|private|Authorization|Bearer|--key' "$TMPROOT/install-help.txt"
pass 'installer help omits private repository token options'

INSTALL_BIN="$TMPROOT/install-bin"
INSTALL_RUNTIME="$TMPROOT/install-runtime"
sh "$SKILL_ROOT/install.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/install.out" 2>"$TMPROOT/install.err"
test ! -s "$TMPROOT/install.err"
grep -q 'orbit install: installing Orbit CLI' "$TMPROOT/install.out"
grep -q 'orbit install: copying runtime files' "$TMPROOT/install.out"
grep -q 'orbit install: verifying installed orbit command' "$TMPROOT/install.out"
test -x "$INSTALL_BIN/orbit"
test -x "$INSTALL_RUNTIME/scripts/orbit"
test -f "$INSTALL_RUNTIME/package.json"
test -f "$INSTALL_RUNTIME/skills/orbit/SKILL.md"
test -f "$INSTALL_RUNTIME/skills/orbit/references/runtime/guide.md"
test -f "$INSTALL_RUNTIME/skills/orbit/references/runtime/core-operating-model.md"
test -f "$INSTALL_RUNTIME/skills/orbit/references/runtime/coding-guideline.md"
test -f "$INSTALL_RUNTIME/skills/orbit/references/runtime/quality-outcome-and-review.md"
test -f "$INSTALL_RUNTIME/skills/orbit/references/runtime/testing-guideline.md"
test -f "$INSTALL_RUNTIME/skills/orbit/assets/templates/review-report.yaml"
test -f "$INSTALL_RUNTIME/skills/orbit/assets/templates/design-review-report.yaml"
test -f "$INSTALL_RUNTIME/skills/orbit/assets/templates/test-report.yaml"
"$INSTALL_BIN/orbit" version >"$TMPROOT/installed-version.txt"
grep -qx "$EXPECTED_VERSION" "$TMPROOT/installed-version.txt"
pass 'installer creates runnable orbit command'

test ! -e "$SKILL_ROOT/SKILL.md"
test -f "$SKILL_ROOT/skills/orbit/SKILL.md"
test -f "$SKILL_ROOT/skills/orbit/references/overview.md"
test -f "$SKILL_ROOT/skills/orbit/references/runtime/guide.md"
test -f "$SKILL_ROOT/skills/orbit/references/runtime/core-operating-model.md"
test -f "$SKILL_ROOT/skills/orbit/references/runtime/coding-guideline.md"
test -f "$SKILL_ROOT/skills/orbit/references/runtime/quality-outcome-and-review.md"
test -f "$SKILL_ROOT/skills/orbit/references/runtime/testing-guideline.md"
test -f "$SKILL_ROOT/skills/orbit/assets/templates/task.yaml"
test -f "$SKILL_ROOT/skills/orbit/assets/templates/review-report.yaml"
! grep -q 'internal: true' "$SKILL_ROOT/skills/orbit/SKILL.md"
pass 'public npx skill package includes referenced resources'

ruby --disable-gems -rjson - "$SKILL_ROOT" <<'RUBY'
root = ARGV.fetch(0)
package = JSON.parse(File.read(File.join(root, "package.json")))
files = package.fetch("files")
abort("package.json must include skills/orbit") unless files.include?("skills/orbit")
%w[SKILL.md assets references].each do |legacy|
  abort("package.json must not include legacy root skill path: #{legacy}") if files.include?(legacy)
end
RUBY
pass 'npm package manifest publishes skills/orbit instead of legacy root skill paths'

ruby --disable-gems - "$SKILL_ROOT" <<'RUBY'
root = ARGV.fetch(0)
install_script = File.read(File.join(root, "install.sh"))
runtime_manifest = install_script[/runtime_files="\n(.*?)\n"/m, 1].to_s.lines.map(&:strip).reject(&:empty?)
abort("install.sh runtime_files manifest was not found") if runtime_manifest.empty?
skill_files = Dir.chdir(root) { Dir["skills/orbit/**/*"].select { |path| File.file?(path) }.sort }
missing = skill_files - runtime_manifest
legacy = runtime_manifest.select { |path| path == "SKILL.md" || path.start_with?("assets/") || path.start_with?("references/") }
abort("install.sh runtime_files missing skill resources: #{missing.join(", ")}") unless missing.empty?
abort("install.sh runtime_files still includes legacy root skill paths: #{legacy.join(", ")}") unless legacy.empty?
RUBY
pass 'installer runtime manifest includes every packaged skill resource'

ruby --disable-gems - "$SKILL_ROOT" <<'RUBY'
root = ARGV.fetch(0)
skill_root = File.join(root, "skills", "orbit")
missing = []

Dir[File.join(skill_root, "**/*.md")].each do |file|
  File.read(file).scan(/\[[^\]]+\]\(([^)]+)\)/) do |match|
    href = match.fetch(0).split(/[ #]/, 2).first
    next if href.nil? || href.empty? || href =~ %r{\A(?:https?:|mailto:|#)}

    target = File.expand_path(href, File.dirname(file))
    missing << "#{file.delete_prefix(root + "/")}: #{href}" unless File.exist?(target)
  end
end

Dir[File.join(skill_root, "**/*.{md,yaml,json}")].each do |file|
  text = File.read(file)
  text.scan(%r{(?:references/runtime|references|assets/templates)/[A-Za-z0-9_.\-/]+|SKILL\.md}) do |ref|
    next if ref == "SKILL.md"

    target = File.join(skill_root, ref)
    missing << "#{file.delete_prefix(root + "/")}: #{ref}" unless File.exist?(target)
  end
end

abort("packaged skill contains missing local references: #{missing.join("; ")}") unless missing.empty?
RUBY
pass 'packaged skill markdown links and resource references are self-contained'

REMOTE_INSTALLER="$TMPROOT/remote-install.sh"
REMOTE_BIN="$TMPROOT/install-remote-bin"
REMOTE_RUNTIME="$TMPROOT/install-remote-runtime"
cp "$SKILL_ROOT/install.sh" "$REMOTE_INSTALLER"
ORBIT_RAW_BASE="file://$SKILL_ROOT" sh "$REMOTE_INSTALLER" --bin-dir "$REMOTE_BIN" --runtime-dir "$REMOTE_RUNTIME" >"$TMPROOT/install-remote.out" 2>"$TMPROOT/install-remote.err"
test ! -s "$TMPROOT/install-remote.err"
grep -q 'orbit install: downloading Orbit runtime from file://' "$TMPROOT/install-remote.out"
grep -q 'orbit install: this can take a minute on slower networks; progress updates in place on terminals' "$TMPROOT/install-remote.out"
grep -q 'orbit install: \[1/' "$TMPROOT/install-remote.out"
test "$(grep -c 'orbit install: \[[0-9][0-9]*/' "$TMPROOT/install-remote.out")" -le 6
grep -q 'orbit install: downloading runtime files complete' "$TMPROOT/install-remote.out"
grep -q 'orbit install: verifying installed orbit command' "$TMPROOT/install-remote.out"
test -x "$REMOTE_BIN/orbit"
test -f "$REMOTE_RUNTIME/skills/orbit/SKILL.md"
"$REMOTE_BIN/orbit" version >"$TMPROOT/remote-installed-version.txt"
grep -qx "$EXPECTED_VERSION" "$TMPROOT/remote-installed-version.txt"
pass 'remote installer shows progress while downloading runtime'

INSTALLED_PROJECT="$TMPROOT/installed-project"
mkdir -p "$INSTALLED_PROJECT"
(cd "$INSTALLED_PROJECT" && "$INSTALL_BIN/orbit" init --operation-mode solo >/dev/null)
INSTALLED_TASK="$TMPROOT/installed-task.yaml"
(cd "$INSTALLED_PROJECT" && "$INSTALL_BIN/orbit" new-task --task-type implementation --output "$INSTALLED_TASK" >/dev/null)
(cd "$INSTALLED_PROJECT" && ORBIT_INSTANCE=lead-main "$INSTALL_BIN/orbit" rules print-context --task "$INSTALLED_TASK" --json >"$TMPROOT/installed-rules-context.json")
json_assert 'installed orbit can load packaged default runtime rules' "$TMPROOT/installed-rules-context.json" 'j["valid"] == true && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "skills/orbit/SKILL.md" && r["exists"] == true } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "skills/orbit/references/runtime/coding-guideline.md" && r["exists"] == true }'

sh "$SKILL_ROOT/install.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/update.out" 2>"$TMPROOT/update.err"
test ! -s "$TMPROOT/update.err"
"$INSTALL_BIN/orbit" version >"$TMPROOT/updated-version.txt"
grep -qx "$EXPECTED_VERSION" "$TMPROOT/updated-version.txt"
pass 'installer can be rerun as update'

sh "$SKILL_ROOT/uninstall.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/uninstall.out" 2>"$TMPROOT/uninstall.err"
test ! -s "$TMPROOT/uninstall.err"
test ! -e "$INSTALL_BIN/orbit"
test ! -d "$INSTALL_RUNTIME"
pass 'uninstaller removes orbit wrapper and runtime'

mkdir -p "$INSTALL_BIN" "$INSTALL_RUNTIME"
printf '%s\n' '#!/usr/bin/env sh' 'exit 0' >"$INSTALL_BIN/orbit"
chmod 0755 "$INSTALL_BIN/orbit"
sh "$SKILL_ROOT/uninstall.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/uninstall-skip.out" 2>"$TMPROOT/uninstall-skip.err"
test -f "$INSTALL_BIN/orbit"
grep -q 'Skipped wrapper not created by Orbit installer' "$TMPROOT/uninstall-skip.err"
test ! -d "$INSTALL_RUNTIME"
pass 'uninstaller preserves unrelated orbit wrapper'

INSTALL_CWD_BIN="$TMPROOT/install-cwd-bin"
INSTALL_CWD_RUNTIME="$TMPROOT/install-cwd-runtime"
(cd "$SKILL_ROOT" && sh install.sh --bin-dir "$INSTALL_CWD_BIN" --runtime-dir "$INSTALL_CWD_RUNTIME" >"$TMPROOT/install-cwd.out" 2>"$TMPROOT/install-cwd.err")
test ! -s "$TMPROOT/install-cwd.err"
"$INSTALL_CWD_BIN/orbit" version >"$TMPROOT/install-cwd-version.txt"
grep -qx "$EXPECTED_VERSION" "$TMPROOT/install-cwd-version.txt"
pass 'installer detects local skill when run as sh install.sh from skill directory'

"$CLI" --help >"$TMPROOT/help.txt" 2>"$TMPROOT/help.err"
test ! -s "$TMPROOT/help.err"
grep -q 'orbit validate' "$TMPROOT/help.txt"
grep -q 'changed-files' "$TMPROOT/help.txt"
grep -Fq 'orbit evidence add --file PATH --kind KIND --status STATUS --summary SUMMARY [--task PATH]' "$TMPROOT/help.txt"
grep -Fq 'orbit evidence submit --file PATH --report PATH [--task PATH] --json' "$TMPROOT/help.txt"
grep -q 'orbit evidence waive' "$TMPROOT/help.txt"
grep -q 'orbit evidence attach-rule' "$TMPROOT/help.txt"
grep -q 'orbit classify-intent --text TEXT --json' "$TMPROOT/help.txt"
grep -q 'orbit compact-evidence --task PATH --evidence PATH' "$TMPROOT/help.txt"
grep -q 'orbit docs alias --id ID --path PATH' "$TMPROOT/help.txt"
grep -q 'orbit audit' "$TMPROOT/help.txt"
grep -q 'orbit dispatch' "$TMPROOT/help.txt"
grep -q 'orbit handoff' "$TMPROOT/help.txt"
grep -q 'orbit runtime register|ack-session' "$TMPROOT/help.txt"
grep -Fq 'orbit dispatch --task PATH --to INSTANCE [--pane PANE] [--reply-to PANE] [--manual-payload] [--dry-run] --json' "$TMPROOT/help.txt"
grep -Fq 'orbit handoff --task PATH --state PATH --evidence PATH [--output PATH] [--record-state] --json' "$TMPROOT/help.txt"
grep -Fq 'orbit rules print-context --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]' "$TMPROOT/help.txt"
grep -q 'orbit start INSTANCE' "$TMPROOT/help.txt"
grep -q 'orbit state progress' "$TMPROOT/help.txt"
grep -q 'orbit state start' "$TMPROOT/help.txt"
grep -q 'orbit state transition' "$TMPROOT/help.txt"
grep -q 'orbit state show --json' "$TMPROOT/help.txt"
grep -q 'orbit tools detect --json' "$TMPROOT/help.txt"
grep -q 'orbit wait-gate --task PATH --evidence PATH --json' "$TMPROOT/help.txt"
pass 'help lists implemented commands without stderr'

"$CLI" runtime --help >"$TMPROOT/runtime-help.txt" 2>"$TMPROOT/runtime-help.err"
test ! -s "$TMPROOT/runtime-help.err"
grep -Fq 'orbit runtime register --json' "$TMPROOT/runtime-help.txt"
grep -Fq 'orbit runtime ack-session INSTANCE --json' "$TMPROOT/runtime-help.txt"
pass 'runtime subcommand help works'

"$CLI" audit --help >"$TMPROOT/audit-help.txt" 2>"$TMPROOT/audit-help.err"
test ! -s "$TMPROOT/audit-help.err"
grep -q 'orbit audit --task PATH --state PATH --evidence PATH' "$TMPROOT/audit-help.txt"
grep -q '\-\-handoff PATH' "$TMPROOT/audit-help.txt"
grep -q '\-\-compact-summary PATH' "$TMPROOT/audit-help.txt"
grep -q 'not an evidence directory' "$TMPROOT/audit-help.txt"
pass 'audit subcommand help works'

"$CLI" dispatch --help >"$TMPROOT/dispatch-help.txt" 2>"$TMPROOT/dispatch-help.err"
test ! -s "$TMPROOT/dispatch-help.err"
grep -Fq 'orbit dispatch --task PATH --to INSTANCE [--pane PANE] [--reply-to PANE] [--manual-payload] [--dry-run] --json' "$TMPROOT/dispatch-help.txt"
grep -q 'wait-gate' "$TMPROOT/dispatch-help.txt"
grep -q 'Herdr is the only official direct delivery adapter' "$TMPROOT/dispatch-help.txt"
grep -q 'Manual payloads are artifacts' "$TMPROOT/dispatch-help.txt"
pass 'dispatch subcommand help works'

"$CLI" classify-intent --help >"$TMPROOT/classify-intent-help.txt" 2>"$TMPROOT/classify-intent-help.err"
test ! -s "$TMPROOT/classify-intent-help.err"
grep -Fq 'orbit classify-intent --text TEXT --json' "$TMPROOT/classify-intent-help.txt"
grep -q 'workflow intent' "$TMPROOT/classify-intent-help.txt"
pass 'classify-intent subcommand help works'

"$CLI" compact-evidence --help >"$TMPROOT/compact-evidence-help.txt" 2>"$TMPROOT/compact-evidence-help.err"
test ! -s "$TMPROOT/compact-evidence-help.err"
grep -Fq 'orbit compact-evidence --task PATH --evidence PATH [--handoff PATH] [--output PATH] --json' "$TMPROOT/compact-evidence-help.txt"
grep -q 'durable evidence summary' "$TMPROOT/compact-evidence-help.txt"
pass 'compact-evidence subcommand help works'

"$CLI" docs --help >"$TMPROOT/docs-help.txt" 2>"$TMPROOT/docs-help.err"
test ! -s "$TMPROOT/docs-help.err"
grep -Fq 'orbit docs alias --id ID --path PATH [--registry PATH] --json' "$TMPROOT/docs-help.txt"
grep -Fq 'orbit docs check [--registry PATH] [--open-dir PATH] [--archive-dir PATH] --json' "$TMPROOT/docs-help.txt"
pass 'docs subcommand help works'

"$CLI" handoff --help >"$TMPROOT/handoff-help.txt" 2>"$TMPROOT/handoff-help.err"
test ! -s "$TMPROOT/handoff-help.err"
grep -Fq 'orbit handoff --task PATH --state PATH --evidence PATH [--output PATH] [--record-state] --json' "$TMPROOT/handoff-help.txt"
grep -q 'not an evidence directory' "$TMPROOT/handoff-help.txt"
pass 'handoff subcommand help works'

"$CLI" validate --help >"$TMPROOT/validate-help.txt" 2>"$TMPROOT/validate-help.err"
test ! -s "$TMPROOT/validate-help.err"
grep -Fq 'orbit validate [--task PATH] [--evidence PATH] [--state PATH]' "$TMPROOT/validate-help.txt"
grep -q 'changed-files' "$TMPROOT/validate-help.txt"
grep -q 'scope.include' "$TMPROOT/validate-help.txt"
grep -q 'not an evidence directory' "$TMPROOT/validate-help.txt"
pass 'validate subcommand help works'

"$CLI" rules resolve --help >"$TMPROOT/rules-resolve-help.txt" 2>"$TMPROOT/rules-resolve-help.err"
test ! -s "$TMPROOT/rules-resolve-help.err"
grep -Fq 'orbit rules resolve --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]' "$TMPROOT/rules-resolve-help.txt"
grep -q 'Evidence manifest used only for override-backed identity checks' "$TMPROOT/rules-resolve-help.txt"
grep -q 'deterministic code' "$TMPROOT/rules-resolve-help.txt"
pass 'rules resolve subcommand help works'

"$CLI" rules print-context --help >"$TMPROOT/rules-print-context-help.txt" 2>"$TMPROOT/rules-print-context-help.err"
test ! -s "$TMPROOT/rules-print-context-help.err"
grep -Fq 'orbit rules print-context --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]' "$TMPROOT/rules-print-context-help.txt"
grep -q 'Evidence manifest used only for override-backed identity checks' "$TMPROOT/rules-print-context-help.txt"
grep -q 'Project rules are additive' "$TMPROOT/rules-print-context-help.txt"
pass 'rules print-context subcommand help works'

"$CLI" classify-intent --text "先讨论一下这个方案怎么看" --json >"$TMPROOT/intent-discussion.json"
json_assert 'classify-intent keeps discussion orbit-aware without formal task' "$TMPROOT/intent-discussion.json" 'j["intent"] == "discussion" && j["policy"]["formal_task"] == false && j["policy"]["skip_task_reason_required"] == true'
"$CLI" classify-intent --text "Orbit 是什么？先解释一下，不要开任务" --json >"$TMPROOT/intent-orbit-question.json"
json_assert 'classify-intent does not formalize plain Orbit discussion' "$TMPROOT/intent-orbit-question.json" 'j["intent"] == "discussion" && j["explicit_orbit_workflow"] == false && j["policy"]["formal_task"] == false && j["policy"]["skip_task_reason_required"] == true'
"$CLI" classify-intent --text "按 Orbit 流程继续实现这个功能" --json >"$TMPROOT/intent-orbit-coding.json"
json_assert 'classify-intent explicit Orbit workflow requires formal task' "$TMPROOT/intent-orbit-coding.json" 'j["explicit_orbit_workflow"] == true && j["intent"] == "coding" && j["policy"]["formal_task"] == true && j["policy"]["evidence"] == true && j["policy"]["gates"] == true'
"$CLI" classify-intent --text "整理文档并更新 .orbit evidence 历史路径" --json >"$TMPROOT/intent-docs-orbit.json"
json_assert 'classify-intent docs maintenance touching orbit evidence requires task' "$TMPROOT/intent-docs-orbit.json" 'j["intent"] == "docs_maintenance" && j["policy"]["formal_task"] == true && j["policy"]["evidence"] == true && j["policy"]["gates"] == true'
"$CLI" classify-intent --text "review 这个变更" --json >"$TMPROOT/intent-review.json"
json_assert 'classify-intent review emits review policy' "$TMPROOT/intent-review.json" 'j["intent"] == "review" && j["policy"]["default_task_type"] == "review" && j["policy"]["evidence"] == true'

"$CLI" start --help >"$TMPROOT/start-help.txt" 2>"$TMPROOT/start-help.err"
test ! -s "$TMPROOT/start-help.err"
grep -Fq 'orbit start INSTANCE [--cwd PROJECT_ROOT] [--layout auto|same-tab|new-tab] [--force] [--dry-run] [--json]' "$TMPROOT/start-help.txt"
grep -q 'not through a shell string' "$TMPROOT/start-help.txt"
grep -q -- '--cwd must be the same Orbit project root' "$TMPROOT/start-help.txt"
pass 'start subcommand help works'

"$CLI" wait-gate --help >"$TMPROOT/wait-gate-help.txt" 2>"$TMPROOT/wait-gate-help.err"
test ! -s "$TMPROOT/wait-gate-help.err"
grep -Fq 'orbit wait-gate --task PATH --evidence PATH --json' "$TMPROOT/wait-gate-help.txt"
grep -q 'does not replace reviewer/tester judgment' "$TMPROOT/wait-gate-help.txt"
pass 'wait-gate subcommand help works'

"$CLI" evidence --help >"$TMPROOT/evidence-help.txt" 2>"$TMPROOT/evidence-help.err"
test ! -s "$TMPROOT/evidence-help.err"
grep -Fq 'orbit evidence submit --file PATH --report PATH [--task PATH] --json' "$TMPROOT/evidence-help.txt"
grep -Fq 'orbit evidence add --file PATH --kind KIND --status STATUS --summary SUMMARY [--task PATH]' "$TMPROOT/evidence-help.txt"
grep -q 'task_sha256' "$TMPROOT/evidence-help.txt"
pass 'evidence subcommand help works'

"$CLI" evidence submit --help >"$TMPROOT/evidence-submit-help.txt" 2>"$TMPROOT/evidence-submit-help.err"
test ! -s "$TMPROOT/evidence-submit-help.err"
grep -Fq 'orbit evidence submit --file PATH --report PATH [--task PATH] --json' "$TMPROOT/evidence-submit-help.txt"
pass 'evidence submit --help redirects to evidence subcommand help'

"$CLI" version >"$TMPROOT/version.txt"
grep -qx "$EXPECTED_VERSION" "$TMPROOT/version.txt"
pass 'version outputs package.json version'

NO_ORBIT_PIGGYBACK="$TMPROOT/no-orbit-piggyback"
mkdir -p "$NO_ORBIT_PIGGYBACK"
(cd "$NO_ORBIT_PIGGYBACK" && HERDR_ENV=1 "$CLI" --help >"$TMPROOT/no-orbit-help.txt" && HERDR_ENV=1 "$CLI" version >"$TMPROOT/no-orbit-version.txt" && test ! -e .orbit/runtime)
grep -qx "$EXPECTED_VERSION" "$TMPROOT/no-orbit-version.txt"
pass 'runtime piggyback skips help and version outside orbit project'

PROJECT="$TMPROOT/project"
mkdir -p "$PROJECT"
cd "$PROJECT"

expect_failure 'init requires operation mode in non-tty mode' "$CLI" init
"$CLI" init --operation-mode solo >"$TMPROOT/init.out" 2>"$TMPROOT/init.err"
test ! -s "$TMPROOT/init.err"
test -f .orbit/roles.yaml
test -f .orbit/instances.yaml
test -f .orbit/loop-state.yaml
yaml_assert 'init writes solo operation defaults' .orbit/roles.yaml 'j["operation_defaults"]["operation_mode"] == "solo" && j["operation_defaults"]["owner_instance"] == "lead-main" && j["operation_defaults"]["assigned_instance"] == "lead-main"'
yaml_assert 'init creates main instance keys' .orbit/instances.yaml 'j["instances"].key?("lead-main") && j["instances"].key?("reviewer-main") && j["instances"].key?("tester-main")'
pass 'init creates config from templates'
"$CLI" instances status --json >"$TMPROOT/instances-status.json"
json_assert 'instances status defaults user-managed unbound instances to startable Herdr binding' "$TMPROOT/instances-status.json" 'j["schema_version"] == "orbit-instances-status-v1" && j["instances"].any? { |i| i["instance"] == "reviewer-main" && i["management"] == "user_managed" && i["binding"] == "unbound" && i["liveness"] == "not_alive" && i["liveness_reason"] == "no_binding" && i["availability"] == "missing" && i["herdr"]["adapter"] == "herdr" && i["view"]["min_columns"] == 120 && i["view_status"]["too_narrow"].nil? }'
ORBIT_INSTANCE=lead-main HERDR_PANE_ID=manual-pane "$CLI" runtime register --json >"$TMPROOT/runtime-register-no-pending.json"
json_assert 'runtime register without pending launch does not produce Herdr-verified identity' "$TMPROOT/runtime-register-no-pending.json" 'j["identity_verification"] == "identity_pending_unbound" && j["dispatch_ready"] == false && j["runtime_session"]["identity"]["verification"] != "herdr_verified" && j["runtime_session"]["diagnostic_only"] == true && j["runtime_session"]["persistence"] == "not_written"'
ruby --disable-gems -rjson -e 'session = JSON.parse(File.read(ARGV[0])).dig("runtime_session", "session_id"); abort("session_id missing") if session.to_s.empty?; abort(session) if File.exist?(File.join(".orbit/runtime/sessions", "#{session}.json"))' "$TMPROOT/runtime-register-no-pending.json"
ruby --disable-gems -rjson -e 'p=".orbit/runtime/instances/lead-main.json"; if File.exist?(p); j=JSON.parse(File.read(p)); abort(JSON.pretty_generate(j)) unless j["current_session_id"].to_s.empty?; end'
pass 'runtime register without pending launch is diagnostic-only'
mkdir -p "$TMPROOT/fakebin"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    ruby_pwd=$(ruby --disable-gems -e 'print Dir.pwd')
    if [ "${ORBIT_FAKE_HERDR_REGISTER_MODE:-}" = "empty" ]; then
      printf '{"result":{"agents":[]}}\n'
    else
      printf '{"result":{"agents":[{"pane_id":"register-pane","agent":"codex","agent_status":"idle","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    fi
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
ruby --disable-gems -rjson -ryaml -rdigest -rtime -rfileutils -e '
  ids = ARGV
  roles = YAML.safe_load(File.read(".orbit/roles.yaml"), aliases: true).fetch("roles")
  instances = YAML.safe_load(File.read(".orbit/instances.yaml"), aliases: true).fetch("instances")
  stable_instance = ->(value) {
    copy = JSON.parse(JSON.generate(value))
    %w[binding herdr view].each { |key| copy.delete(key) }
    copy
  }
  instance = instances.fetch("lead-main")
  role = roles.fetch(instance.fetch("role_ref"))
  now = Time.now.utc.iso8601
  FileUtils.mkdir_p(".orbit/runtime/sessions")
  ids.each do |session_id|
    File.write(".orbit/runtime/sessions/#{session_id}.json", JSON.pretty_generate({
      "schema_version" => "orbit-runtime-session-v1",
      "session_id" => session_id,
      "launch_id" => "orl-#{session_id}",
      "state" => "pending",
      "project_root" => Dir.pwd,
      "project_root_sha256" => Digest::SHA256.hexdigest(File.expand_path(Dir.pwd)),
      "project_id" => File.basename(Dir.pwd),
      "host_id" => "test-host",
      "user" => "test-user",
      "instance" => "lead-main",
      "role" => "lead",
      "role_ref" => "lead",
      "role_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(role)),
      "instance_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(stable_instance.call(instance))),
      "client" => "codex",
      "command" => "codex",
      "herdr" => {"session"=>"hs-register", "workspace"=>"", "tab"=>"", "pane"=>"register-pane", "canonical_pane"=>"register-pane"},
      "identity" => {"verification"=>"identity_pending", "whoami_valid"=>true, "conflicts"=>[]},
      "created_at" => now,
      "updated_at" => now,
      "heartbeat" => {"last_seen_at"=>now, "ttl_seconds"=>300}
    }) + "\n")
  end
  ' ors-register-ok ors-register-bad-launch ors-config-drift ors-project-drift ors-session-mismatch ors-probe-pending ors-wrong-pane ors-reentry ors-piggyback
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-register-ok ORBIT_LAUNCH_ID=orl-ors-register-ok HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json >"$TMPROOT/runtime-register-correct-pane-spoof.json"
json_assert 'runtime register does not verify even when env claims the matching Herdr pane' "$TMPROOT/runtime-register-correct-pane-spoof.json" 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j["runtime_session"]["state"] == "pending" && j["runtime_session"]["identity"]["verification"] == "identity_pending"'
expect_failure 'runtime register refuses forged session id without pending store record' env ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-forged-missing ORBIT_LAUNCH_ID=orl-ors-forged-missing HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json
expect_failure 'runtime register refuses wrong launch id' env ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-register-bad-launch ORBIT_LAUNCH_ID=wrong-launch HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json
cp .orbit/instances.yaml "$TMPROOT/instances-before-register-config-drift.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["lead-main"]["env"]={"ORBIT_EXTRA_CONFIG_HASH"=>"changed"}; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'runtime register refuses config hash drift since start' env ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-config-drift ORBIT_LAUNCH_ID=orl-ors-config-drift HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json
cp "$TMPROOT/instances-before-register-config-drift.yaml" .orbit/instances.yaml
ruby --disable-gems -rjson -e 'p=".orbit/runtime/sessions/ors-project-drift.json"; j=JSON.parse(File.read(p)); j["project_root_sha256"]="wrong-project-root"; File.write(p, JSON.pretty_generate(j))'
expect_failure 'runtime register refuses cross-checkout project hash drift' env ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-project-drift ORBIT_LAUNCH_ID=orl-ors-project-drift HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json
expect_failure 'runtime register refuses named Herdr session namespace mismatch' env ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-session-mismatch ORBIT_LAUNCH_ID=orl-ors-session-mismatch HERDR_SESSION_ID=wrong-herdr-session HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json
ORBIT_FAKE_HERDR_REGISTER_MODE=empty ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-probe-pending ORBIT_LAUNCH_ID=orl-ors-probe-pending HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json >"$TMPROOT/runtime-register-probe-pending.json"
json_assert 'runtime register keeps identity pending when Herdr probe is not ready' "$TMPROOT/runtime-register-probe-pending.json" 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j["runtime_session"]["state"] == "pending" && j["runtime_session"]["identity"]["verification"] == "identity_pending"'
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-wrong-pane ORBIT_LAUNCH_ID=orl-ors-wrong-pane HERDR_SESSION_ID=hs-register HERDR_PANE_ID=attacker-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json >"$TMPROOT/runtime-register-wrong-pane.json"
json_assert 'runtime register does not verify pending session from a different current pane' "$TMPROOT/runtime-register-wrong-pane.json" 'j["identity_verification"] == "pending" && j["dispatch_ready"] == false && j["runtime_session"]["state"] == "pending" && j["runtime_session"]["identity"]["verification"] == "identity_pending"'
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-reentry ORBIT_LAUNCH_ID=orl-ors-reentry HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane ORBIT_RUNTIME_REFRESHING=1 PATH="$TMPROOT/fakebin:$PATH" "$CLI" whoami --json >"$TMPROOT/piggyback-reentry-whoami.json"
ruby --disable-gems -rjson -e 'j=JSON.parse(File.read(".orbit/runtime/sessions/ors-reentry.json")); abort(JSON.pretty_generate(j)) unless j.dig("identity","verification") == "identity_pending" && j["state"] == "pending"'
pass 'Herdr Orbit command skips piggyback under runtime refresh reentry guard'
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-piggyback ORBIT_LAUNCH_ID=orl-ors-piggyback HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" whoami --json >"$TMPROOT/piggyback-whoami.json"
ruby --disable-gems -rjson -e 'j=JSON.parse(File.read(".orbit/runtime/sessions/ors-piggyback.json")); abort(JSON.pretty_generate(j)) unless j.dig("identity","verification") == "identity_pending" && j["state"] == "pending"'
pass 'Herdr Orbit command piggybacks pending runtime registration without trusting env pane'
ruby --disable-gems -rjson -e 'p=".orbit/runtime/sessions/ors-piggyback.json"; j=JSON.parse(File.read(p)); j["heartbeat"]["last_seen_at"]="2000-01-01T00:00:00Z"; File.write(p, JSON.pretty_generate(j))'
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-piggyback ORBIT_LAUNCH_ID=orl-ors-piggyback HERDR_SESSION_ID=hs-register HERDR_PANE_ID=register-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" whoami --json >"$TMPROOT/piggyback-refresh-whoami.json"
ruby --disable-gems -rjson -e 'j=JSON.parse(File.read(".orbit/runtime/sessions/ors-piggyback.json")); abort(JSON.pretty_generate(j)) unless j.dig("heartbeat","last_seen_at") != "2000-01-01T00:00:00Z"'
pass 'Herdr Orbit command refreshes pending registration without producing verified heartbeat'
rm -rf .orbit/runtime
yaml_assert 'init creates user-managed Herdr instance bindings and sibling view by default' .orbit/instances.yaml 'j["instances"].values.all? { |i| i["management"] == "user_managed" && i["binding"].is_a?(Hash) && i["binding"]["adapter"] == "herdr" && !i["binding"].key?("view") && i["view"].is_a?(Hash) && !i.key?("transport") }'
cp .orbit/instances.yaml "$TMPROOT/instances-before-workspace-only.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["binding"]={"adapter"=>"herdr","workspace"=>"w1","tab"=>"t1"}; File.write(p, YAML.dump(y))' .orbit/instances.yaml
"$CLI" instances status --json >"$TMPROOT/instances-workspace-only-status.json"
json_assert 'workspace and tab without pane do not count as a live binding' "$TMPROOT/instances-workspace-only-status.json" 'j["instances"].any? { |i| i["instance"] == "reviewer-main" && i["binding"] == "unbound" && i["liveness"] == "not_alive" && i["liveness_reason"] == "no_binding" && i["herdr"]["workspace"] == "w1" && i["herdr"]["tab"] == "t1" }'
"$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-workspace-only-create.json"
json_assert 'start creates by default when only workspace tab hints are configured' "$TMPROOT/start-reviewer-workspace-only-create.json" 'j["action"] == "dry_run" && j["instance_status"]["binding"] == "unbound" && j["instance_status"]["liveness_reason"] == "no_binding" && j["view"]["min_columns"] == 120 && j.dig("layout","minimum","cols") == 120 && !j.key?("force_command")'
cp "$TMPROOT/instances-before-workspace-only.yaml" .orbit/instances.yaml
mkdir -p "$TMPROOT/fakebin"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    ruby_pwd=$(ruby --disable-gems -e 'print Dir.pwd')
    if [ "${ORBIT_FAKE_HERDR_RUNTIME_MODE:-}" = "ambiguous" ]; then
      printf '{"result":{"agents":[{"pane_id":"runtime-only-pane","agent":"codex","agent_status":"idle","cwd":"__PWD__"},{"pane_id":"runtime-duplicate-pane","agent":"codex","agent_status":"idle","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    else
      printf '{"result":{"agents":[{"pane_id":"runtime-only-pane","agent":"codex","agent_status":"idle","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    fi
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-no-runtime-client-cwd-only.json"
json_assert 'start does not reuse Herdr client/cwd match without verified runtime session' "$TMPROOT/start-reviewer-no-runtime-client-cwd-only.json" 'j["action"] == "dry_run" && j["dispatch_ready"].nil? && j["instance_status"]["binding"] == "unbound"'
ruby --disable-gems -rjson -ryaml -rdigest -rtime -rfileutils -e '
  roles = YAML.safe_load(File.read(".orbit/roles.yaml"), aliases: true).fetch("roles")
  instances = YAML.safe_load(File.read(".orbit/instances.yaml"), aliases: true).fetch("instances")
  stable_instance = ->(value) {
    copy = JSON.parse(JSON.generate(value))
    %w[binding herdr view].each { |key| copy.delete(key) }
    copy
  }
  instance = instances.fetch("reviewer-main")
  role = roles.fetch(instance.fetch("role_ref"))
  now = Time.now.utc.iso8601
  FileUtils.mkdir_p(".orbit/runtime/sessions")
  FileUtils.mkdir_p(".orbit/runtime/instances")
  File.write(".orbit/runtime/sessions/ors-runtime-only.json", JSON.pretty_generate({
    "schema_version" => "orbit-runtime-session-v1",
    "session_id" => "ors-runtime-only",
    "launch_id" => "orl-runtime-only",
    "state" => "active",
    "project_root" => Dir.pwd,
    "project_root_sha256" => Digest::SHA256.hexdigest(File.expand_path(Dir.pwd)),
    "project_id" => File.basename(Dir.pwd),
    "host_id" => "test-host",
    "user" => "test-user",
    "instance" => "reviewer-main",
    "role" => "reviewer",
    "role_ref" => "reviewer",
    "role_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(role)),
    "instance_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(stable_instance.call(instance))),
    "client" => "codex",
    "command" => "codex",
    "herdr" => {"session"=>"", "workspace"=>"", "tab"=>"", "pane"=>"runtime-only-pane", "canonical_pane"=>"runtime-only-pane"},
    "identity" => {"verification"=>"herdr_verified", "whoami_valid"=>true, "conflicts"=>[]},
    "created_at" => now,
    "updated_at" => now,
    "heartbeat" => {"last_seen_at"=>now, "ttl_seconds"=>300}
  }) + "\n")
'
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-reuse-discovered.json"
json_assert 'start ignores handwritten herdr_verified runtime session without trusted caller proof' "$TMPROOT/start-reviewer-reuse-discovered.json" 'j["action"] == "dry_run" && j["dispatch_ready"].nil? && j.dig("instance_status","runtime_resolution","binding_resolution") == "missing" && j.dig("instance_status","runtime_resolution","identity_verification") == "absent"'
ruby --disable-gems -rjson -e 'p=".orbit/runtime/sessions/ors-runtime-only.json"; j=JSON.parse(File.read(p)); j["heartbeat"]["last_seen_at"]="2000-01-01T00:00:00Z"; File.write(p, JSON.pretty_generate(j))'
ruby --disable-gems -rjson -rtime -e 'p=".orbit/runtime/sessions/ors-runtime-only.json"; j=JSON.parse(File.read(p)); now=Time.now.utc.iso8601; j["heartbeat"]["last_seen_at"]=now; j["updated_at"]=now; File.write(p, JSON.pretty_generate(j))'
ruby --disable-gems -rjson -e 'src=".orbit/runtime/sessions/ors-runtime-only.json"; dst=".orbit/runtime/sessions/ors-runtime-duplicate.json"; j=JSON.parse(File.read(src)); j["session_id"]="ors-runtime-duplicate"; j["launch_id"]="orl-runtime-duplicate"; j["herdr"]["pane"]="runtime-duplicate-pane"; j["herdr"]["canonical_pane"]="runtime-duplicate-pane"; File.write(dst, JSON.pretty_generate(j))'
rm -f .orbit/runtime/instances/reviewer-main.json
if ORBIT_FAKE_HERDR_RUNTIME_MODE=ambiguous PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-ambiguous-runtime.json" 2>"$TMPROOT/start-reviewer-ambiguous-runtime.err"; then
  :
else
  printf 'FAIL start untrusted runtime sessions: command unexpectedly failed\n' >&2
  cat "$TMPROOT/start-reviewer-ambiguous-runtime.err" >&2
  exit 1
fi
json_assert 'start ignores ambiguous handwritten herdr_verified runtime sessions without trusted caller proof' "$TMPROOT/start-reviewer-ambiguous-runtime.json" 'j["action"] == "dry_run" && j.dig("instance_status","runtime_resolution","binding_resolution") == "missing" && j.dig("instance_status","runtime_resolution","identity_verification") == "absent"'
rm -f .orbit/runtime/sessions/ors-runtime-duplicate.json .orbit/runtime/instances/reviewer-main.json
PATH="$TMPROOT/fakebin:$PATH" "$CLI" instances status --json >"$TMPROOT/instances-status-repaired-not-written.json"
json_assert 'instances status ignores handwritten herdr_verified runtime session without trusted caller proof' "$TMPROOT/instances-status-repaired-not-written.json" 'reviewer = j["instances"].find { |entry| entry["instance"] == "reviewer-main" }; j["config_write"] == "not_written" && reviewer["runtime_resolution"]["binding_resolution"] == "missing" && reviewer["runtime_resolution"]["identity_verification"] == "absent" && reviewer["repair_binding_command"].nil?'
yaml_assert 'instances status without repair-binding does not write config' .orbit/instances.yaml 'j["instances"]["reviewer-main"]["binding"]["pane"].to_s.empty?'
cp .orbit/instances.yaml "$TMPROOT/instances-before-runtime-hash-drift.yaml"
ruby --disable-gems -rjson -rtime -rfileutils -e 'FileUtils.mkdir_p(".orbit/runtime/instances"); File.write(".orbit/runtime/instances/reviewer-main.json", JSON.pretty_generate({"schema_version"=>"orbit-runtime-instance-v1","instance"=>"reviewer-main","current_session_id"=>"ors-runtime-only","current_state"=>"active","previous_sessions"=>[],"replacement_diagnostics"=>[],"ack"=>nil,"updated_at"=>Time.now.utc.iso8601}))'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["env"]={"ORBIT_EXTRA_CONFIG_HASH"=>"changed"}; File.write(p, YAML.dump(y))' .orbit/instances.yaml
PATH="$TMPROOT/fakebin:$PATH" "$CLI" instances status --json >"$TMPROOT/instances-status-runtime-hash-drift.json"
json_assert 'runtime resolver rejects verified session after instance config hash drift' "$TMPROOT/instances-status-runtime-hash-drift.json" 'reviewer = j["instances"].find { |entry| entry["instance"] == "reviewer-main" }; reviewer["runtime_resolution"]["identity_verification"] == "mismatch" && reviewer["runtime_resolution"]["liveness_reason"] == "instance_config_hash_mismatch" && reviewer["dispatch_ready"] == false'
cp "$TMPROOT/instances-before-runtime-hash-drift.yaml" .orbit/instances.yaml
PATH="$TMPROOT/fakebin:$PATH" "$CLI" instances status --repair-binding --json >"$TMPROOT/instances-status-repair-written.json"
json_assert 'instances status repair-binding does not write untrusted runtime session to config' "$TMPROOT/instances-status-repair-written.json" 'j["config_write"] == "requested" && !j["config_repairs"].any? { |r| r["instance"] == "reviewer-main" }'
yaml_assert 'instances status repair-binding leaves config unchanged for untrusted runtime session' .orbit/instances.yaml 'j["instances"]["reviewer-main"]["binding"]["pane"].to_s.empty? && j["instances"]["reviewer-main"]["binding"]["canonical_pane"].to_s.empty?'
rm -rf .orbit/runtime
for role in lead-main reviewer-main tester-main; do
  "$CLI" bind-pane --instance "$role" --pane "concurrent-$role" --json >"$TMPROOT/concurrent-bind-$role.json" &
done
wait
yaml_assert 'concurrent bind-pane preserves all Herdr instance bindings' .orbit/instances.yaml 'j["instances"]["lead-main"]["binding"]["pane"] == "concurrent-lead-main" && j["instances"]["reviewer-main"]["binding"]["pane"] == "concurrent-reviewer-main" && j["instances"]["tester-main"]["binding"]["pane"] == "concurrent-tester-main"'
"$CLI" bind-pane --instance reviewer-main --pane pane-reviewer --json >"$TMPROOT/bind-pane-reviewer-main.json"
json_assert 'bind-pane records reviewer Herdr binding as manual hint only' "$TMPROOT/bind-pane-reviewer-main.json" 'j["schema_version"] == "orbit-bind-pane-v1" && j["instance"] == "reviewer-main" && j["identity_verification"] == "absent" && j["dispatch_ready"] == false && j["status"]["binding"] == "bound" && j["status"]["liveness"] == "unknown" && j["status"]["herdr"]["pane"] == "pane-reviewer"'
mkdir -p "$TMPROOT/fakebin"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"pane-reviewer","agent":"codex","agent_status":"idle","cols":80,"rows":24}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" instances status --json >"$TMPROOT/instances-too-narrow-status.json"
json_assert 'instances status reports observed Herdr pane too narrow' "$TMPROOT/instances-too-narrow-status.json" 'j["instances"].any? { |i| i["instance"] == "reviewer-main" && i.dig("view_status","observed_geometry","cols") == 80 && i.dig("view_status","too_narrow") == true && i.dig("view_status","remediation") == "resize_or_recreate_view" }'
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-too-narrow.json"; then
  printf 'FAIL start too narrow: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start refuses to reuse too-narrow Herdr pane' "$TMPROOT/start-reviewer-too-narrow.json" 'j["action"] == "needs_attention" && j["reason"] == "pane_too_narrow" && j["recommended_action"] == "resize_or_recreate_view" && j.dig("instance_status","view_status","too_narrow") == true'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"pane-reviewer","agent":"codex","agent_status":"idle"}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-reuse.json"
json_assert 'start does not reuse Herdr binding without verified runtime identity' "$TMPROOT/start-reviewer-reuse.json" 'j["action"] == "reuse_identity_pending" && j["reason"] == "binding_agent_found_but_runtime_identity_unverified" && j["dispatch_ready"] == false && j["reuse_probe"]["agent_detected"] == true && j["reuse_probe"]["agent"] == "codex" && j["runtime_resolution"]["identity_verification"] == "absent" && j["next"].any? { |n| n["manual_payload"].to_s.include?("trusted caller-pane proof") } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "skills/orbit/SKILL.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "skills/orbit/references/runtime/guide.md" }'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"pane-reviewer","agent":"claude","agent_status":"idle"}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-client-mismatch.json" 2>"$TMPROOT/start-reviewer-client-mismatch.err"; then
  printf 'FAIL start client mismatch: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start refuses to reuse Herdr binding with wrong client' "$TMPROOT/start-reviewer-client-mismatch.json" 'j["action"] == "needs_force" && j["reuse_probe"]["decision"] == "needs_attention" && j["reuse_probe"]["identity_conflicts"].include?("client_mismatch") && j["reuse_probe"]["identity_checks"].any? { |c| c["check"] == "client" && c["status"] == "fail" && c["expected"] == "codex" && c["actual"] == "claude" }'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"pane-reviewer","agent":"codex","agent_status":"idle","cwd":"/tmp/orbit-other-checkout"}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-cwd-mismatch.json" 2>"$TMPROOT/start-reviewer-cwd-mismatch.err"; then
  printf 'FAIL start cwd mismatch: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start refuses to reuse Herdr binding with wrong cwd' "$TMPROOT/start-reviewer-cwd-mismatch.json" 'j["action"] == "needs_force" && j["reuse_probe"]["decision"] == "needs_attention" && j["reuse_probe"]["identity_conflicts"].include?("cwd_mismatch") && j["reuse_probe"]["identity_checks"].any? { |c| c["check"] == "cwd" && c["status"] == "fail" && c["expected"] == Dir.pwd && c["actual"].values.include?("/tmp/orbit-other-checkout") }'
"$CLI" bind-pane --instance reviewer-main --pane alias-reviewer --json >"$TMPROOT/bind-pane-reviewer-alias.json"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "pane get")
    printf '{"result":{"pane":{"pane_id":"canonical-reviewer"}}}\n'
    ;;
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"canonical-reviewer","agent":"codex","agent_status":"idle"}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-alias-reuse.json"
json_assert 'start resolves Herdr pane aliases but still requires verified runtime identity' "$TMPROOT/start-reviewer-alias-reuse.json" 'j["action"] == "reuse_identity_pending" && j["reason"] == "binding_agent_found_but_runtime_identity_unverified" && j["reuse_probe"]["pane"] == "alias-reviewer" && j["reuse_probe"]["canonical_pane"] == "canonical-reviewer" && j["reuse_probe"]["agent_detected"] == true && j["reuse_probe"]["agent"] == "codex" && j["dispatch_ready"] == false'
"$CLI" bind-pane --instance reviewer-main --pane self-alias --json >"$TMPROOT/bind-pane-reviewer-self.json"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "pane get")
    printf '{"result":{"pane":{"pane_id":"self-canonical"}}}\n'
    ;;
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if HERDR_PANE_ID=current-alias PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-self-wake-needs-force.json" 2>"$TMPROOT/start-reviewer-self-wake-needs-force.err"; then
  printf 'FAIL start self-wake without force: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start refuses to self-wake cached binding without force' "$TMPROOT/start-reviewer-self-wake-needs-force.json" 'j["action"] == "needs_force" && j["liveness_source"] == "herdr_probe" && j["reuse_probe"]["decision"] == "self_wake" && j["risk"].any? { |r| r["code"] == "duplicate_instance_agents_may_run_concurrently" } && j["risk"].any? { |r| r["code"] == "old_and_new_agents_may_compete_for_orbit_state" } && j["force_command"] == ["orbit", "start", "reviewer-main", "--force"]'
if HERDR_PANE_ID=current-alias PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run >"$TMPROOT/start-reviewer-self-wake-needs-force-human.out" 2>"$TMPROOT/start-reviewer-self-wake-needs-force-human.err"; then
  printf 'FAIL start self-wake without force human: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'Force does not kill the old external process' "$TMPROOT/start-reviewer-self-wake-needs-force-human.err"
grep -q 'compete for evidence, gate leases, and loop state writes' "$TMPROOT/start-reviewer-self-wake-needs-force-human.err"
HERDR_PANE_ID=current-alias PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --force --dry-run --json >"$TMPROOT/start-reviewer-self-wake-dry-run.json"
json_assert 'start self-wakes current Herdr pane without requiring prompt classification' "$TMPROOT/start-reviewer-self-wake-dry-run.json" 'j["action"] == "self_wake_dry_run" && j["reuse_probe"]["decision"] == "self_wake" && j["reuse_probe"]["self_pane"] == true && j["reuse_probe"]["safe_to_wake"] == true && j["self_wake"]["mode"] == "exec_current_process" && j["self_wake"]["command"].include?("codex")'
"$CLI" bind-pane --instance reviewer-main --pane shell-pane --json >"$TMPROOT/bind-pane-reviewer-shell.json"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  "pane read")
    printf 'project %%\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-wake-needs-force.json" 2>"$TMPROOT/start-reviewer-wake-needs-force.err"; then
  printf 'FAIL start wake without force: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start refuses to wake cached Herdr shell pane without force' "$TMPROOT/start-reviewer-wake-needs-force.json" 'j["action"] == "needs_force" && j["liveness_source"] == "herdr_probe" && j["reuse_probe"]["decision"] == "wake" && j["reuse_probe"]["safe_to_wake"] == true'
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --force --dry-run --json >"$TMPROOT/start-reviewer-wake-dry-run.json"
json_assert 'start wakes bound Herdr shell pane in dry-run only with force' "$TMPROOT/start-reviewer-wake-dry-run.json" 'j["action"] == "wake_dry_run" && j["force"] == true && j["reuse_probe"]["agent_detected"] == false && j["reuse_probe"]["safe_to_wake"] == true && j["wake_adapter"]["command"][0,4] == ["herdr", "pane", "run", "shell-pane"] && j["wake_adapter"]["command"][4].include?("ORBIT_INSTANCE") && j["wake_adapter"]["command"][4].include?("reviewer") && j["wake_adapter"]["command"][4].include?("ORBIT_ROLE") && j["wake_adapter"]["command"][4].include?("codex")'
"$CLI" bind-pane --instance reviewer-main --pane shell-process-pane --json >"$TMPROOT/bind-pane-reviewer-shell-process.json"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  "pane process-info")
    printf '{"result":{"process_info":{"pane_id":"shell-process-pane","shell_pid":123,"foreground_processes":[{"pid":123,"name":"zsh","argv0":"zsh","argv":["-zsh"],"cmdline":"-zsh"}]}}}\n'
    ;;
  "pane read")
    printf 'command output without shell prompt marker\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --force --dry-run --json >"$TMPROOT/start-reviewer-shell-process-wake-dry-run.json"
json_assert 'start treats foreground shell process as safe to wake' "$TMPROOT/start-reviewer-shell-process-wake-dry-run.json" 'j["action"] == "wake_dry_run" && j["reuse_probe"]["pane"] == "shell-process-pane" && j["reuse_probe"]["safe_to_wake"] == true && j["reuse_probe"]["pane_process_info"]["safe_to_wake"] == true && j["reuse_probe"]["pane_read"]["safe_to_wake"] == false && j["reuse_probe"]["decision"] == "wake"'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"shell-pane","name":"reviewer","agent_status":"unknown"}]}}\n'
    ;;
  "pane read")
    printf 'project %%\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --force --dry-run --json >"$TMPROOT/start-reviewer-placeholder-wake-dry-run.json"
json_assert 'start ignores Herdr placeholder entries without an agent client' "$TMPROOT/start-reviewer-placeholder-wake-dry-run.json" 'j["action"] == "wake_dry_run" && j["reuse_probe"]["agent_detected"] == false && j["reuse_probe"]["decision"] == "wake" && j["reuse_probe"]["safe_to_wake"] == true'
"$CLI" bind-pane --instance reviewer-main --pane alias-run --json >"$TMPROOT/bind-pane-reviewer-alias-run.json"
ruby --disable-gems -rjson -ryaml -rdigest -rtime -rfileutils -e '
  roles = YAML.safe_load(File.read(".orbit/roles.yaml"), aliases: true).fetch("roles")
  instances = YAML.safe_load(File.read(".orbit/instances.yaml"), aliases: true).fetch("instances")
  stable_instance = ->(value) {
    copy = JSON.parse(JSON.generate(value))
    %w[binding herdr view].each { |key| copy.delete(key) }
    copy
  }
  instance = instances.fetch("reviewer-main")
  role = roles.fetch(instance.fetch("role_ref"))
  now = Time.now.utc.iso8601
  session = {
    "schema_version"=>"orbit-runtime-session-v1",
    "session_id"=>"ors-force-old",
    "launch_id"=>"orl-force-old",
    "state"=>"active",
    "project_root"=>Dir.pwd,
    "project_root_sha256"=>Digest::SHA256.hexdigest(File.expand_path(Dir.pwd)),
    "project_id"=>File.basename(Dir.pwd),
    "host_id"=>"test-host",
    "user"=>"test-user",
    "instance"=>"reviewer-main",
    "role"=>"reviewer",
    "role_ref"=>"reviewer",
    "role_config_sha256"=>Digest::SHA256.hexdigest(JSON.generate(role)),
    "instance_config_sha256"=>Digest::SHA256.hexdigest(JSON.generate(stable_instance.call(instance))),
    "client"=>"codex",
    "command"=>"codex",
    "herdr"=>{"session"=>"","workspace"=>"","tab"=>"","pane"=>"alias-run","canonical_pane"=>"alias-run"},
    "identity"=>{"verification"=>"herdr_verified","whoami_valid"=>true,"conflicts"=>[]},
    "created_at"=>now,
    "updated_at"=>now,
    "heartbeat"=>{"last_seen_at"=>now,"ttl_seconds"=>300}
  }
  FileUtils.mkdir_p(".orbit/runtime/sessions")
  FileUtils.mkdir_p(".orbit/runtime/instances")
  File.write(".orbit/runtime/sessions/ors-force-old.json", JSON.pretty_generate(session) + "\n")
  File.write(".orbit/runtime/instances/reviewer-main.json", JSON.pretty_generate({"schema_version"=>"orbit-runtime-instance-v1","instance"=>"reviewer-main","current_session_id"=>"ors-force-old","current_state"=>"active","previous_sessions"=>[],"replacement_diagnostics"=>[],"ack"=>nil,"updated_at"=>now}) + "\n")
'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_RUN_ARGS:?}"
: "${ORBIT_FAKE_HERDR_WAIT_ARGS:?}"
case "$1 $2" in
  "pane get")
    if [ "$3" = "alias-run" ]; then
      printf '{"result":{"pane":{"pane_id":"canonical-run"}}}\n'
    else
      exit 1
    fi
    ;;
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  "pane read")
    test "$3" = "canonical-run" || exit 41
    printf 'project %%\n'
    ;;
  "pane run")
    test "$3" = "canonical-run" || exit 42
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_RUN_ARGS"
    printf 'running\n'
    ;;
  "wait output")
    test "$3" = "canonical-run" || exit 43
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_WAIT_ARGS"
    printf 'OpenAI Codex\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
ORBIT_FAKE_HERDR_RUN_ARGS="$TMPROOT/fake-herdr-wake-run-args.txt" ORBIT_FAKE_HERDR_WAIT_ARGS="$TMPROOT/fake-herdr-wake-wait-args.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --force --json >"$TMPROOT/start-reviewer-alias-wake-real.json"
json_assert 'start wakes canonical Herdr pane when forced and leaves identity pending' "$TMPROOT/start-reviewer-alias-wake-real.json" 'j["action"] == "started_identity_pending" && j["dispatch_ready"] == false && j["force"] == true && j["reuse_probe"]["pane"] == "alias-run" && j["reuse_probe"]["canonical_pane"] == "canonical-run" && j["wake_adapter"]["command"][0,4] == ["herdr", "pane", "run", "canonical-run"] && j["adapter_result"]["ready_wait"]["command"][0,4] == ["herdr", "wait", "output", "canonical-run"] && j["instance_status_after_start"]["herdr"]["pane"] == "canonical-run" && j["replacement"] == ".orbit/runtime/replacements/reviewer-main.json" && j["runtime_session"]["state"] == "pending" && j["runtime_session"]["identity"]["verification"] == "identity_pending"'
json_assert 'forced start appends runtime replacement diagnostic without losing session pointer' ".orbit/runtime/instances/reviewer-main.json" 'j["schema_version"] == "orbit-runtime-instance-v1" && j["instance"] == "reviewer-main" && j["current_session_id"].is_a?(String) && j["current_state"] == "pending" && j["replacement_diagnostics"].any? { |r| r["schema_version"] == "orbit-start-replacement-v1" && r["previous_binding"]["pane"] == "alias-run" && r["new_binding"]["pane"] == "canonical-run" && r["risk"].any? { |risk| risk["code"] == "duplicate_instance_agents_may_run_concurrently" } }'
json_assert 'forced start marks previous verified runtime session replaced' ".orbit/runtime/sessions/ors-force-old.json" 'j["state"] == "replaced" && j["identity"]["verification"] == "herdr_verified" && j["replacement"]["schema_version"] == "orbit-start-replacement-v1"'
expect_failure 'runtime register refuses to reactivate replaced session' env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID=ors-force-old ORBIT_LAUNCH_ID=orl-force-old PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime register --json
json_assert 'replaced session remains replaced after rejected register' ".orbit/runtime/sessions/ors-force-old.json" 'j["state"] == "replaced" && j.dig("identity", "verification") == "herdr_verified"'
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); abort(actual.inspect) unless actual[0,3] == ["pane","run","canonical-run"] && actual[3].include?("env ") && actual[3].include?("ORBIT_INSTANCE\\=reviewer-main") && actual[3].include?("ORBIT_ROLE\\=reviewer") && actual[3].include?("ORBIT_SESSION_ID\\=") && actual[3].include?("ORBIT_LAUNCH_ID\\=") && actual[3].end_with?(" codex")' "$TMPROOT/fake-herdr-wake-run-args.txt"
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); abort(actual.inspect) unless actual[0,3] == ["wait","output","canonical-run"] && actual.include?("OpenAI Codex|›")' "$TMPROOT/fake-herdr-wake-wait-args.txt"
pass 'start real force wake uses canonical Herdr pane'
"$CLI" bind-pane --instance reviewer-main --pane busy-pane --json >"$TMPROOT/bind-pane-reviewer-busy.json"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  "pane read")
    printf 'running build\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-needs-force-busy.json" 2>"$TMPROOT/start-reviewer-needs-force-busy.err"; then
  printf 'FAIL start stale busy binding: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start requires force for bound Herdr pane that is not safe to wake' "$TMPROOT/start-reviewer-needs-force-busy.json" 'j["action"] == "needs_force" && j["reuse_probe"]["agent_detected"] == false && j["reuse_probe"]["safe_to_wake"] == false && j["reuse_probe"]["decision"] == "needs_attention"'
"$CLI" bind-pane --instance reviewer-main --pane local-cache --json >"$TMPROOT/bind-pane-reviewer-local.json"
if "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-local-cache-needs-force.json" 2>"$TMPROOT/start-reviewer-local-cache-needs-force.err"; then
  printf 'FAIL start cached binding without live agent: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start refuses cached Herdr binding without live agent' "$TMPROOT/start-reviewer-local-cache-needs-force.json" 'j["action"] == "needs_force" && j["liveness_source"] == "herdr_probe" && j["reuse_probe"]["decision"] == "needs_attention" && j["force_command"] == ["orbit", "start", "reviewer-main", "--force"]'
"$CLI" start reviewer-main --force --dry-run --json >"$TMPROOT/start-reviewer-local-cache-force-dry-run.json"
json_assert 'start force allows dry-run over cached binding' "$TMPROOT/start-reviewer-local-cache-force-dry-run.json" 'j["action"] == "dry_run" && j["force"] == true && j["risk"].any? { |r| r["code"] == "old_external_process_may_still_exist" }'
"$CLI" init --force --operation-mode solo >/dev/null
mkdir -p .orbit/runtime/locks
ruby --disable-gems -e 'File.open(".orbit/runtime/locks/start-reviewer-main.lock", File::RDWR | File::CREAT, 0o600) { |f| f.flock(File::LOCK_EX); File.write(ARGV[0], "ready"); sleep 10 }' "$TMPROOT/start-reviewer-lock-ready" &
START_LOCK_PID=$!
while [ ! -f "$TMPROOT/start-reviewer-lock-ready" ]; do
  sleep 0.05
done
if "$CLI" start reviewer-main --force --json >"$TMPROOT/start-reviewer-force-lock-busy.json" 2>"$TMPROOT/start-reviewer-force-lock-busy.err"; then
  printf 'FAIL start force lock busy: command unexpectedly succeeded\n' >&2
  kill "$START_LOCK_PID" 2>/dev/null || true
  wait "$START_LOCK_PID" 2>/dev/null || true
  exit 1
fi
kill "$START_LOCK_PID" 2>/dev/null || true
wait "$START_LOCK_PID" 2>/dev/null || true
json_assert 'start force refuses concurrent replacement when instance lock is held' "$TMPROOT/start-reviewer-force-lock-busy.json" 'j["action"] == "needs_attention" && j["reason"] == "start_in_progress" && j["liveness_reason"].include?("another forced start")'
"$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-reviewer-main.json"
json_assert 'start dry-run resolves instance command env cwd client and context metadata' "$TMPROOT/start-reviewer-main.json" 'j["schema_version"] == "orbit-start-plan-v1" && j["action"] == "dry_run" && j["adapter"] == "herdr" && j["instance"] == "reviewer-main" && j["argv"] == ["codex"] && j["client"]["expected_client"] == "codex" && j["client"]["full_permission"]["known_client"] == true && j["client"]["full_permission"]["configured"] == false && j["env"]["ORBIT_INSTANCE"] == "reviewer-main" && j["env"]["ORBIT_ROLE"] == "reviewer" && j["env"]["ORBIT_SESSION_ID"].is_a?(String) && j["env"]["ORBIT_LAUNCH_ID"].is_a?(String) && j["cwd"] == Dir.pwd && j["context_preflight"]["commands"][0] == ["orbit", "whoami", "--json"] && !j["context_preflight"]["commands"].include?(["orbit", "runtime", "register", "--json"]) && j["context_preflight"]["required_files"].any? { |r| r["path"] == "skills/orbit/SKILL.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "skills/orbit/references/runtime/guide.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "skills/orbit/references/runtime/quality-outcome-and-review.md" }'
mkdir -p "$TMPROOT/project/subdir"
expect_failure 'start rejects cwd outside Orbit project root' "$CLI" start reviewer-main --cwd "$TMPROOT/project/subdir" --dry-run --json
"$CLI" start reviewer-main --dry-run >"$TMPROOT/start-reviewer-human.txt" 2>"$TMPROOT/start-reviewer-human.err"
test ! -s "$TMPROOT/start-reviewer-human.err"
grep -q 'Orbit start plan:' "$TMPROOT/start-reviewer-human.txt"
grep -q -- '- instance: reviewer-main' "$TMPROOT/start-reviewer-human.txt"
grep -q -- '- command: codex' "$TMPROOT/start-reviewer-human.txt"
pass 'start dry-run works without json'
env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_TAB -u HERDR_WORKSPACE_ID -u HERDR_WORKSPACE "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-herdr-dry-run.json"
json_assert 'start herdr dry-run emits adapter plan' "$TMPROOT/start-herdr-dry-run.json" 'cmd=j["herdr_start"]["command"]; sep=cmd.index("--"); j["schema_version"] == "orbit-start-plan-v1" && j["action"] == "dry_run" && j["adapter"] == "herdr" && j["herdr_start"]["schema_version"] == "orbit-herdr-start-v1" && cmd[0,7] == ["herdr", "agent", "start", "reviewer-main", "--cwd", Dir.pwd, "--no-focus"] && sep == 7 && cmd[sep + 1] == "env" && cmd.include?("ORBIT_INSTANCE=reviewer-main") && cmd.include?("ORBIT_ROLE=reviewer") && cmd.any? { |part| part.start_with?("ORBIT_SESSION_ID=") } && cmd.any? { |part| part.start_with?("ORBIT_LAUNCH_ID=") } && cmd.last == "codex" && j["herdr_start"]["env"]["ORBIT_INSTANCE"] == "reviewer-main" && j["herdr_start"]["ready_wait"]["mode"] == "output_match"'
json_assert 'start herdr dry-run exposes create policy and permission setup' "$TMPROOT/start-herdr-dry-run.json" 'j["creation_policy"]["reuse_first"] == true && j["creation_policy"]["same_level_view"]["strategy"] == "default_view" && j["creation_policy"]["permission_setup"]["required"] == true && j["creation_policy"]["permission_setup"]["summary"].include?("does not silently bypass")'
mkdir -p "$TMPROOT/fakebin"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "pane layout")
    printf '{"result":{"layout":{"tab_id":"lead-tab","workspace_id":"lead-workspace","panes":[{"pane_id":"lead-pane","focused":true,"rect":{"width":260,"height":50}}]}}}\n'
    ;;
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"lead-pane","tab_id":"lead-tab","agent":"codex","agent_status":"idle"}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
env HERDR_PANE_ID=lead-pane HERDR_TAB_ID=lead-tab PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-herdr-same-tab-dry-run.json"
json_assert 'start herdr uses same tab only when layout stays readable' "$TMPROOT/start-herdr-same-tab-dry-run.json" 'cmd=j["herdr_start"]["command"]; sep=cmd.index("--"); j["creation_policy"]["same_level_view"]["strategy"] == "same_tab" && j["layout"]["selected"] == "same_tab" && j["layout"]["source_pane_size"] == {"cols"=>260, "rows"=>50} && j["layout"]["projected_same_tab_size"] == {"cols"=>130, "rows"=>50} && j["layout"]["existing_agent_panes_in_tab"] == 1 && cmd[0,11] == ["herdr", "agent", "start", "reviewer-main", "--cwd", Dir.pwd, "--tab", "lead-tab", "--split", "right", "--no-focus"] && sep == 11 && cmd[sep + 1] == "env" && cmd.include?("ORBIT_INSTANCE=reviewer-main") && cmd.include?("ORBIT_ROLE=reviewer") && cmd.last == "codex"'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "pane layout")
    printf '{"result":{"layout":{"tab_id":"lead-tab","workspace_id":"lead-workspace","panes":[{"pane_id":"lead-pane","focused":true,"rect":{"width":120,"height":50}}]}}}\n'
    ;;
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"lead-pane","tab_id":"lead-tab","agent":"codex","agent_status":"idle"}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
env HERDR_PANE_ID=lead-pane HERDR_TAB_ID=lead-tab PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-herdr-auto-new-tab-dry-run.json"
json_assert 'start herdr auto chooses new tab when same-tab split would be unreadable' "$TMPROOT/start-herdr-auto-new-tab-dry-run.json" 'cmd=j["herdr_start"]["command"]; sep=cmd.index("--"); j["action"] == "dry_run" && j["layout"]["selected"] == "new_tab" && j["layout"]["projected_same_tab_size"] == {"cols"=>60, "rows"=>50} && j["layout"]["reason"].include?("below minimum") && cmd[0,9] == ["herdr", "agent", "start", "reviewer-main", "--cwd", Dir.pwd, "--workspace", "lead-workspace", "--no-focus"] && sep == 9 && cmd[sep + 1] == "env" && cmd.include?("ORBIT_INSTANCE=reviewer-main") && cmd.include?("ORBIT_ROLE=reviewer") && cmd.last == "codex"'
if env HERDR_PANE_ID=lead-pane HERDR_TAB_ID=lead-tab PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --layout same-tab --dry-run --json >"$TMPROOT/start-herdr-same-tab-blocked.json" 2>"$TMPROOT/start-herdr-same-tab-blocked.err"; then
  printf 'FAIL start same-tab unreadable layout: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start herdr same-tab fails closed when split would be unreadable' "$TMPROOT/start-herdr-same-tab-blocked.json" 'j["action"] == "blocked" && j["layout"]["selected"] == "same_tab" && j["layout"]["blocked"] == true && j["layout"]["reason"].include?("below minimum")'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_ARGS:?}"
: "${ORBIT_FAKE_HERDR_ENV:?}"
: "${ORBIT_FAKE_HERDR_CWD:?}"
case "$1 $2" in
  "pane layout")
    printf '{"result":{"layout":{"tab_id":"lead-tab","workspace_id":"lead-workspace","panes":[{"pane_id":"lead-pane","focused":true,"rect":{"width":260,"height":50}}]}}}\n'
    ;;
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"lead-pane","tab_id":"lead-tab","agent":"codex","agent_status":"idle"}]}}\n'
    ;;
  "agent start")
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_ARGS"
    printf '%s/%s\n' "$ORBIT_INSTANCE" "$ORBIT_ROLE" >"$ORBIT_FAKE_HERDR_ENV"
    pwd >"$ORBIT_FAKE_HERDR_CWD"
    printf '{"result":{"agent":{"pane_id":"fake-pane","agent":"codex"}}}\n'
    ;;
  "wait output")
    : "${ORBIT_FAKE_HERDR_WAIT_ARGS:?}"
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_WAIT_ARGS"
    printf 'OpenAI Codex\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
ORBIT_FAKE_HERDR_ARGS="$TMPROOT/fake-herdr-args.txt" ORBIT_FAKE_HERDR_WAIT_ARGS="$TMPROOT/fake-herdr-wait-args.txt" ORBIT_FAKE_HERDR_ENV="$TMPROOT/fake-herdr-env.txt" ORBIT_FAKE_HERDR_CWD="$TMPROOT/fake-herdr-cwd.txt" HERDR_PANE_ID=lead-pane HERDR_TAB_ID=lead-tab PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --json >"$TMPROOT/start-herdr-real.json"
json_assert 'start herdr invokes adapter, records actual client, and waits for runtime identity' "$TMPROOT/start-herdr-real.json" 'j["action"] == "started_identity_pending" && j["dispatch_ready"] == false && j["adapter_result"]["success"] == true && j["adapter_result"]["stdout"].include?("fake-pane") && j["adapter_result"]["pane_id"] == "fake-pane" && j["adapter_result"]["ready_wait"]["success"] == true && j["creation_policy"]["same_level_view"]["strategy"] == "same_tab" && j["instance_status_after_start"]["herdr"]["tab"] == "lead-tab" && j["instance_status_after_start"]["herdr"]["pane"] == "fake-pane" && j["runtime_session"]["state"] == "pending" && j["runtime_session"]["identity"]["verification"] == "identity_pending"'
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); sep=actual.index("--"); cwd_ok=[Dir.pwd, File.realpath(Dir.pwd)].include?(actual[4]); abort(actual.inspect) unless actual[0,4] == ["agent","start","reviewer-main","--cwd"] && cwd_ok && actual[5,6] == ["--tab","lead-tab","--split","right","--no-focus","--"] && sep == 10 && actual[sep + 1] == "env" && actual.include?("ORBIT_INSTANCE=reviewer-main") && actual.include?("ORBIT_ROLE=reviewer") && actual.any? { |part| part.start_with?("ORBIT_SESSION_ID=") } && actual.any? { |part| part.start_with?("ORBIT_LAUNCH_ID=") } && actual.last == "codex"' "$TMPROOT/fake-herdr-args.txt"
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); abort(actual.inspect) unless actual[0,3] == ["wait","output","fake-pane"] && actual.include?("--regex") && actual.include?("OpenAI Codex|›")' "$TMPROOT/fake-herdr-wait-args.txt"
grep -qx 'reviewer-main/reviewer' "$TMPROOT/fake-herdr-env.txt"
grep -qx "$PROJECT" "$TMPROOT/fake-herdr-cwd.txt"
pass 'start herdr passes argv env cwd and waits for codex readiness'

cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_ARGS:?}"
: "${ORBIT_FAKE_HERDR_ENV:?}"
: "${ORBIT_FAKE_HERDR_CWD:?}"
case "$1 $2" in
  "pane layout")
    printf '{"result":{"layout":{"tab_id":"lead-tab","workspace_id":"lead-workspace","panes":[{"pane_id":"lead-pane","focused":true,"rect":{"width":260,"height":50}}]}}}\n'
    ;;
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"lead-pane","tab_id":"lead-tab","agent":"codex","agent_status":"idle"}]}}\n'
    ;;
  "agent start")
    printf '%s\n' "$@" >>"$ORBIT_FAKE_HERDR_ARGS"
    printf '%s\n' '---' >>"$ORBIT_FAKE_HERDR_ARGS"
    printf '%s/%s\n' "$ORBIT_INSTANCE" "$ORBIT_ROLE" >>"$ORBIT_FAKE_HERDR_ENV"
    pwd >>"$ORBIT_FAKE_HERDR_CWD"
    if [ "$3" = "reviewer-main" ]; then
      printf '{"error":{"code":"agent_name_taken","message":"agent name reviewer-main is already used"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"agent":{"pane_id":"retry-pane","agent":"codex"}}}\n'
    ;;
  "wait output")
    printf 'OpenAI Codex\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
"$CLI" init --force --operation-mode solo >/dev/null
ORBIT_FAKE_HERDR_ARGS="$TMPROOT/fake-herdr-retry-args.txt" ORBIT_FAKE_HERDR_ENV="$TMPROOT/fake-herdr-retry-env.txt" ORBIT_FAKE_HERDR_CWD="$TMPROOT/fake-herdr-retry-cwd.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main --json >"$TMPROOT/start-herdr-agent-name-taken-retry.json"
json_assert 'start herdr retries agent_name_taken with unique label' "$TMPROOT/start-herdr-agent-name-taken-retry.json" 'j["action"] == "started_identity_pending" && j["dispatch_ready"] == false && j["adapter_result"]["success"] == true && j["adapter_result"]["pane_id"] == "retry-pane" && j["adapter_result"]["retry"]["reason"] == "agent_name_taken" && j["adapter_result"]["retry"]["label"].start_with?("project-reviewer-main-") && j["adapter_result"]["retry"]["command"][0,3] == ["herdr", "agent", "start"] && j["adapter_result"]["retry"]["command"][3] == j["adapter_result"]["retry"]["label"] && j["instance_status_after_start"]["herdr"]["pane"] == "retry-pane" && j["runtime_session"]["state"] == "pending"'
RETRY_LABEL=$(ruby --disable-gems -rjson -e 'j=JSON.parse(File.read(ARGV[0])); print j["adapter_result"]["retry"]["label"]' "$TMPROOT/start-herdr-agent-name-taken-retry.json")
ruby --disable-gems -e 'entries=File.read(ARGV[0]).split("---\n").map { |s| s.lines.map(&:chomp).reject(&:empty?) }; abort(entries.inspect) unless entries.length == 2 && entries[0][0,4] == ["agent","start","reviewer-main","--cwd"] && entries[1][0,3] == ["agent","start",ARGV[1]]' "$TMPROOT/fake-herdr-retry-args.txt" "$RETRY_LABEL"
grep -qx 'reviewer-main/reviewer' "$TMPROOT/fake-herdr-retry-env.txt"
pass 'start herdr preserves Orbit identity across retry label'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_ARGS:?}"
: "${ORBIT_FAKE_HERDR_ENV:?}"
: "${ORBIT_FAKE_HERDR_CWD:?}"
case "$1 $2" in
  "agent start")
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_ARGS"
    printf '%s/%s\n' "$ORBIT_INSTANCE" "$ORBIT_ROLE" >"$ORBIT_FAKE_HERDR_ENV"
    pwd >"$ORBIT_FAKE_HERDR_CWD"
    printf '{"result":{"agent":{"pane_id":"fake-pane","agent":"codex"}}}\n'
    ;;
  "wait output")
    : "${ORBIT_FAKE_HERDR_WAIT_ARGS:?}"
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_WAIT_ARGS"
    printf 'OpenAI Codex\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
"$CLI" init --force --operation-mode solo >/dev/null
ORBIT_FAKE_HERDR_ARGS="$TMPROOT/fake-herdr-human-args.txt" ORBIT_FAKE_HERDR_WAIT_ARGS="$TMPROOT/fake-herdr-human-wait-args.txt" ORBIT_FAKE_HERDR_ENV="$TMPROOT/fake-herdr-human-env.txt" ORBIT_FAKE_HERDR_CWD="$TMPROOT/fake-herdr-human-cwd.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer-main >"$TMPROOT/start-herdr-human.txt" 2>"$TMPROOT/start-herdr-human.err"
test ! -s "$TMPROOT/start-herdr-human.err"
grep -q 'Started Orbit instance:' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- instance: reviewer-main' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- pane: fake-pane' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- ready: pass' "$TMPROOT/start-herdr-human.txt"
pass 'start herdr works without json'
cp .orbit/instances.yaml "$TMPROOT/start-instances.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["command"]="printf;printf"; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'start rejects shell metacharacter command string' "$CLI" start reviewer-main --dry-run --json
cp "$TMPROOT/start-instances.yaml.bak" .orbit/instances.yaml
expect_failure 'start rejects unknown instance' "$CLI" start missing --dry-run --json
yaml_assert 'init creates loop state from template' .orbit/loop-state.yaml 'j["schema_version"] == "orbit-loop-state-v1" && j["project"] == File.basename(Dir.pwd) && j["phase"] == "idle" && j["status"] == "idle" && j["history"].is_a?(Array) && j["budget"].is_a?(Hash) && j["artifacts"].is_a?(Hash)'
yaml_assert 'init leaves project rules empty by default' .orbit/roles.yaml 'j["roles"].values.all? { |role| role["rules"].is_a?(Array) && role["rules"].empty? }'

ruby --disable-gems -e 'File.open(ARGV[0], "a") { |f| f.puts "# local edit" }' .orbit/roles.yaml
expect_failure 'init refuses overwrite' "$CLI" init
ruby --disable-gems -e 'abort unless File.readlines(ARGV[0]).last.include?("# local edit")' .orbit/roles.yaml
pass 'init preserves existing local edit'
"$CLI" init --force --operation-mode solo >/dev/null
yaml_assert 'init --force overwrites with solo template defaults' .orbit/roles.yaml 'j.dig("operation_defaults","operation_mode") == "solo" && j.dig("operation_defaults","assigned_instance") == "lead-main" && !File.read(ARGV[0]).include?("# local edit")'
yaml_assert 'init --force regenerates loop state' .orbit/loop-state.yaml 'j["schema_version"] == "orbit-loop-state-v1" && j["project"] == File.basename(Dir.pwd) && j["phase"] == "idle"'

"$CLI" state show --json >"$TMPROOT/state.json" 2>"$TMPROOT/state.err"
test ! -s "$TMPROOT/state.err"
json_assert 'state show outputs loop state json' "$TMPROOT/state.json" 'j["schema_version"] == "orbit-loop-state-v1" && j["project"] == File.basename(Dir.pwd) && j["phase"] == "idle" && j["history"].is_a?(Array)'
"$CLI" state show --json --state .orbit/loop-state.yaml >"$TMPROOT/state-custom.json"
json_assert 'state show supports explicit state path' "$TMPROOT/state-custom.json" 'j["schema_version"] == "orbit-loop-state-v1"'
expect_failure 'state show requires json' "$CLI" state show
expect_failure 'state show rejects missing state option value' "$CLI" state show --json --state
cp .orbit/loop-state.yaml "$TMPROOT/loop-state.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["budget"]="bad"; File.write(p, YAML.dump(y))' .orbit/loop-state.yaml
expect_failure 'state show fails invalid optional budget' "$CLI" state show --json
cp "$TMPROOT/loop-state.yaml.bak" .orbit/loop-state.yaml

"$CLI" validate --json >"$TMPROOT/valid-project.json" 2>"$TMPROOT/valid-project.err"
test ! -s "$TMPROOT/valid-project.err"
json_assert 'validate project config passes' "$TMPROOT/valid-project.json" 'j["valid"] == true && j["checked"] == ["project_config"] && j["trust_level"]["mode"] == "audit_only" && j["trust_level"]["known_bypasses"].is_a?(Array) && j["trust_level"]["required_before_done"].is_a?(Array)'
cp .orbit/instances.yaml "$TMPROOT/schema-instances.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["command"]=["codex","--profile","review"]; File.write(p, YAML.dump(y))' .orbit/instances.yaml
"$CLI" validate --json >"$TMPROOT/valid-array-command.json"
json_assert 'validate accepts array instance command' "$TMPROOT/valid-array-command.json" 'j["valid"] == true'
"$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-array-command.json"
json_assert 'start dry-run preserves array instance command' "$TMPROOT/start-array-command.json" 'j["argv"] == ["codex", "--profile", "review"]'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["command"]=["/usr/local/bin/codex"]; File.write(p, YAML.dump(y))' .orbit/instances.yaml
"$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-absolute-codex-command.json"
json_assert 'start ready wait uses basename for absolute client command' "$TMPROOT/start-absolute-codex-command.json" 'j["argv"] == ["/usr/local/bin/codex"] && j["client"]["expected_client"] == "codex" && j["herdr_start"]["ready_wait"]["mode"] == "output_match" && j["herdr_start"]["ready_wait"]["match"].include?("OpenAI Codex")'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["command"]=["codex","--dangerously-bypass-approvals-and-sandbox"]; y["instances"]["lead-main"]["command"]=["claude","--dangerously-skip-permissions"]; y["instances"]["tester-main"]["command"]=["opencode","run","--interactive","--dangerously-skip-permissions"]; File.write(p, YAML.dump(y))' .orbit/instances.yaml
"$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-codex-full-permission.json"
"$CLI" start lead-main --dry-run --json >"$TMPROOT/start-claude-full-permission.json"
"$CLI" start tester-main --dry-run --json >"$TMPROOT/start-opencode-full-permission.json"
json_assert 'start dry-run audits codex full-permission flag' "$TMPROOT/start-codex-full-permission.json" 'j["client"]["expected_client"] == "codex" && j["client"]["full_permission"]["configured"] == true && j["client"]["full_permission"]["present_flags"].include?("--dangerously-bypass-approvals-and-sandbox")'
json_assert 'start dry-run audits claude full-permission flag' "$TMPROOT/start-claude-full-permission.json" 'j["client"]["expected_client"] == "claude" && j["client"]["full_permission"]["configured"] == true && j["client"]["full_permission"]["present_flags"].include?("--dangerously-skip-permissions")'
json_assert 'start dry-run audits opencode full-permission flag' "$TMPROOT/start-opencode-full-permission.json" 'j["client"]["expected_client"] == "opencode" && j["client"]["full_permission"]["configured"] == true && j["client"]["full_permission"]["present_flags"].include?("--dangerously-skip-permissions")'
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["command"]=""; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate rejects empty instance command' "$CLI" validate --json
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["env"]=["bad"]; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate rejects non-mapping instance env' "$CLI" validate --json
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["env"]["ORBIT_ROLE"]=7; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate rejects non-string instance env value' "$CLI" validate --json
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["env"]["ORBIT_INSTANCE"]="other"; y["instances"]["reviewer-main"]["env"]["ORBIT_ROLE"]="lead"; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate rejects reserved instance env identity mismatch' "$CLI" validate --json
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
mkdir -p "$TMPROOT/evidence-dir"
if "$CLI" validate --evidence "$TMPROOT/evidence-dir" --json >"$TMPROOT/validate-evidence-dir.json" 2>"$TMPROOT/validate-evidence-dir.err"; then
  printf 'FAIL validate evidence directory: command unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -s "$TMPROOT/validate-evidence-dir.err"
json_assert 'validate evidence directory reports manifest hint' "$TMPROOT/validate-evidence-dir.json" 'j["valid"] == false && j["errors"].any? { |e| e["source"] == "evidence_file" && e["message"].include?("got directory") && e["message"].include?("orbit evidence init") }'
"$CLI" tools detect --json >"$TMPROOT/tools-detect.json" 2>"$TMPROOT/tools-detect.err"
test ! -s "$TMPROOT/tools-detect.err"
json_assert 'tools detect outputs Herdr-only capabilities' "$TMPROOT/tools-detect.json" 'j["schema_version"] == "orbit-tools-v1" && j["detected"].any? { |t| t["name"] == "local_shell" && t["available"] == true } && %w[herdr ci git].all? { |name| j["detected"].any? { |t| t["name"] == name && [true, false].include?(t["available"]) } } && j["detected"].find { |t| t["name"] == "herdr" }["capabilities"].none? { |c| c == "notice.delivery" } && !j["detected"].any? { |t| t["name"] == "tmux" }'
"$CLI" tools doctor --json >"$TMPROOT/tools-doctor.json" 2>"$TMPROOT/tools-doctor.err"
test ! -s "$TMPROOT/tools-doctor.err"
json_assert 'tools doctor reports Herdr runtime adapter diagnostics' "$TMPROOT/tools-doctor.json" 'j["schema_version"] == "orbit-tools-doctor-v1" && %w[pass warn].include?(j["health"]) && %w[herdr unavailable].include?(j["runtime_adapter"]) && j["manual_payload_available"] == true && j["agent_state_authority"].is_a?(Hash) && j["herdr_diagnostics"].is_a?(Hash) && j["herdr_diagnostics"]["current_pane"].is_a?(Hash) && j["herdr_diagnostics"]["configured_bindings"].is_a?(Array) && j["herdr_diagnostics"]["client_integration_authority"].is_a?(Hash) && j["herdr_diagnostics"]["inner_tmux"].is_a?(Hash) && j["detected"].any? { |t| t["name"] == "local_shell" && t["available"] == true } && !j["detected"].any? { |t| t["name"] == "tmux" } && j["findings"].is_a?(Array)'
expect_failure 'tools detect requires json' "$CLI" tools detect
expect_failure 'tools rejects missing subcommand' "$CLI" tools

mkdir -p docs/open docs/archive
printf '%s\n' '# Active Design' 'status: active' >docs/open/active.md
printf '%s\n' '# Archive' >docs/archive/README.md
"$CLI" docs alias --id docs.active --path docs/open/active.md --registry "$TMPROOT/docs-registry.json" --json >"$TMPROOT/docs-alias.json"
json_assert 'docs alias writes stable doc registry entry' "$TMPROOT/docs-alias.json" 'j["schema_version"] == "orbit-docs-alias-v1" && j["entry"]["id"] == "docs.active" && j["entry"]["current_path"] == "docs/open/active.md" && j["entry"]["content_hash"].start_with?("sha256:")'
"$CLI" docs check --registry "$TMPROOT/docs-registry.json" --open-dir docs/open --archive-dir docs/archive --json >"$TMPROOT/docs-check-valid.json"
json_assert 'docs check passes valid registry' "$TMPROOT/docs-check-valid.json" 'j["schema_version"] == "orbit-docs-check-v1" && j["valid"] == true && j["aliases"].any? { |a| a["id"] == "docs.active" && a["exists"] == true && a["hash_matches"] == true }'
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["docs"]["docs.active"]["current_path"]="docs/open/missing.md"; j["docs"]["docs.active"]["absolute_path"]=""; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/docs-registry.json"
if "$CLI" docs check --registry "$TMPROOT/docs-registry.json" --open-dir docs/open --archive-dir docs/archive --json >"$TMPROOT/docs-check-missing.json"; then
  printf 'FAIL docs check missing alias: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'docs check fails missing alias target' "$TMPROOT/docs-check-missing.json" 'j["valid"] == false && j["issues"].any? { |i| i["source"] == "docs_registry.docs.active.current_path" }'
printf '%s\n' '# Done Design' 'status: done' >docs/open/done.md
"$CLI" docs alias --id docs.active --path docs/open/active.md --registry "$TMPROOT/docs-registry.json" --json >/dev/null
if "$CLI" docs check --registry "$TMPROOT/docs-registry.json" --open-dir docs/open --archive-dir docs/archive --json >"$TMPROOT/docs-check-closed-open.json"; then
  printf 'FAIL docs check closed open doc: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'docs check reports closed open docs not archived or indexed' "$TMPROOT/docs-check-closed-open.json" 'j["valid"] == false && j["open_docs"].any? { |d| d["path"] == "docs/open/done.md" && d["issue"] == "closed_open_doc_not_archived_or_indexed" }'

NO_CFG="$TMPROOT/no-config"
mkdir -p "$NO_CFG"
cd "$NO_CFG"
expect_failure 'validate fails without project config' "$CLI" validate --json
expect_failure 'state show fails without loop state' "$CLI" state show --json
cd "$PROJECT"

cp .orbit/roles.yaml "$TMPROOT/roles.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("capability_registry"); File.write(p, YAML.dump(y))' .orbit/roles.yaml
expect_failure 'validate fails without capability_registry' "$CLI" validate --json
cp "$TMPROOT/roles.yaml.bak" .orbit/roles.yaml

cp .orbit/instances.yaml "$TMPROOT/instances.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["role_ref"]="missing-role"; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate fails on missing role_ref target' "$CLI" validate --json
cp "$TMPROOT/instances.yaml.bak" .orbit/instances.yaml

ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["binding"] ||= {}; y["instances"]["reviewer-main"]["binding"]["view"]={"min_columns"=>120}; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate fails when instance view is nested under binding' "$CLI" validate --json
cp "$TMPROOT/instances.yaml.bak" .orbit/instances.yaml

for pair in lead-main:lead reviewer-main:reviewer tester-main:tester; do
  instance=${pair%%:*}
  role=${pair##*:}
  env ORBIT_INSTANCE="$instance" ORBIT_ROLE="$role" "$CLI" whoami --json >"$TMPROOT/whoami-$role.json" 2>"$TMPROOT/whoami-$role.err"
  test ! -s "$TMPROOT/whoami-$role.err"
  json_assert "whoami resolves $role" "$TMPROOT/whoami-$role.json" "j[\"resolved_role\"] == \"$role\" && j[\"instance\"] == \"$instance\" && j[\"resolved_instance\"] == \"$instance\" && j[\"role_ref\"] == \"$role\" && j[\"expected_command\"] == \"codex\" && j[\"herdr\"].is_a?(Hash) && !j.key?(\"transport_binding\") && j[\"conflicts\"].empty?"
done
expect_failure 'whoami rejects role-name alias when concrete instance key is required' env ORBIT_INSTANCE=lead ORBIT_ROLE=lead "$CLI" whoami --json
env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_CLIENT=codex "$CLI" whoami --json >"$TMPROOT/whoami-reviewer-client.json"
json_assert 'whoami exposes actual client from env' "$TMPROOT/whoami-reviewer-client.json" 'j["actual_client"] == "codex" && !j.key?("binding_status") && j["binding"] == "unbound"'
expect_failure 'whoami fails on actual client mismatch' env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_CLIENT=opencode "$CLI" whoami --json
json_assert 'whoami returns no project rules until user configures them' "$TMPROOT/whoami-reviewer.json" 'j["rules"].is_a?(Array) && j["rules"].empty?'

env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer "$CLI" whoami --json >"$TMPROOT/whoami-reviewer-main.json"
json_assert 'whoami supports reviewer-main instance' "$TMPROOT/whoami-reviewer-main.json" 'j["resolved_role"] == "reviewer" && j["instance"] == "reviewer-main" && j["resolved_instance"] == "reviewer-main"'

ORBIT_ROLE=reviewer "$CLI" whoami --json >"$TMPROOT/whoami-role-only.json"
json_assert 'whoami infers unique instance from role' "$TMPROOT/whoami-role-only.json" 'j["resolved_role"] == "reviewer" && j["conflicts"].empty?'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y={"schema_version"=>"orbit-rule-packs-v1","rule_packs"=>{"common"=>["project-common"],"review"=>[{"id"=>"brooks-review","path"=>".orbit/rule-packs/brooks-review.md"}],"test"=>["brooks-test"],"audit"=>["orbit-drift"]}}; File.write(p, YAML.dump(y))' .orbit/rule-packs.yaml
ORBIT_INSTANCE=reviewer-main "$CLI" whoami --json >"$TMPROOT/whoami-reviewer-rule-packs.json"
json_assert 'whoami exposes configured review rule packs' "$TMPROOT/whoami-reviewer-rule-packs.json" 'j["rule_packs"].any? { |p| p["category"] == "common" && p["id"] == "project-common" } && j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" && p["path"] == ".orbit/rule-packs/brooks-review.md" }'

expect_failure 'whoami fails on env role conflict' env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=lead "$CLI" whoami --json
expect_failure 'whoami fails on unknown instance' env ORBIT_INSTANCE=missing "$CLI" whoami --json
expect_failure 'whoami fails without runtime identity' "$CLI" whoami --json
