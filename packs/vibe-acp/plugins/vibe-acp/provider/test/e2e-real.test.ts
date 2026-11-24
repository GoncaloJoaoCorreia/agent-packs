// Real-turn smoke test against the signed-in `vibe-acp` binary. Sandboxed: own child process,
// scratch cwd (own Vibe session history), no OpenCode config touched.
// Skipped unless VIBE_ACP_E2E=1 (CI runs the unit tests only):  VIBE_ACP_E2E=1 node --test test/e2e-real.test.ts
import assert from "node:assert/strict"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { AcpClient } from "../src/client.ts"
import { makeRenderer } from "../src/renderer.ts"
import type { SessionUpdate } from "../src/acp.ts"

const e2e = process.env.VIBE_ACP_E2E === "1"

test("one real turn against vibe-acp", { skip: !e2e }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "vibe-acp-e2e-"))
  try {
    const client = await AcpClient.start({ cwd, clientInfo: { name: "e2e-test", version: "0.0.0" } })
    try {
      const session = await client.newSession(cwd)
      assert.ok(session.catalog.models.length > 0, "model catalog reported")
      await client.setSessionMode(session.sessionId, "ask")
      const model = session.catalog.models[0].id
      await client.setSessionConfigOption(session.sessionId, "model", model)
      const renderer = makeRenderer()
      const parts: unknown[] = []
      const result = await client.prompt(session.sessionId, "Reply with exactly the word PONG and nothing else.", (update: SessionUpdate) => {
        for (const part of renderer.push(update)) parts.push(part)
      })
      for (const part of renderer.end()) parts.push(part)
      assert.equal(result.stopReason, "end_turn")
      const text = parts.filter((p) => (p as { type: string }).type === "text-delta").map((p) => (p as { delta: string }).delta).join("")
      assert.match(text, /PONG/)
      assert.ok(result.usage && result.usage.outputTokens! > 0)
      await client.closeSession(session.sessionId)
    } finally {
      await client.close()
    }
  } finally {
    rmSync(cwd, { recursive: true, force: true })
  }
})
