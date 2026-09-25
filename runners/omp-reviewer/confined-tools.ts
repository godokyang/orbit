// read/grep/glob confined to one snapshot root, registered as SDK custom tools
// that replace the same-named built-ins in a restricted session. They never
// delegate to the native tools, so native URL, internal-URI, multi-path and
// absolute-path handling is unreachable.
import { lstatSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "@oh-my-pi/pi-coding-agent";

const MAX_READ_LINES = 2000;
const MAX_FILE_BYTES = 1_000_000;
const MAX_RESULTS = 300;

export class OutsideSnapshotError extends Error {}

function text(value: string, details: Record<string, unknown>) {
	return { content: [{ type: "text" as const, text: value }], details: { confined: true, ...details } };
}

function within(root: string, candidate: string): boolean {
	const relative = path.relative(root, candidate);
	return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

export function createConfinedTools(snapshotRoot: string) {
	const root = realpathSync(snapshotRoot);
	const lexicalRoots = [...new Set([path.resolve(snapshotRoot), root])];

	function resolveInside(requested: string | undefined): string {
		const value = requested === undefined || requested === "" ? "." : requested;
		if (value.includes("\0") || value.startsWith("~") || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) {
			throw new OutsideSnapshotError(`path is not a snapshot path: ${value}`);
		}
		const lexical = path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
		if (!lexicalRoots.some(base => within(base, lexical))) {
			throw new OutsideSnapshotError(`path is outside the snapshot: ${value}`);
		}
		let real: string;
		try {
			real = realpathSync(lexical);
		} catch {
			throw new Error(`path does not exist in the snapshot: ${value}`);
		}
		if (!within(root, real)) throw new OutsideSnapshotError(`path resolves outside the snapshot: ${value}`);
		return real;
	}

	// Yields files under `base` without descending into symlinked directories;
	// symlinked files are kept only when their real target stays inside root.
	function* walk(base: string): Generator<{ rel: string; abs: string }> {
		const stat = statSync(base);
		if (stat.isFile()) {
			yield { rel: path.relative(root, base), abs: base };
			return;
		}
		const stack = [base];
		while (stack.length > 0) {
			const dir = stack.pop()!;
			for (const name of readdirSync(dir).sort()) {
				if (name === ".git") continue;
				const abs = path.join(dir, name);
				const entry = lstatSync(abs);
				if (entry.isDirectory()) {
					stack.push(abs);
				} else if (entry.isFile()) {
					yield { rel: path.relative(root, abs), abs };
				} else if (entry.isSymbolicLink()) {
					let real: string;
					try {
						real = realpathSync(abs);
					} catch {
						continue;
					}
					if (within(root, real) && statSync(real).isFile()) yield { rel: path.relative(root, abs), abs: real };
				}
			}
		}
	}

	function checkPattern(pattern: string) {
		if (path.isAbsolute(pattern) || pattern.split(/[\\/]/).includes("..") || pattern.startsWith("~")) {
			throw new OutsideSnapshotError(`glob pattern must stay inside the snapshot: ${pattern}`);
		}
	}

	const read = {
		name: "read",
		label: "Read (snapshot)",
		description:
			"Read a text file, or list a directory, inside the fixed review snapshot. Paths are relative to the snapshot root; URLs, internal URIs and paths outside the snapshot are rejected.",
		parameters: z.object({
			path: z.string(),
			offset: z.number().optional(),
			limit: z.number().optional(),
		}),
		async execute(_id: string, params: { path: string; offset?: number; limit?: number }) {
			const target = resolveInside(params.path);
			const stat = statSync(target);
			if (stat.isDirectory()) {
				const names = readdirSync(target)
					.filter(name => name !== ".git")
					.sort()
					.map(name => (lstatSync(path.join(target, name)).isDirectory() ? `${name}/` : name));
				return text(names.join("\n"), { path: path.relative(root, target) || "." });
			}
			if (stat.size > MAX_FILE_BYTES) throw new Error(`file too large to read: ${params.path}`);
			const lines = readFileSync(target, "utf8").split("\n");
			const start = Math.max(1, Math.floor(params.offset ?? 1));
			const limit = Math.min(MAX_READ_LINES, Math.max(1, Math.floor(params.limit ?? MAX_READ_LINES)));
			const slice = lines.slice(start - 1, start - 1 + limit).map((line, index) => `${start + index}|${line}`);
			return text(slice.join("\n"), { path: path.relative(root, target), lines: lines.length });
		},
	};

	const glob = {
		name: "glob",
		label: "Glob (snapshot)",
		description: "List snapshot files whose snapshot-relative path matches a glob pattern such as `**/*.js`.",
		parameters: z.object({ pattern: z.string(), path: z.string().optional() }),
		async execute(_id: string, params: { pattern: string; path?: string }) {
			checkPattern(params.pattern);
			const base = resolveInside(params.path);
			const matcher = new Bun.Glob(params.pattern);
			const hits: string[] = [];
			for (const file of walk(base)) {
				if (matcher.match(path.relative(base, path.join(root, file.rel)))) hits.push(file.rel);
				if (hits.length >= MAX_RESULTS) break;
			}
			return text(hits.join("\n") || "(no matches)", { count: hits.length });
		},
	};

	const grep = {
		name: "grep",
		label: "Grep (snapshot)",
		description: "Search snapshot files for a regular expression; prints `path:line: text`.",
		parameters: z.object({
			pattern: z.string(),
			path: z.string().optional(),
			glob: z.string().optional(),
			ignore_case: z.boolean().optional(),
		}),
		async execute(_id: string, params: { pattern: string; path?: string; glob?: string; ignore_case?: boolean }) {
			if (params.glob) checkPattern(params.glob);
			const base = resolveInside(params.path);
			const regex = new RegExp(params.pattern, params.ignore_case ? "i" : "");
			const filter = params.glob ? new Bun.Glob(params.glob) : undefined;
			const hits: string[] = [];
			for (const file of walk(base)) {
				if (filter && !filter.match(file.rel)) continue;
				if (statSync(file.abs).size > MAX_FILE_BYTES) continue;
				const lines = readFileSync(file.abs, "utf8").split("\n");
				lines.forEach((line, index) => {
					if (hits.length < MAX_RESULTS && regex.test(line)) hits.push(`${file.rel}:${index + 1}: ${line}`);
				});
				if (hits.length >= MAX_RESULTS) break;
			}
			return text(hits.join("\n") || "(no matches)", { count: hits.length });
		},
	};

	return [read, grep, glob];
}
