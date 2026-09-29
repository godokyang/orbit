// Type declarations for plugins/model-call-receipts.mjs. The implementation
// comment in the .mjs is the semantic authority; these declarations exist so
// both the Bun reviewer wrapper and TypeScript editors share one type source.

export interface ModelCallReceipt {
	call_id: string | null;
	origin?: "local_provider_invocation";
	// "pending" is an observed call boundary whose result has not arrived yet:
	// identity is kept, and no counts are claimed at all.
	usage_status: "reported" | "unknown" | "pending";
	provider_response_id?: string;
	provider?: string;
	model?: string;
	upstream_provider?: string;
	upstream_model?: string;
	requested_model?: string;
	stop_reason?: string;
	completed_at?: string;
	input?: number;
	output?: number;
	cacheRead?: number;
	cacheWrite?: number;
	reasoningTokens?: number;
	totalTokens?: number;
}

/** One provider call: the local boundary id and the assistant turn it produced. */
export interface ModelCallTurn {
	call_id: string | null;
	message: unknown;
}

/** A provider call boundary whose result has not been observed yet. */
export interface PendingCall {
	call_id: string;
	message: unknown;
	requested_model?: string;
	/** Session identity (`provider/id`), used only when the turn itself has no model. */
	session_model?: string;
}

export interface ReviewerUsageReport {
	calls: ModelCallReceipt[];
	gaps: string[];
}

/** Attribution meta for the pure ledger conversion; see ledgerReceipt. */
export interface LedgerReceiptMeta {
	role?: string;
	phase?: string;
	session_id?: string;
	agent_id?: string;
	work_unit_id?: string;
	route?: string;
	recorded_at?: string;
}

/** Mints Orbit's local invocation id; call only at an observed call boundary. */
export function mintCallId(): string;

export function pendingCallReceipt(call: PendingCall): ModelCallReceipt;

export function syncCallReceipts(
	existing: readonly ModelCallReceipt[],
	turns: readonly ModelCallTurn[],
	requestedModel?: string,
): ReviewerUsageReport;

export function modelCallReceipts(turns: readonly ModelCallTurn[], requestedModel?: string): ReviewerUsageReport;

/** Converts one receipt to the ResourceCallLedger shape; null when no real call id. */
export function ledgerReceipt(call: ModelCallReceipt, meta: LedgerReceiptMeta): Record<string, unknown> | null;
