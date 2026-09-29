import assert from 'node:assert/strict';
import { accountScopeKey, credentialIdOf, ledgerReceipt, matchAccountIdentity, mintCallId, modelCallReceipts, pendingCallReceipt, syncCallReceipts } from '../plugins/model-call-receipts.mjs';

// Shared-module surface: the Node host and the Bun reviewer use the same pure
// computation, and the local invocation id is a real boundary uuid.
{
	assert.equal(typeof pendingCallReceipt, 'function');
	assert.equal(typeof modelCallReceipts, 'function');
	assert.equal(typeof syncCallReceipts, 'function');
	assert.equal(typeof ledgerReceipt, 'function');
	assert.equal(typeof mintCallId, 'function');

	const first = mintCallId();
	const second = mintCallId();
	assert.match(first, /^orbit-call-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
	assert.notEqual(first, second);

	// Boundary → result round trip under one id, straight from the .mjs.
	const callId = mintCallId();
	const pending = pendingCallReceipt({ call_id: callId, requested_model: 'zhipu-coding-plan/glm-5.2',
		message: { role: 'assistant', provider: 'openrouter', model: 'zhipu-coding-plan/glm-5.2', usage: { input: 0, output: 0, cacheRead: 0 } } });
	assert.equal(pending.usage_status, 'pending');
	assert.equal('input' in pending, false);
	const report = syncCallReceipts([pending], [{ call_id: callId, message: { role: 'assistant', provider: 'openrouter',
		model: 'zhipu-coding-plan/glm-5.2', stopReason: 'stop', usage: { input: 100, output: 40, cacheRead: 20 } } }], 'zhipu-coding-plan/glm-5.2');
	assert.equal(report.calls.length, 1);
	assert.equal(report.calls[0].call_id, callId);
	assert.equal(report.calls[0].usage_status, 'reported');
	assert.equal(report.calls[0].input, 100);
	assert.deepEqual(report.gaps, []);
}

// Final usage: a fully reported call converts to the ledger shape with all six
// native categories, token units, separated identities and no price anywhere.
{
	const [call] = modelCallReceipts([{ call_id: 'orbit-call-final-1', message: {
		role: 'assistant', responseId: 'req_1', provider: 'openrouter', model: 'zhipu-coding-plan/glm-5.2',
		upstreamModel: 'z-ai/glm-5.2', upstreamProvider: 'Together', stopReason: 'end', timestamp: 1_700_000_000_000,
		usage: { input: 100, output: 40, cacheRead: 20, cacheWrite: 5, reasoningTokens: 30, totalTokens: 165, cost: { total: 9 } },
	} }], 'zhipu-coding-plan/glm-5.2').calls;

	const entry = ledgerReceipt(call, { role: 'member', phase: 'execute', session_id: 'session-1',
		agent_id: 'w1Y:p1B', work_unit_id: 'unit-7', route: 'subscription_quota', recorded_at: '2026-09-29T10:00:00Z' });
	assert.equal(entry.call_id, 'orbit-call-final-1');
	assert.equal(entry.origin, 'local_provider_invocation');
	assert.equal(entry.role, 'member');
	assert.equal(entry.phase, 'execute');
	assert.equal(entry.status, 'completed');
	assert.equal(entry.usage_source, 'native_message');
	assert.equal(entry.usage_status, 'reported');
	assert.deepEqual(entry.usage, { input: 100, output: 40, cacheRead: 20, cacheWrite: 5, reasoningTokens: 30, totalTokens: 165 });
	assert.deepEqual(entry.usage_units, { input: 'token', output: 'token', cacheRead: 'token', cacheWrite: 'token', reasoningTokens: 'token', totalTokens: 'token' });
	// Categories stay separate: no derived sum ever appears.
	assert.equal(Object.keys(entry.usage).length, 6);
	// Identities never mix: executed, requested and upstream stay apart.
	assert.equal(entry.actual_model, 'zhipu-coding-plan/glm-5.2');
	assert.equal(entry.requested_model, 'zhipu-coding-plan/glm-5.2');
	assert.equal(entry.upstream_model, 'z-ai/glm-5.2');
	assert.equal(entry.upstream_provider, 'Together');
	assert.equal(entry.provider_response_id, 'req_1');
	assert.equal(entry.billing_route, 'subscription_quota');
	// Attribution: the session rides the ledger's attempt linkage label.
	assert.equal(entry.attempt_id, 'session-1');
	assert.equal(entry.member_id, 'w1Y:p1B');
	assert.equal(entry.work_unit_id, 'unit-7');
	assert.equal(entry.recorded_at, '2026-09-29T10:00:00Z');
	// The SDK's own category contract is declared, never recomputed.
	assert.equal(entry.category_relationships, 'source_declared');
	assert.ok(entry.relationship_note.length <= 256);
	// No money, no quota arithmetic, no fabricated fields.
	for (const key of Object.keys(entry)) assert.ok(!/cost|price|amount|quota_consumption/.test(key), key);
	assert.equal('cacheRead' in entry.usage, true);

	// An unverified route stays unknown; it is never rewritten.
	const unrouted = ledgerReceipt(call, { role: 'checker', phase: 'check' });
	assert.equal(unrouted.billing_route, 'unknown');
	assert.equal('attempt_id' in unrouted, false);
	assert.equal('member_id' in unrouted, false);

	// A partial report keeps its trustworthy fields and never invents the rest.
	const [partial] = modelCallReceipts([{ call_id: 'orbit-call-final-2', message: {
		role: 'assistant', model: 'zhipu-coding-plan/glm-5.2', usage: { input: 120, output: 7 },
	} }]).calls;
	const partialEntry = ledgerReceipt(partial, { role: 'checker', phase: 'check' });
	assert.deepEqual(partialEntry.usage, { input: 120, output: 7 });
	assert.deepEqual(partialEntry.usage_units, { input: 'token', output: 'token' });
	assert.equal(partialEntry.usage_status, 'unknown');
	assert.equal('cacheRead' in partialEntry.usage, false);
}

// Failure and missing boundaries: a failed call keeps partial real usage and is
// still recorded; an unobserved boundary yields no id and no ledger entry.
{
	const [errored] = modelCallReceipts([{ call_id: 'orbit-call-fail-1', message: {
		role: 'assistant', model: 'zhipu-coding-plan/glm-5.2', stopReason: 'error', errorMessage: 'stream aborted',
		usage: { input: 900, output: 0, cacheRead: 100 },
	} }]).calls;
	const failedEntry = ledgerReceipt(errored, { role: 'member', phase: 'execute', session_id: 'session-2' });
	assert.equal(failedEntry.status, 'failed');
	assert.deepEqual(failedEntry.usage, { input: 900, cacheRead: 100 });
	assert.equal(failedEntry.usage_status, 'unknown');

	// An errored turn whose counters are only the SDK's initialized zeros claims
	// no consumption at all: usage is unknown, never zero.
	const [zeroed] = modelCallReceipts([{ call_id: 'orbit-call-fail-2', message: {
		role: 'assistant', model: 'zhipu-coding-plan/glm-5.2', stopReason: 'error', errorMessage: '401 unauthorized',
		usage: { input: 0, output: 0, cacheRead: 0 },
	} }]).calls;
	const zeroedEntry = ledgerReceipt(zeroed, { role: 'member', phase: 'execute' });
	assert.equal(zeroedEntry.status, 'failed');
	assert.equal(zeroedEntry.usage, null);
	assert.deepEqual(zeroedEntry.usage_units, {});

	// A pending boundary is still a real recorded call, with unknown usage.
	const pendingEntry = ledgerReceipt(
		pendingCallReceipt({ call_id: 'orbit-call-fail-3', message: { role: 'assistant', model: 'zhipu-coding-plan/glm-5.2' } }),
		{ role: 'member', phase: 'execute' });
	assert.equal(pendingEntry.status, 'unknown');
	assert.equal(pendingEntry.usage, null);
	assert.equal(pendingEntry.usage_status, 'pending');

	// No observed boundary → no invocation id → no ledger entry; the gap is the
	// caller's to record, never an id manufactured by the conversion.
	const [unobserved] = modelCallReceipts([{ call_id: null, message: {
		role: 'assistant', model: 'zhipu-coding-plan/glm-5.2', usage: { input: 5, output: 6, cacheRead: 0 },
	} }]).calls;
	assert.equal(unobserved.call_id, null);
	assert.equal(ledgerReceipt(unobserved, { role: 'member', phase: 'execute' }), null);
	assert.equal(ledgerReceipt(null, { role: 'member', phase: 'execute' }), null);
}

// --- Credential row and keyless account identity -------------------------
// Three scripted accounts; the row that served the message is the only one
// whose identity may be attached. The SDK's list is in stable storage order,
// so a first-item or session-pin fallback would pick acct-first here.
const accounts = [
	{ credentialId: 91, accountId: 'acct-first', email: 'first@example.test' },
	{ credentialId: 42, accountId: 'acct-second', orgId: 'org-second' },
	{ credentialId: 42, accountId: 'acct-duplicate' },
];

// (1) exact match on the credential row, never the first list item.
const matched = matchAccountIdentity(accounts, 42);
assert.equal(matched, undefined, 'a duplicated credential row is ambiguous and stays unknown');
assert.equal(credentialIdOf({ credentialId: 91 }), 91);
assert.deepEqual(matchAccountIdentity([{ credentialId: 91, accountId: 'acct-first', email: 'first@example.test' }], 91),
	{ account_id: 'acct-first' }, 'only the keyless identity fields are carried, never email');
assert.equal(accountScopeKey('zhipu', { account_id: 'acct-first' }), 'zhipu|acct-first|-|-');
assert.equal(accountScopeKey('zhipu', undefined), null);

const [served] = modelCallReceipts([{ call_id: 'orbit-call-acct-1', message: {
	role: 'assistant', provider: 'zhipu', model: 'glm-5.2', stopReason: 'stop', credentialId: 91,
	usage: { input: 10, output: 2, cacheRead: 0 },
} }], 'glm-5.2', () => matchAccountIdentity([{ credentialId: 91, accountId: 'acct-first', orgId: 'org-a' }], 91)).calls;
assert.deepEqual([served.credential_id, served.account_id, served.org_id, served.project_id, served.account_identity_source],
	[91, 'acct-first', 'org-a', undefined, 'oauth_accounts_by_credential_id'],
	'the receipt carries the serving row and only its keyless identity');
assert.equal(served.account_scope, 'zhipu|acct-first|org-a|-');
const servedEntry = ledgerReceipt(served, { role: 'member', phase: 'execute' });
assert.equal(servedEntry.credential_id, 91);
assert.equal(servedEntry.account_id, 'acct-first');
assert.equal(servedEntry.account_identity_source, 'oauth_accounts_by_credential_id');

// (2) a message without a credential row keeps null and an unknown identity.
const [external] = modelCallReceipts([{ call_id: 'orbit-call-acct-2', message: {
	role: 'assistant', provider: 'zhipu', model: 'glm-5.2', stopReason: 'stop',
	usage: { input: 3, output: 1, cacheRead: 0 },
} }], 'glm-5.2', () => ({ account_id: 'must-not-be-used' })).calls;
assert.equal(external.credential_id, null, 'an unreported credential row stays null');
assert.equal(external.account_id, undefined, 'no identity is attached without a credential row');
assert.equal(external.account_scope, undefined);
assert.equal(ledgerReceipt(external, { role: 'member', phase: 'execute' }).credential_id, null);

// (3) a resolver that misses or throws leaves the call recorded and unknown,
//     and the failed call keeps its own real usage fields unchanged.
const [failed] = modelCallReceipts([{ call_id: 'orbit-call-acct-3', message: {
	role: 'assistant', provider: 'zhipu', model: 'glm-5.2', stopReason: 'error', errorMessage: 'boom',
	credentialId: 7, usage: { input: 900, output: 0, cacheRead: 100 },
} }], 'glm-5.2', () => { throw new Error('resolver unavailable'); }).calls;
assert.equal(failed.credential_id, 7, 'the reported row is kept even when the lookup fails');
assert.equal(failed.account_id, undefined);
assert.deepEqual({ input: failed.input, cacheRead: failed.cacheRead, reasoning: failed.reasoningTokens },
	{ input: 900, cacheRead: 100, reasoning: undefined },
	'usage categories keep their own reported fields, separately');

console.log('model_call_receipts_test.mjs: all shared-receipt checks passed');
