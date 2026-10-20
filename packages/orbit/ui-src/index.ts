import type { Context } from '@deepseek-ai/cordis'
import { createElement, useEffect, useState } from 'react'
import type {} from '@deepseek-ai/dsh-client-ui-conversation/client'
import type {} from '@deepseek-ai/dsh-client-ui-session/client'
import type {} from '@deepseek-ai/dsh-client-ui-slots'

export const inject = ['slots', 'uiConversation']

interface OrbitStatus {
  taskId?: string
  status?: string
  stopConfirmation?: { confirmed?: boolean }
  checksInFlight?: number | null
  openFindings?: string[]
  pendingQuestions?: Array<{ id: string; question: string }>
}

async function request(sessionId: string, init?: RequestInit): Promise<OrbitStatus | undefined> {
  try {
    const response = await fetch(`/orbit/api?session=${encodeURIComponent(sessionId)}`, init)
    if (!response.ok) return undefined
    return (await response.json()) as OrbitStatus
  } catch {
    return undefined
  }
}

function action(sessionId: string, body: Record<string, unknown>): Promise<OrbitStatus | undefined> {
  return request(sessionId, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-orbit-api': '1' },
    body: JSON.stringify({ session: sessionId, ...body }),
  })
}

function OrbitPanel({ sessionId }: { sessionId: string }): unknown {
  const [data, setData] = useState<OrbitStatus | undefined>(undefined)
  useEffect(() => {
    let alive = true
    const load = (): void => { void request(sessionId).then((next) => { if (alive && next !== undefined) setData(next) }) }
    load()
    const timer = setInterval(load, 2000)
    return () => { alive = false; clearInterval(timer) }
  }, [sessionId])
  if (data === undefined) return createElement('div', { style: { padding: '4px 12px', fontSize: 12, opacity: 0.65 } }, 'Orbit')
  const pending = data.pendingQuestions ?? []
  return createElement('div', { style: { display: 'flex', gap: 8, alignItems: 'center', padding: '4px 12px', fontSize: 12 } },
    createElement('strong', null, 'Orbit'),
    createElement('span', null, `${data.taskId ?? ''} · ${data.status ?? 'unknown'}${data.stopConfirmation?.confirmed ? ' stopped' : ''} · checks ${data.checksInFlight ?? 'none'} · findings ${data.openFindings?.length ?? 0} · questions ${pending.length}`),
    createElement('button', { onClick: () => { void action(sessionId, { action: 'stop' }) } }, 'Stop'),
    pending[0] !== undefined ? createElement('button', {
      onClick: () => { void action(sessionId, { action: 'answer', question: pending[0]!.id, selected: [], custom: 'Continue.' }) },
    }, 'Answer') : null,
  )
}

export function apply(ctx: Context): void {
  ctx.slots.register({ name: 'conversation.input.dock', id: 'orbit-panel' }, OrbitPanel as never)
}
