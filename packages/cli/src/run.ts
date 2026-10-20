import { randomUUID } from 'node:crypto'
import { join, resolve } from 'node:path'
import { CONTROL_SOCKET_FILE, type ControlRequest, type ControlResponse, type TaskEvent } from '@orbit/core'
import { requestControl } from './client.js'
import { localEvents, localQuestions, localStatus, localStatusByRef, localStatusBySession, type StatusView } from './tasks.js'
import { exportTask } from './export.js'
import { localSessions } from './sessions.js'
import { CAPABILITIES, INTEGRATION_CONTRACT, buildLaunchSpec } from './capabilities.js'
import { doctor } from './doctor.js'

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
  orbit questions [TASK] [--json] [--project DIR]
  orbit answer [TASK] --question ID --selected A,B [--custom TEXT] [--json] [--project DIR]
  orbit prompt [TASK] --message TEXT [--json] [--project DIR]
  orbit abort [TASK] [--json] [--project DIR]
  orbit doctor [--json] [--home DIR] [--profile P]
  orbit export [TASK] --output FILE [--json] [--project DIR]
  orbit version [--json]
  orbit capabilities [--json]
  orbit launch [--json] [--profile P] [--home DIR] [--project DIR] [--bootstrap FILE] [--result FILE] [--dsh BIN]

