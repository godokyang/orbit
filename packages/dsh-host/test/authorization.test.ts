import { describe, expect, it } from 'vitest'
import { allowedSet, authorizeRoute, routeKey } from '../src/authorization.js'

describe('strict model authorization', () => {
  it('allows any route when no frozen list is configured', () => {
    const decision = authorizeRoute({ route: { provider: 'p', model: 'm' }, allowed: allowedSet([]) })
    expect(decision).toMatchObject({ ok: true })
  })

  it('accepts an exact provider/model pair and binds it', () => {
    const decision = authorizeRoute({
      route: { provider: 'p', model: 'm', reasoning: 'high' },
      allowed: allowedSet(['p/m']),
    })
    expect(decision).toMatchObject({ ok: true, bound: { provider: 'p', model: 'm', reasoning: 'high' } })
  })

  it('rejects a route outside the list', () => {
    const decision = authorizeRoute({ route: { provider: 'p', model: 'other' }, allowed: allowedSet(['p/m']) })
    expect(decision).toMatchObject({ ok: false, code: 'not_allowed' })
  })

  it('rejects provider/model drift after binding', () => {
    const decision = authorizeRoute({
      route: { provider: 'p', model: 'm2' },
      allowed: allowedSet(['p/m', 'p/m2']),
      bound: { provider: 'p', model: 'm' },
    })
    expect(decision).toMatchObject({ ok: false, code: 'drift' })
  })

  it('does not treat reasoning effort as drift', () => {
    const decision = authorizeRoute({
      route: { provider: 'p', model: 'm', reasoning: 'low' },
      allowed: allowedSet(['p/m']),
      bound: { provider: 'p', model: 'm', reasoning: 'high' },
    })
    expect(decision.ok).toBe(true)
  })

  it('normalizes blank allowlist entries', () => {
    expect([...allowedSet([' p/m ', ' ', 'p/n'])]).toEqual(['p/m', 'p/n'])
    expect(routeKey({ provider: 'p', model: 'm' })).toBe('p/m')
  })
})
