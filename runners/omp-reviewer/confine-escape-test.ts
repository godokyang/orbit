// Real escape negatives for confined read/grep/glob. No test framework.
// Exit 0 only when every outside path is rejected and no outside bytes are returned.
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createConfinedTools, OutsideSnapshotError } from "./confined-tools.ts";

const snapshot = mkdtempSync(path.join(tmpdir(), "orbit-confine-snap-"));
const outside = mkdtempSync(path.join(tmpdir(), "orbit-confine-out-"));
const secret = "OUTSIDE_SECRET";
mkdirSync(path.join(snapshot, "src"));
writeFileSync(path.join(snapshot, "src", "sum.js"), "export function sum() { return 1; }\n");
writeFileSync(path.join(snapshot, "inside.txt"), "INSIDE_OK\n");
writeFileSync(path.join(outside, "secret.txt"), `${secret} must not be readable\n`);
symlinkSync(path.join(snapshot, "inside.txt"), path.join(snapshot, "inside-link.txt"));
symlinkSync(path.join(outside, "secret.txt"), path.join(snapshot, ".probe-escape"));
symlinkSync(outside, path.join(snapshot, ".probe-dir-escape"));

const tools = Object.fromEntries(createConfinedTools(snapshot).map(tool => [tool.name, tool]));

function body(result: { content?: Array<{ text?: string }> }) {
	return (result.content ?? []).map(part => part.text ?? "").join("\n");
}

async function call(name: string, params: Record<string, unknown>) {
	const tool = tools[name];
	if (!tool) throw new Error(`missing tool ${name}`);
	return tool.execute("escape-probe", params);
}

const failures: string[] = [];

async function expectDeny(label: string, name: string, params: Record<string, unknown>) {
	try {
		const result = await call(name, params);
		const text = body(result);
		failures.push(`${label}: allowed, excerpt=${JSON.stringify(text.slice(0, 180))}`);
	} catch (error) {
		if (!(error instanceof OutsideSnapshotError)) {
			failures.push(`${label}: rejected with ${error instanceof Error ? error.name : "unknown"}: ${error instanceof Error ? error.message : error}`);
			return;
		}
		if (String(error.message).includes(secret)) failures.push(`${label}: error leaked outside bytes`);
	}
}

async function expectAllow(label: string, name: string, params: Record<string, unknown>, needle: string) {
	try {
		const text = body(await call(name, params));
		if (!text.includes(needle)) failures.push(`${label}: missing ${needle}`);
		if (text.includes(secret)) failures.push(`${label}: leaked outside bytes`);
	} catch (error) {
		failures.push(`${label}: ${error instanceof Error ? error.message : error}`);
	}
}

await expectAllow("read inside", "read", { path: "inside.txt" }, "INSIDE_OK");
await expectAllow("read internal symlink", "read", { path: "inside-link.txt" }, "INSIDE_OK");
await expectDeny("read absolute outside", "read", { path: path.join(outside, "secret.txt") });
await expectDeny("read relative escape", "read", { path: path.relative(snapshot, path.join(outside, "secret.txt")) });
await expectDeny("read home", "read", { path: "~/.omp/agent/config.yml" });
await expectDeny("read file url", "read", { path: `file://${path.join(outside, "secret.txt")}` });
await expectDeny("read url", "read", { path: "https://example.com/" });
await expectDeny("read memory uri", "read", { path: "memory://root" });
await expectDeny("read symlink file escape", "read", { path: ".probe-escape" });
await expectDeny("read symlink dir escape", "read", { path: ".probe-dir-escape/secret.txt" });
await expectDeny("grep outside path", "grep", { pattern: secret, path: outside });
await expectDeny("grep glob escape", "grep", { pattern: secret, glob: "../**" });
await expectDeny("glob outside path", "glob", { pattern: "*", path: outside });
await expectDeny("glob pattern escape", "glob", { pattern: "../**/*" });

const clean = body(await call("grep", { pattern: secret }));
if (clean.includes(secret)) failures.push("grep snapshot leaked outside bytes");
const names = body(await call("glob", { pattern: "**/*" }));
if (names.includes(".probe-escape") || names.includes("secret.txt") || names.includes(secret)) {
	failures.push(`glob snapshot listed an escape: ${names}`);
}

if (failures.length) {
	console.error(failures.map(item => `FAIL ${item}`).join("\n"));
	process.exit(1);
}
console.log("PASS confined tools rejected absolute, relative, home, URL, and symlink escapes");
