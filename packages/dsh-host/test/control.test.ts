import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { connect } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { ControlServer } from '../src/control.js'

const dirs: string[] = []

async function socketPath(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'orbit-sock-'))
  dirs.push(dir)
  return join(dir, 'orbit.sock')
}

function exchange(path: string, line: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect(path)
    let buffer = ''
    socket.setEncoding('utf8')
    socket.once('connect', () => socket.write(`${line}\n`))
    socket.on('data', (chunk: string) => {
      buffer += chunk
      const index = buffer.indexOf('\n')
      if (index >= 0) {
        socket.destroy()
        resolve(buffer.slice(0, index))
      }
    })
    socket.once('error', reject)
  })
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('control server', () => {
  it('answers one newline-delimited JSON request', async () => {
    const path = await socketPath()
    const server = new ControlServer(path, async (request) => ({ method: request.method, task: request.task ?? null }))
    await server.start()
    try {
      const line = await exchange(path, JSON.stringify({ id: 'r1', method: 'status', task: 'task-1' }))
      expect(JSON.parse(line)).toEqual({ id: 'r1', ok: true, result: { method: 'status', task: 'task-1' } })
    } finally {
      await server.close()
    }
  })

  it('forwards prompt and answer payload fields', async () => {
    const path = await socketPath()
    const server = new ControlServer(path, async (request) => ({
      message: request.message ?? null,
      question: request.question ?? null,
      selected: request.selected ?? null,
      custom: request.custom ?? null,
    }))
    await server.start()
    try {
      const line = await exchange(
        path,
        JSON.stringify({ id: 'r2', method: 'prompt', message: 'go', question: 'q1', selected: ['a'], custom: 'x' }),
      )
      expect(JSON.parse(line)).toMatchObject({
        ok: true,
        result: { message: 'go', question: 'q1', selected: ['a'], custom: 'x' },
      })
    } finally {
      await server.close()
    }
  })

  it('returns a structured error for a malformed request', async () => {
    const path = await socketPath()
    const server = new ControlServer(path, async () => ({}))
    await server.start()
    try {
      const line = await exchange(path, JSON.stringify({ id: 'r2' }))
      const response = JSON.parse(line) as { id: string; ok: boolean; error: { message: string } }
      expect(response).toMatchObject({ id: 'r2', ok: false })
      expect(response.error.message).toContain('method')
    } finally {
      await server.close()
    }
  })

  it('reclaims a stale socket file but refuses a live one', async () => {
    const path = await socketPath()
    const first = new ControlServer(path, async () => ({ ok: true }))
    await first.start()
    const second = new ControlServer(path, async () => ({ ok: true }))
    await expect(second.start()).rejects.toThrow(/already in use/)
    await first.close()
    const third = new ControlServer(path, async () => ({ ok: true }))
    await third.start()
    await third.close()
  })
})
