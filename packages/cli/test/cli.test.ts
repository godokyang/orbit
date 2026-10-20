import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
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

describe('orbit-ts sessions (offline archive)', () => {
  it('projects visible text, user messages, activities and gaps from archives', async () => {
    const dir = await project()
    const taskId = await startTask(dir)
    const { TaskService } = await import('@orbit/core')
    const service = await TaskService.open(join(dir, '.orbit', 'tasks', taskId))
    const state = await service.state()
    await service.store.writeArchive(`sessions/${state.root.sessionId}/seq-1-3.json`, {
      seq: { first: 1, last: 3 },
      events: [
        { seq: 1, type: 'user/message', data: { id: 'u1', content: [{ type: 'text', text: 'go' }], source: { kind: 'user' } } },
        { seq: 2, type: 'assistant/message', data: { message: { content: [{ type: 'text', text: 'working' }] } } },
        { seq: 3, type: 'tool/call', data: { callId: 'c1', name: 'bash', arguments: '{"description":"x"}' } },
      ],
    })
    await service.store.writeArchive(`sessions/${state.root.sessionId}/seq-5-5.json`, {
      seq: { first: 5, last: 5 },
      gap: { from: 4, to: 4 },
      events: [
        { seq: 5, type: 'turn/end', data: { reason: { kind: 'completed' } } },
        { seq: 5, type: 'tool/result', data: { message: { toolCallId: 'c1', isError: false } } },
      ],
    })

    const sink = capture()
    expect(await runCli(['sessions', '--json', '--project', dir], sink.io)).toBe(0)
    const view = JSON.parse(sink.out()) as {
      root: { state: string; visible_text: unknown[]; user_messages: unknown[]; activities: Array<{ status: string }>; gaps: unknown[]; archive_segments: number }
    }
    expect(view.root.state).toBe('available')
    expect(view.root.visible_text).toHaveLength(1)
    expect(view.root.user_messages).toHaveLength(1)
    expect(view.root.activities[0]?.status).toBe('ok')
    expect(view.root.gaps).toHaveLength(1)
    expect(view.root.archive_segments).toBe(2)
  })

  it('returns unavailable when no archive exists', async () => {
    const dir = await project()
    await startTask(dir)
    const sink = capture()
    expect(await runCli(['sessions', '--json', '--project', dir], sink.io)).toBe(0)
    const view = JSON.parse(sink.out()) as { root: { state: string } }
    expect(view.root.state).toBe('unavailable')
  })
})

describe('orbit-ts capabilities and launch', () => {
  it('reports the frozen 2.0 contract and capabilities', async () => {
    const sink = capture()
    expect(await runCli(['capabilities', '--json'], sink.io)).toBe(0)
    const payload = JSON.parse(sink.out()) as {
      integration_contract: { version: string; major: number }
      capabilities: Record<string, unknown>
    }
    expect(payload.integration_contract).toMatchObject({ version: '2.0.0', major: 2 })
    expect(Object.keys(payload.capabilities)).toEqual(
      expect.arrayContaining(['launch', 'status', 'events', 'sessions', 'questions', 'answer', 'stop', 'export']),
    )
    const { readFileSync } = await import('node:fs')
    const contract = JSON.parse(readFileSync(join(process.cwd(), 'contracts', 'integration.json'), 'utf8')) as {
      version: string
      capabilities: Record<string, unknown>
    }
    expect(payload.integration_contract.version).toBe(contract.version)
    expect(Object.keys(payload.capabilities).sort()).toEqual(Object.keys(contract.capabilities).sort())
  })

  it('returns a launch spec without starting a process', async () => {
    const dir = await project()
    const sink = capture()
    expect(await runCli(['launch', '--json', '--project', dir, '--profile', 'orbit-node', '--home', '/tmp/orbit-home'], sink.io)).toBe(0)
    const spec = JSON.parse(sink.out()) as {
      profile: string
      cwd: string
      argv: string[]
      env: Record<string, string>
      control_socket: string
      stdin: string
    }
    expect(spec).toMatchObject({
      profile: 'orbit-node',
      cwd: dir,
      argv: ['--profile', 'orbit-node'],
      env: { DSH_HOME: '/tmp/orbit-home' },
      control_socket: join(dir, '.orbit', 'orbit.sock'),
      stdin: 'keep-open',
    })
  })
})

describe('orbit-ts questions and answer', () => {
  it('lists pending questions from the durable record offline', async () => {
    const dir = await project()
    const taskId = await startTask(dir)
    const { TaskService } = await import('@orbit/core')
    const service = await TaskService.open(join(dir, '.orbit', 'tasks', taskId))
    await service.askQuestion({ memberId: 'member-1', externalId: 'q1', question: 'Which?', options: [{ label: 'a' }] })

    const sink = capture()
    expect(await runCli(['questions', '--json', '--project', dir], sink.io)).toBe(0)
    const payload = JSON.parse(sink.out()) as { questions: Array<{ status: string; question: string }> }
    expect(payload.questions[0]).toMatchObject({ status: 'pending', question: 'Which?' })
  })

  it('answers through the live host socket', async () => {
    const dir = await project()
    await fakeControl(dir, () => ({ question: { id: 'question-1', status: 'answered' } }))
    const sink = capture()
    expect(
      await runCli(['answer', '--project', dir, '--question', 'question-1', '--selected', 'a,b', '--custom', 'other'], sink.io),
    ).toBe(0)
    expect(sink.out()).toContain('answered question-1')
  })
})

