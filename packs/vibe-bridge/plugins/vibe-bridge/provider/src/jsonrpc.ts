// Minimal newline-delimited JSON-RPC 2.0 connection over stdio streams — no dependencies,
// so the provider package loads in any OpenCode runtime (node/bun; the ACP client itself is
// stubbed on workerd, see index.ts). ACP speaks exactly this framing on stdio.

export interface JsonRpcRequest {
  jsonrpc: "2.0"
  id: number | string
  method: string
  params?: unknown
}

export interface JsonRpcNotification {
  jsonrpc: "2.0"
  method: string
  params?: unknown
}

export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | {
  jsonrpc: "2.0"
  id: number | string
  result?: unknown
  error?: { code: number; message: string; data?: unknown }
}

export interface StreamTransport {
  /** Writable side: raw bytes to the peer's stdin. */
  write(chunk: Uint8Array): void
  /** Readable side: raw bytes from the peer's stdout. */
  read(onChunk: (chunk: Uint8Array) => void): void
  close(): void
}

export type RequestHandler = (params: unknown, id: number | string) => unknown | Promise<unknown>
export type NotificationHandler = (params: unknown) => void

export class JsonRpcConnection {
  private nextId = 1
  private readonly pending = new Map<number | string, { resolve: (v: unknown) => void; reject: (e: Error) => void }>()
  private readonly requestHandlers = new Map<string, RequestHandler>()
  private readonly notificationHandlers = new Map<string, NotificationHandler>()
  private buffer = ""
  private closed = false
  readonly onClose: Promise<void>
  private closeResolve!: () => void
  private readonly transport: StreamTransport

  constructor(transport: StreamTransport) {
    this.transport = transport
    this.onClose = new Promise((resolve) => {
      this.closeResolve = resolve
    })
    transport.read((chunk) => this.feed(chunk))
  }

  /** Handle a peer request (a message with both `id` and `method`). */
  onRequest(method: string, handler: RequestHandler): void {
    this.requestHandlers.set(method, handler)
  }

  /** Handle a peer notification (a message with `method` but no `id`). */
  onNotification(method: string, handler: NotificationHandler): void {
    this.notificationHandlers.set(method, handler)
  }

  request<T = unknown>(method: string, params?: unknown): Promise<T> {
    if (this.closed) return Promise.reject(new Error(`connection closed (${method})`))
    const id = this.nextId++
    const message: JsonRpcRequest = { jsonrpc: "2.0", id, method, params }
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, {
        resolve: (v) => resolve(v as T),
        reject,
      })
      try {
        this.send(message)
      } catch (error) {
        this.pending.delete(id)
        reject(error instanceof Error ? error : new Error(String(error)))
      }
    })
  }

  notify(method: string, params?: unknown): void {
    if (this.closed) return
    this.send({ jsonrpc: "2.0", method, params } satisfies JsonRpcNotification)
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    for (const { reject } of this.pending.values()) reject(new Error("connection closed"))
    this.pending.clear()
    try {
      this.transport.close()
    } finally {
      this.closeResolve()
    }
  }

  private send(message: JsonRpcMessage): void {
    this.transport.write(new TextEncoder().encode(JSON.stringify(message) + "\n"))
  }

  private feed(chunk: Uint8Array): void {
    this.buffer += new TextDecoder().decode(chunk)
    let index: number
    while ((index = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, index).trim()
      this.buffer = this.buffer.slice(index + 1)
      if (line.length === 0) continue
      let message: JsonRpcMessage
      try {
        message = JSON.parse(line) as JsonRpcMessage
      } catch {
        continue // not JSON — ignore (should not happen on ACP stdio)
      }
      void this.dispatch(message)
    }
  }

  private async dispatch(message: JsonRpcMessage): Promise<void> {
    if ("method" in message && message.method !== undefined) {
      if ("id" in message && message.id !== undefined) {
        // peer request — answer it
        const handler = this.requestHandlers.get(message.method)
        if (!handler) {
          this.send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `method not found: ${message.method}` } })
          return
        }
        try {
          const result = await handler(message.params, message.id)
          this.send({ jsonrpc: "2.0", id: message.id, result: result === undefined ? null : result })
        } catch (error) {
          this.send({
            jsonrpc: "2.0",
            id: message.id,
            error: { code: -32603, message: error instanceof Error ? error.message : String(error) },
          })
        }
        return
      }
      // notification
      this.notificationHandlers.get(message.method)?.(message.params)
      return
    }
    // response to one of our requests
    if ("id" in message && message.id !== undefined) {
      const pending = this.pending.get(message.id)
      if (!pending) return
      this.pending.delete(message.id)
      if ("error" in message && message.error) {
        pending.reject(new Error(`JSON-RPC error ${message.error.code}: ${message.error.message}`))
      } else {
        pending.resolve("result" in message ? message.result : null)
      }
    }
  }
}
