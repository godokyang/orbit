import { createHash } from 'node:crypto'
import { realpathSync, statSync } from 'node:fs'
import { OrbitError } from './errors.js'
import type { FindingRecord } from './types.js'

/** Material schema version; bump when the canonical structure changes. */
export const OBSERVATION_KEY_VERSION = 1
/** Only the newest host observations are material. */
export const OBSERVATION_TAIL = 10
/** Per-string bound inside canonical material. */
export const OBSERVATION_STRING_CAP = 2_000

export interface ObservationHost {
  status?: unknown
  lastTurnId?: unknown
  lastTurnStatus?: unknown
  observations?: unknown[]
}

export interface ObservationKeyInput {
  inputDigest: string
  artifactRoot: string
  artifactDigest: string
  host: ObservationHost
  findings: readonly FindingRecord[]
  dispute?: unknown
  trigger?: unknown
}

function sha256(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

function boundString(value: unknown): string {
  const text = String(value)
  if ([...text].length <= OBSERVATION_STRING_CAP) return text
  return `${text.slice(0, OBSERVATION_STRING_CAP)}…[${[...text].length}:${sha256(text)}]`
}

/** Deep-canonical form: sorted object keys, bounded strings, array order kept. */
export function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((entry) => canonicalize(entry))
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>
    return Object.fromEntries(Object.keys(record).sort().map((key) => [key, canonicalize(record[key])]))
  }
  if (typeof value === 'string') return boundString(value)
  if (typeof value === 'number' || typeof value === 'boolean' || value === null || value === undefined) return value
  return boundString(value)
}

/** realpath keeps the key independent of symlink spelling. */
export function canonicalArtifactRoot(path: string): string {
  if (path.trim().length === 0) throw new OrbitError('invalid_input', 'artifact root is required')
  let real: string
  try {
    real = realpathSync(path)
  } catch (error) {
    throw new OrbitError('invalid_input', `artifact root is not resolvable: ${path} (${(error as Error).message})`)
  }
  if (!statSync(real).isDirectory()) throw new OrbitError('invalid_input', `artifact root is not a directory: ${path}`)
  return real
}

function hostMaterial(host: ObservationHost): Record<string, unknown> {
  const observations = host.observations ?? []
  if (!Array.isArray(observations)) throw new OrbitError('invalid_input', 'host observations must be an array')
  return {
    status: host.status,
    last_turn_id: host.lastTurnId,
    last_turn_status: host.lastTurnStatus,
    observations: observations.slice(-OBSERVATION_TAIL).map((entry) => sha256(JSON.stringify(canonicalize(entry)))),
  }
}

function openFindingsMaterial(findings: readonly FindingRecord[]): Array<Record<string, unknown>> {
  return findings
    .filter((finding) => finding.status === 'open')
    .map((finding) => ({
      id: finding.id,
      requirement: boundString(finding.requirement),
      evidence: boundString(finding.evidence),
      action: boundString(finding.action),
    }))
    .sort((a, b) => String(a.id).localeCompare(String(b.id)))
}

/** Canonical material the key hashes; exposed for logs and debugging. */
export function observationKeyMaterial(input: ObservationKeyInput): Record<string, unknown> {
  return {
    version: OBSERVATION_KEY_VERSION,
    input_digest: boundString(input.inputDigest),
    artifact_root: canonicalArtifactRoot(input.artifactRoot),
    artifact_digest: boundString(input.artifactDigest),
    host: hostMaterial(input.host),
    open_findings: openFindingsMaterial(input.findings),
    dispute: canonicalize(input.dispute),
    trigger: canonicalize(input.trigger),
  }
}

/** Deterministic 64-hex observation key for check deduplication. */
export function observationKey(input: ObservationKeyInput): string {
  return sha256(JSON.stringify(observationKeyMaterial(input)))
}