status/events read the live host through the project control socket and fall
back to the durable task record when no host is running. stop requires the
live host. export snapshots the task record into a self-contained JSON file.`

interface Parsed {
  command: 'status' | 'events' | 'stop' | 'export' | 'sessions' | 'capabilities' | 'launch' | 'questions' | 'answer' | 'prompt' | 'abort' | 'doctor' | 'version'
  question?: string
  selected?: string[]
  custom?: string
  profile?: string
  home?: string
  after?: string
  externalRef?: string
  session?: string
  bootstrap?: string
  resultFile?: string
  dshBin?: string
  message?: string
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
  const commands = ['status', 'events', 'stop', 'export', 'sessions', 'capabilities', 'launch', 'questions', 'answer', 'prompt', 'abort', 'doctor', 'version'] as const
  if (command === undefined || !(commands as readonly string[]).includes(command)) {
    throw new UsageError(`unknown command: ${String(command)}`)
  }
  let task: string | undefined
  let project = process.cwd()
  let json = false
  let output: string | undefined
  let profile: string | undefined
  let home: string | undefined
  let question: string | undefined
  let selected: string[] | undefined
  let custom: string | undefined
  let after: string | undefined
  let externalRef: string | undefined
  let session: string | undefined
  let bootstrap: string | undefined
  let resultFile: string | undefined
  let dshBin: string | undefined
  let message: string | undefined
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--json') {
      json = true
    } else if (arg === '--project') {
      const value = argv[index + 1]
      if (value === undefined) throw new UsageError('--project requires a directory')
      project = resolve(value)
      index += 1
    } else if (arg === '--message') {
      message = argv[++index]
    } else if (arg === '--dsh') {
      dshBin = argv[++index]
    } else if (arg === '--bootstrap') {
      bootstrap = argv[++index]
    } else if (arg === '--result') {
      resultFile = argv[++index]
    } else if (arg === '--session') {
      session = argv[++index]
    } else if (arg === '--external-ref') {
      externalRef = argv[++index]
    } else if (arg === '--after') {
      after = argv[++index]
    } else if (arg === '--question') {
      question = argv[++index]
    } else if (arg === '--selected') {
      const value = argv[++index]
      if (value === undefined) throw new UsageError('--selected requires labels')
      selected = value.split(',').map((entry) => entry.trim()).filter((entry) => entry.length > 0)
    } else if (arg === '--custom') {
      custom = argv[++index]
    } else if (arg === '--profile') {
      profile = argv[++index]
    } else if (arg === '--home') {
      home = argv[++index]
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
  return {
    command: command as Parsed['command'],
    project,
    json,
    ...(task === undefined ? {} : { task }),
    ...(output === undefined ? {} : { output }),
    ...(profile === undefined ? {} : { profile }),
    ...(home === undefined ? {} : { home }),
    ...(question === undefined ? {} : { question }),
    ...(selected === undefined ? {} : { selected }),
    ...(custom === undefined ? {} : { custom }),
    ...(after === undefined ? {} : { after }),
    ...(externalRef === undefined ? {} : { externalRef }),
    ...(session === undefined ? {} : { session }),
    ...(bootstrap === undefined ? {} : { bootstrap }),
    ...(resultFile === undefined ? {} : { resultFile }),
    ...(dshBin === undefined ? {} : { dshBin }),
    ...(message === undefined ? {} : { message }),
  }
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

function encodeCursor(seq: number | undefined): string | null {
  return seq === undefined ? null : Buffer.from(JSON.stringify({ seq }), 'utf8').toString('base64url')
}

function decodeCursor(cursor: string | undefined): number | undefined {
  if (cursor === undefined) return undefined
  if (/^\d+$/.test(cursor)) return Number(cursor)
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')) as { seq?: unknown }
    if (typeof parsed.seq !== 'number' || !Number.isInteger(parsed.seq) || parsed.seq < 0) throw new Error('bad seq')
    return parsed.seq
  } catch {
    throw new UsageError(`invalid --after cursor: ${cursor}`)
  }
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
    if (parsed.command === 'version') {
      out(parsed.json ? JSON.stringify({ version: '0.0.0' }) : '0.0.0')
      return 0
    }

    if (parsed.command === 'capabilities') {
      const payload = { integration_contract: INTEGRATION_CONTRACT, orbit: { version: '0.0.0' }, capabilities: CAPABILITIES }
      out(JSON.stringify(payload, null, 2))
      return 0
    }

    if (parsed.command === 'prompt') {
      if (parsed.message === undefined) throw new UsageError('prompt requires --message TEXT')
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'prompt',
        message: parsed.message,
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      if (response === undefined) throw new Error(`no live Orbit host for ${parsed.project} (control socket missing)`)
      if (!response.ok) throw new Error(response.error.message)
      const result = response.result as { taskId: string; messageId: string }
      out(parsed.json ? JSON.stringify(result, null, 2) : `prompt accepted for ${result.taskId} (${result.messageId})`)
      return 0
    }

    if (parsed.command === 'abort') {
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'abort',
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      if (response === undefined) throw new Error(`no live Orbit host for ${parsed.project} (control socket missing)`)
      if (!response.ok) throw new Error(response.error.message)
      const result = response.result as { taskId: string; scope: string }
      out(parsed.json ? JSON.stringify(result, null, 2) : `aborted session for ${result.taskId} (${result.scope})`)
      return 0
    }

    if (parsed.command === 'questions') {
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'questions',
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      const result = response !== undefined && response.ok
        ? (response.result as { questions: unknown[] })
        : await localQuestions(parsed.project, parsed.task)
      if (parsed.json) out(JSON.stringify(result, null, 2))
      else {
        const questions = result.questions as Array<{ id: string; memberId: string; question: string; status: string }>
        out(questions.length === 0 ? 'no questions' : questions.map((entry) => `${entry.id}  ${entry.status}  ${entry.memberId}  ${entry.question}`).join('\n'))
      }
      return 0
    }

    if (parsed.command === 'answer') {
      if (parsed.question === undefined) throw new UsageError('answer requires --question ID')
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'answer',
        question: parsed.question,
        selected: parsed.selected ?? [],
        ...(parsed.custom === undefined ? {} : { custom: parsed.custom }),
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      if (response === undefined) throw new Error(`no live Orbit host for ${parsed.project} (control socket missing)`)
      if (!response.ok) throw new Error(response.error.message)
      const result = response.result as { question: { id: string; status: string } }
      out(parsed.json ? JSON.stringify(result, null, 2) : `answered ${result.question.id} (${result.question.status})`)
      return 0
    }

    if (parsed.command === 'doctor') {
      const report = doctor(parsed.home ?? process.env.DSH_HOME ?? join(process.env.HOME ?? '', '.dsh'), parsed.profile ?? 'orbit-app')
      out(parsed.json ? JSON.stringify(report, null, 2) : `${report.ok ? 'ok' : 'problems'}  ${report.profile}  ${report.checks.map((check) => `${check.name}:${check.ok ? 'ok' : 'FAIL'}`).join(' ')}`)
      return report.ok ? 0 : 1
    }

    if (parsed.command === 'launch') {
      const spec = buildLaunchSpec({
        projectRoot: parsed.project,
        ...(parsed.profile === undefined ? {} : { profile: parsed.profile }),
        ...(parsed.home === undefined ? {} : { home: parsed.home }),
        ...(parsed.bootstrap === undefined ? {} : { bootstrap: parsed.bootstrap }),
        ...(parsed.resultFile === undefined ? {} : { result: parsed.resultFile }),
        ...(parsed.dshBin === undefined ? {} : { dshBin: parsed.dshBin }),
      })
      out(parsed.json ? JSON.stringify(spec, null, 2) : `${spec.profile}  cwd ${spec.cwd}  socket ${spec.control_socket}`)
      return 0
    }

    if (parsed.command === 'status' && parsed.session !== undefined) {
      if (parsed.task !== undefined || parsed.externalRef !== undefined) {
        throw new UsageError('TASK, --external-ref and --session are mutually exclusive')
      }
      const tasks = await localStatusBySession(parsed.project, parsed.session)
      if (parsed.json) out(JSON.stringify({ tasks }, null, 2))
      else out(tasks.length === 0 ? 'no tasks' : tasks.map((task) => `${task.taskId}  ${task.status}  ${task.artifactRoot}`).join('\n'))
      return 0
    }

    if (parsed.command === 'status' && parsed.externalRef !== undefined) {
      if (parsed.task !== undefined) throw new UsageError('TASK and --external-ref are mutually exclusive')
      const tasks = await localStatusByRef(parsed.project, parsed.externalRef)
      if (parsed.json) out(JSON.stringify({ tasks }, null, 2))
      else out(tasks.length === 0 ? 'no tasks' : tasks.map((task) => `${task.taskId}  ${task.status}  ${task.artifactRoot}`).join('\n'))
      return 0
    }

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
      const afterSeq = decodeCursor(parsed.after)
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'events',
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      const result = response === undefined
        ? await localEvents(parsed.project, parsed.task)
        : response.ok
          ? (response.result as { taskId: string; events: TaskEvent[] })
          : (() => { throw new Error(response.error.message) })()
      const events = result.events.filter((event) => afterSeq === undefined || event.seq > afterSeq)
      const envelope = { taskId: result.taskId, events, next_cursor: encodeCursor(events.at(-1)?.seq) }
      if (parsed.json) out(JSON.stringify(envelope, null, 2))
      else out(events.length === 0 ? 'no events' : events.map((event) => `${event.seq}  ${event.type}`).join('\n'))
      return 0
    }

    if (parsed.command === 'sessions') {
      const response = await control(parsed.project, {
        id: randomUUID(),
        method: 'sessions',
        ...(parsed.task === undefined ? {} : { task: parsed.task }),
      })
      if (response === undefined) {
        const result = await localSessions(parsed.project, parsed.task)
        if (parsed.json) {
          out(JSON.stringify(result, null, 2))
        } else {
          const sessions = [result.root, ...result.members]
          out(`as_of_seq ${result.as_of_seq} (archived)`)
          for (const session of sessions) {
            out(
              `${session.session_id}  ${session.state}  segments ${session.archive_segments}  visible ${session.visible_text.length}  user ${session.user_messages.length}  activities ${session.activities.length}  gaps ${session.gaps.length}`,
            )
          }
        }
        return 0
      }
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
