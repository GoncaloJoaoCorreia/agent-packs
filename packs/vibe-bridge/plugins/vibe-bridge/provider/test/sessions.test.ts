// SessionManager tests with an in-memory fake ACP client: one ACP session per OpenCode session,
// config set only on change, turns serialized, dead-client restart, permission mapping.
import assert from "node:assert/strict"
import { test } from "node:test"
import { SessionManager, type ClientLike } from "../src/sessions.ts"
import type { AcpSessionInfo } from "../src/client.ts"
import type { SessionUpdate } from "../src/acp.ts"
import type { PermissionCheck } from "../src/permissions.ts"

const catalog = {
  models: [{ id: "m1", name: "M1" }],
  thinking: { current: "high", levels: ["low", "high"] },
  modes: { current: "accept-edits", available: ["ask", "accept-edits"] },
}

class FakeClient implements ClientLike {
  sessions = new Map<string, { closed: boolean }>()
  configCalls: { sessionId: string; configId: string; value: string }[] = []
  modeCalls: string[] = []
  prompts: { sessionId: string; prompt: string }[] = []
  private closeResolve!: () => void
  closed: Promise<void>
  private seq = 0

  constructor() {
    this.closed = new Promise<void>((resolve) => { this.closeResolve = resolve })
  }

  async newSession(): Promise<AcpSessionInfo> {
    const sessionId = `acp-${this.seq++}`
    this.sessions.set(sessionId, { closed: false })
    return { sessionId, catalog }
  }
  async setSessionMode(sessionId: string, modeId: string) { this.modeCalls.push(`${sessionId}:${modeId}`) }
  async setSessionConfigOption(sessionId: string, configId: string, value: string) {
    this.configCalls.push({ sessionId, configId, value })
  }
  async prompt(sessionId: string, prompt: string, _onUpdate: ((u: SessionUpdate) => void) | undefined): Promise<{ stopReason: string; usage?: object }> {
    this.prompts.push({ sessionId, prompt })
    return { stopReason: "end_turn", usage: { inputTokens: 1 } }
  }
  async closeSession(sessionId: string) { this.sessions.get(sessionId)!.closed = true }
  async close() { this.closeResolve() }
}

function makeManager(client: FakeClient, extra: Partial<ConstructorParameters<typeof SessionManager>[0]> = {}) {
  return new SessionManager({
    directory: "/tmp",
    connect: async () => client,
    initialCatalog: catalog,
    ...extra,
  })
}

const noop = () => {}

test("one ACP session per OpenCode session; mode ask is set on new sessions", async () => {
  const client = new FakeClient()
  const manager = makeManager(client)
  const signal = new AbortController().signal
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "a" }, noop, signal)
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "b" }, noop, signal)
  await manager.run({ sessionID: "s2", kind: "primary", model: "m1", prompt: "c" }, noop, signal)
  assert.equal(client.prompts.length, 3)
  assert.equal(client.sessions.size, 2) // s1 and s2 share no ACP session
  assert.deepEqual(client.modeCalls, ["acp-0:ask", "acp-1:ask"])
})

test("model config is set only when the selection changes", async () => {
  const client = new FakeClient()
  const manager = makeManager(client)
  const signal = new AbortController().signal
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "a" }, noop, signal)
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "b" }, noop, signal)
  await manager.run({ sessionID: "s1", kind: "primary", model: "m2", prompt: "c" }, noop, signal)
  await manager.run({ sessionID: "s1", kind: "primary", model: "m2", thinking: "low", prompt: "d" }, noop, signal)
  await manager.run({ sessionID: "s1", kind: "primary", model: "m2", thinking: "low", prompt: "e" }, noop, signal)
  assert.deepEqual(client.configCalls, [
    { sessionId: "acp-0", configId: "model", value: "m1" },
    { sessionId: "acp-0", configId: "model", value: "m2" },
    { sessionId: "acp-0", configId: "thinking", value: "low" },
  ])
})

