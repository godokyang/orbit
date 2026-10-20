import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { openTask } from './tasks.js'

export interface ArchivedSession {
  session_id: string
  state: 'available' | 'unavailable'
  as_of_seq: number
  visible_text: Array<{ seq: number; text: string }>
  user_messages: Array<{ id: string; seq: number; text: string }>
  activities: Array<{ seq: number; name: string; status: string; target: string }>
  questions: unknown[]
  deliveries: Array<{ seq: number; kind: string }>
  gaps: Array<{ from: number; to: number }>
  archive_segments: number
}

export interface ArchivedSessions {
  as_of_seq: number
  root: ArchivedSession
  members: ArchivedSession[]
}

interface ArchivedEvent {
  seq: number
  type: string
  data: Record<string, unknown>
}

interface ArchiveSegment {
  seq?: { first?: number; last?: number }
  gap?: { from: number; to: number }
  events?: ArchivedEvent[]
}

function textBlocks(value: unknown): string {
  const blocks = Array.isArray(value) ? value : []
  return blocks
    .filter((block): block is { type?: string; text?: string } => typeof block === 'object' && block !== null)
    .filter((block) => block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text ?? '')
    .join('')
}

function activityTarget(args: unknown): string {
  if (args === null || typeof args !== 'object') return 'unknown'
  const record = args as Record<string, unknown>
  if (typeof record.file_path === 'string') return record.file_path
  if (typeof record.description === 'string') return 'shell'
  return 'unknown'
}

async function readSegments(taskDir: string, sessionId: string): Promise<ArchiveSegment[]> {
  const dir = join(taskDir, 'sessions', sessionId)
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return []
  }
  const segments: ArchiveSegment[] = []
  for (const name of names.filter((entry) => /^seq-\d+-\d+\.json$/.test(entry)).sort()) {
    try {
      segments.push(JSON.parse(await readFile(join(dir, name), 'utf8')) as ArchiveSegment)
    } catch {
      // A corrupt segment is omitted from the projection; no fabricated events.
    }
  }
  return segments
}

export function projectArchivedSession(sessionId: string, segments: ArchiveSegment[]): ArchivedSession {
  const events = segments
    .flatMap((segment) => segment.events ?? [])
    .sort((a, b) => a.seq - b.seq)
  if (events.length === 0) {
    return {
      session_id: sessionId,
      state: 'unavailable',
      as_of_seq: -1,
      visible_text: [],
      user_messages: [],
      activities: [],
      questions: [],
      deliveries: [],
      gaps: segments.filter((segment) => segment.gap !== undefined).map((segment) => segment.gap as { from: number; to: number }),
      archive_segments: segments.length,
    }
  }
  const visible: ArchivedSession['visible_text'] = []
  const users: ArchivedSession['user_messages'] = []
  const activities: ArchivedSession['activities'] = []
  const deliveries: ArchivedSession['deliveries'] = []
  const results = new Map<string, { isError?: boolean }>()
  for (const event of events) {
    const data = event.data ?? {}
    if (event.type === 'tool/result') {
      const message = data.message as { toolCallId?: string; isError?: boolean } | undefined
      if (typeof message?.toolCallId === 'string') results.set(message.toolCallId, { isError: message.isError })
    }
  }
  for (const event of events) {
    const data = event.data ?? {}
    if (event.type === 'assistant/message') {
      const message = data.message as { content?: unknown } | undefined
      const text = textBlocks(message?.content)
      if (text.length > 0) visible.push({ seq: event.seq, text })
    } else if (event.type === 'user/message') {
      const source = data.source as { kind?: string } | undefined
      const text = textBlocks(data.content)
      if (source?.kind === 'user' && text.length > 0) {
        users.push({ id: String(data.id ?? `seq-${event.seq}`), seq: event.seq, text })
      }
    } else if (event.type === 'tool/call') {
      let args: unknown
      try {
        args = JSON.parse(String(data.arguments ?? '{}'))
      } catch {
        args = undefined
      }
      const result = typeof data.callId === 'string' ? results.get(data.callId) : undefined
      activities.push({
        seq: event.seq,
        name: String(data.name ?? 'unknown'),
        status: result === undefined ? 'not_observed' : result.isError === true ? 'error' : 'ok',
        target: activityTarget(args),
      })
    } else if (event.type === 'turn/end') {
      const reason = data.reason as { kind?: string } | undefined
      if (reason?.kind === 'completed') deliveries.push({ seq: event.seq, kind: 'turn_completed' })
    }
  }
  const gaps = segments
    .filter((segment) => segment.gap !== undefined)
    .map((segment) => segment.gap as { from: number; to: number })
  return {
    session_id: sessionId,
    state: 'available',
    as_of_seq: events.at(-1)?.seq ?? -1,
    visible_text: visible,
    user_messages: users,
    activities,
    questions: [],
    deliveries,
    gaps,
    archive_segments: segments.length,
  }
}

/** Offline projection from the task's incremental session archives. */
export async function localSessions(projectRoot: string, id?: string): Promise<ArchivedSessions> {
  const service = await openTask(projectRoot, id)
  const state = await service.state()
  const members = await service.store.members()
  const root = projectArchivedSession(state.root.sessionId, await readSegments(service.store.dir, state.root.sessionId))
  const projected: ArchivedSession[] = []
  for (const member of members.members) {
    projected.push(projectArchivedSession(member.id, await readSegments(service.store.dir, member.id)))
  }
  const asOf = Math.max(root.as_of_seq, ...projected.map((session) => session.as_of_seq), -1)
  return { as_of_seq: asOf, root, members: projected }
}
