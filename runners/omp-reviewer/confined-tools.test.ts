import { test } from "bun:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createConfinedTools } from "./confined-tools";

test("reviewer tools expose required parameters and reject missing ones while accepting intent", async () => {
	const snapshot = mkdtempSync(path.join(tmpdir(), "orbit-check-parameters-"));
	try {
		writeFileSync(path.join(snapshot, "artifact.txt"), "verified\n");
		const cases = [
			{ name: "read", required: "path", args: { path: "artifact.txt" }, fields: ["path", "offset", "limit"], match: /1\|verified/ },
			{ name: "grep", required: "pattern", args: { pattern: "verified", path: "artifact.txt" }, fields: ["pattern", "path", "glob", "ignore_case"], match: /artifact.txt:1: verified/ },
			{ name: "glob", required: "pattern", args: { pattern: "*.txt" }, fields: ["pattern", "path"], match: /artifact\.txt$/ },
		];
		const tools = createConfinedTools(snapshot);
		for (const entry of cases) {
			const tool = tools.find(tool => tool.name === entry.name)!;
			const schema = JSON.parse(JSON.stringify(tool.parameters));
			assert.deepEqual(Object.keys(schema.properties).sort(), entry.fields.sort());
			assert.deepEqual(schema.required, [entry.required]);
			for (const missing of [{}, { i: "Read the artifact" }]) {
				await assert.rejects(tool.execute("missing", missing as never), error =>
					error instanceof Error && error.message.includes(`"${entry.required}"`));
			}
			const result = await tool.execute("with-intent", { ...entry.args, i: "Verify artifact" } as never);
			assert.match(result.content[0].text!, entry.match);
		}
	} finally {
		rmSync(snapshot, { recursive: true, force: true });
	}
});

test("read-only reviewer access can reach registered evidence sources with source identity", async () => {
	const snapshot = mkdtempSync(path.join(tmpdir(), "orbit-review-sources-snapshot-"));
	const record = mkdtempSync(path.join(tmpdir(), "orbit-review-sources-record-"));
	const unrelated = mkdtempSync(path.join(tmpdir(), "orbit-review-sources-unrelated-"));
	try {
		writeFileSync(path.join(snapshot, "current.txt"), "snapshot version\n");
		const earlier = path.join(record, "checks", "1", "evidence.json");
		mkdirSync(path.dirname(earlier), { recursive: true });
		writeFileSync(earlier, "historical receipt\n");
		writeFileSync(path.join(record, "state.json"), "task state\n");
		writeFileSync(path.join(unrelated, "secret.txt"), "outside registered roots\n");
		const sessionFile = path.join(unrelated, "member-session.jsonl");
		writeFileSync(sessionFile, "session transcript\n");
		const [read, grep, glob] = createConfinedTools(snapshot, { readRoots: [
			{ path: record, label: "this Orbit task record", version: "task=t1; check=2" },
			{ path: sessionFile, label: "recorded member session", version: "member=m1", exactFile: true },
		] });
		const state = await read.execute("source-test", { path: path.join(record, "state.json") });
		assert.match(state.content[0].text, /task state/);
		assert.equal(state.details.source, "this Orbit task record");
		assert.match(state.content[0].text, /sha256=/);
		assert.match((await read.execute("source-test", { path: sessionFile })).content[0].text, /session transcript/);
		await assert.rejects(read.execute("source-test", { path: path.join(unrelated, "secret.txt") }));
		await assert.rejects(read.execute("source-test", { path: unrelated }));
		assert.equal((await grep.execute("source-test", { path: record, pattern: "historical" })).details.source,
			"this Orbit task record");
		assert.equal((await glob.execute("source-test", { pattern: "**/*.json", path: record })).details.count, 2);
	} finally {
		rmSync(snapshot, { recursive: true, force: true });
		rmSync(record, { recursive: true, force: true });
		rmSync(unrelated, { recursive: true, force: true });
	}
});

test("a final LF is not an extra empty line in reviewer read or grep", async () => {
	const snapshot = mkdtempSync(path.join(tmpdir(), "orbit-check-lines-"));
	try {
		const file = path.join(snapshot, "release.txt");
		const [read, grep] = createConfinedTools(snapshot);
		writeFileSync(file, "release=verified\n");
		const single = await read.execute("line-check", { path: "release.txt" });
		assert.match(single.content[0].text!, /final_newline=LF; actual_lines=1/);
		assert.match(single.content[0].text!, /1\|release=verified$/);
		assert.equal((await grep.execute("line-check", { path: "release.txt", pattern: "^$" })).content[0].text,
			"(no matches)");

		writeFileSync(file, "release=verified\n\n");
		const doubled = await read.execute("line-check", { path: "release.txt" });
		assert.match(doubled.content[0].text!, /final_newline=LF; actual_lines=2/);
		assert.match(doubled.content[0].text!, /1\|release=verified\n2\|$/);
		assert.match((await grep.execute("line-check", { path: "release.txt", pattern: "^$" })).content[0].text!,
			/release\.txt:2: $/);
	} finally {
		rmSync(snapshot, { recursive: true, force: true });
	}
});

test("a snapshot image is returned as pixels with traceable read facts", async () => {
	const snapshot = mkdtempSync(path.join(tmpdir(), "orbit-check-image-"));
	try {
		const facts: Array<Record<string, unknown>> = [];
		const [read] = createConfinedTools(snapshot, { onImageRead: entry => facts.push(entry) });
		// A real 1x1 PNG: the bytes are sniffed, never trusted by extension.
		const png = Buffer.from(
			"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
			"base64",
		);
		writeFileSync(path.join(snapshot, "screen.png"), png);
		const sha = createHash("sha256").update(png).digest("hex");
		const seen = await read.execute("image-check", { path: "screen.png" }, undefined, {
			model: { input: ["text", "image"] },
		});
		assert.equal(seen.content[0].type, "image");
		assert.equal(seen.content[0].mimeType, "image/png");
		assert.equal(seen.content[0].data, png.toString("base64"));
		assert.match(seen.content[1].text!, new RegExp(`source=fixed snapshot;.*mime=image/png; bytes=${png.length}; sha256=${sha}; read_at=`));
		assert.deepEqual(facts, [{ path: path.join(realpathSync(snapshot), "screen.png"), bytes: png.length, sha256: sha, mime_type: "image/png", model_image_input: true }]);

		// A model that declares no image input is told so, not left to assume pixels.
		const blind = await read.execute("image-check", { path: "screen.png" }, undefined, { model: { input: ["text"] } });
		assert.match(blind.content[1].text, /declares no image input, so these pixels were not delivered/);
		assert.equal(facts[1].model_image_input, false);

		// Only the bytes decide: a text file named .png is still text.
		writeFileSync(path.join(snapshot, "not.png"), "plain text\n");
		const asText = await read.execute("image-check", { path: "not.png" });
		assert.equal(asText.content[0].type, "text");
		assert.match(asText.content[0].text!, /final_newline=LF; actual_lines=1/);
		assert.match(asText.content[0].text!, /1\|plain text$/);
	} finally {
		rmSync(snapshot, { recursive: true, force: true });
	}
});
