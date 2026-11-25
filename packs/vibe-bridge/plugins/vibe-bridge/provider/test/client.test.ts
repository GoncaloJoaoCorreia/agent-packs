// End-to-end client test against a fake ACP agent process (real stdio, sandboxed child process).
import assert from "node:assert/strict"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import { AcpClient, catalogOf, choose } from "../src/client.ts"
import type { SessionUpdate } from "../src/acp.ts"

const here = fileURLToPath(new URL(".", import.meta.url))
const fakeServer = join(here, "fake-acp-server.mjs")

async function withClient<T>(scenario: string, fn: (client: AcpClient) => Promise<T>): Promise<T> {
  const cwd = mkdtempSync(join(tmpdir(), "vibe-acp-test-"))
  try {
    const client = await AcpClient.start({
      cwd,
      command: process.execPath,
      args: [fakeServer],
      env: { FAKE_SCENARIO: scenario },
      clientInfo: { name: "test", version: "0.0.0" },
    })
    try {
      return await fn(client)
    } finally {
      await client.close()
    }
  } finally {
    rmSync(cwd, { recursive: true, force: true })
  }
}

test("initialize + session/new exposes the model catalog from configOptions", async () => {
  await withClient("tool", async (client) => {
    assert.equal(client.agentInfo.name, "fake-vibe")
    const session = await client.newSession(process.cwd())
    assert.deepEqual(session.catalog.models.map((m) => m.id), ["fake-large", "fake-small"])
    assert.deepEqual(session.catalog.thinking.levels, ["low", "high"])
    assert.ok(session.catalog.modes.available.includes("ask"))
    await client.setSessionMode(session.sessionId, "ask")
    await client.setSessionConfigOption(session.sessionId, "model", "fake-small")
    await client.closeSession(session.sessionId)
  })
})

test("prompt streams updates, answers request_permission, resolves with stopReason + usage", async () => {
  await withClient("tool", async (client) => {
    const session = await client.newSession(process.cwd())
    const updates: SessionUpdate[] = []
    let permission: unknown
    const result = await client.prompt(
      session.sessionId,
      "do it",
      (update) => updates.push(update),
      undefined,
    )
    assert.equal(result.stopReason, "end_turn")
    assert.equal(result.usage?.totalTokens, 120)
    const kinds = updates.map((u) => u.sessionUpdate)
    assert.ok(kinds.includes("agent_message_chunk"))
    assert.ok(kinds.includes("agent_thought_chunk"))
    // the tool call and its completion arrive duplicated — the renderer dedupes (renderer.test.ts)
    assert.equal(kinds.filter((k) => k === "tool_call").length, 2)
    assert.equal(kinds.filter((k) => k === "tool_call_update").length, 2)
  })
})

test("prompt answers request_permission through the permission handler", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "vibe-acp-test-"))
  try {
    const seen: unknown[] = []
    const client = await AcpClient.start({
      cwd,
      command: process.execPath,
      args: [fakeServer],
      clientInfo: { name: "test", version: "0.0.0" },
      permission: (request) => {
        seen.push(request)
        return choose(request, true)
      },
    })
    try {
      const session = await client.newSession(cwd)
      const updates: SessionUpdate[] = []
      const result = await client.prompt(session.sessionId, "go", (u) => updates.push(u))
      assert.equal(seen.length, 1)
      const req = seen[0] as { toolCall: { toolCallId: string } }
      assert.equal(req.toolCall.toolCallId, "tool-1")
      // allowed -> the call completes
      const done = updates.find((u) => u.sessionUpdate === "tool_call_update")
      assert.equal((done as { status?: string }).status, "completed")
      assert.equal(result.stopReason, "end_turn")
    } finally {
      await client.close()
    }
  } finally {
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("session/cancel resolves the pending prompt as cancelled", async () => {
  await withClient("cancel", async (client) => {
    const session = await client.newSession(process.cwd())
    const prompt = client.prompt(session.sessionId, "count forever", undefined)
    await new Promise((r) => setTimeout(r, 200))
    await client.cancel(session.sessionId)
    const result = await prompt
    assert.equal(result.stopReason, "cancelled")
  })
})

test("abort signal cancels the turn via session/cancel", async () => {
  await withClient("cancel", async (client) => {
    const session = await client.newSession(process.cwd())
    const controller = new AbortController()
    const prompt = client.prompt(session.sessionId, "count forever", undefined, controller.signal)
    setTimeout(() => controller.abort(), 200)
    await assert.rejects(prompt, /cancelled/)
  })
})

test("updates reach both the default onUpdate (tool-call tracker) and the prompt listener", async () => {
  // Regression: per-prompt listeners used to shadow the default onUpdate, so the session
  // manager's tool-call tracker saw nothing and permission requests mapped to kind "other".
  const cwd = mkdtempSync(join(tmpdir(), "vibe-acp-test-"))
  try {
    const tracked: string[] = []
    const promptUpdates: string[] = []
    const client = await AcpClient.start({
      cwd,
      command: process.execPath,
      args: [fakeServer],
      clientInfo: { name: "test", version: "0.0.0" },
      onUpdate: (_sid, u) => tracked.push(u.sessionUpdate),
    })
    try {
      const session = await client.newSession(cwd)
      await client.prompt(session.sessionId, "go", (u) => promptUpdates.push(u.sessionUpdate))
      assert.ok(tracked.includes("tool_call"), "default onUpdate saw the tool call")
      assert.ok(promptUpdates.includes("tool_call"), "prompt listener saw the tool call")
      assert.equal(
        tracked.filter((k) => k === "tool_call").length,
        promptUpdates.filter((k) => k === "tool_call").length,
        "both handlers see every update",
      )
    } finally {
      await client.close()
    }
  } finally {
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("catalogOf reads models/thinking/modes from a session/new response", () => {
  const catalog = catalogOf({
    sessionId: "s",
    modes: { currentModeId: "accept-edits", availableModes: [{ id: "ask" }] },
    configOptions: [
      { id: "model", category: "model", currentValue: "m", options: [{ value: "m1", name: "M1" }] },
      { id: "thinking", category: "thinking", currentValue: "high", options: [{ value: "low" }] },
    ],
  })
  assert.deepEqual(catalog.models, [{ id: "m1", name: "M1", description: undefined }])
  assert.deepEqual(catalog.thinking, { current: "high", levels: ["low"] })
})
