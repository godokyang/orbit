import type { finalizeSubprocessOutput, YieldDetails } from "@oh-my-pi/pi-coding-agent";
import { loadCheckResultSchema, validateCheckResult } from "./check-result";

type Finalize = typeof finalizeSubprocessOutput;
export type ReviewYieldEvent = { toolCallId: string; isError: boolean; result: { details?: YieldDetails } };

export function reviewOutputSchema(): Record<string, unknown> {
	const { $id: _id, $schema: _draft, ...report } = loadCheckResultSchema();
	return { ...report, required: Object.keys(report.properties) };
}

// Use OMP's strict finalizer, including its normalization and override/error
// handling. Empty rawOutput deliberately disables its free-text fallback.
export function finalizeReview(finalize: Finalize, events: ReviewYieldEvent[]) {
	const last = events.at(-1);
	const finalized = finalize({
		rawOutput: "", exitCode: last?.isError ? 1 : 0,
		stderr: last?.isError ? "latest yield failed" : "",
		doneAborted: false, signalAborted: false,
		yieldItems: events.filter(event => !event.isError && event.result.details).map(event => event.result.details!),
		outputSchema: reviewOutputSchema(), outputSchemaMode: "strict", outputSchemaSource: "session",
	});
	const structured = finalized.structuredOutput;
	const problems = finalized.exitCode !== 0 || finalized.abortedViaYield || !finalized.hasYield || structured?.status !== "valid"
		? [finalized.stderr || structured?.error || "required successful structured yield is missing"]
		: validateCheckResult(structured.data);
	return { result: problems.length === 0 ? structured!.data : null, problems, finalized };
}

// SDK argument repair can drop unknown fields or coerce types before yield runs.
// Check the original complete data with the SAME native strict finalizer before
// dispatch; its documented optional-null normalization remains allowed. No tool
// replacement, execution wrapper, accepted-state map or transcript lookup.
export function reviewSubmissionProblems(finalize: Finalize, args: unknown): string[] {
	if (!args || typeof args !== "object" || Array.isArray(args)) return ["yield requires a complete report in data"];
	const raw = args as Record<string, unknown>;
	if (Array.isArray(raw.type)) return ["this review requires one complete report in data, not incremental sections"];
	if (raw.error !== undefined && raw.error !== null && raw.error !== "") return []; // Native aborted yield stays a failure.
	return finalizeReview(finalize, [{ toolCallId: "input-validation", isError: false,
		result: { details: { status: "success", data: raw.data } } }]).problems;
}
