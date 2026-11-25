// ACP (Agent Client Protocol v1) wire types — only the surface `vibe-acp` actually uses.
// ACP is newline-delimited JSON-RPC 2.0 over stdio.

export interface Implementation {
  name: string
  title?: string
  version: string
}

export interface InitializeResponse {
  protocolVersion: number
  agentCapabilities?: {
    loadSession?: boolean
    promptCapabilities?: { audio?: boolean; embeddedContext?: boolean; image?: boolean }
    sessionCapabilities?: Record<string, unknown>
  }
  agentInfo?: Implementation
  authMethods?: unknown[]
}

export interface ConfigSelectOption {
  id: string
  name?: string
  category?: string
  type?: string
  currentValue?: string
  options?: { value: string; name?: string; description?: string }[]
}

export interface NewSessionResponse {
  sessionId: string
  modes?: { currentModeId?: string; availableModes?: { id: string; name?: string }[] }
  configOptions?: ConfigSelectOption[]
}

export interface PromptResponse {
  stopReason: string
  usage?: {
    totalTokens?: number
    inputTokens?: number
    outputTokens?: number
    cachedReadTokens?: number
    thoughtTokens?: number
  }
}

export interface ToolCallLocation {
  path: string
}

export interface ToolCallUpdate {
  sessionUpdate: "tool_call" | "tool_call_update"
  toolCallId: string
  title?: string | null
  kind?: string
  status?: string
  content?: unknown[]
  locations?: ToolCallLocation[]
  rawInput?: unknown
  rawOutput?: unknown
  _meta?: { tool_name?: string }
}

export type SessionUpdate =
  | { sessionUpdate: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk"; content?: { type: string; text?: string } }
  | ToolCallUpdate
  | { sessionUpdate: string; [key: string]: unknown }

export interface SessionUpdateNotification {
  sessionId: string
  update: SessionUpdate
}

export interface PermissionOption {
  optionId: string
  name?: string
  kind: string
}

export interface RequestPermissionRequest {
  sessionId: string
  toolCall: { toolCallId: string } & Record<string, unknown>
  options: PermissionOption[]
}

export type RequestPermissionResponse =
  | { outcome: { outcome: "selected"; optionId: string } }
  | { outcome: { outcome: "cancelled" } }

/** The models the CLI reports: `configOptions` select with category "model". */
export interface DiscoveredModel {
  /** The ACP config value (alias), e.g. "mistral-large-4-0". This is the OpenCode model id. */
  id: string
  name: string
  description?: string
}

/** Effort levels come from the "thinking" select, not from model names. */
export interface DiscoveredThinking {
  current?: string
  levels: string[]
}

export interface DiscoveredCatalog {
  models: DiscoveredModel[]
  thinking: DiscoveredThinking
  modes: { current?: string; available: string[] }
}
