import { expect, test } from "bun:test";
import { providerErrorFact } from "./provider-error";

// The real opencode-go quota-exhaustion turn (frozen evidence:
// deepseek-reviewer-429-rootcause.json — six identical reviewer failures
// misclassified as invalid_result). The SDK's own usage-limit outcome must
// surface it as auth_or_quota with the provider's actual text kept.
test("a real 429 usage-limit turn classifies as auth_or_quota", () => {
	const fact = providerErrorFact({
		stopReason: "error",
		errorStatus: 429,
		errorMessage: "429 Go usage limit exceeded retry-after-ms=961624000 (type=GoUsageLimitError)",
		errorId: 659456,
	});
	expect(fact?.kind).toBe("auth_or_quota");
	expect(fact?.status).toBe(429);
	expect(fact?.error_id).toBe(659456);
	expect(fact?.detail).toContain("Go usage limit exceeded");
	expect(providerErrorFact({ stopReason: "error", errorStatus: 402,
		errorMessage: "402 Access denied: this model is only available to accounts with a balance greater than 0. This is an anti-abuse measure, not a usage charge." })?.kind).toBe("auth_or_quota");
	expect(providerErrorFact({ stopReason: "error", errorStatus: 402,
		errorMessage: "A subscription is required for this endpoint" })?.kind).toBe("unavailable");

	// Trusted HTTP auth statuses are the auth half of the same kind (the SDK's
	// own auth handling treats a hard 401/403 likewise): an authentication or
	// permission failure is never reported as a generic unavailability.
	expect(providerErrorFact({ stopReason: "error", errorStatus: 401, errorMessage: "invalid API key" })?.kind)
		.toBe("auth_or_quota");
	expect(providerErrorFact({ stopReason: "error", errorStatus: 403, errorMessage: "forbidden" })?.kind)
		.toBe("auth_or_quota");
});

// stopReason "error" alone never implies quota: a transient per-minute rate
// limit on the same 429 status stays unavailable, not auth_or_quota.
test("a transient 429 rate limit is not quota", () => {
	const fact = providerErrorFact({
		stopReason: "error",
		errorStatus: 429,
		errorMessage: "Too many requests. Please retry in 5s.",
	});
	expect(fact?.kind).toBe("unavailable");
	expect(fact?.detail).toContain("HTTP 429");
});

// Other provider failures keep their evidence and classify as unavailable.
test("a server error carries status and text as unavailable", () => {
	const fact = providerErrorFact({ stopReason: "error", errorStatus: 500, errorMessage: "Internal server error" });
	expect(fact?.kind).toBe("unavailable");
	expect(fact?.detail).toBe("HTTP 500: Internal server error");
	const bare = providerErrorFact({ stopReason: "error" });
	expect(bare?.kind).toBe("unavailable");
	expect(bare?.status).toBeNull();
	expect(bare?.error_id).toBeNull();
	expect(bare?.detail).toBe("provider reported an error without detail");
});

// A non-error stop is never a provider failure: the unparseable-final path
// stays the model-compliance invalid_result one.
test("a completed turn is never reclassified", () => {
	expect(providerErrorFact({ stopReason: "stop", errorMessage: undefined })).toBeUndefined();
	expect(providerErrorFact(undefined)).toBeUndefined();
	expect(providerErrorFact({ stopReason: "length" })).toBeUndefined();
});
