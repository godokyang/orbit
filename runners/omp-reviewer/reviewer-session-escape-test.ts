// No-model restricted-session escape negative. Spawns reviewer.ts; no model request.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), "orbit-reviewer-session-"));
const snapshot = path.join(work, "snapshot");
const outside = path.join(work, "outside");
const profile = path.join(work, "profile");
const secret = "OUTSIDE_SECRET";
mkdirSync(snapshot);
mkdirSync(outside);
mkdirSync(profile);
writeFileSync(path.join(snapshot, "inside.txt"), "INSIDE_OK\n");
writeFileSync(path.join(outside, "secret.txt"), `${secret} must not reach the session tool\n`);
symlinkSync(path.join(snapshot, "inside.txt"), path.join(snapshot, "inside-link.txt"));
symlinkSync(path.join(outside, "secret.txt"), path.join(snapshot, ".probe-escape"));
symlinkSync(outside, path.join(snapshot, ".probe-dir-escape"));
const config = path.join(work, "request.json");
const out = path.join(work, "evidence.json");
writeFileSync(config, JSON.stringify({
	snapshot,
	profile,
	out,
	probe_outside: path.join(outside, "secret.txt"),
	probe_inside: "inside.txt",
	probe_inside_link: "inside-link.txt",
	probe_symlink_file: ".probe-escape",
	probe_symlink_dir: ".probe-dir-escape/secret.txt",
	probe_secret: secret,
}));

let status = 0;
let stderr = "";
try {
	execFileSync("bun", [path.join(here, "reviewer.ts"), "--config", config], {
		encoding: "utf8",
		env: { ...process.env, PI_CODING_AGENT_DIR: profile, OMP_PROFILE: undefined },
		stdio: ["ignore", "pipe", "pipe"],
	});
} catch (error) {
	const failed = error as { status?: number; stderr?: string; stdout?: string };
	status = failed.status ?? 1;
	stderr = `${failed.stderr ?? ""}\n${failed.stdout ?? ""}`;
}

if (status !== 0) {
	console.error(stderr || `reviewer exited ${status}`);
	process.exit(status || 1);
}
const evidence = JSON.parse(readFileSync(out, "utf8"));
const failures: string[] = [];
if (evidence.ok !== true) failures.push(`ok is not true: ${JSON.stringify(evidence.problems)}`);
if (evidence.review_ran !== false || evidence.result !== null) failures.push("no-model run forged a check result");
if (evidence.model !== undefined && evidence.model !== null) failures.push(`model was contacted or recorded: ${evidence.model}`);
if (JSON.stringify(evidence).includes(secret)) failures.push("evidence contains outside secret");
if (evidence.active_tools?.join() !== "glob,grep,read") failures.push(`active tools: ${evidence.active_tools}`);
if (evidence.forbidden_tools_present?.length) failures.push(`forbidden tools: ${evidence.forbidden_tools_present}`);
if (evidence.read_tool_is_confined !== true) failures.push("session read tool is not the confined replacement");
if (evidence.global_registry?.length) failures.push(`global registry: ${evidence.global_registry}`);
if (!evidence.fingerprint_before || evidence.fingerprint_before !== evidence.fingerprint_after) {
	failures.push("snapshot fingerprint missing or changed");
}
const probe = evidence.probe ?? {};
for (const [label, item] of Object.entries(probe) as Array<[string, { pass?: boolean }]>) {
	if (item.pass !== true) failures.push(`probe ${label} did not pass`);
}
for (const required of ["read_absolute_outside", "read_relative_escape", "read_home", "read_file_url", "read_symlink_file_escape", "read_symlink_dir_escape", "grep_outside", "glob_pattern_escape"]) {
	if (!probe[required]) failures.push(`missing probe ${required}`);
}
if (failures.length) {
	console.error(failures.map(item => `FAIL ${item}`).join("\n"));
	process.exit(1);
}
console.log(`PASS restricted session rejected escapes; fingerprints ${evidence.fingerprint_before}`);
