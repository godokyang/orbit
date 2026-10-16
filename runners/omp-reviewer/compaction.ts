import { installModelAuthorization, parseAllowedModels, requireAllowedModel } from "../../plugins/model-authorization.mjs";
// Production entry for one JEV compaction model call (satisfied long-material
// shortening; never a check, never a supervision record).
//
//   ORBIT_COMPACTION_REQUEST=request.json omp --trusted-extension /absolute/compaction.ts
// The Ruby supervisor (lib/orbit/jev_compaction_runner.rb) supplies the same
// confined native flags the reviewer uses and owns exit.
//
// The profile must be a fresh directory and PI_CODING_AGENT_DIR must equal it;
// OMP_PROFILE/PI_PROFILE must be unset. The model catalog and credentials come
// from the parent OMP session's own agent dir (source_agent_* fields) through
// the same discoverAuthStorage/ModelRegistry path the reviewer uses: no second
// login and no credential copies. This session has no tools at all (no
// read/grep/glob/yield): it may only answer in prose. Every statement the
// compacted text makes must come from the supplied prompt material; the prompt
// says so, and this process adds no fact of its own.
import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { isUsageLimitOutcome } from "@oh-my-pi/pi-ai/error";
import { getBaseConfigRoot, getModelDbPath, getProfileRootDir, resolveProfileEnv, postmortem } from "@oh-my-pi/pi-utils";
import { providerErrorFact } from "./provider-error.ts";
import { credentialIdOf, createCallBoundaryBinder, matchAccountIdentity, pendingCallReceipt, syncCallReceipts,
	type AccountIdentity, type ModelCallReceipt, type ModelCallTurn } from "./usage-receipt.ts";

type Request = {
	profile?: string;
	out?: string;
	prompt?: string;
	model?: string;
	allowed_models?: string[];
	// Launcher-supplied label for this compaction process. It names the process,
	// not the model call inside it; without one this process mints its own.
	attempt_id?: string;
	// Parent OMP session inputs captured by the launcher before it confined
	// this process. Plain paths and profile names only — never credentials.
	source_agent_dir?: string;
	source_pi_coding_agent_dir?: string;
	source_pi_config_dir?: string;
	source_omp_profile?: string;
	source_pi_profile?: string;
	source_project_dir?: string;
	// Actual local host version supplied by the supervisor.
	sdk_version?: string;
	// Zero-cost contract check: create the no-tools session, report its active
	// tools and dispose it without sending any prompt (no provider call).
	session_probe?: boolean;
};

