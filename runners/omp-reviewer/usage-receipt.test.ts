import { expect, test } from "bun:test";
import { modelCallReceipts, pendingCallReceipt, syncCallReceipts } from "./usage-receipt";

// In-flight receipts. A call boundary is persisted before its result exists, so
// an interrupted attempt still has an attributable call and never shows the
// SDK's initialized zeros as reported usage.
test("a boundary receipt keeps identity only and stays pending", () => {
	const receipt = pendingCallReceipt({
		call_id: "orbit-call-p1",
		requested_model: "zhipu-coding-plan/glm-5.2",
		// The start snapshot carries the SDK's initialized zero counters.
		message: { role: "assistant", provider: "openrouter", model: "zhipu-coding-plan/glm-5.2",
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0 } },
	});
	expect(receipt).toEqual({
		call_id: "orbit-call-p1",
		origin: "local_provider_invocation",
		usage_status: "pending",
		credential_id: null,
		provider: "openrouter",
		model: "zhipu-coding-plan/glm-5.2",
		requested_model: "zhipu-coding-plan/glm-5.2",
	});
	expect("input" in receipt).toBe(false);
	expect("totalTokens" in receipt).toBe(false);
});

test("a boundary without a turn model falls back to the session identity", () => {
	const receipt = pendingCallReceipt({ call_id: "orbit-call-p2", session_model: "zhipu-coding-plan/glm-5.2",
		requested_model: "zhipu-coding-plan/glm-5.2", message: { role: "assistant" } });
	expect(receipt.model).toBe("zhipu-coding-plan/glm-5.2");
	expect("upstream_model" in receipt).toBe(false);
});

test("the finished report updates the same call id in place", () => {
	const pending = pendingCallReceipt({
		call_id: "orbit-call-p3", requested_model: "zhipu-coding-plan/glm-5.2",
		message: { role: "assistant", provider: "openrouter", model: "zhipu-coding-plan/glm-5.2", usage: { input: 0, output: 0, cacheRead: 0 } },
	});
	const interim = { calls: [pending], gaps: ["x"] };
	const start = pendingCallReceipt({ call_id: "orbit-call-p3", requested_model: "zhipu-coding-plan/glm-5.2",
		message: { role: "assistant", model: "zhipu-coding-plan/glm-5.2" } });
	expect(start.call_id).toBe(pending.call_id);

	const report = syncCallReceipts(
		[pending],
		[{ call_id: "orbit-call-p3", message: { role: "assistant", responseId: "req_p3", provider: "openrouter",
			model: "zhipu-coding-plan/glm-5.2", stopReason: "stop", usage: { input: 100, output: 40, cacheRead: 20 } } }],
		"zhipu-coding-plan/glm-5.2",
	);
	expect(report.calls.length).toBe(1);
	expect(report.calls[0].call_id).toBe("orbit-call-p3");
	expect(report.calls[0].usage_status).toBe("reported");
	expect(report.calls[0].input).toBe(100);
	expect(report.gaps).toEqual([]);
	expect(interim.calls.length).toBe(1);
});

test("a boundary that never produced a result keeps its pending entry and a gap", () => {
	const pending = pendingCallReceipt({ call_id: "orbit-call-p4", requested_model: "zhipu-coding-plan/glm-5.2",
		message: { role: "assistant", model: "zhipu-coding-plan/glm-5.2", usage: { input: 0, output: 0, cacheRead: 0 } } });
	const report = syncCallReceipts([pending], [], "zhipu-coding-plan/glm-5.2");
	expect(report.calls[0].usage_status).toBe("pending");
	expect(report.gaps).toEqual([
		"no assistant turn completed for this check attempt, so no provider usage was reported",
		"orbit-call-p4: the provider call started but no result was observed; usage is pending, not measured",
	]);
});

// One receipt per provider call boundary, including failed calls. These cases
// pin the three separate identities (local invocation id, provider response id,
// models), the partial/unknown usage status, the explicit gaps, and the rule
// that a failed request's initialized-to-zero counters are not consumption.
test("a completed turn keeps the local invocation id, provider id, models and categories", () => {
	const report = modelCallReceipts(
		[
			{
				call_id: "orbit-call-1",
				message: {
					role: "assistant",
					responseId: "req_abc",
					provider: "openrouter",
					model: "zhipu-coding-plan/glm-5.2",
					upstreamModel: "z-ai/glm-5.2",
					upstreamProvider: "Together",
					stopReason: "end",
					timestamp: 1_700_000_000_000,
					usage: { input: 100, output: 40, cacheRead: 20, cacheWrite: 5, reasoningTokens: 30, totalTokens: 165, cost: { total: 9 } },
				},
			},
		],
		"zhipu-coding-plan/glm-5.2",
	);
	expect(report.gaps).toEqual([]);
	expect(report.calls).toEqual([
		{
			call_id: "orbit-call-1",
			origin: "local_provider_invocation",
			usage_status: "reported",
			credential_id: null,
			provider_response_id: "req_abc",
			provider: "openrouter",
			model: "zhipu-coding-plan/glm-5.2",
			upstream_provider: "Together",
			upstream_model: "z-ai/glm-5.2",
			requested_model: "zhipu-coding-plan/glm-5.2",
			stop_reason: "end",
			completed_at: "2023-11-14T22:13:20.000Z",
			input: 100,
			output: 40,
			cacheRead: 20,
			cacheWrite: 5,
			reasoningTokens: 30,
			totalTokens: 165,
		},
	]);
});

