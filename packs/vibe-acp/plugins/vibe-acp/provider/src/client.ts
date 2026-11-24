// Owns the `vibe-acp` child process and speaks ACP v1 to it over stdio.
// Spawned lazily by the session manager; one process per OpenCode server.

import { spawn, type ChildProcess } from "node:child_process"
import { JsonRpcConnection, type StreamTransport } from "./jsonrpc.ts"
import type {
  DiscoveredCatalog,
  InitializeResponse,
  NewSessionResponse,
  PromptResponse,
  RequestPermissionRequest,
  RequestPermissionResponse,
  SessionUpdate,
  SessionUpdateNotification,
} from "./acp.ts"

export interface AcpClientOptions {
  /** Directory the ACP sessions run in (the OpenCode project directory). */
  cwd: string
  /** CLI to run. Default "vibe-acp"; "vibe acp" is tried as a fallback by resolveCommand. */
  command?: string
  args?: string[]
  env?: Record<string, string>
  clientInfo?: { name: string; version: string }
  /** Answers the agent's session/request_permission. Without one, every request is refused. */
  permission?: (request: RequestPermissionRequest) => Promise<RequestPermissionResponse> | RequestPermissionResponse
  /** Stream of session updates, keyed by session id. */
  onUpdate?: (sessionId: string, update: SessionUpdate) => void
  onStderr?: (line: string) => void
  /** Injectable for tests. */
  spawnProcess?: (command: string, args: string[], options: { cwd: string; env: Record<string, string> }) => ChildProcess
}

export interface AcpSessionInfo {
  sessionId: string
  catalog: DiscoveredCatalog
}

export class AcpClient {
  private readonly listeners = new Map<string, (update: SessionUpdate) => void>()
  private readonly child: ChildProcess
  private readonly connection: JsonRpcConnection
  readonly agentInfo: { name: string; version: string }
  readonly closed: Promise<void>
  private readonly onUpdate?: (sessionId: string, update: SessionUpdate) => void

  private constructor(
    child: ChildProcess,
    connection: JsonRpcConnection,
    agentInfo: { name: string; version: string },
    closed: Promise<void>,
    onUpdate?: (sessionId: string, update: SessionUpdate) => void,
  ) {
    this.child = child
    this.connection = connection
    this.agentInfo = agentInfo
    this.closed = closed
    this.onUpdate = onUpdate
  }

  static async start(options: AcpClientOptions): Promise<AcpClient> {
    const command = options.command ?? "vibe-acp"
    const args = options.args ?? []
    const spawnProcess =
      options.spawnProcess ??
      ((cmd: string, cmdArgs: string[], opts: { cwd: string; env: Record<string, string> }) =>
        spawn(cmd, cmdArgs, { cwd: opts.cwd, env: { ...process.env, ...opts.env }, stdio: ["pipe", "pipe", "pipe"] }))
    const child = spawnProcess(command, args, { cwd: options.cwd, env: options.env ?? {} })
    const closed = new Promise<void>((resolve) => {
      if (child.exitCode !== null || child.signalCode !== null) return resolve()
      child.once("exit", () => resolve())
      child.once("error", () => resolve())
    })
    // stderr is drained so a full pipe never blocks the CLI.
    let stderrBuffer = ""
    child.stderr?.on("data", (chunk: Buffer) => {
      stderrBuffer += chunk.toString()
      let index: number
      while ((index = stderrBuffer.indexOf("\n")) >= 0) {
        const line = stderrBuffer.slice(0, index)
        stderrBuffer = stderrBuffer.slice(index + 1)
        options.onStderr?.(line)
      }
    })
    if (!child.stdin || !child.stdout) throw new Error(`${command} did not provide stdio pipes`)
    const transport: StreamTransport = {
      write: (chunk) => child.stdin!.write(chunk),
      read: (onChunk) => child.stdout!.on("data", onChunk),
      close: () => {
        child.stdin?.end()
        child.kill("SIGTERM")
      },
    }
    const connection = new JsonRpcConnection(transport)
    const routeUpdate = (params: unknown): void => {
      const p = params as SessionUpdateNotification
      // Always notify the default handler (the session manager tracks tool calls there for
      // permission mapping), and the per-prompt listener when one is registered.
      options.onUpdate?.(p.sessionId, p.update)
      client?.listeners.get(p.sessionId)?.(p.update)
    }
    connection.onNotification("session/update", routeUpdate)
    let client: AcpClient | undefined
    connection.onRequest("session/request_permission", (params) => {
      const request = params as RequestPermissionRequest
      if (!options.permission) return refuse(request)
      return options.permission(request)
    })
    let initialize: InitializeResponse
    try {
      initialize = await connection.request<InitializeResponse>("initialize", {
        protocolVersion: 1,
        clientCapabilities: {},
        clientInfo: options.clientInfo ?? { name: "opencode", version: "0.0.0" },
      })
    } catch (error) {
      connection.close()
      throw new Error(`could not initialize ACP session with ${command}: ${error instanceof Error ? error.message : String(error)}`)
    }
    client = new AcpClient(
      child,
      connection,
      {
        name: initialize.agentInfo?.name ?? command,
        version: initialize.agentInfo?.version ?? "unknown",
      },
      closed.then(() => connection.close()),
      options.onUpdate,
    )
    return client
  }