// A trusted factory deliberately stays pending. Only its owning parent ends
// the host, using its real process-group signal after collecting completion.
export default async function compactionFactory(api: ExtensionAPI): Promise<never> {
const { AgentRegistry, createAgentSession, discoverAuthStorage, isAuthenticated,
    ModelRegistry, SessionManager, Settings } = api.pi;

function arg(name: string): string | undefined {
	const index = process.argv.indexOf(`--${name}`);
	return index === -1 ? undefined : process.argv[index + 1];
}

function loadRequest(): Request {
	const configPath = process.env.ORBIT_COMPACTION_REQUEST;
	const fromFile = configPath ? (JSON.parse(readFileSync(configPath, "utf8")) as Request) : {};
	if (typeof fromFile !== "object" || fromFile === null || Array.isArray(fromFile)) {
		throw new Error("--config must be a JSON object");
	}
	const cli: Request = {
		profile: arg("profile"),
		out: arg("out"),
		prompt: arg("prompt"),
		model: arg("model"),
		attempt_id: arg("attempt-id"),
		source_agent_dir: arg("source-agent-dir"),
		source_pi_coding_agent_dir: arg("source-pi-coding-agent-dir"),
		source_omp_profile: arg("source-omp-profile"),
		source_pi_profile: arg("source-pi-profile"),
		source_project_dir: arg("source-project-dir"),
		sdk_version: arg("sdk-version"),
	};
	return {
		...fromFile,
		...Object.fromEntries(Object.entries(cli).filter(([, value]) => value !== undefined)),
	};
}

// Temp file plus rename, so a reader of an in-flight compaction never sees half
// a document. Returns false instead of throwing: a write that cannot happen
// must not decide the compaction's own outcome.
function writeEvidenceAtomically(target: string, payload: unknown): boolean {
	const temporary = `${target}.${process.pid}.tmp`;
	try {
		writeFileSync(temporary, JSON.stringify(payload, null, 2));
		renameSync(temporary, target);
		return true;
	} catch {
		try {
			unlinkSync(temporary);
		} catch {
			// The leftovers sit next to the evidence file and carry no result.
		}
		return false;
	}
}

// Structured failure kinds matching lib/orbit/omp_check_runner.rb FAILURE_KINDS.
class CompactionFailure extends Error {
	readonly kind: "auth_or_quota" | "unavailable" | "invalid_result";
	constructor(message: string, kind: "auth_or_quota" | "unavailable" | "invalid_result") {
		super(message);
		this.kind = kind;
	}
}

function boundedReason(text: string): string {
	return text.replace(/\s+/g, " ").trim().slice(0, 200);
}

// The parent OMP session's effective agent dir, resolved from the env inputs
// the launcher captured before confining this process. Mirrors the reviewer's
// copy of pi-utils' DirResolver precedence: a named profile (OMP_PROFILE >
// PI_PROFILE) derives its own agent dir and ignores PI_CODING_AGENT_DIR;
// default mode honors a non-profile override; otherwise the base config root.
// An invalid profile name resolves to the default, like the SDK's own safe
// module-load path.
function resolveSourceAgentDir(request: Request): string {
	const confined = process.env.PI_CONFIG_DIR;
	if (request.source_pi_config_dir === undefined) delete process.env.PI_CONFIG_DIR;
	else process.env.PI_CONFIG_DIR = request.source_pi_config_dir;
	try {
		if (request.source_agent_dir?.trim()) return realpathSync(path.resolve(request.source_agent_dir));
		let profile: string | undefined;
		try {
			profile = resolveProfileEnv(request.source_omp_profile, request.source_pi_profile);
		} catch {
			profile = undefined;
		}
		if (profile) return realpathSync(path.join(getProfileRootDir(profile), "agent"));
		let piProfile: string | undefined;
		try {
			piProfile = resolveProfileEnv(undefined, request.source_pi_profile);
		} catch {
			piProfile = undefined;
		}
		const profileDerived = piProfile ? path.join(getProfileRootDir(piProfile), "agent") : undefined;
		const override = request.source_pi_coding_agent_dir?.trim();
		if (override && path.resolve(override) !== profileDerived) return realpathSync(path.resolve(override));
		return realpathSync(path.join(getBaseConfigRoot(), "agent"));
	} finally {
		if (confined === undefined) delete process.env.PI_CONFIG_DIR;
		else process.env.PI_CONFIG_DIR = confined;
	}
}

const request = loadRequest();
const allowedModels = parseAllowedModels(request.allowed_models);
requireAllowedModel(request.model, allowedModels);
const problems: string[] = [];
const requestedAttemptId = request.attempt_id;
if (requestedAttemptId !== undefined && !/^[\x20-\x7e]{1,200}$/.test(requestedAttemptId)) {
	throw new Error("attempt_id must be 1-200 printable characters");
}

const evidence: Record<string, unknown> = {
	mode: "compaction",
	attempt_id: requestedAttemptId ?? `orbit-compaction-${randomUUID()}`,
	ok: false,
	model: null,
	requested_model: request.model ?? null,
	raw_text: null,
	input_bytes: null,
	output_bytes: null,
	elapsed_ms: null,
	started_at: null,
	completed_at: null,
	usage: null,
	usage_gaps: [],
};

// The enclosing trusted factory stays pending, so OMP's outer startup watchdog
// cannot describe this private session. Record only phase facts, never prompt
// text, stream content or credentials.
function recordPhase(phase: string): void {
	evidence.compaction_phase = phase;
	evidence.compaction_phase_at = new Date().toISOString();
	persistEvidence();
}

function persistEvidence(): void {
	if (!request.out) return;
	if (!writeEvidenceAtomically(request.out, evidence) && evidence.evidence_write_failed !== true) {
		evidence.evidence_write_failed = true;
	}
}

// Disposal is a swappable closure because postmortem registration happens
// before the private session exists, and it must still end that session on a
// signal. It does three things per call (session, auth storage, evidence flag).
let disposePrivate = async (): Promise<void> => {};
let syncInterruptedUsage: (() => void) | undefined;
postmortem.register("orbit-jev-compaction", async (reason: string) => {
	syncInterruptedUsage?.();
	try { await disposePrivate(); } catch (error) { evidence.cleanup_error = String(error); }
	evidence.signal_cleanup = reason;
	persistEvidence();
});

try {
	if (!request.session_probe && (!request.prompt || !request.model)) {
		throw new Error("prompt and model are required for a compaction call");
	}
	const profile = path.resolve(request.profile);
	const out = path.resolve(request.out);
	const promptPath = request.prompt === undefined ? null : path.resolve(request.prompt);
	evidence.profile = profile;
	evidence.out = out;
	if (process.env.PI_CODING_AGENT_DIR !== profile || process.env.OMP_PROFILE || process.env.PI_PROFILE) {
		throw new Error("run with PI_CODING_AGENT_DIR=<profile> and without OMP_PROFILE/PI_PROFILE");
	}
	const version = request.sdk_version;
	if (!version) throw new Error("launcher must supply actual host version");
	evidence.sdk_version = version;
	evidence.host_version = version;
	evidence.host_runtime_executable = realpathSync(process.execPath);

	recordPhase("catalog_loading");
	const sourceAgentDir = resolveSourceAgentDir(request);
	if (!path.isAbsolute(sourceAgentDir) || sourceAgentDir === profile) {
		throw new Error(`invalid source agent dir: ${sourceAgentDir}`);
	}
	let stat;
	try {
		stat = lstatSync(sourceAgentDir);
	} catch {
		throw new Error(`source agent dir is not accessible: ${sourceAgentDir}`);
	}
	if (!stat.isDirectory()) throw new Error("source agent dir is not a directory");
	evidence.source_agent_dir = sourceAgentDir;
	const settings = await Settings.loadReadOnly({
		cwd: request.source_project_dir ? path.resolve(request.source_project_dir) : process.cwd(),
		agentDir: sourceAgentDir,
	});
	const authStorage = await discoverAuthStorage(sourceAgentDir);
	const modelRegistry = new ModelRegistry(authStorage, path.join(sourceAgentDir, "models.yml"), {
		settings,
		cacheDbPath: getModelDbPath(sourceAgentDir),
	});
	await modelRegistry.refresh("online-if-uncached");

	let model;
	if (request.model) {
		const [provider, ...rest] = request.model.split("/");
		const id = rest.join("/");
		if (!provider || !id) throw new Error("model must be provider/id");
		model = modelRegistry.find(provider, id);
		if (!model) throw new CompactionFailure(`model not in catalog: ${request.model}`, "unavailable");
		try {
			const key = await modelRegistry.getApiKey(model);
			if (!isAuthenticated(key)) throw new CompactionFailure(`no credential for ${provider}`, "auth_or_quota");
		} catch (error) {
			if (error instanceof CompactionFailure) throw error;
			throw new CompactionFailure(`credential resolution failed for ${provider}: ${boundedReason(error instanceof Error ? error.message : String(error))}`, "auth_or_quota");
		}
	}

	recordPhase("session_creating");
	const sessionRoot = path.join(profile, "compaction-workspace");
	mkdirSync(sessionRoot, { recursive: true });
	const agentRegistry = new AgentRegistry();
	const { session } = await createAgentSession({
		cwd: sessionRoot,
		agentDir: profile,
		authStorage,
		modelRegistry,
		model,
		thinkingLevel: "low",
		settings: Settings.isolated({
			"memory.backend": "off",
			"memories.enabled": false,
			"stt.enabled": false,
			"fetch.enabled": false,
			"web_search.enabled": false,
			"github.enabled": false,
			"bash.enabled": false,
			"autolearn.enabled": false,
			"checkpoint.enabled": false,
			"goal.enabled": false,
			// Provider-error turns skip SDK auto-retry: this runner makes exactly
			// one attempt, and a failure is reported instead of being retried.
			"retry.enabled": false,
		}),
		sessionManager: SessionManager.create(sessionRoot, path.join(profile, "sessions")),
		// No tool at all: a compaction answer is prose, and this session must not
		// read the project, run commands or submit a structured result.
		toolNames: [],
		restrictToolNames: true,
		customTools: [],
		enableMCP: false,
		enableIrc: false,
		enableLsp: false,
		disableExtensionDiscovery: true,
		skills: [],
		rules: [],
		contextFiles: [],
		promptTemplates: [],
		slashCommands: [],
		agentRegistry,
		agentId: "OrbitCompactor",
		agentDisplayName: "orbit-compactor",
		hasUI: false,
		skipPythonPreflight: true,
	});
	installModelAuthorization(session, () => allowedModels, { main: true });
	evidence.session_created = true;
	disposePrivate = async () => {
		await session.dispose();
		authStorage.close();
		evidence.session_disposed = true;
	};
	recordPhase("session_ready");

	try {
		const activeTools: string[] = session.getActiveToolNames().sort();
		evidence.active_tools = activeTools;
		if (activeTools.length > 0) problems.push(`compaction must run without tools, got ${activeTools.join(", ")}`);
		evidence.model = session.model ? `${session.model.provider}/${session.model.id}` : null;

		// Contract probe: the session exists with no tools and no prompt is sent,
		// so nothing is metered and no provider call happens.
		if (request.session_probe) {
			evidence.session_probe = true;
			recordPhase("probe_complete");
		} else {
			const turns: ModelCallTurn[] = [];
			const sessionLabel = session.model ? `${session.model.provider}/${session.model.id}` : undefined;
			let receipts: ModelCallReceipt[] = [];
			// The session's auth storage OAuth list is not part of the public
			// ModelRegistry type, so it is read through the same validated optional
			// path the reviewer uses and only for a keyless account label.
			const accountIdentityFor = (message: unknown): AccountIdentity | undefined => {
				const credentialId = credentialIdOf(message);
				const providerName = message !== null && typeof message === "object" && "provider" in message &&
					typeof message.provider === "string" && message.provider.length > 0 ? message.provider : null;
				if (credentialId === null || providerName === null) return undefined;
				try {
					const oauth = (session.modelRegistry as { authStorage?: { oauth?: { accounts?: (p: string) => unknown } } })?.authStorage?.oauth;
					return matchAccountIdentity(oauth?.accounts?.(providerName), credentialId);
				} catch {
					return undefined;
				}
			};
			const syncUsage = () => {
				const keyed = receipts.filter(receipt => receipt.call_id !== null);
				const report = syncCallReceipts(keyed, turns, request.model!, accountIdentityFor);
				receipts = report.calls;
				evidence.usage = receipts.length > 0 ? receipts : null;
				evidence.usage_gaps = report.gaps;
			};
			syncInterruptedUsage = syncUsage;
			const boundaryBinder = createCallBoundaryBinder();
			session.subscribe(event => {
				if (event.type !== "message_start" && event.type !== "message_end") return;
				const message = event.message;
				if (message.role !== "assistant") return;
				if (event.type === "message_start") {
					const callId = `orbit-call-${randomUUID()}`;
					boundaryBinder.bindStart(callId);
					receipts.push(pendingCallReceipt({ call_id: callId, message, requested_model: request.model,
						session_model: sessionLabel, account: accountIdentityFor(message) }));
					syncUsage();
					recordPhase("provider_stream_started");
					return;
				}
				turns.push({ call_id: boundaryBinder.bindEnd(), message });
				syncUsage();
				recordPhase("provider_turn_ended");
			});

			if (promptPath === null) throw new Error("prompt is required for a compaction call");
			const prompt = readFileSync(promptPath, "utf8");
			evidence.input_bytes = Buffer.byteLength(prompt, "utf8");
			evidence.started_at = new Date().toISOString();
			const startedAt = Date.now();
			recordPhase("prompt_running");
			await session.prompt(prompt);
			evidence.elapsed_ms = Date.now() - startedAt;
			evidence.completed_at = new Date().toISOString();

			const last = [...session.messages].reverse().find(message => message.role === "assistant");
			const text = (last?.content ?? []).filter((part: { type: string }) => part.type === "text").map((part: { text: string }) => part.text).join("");
			// A mid-session provider failure arrives as an assistant turn with
			// stopReason "error"; it fails the compaction even if text was produced.
			const providerError = providerErrorFact(last, isUsageLimitOutcome);
			if (providerError) {
				evidence.error = { ...providerError };
				problems.push(`provider error: ${providerError.detail}`);
			}
			evidence.raw_text = text;
			evidence.output_bytes = Buffer.byteLength(text, "utf8");
			if (!evidence.model) problems.push("session did not report an actual provider/model");
			else if (evidence.model !== request.model) problems.push(`model drift: requested ${request.model}, session resolved ${evidence.model}`);
		}
	} finally {
		// Receipts are kept on every path: a metered call is never reported as
		// free, and a call the provider did not identify is named in usage_gaps
		// instead of being invented.
		syncInterruptedUsage?.();
		recordPhase("session_disposing");
		await disposePrivate();
	}
} catch (error) {
	const stack = error instanceof Error ? error.stack : undefined;
	problems.push(error instanceof Error ? error.message : String(error));
	evidence.diagnostic_stack = stack ?? null;
	if (error instanceof CompactionFailure) {
		evidence.error = { kind: error.kind, detail: error.message };
	}
	if (stack) console.error(stack);
}

try { await disposePrivate(); } catch (error) { problems.push(`cleanup failed: ${String(error)}`); }
evidence.problems = problems;
// A probe proves the session contract, not a text; a compaction call must have
// produced text.
evidence.ok = problems.length === 0 && (request.session_probe === true ||
	(typeof evidence.raw_text === "string" && evidence.raw_text.trim().length > 0));
evidence.host_completion = "complete";
recordPhase("complete");
if (!writeEvidenceAtomically(request.out, evidence)) throw new Error("cannot persist final compaction evidence");
setInterval(() => {}, 1000);
return await new Promise<never>(() => {});
}
