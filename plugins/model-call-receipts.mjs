// Shared pure receipts for the provider model calls inside one OMP session.
// Used by both the Node host (plugins/omp-host.mjs, execution members) and the
// Bun reviewer runner (runners/omp-reviewer/usage-receipt.ts re-exports this
// module), so the receipt computation exists exactly once. This module has no
// I/O and no prices: it never converts usage to money or quota, and it never
// derives one usage category from another.
//
// Identity has three separate parts and they are never mixed:
//   call_id        Orbit's local id for one provider call boundary. The agent
//                  loop turns the first provider `start` of every response into
//                  `message_start`, so one id is minted there (mintCallId) and
//                  reused for that response's message_end or failure receipt.
//                  It is an invocation label (origin=local_provider_invocation),
//                  not a provider id, and it is never derived afterwards from
//                  time or from the check attempt id. A response whose boundary
//                  was never observed keeps call_id=null and a gap; no id is
//                  manufactured for it.
//   provider_response_id  the provider's own response id, stored separately and
//                  only when the service actually reported one.
//   model / upstream_model  the actual OMP-configured model that ran versus the
//                  upstream supplier's concrete model. The upstream model is
//                  unknown unless the provider returned it: the requested id is
//                  never presented as the upstream model.
//
// Every assistant turn produces a receipt, including a failed call: dropping it
// would undercount real attempts. Counts are carried only when the provider
// actually reported them, so `usage_status` is "reported" only for a complete
// reported composition and "unknown" otherwise, and any trustworthy individual
// field is still kept. A failed request's initialized-to-zero counters are not a
// report of zero consumption, so they are dropped rather than recorded as zero.
// There is no session-level fallback: a session total spans several model calls.
//
// Category relationships below follow the pinned OMP SDK's own Usage contract
// (@oh-my-pi/pi-catalog 18.3.4 `dist/types/types.d.ts`): `input` is "Non-cached
// conversation input tokens", `cacheRead`/`cacheWrite` are separate prompt-cache
// buckets, `reasoningTokens` is "Always a subset of `output`", and `totalTokens`
// is "Sum of input + output + cacheRead + cacheWrite plus provider-side
// orchestration tokens when reported". Providers that don't expose a field leave
// it undefined — "`undefined` means unknown, NOT zero" — so no field is inferred
// and consumers must not add the preserved categories together.
//
// Each receipt carries the provider's final per-response report from the
// assistant message (message_end). Streaming updates along the way are deltas
// or cumulative snapshots of the same response, so callers must never sum usage
// across stream events or across messages of one response; one call keeps one
// receipt under one call_id from boundary to result. Only the legacy assistant
// message shape (message.usage/model/upstreamModel/...) is read, because that
// structure is verified; a newer SDK `usageReport` channel is not consulted —
// its shape has no evidence here and nothing is fabricated from it.

import { randomUUID } from "node:crypto";

// The SDK usage contract these relationships are declared from. Kept under the
// ledger's 256-char receipt text limit; it states the source definition without
// authorising any derived total or price.
const SDK_RELATIONSHIP_NOTE =
	"OMP SDK 18.3.4 usage contract: input is non-cached conversation input; cacheRead/cacheWrite are separate cache buckets; " +
	"reasoningTokens is a subset of output; totalTokens sums all plus provider orchestration when reported";

const COUNT_FIELDS = ["input", "output", "cacheRead", "cacheWrite", "reasoningTokens", "totalTokens"];
const REQUIRED_FIELDS = ["input", "output", "cacheRead"];

function integer(value) {
	return Number.isInteger(value) && value >= 0;
}

