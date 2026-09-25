// Production entry for one independent OMP reviewer/adjudicator session.
//
//   bun reviewer.ts --config request.json
//   bun reviewer.ts --snapshot DIR --profile DIR --out FILE [--prompt FILE] [--model provider/id]
//
// The profile must be a fresh directory and PI_CODING_AGENT_DIR must equal it.
// OMP_PROFILE must be unset. Credentials, when a model is requested, stay in
// memory. Without --model this process does not call a model; a confinement
// probe is not a check result.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { lstatSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import path from "node:path";
import { recoverTrailingJsonObject } from "./json-recovery";
import { parseProbeModels, probeModelAvailability } from "./model-probe";
import { validateCheckResult } from "./check-result";
import {
	AgentRegistry,
	createAgentSession,
	discoverAuthStorage,
	ModelRegistry,
	SessionManager,
	Settings,
} from "@oh-my-pi/pi-coding-agent";
import { createConfinedTools } from "./confined-tools.ts";

const PINNED_SDK = "18.2.8";
const REVIEW_TOOLS = ["read", "grep", "glob"];
const FORBIDDEN_TOOLS = ["write", "edit", "bash", "eval", "task", "hub", "todo", "ask", "web_search", "browser", "lsp", "ast_edit", "notebook", "checkpoint", "rewind", "goal", "manage_skill", "learn"];

type Request = {
	snapshot?: string;
	profile?: string;
	out?: string;
	prompt?: string;
	model?: string;
	token_provider?: string;
	probe_models?: string;
	probe_outside?: string;
	probe_inside?: string;
	probe_inside_link?: string;
	probe_symlink_file?: string;
	probe_symlink_dir?: string;
	probe_secret?: string;
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
		token_provider: arg("token-provider"),
		probe_models: arg("probe-models"),
		probe_outside: arg("probe-outside"),
		probe_inside: arg("probe-inside"),
		probe_inside_link: arg("probe-inside-link"),
		probe_symlink_file: arg("probe-symlink-file"),
		probe_symlink_dir: arg("probe-symlink-dir"),
		probe_secret: arg("probe-secret"),
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

// Availability-only credential resolver for the model probe. It runs OMP's own
// provider token command with the user's ambient environment (the isolated
// profile dir is removed), caches the result per provider, and returns only a
// boolean plus a structured reason. The resolved token is read to test
// presence and immediately discarded — it is never returned or written.
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

function credentialResolver(): (provider: string) => { ok: boolean; reason?: string } {
	const cache = new Map<string, { ok: boolean; reason?: string }>();
	const { PI_CODING_AGENT_DIR: _profile, ...userEnv } = process.env;
	return provider => {
		const cached = cache.get(provider);
		if (cached) return cached;
		let result: { ok: boolean; reason?: string };
		try {
			const token = execFileSync("omp", ["token", provider], { encoding: "utf8", env: userEnv }).trim();
			result = token ? { ok: true } : { ok: false, reason: `no credential for ${provider}` };
		} catch {
			result = { ok: false, reason: `credential resolution failed for ${provider}` };
		}
		cache.set(provider, result);
		return result;
	};
}

const request = loadRequest();
const problems: string[] = [];
const evidence: Record<string, unknown> = {
	ok: false,
	review_ran: false,
	probe_ran: false,
	result: null,
	model: null,
	usage: null,
};
let exitCode = 1;

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
	if (process.env.PI_CODING_AGENT_DIR !== profile || process.env.OMP_PROFILE) {
		throw new Error("run with PI_CODING_AGENT_DIR=<profile> and without OMP_PROFILE");
	}
	if (snapshot && (within(snapshot, out) || within(snapshot, profile))) throw new Error("profile and out must stay outside the snapshot");
	const version = sdkVersion();
	evidence.sdk_version = version;
	if (version !== PINNED_SDK) throw new Error(`SDK ${version} is not the pinned ${PINNED_SDK}`);
	const modeCount = [request.model, request.probe_outside, probeMode].filter(Boolean).length;
	if (modeCount === 0) throw new Error("pass --model for a check, a confinement probe, or --probe-models; none is a pass by itself");
	if (modeCount > 1) throw new Error("use exactly one of --model, --probe-outside, or --probe-models");
	if (probeMode && probeSpecs.length === 0) throw new Error("--probe-models requires at least one provider/id");

	if (snapshot) evidence.fingerprint_before = fingerprint(snapshot);
	const authStorage = await discoverAuthStorage(profile);
	const modelRegistry = new ModelRegistry(authStorage);
	let model;
	if (request.model) {
		if (!request.prompt) throw new Error("model requires a prompt file");
		const [provider, ...rest] = request.model.split("/");
		const id = rest.join("/");
		if (!provider || !id) throw new Error("model must be provider/id");
		model = modelRegistry.find(provider, id);
		if (!model) throw new ReviewerFailure(`model not in catalog: ${request.model}`, "unavailable");
		const { PI_CODING_AGENT_DIR: _profile, ...userEnv } = process.env;
		const key = execFileSync("omp", ["token", request.token_provider ?? provider], { encoding: "utf8", env: userEnv }).trim();
		if (!key) throw new ReviewerFailure(`no credential for ${request.token_provider ?? provider}`, "auth_or_quota");
		authStorage.setRuntimeApiKey(provider, key);
	}

	if (probeMode) {
		evidence.probe_models = probeModelAvailability(
			probeSpecs,
			(provider, id) => modelRegistry.find(provider, id) !== undefined,
			credentialResolver(),
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
				const usage: unknown[] = [];
				session.subscribe(event => {
					if (event.type === "message_end" && event.message.role === "assistant") usage.push(event.message.usage);
				});
				const prompt = readFileSync(request.prompt!, "utf8");
				await session.prompt(prompt);
				const last = [...session.messages].reverse().find(message => message.role === "assistant");
				const text = (last?.content ?? []).filter((part: { type: string }) => part.type === "text").map((part: { text: string }) => part.text).join("");
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
				evidence.model = session.model ? `${session.model.provider}/${session.model.id}` : null;
				evidence.usage = usage;
				evidence.raw_text = text;
				evidence.result = contractProblems.length === 0 ? result : null;
				evidence.contract_problems = contractProblems;
				if (!evidence.model) problems.push("session did not report an actual provider/model");
			}
		} finally {
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

evidence.problems = problems;
evidence.ok = problems.length === 0;
if (request.out && (!request.snapshot || !within(path.resolve(request.snapshot), path.resolve(request.out)))) {
	writeFileSync(request.out, JSON.stringify(evidence, null, 2));
}
if (evidence.ok) exitCode = 0;
console.log(request.out ?? "");
process.exit(exitCode);
