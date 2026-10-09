// read/grep/glob confined to one snapshot root, registered as SDK custom tools
// that replace the same-named built-ins in a restricted session. They never
// delegate to the native tools, so native URL, internal-URI, multi-path and
// absolute-path handling is unreachable.
import { createHash } from "node:crypto";
import { lstatSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "@oh-my-pi/pi-coding-agent";

const MAX_READ_LINES = 2000;
const MAX_FILE_BYTES = 1_000_000;
// Bounded like the text cap: a delivered image travels base64-encoded in the
// tool result, so an unbounded screenshot would dominate the reviewer context.
const MAX_IMAGE_BYTES = 4_000_000;
const MAX_RESULTS = 300;

export class OutsideSnapshotError extends Error {}

/** Traceable fact about one snapshot image this reviewer process actually read. */
export type SnapshotImageRead = {
	path: string;
	bytes: number;
	sha256: string;
	mime_type: string;
	/** The calling model's declared image input; null when the SDK gave no model. */
	model_image_input: boolean | null;
};

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// Sniffed from the bytes, never from the file name: an extension is not
// evidence that the bytes are an image, and neither is evidence that a model
// received the pixels.
function imageMime(bytes: Buffer): string | undefined {
	if (bytes.length >= 8 && bytes.subarray(0, 8).equals(PNG_MAGIC)) return "image/png";
	if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
	const magic = bytes.subarray(0, 12).toString("latin1");
	if (bytes.length >= 6 && (magic.startsWith("GIF87a") || magic.startsWith("GIF89a"))) return "image/gif";
	if (bytes.length >= 12 && magic.startsWith("RIFF") && magic.slice(8, 12) === "WEBP") return "image/webp";
	return undefined;
}

function text(value: string, details: Record<string, unknown>) {
	return { content: [{ type: "text" as const, text: value }], details: { confined: true, ...details } };
}

function within(root: string, candidate: string): boolean {
	const relative = path.relative(root, candidate);
	return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

export function createConfinedTools(snapshotRoot: string, options: {
  onImageRead?: (fact: SnapshotImageRead) => void;
  inputModalities?: () => readonly string[] | undefined;
} = {}) {
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
			"Read a text file, or list a directory, inside the fixed review snapshot. File results report exact byte length, final line ending and actual text lines; a terminal LF does not create an extra empty line. An image file (sniffed from its bytes, not its name) returns the picture itself together with its snapshot path, byte count and sha256. Paths are relative to the snapshot root; URLs, internal URIs and paths outside the snapshot are rejected.",
		parameters: z.object({
			path: z.string(),
			offset: z.number().optional(),
			limit: z.number().optional(),
		}),
		async execute(
			_id: string,
			params: { path: string; offset?: number; limit?: number },
			_onUpdate?: unknown,
			ctx?: { model?: { input?: readonly string[] } },
		) {
			const target = resolveInside(params.path);
			const stat = statSync(target);
			if (stat.isDirectory()) {
				const names = readdirSync(target)
					.filter(name => name !== ".git")
					.sort()
					.map(name => (lstatSync(path.join(target, name)).isDirectory() ? `${name}/` : name));
				return text(names.join("\n"), { path: path.relative(root, target) || "." });
			}
			if (stat.size > MAX_IMAGE_BYTES) throw new Error(`file too large to read: ${params.path}`);
			const bytes = readFileSync(target);
			const mime = imageMime(bytes);
			if (mime) {
				const snapshotPath = path.relative(root, target);
				const sha256 = createHash("sha256").update(bytes).digest("hex");
				const modalities = ctx?.model?.input ?? options.inputModalities?.();
				const modelImageInput = modalities === undefined ? null : modalities.includes("image");
				options.onImageRead?.({ path: snapshotPath, bytes: stat.size, sha256, mime_type: mime, model_image_input: modelImageInput });
				const header = `[image=${snapshotPath}; mime=${mime}; bytes=${stat.size}; sha256=${sha256}]`;
				const refusal =
					modelImageInput === false
						? "\nThe selected model declares no image input, so these pixels were not delivered. Visual verification of this image stays unverified."
						: "";
				return {
					content: [
						{ type: "image" as const, data: bytes.toString("base64"), mimeType: mime },
						{ type: "text" as const, text: `${header}${refusal}` },
					],
					details: { confined: true, path: snapshotPath, bytes: stat.size, sha256, mime_type: mime, image: true },
				};
			}
			if (stat.size > MAX_FILE_BYTES) throw new Error(`file too large to read: ${params.path}`);
			const content = bytes.toString("utf8");
			const lines = content.length === 0 ? [] : content.split("\n");
			if (content.endsWith("\n")) lines.pop();
			const start = Math.max(1, Math.floor(params.offset ?? 1));
			const limit = Math.min(MAX_READ_LINES, Math.max(1, Math.floor(params.limit ?? MAX_READ_LINES)));
			const slice = lines.slice(start - 1, start - 1 + limit).map((line, index) => `${start + index}|${line}`);
			const finalNewline = content.endsWith("\r\n") ? "CRLF" : content.endsWith("\n") ? "LF" : "none";
			return text([`[bytes=${stat.size}; final_newline=${finalNewline}; actual_lines=${lines.length}]`, ...slice].join("\n"),
				{ path: path.relative(root, target), lines: lines.length, bytes: stat.size, final_newline: finalNewline });
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
				const content = readFileSync(file.abs, "utf8");
				const lines = content.length === 0 ? [] : content.split("\n");
				if (content.endsWith("\n")) lines.pop();
				lines.forEach((line, index) => {
					if (hits.length < MAX_RESULTS && regex.test(line)) hits.push(`${file.rel}:${index + 1}: ${line}`);
				});
			}
			return text(hits.join("\n") || "(no matches)", { count: hits.length });
		},
	};

	return [read, grep, glob];
}
