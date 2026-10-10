import { readFileSync } from "node:fs";

// contracts/check-result.schema.json is the single structural source: every
// enforced key list, enum, bound, boolean flag and closed-object rule below is
// derived from it (lib/orbit/check_runner.rb derives the same structure on the
// Ruby side). The current schema does not encode every semantic gate the
// contract keeps — non-empty strings, positive integer, trimmed and unique coverage
// requirements, verified⇒evidence, the delivery-only scope default — so those
// stay explicit here. Loading fails closed on a missing or foreign schema file.
const SCHEMA_ID = "https://orbit.local/contracts/check-result.schema.json";
const SCHEMA_URL = new URL("../../contracts/check-result.schema.json", import.meta.url);

export function loadCheckResultSchema(path: URL = SCHEMA_URL): Record<string, any> {
	let schema: unknown;
	try {
		schema = JSON.parse(readFileSync(path, "utf8"));
	} catch (error) {
		throw new Error(`check-result schema is unreadable: ${error}`);
	}
	const record = schema as Record<string, unknown> | null;
	if (typeof schema !== "object" || schema === null || record!.$id !== SCHEMA_ID) {
		throw new Error(`check-result schema identity mismatch: ${String(record?.$id)}`);
	}
	return record as Record<string, any>;
}

// The structural facts the validator enforces, derived from a schema document.
// Allowed keys come from properties, the mandatory subset from required, and a
// closed object from additionalProperties === false — never from each other.
export interface CheckResultStructure {
	verdicts: string[];
	resultProperties: string[];
	resultRequired: string[];
	resultClosed: boolean;
	findingProperties: string[];
	findingRequired: string[];
	findingClosed: boolean;
	deliveryProperties: string[];
	deliveryRequired: string[];
	deliveryClosed: boolean;
	booleanProperties: string[];
	coverageProperties: string[];
	coverageRequired: string[];
	coverageClosed: boolean;
	coverageItemProperties: string[];
	coverageItemRequired: string[];
	coverageItemClosed: boolean;
	coverageItemsMin: number;
	coverageItemsMax: number;
	coverageRequirementMax: number;
	coverageEvidenceMax: number;
	coverageStatuses: string[];
	coverageScopes: string[];
}

export function deriveCheckResultStructure(schema: Record<string, any>): CheckResultStructure {
	if (typeof schema !== "object" || schema === null || schema.$id !== SCHEMA_ID) {
		throw new Error(`check-result schema identity mismatch: ${String(schema?.$id)}`);
	}
	const properties = schema.properties ?? {};
	const findingsItem = properties.findings?.items ?? {};
	const delivery = properties.delivery ?? {};
	const coverage = properties.coverage ?? {};
	const coverageProperties = coverage.properties ?? {};
	const itemsSpec = coverageProperties.items ?? {};
	const coverageItem = itemsSpec.items ?? {};
	const itemProperties = coverageItem.properties ?? {};
	const structure: CheckResultStructure = {
		verdicts: properties.verdict?.enum,
		resultProperties: Object.keys(properties),
		resultRequired: schema.required,
		resultClosed: schema.additionalProperties === false,
		findingProperties: Object.keys(findingsItem.properties ?? {}),
		findingRequired: findingsItem.required ?? [],
		findingClosed: findingsItem.additionalProperties === false,
		deliveryProperties: Object.keys(delivery.properties ?? {}),
		deliveryRequired: delivery.required ?? [],
		deliveryClosed: delivery.additionalProperties === false,
		booleanProperties: [
			["delivery.ready", delivery.properties?.ready],
			["coverage.complete", coverageProperties.complete],
		].filter(([, node]) => node?.type === "boolean").map(([name]) => name),
		coverageProperties: Object.keys(coverageProperties),
		coverageRequired: coverage.required ?? [],
		coverageClosed: coverage.additionalProperties === false,
		coverageItemProperties: Object.keys(itemProperties),
		coverageItemRequired: [...(coverageItem.required ?? [])].sort(),
		coverageItemClosed: coverageItem.additionalProperties === false,
		coverageItemsMin: itemsSpec.minItems,
		coverageItemsMax: itemsSpec.maxItems,
		coverageRequirementMax: itemProperties.requirement?.maxLength,
		coverageEvidenceMax: itemProperties.evidence?.maxLength,
		coverageStatuses: itemProperties.status?.enum,
		coverageScopes: itemProperties.scope?.enum,
	};
	const missing = Object.entries(structure).filter(([, value]) => value === undefined).map(([key]) => key);
	if (missing.length) throw new Error(`check-result schema is missing structural facts: ${missing.join(", ")}`);
	return structure;
}

const STRUCTURE = deriveCheckResultStructure(loadCheckResultSchema());

// JSON Schema maxLength counts Unicode code points and
// Ruby String#length agrees; String#length here counts UTF-16 code units, so
// non-BMP requirement text would fail on this side alone without this unit.
function codePointLength(text: string): number {
	return [...text].length;
}

export function validateCheckResult(value: unknown): string[] {
	return checkResultProblems(STRUCTURE, value);
}

