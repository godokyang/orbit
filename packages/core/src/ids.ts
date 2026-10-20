import { createHash, randomBytes } from 'node:crypto'

export function sha256Hex(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

export function newId(prefix: string): string {
  const time = Date.now().toString(36)
  const random = randomBytes(6).toString('hex')
  return `${prefix}-${time}-${random}`
}

/** Count Unicode code points, matching the contract's character bounds. */
export function charLength(text: string): number {
  return [...text].length
}

export function isBlank(text: string): boolean {
  return text.trim().length === 0
}
