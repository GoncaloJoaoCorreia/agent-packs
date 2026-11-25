// The AI SDK LanguageModelV3 the provider package hands to OpenCode (via the `aisdk:` package
// bridge). doStream drives one ACP turn and renders the updates into stream parts.
//
// OpenCode names the session/agent/kind of every request in headers (set by the pack's plugin
// through the session "model.request" hook): x-opencode-session-id, x-opencode-vibe-agent,
// x-opencode-vibe-kind.

import type { LanguageModelV3, LanguageModelV3CallOptions, LanguageModelV3StreamPart } from "@ai-sdk/provider"
import type { SessionManager, Turn } from "./sessions.ts"
import type { SessionUpdate } from "./acp.ts"
import { finishReason, makeRenderer, usageOf, type StreamPart } from "./renderer.ts"

export const SESSION_HEADER = "x-opencode-session-id"
export const AGENT_HEADER = "x-opencode-vibe-agent"
export const KIND_HEADER = "x-opencode-vibe-kind"

export class VibeAcpLanguageModel implements LanguageModelV3 {
  readonly specificationVersion = "v3"
  readonly provider = "vibe"
  readonly supportedUrls = {}
  readonly modelId: string
  private readonly manager: SessionManager

  constructor(modelId: string, manager: SessionManager) {
    this.modelId = modelId
    this.manager = manager
  }

  async doGenerate(_options: LanguageModelV3CallOptions): Promise<never> {
    throw new Error("vibe ACP models only support streaming")
  }

  async doStream(options: LanguageModelV3CallOptions): Promise<{ stream: ReadableStream<LanguageModelV3StreamPart> }> {
    const abort = new AbortController()
    const signal = options.abortSignal ? AbortSignal.any([abort.signal, options.abortSignal]) : abort.signal
    const headers = options.headers ?? {}
    const providerOptions = (options.providerOptions?.["vibe"] ?? {}) as { thinking?: unknown }
    const renderer = makeRenderer()
    let cancelled = false
    let task: Promise<void> | undefined
    const stream = new ReadableStream<LanguageModelV3StreamPart>({
      start: (controller) => {
        controller.enqueue({ type: "stream-start", warnings: [] } as LanguageModelV3StreamPart)
        const flush = () => {
          for (const part of renderer.end()) controller.enqueue(part as LanguageModelV3StreamPart)
        }
        task = this.manager
          .run(
            {
              sessionID: header(headers, SESSION_HEADER),
              agent: header(headers, AGENT_HEADER),
              kind: header(headers, KIND_HEADER),
              model: this.modelId,
              thinking: typeof providerOptions.thinking === "string" ? providerOptions.thinking : undefined,
              prompt: readPrompt(options),
            },
            (update: SessionUpdate) => {
              if (cancelled) return
              for (const part of renderer.push(update)) controller.enqueue(part as LanguageModelV3StreamPart)
            },
            signal,
          )
          .then(
            (turn: Turn) => {
              if (cancelled) return
              flush()
              controller.enqueue({
                type: "finish",
                usage: usageOf(turn.usage),
                finishReason: finishReason(turn.stopReason),
              } as unknown as LanguageModelV3StreamPart)
              controller.close()
            },
            (error: unknown) => {
              if (cancelled) return
              flush()
              controller.error(error)
            },
          )
      },
      cancel: () => {
        cancelled = true
        abort.abort()
        return task
      },
    })
    return { stream }
  }
}

function header(headers: Record<string, string | string[] | undefined>, name: string): string | undefined {
  const value = headers[name]
  return Array.isArray(value) ? value[0] : value
}

/**
 * The host's system prompt is not forwarded: it describes OpenCode's tools, which the ACP agent
 * does not have — the agent reads the project's instruction files itself. Only the last user
 * text is sent as the turn.
 */
export function readPrompt(options: LanguageModelV3CallOptions): string {
  for (let index = options.prompt.length - 1; index >= 0; index -= 1) {
    const message = options.prompt[index]
    if (message.role !== "user") continue
    const parts = message.content
      .filter((part) => part.type === "text")
      .map((part) => part.text)
      .filter((text) => text.length > 0)
    const text = parts.join("\n")
    if (text.length > 0) return text
  }
  return "[continue]"
}

export type { StreamPart }