function optionalString(value) {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function turnLabel(turn, index) {
	return turn.call_id ?? `model call ${index + 1}`;
}

// Mints Orbit's local invocation id for one provider call. Call this ONLY at
// the observed call boundary (the assistant message_start of one response),
// never afterwards to fill a gap: a late id would falsely brand a response
// whose boundary was missed as an observed invocation.
export function mintCallId() {
	return `orbit-call-${randomUUID()}`;
}

// Counts kept from one turn. A failed turn keeps its nonzero counts and drops
// zeros (those are the counters initialized before the request, not a provider
// statement that the call was free); a successful turn keeps reported zeros.
function reportedCounts(message) {
	const usage = message.usage;
	const failed = message.stopReason === "error" || message.stopReason === "aborted" || optionalString(message.errorMessage) !== undefined;
	const counts = {};
	for (const field of COUNT_FIELDS) {
		if (!integer(usage?.[field])) continue;
		if (failed && usage[field] === 0) continue;
		counts[field] = usage[field];
	}
	return counts;
}

// Never carries an unset value: an absent field means the provider did not
// report it, not that it is zero.
function omitUnreported(receipt) {
	for (const key of Object.keys(receipt)) {
		if (receipt[key] === undefined) delete receipt[key];
	}
	return receipt;
}

// The receipt for an observed call boundary whose result has not arrived.
//
// It carries the local id, the executed identity and nothing else: the SDK
// initializes usage to zeros before the request, and those zeros are not a
// provider report, so no count is read here at all and `usage_status` stays
// "pending" until a message_end supplies a real report.
export function pendingCallReceipt(call) {
	const message = call.message ?? {};
	return omitUnreported({
		call_id: call.call_id,
		origin: "local_provider_invocation",
		usage_status: "pending",
		provider: optionalString(message.provider),
		// The executed OMP configuration; the session identity is a fallback for
		// the turn's own model, never a substitute for the upstream model.
		model: optionalString(message.model) ?? optionalString(call.session_model),
		requested_model: optionalString(call.requested_model),
	});
}

// Folds finalized turns into the receipts already held for this attempt, so one
// observed call keeps one entry under one id from boundary to result: a pending
// entry is replaced by its report in place, and a boundary that never produced
// a result keeps its pending entry and its own gap.
export function syncCallReceipts(existing, turns, requestedModel) {
	const report = modelCallReceipts(turns, requestedModel);
	const finalized = new Map();
	const unkeyed = [];
	for (const call of report.calls) {
		if (call.call_id === null) unkeyed.push(call);
		else finalized.set(call.call_id, call);
	}

	const gaps = [...report.gaps];
	const calls = [];
	const placed = new Set();
	for (const receipt of existing) {
		const updated = receipt.call_id === null ? undefined : finalized.get(receipt.call_id);
		if (updated) {
			calls.push(updated);
			placed.add(updated.call_id);
			continue;
		}
		calls.push(receipt);
		if (receipt.call_id !== null) placed.add(receipt.call_id);
		if (receipt.usage_status === "pending") {
			gaps.push(`${receipt.call_id}: the provider call started but no result was observed; usage is pending, not measured`);
		}
	}
	for (const [callId, call] of finalized) {
		if (placed.has(callId)) continue;
		calls.push(call);
	}
	calls.push(...unkeyed);
	return { calls, gaps };
}

export function modelCallReceipts(turns, requestedModel) {
	const calls = [];
	const gaps = [];
	if (turns.length === 0) {
		gaps.push("no assistant turn completed for this check attempt, so no provider usage was reported");
	}

	turns.forEach((turn, index) => {
		const label = turnLabel(turn, index);
		if (turn.call_id === null) {
			gaps.push(`${label}: no provider call boundary was observed for this response, so this call has no invocation id`);
		}

		const message = turn.message ?? {};
		const counts = reportedCounts(message);
		const missing = REQUIRED_FIELDS.filter(field => counts[field] === undefined);
		if (missing.length > 0) {
			gaps.push(`${label}: the provider reported no complete usage (${missing.join(", ")} unknown); the call is kept with usage_status=unknown`);
		}

		const completedAt = typeof message.completedAt === "number" ? message.completedAt : message.timestamp;
		const receipt = {
			call_id: turn.call_id,
			origin: turn.call_id === null ? undefined : "local_provider_invocation",
			usage_status: missing.length === 0 ? "reported" : "unknown",
			provider_response_id: optionalString(message.responseId),
			provider: optionalString(message.provider),
			// The executed OMP configuration, not the upstream supplier's model;
			// the requested name is recorded separately, so a fallback inside the
			// session is visible instead of hidden.
			model: optionalString(message.model),
			upstream_provider: optionalString(message.upstreamProvider),
			upstream_model: optionalString(message.upstreamModel),
			requested_model: optionalString(requestedModel),
			stop_reason: optionalString(message.stopReason),
			completed_at: typeof completedAt === "number" ? new Date(completedAt).toISOString() : undefined,
			...counts,
		};
		// Optional identity fields follow the same rule as the counts: an
		// unreported value is removed from the receipt instead of travelling as
		// an explicit undefined, so an unknown stays unknown.
		calls.push(omitUnreported(receipt));
	});

	return { calls, gaps };
}

// Pure conversion of one receipt into the hash Orbit's ResourceCallLedger
// consumes (lib/orbit/resource_call_ledger.rb `record_check`, orbit-resource-
// calls-v1). The output carries no price, no derived token total and no
// fabricated field: six native SDK categories keep their own names, each
// declared in `usage_units` as tokens, and the SDK's own category contract is
// attached as the declared relationship instead of being recomputed.
//
//   meta.role          ledger role: root|member|judgment|checker|arbiter
//   meta.phase         ledger phase label (e.g. "execute", "check")
//   meta.session_id    the session that contained this call, stored under the
//                      ledger's attempt linkage label (attempt_id); like a
//                      check attempt, one session can make several provider
//                      calls, and the label never substitutes for a call id
//   meta.agent_id      ledger member_id
//   meta.work_unit_id  ledger work_unit_id
//   meta.route         verified billing route; anything else stays "unknown"
//   meta.recorded_at   host-side observation time for the event payload; the
//                      ledger stamps its own recorded_at when it stores
//
// Returns null when the receipt has no real call id — an unobserved boundary
// is a gap for the caller to record, never an id manufactured here.
export function ledgerReceipt(call, meta) {
	if (call === null || typeof call !== "object") return null;
	const callId = optionalString(call.call_id);
	if (!callId) return null;

	const usage = {};
	for (const field of COUNT_FIELDS) {
		if (integer(call[field])) usage[field] = call[field];
	}
	const reported = Object.keys(usage).length > 0;
	const stopReason = optionalString(call.stop_reason);
	const status = stopReason === "error" || stopReason === "aborted" ? "failed" : stopReason ? "completed" : "unknown";

	return omitUnreported({
		call_id: callId,
		origin: optionalString(call.origin),
		role: optionalString(meta?.role),
		phase: optionalString(meta?.phase),
		status,
		provider: optionalString(call.provider),
		actual_model: optionalString(call.model),
		requested_model: optionalString(call.requested_model),
		billing_route: optionalString(meta?.route) ?? "unknown",
		// Counts came from the SDK's native assistant message, not from a raw
		// provider HTTP response read by Orbit itself.
		usage_source: "native_message",
		usage_status: optionalString(call.usage_status),
		usage: reported ? usage : null,
		usage_units: reported ? Object.fromEntries(Object.keys(usage).map(field => [field, "token"])) : {},
		category_relationships: "source_declared",
		relationship_note: SDK_RELATIONSHIP_NOTE,
		attempt_id: optionalString(meta?.session_id),
		member_id: optionalString(meta?.agent_id),
		work_unit_id: optionalString(meta?.work_unit_id),
		provider_response_id: optionalString(call.provider_response_id),
		upstream_provider: optionalString(call.upstream_provider),
		upstream_model: optionalString(call.upstream_model),
		recorded_at: optionalString(meta?.recorded_at),
	});
}