test("a service that reports no response id still yields an attributable call", () => {
	const report = modelCallReceipts([
		{ call_id: "orbit-call-2", message: { role: "assistant", model: "zhipu-coding-plan/glm-5.2", usage: { input: 1, output: 2, cacheRead: 3 } } },
	]);
	expect(report.gaps).toEqual([]);
	expect(report.calls[0].call_id).toBe("orbit-call-2");
	expect(report.calls[0].origin).toBe("local_provider_invocation");
	expect(report.calls[0].usage_status).toBe("reported");
	expect("provider_response_id" in report.calls[0]).toBe(false);
});

test("an unobserved boundary is a gap but the measured usage is still kept", () => {
	const report = modelCallReceipts([
		{ call_id: null, message: { role: "assistant", model: "zhipu-coding-plan/glm-5.2", usage: { input: 5, output: 6, cacheRead: 0 } } },
	]);
	expect(report.gaps).toEqual(["model call 1: no provider call boundary was observed for this response, so this call has no invocation id"]);
	expect(report.calls[0].call_id).toBeNull();
	expect("origin" in report.calls[0]).toBe(false);
	expect(report.calls[0].usage_status).toBe("reported");
	expect(report.calls[0].input).toBe(5);
});

test("the requested model is never presented as the upstream model", () => {
	const [call] = modelCallReceipts(
		[{ call_id: "orbit-call-3", message: { role: "assistant", model: "zenmux/x-ai/grok-4.7", usage: { input: 1, output: 1, cacheRead: 0 } } }],
		"zenmux/x-ai/grok-4.6",
	).calls;
	expect(call.model).toBe("zenmux/x-ai/grok-4.7");
	expect(call.requested_model).toBe("zenmux/x-ai/grok-4.6");
	expect("upstream_model" in call).toBe(false);
	expect("upstream_provider" in call).toBe(false);
});

test("a failed call without usable usage keeps its identity and an unknown status", () => {
	const report = modelCallReceipts([
		{ call_id: "orbit-call-4", message: { role: "assistant", model: "zhipu-coding-plan/glm-5.2", stopReason: "error", errorMessage: "401 unauthorized" } },
	]);
	expect(report.gaps).toEqual([
		"orbit-call-4: the provider reported no complete usage (input, output, cacheRead unknown); the call is kept with usage_status=unknown",
	]);
	expect(report.calls).toEqual([
		{ call_id: "orbit-call-4", origin: "local_provider_invocation", usage_status: "unknown",
			credential_id: null, model: "zhipu-coding-plan/glm-5.2", stop_reason: "error" },
	]);
});

test("a partially reported call keeps its trustworthy fields and reports the missing ones", () => {
	const report = modelCallReceipts([
		{ call_id: "orbit-call-5", message: { role: "assistant", model: "zhipu-coding-plan/glm-5.2", usage: { input: 120, output: 7 } } },
	]);
	expect(report.calls[0].input).toBe(120);
	expect(report.calls[0].output).toBe(7);
	expect(report.calls[0].usage_status).toBe("unknown");
	expect("cacheRead" in report.calls[0]).toBe(false);
	expect(report.gaps).toEqual([
		"orbit-call-5: the provider reported no complete usage (cacheRead unknown); the call is kept with usage_status=unknown",
	]);
});

test("an errored turn's initialized-zero counters are not a report of zero consumption", () => {
	const errored = modelCallReceipts([
		{ call_id: "orbit-call-6", message: { role: "assistant", stopReason: "error", errorMessage: "401 unauthorized", usage: { input: 0, output: 0, cacheRead: 0 } } },
	]);
	expect(errored.calls.length).toBe(1);
	expect(errored.calls[0].usage_status).toBe("unknown");
	expect("input" in errored.calls[0]).toBe(false);
	expect("cacheRead" in errored.calls[0]).toBe(false);

	const partiallyMetered = modelCallReceipts([
		{ call_id: "orbit-call-7", message: { role: "assistant", stopReason: "error", errorMessage: "stream aborted", usage: { input: 900, output: 0, cacheRead: 100 } } },
	]);
	expect(partiallyMetered.calls[0].input).toBe(900);
	expect(partiallyMetered.calls[0].cacheRead).toBe(100);
	expect("output" in partiallyMetered.calls[0]).toBe(false);
	expect(partiallyMetered.calls[0].usage_status).toBe("unknown");
});

test("no assistant turn at all is a gap and no call", () => {
	const report = modelCallReceipts([]);
	expect(report.calls).toEqual([]);
	expect(report.gaps).toEqual(["no assistant turn completed for this check attempt, so no provider usage was reported"]);
});

test("absent categories stay absent and reasoning is never folded into output", () => {
	const [call] = modelCallReceipts([
		{ call_id: "orbit-call-8", message: { role: "assistant", usage: { input: 10, output: 100, cacheRead: 0, reasoningTokens: 80 } } },
	]).calls;
	expect(call.output).toBe(100);
	expect(call.reasoningTokens).toBe(80);
	expect("cacheWrite" in call).toBe(false);
	expect("totalTokens" in call).toBe(false);
});
