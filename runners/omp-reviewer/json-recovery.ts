// Recover only a whole-message json fence or the existing prose-prefix form.
// A message containing fence markers owns the fence branch: a malformed or
// ambiguous envelope must never fall through to selecting an inner object.
// The caller still validates the candidate against the unchanged result schema.
export function recoverCheckResultJson(text: string): { value: unknown; description: string } | undefined {
	if (hasFenceOutsideJsonStrings(text)) {
		const match = /^```json\r?\n([\s\S]*)\r?\n```$/.exec(text.trim());
		if (!match || /^[ \t]*```/m.test(match[1])) return undefined;
		try {
			return { value: JSON.parse(match[1]), description: "single whole-message json fence; contract-valid JSON object" };
		} catch {
			return undefined;
		}
	}
	const value = recoverTrailingJsonObject(text);
	return value === undefined ? undefined : {
		value, description: "trailing contract-valid JSON object; earlier objects are prose",
	};
}

// Only distinguish JSON string contents from envelope markers. This is not
// Markdown parsing: the strict whole-message match above owns fence syntax.
function hasFenceOutsideJsonStrings(text: string): boolean {
	let depth = 0;
	let inString = false;
	let escaped = false;
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (inString) {
			if (escaped) escaped = false;
			else if (ch === "\\") escaped = true;
			else if (ch === '"') inString = false;
			continue;
		}
		if (text.startsWith("```", i)) return true;
		if (ch === "{" || ch === "[") depth++;
		else if (ch === "}" || ch === "]") depth = Math.max(0, depth - 1);
		else if (ch === '"' && depth > 0) inString = true;
	}
	return false;
}

// Recovery for checker final messages that prepend prose to the JSON result.
// Deliberately conservative: the WHOLE message must parse as JSON first; only
// when that fails do we accept the complete JSON object that ends at the very
// end of the text. Prose before it may contain brace examples (e.g. sample
// records); they are metadata, never the verdict. Fail-closed on: unbalanced
// braces, no balanced object, any non-whitespace after the trailing object, or
// a trailing object that does not parse; the caller additionally requires
// validateCheckResult to pass. No re-prompts, no schema coercion.
export function recoverTrailingJsonObject(text: string): unknown {
	const spans: { start: number; end: number }[] = [];
	let depth = 0;
	let start = -1;
	let inString = false;
	let escaped = false;
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (inString) {
			if (escaped) escaped = false;
			else if (ch === "\\") escaped = true;
			else if (ch === '"') inString = false;
			continue;
		}
		if (ch === '"') {
			inString = true;
			continue;
		}
		if (ch === "{") {
			if (depth === 0) start = i;
			depth++;
		} else if (ch === "}") {
			depth--;
			if (depth < 0) return undefined;
			if (depth === 0 && start !== -1) {
				spans.push({ start, end: i + 1 });
				start = -1;
			}
		}
	}
	if (depth !== 0 || spans.length === 0) return undefined; // unbalanced or no object
	const trailing = spans[spans.length - 1]; // earlier balanced objects are prose
	if (text.slice(trailing.end).trim() !== "") return undefined; // it must be at the very end
	try {
		return JSON.parse(text.slice(trailing.start, trailing.end));
	} catch {
		return undefined;
	}
}
