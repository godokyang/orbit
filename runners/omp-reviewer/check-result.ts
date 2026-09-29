const VERDICTS = ["continue", "correct", "pause", "complete", "needs_user"];
const RESULT_KEYS = ["verdict", "reason", "findings", "resolved_ids", "next_check_seconds", "delivery"];
const OPTIONAL_RESULT_KEYS = ["coverage"];
const FINDING_KEYS = ["action", "evidence", "id", "requirement"];
const DELIVERY_KEYS = ["ready", "reason"];

// Contract validation for the final JSON object of an independent check run,
// mirroring contracts/check-result.schema.json (additionalProperties: false,
// non-empty strings, positive integer next_check_seconds, and the required
// structured delivery judgment: exactly ready (boolean) + reason (non-empty
// string), separate from verdict and findings).
export function validateCheckResult(value: unknown): string[] {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return ["check result must be a JSON object"];
	const record = value as Record<string, unknown>;
	const problems: string[] = [];
	const keys = Object.keys(record);
	const extra = keys.filter(key => !RESULT_KEYS.includes(key) && !OPTIONAL_RESULT_KEYS.includes(key));
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
	const delivery = record.delivery;
	if (typeof delivery !== "object" || delivery === null || Array.isArray(delivery)) {
		problems.push(`delivery must be an object with exactly: ${DELIVERY_KEYS.join(", ")}`);
	} else {
		const deliveryKeys = Object.keys(delivery);
		const deliveryExtra = deliveryKeys.filter(key => !DELIVERY_KEYS.includes(key));
		const deliveryMissing = DELIVERY_KEYS.filter(key => !deliveryKeys.includes(key));
		if (deliveryExtra.length) problems.push(`delivery has unexpected keys: ${deliveryExtra.join(", ")}`);
		if (deliveryMissing.length) problems.push(`delivery is missing keys: ${deliveryMissing.join(", ")}`);
		if (typeof (delivery as Record<string, unknown>).ready !== "boolean") problems.push("delivery.ready must be a boolean");
		const reason = (delivery as Record<string, unknown>).reason;
		if (typeof reason !== "string" || reason === "") problems.push("delivery.reason must be a non-empty string");
	}
	if (keys.includes("coverage")) {
		const coverage = record.coverage;
		if (typeof coverage !== "object" || coverage === null || Array.isArray(coverage) ||
			Object.keys(coverage).sort().join() !== "complete,items") {
			problems.push("coverage must contain exactly complete and items");
		} else {
			const c = coverage as Record<string, unknown>;
			if (typeof c.complete !== "boolean") problems.push("coverage.complete must be a boolean");
			if (!Array.isArray(c.items) || c.items.length < 1 || c.items.length > 64) {
				problems.push("coverage.items must contain 1..64 entries");
			} else {
				const seen = new Set<string>();
				for (const item of c.items) {
					if (typeof item !== "object" || item === null || Array.isArray(item) ||
						Object.keys(item).sort().join() !== "evidence,requirement,status") {
						problems.push("each coverage item must contain exactly requirement, status and evidence");
						continue;
					}
					const requirement = item.requirement;
					if (typeof requirement !== "string" || !requirement.trim() || requirement.length > 300) {
						problems.push("coverage requirement must be a non-empty string of at most 300 characters");
					} else {
						if (seen.has(requirement.trim())) problems.push("coverage contains duplicate requirements");
						seen.add(requirement.trim());
					}
					if (!["verified", "unverified"].includes(item.status)) problems.push("coverage status must be verified or unverified");
					if (typeof item.evidence !== "string" || item.evidence.length > 1000 ||
						(item.status === "verified" && !item.evidence.trim())) problems.push("coverage evidence must fit its status and bound");
				}
			}
		}
	}
	return problems;
}
