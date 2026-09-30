// Production entry for one independent OMP reviewer/adjudicator session.
//
//   bun reviewer.ts --config request.json
//   bun reviewer.ts --snapshot DIR --profile DIR --out FILE [--prompt FILE] [--model provider/id]
//
// The profile must be a fresh directory and PI_CODING_AGENT_DIR must equal it;
// OMP_PROFILE/PI_PROFILE must be unset. Session state stays confined to that
// profile, while the model catalog and credentials come from the parent OMP
// session's own agent dir (source_agent_* fields): the same models.yml, model
// cache, settings and auth storage the host session uses, resolved through
// OMP's official discoverAuthStorage/ModelRegistry path. No second login, no
// credential copies: tokens live only inside OMP's own storage and process
// memory. Without --model this process does not call a model; a confinement
// probe is not a check result.
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { lstatSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { recoverTrailingJsonObject } from "./json-recovery";
import { providerErrorFact } from "./provider-error.ts";
import { parseProbeModels, probeModelAvailability, type CredentialAvailability } from "./model-probe";
import { validateCheckResult } from "./check-result";
import {
	AgentRegistry,
	createAgentSession,
	discoverAuthStorage,
	isAuthenticated,
	ModelRegistry,
	SessionManager,
	Settings,
	type AuthStorage,
} from "@oh-my-pi/pi-coding-agent";
import { getBaseConfigRoot, getModelDbPath, getProfileRootDir, resolveProfileEnv } from "@oh-my-pi/pi-utils";
import { createConfinedTools } from "./confined-tools.ts";
import {
	createCallBoundaryBinder,
	matchAccountIdentity,
	pendingCallReceipt,
	syncCallReceipts,
	type AccountIdentity,
	type ModelCallReceipt,
	type ModelCallTurn,
} from "./usage-receipt.ts";

const REVIEW_TOOLS = ["read", "grep", "glob"];
const FORBIDDEN_TOOLS = ["write", "edit", "bash", "eval", "task", "hub", "todo", "ask", "web_search", "browser", "lsp", "ast_edit", "notebook", "checkpoint", "rewind", "goal", "manage_skill", "learn"];

type Request = {
	snapshot?: string;
	profile?: string;
	out?: string;
	prompt?: string;
	model?: string;
	// Launcher-supplied check-attempt id. It names this reviewer process, not
	// the model calls inside it; without one this process mints its own.
	attempt_id?: string;
	probe_models?: string;
	probe_outside?: string;
	probe_inside?: string;
	probe_inside_link?: string;
	probe_symlink_file?: string;
	probe_symlink_dir?: string;
	probe_secret?: string;
	// Parent OMP session inputs captured by the launcher before it confined
	// this process. Plain paths and profile names only — never credentials.
	source_agent_dir?: string;
	source_pi_coding_agent_dir?: string;
	source_omp_profile?: string;
	source_pi_profile?: string;
	source_project_dir?: string;
	// Reviewer SDK version the install verified; falls back to this runner's
	// own package.json dependency when absent (manual runs).
	sdk_version?: string;
};

function arg(name: string): string | undefined {
	const index = process.argv.indexOf(`--${name}`);
	return index === -1 ? undefined : process.argv[index + 1];
}

function loadRequest(): Request {
	const configPath = arg("config");
	const fromFile = configPath ? (JSON.parse(readFileSync(configPath, "utf8")) as Request) : {};
	if (typeof fromFile !== "object" || fromFile === null || Array.isArray(fromFile)) {
		throw new Error("--config must be a JSON object");
	}
	const cli: Request = {
		snapshot: arg("snapshot"),
		profile: arg("profile"),
		out: arg("out"),
		prompt: arg("prompt"),
		model: arg("model"),
		attempt_id: arg("attempt-id"),
		probe_models: arg("probe-models"),
		probe_outside: arg("probe-outside"),
		probe_inside: arg("probe-inside"),
		probe_inside_link: arg("probe-inside-link"),
		probe_symlink_file: arg("probe-symlink-file"),
		probe_symlink_dir: arg("probe-symlink-dir"),
		probe_secret: arg("probe-secret"),
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

function sdkVersion(): string {
	// import.meta.resolve() in this module returns a repeated "file:file:..." string
	// (observed length 4244) and readFileSync then throws ENAMETOOLONG. Read the
	// package that actually satisfied the import, next to this file.
	const pkg = path.join(path.dirname(fileURLToPath(import.meta.url)), "node_modules", "@oh-my-pi", "pi-coding-agent", "package.json");
	return JSON.parse(readFileSync(pkg, "utf8")).version;
}

function expectedSdkVersion(request: Request): string {
	const fromRequest = request.sdk_version?.trim();
	if (fromRequest) return fromRequest;
	const pkg = path.join(path.dirname(fileURLToPath(import.meta.url)), "package.json");
	const declared = JSON.parse(readFileSync(pkg, "utf8"))?.dependencies?.["@oh-my-pi/pi-coding-agent"];
	if (typeof declared !== "string" || !declared.trim()) throw new Error("cannot determine the expected reviewer SDK version");
	return declared.trim();
}

function fingerprint(root: string): string {
	const lib = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../lib/orbit/workspace_snapshot.rb");
	const code = [
		`require ${JSON.stringify(lib)}`,
		"puts Orbit::WorkspaceSnapshot.fingerprint(project_root: ARGV[0])",
	].join("\n");
	return execFileSync(process.env.ORBIT_RUBY || "ruby", ["--disable-gems", "-e", code, root], { encoding: "utf8" }).trim();
}

function within(root: string, candidate: string): boolean {
	const relative = path.relative(root, candidate);
	return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

// The evidence path is written only where the final write is allowed: never
// inside the fixed snapshot, and only when an output file was requested.
function evidencePath(current: Request): string | undefined {
	if (!current.out) return undefined;
	if (current.snapshot && within(path.resolve(current.snapshot), path.resolve(current.out))) return undefined;

	return current.out;
}

// Temp file plus rename, so a reader of an in-flight attempt never sees half a
// document. Returns false instead of throwing: a write that cannot happen must
// not decide the check's verdict.
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
			// The leftovers sit next to the evidence file and carry no verdict.
		}
		return false;
	}
}

// Persists the evidence as it currently stands. This runs when a provider call
// boundary is observed, so an interrupted attempt still shows its call ids and
// an explicit pending status instead of leaving no receipt at all.
function persistEvidence(): void {
	const target = evidencePath(request);
	if (!target) return;
	if (!writeEvidenceAtomically(target, evidence) && evidence.evidence_write_failed !== true) {
		evidence.evidence_write_failed = true;
	}
}


function agentsFile(snapshot: string): Array<{ path: string; content: string }> {
	const file = path.join(snapshot, "AGENTS.md");
	try {
		if (!lstatSync(file).isFile()) return [];
		const real = realpathSync(file);
		if (!within(realpathSync(snapshot), real)) throw new Error("AGENTS.md resolves outside the snapshot");
		return [{ path: file, content: readFileSync(real, "utf8") }];
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
		throw error;
	}
}

// Structured failure kinds matching lib/orbit/omp_check_runner.rb FAILURE_KINDS.
// A ReviewerFailure is written to evidence.error.kind so the Ruby side can use
// the "structured" basis directly instead of the heuristic text pattern.
class ReviewerFailure extends Error {
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
// the launcher captured before confining this process. Mirrors pi-utils'
// DirResolver precedence: a named profile (OMP_PROFILE > PI_PROFILE) derives
// its own agent dir and ignores PI_CODING_AGENT_DIR; default mode honors a
// non-profile PI_CODING_AGENT_DIR override; otherwise the base config root's
// agent dir. Invalid names resolve to the default, like the SDK's own safe
// module-load path.
function sourceProfileName(request: Request): string | undefined {
	try {
		return resolveProfileEnv(request.source_omp_profile, request.source_pi_profile);
	} catch {
		return undefined;
	}
}

function resolveSourceAgentDir(request: Request): string {
	if (request.source_agent_dir?.trim()) return path.resolve(request.source_agent_dir);
	const profile = sourceProfileName(request);
	if (profile) return path.join(getProfileRootDir(profile), "agent");
	let piProfile: string | undefined;
	try {
		piProfile = resolveProfileEnv(undefined, request.source_pi_profile);
	} catch {
		piProfile = undefined;
	}
	const profileDerived = piProfile ? path.join(getProfileRootDir(piProfile), "agent") : undefined;
	const override = request.source_pi_coding_agent_dir?.trim();
	if (override && path.resolve(override) !== profileDerived) return path.resolve(override);
	return path.join(getBaseConfigRoot(), "agent");
}

// Build the catalog and credential store from the parent OMP session's agent
// dir with the exact formula createAgentSession uses for a host session:
// read-only settings (no writes to the user's config), discoverAuthStorage
// (local SQLite or the configured broker — OMP's own store), the source
// models.yml and model-cache database, then the same cache-first refresh the
// host session performs. One resolution path for the probe and the real
// check; credentials never leave OMP's storage.
async function buildSourceCatalog(request: Request, sourceAgentDir: string): Promise<{ authStorage: AuthStorage; modelRegistry: ModelRegistry }> {
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
	return { authStorage, modelRegistry };
}

// Availability-only credential resolution for the probe: OMP's own per-model
// resolver (the same call the real check's session makes at request time),
// returning a boolean plus a bounded structured reason. The resolved key is
// read to test presence and immediately discarded — never returned or written.
function credentialResolver(modelRegistry: ModelRegistry): (provider: string, id: string) => Promise<CredentialAvailability> {
	return async (provider, id) => {
		const model = modelRegistry.find(provider, id);
		if (!model) return { ok: false, reason: "model not in OMP source catalog" };
		try {
			const key = await modelRegistry.getApiKey(model);
			if (isAuthenticated(key)) return { ok: true };
			return { ok: false, reason: `no credential for ${provider}` };
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			return { ok: false, reason: `credential resolution failed for ${provider}: ${boundedReason(message)}` };
		}
	};
}

const request = loadRequest();
const problems: string[] = [];
// One id per reviewer process. It identifies this check attempt only: the model
// calls inside it carry their own provider-reported ids, and this attempt id
// never substitutes for one that is missing.
const requestedAttemptId = request.attempt_id;
if (requestedAttemptId !== undefined && !/^[\x20-\x7e]{1,200}$/.test(requestedAttemptId)) {
	throw new Error("attempt_id must be 1-200 printable characters");
}
const evidence: Record<string, unknown> = {
	attempt_id: requestedAttemptId ?? `orbit-check-${randomUUID()}`,
	ok: false,
	review_ran: false,
	probe_ran: false,
	result: null,
	model: null,
	usage: null,
	usage_gaps: [],
};
let exitCode = 1;
let openAuthStorage: AuthStorage | undefined;

try {
	const probeSpecs = parseProbeModels(request.probe_models);
	const probeMode = request.probe_models !== undefined;
	if (!request.profile || !request.out) throw new Error("profile and out are required");
	if (!request.snapshot && !probeMode) throw new Error("a snapshot is required for a check");
	const snapshot = request.snapshot ? path.resolve(request.snapshot) : undefined;
	const profile = path.resolve(request.profile);
	const out = path.resolve(request.out);
	if (snapshot) evidence.snapshot = snapshot;
	evidence.profile = profile;
	evidence.out = out;
	if (process.env.PI_CODING_AGENT_DIR !== profile || process.env.OMP_PROFILE || process.env.PI_PROFILE) {
		throw new Error("run with PI_CODING_AGENT_DIR=<profile> and without OMP_PROFILE/PI_PROFILE");
	}
	if (snapshot && (within(snapshot, out) || within(snapshot, profile))) throw new Error("profile and out must stay outside the snapshot");
	const version = sdkVersion();
	evidence.sdk_version = version;
	const expectedSdk = expectedSdkVersion(request);
	if (version !== expectedSdk) throw new Error(`SDK ${version} does not match the expected reviewer SDK ${expectedSdk}`);
	const modeCount = [request.model, request.probe_outside, probeMode].filter(Boolean).length;
	if (modeCount === 0) throw new Error("pass --model for a check, a confinement probe, or --probe-models; none is a pass by itself");
	if (modeCount > 1) throw new Error("use exactly one of --model, --probe-outside, or --probe-models");
	if (probeMode && probeSpecs.length === 0) throw new Error("--probe-models requires at least one provider/id");

	if (snapshot) evidence.fingerprint_before = fingerprint(snapshot);
	const usesSourceCatalog = Boolean(request.model) || probeMode;
	let authStorage: AuthStorage;
	let modelRegistry: ModelRegistry;
	if (usesSourceCatalog) {
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
		if (!stat.isDirectory()) throw new Error(`source agent dir is not a directory: ${sourceAgentDir}`);
		evidence.source_agent_dir = sourceAgentDir;
		({ authStorage, modelRegistry } = await buildSourceCatalog(request, sourceAgentDir));
		openAuthStorage = authStorage;
	} else {
		authStorage = await discoverAuthStorage(profile);
		modelRegistry = new ModelRegistry(authStorage);
		openAuthStorage = authStorage;
	}
	let model;
	if (request.model) {
		if (!request.prompt) throw new Error("model requires a prompt file");
		const [provider, ...rest] = request.model.split("/");
		const id = rest.join("/");
		if (!provider || !id) throw new Error("model must be provider/id");
		model = modelRegistry.find(provider, id);
		if (!model) throw new ReviewerFailure(`model not in catalog: ${request.model}`, "unavailable");
		// Fail fast on missing credentials with the same structured kind the
		// runtime uses, resolved through OMP's own store. The key is discarded;
		// the session below resolves its own fresh credential per request.
		try {
			const key = await modelRegistry.getApiKey(model);
			if (!isAuthenticated(key)) throw new ReviewerFailure(`no credential for ${provider}`, "auth_or_quota");
		} catch (error) {
			if (error instanceof ReviewerFailure) throw error;
			throw new ReviewerFailure(`credential resolution failed for ${provider}: ${boundedReason(error instanceof Error ? error.message : String(error))}`, "auth_or_quota");
		}
	}

	if (probeMode) {
		evidence.probe_models = await probeModelAvailability(
			probeSpecs,
			(provider, id) => modelRegistry.find(provider, id) !== undefined,
			credentialResolver(modelRegistry),
		);
	} else if (snapshot !== undefined) {
		const agentRegistry = new AgentRegistry();
		const { session } = await createAgentSession({
			cwd: snapshot,
			agentDir: profile,
			authStorage,
			modelRegistry,
			model,
			thinkingLevel: request.model ? "low" : undefined,
			settings: Settings.isolated({
				"fetch.enabled": false,
				"web_search.enabled": false,
				"github.enabled": false,
				"bash.enabled": false,
				"autolearn.enabled": false,
				"checkpoint.enabled": false,
				"goal.enabled": false,
				// Provider-error turns skip SDK auto-retry here; Orbit's
				// existing bounded model reselection handles failures. Isolated
				// checker/adjudicator sessions only.
				"retry.enabled": false,
			}),
			sessionManager: SessionManager.create(snapshot, path.join(profile, "sessions")),
			toolNames: REVIEW_TOOLS,
			restrictToolNames: true,
			allowRestrictedCustomTools: true,
			customTools: createConfinedTools(snapshot),
			enableMCP: false,
			enableIrc: false,
			enableLsp: false,
			disableExtensionDiscovery: true,
			skills: [],
			rules: [],
			contextFiles: agentsFile(snapshot),
			promptTemplates: [],
			slashCommands: [],
			agentRegistry,
			agentId: "OrbitReviewer",
			agentDisplayName: "orbit-reviewer",
			hasUI: false,
			skipPythonPreflight: true,
		});

		let syncReviewUsage: (() => void) | undefined;
		try {
			const active = session.getActiveToolNames().sort();
			const forbidden = FORBIDDEN_TOOLS.filter(name => session.getToolByName(name) !== undefined);
			evidence.active_tools = active;
			evidence.forbidden_tools_present = forbidden;
			evidence.read_tool_is_confined = session.getToolByName("read")?.label === "Read (snapshot)";
			evidence.private_registry = agentRegistry.list().map(ref => ref.id);
			evidence.global_registry = AgentRegistry.global().list().map(ref => ref.id);
			const toolProblems: string[] = [];
			if (active.join() !== [...REVIEW_TOOLS].sort().join()) toolProblems.push(`active tools must be only read/grep/glob, got ${active.join(", ") || "(none)"}`);
			if (forbidden.length) toolProblems.push(`forbidden tools present: ${forbidden.join(", ")}`);
			if (evidence.read_tool_is_confined !== true) toolProblems.push("read is not the confined replacement");
			if ((evidence.global_registry as string[]).length) toolProblems.push("reviewer registered on the global agent registry");
			problems.push(...toolProblems);

			if (request.probe_outside && toolProblems.length === 0) {
				evidence.probe_ran = true;
				const secret = request.probe_secret ?? "OUTSIDE_SECRET";
				const liveDir = path.dirname(request.probe_outside);
				const cases: Array<[string, string, Record<string, unknown>, "allow" | "deny" | "allow-clean"]> = [];
				if (request.probe_inside) {
					cases.push(["read_inside", "read", { path: request.probe_inside }, "allow"]);
					cases.push(["read_absolute_inside", "read", { path: path.join(snapshot, request.probe_inside) }, "allow"]);
				}
				if (request.probe_inside_link) cases.push(["read_internal_symlink", "read", { path: request.probe_inside_link }, "allow"]);
				cases.push(
					["read_absolute_outside", "read", { path: request.probe_outside }, "deny"],
					["read_relative_escape", "read", { path: path.relative(snapshot, request.probe_outside) }, "deny"],
					["read_home", "read", { path: "~/.omp/agent/config.yml" }, "deny"],
					["read_url", "read", { path: "https://example.com/" }, "deny"],
					["read_file_url", "read", { path: `file://${request.probe_outside}` }, "deny"],
					["read_internal_uri", "read", { path: "memory://root" }, "deny"],
					["grep_outside", "grep", { pattern: secret, path: liveDir }, "deny"],
					["grep_glob_escape", "grep", { pattern: secret, glob: "../**" }, "deny"],
					["grep_all_no_outside_content", "grep", { pattern: secret }, "allow-clean"],
					["glob_outside", "glob", { pattern: "*", path: liveDir }, "deny"],
					["glob_pattern_escape", "glob", { pattern: "../**/*" }, "deny"],
					["glob_all_no_escape_entries", "glob", { pattern: "**/*" }, "allow-clean"],
				);
				if (request.probe_symlink_file) cases.push(["read_symlink_file_escape", "read", { path: request.probe_symlink_file }, "deny"]);
				if (request.probe_symlink_dir) cases.push(["read_symlink_dir_escape", "read", { path: request.probe_symlink_dir }, "deny"]);

				const confinement: Record<string, unknown> = {};
				for (const [label, toolName, params, expect] of cases) {
					const tool = session.getToolByName(toolName);
					if (!tool) {
						confinement[label] = { expect, pass: false, error: "tool missing" };
						problems.push(`${label}: session tool missing`);
						continue;
					}
					try {
						const result = await tool.execute(`probe-${label}`, params as never);
						const text = (result.content ?? []).map((part: { text?: string }) => part.text ?? "").join("\n");
						const leaked = text.includes(secret);
						const pass = expect === "deny" ? false : !leaked && (expect === "allow-clean" || text.length > 0);
						confinement[label] = { expect, pass, leaked, excerpt: text.slice(0, 180) };
						if (!pass) problems.push(`${label}: expected ${expect}`);
						if (leaked) problems.push(`${label}: outside content returned`);
					} catch (error) {
						const message = String(error instanceof Error ? error.message : error).slice(0, 300);
						const pass = expect === "deny" && !message.includes(secret);
						confinement[label] = { expect, pass, error: message };
						if (!pass) problems.push(`${label}: ${expect === "deny" ? "error leaked or was not a denial" : message}`);
					}
				}
				evidence.probe = confinement;
			}

			if (request.model && toolProblems.length === 0) {
				evidence.review_ran = true;
				const turns: ModelCallTurn[] = [];
				// The identity is captured before the request so a failed call
				// still names the model that actually ran, instead of falling
				// back to the requested name or to nothing.
				evidence.model = session.model ? `${session.model.provider}/${session.model.id}` : null;
				const sessionLabel = session.model ? `${session.model.provider}/${session.model.id}` : undefined;
				let receipts: ModelCallReceipt[] = [];
				// The keyless account identity of the credential row that served this
				// boundary, matched exactly from the SDK's own stored account list: no
				// network, no refresh, no oauth.access, no email or secret, and never
				// the first list item or the session pin.
				const accountIdentityFor = (message: unknown): AccountIdentity | undefined => {
					const credentialId = (message as { credentialId?: unknown })?.credentialId;
					const provider = (message as { provider?: unknown })?.provider;
					if (!Number.isInteger(credentialId) || typeof provider !== "string" || provider.length === 0) return undefined;
					try {
						const accounts = (session.modelRegistry as { authStorage?: { oauth?: { accounts?: (p: string) => unknown } } })
							?.authStorage?.oauth?.accounts?.(provider);
						return matchAccountIdentity(accounts, credentialId as number);
					} catch {
						return undefined;
					}
				};
				const syncUsage = () => {
					// Replayed turns must not grow the list: unkeyed receipts are
					// recomputed from the full turn log on every sync, so only
					// keyed receipts are carried as existing state. The
					// recomputation is deterministic, so an unkeyed row is
					// regenerated identically instead of appended again (frozen
					// SUT cae67791 check1: one response id appeared six times).
					const keyed = receipts.filter(receipt => receipt.call_id !== null);
					const report = syncCallReceipts(keyed, turns, request.model, accountIdentityFor);
					receipts = report.calls;
					evidence.usage = receipts.length > 0 ? receipts : null;
					evidence.usage_gaps = report.gaps;
				};
				syncReviewUsage = syncUsage;
				// The agent loop turns the first provider `start` of every response
				// into `message_start`, so that is the real call boundary: mint the
				// local invocation id there, persist its in-flight receipt, and reuse
				// the same id for that response's end or failure. The id is never
				// derived afterwards from time and never from the check attempt id.
				// SDK 18.3.4 clones the message for each event
				// (snapshotAssistantMessage, agent-loop.ts:398), so the end's object
				// is never the start's: pairing runs by stream order via
				// createCallBoundaryBinder, and an end without an open start keeps
				// call_id null and its gap rather than a manufactured id.
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
						persistEvidence();
						return;
					}
					turns.push({ call_id: boundaryBinder.bindEnd(), message });
					syncUsage();
					persistEvidence();
				});
				const prompt = readFileSync(request.prompt!, "utf8");
				await session.prompt(prompt);
				const last = [...session.messages].reverse().find(message => message.role === "assistant");
				const text = (last?.content ?? []).filter((part: { type: string }) => part.type === "text").map((part: { text: string }) => part.text).join("");
				// A mid-session provider failure arrives as an assistant turn with
				// stopReason "error" and the provider's own error fields (pi-ai
				// public surface). It fails the check before any contract parsing:
				// even a trailing contract-valid JSON in such a turn is leftover
				// content, never a verdict. raw_text, result and the usage
				// receipts/gaps are still recorded as-is below.
				const providerError = providerErrorFact(last);
				if (providerError) {
					evidence.error = { kind: providerError.kind, detail: providerError.detail };
					problems.push(`provider error: ${providerError.detail}`);
				}
				let result: unknown;
				let parseError: string | undefined;
				try {
					result = JSON.parse(text.trim());
				} catch (error) {
					parseError = error instanceof Error ? error.message : String(error);
				}
				if (result === undefined) {
					// Fail-closed recovery: only the complete JSON object at the
					// very end of the message is accepted, and only when it
					// validates; earlier balanced objects are prose. The prose
					// prefix stays visible in raw_text and is recorded as recovery
					// metadata — never as a problem, because evidence.ok must
					// reflect a usable verdict.
					const recovered = recoverTrailingJsonObject(text);
					if (recovered !== undefined && validateCheckResult(recovered).length === 0) {
						result = recovered;
						evidence.json_recovery = "trailing contract-valid JSON object; earlier objects are prose";
					}
				}
				const contractProblems = result === undefined
					? [`final message is not valid JSON${parseError ? `: ${parseError}` : ""}`]
					: validateCheckResult(result);
				problems.push(...contractProblems);
				evidence.raw_text = text;
				evidence.result = contractProblems.length === 0 ? result : null;
				evidence.contract_problems = contractProblems;
				if (!evidence.model) problems.push("session did not report an actual provider/model");
				else if (evidence.model !== request.model) problems.push(`model drift: requested ${request.model}, session resolved ${evidence.model}`);
			}
		} finally {
			// Receipts are kept on every path, including a failed or
			// contract-invalid run: a metered call is never reported as zero, a
			// call that never produced a result keeps its pending entry, and a
			// call the provider did not identify or meter is named in usage_gaps
			// instead of being invented.
			syncReviewUsage?.();
			await session.dispose();
		}
	}

	if (snapshot) {
		evidence.fingerprint_after = fingerprint(snapshot);
		if (evidence.fingerprint_before !== evidence.fingerprint_after) problems.push("snapshot fingerprint changed during the session");
	}
} catch (error) {
	const stack = error instanceof Error ? error.stack : undefined;
	problems.push(error instanceof Error ? error.message : String(error));
	evidence.diagnostic_stack = stack ?? null;
	if (error instanceof ReviewerFailure) {
		evidence.error = { kind: error.kind, detail: error.message };
	}
	if (stack) console.error(stack);
}

try {
	openAuthStorage?.close();
} catch {
	// Closing OMP's own store is best-effort; the process exits right after.
}

evidence.problems = problems;
evidence.ok = problems.length === 0;
if (request.out && (!request.snapshot || !within(path.resolve(request.snapshot), path.resolve(request.out)))) {
	writeFileSync(request.out, JSON.stringify(evidence, null, 2));
}
if (evidence.ok) exitCode = 0;
console.log(request.out ?? "");
process.exit(exitCode);
