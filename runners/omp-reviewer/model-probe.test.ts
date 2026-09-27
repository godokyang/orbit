import { test } from "bun:test";
import assert from "node:assert/strict";
import { parseProbeModels, probeModelAvailability } from "./model-probe";

test("parseProbeModels splits, trims and drops blanks", () => {
	assert.deepEqual(parseProbeModels(" a/b , c/d ,, e/f "), ["a/b", "c/d", "e/f"]);
	assert.deepEqual(parseProbeModels(undefined), []);
	assert.deepEqual(parseProbeModels(""), []);
});

test("probeModelAvailability resolves each model through OMP's own per-model resolver", async () => {
	const credentialCalls: string[] = [];
	const credentials = new Map([
		["good/model", { ok: true }],
		["good/x-ai/grok-4.7", { ok: true }],
		["good/other", { ok: true }],
		["nokey/model", { ok: false, reason: "no credential for nokey" }],
	]);
	const result = await probeModelAvailability(
		["good/model", "good/x-ai/grok-4.7", "nokey/model", "gone/model", "notamodel", "good/model", "good/other"],
		(provider, id) => provider === "good" || (provider !== "gone" && id === "model"),
		async (provider, id) => {
			credentialCalls.push(`${provider}/${id}`);
			return credentials.get(`${provider}/${id}`) ?? { ok: false, reason: "unexpected model" };
		},
	);
	// A model id may itself contain slashes (e.g. good/x-ai/grok-4.7): the
	// provider is the first segment and everything after it is the id.
	assert.deepEqual(result.resolvable, ["good/model", "good/x-ai/grok-4.7", "good/other"]);
	assert.deepEqual(result.unresolvable, [
		{ model: "nokey/model", reason: "no credential for nokey" },
		{ model: "gone/model", reason: "model not in OMP source catalog" },
		{ model: "notamodel", reason: "model must be provider/id" },
	]);
	// Resolution is per unique model — the exact granularity the real check's
	// session uses at request time — and duplicates never re-resolve.
	assert.deepEqual(credentialCalls, ["good/model", "good/x-ai/grok-4.7", "nokey/model", "good/other"]);
});

test("probeModelAvailability propagates a resolver crash instead of dropping the model", async () => {
	// The reviewer's resolver converts expected credential failures into
	// structured reasons; an unexpected crash escaping it must not silently
	// shrink the candidate list, so the pure function rethrows.
	let thrown: unknown;
	try {
		await probeModelAvailability(
			["broken/model"],
			() => true,
			async () => {
				throw new Error("OAuth refresh failed for broken");
			},
		);
	} catch (error) {
		thrown = error;
	}
	assert.ok(thrown instanceof Error && thrown.message === "OAuth refresh failed for broken");
});
