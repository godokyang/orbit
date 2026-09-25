import { test } from "bun:test";
import assert from "node:assert/strict";
import { recoverTrailingJsonObject } from "./json-recovery";
import { validateCheckResult } from "./check-result";

// Exact key set of contracts/check-result.schema.json (additionalProperties: false).
const RESULT = '{"verdict":"continue","reason":"all requirements verified","findings":[],"resolved_ids":[],"next_check_seconds":300}';

function recoverAndValidate(text: string): unknown {
	const recovered = recoverTrailingJsonObject(text);
	if (recovered === undefined) return undefined;
	return validateCheckResult(recovered).length === 0 ? recovered : undefined;
}

test("recovers the trailing contract-valid object after a prose prefix (earlier objects are prose)", () => {
	const text = `I reviewed the fixed snapshot against the instruction and the named basis.\n${RESULT}`;
	assert.deepEqual(recoverAndValidate(text), JSON.parse(RESULT));
});

test("ignores brace examples in prose and accepts the trailing contract-valid object", () => {
	// Mirrors the real check #2 failure: prose contains sample record objects.
	const text = [
		"Verified against the fixed snapshot:",
		"1. rows now emit {B-200, 43, 107500} and {C-300, 85, 8500} in that order;",
		"2. errors keep the shape {index, reason} with 0-based indexes.",
		RESULT,
	].join("\n");
	assert.deepEqual(recoverAndValidate(text), JSON.parse(RESULT));

	// An earlier object followed by prose is still prose, not the verdict.
	const earlier = `{"a":1} then prose ${RESULT}`;
	assert.deepEqual(recoverAndValidate(earlier), JSON.parse(RESULT));

	// A brace inside a prefix string must not confuse the span scan.
	const trickyPrefix = `note ${JSON.stringify({ note: "}" })} ${RESULT}`;
	assert.deepEqual(recoverAndValidate(trickyPrefix), JSON.parse(RESULT));
});

test("rejects anything that is not a contract-valid trailing object", () => {
	assert.equal(recoverAndValidate(`no json at all`), undefined);
	assert.equal(recoverAndValidate(`note {"a":1}`), undefined, "an object that is not at the end is rejected");
	assert.equal(recoverAndValidate(`prefix {"a":`), undefined, "unbalanced braces stay fail-closed");
	assert.equal(recoverAndValidate(`prose {"x":"y"} tail`), undefined, "text after the trailing object is rejected");
	// A trailing object with the wrong shape must not fall back to an earlier object.
	const badRole = '{"role":"reviewer","verdict":"continue","reason":"x","findings":[],"resolved_ids":[],"next_check_seconds":300}';
	assert.equal(recoverAndValidate(`prose {"a":1}\n${badRole}`), undefined, "an invalid trailing object fails the result contract");
});
