// Mid-session provider failure facts for one errored assistant turn, mapped
// onto the reviewer failure taxonomy (auth_or_quota | unavailable, matching
// lib/orbit/omp_check_runner.rb FAILURE_KINDS). The SDK already classifies the
// provider's own error content (pi-ai error/rate-limit.ts); this module only
// translates that public outcome. stopReason "error" alone never implies
// quota — the content gate decides, and a non-error stop is never a provider
// failure here (that path stays the model-compliance invalid_result one).
import { isUsageLimitOutcome } from "@oh-my-pi/pi-ai/error";

export interface ProviderErrorFact {
	kind: "auth_or_quota" | "unavailable";
	detail: string;
	status: number | null;
	error_id: number | null;
}

export function providerErrorFact(message: unknown): ProviderErrorFact | undefined {
	const turn = message as {
		stopReason?: unknown;
		errorStatus?: unknown;
		errorId?: unknown;
		errorMessage?: unknown;
		errorClassificationMessage?: unknown;
	} | undefined;
	if (turn?.stopReason !== "error") return undefined;
	// The SDK's own auth classifier prefers the stable classification text over
	// the display-oriented raw message (pi-ai error/auth-classify.ts).
	const text = [turn.errorClassificationMessage, turn.errorMessage]
		.find((value): value is string => typeof value === "string" && value.trim().length > 0);
	const status = typeof turn.errorStatus === "number" ? turn.errorStatus : undefined;
	// Quota/balance content is decided by the SDK's own usage-limit outcome; a
	// trusted HTTP 401 (authentication) or 403 (permission) is the auth half of
	// the product taxonomy, matching the SDK's own hard-401/403 handling
	// (pi-ai error/auth-classify.ts). Everything else stays unavailable —
	// transient 429s, 5xx and unknown errors are never reported as auth/quota.
	const auth = status === 401 || status === 403;
	// Zenmux's evidenced 402 balance gate is not in the SDK usage-limit
	// vocabulary. Preserve its account-level refusal across artifact changes;
	// do not turn every informative 402 or a transient rate limit into quota.
	const balanceGate = status === 402 && /\bbalance (?:greater than|above|>)\s*0\b/i.test(text ?? "");
	const kind = auth || balanceGate || isUsageLimitOutcome(status, text) ? "auth_or_quota" : "unavailable";
	const detail = `${status !== undefined ? `HTTP ${status}: ` : ""}${text?.trim() ?? "provider reported an error without detail"}`
		.replace(/\s+/g, " ").trim().slice(0, 200);
	// Preserve only SDK-public numeric diagnostics. No headers, request body,
	// credential text or reconstructed retry advice enters this projection.
	return { kind, detail,
		status: typeof status === "number" && Number.isInteger(status) && status >= 100 && status <= 599 ? status : null,
		error_id: typeof turn.errorId === "number" && Number.isSafeInteger(turn.errorId) && turn.errorId >= 0 ? turn.errorId : null };
}
