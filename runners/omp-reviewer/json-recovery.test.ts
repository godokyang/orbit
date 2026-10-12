import { test } from "bun:test";
import assert from "node:assert/strict";
import { recoverCheckResultJson } from "./json-recovery";
import { validateCheckResult } from "./check-result";

// Exact key set of contracts/check-result.schema.json (additionalProperties: false).
const RESULT = '{"verdict":"continue","reason":"all requirements verified","findings":[],"resolved_ids":[],"next_check_seconds":300,"delivery":{"ready":true,"reason":"delivered answer is visible in the program record"}}';

function recoverAndValidate(text: string): unknown {
	const recovered = recoverCheckResultJson(text);
	if (recovered === undefined) return undefined;
	return validateCheckResult(recovered.value).length === 0 ? recovered.value : undefined;
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
	const badRole = '{"role":"reviewer","verdict":"continue","reason":"x","findings":[],"resolved_ids":[],"next_check_seconds":300,"delivery":{"ready":true,"reason":"r"}}';
	assert.equal(recoverAndValidate(`prose {"a":1}\n${badRole}`), undefined, "an invalid trailing object fails the result contract");
});

test("recovers a single whole-message json fence and identifies its envelope", () => {
	for (const text of [`\`\`\`json\n${RESULT}\n\`\`\``, ` \n\`\`\`json\r\n${RESULT}\r\n\`\`\`\n `]) {
		assert.deepEqual(recoverAndValidate(text), JSON.parse(RESULT));
		assert.equal(recoverCheckResultJson(text)?.description, "single whole-message json fence; contract-valid JSON object");
	}
});

test("fences do not repair bad JSON, extra fields, or select a nested valid result", () => {
	const extra = { ...JSON.parse(RESULT), reasoning_compressed: "unexpected field" };
	for (const body of [JSON.stringify(extra), `${RESULT}}`, `invalid prefix ${RESULT}`, JSON.stringify({ result: JSON.parse(RESULT) })]) {
		assert.equal(recoverAndValidate(`\`\`\`json\n${body}\n\`\`\``), undefined);
	}
});

test("rejects external prose, multiple fences, and incomplete envelopes without fallback", () => {
	const fenced = `\`\`\`json\n${RESULT}\n\`\`\``;
	for (const text of [
		`Explanation\n${fenced}`, `${fenced}\nExplanation`, `${fenced}\n${fenced}`,
		`\`\`\`json\n${RESULT}`, `${RESULT}\n\`\`\``,
		`\`\`\`json\ninvalid\n\`\`\`\n${RESULT}`, `prefix \`\`\`json\n${RESULT}`,
		`\`\`\`javascript\n${RESULT}\n\`\`\``,
	]) assert.equal(recoverAndValidate(text), undefined);
});

test("ordinary JSON and the existing prose recovery retain their original result and metadata", () => {
	assert.deepEqual(validateCheckResult(JSON.parse(RESULT)), []);
	const text = `Summary with example {"a":1}.\n${RESULT}`;
	assert.deepEqual(recoverAndValidate(text), JSON.parse(RESULT));
	assert.equal(recoverCheckResultJson(text)?.description, "trailing contract-valid JSON object; earlier objects are prose");
	const literal = { ...JSON.parse(RESULT), reason: 'Preserve "quoted" text and the literal ``` marker.' };
	const prefixed = `Summary.\n${JSON.stringify(literal)}`;
	assert.deepEqual(recoverAndValidate(prefixed), literal);
	assert.equal(recoverCheckResultJson(prefixed)?.description, "trailing contract-valid JSON object; earlier objects are prose");
});