  /** session/new — the response carries the model catalog in `configOptions`. */
  async newSession(cwd: string): Promise<AcpSessionInfo> {
    const response = await this.connection.request<NewSessionResponse>("session/new", { cwd, mcpServers: [] })
    return { sessionId: response.sessionId, catalog: catalogOf(response) }
  }

  async setSessionMode(sessionId: string, modeId: string): Promise<void> {
    // ACP v1 method name (the SDK calls it setSessionMode but the wire method is session/set_mode)
    await this.connection.request("session/set_mode", { sessionId, modeId })
  }

  async setSessionConfigOption(sessionId: string, configId: string, value: string): Promise<void> {
    await this.connection.request("session/set_config_option", { sessionId, configId, value })
  }

  /**
   * One turn. Updates stream through `onUpdate` until the prompt resolves.
   * `signal` aborts the turn by sending session/cancel, per the protocol.
   */
  async prompt(
    sessionId: string,
    text: string,
    onUpdate: ((update: SessionUpdate) => void) | undefined,
    signal?: AbortSignal,
  ): Promise<PromptResponse> {
    if (onUpdate) this.listeners.set(sessionId, onUpdate)
    try {
      const cancelled = signal
        ? new Promise<never>((_resolve, reject) => {
            const onAbort = () => {
              this.connection.notify("session/cancel", { sessionId })
              reject(new Error("turn cancelled"))
            }
            if (signal.aborted) onAbort()
            else signal.addEventListener("abort", onAbort, { once: true })
          })
        : undefined
      const died = this.closed.then((): never => {
        throw new Error("vibe-acp exited during the turn")
      })
      return await Promise.race([
        this.connection.request<PromptResponse>("session/prompt", {
          sessionId,
          prompt: [{ type: "text", text }],
        }),
        died,
        ...(cancelled ? [cancelled] : []),
      ])
    } finally {
      if (onUpdate) this.listeners.delete(sessionId)
    }
  }

  async cancel(sessionId: string): Promise<void> {
    this.connection.notify("session/cancel", { sessionId })
  }

  async closeSession(sessionId: string): Promise<void> {
    await this.connection.request("session/close", { sessionId }).catch(() => {})
  }

  async close(): Promise<void> {
    this.connection.close()
    await this.closed.catch(() => {})
  }
}

/** Refuse a permission request by picking reject_once, else cancel — the agent may not act. */
export function refuse(request: RequestPermissionRequest): RequestPermissionResponse {
  const reject = request.options.find((option) => option.kind === "reject_once")
  return reject
    ? { outcome: { outcome: "selected", optionId: reject.optionId } }
    : { outcome: { outcome: "cancelled" } }
}

/** Pick allow_once / reject_once from the agent's offered options. */
export function choose(request: RequestPermissionRequest, allowed: boolean): RequestPermissionResponse {
  const kinds = allowed ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
  for (const kind of kinds) {
    const option = request.options.find((candidate) => candidate.kind === kind)
    if (option) return { outcome: { outcome: "selected", optionId: option.optionId } }
  }
  return { outcome: { outcome: "cancelled" } }
}

/** Read the model catalog out of a session/new response's configOptions. */
export function catalogOf(response: NewSessionResponse): DiscoveredCatalog {
  const options = response.configOptions ?? []
  const model = options.find((c) => c.category === "model" || c.id === "model")
  const thinking = options.find((c) => c.category === "thinking" || c.id === "thinking")
  const mode = options.find((c) => c.category === "mode" || c.id === "mode")
  return {
    models: (model?.options ?? []).map((o) => ({ id: o.value, name: o.name ?? o.value, description: o.description })),
    thinking: { current: thinking?.currentValue, levels: (thinking?.options ?? []).map((o) => o.value) },
    modes: {
      current: response.modes?.currentModeId ?? mode?.currentValue,
      available: (response.modes?.availableModes ?? mode?.options ?? []).map((m) => m.id ?? m.value),
    },
  }
}
