import { randomUUID } from 'node:crypto'
import { join, resolve } from 'node:path'
import { CONTROL_SOCKET_FILE, type ControlRequest, type ControlResponse } from '@orbit/core'
import { requestControl } from './client.js'
import { localEvents, localStatus, type StatusView } from './tasks.js'
import { exportTask } from './export.js'

export interface CliIo {
  out: (text: string) => void
  err: (text: string) => void
}

const USAGE = `orbit — Orbit thin client

Usage:
  orbit-ts status [TASK] [--json] [--project DIR]
  orbit-ts events [TASK] [--json] [--project DIR]
  orbit stop   [TASK] [--json] [--project DIR]
  orbit sessions [TASK] [--json] [--project DIR]
  orbit export [TASK] --output FILE [--json] [--project DIR]

status/events read the live host through the project control socket and fall
back to the durable task record when no host is running. stop requires the
live host. export snapshots the task record into a self-contained JSON file.`

interface Parsed {
  command: 'status' | 'events' | 'stop' | 'export' | 'sessions'
  task?: string
  project: string
  json: boolean
  output?: string
}

class UsageError extends Error {}

function parse(argv: string[]): Parsed | 'help' {
  if (argv.length === 0) throw new UsageError('missing command')
  const command = argv[0]
  if (command === '--help' || command === '-h' || command === 'help') return 'help'
  if (command !== 'status' && command !== 'events' && command !== 'stop' && command !== 'export' && command !== 'sessions') {
    throw new UsageError(`unknown command: ${String(command)}`)
  }
  let task: string | undefined
  let project = process.cwd()
  let json = false
  let output: string | undefined
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--json') {
      json = true
    } else if (arg === '--project') {
      const value = argv[index + 1]
      if (value === undefined) throw new UsageError('--project requires a directory')
      project = resolve(value)
      index += 1
    } else if (arg === '--output') {
      const value = argv[index + 1]
      if (value === undefined) throw new UsageError('--output requires a file')
      output = resolve(value)
      index += 1
    } else if (arg === '--help' || arg === '-h') {
      return 'help'
    } else if (arg?.startsWith('-')) {
      throw new UsageError(`unknown option: ${arg}`)
    } else if (task === undefined) {
      task = arg
    } else {
      throw new UsageError(`unexpected argument: ${arg}`)
    }
  }
  if (command === 'export' && output === undefined) throw new UsageError('export requires --output FILE')
  return { command, project, json, ...(task === undefined ? {} : { task }), ...(output === undefined ? {} : { output }) }
}

async function control(project: string, request: ControlRequest): Promise<ControlResponse | undefined> {
  const socketPath = join(project, '.orbit', CONTROL_SOCKET_FILE)
  try {
    return await requestControl(socketPath, request)
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'ENOENT' || code === 'ECONNREFUSED') return undefined
    throw error
  }
}

function nextAction(view: StatusView): string {
  if (view.status === 'stop_unconfirmed') return 'verify the remaining resources, then run stop again'
  if (view.openFindings.length > 0) return 'fix open findings or open a dispute, then request another check'
  if (view.checksInFlight !== null) return 'wait for the in-flight check'
  if (view.status === 'complete') return 'done'
  if (view.status === 'paused' || view.status === 'needs_user') return 'stopped; resume by creating a new task'
  if (view.completionInvalidation !== undefined) return `completion rejected (${view.completionInvalidation.code}); ${view.completionInvalidation.message}`
  return 'continue delivery; request a manual check before completion'
}

function printStatus(view: StatusView, json: boolean, out: CliIo['out']): void {
  if (json) {
    out(JSON.stringify(view, null, 2))
    return
  }
  const lines = [
    `task ${view.taskId}  ${view.status}`,
    `input v${view.inputVersion}  artifact ${view.artifactRoot}`,
    `members ${view.members.length}  units ${view.workUnits.length}  checks ${view.checks.length}  open findings ${view.openFindings.length}  open disputes ${view.openDisputes?.length ?? 0}`,
  ]
  if (view.stop !== undefined) lines.push(`stop: ${view.stop}${view.checksInFlight === null ? '' : ` (check ${view.checksInFlight} in flight)`}`)
  if (view.completionInvalidation !== undefined) {
    lines.push(`completion: ${view.completionInvalidation.code} — ${view.completionInvalidation.message}`)
  }
  lines.push(`next: ${nextAction(view)}`)
  out(lines.join('\n'))
}

