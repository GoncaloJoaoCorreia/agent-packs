// Translates ACP session updates into AI SDK LanguageModelV3 stream parts.
//
// vibe-acp sends `tool_call` and every `tool_call_update` twice (observed in the M1 spike), and
// OpenCode aborts a turn on duplicate tool-call ids (the bug anomalyco/opencode#65489 hit), so a
// call is emitted exactly once — with its result — when it reaches completed/failed.

import type { SessionUpdate, ToolCallUpdate } from "./acp.ts"

export interface StreamPart {
  type: string
  [key: string]: unknown
}

export interface Renderer {
  push(update: SessionUpdate): StreamPart[]
  /** Settles tool calls still running when the turn ends. */
  end(): StreamPart[]
}

interface Call {
  toolName: string
  input: unknown
  title?: string
  settled: boolean
}

export function makeRenderer(): Renderer {
  const calls = new Map<string, Call>()
  const settle = (id: string, call: Call, status: string, isError: boolean): StreamPart[] => {
    call.settled = true
    return [
      {
        type: "tool-call",
        toolCallId: id,
        toolName: call.toolName,
        input: JSON.stringify(call.input ?? {}),
        providerExecuted: true,
      },
      {
        type: "tool-result",
        toolCallId: id,
        toolName: call.toolName,
        result: { status, title: call.title ?? call.toolName },
        isError,
      },
    ]
  }
  return {
    push: (update) => {
      const kind = update.sessionUpdate
      if (kind === "agent_message_chunk") {
        const text = textOf(update)
        return text === undefined ? [] : [{ type: "text-delta", id: "text", delta: text }]
      }
      if (kind === "agent_thought_chunk") {
        const text = textOf(update)
        return text === undefined ? [] : [{ type: "reasoning-delta", id: "reasoning", delta: text }]
      }
      if (kind === "tool_call" || kind === "tool_call_update") {
        const reported = update as ToolCallUpdate
        let call = calls.get(reported.toolCallId)
        if (!call) {
          call = {
            toolName: reported._meta?.tool_name ?? reported.title ?? "unknown",
            input: reported.rawInput,
            title: reported.title ?? undefined,
            settled: false,
          }
          calls.set(reported.toolCallId, call)
        } else if (!call.settled) {
          if (reported.rawInput !== undefined && reported.rawInput !== null) call.input = reported.rawInput
          if (reported.title) call.title = reported.title
          if (reported._meta?.tool_name) call.toolName = reported._meta.tool_name
        }
        if (call.settled) return [] // duplicate update — never re-emit
        if (reported.status === "completed") return settle(reported.toolCallId, call, "completed", false)
        if (reported.status === "failed") return settle(reported.toolCallId, call, "failed", true)
        return []
      }
      return []
    },
    end: () => [...calls].flatMap(([id, call]) => (call.settled ? [] : settle(id, call, "incomplete", true))),
  }
}

function textOf(update: SessionUpdate): string | undefined {
  const content = (update as { content?: { type: string; text?: string } }).content
  return content?.type === "text" && typeof content.text === "string" ? content.text : undefined
}

/** A turn cut off by its budget, or refused, must not look like a normal finish. */
export function finishReason(stopReason: string): { unified: string; raw: string } {
  const unified =
    stopReason === "end_turn"
      ? "stop"
      : stopReason === "max_tokens" || stopReason === "max_turn_requests"
        ? "length"
        : stopReason === "refusal"
          ? "content-filter"
          : "other"
  return { unified, raw: stopReason }
}

export function usageOf(usage: PromptUsage | undefined): {
  inputTokens: { total: number; noCache: number; cacheRead: number; cacheWrite: number }
  outputTokens: { total: number; text: number; reasoning: number }
} {
  const input = usage?.inputTokens ?? 0
  const cacheRead = usage?.cachedReadTokens ?? 0
  const output = usage?.outputTokens ?? 0
  return {
    inputTokens: {
      total: input,
      noCache: Math.max(0, input - cacheRead),
      cacheRead,
      cacheWrite: 0,
    },
    outputTokens: { total: output, text: output, reasoning: usage?.thoughtTokens ?? 0 },
  }
}

interface PromptUsage {
  totalTokens?: number
  inputTokens?: number
  outputTokens?: number
  cachedReadTokens?: number
  thoughtTokens?: number
}
