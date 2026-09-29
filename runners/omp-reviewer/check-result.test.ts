import { test } from "bun:test";
import assert from "node:assert/strict";
import { validateCheckResult } from "./check-result";

// Mirrors contracts/check-result.schema.json: delivery is a required,
// structured readiness judgment separate from verdict and findings —
// exactly ready (boolean) + reason (non-empty string), additionalProperties
// false everywhere.

function baseResult(): Record<string, unknown> {
	return {
		verdict: "continue",
		reason: "work in progress",
		findings: [],
		resolved_ids: [],
		next_check_seconds: 300,
		delivery: { ready: false, reason: "final answer not visible in the program record" },
	};
}

test("accepts a result carrying the structured delivery judgment", () => {
	const result = baseResult();
	result.delivery = { ready: true, reason: "delivered answer visible in root observations" };
	assert.deepEqual(validateCheckResult(result), []);
});

test("rejects a result without delivery", () => {
	const result = baseResult();
	delete result.delivery;
	const problems = validateCheckResult(result);
	assert.ok(problems.some(p => p.includes("missing keys") && p.includes("delivery")), JSON.stringify(problems));
});

test("rejects a non-boolean ready, an empty reason and extra delivery keys", () => {
	const stringReady = baseResult();
	(stringReady.delivery as Record<string, unknown>).ready = "yes";
	assert.ok(validateCheckResult(stringReady).some(p => p === "delivery.ready must be a boolean"));

	const emptyReason = baseResult();
	(emptyReason.delivery as Record<string, unknown>).reason = "";
	assert.ok(validateCheckResult(emptyReason).some(p => p === "delivery.reason must be a non-empty string"));

	const extra = baseResult();
	(extra.delivery as Record<string, unknown>).evidence = "snapshot";
	assert.ok(validateCheckResult(extra).some(p => p.includes("delivery has unexpected keys")));
});

test("delivery is never implicit: a bare legacy result fails the contract", () => {
	const legacy = {
		verdict: "complete",
		reason: "no findings",
		findings: [],
		resolved_ids: [],
		next_check_seconds: 60,
	};
	assert.ok(validateCheckResult(legacy).some(p => p.includes("delivery")), "the old five-field result is not valid");
});

test("coverage preserves unverified requirements and requires evidence for verified ones", () => {
	const result = baseResult();
	result.coverage = { complete: true, items: [
		{ requirement: "aggregate exact cents", status: "verified", evidence: "src/cli.js uses integer cents" },
		{ requirement: "reject partial output", status: "unverified", evidence: "invalid-row behavior not inspected" },
	] };
	assert.deepEqual(validateCheckResult(result), [], "unverified is a valid report of missing evidence");
	(result.coverage as { items: { evidence: string }[] }).items[0].evidence = "";
	assert.ok(validateCheckResult(result).some(p => p.includes("coverage evidence")), "a verified assertion needs evidence");
});
