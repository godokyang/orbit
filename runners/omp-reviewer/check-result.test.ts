import { readFileSync } from "node:fs";
import { test } from "bun:test";
import assert from "node:assert/strict";
import { checkResultProblems, deriveCheckResultStructure, loadCheckResultSchema, validateCheckResult } from "./check-result";

// Structure (keys, enums, bounds, closed-object rules) is derived from
// contracts/check-result.schema.json; these tests keep the semantic gates
// (delivery judgment, non-empty strings, coverage bounds) honest and prove the
// validators follow the schema instead of hardcoded literals.

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

test("a long requirement is accepted at the representation bound while real refusals stay", () => {
	const sentence = "The closing report must " + "enumerate each enumerated requirement with its exact wording and evidence ".repeat(5).trim() + ".";
	assert.ok(sentence.length > 300 && sentence.length < 1000, `fixture sits between the old and new bound (${sentence.length})`);
	const result = baseResult();
	result.coverage = { complete: true, items: [{ requirement: sentence, status: "verified", evidence: "reviewer read the requirement list" }] };
	assert.deepEqual(validateCheckResult(result), [], "a 348-character requirement sentence is not truncated or rejected");

	const oversized = baseResult();
	oversized.coverage = { complete: true, items: [{ requirement: "x".repeat(1001), status: "verified", evidence: "e" }] };
	assert.ok(validateCheckResult(oversized).some(p => p.includes("at most 1000 characters")), "an oversized requirement is still refused");

	const missingEvidence = baseResult();
	missingEvidence.coverage = { complete: true, items: [{ requirement: sentence, status: "verified", evidence: "" }] };
	assert.ok(validateCheckResult(missingEvidence).some(p => p.includes("coverage evidence")), "a verified item without evidence is still refused");

	const duplicate = baseResult();
	duplicate.coverage = { complete: true, items: [
		{ requirement: sentence, status: "verified", evidence: "e1" },
		{ requirement: sentence, status: "unverified", evidence: "e2" },
	] };
	assert.ok(validateCheckResult(duplicate).some(p => p.includes("duplicate")), "duplicate requirements are still refused");
});

test("check-result structure is shared and schema-derived, not hardcoded", () => {
	const fixture = JSON.parse(readFileSync(new URL("../../tests/fixtures/check-result-samples.json", import.meta.url), "utf8")) as
		{ samples: { name: string; accept: boolean; result: unknown }[] };
	assert.ok(fixture.samples.length >= 4, "the shared sample set is not silently emptied");
	for (const sample of fixture.samples) {
		const accepted = validateCheckResult(structuredClone(sample.result)).length === 0;
		assert.equal(accepted, sample.accept, `${sample.name}: ${JSON.stringify(validateCheckResult(sample.result))}`);
	}

	const schema = structuredClone(loadCheckResultSchema());
	schema.properties.verdict.enum = (schema.properties.verdict.enum as string[]).filter(verdict => verdict !== "pause");
	delete schema.additionalProperties;
	const tampered = deriveCheckResultStructure(schema);
	const paused = { verdict: "pause", reason: "r", findings: [], resolved_ids: [], next_check_seconds: 1, delivery: { ready: false, reason: "x" } };
	const enumProblems = checkResultProblems(tampered, paused);
	assert.ok(enumProblems.some(p => p.startsWith("verdict must be one of:") && !p.includes("pause")), "a removed verdict enum value is enforced from the schema");
	const openProblems = checkResultProblems(tampered, { ...paused, extra: 1 });
	assert.ok(!openProblems.some(p => p.includes("unexpected keys")), "an open schema object accepts extra keys instead of a hardcoded rule");

	// maxLength counts code points, not UTF-16 units: a 1000-code-point
	// requirement of mostly non-BMP characters (1600 UTF-16 units) stays valid
	// on both sides, 1001 code points are refused.
	const emojiHeavy = "🎯".repeat(600) + "x".repeat(400);
	assert.ok(emojiHeavy.length === 1600 && [...emojiHeavy].length === 1000, "the boundary text really mixes the two units");
	const unitResult = { verdict: "correct", reason: "r", findings: [], resolved_ids: [], next_check_seconds: 1,
		delivery: { ready: false, reason: "x" },
		coverage: { complete: true, items: [{ requirement: emojiHeavy, status: "unverified", evidence: "" }] } };
	assert.deepEqual(validateCheckResult(unitResult), [], "1000 code points stay valid despite 1600 UTF-16 units");
	const oversize = structuredClone(unitResult);
	oversize.coverage.items[0].requirement = "🎯".repeat(600) + "x".repeat(401);
	assert.ok(validateCheckResult(oversize).some(p => p.includes("at most 1000")), "1001 code points are still refused");

	const foreign = structuredClone(loadCheckResultSchema());
	foreign.$id = "https://elsewhere/check-result.json";
	assert.throws(() => deriveCheckResultStructure(foreign), /identity mismatch/, "a foreign schema file fails closed");
});
