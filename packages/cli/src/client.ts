import { connect } from 'node:net'
import { CONTROL_MAX_BYTES, isControlResponse, type ControlRequest, type ControlResponse } from '@orbit/core'

/**
 * Send one newline-delimited JSON request to the project's private control
 * socket and wait for the matching reply.
 */
export async function requestControl(socketPath: string, request: ControlRequest, timeoutMs = 3_000): Promise<ControlResponse> {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath)
    let buffer = ''
    let settled = false
    const finish = (error: Error | undefined, response?: ControlResponse): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      if (error !== undefined) reject(error)
      else if (response !== undefined) resolve(response)
      else reject(new Error('control socket closed without a response'))
    }
    const timer = setTimeout(() => finish(new Error('control socket request timed out')), timeoutMs)
    socket.setEncoding('utf8')
    socket.once('connect', () => {
      socket.write(`${JSON.stringify(request)}\n`)
    })
    socket.on('data', (chunk: string) => {
      buffer += chunk
      if (buffer.length > CONTROL_MAX_BYTES) {
        finish(new Error('control response exceeded the size bound'))
        return
      }
      const index = buffer.indexOf('\n')
      if (index < 0) return
      const line = buffer.slice(0, index)
      try {
        const parsed: unknown = JSON.parse(line)
        if (!isControlResponse(parsed)) throw new Error('malformed control response')
        if (parsed.id !== request.id) throw new Error(`control response id mismatch: ${parsed.id}`)
        finish(undefined, parsed)
      } catch (error) {
        finish(error as Error)
      }
    })
    socket.once('error', (error) => finish(error))
    socket.once('close', () => finish(new Error('control socket closed without a response')))
  })
}
