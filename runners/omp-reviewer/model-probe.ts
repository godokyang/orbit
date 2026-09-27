// Pure availability computation for the independent checker's model probe.
//
// The probe answers one question without a model request: for each candidate
// `provider/id`, can the reviewer's OMP source catalog (a) find the exact
// model and (b) resolve a credential through OMP's own per-model resolver?
// Credentials are never returned or stored: the resolver reports availability
// only, so no token can leak into the evidence file or the caller.

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
 * Classify each candidate against the OMP source catalog and credential
 * resolver. `resolveCredential` runs OMP's own per-model resolution — the
 * same call the real check's session makes at request time — so the probe and
 * the check see one identity. Its return value carries an availability
 * boolean, never a token. Duplicate candidates are reported once, in
 * first-seen order.
 */
export async function probeModelAvailability(
	specs: readonly string[],
	findModel: (provider: string, id: string) => boolean,
	resolveCredential: (provider: string, id: string) => Promise<CredentialAvailability>,
): Promise<ModelProbeAvailability> {
	const seen = new Set<string>();
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
			unresolvable.push({ model, reason: "model not in OMP source catalog" });
			continue;
		}
		const credential = await resolveCredential(provider, id);
		if (credential.ok) resolvable.push(model);
		else unresolvable.push({ model, reason: credential.reason ?? `no credential for ${provider}` });
	}
	return { resolvable, unresolvable };
}
