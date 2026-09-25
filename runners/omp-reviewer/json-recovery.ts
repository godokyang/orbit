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
