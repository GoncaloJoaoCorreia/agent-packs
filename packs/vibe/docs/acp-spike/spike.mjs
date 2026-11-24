// M1 spike: drive `vibe-acp` (Mistral Vibe 3.1.4) from an external ACP client over stdio.
// Logs a full NDJSON transcript (both directions) to transcript.ndjson.
import { spawn } from "node:child_process"
import { createWriteStream, mkdirSync } from "node:fs"
import { Readable, Writable } from "node:stream"
import { ClientSideConnection, ndJsonStream } from "@agentclientprotocol/sdk"

const SCRATCH = new URL("./scratch/", import.meta.url).pathname
const OUT = new URL("./transcript.ndjson", import.meta.url).pathname
mkdirSync(SCRATCH, { recursive: true })
const log = createWriteStream(OUT)
const say = (dir, msg) => log.write(JSON.stringify({ dir, ...msg }) + "\n")
const note = (text) => log.write(JSON.stringify({ dir: "note", text }) + "\n")

const child = spawn("vibe-acp", [], { cwd: SCRATCH, stdio: ["pipe", "pipe", "pipe"] })
child.stderr.on("data", (d) => process.stderr.write(`[vibe-acp stderr] ${d}`))

// Tee the raw NDJSON in both directions into the transcript.
const teeLines = (dir, chunk) => {
  for (const line of new TextDecoder().decode(chunk).split("\n")) {
    if (!line.trim()) continue
    try {
      say(dir, JSON.parse(line))
    } catch {
      say(dir, { raw: line })
    }
  }
}
const outStream = new WritableStream({
  write(chunk) {
    teeLines("client->agent", chunk)
    child.stdin.write(chunk)
  },
})
const inTransform = new TransformStream({
  transform(chunk, controller) {
    teeLines("agent->client", chunk)
    controller.enqueue(chunk)
  },
})

const updates = []
let permissionPolicy = "ask-log-allow"
const connection = new ClientSideConnection(
  () => ({
    sessionUpdate: (params) => {
      updates.push(params.update)
      say("agent->client", { method: "session/update", params })
    },
    requestPermission: (params) => {
      say("agent->client", { method: "session/request_permission", params })
      const opts = params.options ?? []
      note(`permission requested for toolCall=${JSON.stringify(params.toolCall)} options=${opts.map((o) => o.kind + ":" + o.optionId).join(",")} policy=${permissionPolicy}`)
      const pick = (kinds) => opts.find((o) => kinds.includes(o.kind))
      if (permissionPolicy === "allow") {
        const allow = pick(["allow_once", "allow_always"])
        return allow ? { outcome: { outcome: "selected", optionId: allow.optionId } } : { outcome: { outcome: "cancelled" } }
      }
      if (permissionPolicy === "reject") {
        const reject = pick(["reject_once", "reject_always"])
        return reject ? { outcome: { outcome: "selected", optionId: reject.optionId } } : { outcome: { outcome: "cancelled" } }
      }
      const allow = pick(["allow_once", "allow_always"])
      return allow ? { outcome: { outcome: "selected", optionId: allow.optionId } } : { outcome: { outcome: "cancelled" } }
    },
  }),
  ndJsonStream(
    outStream,
    Readable.toWeb(child.stdout).pipeThrough(inTransform),
  ),
)

const step = (name) => note(`--- ${name} ---`)

step("initialize")
const init = await connection.initialize({
  protocolVersion: 1,
  clientCapabilities: {},
  clientInfo: { name: "acp-spike", version: "0.0.0" },
})
say("note", { text: "initialize response: " + JSON.stringify(init) })

step("session/new")
const session = await connection.newSession({ cwd: SCRATCH, mcpServers: [] })
say("note", { text: "session/new response: " + JSON.stringify(session) })
const sessionId = session.sessionId
note(`sessionId=${sessionId}`)

const modelOption = (session.configOptions ?? []).find((c) => c.id === "model" || c.category === "model")
note(`model config option: ${JSON.stringify(modelOption)}`)
if (modelOption && modelOption.currentValue) {
  step("session/set_config_option (model)")
  try {
    const r = await connection.setSessionConfigOption({ sessionId, configId: modelOption.id, value: modelOption.currentValue })
    say("note", { text: "set_config_option(model) response: " + JSON.stringify(r) })
  } catch (e) {
    say("note", { text: "set_config_option(model) error: " + String(e) })
  }
}

step("prompt 1: plain text turn")
updates.length = 0
const p1 = await connection.prompt({ sessionId, prompt: [{ type: "text", text: "Reply with exactly the word PONG and nothing else." }] })
say("note", { text: "prompt1 response: " + JSON.stringify(p1) })
note(`prompt1 updates: ${JSON.stringify(updates.map((u) => u.sessionUpdate))}`)

step("prompt 2: tool call, permission ALLOWED")
permissionPolicy = "allow"
updates.length = 0
const p2 = await connection.prompt({
  sessionId,
  prompt: [{ type: "text", text: "Use your file tools to create a file named acp-spike.txt in your working directory containing exactly: hello from acp. Then reply with the single word DONE." }],
})
say("note", { text: "prompt2 response: " + JSON.stringify(p2) })
note(`prompt2 update kinds: ${JSON.stringify(updates.map((u) => ({ u: u.sessionUpdate, status: u.status, name: u.name, toolCallId: u.toolCallId })))}`)

step("prompt 3: tool call, permission REJECTED")
permissionPolicy = "reject"
updates.length = 0
const p3 = await connection.prompt({
  sessionId,
  prompt: [{ type: "text", text: "Run the shell command `touch denied-marker.txt` in your working directory. Then reply with the single word DONE." }],
})
say("note", { text: "prompt3 response: " + JSON.stringify(p3) })
note(`prompt3 update kinds: ${JSON.stringify(updates.map((u) => ({ u: u.sessionUpdate, status: u.status, name: u.name })))}`)
permissionPolicy = "allow"

step("prompt 4: cancel mid-turn")
updates.length = 0
const slow = connection.prompt({
  sessionId,
  prompt: [{ type: "text", text: "Count from 1 to 200, one number per line, no other text." }],
})
setTimeout(() => {
  note("sending session/cancel")
  connection.cancel({ sessionId }).catch((e) => note("cancel error: " + String(e)))
}, 2500)
const p4 = await slow.catch((e) => ({ error: String(e) }))
say("note", { text: "prompt4 result: " + JSON.stringify(p4) })

step("session/close")
try {
  await connection.closeSession({ sessionId })
  note("session closed")
} catch (e) {
  note("closeSession error: " + String(e))
}

child.stdin?.end()
child.kill("SIGTERM")
await new Promise((r) => child.once("exit", r))
log.end()
console.log("transcript written to", OUT)
process.exit(0)