// Structure (key lists, enums, bounds, boolean flags, closed-object rules)
// comes from the passed-in structure derived from
// contracts/check-result.schema.json; what remains here are the semantic
// gates not encoded in the current schema.
export function checkResultProblems(structure: CheckResultStructure, value: unknown): string[] {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return ["check result must be a JSON object"];
	const record = value as Record<string, unknown>;
	const problems: string[] = [];
	const keys = Object.keys(record);
	const extra = structure.resultClosed ? keys.filter(key => !structure.resultProperties.includes(key)) : [];
	const missing = structure.resultRequired.filter(key => !keys.includes(key));
	if (extra.length) problems.push(`unexpected keys: ${extra.join(", ")}`);
	if (missing.length) problems.push(`missing keys: ${missing.join(", ")}`);
	if (!structure.verdicts.includes(record.verdict as string)) problems.push(`verdict must be one of: ${structure.verdicts.join(", ")}`);
	if (typeof record.reason !== "string" || record.reason === "") problems.push("reason must be a non-empty string");
	if (!Array.isArray(record.findings)) {
		problems.push("findings must be an array");
	} else {
		record.findings.forEach((finding, index) => {
			const isObject = typeof finding === "object" && finding !== null && !Array.isArray(finding);
			const findingKeys = isObject ? Object.keys(finding) : [];
			const findingExtra = structure.findingClosed ? findingKeys.filter(key => !structure.findingProperties.includes(key)) : [];
			const findingMissing = structure.findingRequired.filter(key => !findingKeys.includes(key));
			if (!isObject || findingExtra.length || findingMissing.length) {
				return problems.push(`findings[${index}] must be an object with exactly: ${structure.findingProperties.join(", ")}`);
			}
			for (const key of structure.findingRequired) {
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
		problems.push(`delivery must be an object with exactly: ${structure.deliveryRequired.join(", ")}`);
	} else {
		const deliveryRecord = delivery as Record<string, unknown>;
		const deliveryKeys = Object.keys(delivery);
		if (structure.deliveryClosed) {
			const deliveryExtra = deliveryKeys.filter(key => !structure.deliveryProperties.includes(key));
			if (deliveryExtra.length) problems.push(`delivery has unexpected keys: ${deliveryExtra.join(", ")}`);
		}
		const deliveryMissing = structure.deliveryRequired.filter(key => !deliveryKeys.includes(key));
		if (deliveryMissing.length) problems.push(`delivery is missing keys: ${deliveryMissing.join(", ")}`);
		if (structure.booleanProperties.includes("delivery.ready") && typeof deliveryRecord.ready !== "boolean") {
			problems.push("delivery.ready must be a boolean");
		}
		if (typeof deliveryRecord.reason !== "string" || deliveryRecord.reason === "") problems.push("delivery.reason must be a non-empty string");
	}
	if (keys.includes("coverage")) problems.push(...coverageProblems(structure, record.coverage));
	return problems;
}

function coverageProblems(structure: CheckResultStructure, coverage: unknown): string[] {
	if (typeof coverage !== "object" || coverage === null || Array.isArray(coverage)) {
		return [`coverage must contain exactly ${structure.coverageRequired.join(" and ")}`];
	}
	const problems: string[] = [];
	const c = coverage as Record<string, unknown>;
	const coverageKeys = Object.keys(c);
	if (structure.coverageClosed) {
		const extra = coverageKeys.filter(key => !structure.coverageProperties.includes(key));
		const missing = structure.coverageRequired.filter(key => !coverageKeys.includes(key));
		if (extra.length || missing.length) return [`coverage must contain exactly ${structure.coverageRequired.join(" and ")}`];
	} else {
		const missing = structure.coverageRequired.filter(key => !coverageKeys.includes(key));
		if (missing.length) problems.push(`coverage is missing keys: ${missing.join(", ")}`);
	}
	if (structure.booleanProperties.includes("coverage.complete") && typeof c.complete !== "boolean") {
		problems.push("coverage.complete must be a boolean");
	}
	if (!Array.isArray(c.items) || c.items.length < structure.coverageItemsMin || c.items.length > structure.coverageItemsMax) {
		return [...problems, `coverage.items must contain ${structure.coverageItemsMin}..${structure.coverageItemsMax} entries`];
	}
	const seen = new Set<string>();
	for (const item of c.items) {
		const isObject = typeof item === "object" && item !== null && !Array.isArray(item);
		const itemKeys = isObject ? Object.keys(item) : [];
		const itemExtra = structure.coverageItemClosed ? itemKeys.filter(key => !structure.coverageItemProperties.includes(key)) : [];
		const itemMissing = structure.coverageItemRequired.filter(key => !itemKeys.includes(key));
		if (!isObject || itemExtra.length || itemMissing.length) {
			problems.push("each coverage item must contain requirement, status, evidence and optional scope");
			continue;
		}
		const entry = item as Record<string, unknown>;
		const requirement = entry.requirement;
		// A missing scope keeps the delivery-only interpretation: that default
		// is a semantic decision, not part of the derived structure.
		if (!structure.coverageScopes.includes(entry.scope === undefined ? "delivery" : entry.scope)) {
			problems.push(`coverage scope must be ${structure.coverageScopes.join(" or ")}`);
		}
		if (typeof requirement !== "string" || !requirement.trim() || codePointLength(requirement) > structure.coverageRequirementMax) {
			problems.push(`coverage requirement must be a non-empty string of at most ${structure.coverageRequirementMax} characters`);
		} else {
			if (seen.has(requirement.trim())) problems.push("coverage contains duplicate requirements");
			seen.add(requirement.trim());
		}
		if (!structure.coverageStatuses.includes(entry.status)) problems.push(`coverage status must be ${structure.coverageStatuses.join(" or ")}`);
		if (typeof entry.evidence !== "string" || codePointLength(entry.evidence) > structure.coverageEvidenceMax ||
			(entry.status === "verified" && !entry.evidence.trim())) problems.push("coverage evidence must fit its status and bound");
	}
	return problems;
}
