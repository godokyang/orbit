import { test } from "bun:test";
import assert from "node:assert/strict";
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
