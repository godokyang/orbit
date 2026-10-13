import { test } from "bun:test";
import assert from "node:assert/strict";
import { finalizeReview, reviewOutputSchema, reviewSubmissionProblems } from "./review-submission";

function report() {
	return { verdict: "continue", reason: "still implementing", findings: [], resolved_ids: [], next_check_seconds: 30,
		delivery: { ready: false, reason: "not delivered" },
		coverage: { complete: true, items: [{ requirement: "R1", status: "unverified", evidence: "not inspected" }] } };
}
const event = (data = report()) => ({ toolCallId: "native-call", isError: false,
	result: { details: { status: "success" as const, data } } });
const nativeResult = (data: unknown = report()) => ({ rawOutput: "native report", exitCode: 0, stderr: "",
	abortedViaYield: false, hasYield: true,
	structuredOutput: { source: "session" as const, mode: "strict" as const, status: "valid" as const, data } });

test("review consumes the native strict result, preserving the seven-field business report", () => {
	const events = [event()];
	const outcome = finalizeReview(args => {
		assert.equal(args.outputSchemaMode, "strict");
		assert.equal(args.outputSchemaSource, "session");
		assert.deepEqual(args.outputSchema, reviewOutputSchema());
		assert.equal(args.rawOutput, "", "final-text fallback is disabled");
		assert.equal(args.lastAssistantText, undefined);
		assert.deepEqual(args.yieldItems, [events[0].result.details]);
		return nativeResult();
	}, events);
	assert.deepEqual(outcome.result, report());
	assert.deepEqual(outcome.problems, []);
});

test("missing submission, native invalid/aborted outcomes and later errors cannot reuse a result", () => {
	for (const returned of [
		{ ...nativeResult(), hasYield: false },
		{ ...nativeResult(), abortedViaYield: true },
		{ ...nativeResult(), exitCode: 1, stderr: "schema_violation" },
		{ ...nativeResult(), structuredOutput: { ...nativeResult().structuredOutput, status: "invalid" as const, error: "schema overridden" } },
	]) assert.equal(finalizeReview(() => returned, []).result, null);
	const events = [event(), { toolCallId: "later-error", isError: true, result: {} }];
	assert.equal(finalizeReview(args => {
		assert.equal(args.exitCode, 1);
		assert.equal(args.stderr, "latest yield failed");
		assert.equal(args.yieldItems?.length, 1);
		return { ...nativeResult(), exitCode: 1, stderr: args.stderr };
	}, events).result, null);
});

test("native structural success still requires Orbit's original business validator", () => {
	for (const data of [
		{ ...report(), findings: {} },
		{ ...report(), reason: "" },
		{ ...report(), next_check_seconds: 0 },
		{ ...report(), reasoning_compressed: "extra" },
	]) assert.equal(finalizeReview(() => nativeResult(data), [event()]).result, null);
});

test("pre-dispatch guard sends original data to the native strict finalizer without repairing it", () => {
	const data = { ...report(), findings: {} }; const before = JSON.stringify(data);
	const problems = reviewSubmissionProblems(args => {
		assert.deepEqual(args.yieldItems?.[0]?.data, data);
		assert.equal(args.outputSchemaMode, "strict");
		return { ...nativeResult(), exitCode: 1, stderr: "findings must be an array" };
	}, { data, i: "submit review" });
	assert.deepEqual(problems, ["findings must be an array"]);
	assert.equal(JSON.stringify(data), before);
	assert.ok(reviewSubmissionProblems(() => { throw new Error("not reached"); }, null).length);
});
