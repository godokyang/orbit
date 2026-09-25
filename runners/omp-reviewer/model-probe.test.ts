import { test } from "bun:test";
import assert from "node:assert/strict";
import { parseProbeModels, probeModelAvailability } from "./model-probe";

test("parseProbeModels splits, trims and drops blanks", () => {
	assert.deepEqual(parseProbeModels(" a/b , c/d ,, e/f "), ["a/b", "c/d", "e/f"]);
	assert.deepEqual(parseProbeModels(undefined), []);
	assert.deepEqual(parseProbeModels(""), []);
});

test("probeModelAvailability separates catalog and credential failures and never returns a token", () => {
	const credentialCalls: string[] = [];
	const credentials = new Map([
		["good", { ok: true }],
		["nokey", { ok: false, reason: "no credential for nokey" }],
	]);
	const result = probeModelAvailability(
		["good/model", "good/x-ai/grok-4.7", "nokey/model", "gone/model", "notamodel", "good/model", "good/other"],
		(provider, id) => provider === "good" || (provider !== "gone" && id === "model"),
		provider => {
			credentialCalls.push(provider);
			return credentials.get(provider) ?? { ok: false, reason: "unexpected provider" };
		},
	);
	// A model id may itself contain slashes (e.g. good/x-ai/grok-4.7): the
	// provider is the first segment and everything after it is the id.
	assert.deepEqual(result.resolvable, ["good/model", "good/x-ai/grok-4.7", "good/other"]);
	assert.deepEqual(result.unresolvable, [
		{ model: "nokey/model", reason: "no credential for nokey" },
		{ model: "gone/model", reason: "model not in isolated catalog" },
		{ model: "notamodel", reason: "model must be provider/id" },
	]);
	// A provider is resolved at most once, regardless of how many of its models are probed.
	assert.deepEqual(credentialCalls, ["good", "nokey"]);
	// The result carries identifiers and reasons only; a token can never appear.
	for (const entry of [...result.resolvable, ...result.unresolvable.map(item => item.reason)]) {
		assert.equal(typeof entry, "string");
	}
	assert.equal(JSON.stringify(result).includes("secret-token"), false);
});