describe('orbit-ts events cursor', () => {
  it('returns an opaque cursor and filters with it', async () => {
    const dir = await project()
    await startTask(dir)
    const first = capture()
    expect(await runCli(['events', '--json', '--project', dir], first.io)).toBe(0)
    const page = JSON.parse(first.out()) as { events: Array<{ seq: number }>; next_cursor: string }
    expect(page.next_cursor.length).toBeGreaterThan(0)
    const lastSeq = page.events.at(-1)?.seq ?? 0

    const second = capture()
    expect(await runCli(['events', '--json', '--project', dir, '--after', page.next_cursor], second.io)).toBe(0)
    const next = JSON.parse(second.out()) as { events: Array<{ seq: number }> }
    expect(next.events.every((event) => event.seq > lastSeq)).toBe(true)
  })

  it('rejects an invalid cursor', async () => {
    const dir = await project()
    await startTask(dir)
    const sink = capture()
    expect(await runCli(['events', '--project', dir, '--after', 'not-a-cursor'], sink.io)).toBe(1)
  })
})

describe('orbit-ts status by external ref', () => {
  it('returns matching tasks and an empty array for no match', async () => {
    const dir = await project()
    const taskId = await startTask(dir)
    const { TaskService } = await import('@orbit/core')
    const service = await TaskService.open(join(dir, '.orbit', 'tasks', taskId))
    // Rewrite the durable state with refs through the public start path is not
    // available here; use a fresh task started directly by the core.
    const projectRoot = await mkdtemp(join(tmpdir(), 'orbit-refs-cli-'))
    const started = await TaskService.start({
      projectRoot,
      rootSessionId: 'root-ref',
      instruction: 'work',
      externalRefs: ['loom:run-42'],
    })
    void service

    const sink = capture()
    expect(await runCli(['status', '--external-ref', 'loom:run-42', '--json', '--project', projectRoot], sink.io)).toBe(0)
    const payload = JSON.parse(sink.out()) as { tasks: Array<{ taskId: string; externalRefs: string[] }> }
    expect(payload.tasks).toHaveLength(1)
    expect(payload.tasks[0]).toMatchObject({ taskId: started.state.id, externalRefs: ['loom:run-42'] })

    const empty = capture()
    expect(await runCli(['status', '--external-ref', 'missing', '--json', '--project', projectRoot], empty.io)).toBe(0)
    expect(JSON.parse(empty.out())).toEqual({ tasks: [] })
  })
})

describe('orbit-ts launch bootstrap', () => {
  it('passes a frozen headless spec through env with a digest', async () => {
    const dir = await project()
    const specPath = join(dir, 'task.json')
    await writeFile(specPath, JSON.stringify({ version: 1, instruction: 'work', project: dir, model: { provider: 'p', model: 'm' } }))
    const sink = capture()
    expect(
      await runCli(['launch', '--json', '--project', dir, '--bootstrap', specPath, '--result', join(dir, 'result.json')], sink.io),
    ).toBe(0)
    const spec = JSON.parse(sink.out()) as { env: Record<string, string>; bootstrap: { path: string; result: string; sha256: string } }
    expect(spec.bootstrap).toMatchObject({ path: specPath, result: join(dir, 'result.json') })
    expect(spec.bootstrap.sha256).toMatch(/^[0-9a-f]{64}$/)
    expect(spec.env.ORBIT_BOOTSTRAP).toBe(specPath)
    expect(spec.env.ORBIT_BOOTSTRAP_RESULT).toBe(join(dir, 'result.json'))
  })
})

describe('orbit-ts prompt and abort', () => {
  it('sends a prompt through the live host', async () => {
    const dir = await project()
    await fakeControl(dir, () => ({ ok: true, accepted: true, taskId: 'task-1', messageId: 'message-1' }))
    const sink = capture()
    expect(await runCli(['prompt', '--project', dir, '--message', 'continue'], sink.io)).toBe(0)
    expect(sink.out()).toContain('message-1')
  })

  it('aborts the bound session through the live host', async () => {
    const dir = await project()
    await fakeControl(dir, () => ({ ok: true, taskId: 'task-1', scope: 'session', aborted: true }))
    const sink = capture()
    expect(await runCli(['abort', '--project', dir], sink.io)).toBe(0)
    expect(sink.out()).toContain('session')
  })
})

describe('orbit-ts doctor', () => {
  it('reports a healthy isolated profile and a missing bundle', async () => {
    const home = await project()
    const profile = join(home, 'profiles', 'orbit-app')
    await mkdir(join(profile, 'node_modules', '@zeen', 'orbit', 'dist'), { recursive: true })
    await writeFile(join(profile, 'package.json'), JSON.stringify({ dsh: { profile: { bundles: ['@zeen/orbit'] } } }))
    await writeFile(join(profile, 'node_modules', '@zeen', 'orbit', 'dist', 'host.mjs'), '')
    const bin = join(home, 'dsh')
    await writeFile(bin, '#!/bin/sh\necho 0.2.1-rc.2\n', { mode: 0o755 })
    const previous = process.env.DSH_BIN
    process.env.DSH_BIN = bin
    try {
      const sink = capture()
      expect(await runCli(['doctor', '--json', '--home', home, '--profile', 'orbit-app'], sink.io)).toBe(0)
      expect(JSON.parse(sink.out())).toMatchObject({ ok: true, profile: 'orbit-app', dsh: { version: '0.2.1-rc.2' } })

      await writeFile(join(profile, 'package.json'), JSON.stringify({ dsh: { profile: { bundles: [] } } }))
      const bad = capture()
      expect(await runCli(['doctor', '--json', '--home', home, '--profile', 'orbit-app'], bad.io)).toBe(1)
      expect(JSON.parse(bad.out())).toMatchObject({ ok: false })
    } finally {
      if (previous === undefined) delete process.env.DSH_BIN
      else process.env.DSH_BIN = previous
    }
  })
})
