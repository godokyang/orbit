import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { createServer, type Server } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { TaskService } from '@orbit/core'
import { runCli } from '../src/run.js'

const dirs: string[] = []
const servers: Server[] = []

async function project(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'orbit-cli-'))
  dirs.push(dir)
  return dir
}

async function startTask(dir: string): Promise<string> {
  const { state } = await TaskService.start({
    projectRoot: dir,
    rootSessionId: 'root-1',
    instruction: 'Build the CLI slice.',
  })
  return state.id
}

async function fakeControl(dir: string, respond: (request: { id: string; method: string }) => unknown): Promise<Server> {
  await mkdir(join(dir, '.orbit'), { recursive: true })
  const server = createServer((socket) => {
    socket.setEncoding('utf8')
    let buffer = ''
    socket.on('data', (chunk: string) => {
      buffer += chunk
      const index = buffer.indexOf('\n')
      if (index < 0) return
      const request = JSON.parse(buffer.slice(0, index)) as { id: string; method: string }
      socket.write(`${JSON.stringify({ id: request.id, ok: true, result: respond(request) })}\n`)
    })
  })
  servers.push(server)
  await new Promise<void>((resolve) => server.listen(join(dir, '.orbit', 'orbit.sock'), () => resolve()))
  return server
}

function capture(): { io: { out: (text: string) => void; err: (text: string) => void }; out: () => string; err: () => string } {
  const out: string[] = []
  const err: string[] = []
  return {
    io: { out: (text) => out.push(text), err: (text) => err.push(text) },
    out: () => out.join('\n'),
    err: () => err.join('\n'),
  }
}

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))))
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('orbit-ts status/events', () => {
  it('reads the durable record when no host socket exists', async () => {
    const dir = await project()
    const taskId = await startTask(dir)
    const sink = capture()

    expect(await runCli(['status', '--json', '--project', dir], sink.io)).toBe(0)
    const view = JSON.parse(sink.out()) as { taskId: string; status: string; inputVersion: number }
    expect(view).toMatchObject({ taskId, status: 'running', inputVersion: 1 })

    const events = capture()
    expect(await runCli(['events', '--json', '--project', dir], events.io)).toBe(0)
    const parsed = JSON.parse(events.out()) as { events: Array<{ type: string }> }
    expect(parsed.events[0]?.type).toBe('task/created')
  })

  it('prefers the live host answer over the durable record', async () => {
    const dir = await project()
    await startTask(dir)
    await fakeControl(dir, () => ({
      ok: true,
      taskId: 'task-from-socket',
      status: 'running',
      inputVersion: 2,
      artifactRoot: dir,
      checksInFlight: null,
      members: [],
      workUnits: [],
      checks: [],
      openFindings: [],
    }))
    const sink = capture()
    expect(await runCli(['status', '--json', '--project', dir], sink.io)).toBe(0)
    expect(JSON.parse(sink.out())).toMatchObject({ taskId: 'task-from-socket', inputVersion: 2 })
  })

  it('reads session projections from the live host', async () => {
    const dir = await project()
    await startTask(dir)
    await fakeControl(dir, () => ({
      as_of_seq: 9,
      root: {
        session_id: 'root-1',
        state: 'available',
        visible_text: [{ seq: 1, text: 'done' }],
        user_messages: [{ id: 'u1', seq: 2, text: 'go' }],
        activities: [],
        questions: [],
      },
      members: [],
    }))
    const sink = capture()
    expect(await runCli(['sessions', '--json', '--project', dir], sink.io)).toBe(0)
    expect(JSON.parse(sink.out())).toMatchObject({ as_of_seq: 9, root: { session_id: 'root-1' } })
  })

  it('prints a human summary with a next action', async () => {
    const dir = await project()
    await startTask(dir)
    const sink = capture()
    expect(await runCli(['status', '--project', dir], sink.io)).toBe(0)
    expect(sink.out()).toContain('running')
    expect(sink.out()).toContain('next:')
  })
})

describe('orbit-ts stop', () => {
  it('sends stop through the live control socket', async () => {
    const dir = await project()
    await fakeControl(dir, () => ({ ok: true, taskId: 'task-1', status: 'running', fence: 'armed' }))
    const sink = capture()
    expect(await runCli(['stop', '--project', dir], sink.io)).toBe(0)
    expect(sink.out()).toContain('stop armed for task-1')
  })

  it('fails closed when no live host exists', async () => {
    const dir = await project()
    const sink = capture()
    expect(await runCli(['stop', '--project', dir], sink.io)).toBe(1)
    expect(sink.err()).toContain('no live Orbit host')
  })
})

describe('orbit-ts export', () => {
  it('writes a self-contained evidence package', async () => {
    const dir = await project()
    const taskId = await startTask(dir)
    const service = await (await import('@orbit/core')).TaskService.open(join(dir, '.orbit', 'tasks', taskId))
    await service.amend('Second requirement.', { kind: 'explicit-text', verbatim: false, at: new Date().toISOString() })

    const output = join(dir, 'evidence.json')
    const sink = capture()
    expect(await runCli(['export', '--output', output, '--project', dir], sink.io)).toBe(0)
    expect(sink.out()).toContain(taskId)

    const parsed = JSON.parse(await (await import('node:fs/promises')).readFile(output, 'utf8')) as {
      format: string
      taskId: string
      state: { input: { versions: unknown[] } }
      files: Record<string, { encoding: string; content: string }>
    }
    expect(parsed.format).toBe('orbit-export-v1')
    expect(parsed.taskId).toBe(taskId)
    expect(parsed.state.input.versions).toHaveLength(2)
    expect(parsed.files['events.jsonl']?.content).toContain('input/amended')
    expect(parsed.files['state.json']?.encoding).toBe('utf8')
  })

  it('requires --output', async () => {
    const dir = await project()
    const sink = capture()
    expect(await runCli(['export', '--project', dir], sink.io)).toBe(2)
    expect(sink.err()).toContain('--output')
  })
})
