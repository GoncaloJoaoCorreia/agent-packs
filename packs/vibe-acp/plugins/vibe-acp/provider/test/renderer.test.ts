// Renderer unit tests: ACP update -> LanguageModelV3 stream part mapping, incl. the
// tool_call + tool_call_update dedupe case (vibe-acp sends each update twice).
import assert from "node:assert/strict"
import { test } from "node:test"
import { finishReason, makeRenderer, usageOf } from "../src/renderer.ts"

test("text and thought chunks map to text/reasoning deltas", () => {
  const r = makeRenderer()
  assert.deepEqual(r.push({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hello" } }), [
    { type: "text-delta", id: "text", delta: "Hello" },
  ])
  assert.deepEqual(r.push({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "thinking" } }), [
    { type: "reasoning-delta", id: "reasoning", delta: "thinking" },
  ])
  assert.deepEqual(r.push({ sessionUpdate: "usage_update" }), [])
})

test("a tool call is emitted once, with its result, on completed — duplicates are dropped", () => {
  const r = makeRenderer()
  const call = { sessionUpdate: "tool_call", toolCallId: "t1", kind: "edit", title: "Writing f", rawInput: { filePath: "/f" }, status: "in_progress" }
  assert.deepEqual(r.push(call), []) // pending: nothing emitted yet
  // vibe-acp sends the same tool_call twice
  assert.deepEqual(r.push(call), [])
  const update = { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "in_progress" }
  assert.deepEqual(r.push(update), [])
  const done = { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed", rawOutput: { ok: true } }
  const parts = r.push(done)
  assert.equal(parts.length, 2)
  assert.equal(parts[0].type, "tool-call")
  assert.equal(parts[0].toolCallId, "t1")
  assert.equal(parts[0].toolName, "Writing f")
  assert.equal(parts[0].providerExecuted, true)
  assert.deepEqual(JSON.parse(parts[0].input as string), { filePath: "/f" })
  assert.equal(parts[1].type, "tool-result")
  assert.equal(parts[1].isError, false)
  // the duplicate completed update must NOT re-emit (OpenCode aborts on duplicate ids)
  assert.deepEqual(r.push(done), [])
  assert.deepEqual(r.push(update), [])
  assert.deepEqual(r.end(), [])
})

test("a failed call settles as an error result", () => {
  const r = makeRenderer()
  r.push({ sessionUpdate: "tool_call", toolCallId: "t2", kind: "execute", title: "bash: x", rawInput: { command: "x" } })
  const parts = r.push({ sessionUpdate: "tool_call_update", toolCallId: "t2", status: "failed" })
  assert.equal(parts[0].type, "tool-call")
  assert.equal(parts[1].type, "tool-result")
  assert.equal(parts[1].isError, true)
})

test("calls still running at turn end settle as incomplete errors", () => {
  const r = makeRenderer()
  r.push({ sessionUpdate: "tool_call", toolCallId: "t3", title: "slow" })
  const parts = r.end()
  assert.equal(parts.length, 2)
  assert.equal(parts[1].isError, true)
  assert.equal((parts[1].result as { status: string }).status, "incomplete")
})

test("finish reasons map per the plan", () => {
  assert.deepEqual(finishReason("end_turn"), { unified: "stop", raw: "end_turn" })
  assert.deepEqual(finishReason("max_tokens"), { unified: "length", raw: "max_tokens" })
  assert.deepEqual(finishReason("max_turn_requests"), { unified: "length", raw: "max_turn_requests" })
  assert.deepEqual(finishReason("refusal"), { unified: "content-filter", raw: "refusal" })
  assert.deepEqual(finishReason("cancelled"), { unified: "other", raw: "cancelled" })
})

test("usage maps to AI SDK shape", () => {
  assert.deepEqual(usageOf({ inputTokens: 100, outputTokens: 20, cachedReadTokens: 30, thoughtTokens: 5 }), {
    inputTokens: { total: 100, noCache: 70, cacheRead: 30, cacheWrite: 0 },
    outputTokens: { total: 20, text: 20, reasoning: 5 },
  })
  assert.deepEqual(usageOf(undefined).inputTokens.total, 0)
})
