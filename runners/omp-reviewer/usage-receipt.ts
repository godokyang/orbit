// Provider-reported receipts for the model calls inside one reviewer session.
//
// The implementation lives in the shared pure module
// plugins/model-call-receipts.mjs so the Node host and this Bun runner compute
// receipts exactly once; this wrapper only keeps the reviewer's TypeScript
// import path and export surface stable. See the .mjs for the identity,
// usage-status, category-relationship and no-fabrication contract.
export {
	modelCallReceipts,
	pendingCallReceipt,
	syncCallReceipts,
	credentialIdOf,
	matchAccountIdentity,
	accountScopeKey,
} from "../../plugins/model-call-receipts.mjs";

// Pairs assistant message_start/message_end from one session's event stream
// by actual stream order, not by message object identity. SDK 18.3.4 evidence
// (@oh-my-pi/pi-agent-core src/agent-loop.ts): every streamed response emits
// exactly one assistant message_start at the provider stream `start` event
// (:2311) and exactly one message_end at finalization (:2229, :2507), and
// each event carries a FRESH snapshotAssistantMessage clone (:398-407), so an
// object-keyed map never joins the pair (frozen SUT cae67791 check1: real
// starts stayed pending while their ends arrived without a call id).
// Responses are sequential in one session's stream, so an end binds the
// oldest still-open start. An end with no open start genuinely lacks an
// observed boundary: it returns null and the caller keeps the gap — no id is
// manufactured from adjacency or time.
export function createCallBoundaryBinder(): { bindStart: (callId: string) => void; bindEnd: () => string | null } {
	const open: string[] = [];
	return {
		bindStart: callId => {
			open.push(callId);
		},
		bindEnd: () => open.shift() ?? null,
	};
}
export type {
	AccountIdentity,
	LedgerReceiptMeta,
	ModelCallReceipt,
	ModelCallTurn,
	PendingCall,
	ReviewerUsageReport,
} from "../../plugins/model-call-receipts.mjs";
