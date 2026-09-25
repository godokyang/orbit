// Pure availability computation for the independent checker's model probe.
//
// The probe answers one question without a model request: for each candidate
// `provider/id`, can the reviewer's isolated profile (a) find the model in its
// catalog and (b) resolve a provider credential? Credentials are never
// returned or stored: the resolver reports availability only, so no token can
// leak into the evidence file or the caller.

export type CredentialAvailability = { ok: boolean; reason?: string };

export type ModelProbeAvailability = {
	resolvable: string[];
	unresolvable: Array<{ model: string; reason: string }>;
};

/** Split a comma-separated `provider/id` list; blank entries are dropped. */
export function parseProbeModels(value: string | undefined): string[] {
	if (!value) return [];
	return value
		.split(",")
		.map(part => part.trim())
		.filter(part => part.length > 0);
}

/**
 * Classify each candidate against the isolated catalog and credential
 * resolver. `resolveCredential` is called at most once per provider; its
 * return value carries an availability boolean, never a token. Duplicate
 * candidates are reported once, in first-seen order.
 */
export function probeModelAvailability(
	specs: readonly string[],
	findModel: (provider: string, id: string) => boolean,
	resolveCredential: (provider: string) => CredentialAvailability,
): ModelProbeAvailability {
	const seen = new Set<string>();
	const credentials = new Map<string, CredentialAvailability>();
	const resolvable: string[] = [];
	const unresolvable: Array<{ model: string; reason: string }> = [];
	for (const raw of specs) {
		const spec = raw.trim();
		if (!spec || seen.has(spec)) continue;
		seen.add(spec);
		const [provider, ...rest] = spec.split("/");
		const id = rest.join("/");
		if (!provider || !id) {
			unresolvable.push({ model: spec, reason: "model must be provider/id" });
			continue;
		}
		const model = `${provider}/${id}`;
		if (!findModel(provider, id)) {
			unresolvable.push({ model, reason: "model not in isolated catalog" });
			continue;
		}
		let credential = credentials.get(provider);
		if (!credential) {
			credential = resolveCredential(provider);
			credentials.set(provider, credential);
		}
		if (credential.ok) resolvable.push(model);
		else unresolvable.push({ model, reason: credential.reason ?? `no credential for ${provider}` });
	}
	return { resolvable, unresolvable };
}
