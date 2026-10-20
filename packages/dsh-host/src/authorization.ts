import type { ModelIdentity } from '@orbit/core'

export interface ModelRoute {
  provider: string
  model: string
  reasoning?: string
}

export type AuthorizationDecision =
  | { ok: true; bound: ModelRoute }
  | { ok: false; code: 'not_allowed' | 'drift'; message: string }

export function routeKey(route: ModelRoute): string {
  return `${route.provider}/${route.model}`
}

/**
 * Strict task authorization: the empty list means no frozen list. Matching and
 * drift compare the exact provider/model pair; reasoning effort is not a route
 * identity here because it is often unknown before the first stream.
 */
export function authorizeRoute(input: {
  route: ModelRoute
  allowed: ReadonlySet<string>
  bound?: ModelRoute
}): AuthorizationDecision {
  if (input.allowed.size > 0 && !input.allowed.has(routeKey(input.route))) {
    return {
      ok: false,
      code: 'not_allowed',
      message: `model ${routeKey(input.route)} is not in this task's frozen authorization list`,
    }
  }
  if (input.bound !== undefined && routeKey(input.bound) !== routeKey(input.route)) {
    return {
      ok: false,
      code: 'drift',
      message: `model drifted from ${routeKey(input.bound)} to ${routeKey(input.route)}`,
    }
  }
  return {
    ok: true,
    bound: {
      provider: input.route.provider,
      model: input.route.model,
      ...(input.route.reasoning === undefined ? {} : { reasoning: input.route.reasoning }),
    },
  }
}

export function allowedSet(models: readonly string[] | undefined): Set<string> {
  return new Set((models ?? []).map((model) => model.trim()).filter((model) => model.length > 0))
}

export type AuthorizedModel = ModelIdentity