function printEvents(result: { taskId: string; events: Array<{ seq: number; at: string; type: string; data?: unknown }> }, json: boolean, out: CliIo['out']): void {
  if (json) {
    out(JSON.stringify(result, null, 2))
    return
  }
  const lines = result.events.map((event) => `${String(event.seq).padStart(4, '0')}  ${event.at}  ${event.type}${event.data === undefined ? '' : `  ${JSON.stringify(event.data)}`}`)
  out(lines.length === 0 ? `task ${result.taskId} has no events` : lines.join('\n'))
}

export async function runCli(argv: string[], io: Partial<CliIo> = {}): Promise<number> {
  const out = io.out ?? ((text: string) => console.log(text))
  const err = io.err ?? ((text: string) => console.error(text))
  let parsed: Parsed | 'help'
  try {
    parsed = parse(argv)
  } catch (error) {
    err(`${(error as Error).message}\n\n${USAGE}`)
    return 2
  }
  if (parsed === 'help') {
    out(USAGE)
    return 0
  }

  try {
    if (parsed.command === 'status') {
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'status',
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      if (response === undefined) {
        printStatus(await localStatus(parsed.project, parsed.task), parsed.json, out)
        return 0
      }
      if (!response.ok) throw new Error(response.error.message)
      printStatus(response.result as StatusView, parsed.json, out)
      return 0
    }

    if (parsed.command === 'events') {
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'events',
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      if (response === undefined) {
        printEvents(await localEvents(parsed.project, parsed.task), parsed.json, out)
        return 0
      }
      if (!response.ok) throw new Error(response.error.message)
      printEvents(response.result as { taskId: string; events: [] }, parsed.json, out)
      return 0
    }

    if (parsed.command === 'sessions') {
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'sessions',
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      if (response === undefined) throw new Error(`no live Orbit host for ${parsed.project} (control socket missing)`)
      if (!response.ok) throw new Error(response.error.message)
      const result = response.result as {
        as_of_seq: number
        root: { session_id: string; state: string; visible_text: unknown[]; user_messages: unknown[]; activities: unknown[]; questions: unknown[] }
        members: Array<{ session_id: string; state: string; visible_text: unknown[]; user_messages: unknown[]; activities: unknown[]; questions: unknown[] }>
      }
      if (parsed.json) {
        out(JSON.stringify(result, null, 2))
      } else {
        const sessions = [result.root, ...result.members]
        out(`as_of_seq ${result.as_of_seq}`)
        for (const session of sessions) {
          out(
            `${session.session_id}  ${session.state}  visible ${session.visible_text.length}  user ${session.user_messages.length}  activities ${session.activities.length}  questions ${session.questions.length}`,
          )
        }
      }
      return 0
    }

    if (parsed.command === 'export') {
      const result = await exportTask(parsed.project, parsed.task, parsed.output as string)
      out(parsed.json ? JSON.stringify({ taskId: result.taskId, bytes: result.bytes, output: result.output, files: Object.keys(result.files).length }, null, 2) : `exported ${result.taskId} (${Object.keys(result.files).length} files, ${result.bytes} bytes) to ${result.output}`)
      return 0
    }

    const response = await control(parsed.project, {
      id: randomUUID(),
      method: 'stop',
      ...(parsed.task === undefined ? {} : { task: parsed.task }),
    })
    if (response === undefined) {
      throw new Error(`no live Orbit host for ${parsed.project} (control socket missing)`)
    }
    if (!response.ok) throw new Error(response.error.message)
    const result = response.result as Record<string, unknown>
    out(parsed.json ? JSON.stringify(result, null, 2) : `stop armed for ${String(result.taskId)}; status ${String(result.status)}`)
    return 0
  } catch (error) {
    err(`orbit: ${(error as Error).message}`)
    return 1
  }
}
