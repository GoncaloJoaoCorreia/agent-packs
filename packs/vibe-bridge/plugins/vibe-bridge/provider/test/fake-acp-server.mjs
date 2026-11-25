// A scripted fake ACP agent over stdio (NDJSON JSON-RPC) for client tests.
// Scenarios via env FAKE_SCENARIO: "tool" (default) or "cancel".
// Run standalone: node test/fake-acp-server.mjs
import { createInterface } from "node:readline"

const scenario = process.env.FAKE_SCENARIO ?? "tool"
const sessions = new Map()
let nextId = 100

const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n")
const notify = (method, params) => send({ jsonrpc: "2.0", method, params })

const models = [
  { value: "fake-large", name: "Fake Large", description: "fake-large-1" },
  { value: "fake-small", name: "Fake Small", description: "fake-small-1" },
]
const configOptions = [
  { id: "mode", name: "Session Mode", category: "mode", type: "select", currentValue: "accept-edits", options: [
    { value: "ask", name: "Ask" }, { value: "accept-edits", name: "Accept Edits" },
  ] },
  { id: "model", name: "Model", category: "model", type: "select", currentValue: "fake-large", options: models },
  { id: "thinking", name: "Thinking", category: "thinking", type: "select", currentValue: "high", options: [
    { value: "low", name: "Low" }, { value: "high", name: "High" },
  ] },
]

async function handleRequest(id, method, params) {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, agentCapabilities: { loadSession: true }, agentInfo: { name: "fake-vibe", version: "0.0.0" }, authMethods: [] }
    case "session/new": {
      const sessionId = `fake-${nextId++}`
      sessions.set(sessionId, { config: {} })
      return { sessionId, modes: { currentModeId: "accept-edits", availableModes: [{ id: "ask" }, { id: "accept-edits" }] }, configOptions }
    }
    case "session/set_mode": // ACP v1 wire name for setSessionMode
      sessions.get(params.sessionId).mode = params.modeId
      return {}
    case "session/set_config_option":
      sessions.get(params.sessionId).config[params.configId] = params.value
      return { configOptions }
    case "session/close":
      sessions.delete(params.sessionId)
      return {}
    case "session/prompt": {
      const sessionId = params.sessionId
      if (scenario === "cancel") {
        // wait for session/cancel, then resolve cancelled
        return new Promise((resolve) => {
          pendingCancel.set(sessionId, () => resolve({ stopReason: "cancelled", usage: { inputTokens: 1, outputTokens: 1, totalTokens: 2 } }))
        })
      }
      // emit a scripted turn: thought, message, tool call (sent twice like vibe-acp), permission request, result
      notify("session/update", { sessionId, update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "let me check" } } })
      notify("session/update", { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "working on it" } } })
      const call = { sessionUpdate: "tool_call", toolCallId: "tool-1", kind: "execute", title: "bash: echo hi", rawInput: { command: "echo hi" }, status: "in_progress" }
      notify("session/update", { sessionId, update: call })
      notify("session/update", { sessionId, update: call }) // duplicate, like the real CLI
      // ask permission; wait for the client's answer
      const permission = await new Promise((resolve) => {
        pendingPermission.set(sessionId, resolve)
        send({
          jsonrpc: "2.0",
          id: 9000 + nextId++,
          method: "session/request_permission",
          params: {
            sessionId,
            toolCall: { toolCallId: "tool-1" },
            options: [
              { optionId: "allow_once", name: "Allow once", kind: "allow_once" },
              { optionId: "reject_once", name: "Deny", kind: "reject_once" },
            ],
          },
        })
      })
      const allowed = permission?.outcome?.outcome === "selected" && permission.outcome.optionId === "allow_once"
      const done = { sessionUpdate: "tool_call_update", toolCallId: "tool-1", status: allowed ? "completed" : "failed", rawOutput: { ok: allowed } }
      notify("session/update", { sessionId, update: done })
      notify("session/update", { sessionId, update: done }) // duplicate
      notify("session/update", { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "done" } } })
      return { stopReason: "end_turn", usage: { inputTokens: 100, outputTokens: 20, totalTokens: 120, cachedReadTokens: 10 } }
    }
    default:
      throw Object.assign(new Error(`unknown method ${method}`), { code: -32601 })
  }
}

const pendingCancel = new Map()
const pendingPermission = new Map()

const rl = createInterface({ input: process.stdin })
rl.on("line", (line) => {
  if (!line.trim()) return
  const msg = JSON.parse(line)
  if (msg.method === "session/cancel") {
    const resolve = pendingCancel.get(msg.params.sessionId)
    if (resolve) { pendingCancel.delete(msg.params.sessionId); resolve() }
    return
  }
  if ("id" in msg && "method" in msg) {
    handleRequest(msg.id, msg.method, msg.params ?? {})
      .then((result) => send({ jsonrpc: "2.0", id: msg.id, result: result ?? null }))
      .catch((error) => send({ jsonrpc: "2.0", id: msg.id, error: { code: error.code ?? -32603, message: error.message } }))
    return
  }
  if ("id" in msg && "result" in msg) {
    // response to our request_permission
    for (const resolve of pendingPermission.values()) { resolve(msg.result); pendingPermission.clear(); break }
  }
})
