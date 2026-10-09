import { test } from "bun:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createConfinedTools } from "./confined-tools";

test("a final LF is not an extra empty line in reviewer read or grep", async () => {
	const snapshot = mkdtempSync(path.join(tmpdir(), "orbit-check-lines-"));
	try {
		const file = path.join(snapshot, "release.txt");
		const [read, grep] = createConfinedTools(snapshot);
		writeFileSync(file, "release=verified\n");
		const single = await read.execute("line-check", { path: "release.txt" });
		assert.equal(single.content[0].text, "[bytes=17; final_newline=LF; actual_lines=1]\n1|release=verified");
		assert.equal((await grep.execute("line-check", { path: "release.txt", pattern: "^$" })).content[0].text,
			"(no matches)");

		writeFileSync(file, "release=verified\n\n");
		const doubled = await read.execute("line-check", { path: "release.txt" });
		assert.equal(doubled.content[0].text,
			"[bytes=18; final_newline=LF; actual_lines=2]\n1|release=verified\n2|");
		assert.equal((await grep.execute("line-check", { path: "release.txt", pattern: "^$" })).content[0].text,
			"release.txt:2: ");
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
		assert.equal(seen.content[1].text, `[image=screen.png; mime=image/png; bytes=${png.length}; sha256=${sha}]`);
		assert.deepEqual(facts, [{ path: "screen.png", bytes: png.length, sha256: sha, mime_type: "image/png", model_image_input: true }]);

		// A model that declares no image input is told so, not left to assume pixels.
		const blind = await read.execute("image-check", { path: "screen.png" }, undefined, { model: { input: ["text"] } });
		assert.match(blind.content[1].text, /declares no image input, so these pixels were not delivered/);
		assert.equal(facts[1].model_image_input, false);

		// Only the bytes decide: a text file named .png is still text.
		writeFileSync(path.join(snapshot, "not.png"), "plain text\n");
		const asText = await read.execute("image-check", { path: "not.png" });
		assert.equal(asText.content[0].type, "text");
		assert.equal(asText.content[0].text, "[bytes=11; final_newline=LF; actual_lines=1]\n1|plain text");
	} finally {
		rmSync(snapshot, { recursive: true, force: true });
	}
});
