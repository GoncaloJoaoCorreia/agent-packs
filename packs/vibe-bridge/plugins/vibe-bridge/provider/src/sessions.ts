// One `vibe-acp` process per OpenCode server; one ACP session per OpenCode session, so sessions
// never continue each other's conversation. Turns inside a conversation are serialized;
// auxiliary requests (title/generate/compaction) get a throwaway session. A dead CLI is
// replaced on the next turn. Permission requests are answered from the tracked tool call via
// the `assert` hook (wired to OpenCode's permission rules by the plugin), defaulting to refuse.

import { choose, refuse, type AcpSessionInfo } from "./protocol.ts"
import type { AcpClientOptions } from "./client.ts"

import type {
  DiscoveredCatalog,
  DiscoveredModel,
  RequestPermissionRequest,
  RequestPermissionResponse,
  SessionUpdate,
  ToolCallUpdate,
} from "./acp.ts"
import { toPermission, trackToolCall, type PermissionCheck, type TrackedToolCall } from "./permissions.ts"

export interface Turn {
  stopReason: string
  usage?: {
    totalTokens?: number
    inputTokens?: number
    outputTokens?: number
    cachedReadTokens?: number
    thoughtTokens?: number
  }
}

export interface RunRequest {
  /** OpenCode session id (from the x-opencode-session-id header). Undefined = throwaway. */
  sessionID?: string
  /** The OpenCode agent running the turn — its permission rules apply. */
  agent?: string
  /** "primary" continues the conversation; anything else gets a throwaway session. */
  kind?: string
  /** OpenCode model id = the ACP model alias. */
  model: string
  /** Effort level (the ACP "thinking" config), when a variant picked one. */
  thinking?: string
  prompt: string
}

export interface SessionManagerOptions {
  directory: string
  client?: Partial<AcpClientOptions>
  /** Injectable connection for tests. */
  connect?: (options: AcpClientOptions) => Promise<ClientLike>
  /** Asks OpenCode whether the agent may act. Resolves true when allowed. */
  assert?: (check: PermissionCheck) => Promise<boolean>
  /** Called when the CLI reports a model catalog that differs from the known one. */
  onModels?: (catalog: DiscoveredCatalog) => void
  initialCatalog?: DiscoveredCatalog
}

export interface ClientLike {
  readonly closed: Promise<void>
  newSession(cwd: string): Promise<AcpSessionInfo>
  setSessionMode(sessionId: string, modeId: string): Promise<void>
  setSessionConfigOption(sessionId: string, configId: string, value: string): Promise<void>
  prompt(
    sessionId: string,
    text: string,
    onUpdate: ((update: SessionUpdate) => void) | undefined,
    signal?: AbortSignal,
  ): Promise<Turn>
  closeSession(sessionId: string): Promise<void>
  close(): Promise<void>
}

interface Conversation {
  sessionId: string
  config: { model?: string; thinking?: string }
  queue: Promise<unknown>
}

export class SessionManager {
  private client: Promise<ClientLike> | undefined
  private catalog: DiscoveredCatalog
  private readonly conversations = new Map<string, Promise<Conversation>>()
  private readonly owners = new Map<string, { sessionID: string; agent?: string }>()
  private readonly calls = new Map<string, TrackedToolCall>()
  private readonly options: SessionManagerOptions

  constructor(options: SessionManagerOptions) {
    this.options = options
    this.catalog = options.initialCatalog ?? { models: [], thinking: { levels: [] }, modes: { available: [] } }
  }

  get models(): readonly DiscoveredModel[] {
    return this.catalog.models
  }

  /** Lists the models the CLI reports, using a throwaway ACP session. Cached between starts. */
  async discover(): Promise<DiscoveredCatalog> {
    const client = await this.ensure()
    const session = await this.open(client)
    try {
      return this.catalog
    } finally {
      await client.closeSession(session.sessionId).catch(() => {})
    }
  }

  async run(
    request: RunRequest,
    onUpdate: (update: SessionUpdate) => void,
    signal: AbortSignal,
  ): Promise<Turn> {
    const client = await this.ensure()
    if (request.sessionID === undefined || (request.kind !== undefined && request.kind !== "primary")) {
      // Auxiliary request: throwaway conversation, closed afterwards; nobody approves its tools.
      const session = await this.open(client)
      try {
        return await this.turn(client, { sessionId: session.sessionId, config: {}, queue: Promise.resolve() }, request, onUpdate, signal)
      } finally {
        await client.closeSession(session.sessionId).catch(() => {})
      }
    }
    const conversation = await this.conversation(client, request.sessionID)
    const result = conversation.queue.then(() => {
      this.owners.set(conversation.sessionId, { sessionID: request.sessionID!, agent: request.agent })
      return this.turn(client, conversation, request, onUpdate, signal)
    })
    conversation.queue = result.catch(() => {})
    return result
  }

