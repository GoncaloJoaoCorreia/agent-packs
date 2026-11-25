// Maps the ACP agent's session/request_permission onto OpenCode permission actions.
//
// The agent names what kind of thing a tool does (`kind`: edit/execute/read/search/fetch/...),
// and that maps onto the actions OpenCode's permission rules are written for, so a rule that
// asks before edits also asks before the agent's edits. Plan mode and deny rules then apply to
// what the agent asks about.
//
// Limit (verified in the M1 spike): anything the Vibe CLI's own session mode auto-approves
// never reaches session/request_permission. The session manager therefore sets mode "ask" on
// every new ACP session so every tool call is asked about (cf. anomalyco/opencode#53530).

import type { RequestPermissionRequest, ToolCallUpdate } from "./acp.ts"

export const ACTIONS: Record<string, string> = {
  read: "read",
  search: "grep",
  edit: "edit",
  delete: "edit",
  move: "edit",
  execute: "bash",
  fetch: "webfetch",
}

export interface PermissionCheck {
  sessionID: string
  agent?: string
  action: string
  resources: readonly string[]
  metadata: Record<string, unknown>
}

export interface TrackedToolCall {
  toolCallId: string
  kind?: string
  title?: string
  rawInput?: unknown
  locations?: { path: string }[]
}

/** The OpenCode permission a request asks for, derived from the tracked tool call. */
export function toPermission(check: {
  sessionID: string
  agent?: string
  request: RequestPermissionRequest
  call: TrackedToolCall | undefined
}): PermissionCheck {
  const call = check.call
  const kind = call?.kind ?? (check.request.toolCall as { kind?: string }).kind ?? "other"
  const action = ACTIONS[kind] ?? "vibe"
  const paths = (call?.locations ?? []).map((location) => location.path).filter((path) => path.length > 0)
  const command = kind === "execute" ? commandOf(call?.rawInput ?? check.request.toolCall) : undefined
  const resources =
    paths.length > 0 ? paths : command !== undefined ? [command] : call?.title ? [call.title] : ["*"]
  return {
    sessionID: check.sessionID,
    agent: check.agent,
    action,
    resources,
    metadata: { title: call?.title, kind, rawInput: call?.rawInput ?? check.request.toolCall },
  }
}

function commandOf(input: unknown): string | undefined {
  if (typeof input !== "object" || input === null) return undefined
  const command = (input as { command?: unknown }).command
  if (typeof command === "string" && command.length > 0) return command
  if (Array.isArray(command) && command.every((part) => typeof part === "string")) return command.join(" ")
  return undefined
}

/** Convenience for tests and for the session manager: turn a raw tool_call update into a tracked call. */
export function trackToolCall(update: ToolCallUpdate): TrackedToolCall {
  return {
    toolCallId: update.toolCallId,
    kind: update.kind ?? undefined,
    title: update.title ?? undefined,
    rawInput: update.rawInput,
    locations: update.locations,
  }
}