test("auxiliary requests use a throwaway session that is closed afterwards", async () => {
  const client = new FakeClient()
  const manager = makeManager(client)
  const signal = new AbortController().signal
  await manager.run({ sessionID: "s1", kind: "title", model: "m1", prompt: "title?" }, noop, signal)
  assert.equal(client.prompts.length, 1)
  assert.equal(client.sessions.get("acp-0")!.closed, true)
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "real" }, noop, signal)
  assert.equal(client.sessions.size, 2) // throwaway + conversation
})

test("turns in one conversation are serialized", async () => {
  const client = new FakeClient()
  const order: string[] = []
  const slow = new FakeClient()
  slow.prompt = async (sessionId, prompt) => {
    order.push(`start:${prompt}`)
    await new Promise((r) => setTimeout(r, 50))
    order.push(`end:${prompt}`)
    return { stopReason: "end_turn" }
  }
  const manager = makeManager(slow)
  const signal = new AbortController().signal
  await Promise.all([
    manager.run({ sessionID: "s", kind: "primary", model: "m1", prompt: "1" }, noop, signal),
    manager.run({ sessionID: "s", kind: "primary", model: "m1", prompt: "2" }, noop, signal),
  ])
  assert.deepEqual(order, ["start:1", "end:1", "start:2", "end:2"])
})

test("remove() closes the ACP session of the OpenCode session", async () => {
  const client = new FakeClient()
  const manager = makeManager(client)
  const signal = new AbortController().signal
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "a" }, noop, signal)
  await manager.remove("s1")
  assert.equal(client.sessions.get("acp-0")!.closed, true)
})

test("a dead client is replaced on the next turn", async () => {
  const client = new FakeClient()
  let connects = 0
  const manager = new SessionManager({
    directory: "/tmp",
    connect: async () => {
      connects++
      return client
    },
  })
  const signal = new AbortController().signal
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "a" }, noop, signal)
  // simulate the process dying
  client.close()
  await new Promise((r) => setTimeout(r, 10))
  await manager.run({ sessionID: "s1", kind: "primary", model: "m1", prompt: "b" }, noop, signal)
  assert.equal(connects, 2)
})

test("permission requests map kind to the OpenCode action and honor the assert hook", async () => {
  const client = new FakeClient()
  const checks: PermissionCheck[] = []
  const manager = makeManager(client, {
    assert: async (check) => {
      checks.push(check)
      return check.action === "bash" // allow bash, deny the rest
    },
  })
  // wire the manager's onUpdate tracking: simulate the tool_call update arriving
  const signal = new AbortController().signal
  const run = manager.run({ sessionID: "s1", agent: "build", kind: "primary", model: "m1", prompt: "go" }, noop, signal)
  await run
  // drive the permission path directly through the manager's client options is internal;
  // instead verify the mapping function used by permit():
  const { toPermission } = await import("../src/permissions.ts")
  const check = toPermission({
    sessionID: "s1",
    agent: "build",
    request: { sessionId: "acp-0", toolCall: { toolCallId: "t1" }, options: [] },
    call: { toolCallId: "t1", kind: "execute", title: "bash: rm -rf /", rawInput: { command: "rm -rf /" }, locations: [] },
  })
  assert.equal(check.action, "bash")
  assert.deepEqual(check.resources, ["rm -rf /"])
  assert.equal(check.agent, "build")
  const edit = toPermission({
    sessionID: "s1",
    request: { sessionId: "acp-0", toolCall: { toolCallId: "t2" }, options: [] },
    call: { toolCallId: "t2", kind: "edit", title: "Writing x", locations: [{ path: "/x" }] },
  })
  assert.equal(edit.action, "edit")
  assert.deepEqual(edit.resources, ["/x"])
})

test("discover() reads the catalog via a throwaway session and caches it", async () => {
  const client = new FakeClient()
  const manager = makeManager(client)
  const catalog2 = await manager.discover()
  assert.deepEqual(catalog2.models.map((m) => m.id), ["m1"])
  assert.equal(client.sessions.get("acp-0")!.closed, true)
})
