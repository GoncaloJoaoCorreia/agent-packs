// M1 spike part 2: mode=ask behavior, full model list, thinking option, duplicate-update check.
import { spawn } from "node:child_process"
import { createWriteStream, mkdirSync, rmSync } from "node:fs"
import { Readable, Writable } from "node:stream"
import { ClientSideConnection, ndJsonStream } from "@agentclientprotocol/sdk"

const SCRATCH = new URL("./scratch2/", import.meta.url).pathname
const OUT = new URL("./transcript2.ndjson", import.meta.url).pathname
rmSync(SCRATCH, { recursive: true, force: true })
mkdirSync(SCRATCH, { recursive: true })
const log = createWriteStream(OUT)
const say = (dir, msg) => log.write(JSON.stringify({ dir, ...msg }) + "\n")
const note = (text) => log.write(JSON.stringify({ dir: "note", text }) + "\n")

const child = spawn("vibe-acp", [], { cwd: SCRATCH, stdio: ["pipe", "pipe", "pipe"] })
child.stderr.on("data", (d) => process.stderr.write(`[stderr] ${d}`))
const teeLines = (dir, chunk) => {
  for (const line of new TextDecoder().decode(chunk).split("\n")) {
    if (!line.trim()) continue
    try { say(dir, JSON.parse(line)) } catch { say(dir, { raw: line }) }
  }
}
const outStream = new WritableStream({ write(c) { teeLines("c->a", c); child.stdin.write(c) } })
const inT = new TransformStream({ transform(c, ctrl) { teeLines("a->c", c); ctrl.enqueue(c) } })

const perms = []
const connection = new ClientSideConnection(
  () => ({
    sessionUpdate: (params) => say("a->c", { method: "session/update", params }),
    requestPermission: (params) => {
      perms.push(params)
      say("a->c", { method: "session/request_permission", params })
      const reject = (params.options ?? []).find((o) => o.kind === "reject_once")
      return reject ? { outcome: { outcome: "selected", optionId: reject.optionId } } : { outcome: { outcome: "cancelled" } }
    },
  }),
  ndJsonStream(outStream, Readable.toWeb(child.stdout).pipeThrough(inT)),
)

await connection.initialize({ protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: "acp-spike", version: "0.0.0" } })
const session = await connection.newSession({ cwd: SCRATCH, mcpServers: [] })
const sid = session.sessionId
const modelOpt = (session.configOptions ?? []).find((c) => c.category === "model")
note("MODELS: " + JSON.stringify((modelOpt?.options ?? []).map((o) => ({ value: o.value, name: o.name, description: o.description }))))
note("THINKING: " + JSON.stringify((session.configOptions ?? []).find((c) => c.category === "thinking")))
note("MODES: " + JSON.stringify(session.modes))

// force ask mode
const modeRes = await connection.setSessionMode({ sessionId: sid, modeId: "ask" })
note("setSessionMode(ask): " + JSON.stringify(modeRes).slice(0, 200))

// try to make it write a file; permission should now be requested for the edit too
const p = await connection.prompt({
  sessionId: sid,
  prompt: [{ type: "text", text: "Create a file named ask-mode.txt in your working directory with the text: x. Reply DONE when finished." }],
})
note("prompt response: " + JSON.stringify(p))
note("permission requests: " + JSON.stringify(perms.map((r) => ({ toolCall: r.toolCall, kinds: (r.options ?? []).map((o) => o.kind) }))))

// thinking option
try {
  const t = await connection.setSessionConfigOption({ sessionId: sid, configId: "thinking", value: "low" })
  note("set thinking=low ok: " + JSON.stringify(t).slice(0, 300))
} catch (e) { note("set thinking error: " + String(e)) }

await connection.closeSession({ sessionId: sid }).catch(() => {})
child.stdin?.end(); child.kill("SIGTERM")
await new Promise((r) => child.once("exit", r))
log.end()
console.log("done", OUT)
process.exit(0)
