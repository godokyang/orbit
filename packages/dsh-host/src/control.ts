import { chmodSync, existsSync, mkdirSync, rmSync } from 'node:fs'
import { createServer, connect, type Server, type Socket } from 'node:net'
import { dirname } from 'node:path'
import { CONTROL_MAX_BYTES, type ControlRequest, type ControlResponse } from '@orbit/core'

export type ControlHandler = (request: ControlRequest) => Promise<unknown>

async function socketAlive(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect(path)
    const done = (value: boolean): void => {
      socket.destroy()
      resolve(value)
    }
    socket.once('connect', () => done(true))
    socket.once('error', () => done(false))
    socket.setTimeout(300, () => done(false))
  })
}

/**
 * Newline-delimited JSON control socket for the thin CLI. One request per
 * line; the reply carries the same id. The socket file is 0600 and lives in
 * the project's private `.orbit` directory.
 */
export class ControlServer {
  private server: Server | undefined
  private readonly sockets = new Set<Socket>()

  constructor(
    readonly path: string,
    private readonly handler: ControlHandler,
  ) {}

  async start(): Promise<void> {
    if (process.platform === 'win32') throw new Error('orbit control socket is not implemented on Windows yet')
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 })
    if (existsSync(this.path)) {
      if (await socketAlive(this.path)) throw new Error(`orbit control socket is already in use: ${this.path}`)
      rmSync(this.path, { force: true })
    }
    const server = createServer((socket) => this.attach(socket))
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error): void => {
        server.off('listening', onListening)
        reject(error)
      }
      const onListening = (): void => {
        server.off('error', onError)
        resolve()
      }
      server.once('error', onError)
      server.once('listening', onListening)
      server.listen(this.path)
    })
    this.server = server
    chmodSync(this.path, 0o600)
  }

  async close(): Promise<void> {
    for (const socket of this.sockets) socket.destroy()
    this.sockets.clear()
    const server = this.server
    this.server = undefined
    if (server !== undefined) {
      await new Promise<void>((resolve) => server.close(() => resolve()))
    }
    rmSync(this.path, { force: true })
  }

  private attach(socket: Socket): void {
    this.sockets.add(socket)
    socket.setEncoding('utf8')
    let buffer = ''
    socket.on('close', () => this.sockets.delete(socket))
    socket.on('error', () => this.sockets.delete(socket))
    socket.on('data', (chunk: string) => {
      buffer += chunk
      if (buffer.length > CONTROL_MAX_BYTES) {
        socket.destroy()
        return
      }
      let index = buffer.indexOf('\n')
      while (index >= 0) {
        const line = buffer.slice(0, index)
        buffer = buffer.slice(index + 1)
        if (line.trim().length > 0) void this.handleLine(line, socket)
        index = buffer.indexOf('\n')
      }
    })
  }

  private async handleLine(line: string, socket: Socket): Promise<void> {
    let id = ''
    let response: ControlResponse
    try {
      const request = JSON.parse(line) as Partial<ControlRequest>
      id = typeof request.id === 'string' ? request.id : ''
      if (typeof request.method !== 'string') throw new Error('request.method must be a string')
      const result = await this.handler({
        id,
        method: request.method as ControlRequest['method'],
        ...(typeof request.task === 'string' ? { task: request.task } : {}),
      })
      response = { id, ok: true, result }
    } catch (error) {
      response = {
        id,
        ok: false,
        error: { code: 'control_error', message: (error as Error).message },
      }
    }
    if (!socket.destroyed) socket.write(`${JSON.stringify(response)}\n`)
  }
}
