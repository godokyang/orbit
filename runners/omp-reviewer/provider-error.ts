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
}

export function providerErrorFact(message: unknown): ProviderErrorFact | undefined {
	const turn = message as {
		stopReason?: unknown;
		errorStatus?: unknown;
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
	const kind = auth || isUsageLimitOutcome(status, text) ? "auth_or_quota" : "unavailable";
	const detail = `${status !== undefined ? `HTTP ${status}: ` : ""}${text?.trim() ?? "provider reported an error without detail"}`
		.replace(/\s+/g, " ").trim().slice(0, 200);
	return { kind, detail };
}