  /** Closes the ACP session of a deleted OpenCode session. */
  async remove(sessionID: string): Promise<void> {
    const existing = this.conversations.get(sessionID)
    if (!existing) return
    this.conversations.delete(sessionID)
    const conversation = await existing.catch(() => undefined)
    if (!conversation) return
    this.owners.delete(conversation.sessionId)
    const client = await this.client?.catch(() => undefined)
    await client?.closeSession(conversation.sessionId).catch(() => {})
  }

  async close(): Promise<void> {
    const current = this.client
    this.client = undefined
    this.conversations.clear()
    this.owners.clear()
    this.calls.clear()
    const client = await current?.catch(() => undefined)
    await client?.close().catch(() => {})
  }

  private ensure(): Promise<ClientLike> {
    if (this.client) return this.client
    const options: AcpClientOptions = {
      cwd: this.options.directory,
      ...this.options.client,
      permission: (request) => this.permit(request),
      onUpdate: (sessionId, update) => {
        if (update.sessionUpdate === "tool_call" || update.sessionUpdate === "tool_call_update") {
          const tracked = trackToolCall(update as ToolCallUpdate)
          this.calls.set(tracked.toolCallId, { ...this.calls.get(tracked.toolCallId), ...tracked })
        }
      },
    }
    // The process-spawning client is imported lazily: on runtimes without child processes
    // (workerd/console) the pack stays loaded and simply cannot spawn the CLI.
    const started = (this.options.connect ?? (async (o) => (await import("./client.ts")).AcpClient.start(o)))(options)
    this.client = started
    started.then(
      (client) => client.closed.then(() => this.forget(started)),
      () => this.forget(started),
    )
    return started
  }

  private forget(stale: Promise<ClientLike>): void {
    if (this.client !== stale) return
    this.client = undefined
    this.conversations.clear()
    this.owners.clear()
  }

  private async open(client: ClientLike): Promise<AcpSessionInfo> {
    const session = await client.newSession(this.options.directory)
    const reported = session.catalog
    if (reported.models.length > 0 && JSON.stringify(reported) !== JSON.stringify(this.catalog)) {
      this.catalog = reported
      this.options.onModels?.(reported)
    }
    // Ask before every tool call — the CLI's own auto-approve modes would bypass OpenCode's rules.
    const ask = reported.modes.available.includes("ask") ? "ask" : reported.modes.available[0]
    if (ask) await client.setSessionMode(session.sessionId, ask).catch(() => {})
    return session
  }

  private async conversation(client: ClientLike, sessionID: string): Promise<Conversation> {
    const existing = this.conversations.get(sessionID)
    if (existing) return existing
    const opened = this.open(client).then((session): Conversation => ({
      sessionId: session.sessionId,
      config: {},
      queue: Promise.resolve(),
    }))
    this.conversations.set(sessionID, opened)
    opened.catch(() => {
      if (this.conversations.get(sessionID) === opened) this.conversations.delete(sessionID)
    })
    return opened
  }

  private async turn(
    client: ClientLike,
    conversation: Conversation,
    request: RunRequest,
    onUpdate: (update: SessionUpdate) => void,
    signal: AbortSignal,
  ): Promise<Turn> {
    // Set model/thinking only when the selection changed.
    if (request.model !== conversation.config.model) {
      await client.setSessionConfigOption(conversation.sessionId, "model", request.model)
      conversation.config.model = request.model
    }
    if (request.thinking !== undefined && request.thinking !== conversation.config.thinking) {
      await client.setSessionConfigOption(conversation.sessionId, "thinking", request.thinking)
      conversation.config.thinking = request.thinking
    }
    return client.prompt(conversation.sessionId, request.prompt, onUpdate, signal)
  }

  private async permit(request: RequestPermissionRequest): Promise<RequestPermissionResponse> {
    const owner = this.owners.get(request.sessionId)
    const call = this.calls.get(request.toolCall.toolCallId)
    if (!owner || !this.options.assert) return refuse(request)
    const allowed = await this.options
      .assert(toPermission({ sessionID: owner.sessionID, agent: owner.agent, request, call }))
      .catch(() => false)
    return choose(request, allowed)
  }
}
