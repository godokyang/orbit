const VERDICTS = ["continue", "correct", "pause", "complete", "needs_user"];
const RESULT_KEYS = ["verdict", "reason", "findings", "resolved_ids", "next_check_seconds"];
const FINDING_KEYS = ["action", "evidence", "id", "requirement"];

// Contract validation for the final JSON object of an independent check run,
// mirroring contracts/check-result.schema.json (additionalProperties: false,
// non-empty strings, positive integer next_check_seconds).
export function validateCheckResult(value: unknown): string[] {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return ["check result must be a JSON object"];
	const record = value as Record<string, unknown>;
	const problems: string[] = [];
	const keys = Object.keys(record);
	const extra = keys.filter(key => !RESULT_KEYS.includes(key));
	const missing = RESULT_KEYS.filter(key => !keys.includes(key));
	if (extra.length) problems.push(`unexpected keys: ${extra.join(", ")}`);
	if (missing.length) problems.push(`missing keys: ${missing.join(", ")}`);
	if (!VERDICTS.includes(record.verdict as string)) problems.push(`verdict must be one of: ${VERDICTS.join(", ")}`);
	if (typeof record.reason !== "string" || record.reason === "") problems.push("reason must be a non-empty string");
	if (!Array.isArray(record.findings)) {
		problems.push("findings must be an array");
	} else {
		record.findings.forEach((finding, index) => {
			const ok = typeof finding === "object" && finding !== null && Object.keys(finding).sort().join() === FINDING_KEYS.join();
			if (!ok) return problems.push(`findings[${index}] must be an object with exactly: ${FINDING_KEYS.join(", ")}`);
			for (const key of FINDING_KEYS) {
				const field = (finding as Record<string, unknown>)[key];
				if (typeof field !== "string" || field === "") problems.push(`findings[${index}].${key} must be a non-empty string`);
			}
		});
	}
	if (!Array.isArray(record.resolved_ids) || !record.resolved_ids.every(id => typeof id === "string" && id !== "")) {
		problems.push("resolved_ids must be an array of non-empty strings");
	}
	if (!Number.isInteger(record.next_check_seconds) || (record.next_check_seconds as number) <= 0) {
		problems.push("next_check_seconds must be a positive integer");
	}
	return problems;
}
