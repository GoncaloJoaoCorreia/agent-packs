# Permissions & provider-executed tool calls (M4 / G-88)

How the ACP agent's actions interact with OpenCode's permission rules when using the `vibe`
provider.

## The mechanism

1. The ACP agent (inside `vibe-acp`) runs its own tools. OpenCode does not run them; it surfaces
   them as **provider-executed** tool calls (`providerExecuted: true`).
2. Every new ACP session is set to mode **`ask`** (`session/set_mode`). This is essential: with
   vibe's default mode `accept-edits`, file edits are auto-approved by the CLI and **never reach
   `session/request_permission`** — verified in the M1 spike (a denied `bash touch` was
   sidestepped by `write_file`, which succeeded silently). Mode `ask` forces a
   `session/request_permission` for every tool call.
3. When the agent asks, the provider package resolves the referenced tool call (the request
   carries only `toolCallId`; kind/locations/rawInput come from the tracked `tool_call` update),
   maps the ACP `kind` onto an OpenCode permission action, and calls OpenCode's
   `ctx.permission.assert` with the **running session's and agent's rules**:

   | ACP tool `kind` | OpenCode action | resources |
   |---|---|---|
   | `edit`, `delete`, `move` | `edit` | `locations[].path` |
   | `execute` | `bash` | the `command` from `rawInput` |
   | `read` | `read` | `locations[].path` |
   | `search` | `grep` | `locations[].path` |
   | `fetch` | `webfetch` | `locations[].path` or title |
   | other | `vibe` | title or `*` |

4. The answer is mapped back to the offered options: allowed → `allow_once`, denied →
   `reject_once`. Because the check goes through `permission.assert`, **deny rules, plan mode,
   and `ask` prompts all apply** to what the agent asks about, and "always allow" answers persist
   as OpenCode rules.

## Tool-call surfacing (single emission)

`vibe-acp` sends every `tool_call` / `tool_call_update` notification **twice**, and OpenCode
aborts a turn on duplicate tool-call ids (the crash anomalyco/opencode#65489 hit). The renderer
therefore tracks calls by `toolCallId` and emits **one** `tool-call` part plus **one**
`tool-result` part when the call reaches `completed`/`failed` — never re-emitting duplicates —
and settles calls still running at turn end as failed. Unit-tested
(`provider/test/renderer.test.ts`).

## Verified against real turns (2026-11-24, sandboxed)

- Provider level (`SessionManager` + real `vibe-acp`, assert denying edit/bash): tool calls
  settle `failed`, **no file created**; assert denying nothing: `action: "edit"` /
  `action: "bash"` with the right resources (`filePath`, `command`).
- OpenCode level (scratch project with `"permission": { "edit": "deny" }`, pack installed in a
  throwaway config): `opencode run --model vibe/mistral-large-4-0 "create deny-test.txt …"` →
  every write path answered `tool_denied: Tool execution denied by approval callback`,
  `deny-test.txt` **not created**, and the agent did not route around the denial.
  With `--auto` (or an allow rule) the same turn creates the file via a provider-executed
  `write_file` shown exactly once.

## The limit (read this before relying on the rules)

Anything the Vibe CLI's **own settings** auto-approves *without asking* bypasses OpenCode's
rules — the pack mitigates this by forcing session mode `ask`, but vibe's `config.toml`
(e.g. its own permission/approval settings) can still widen what the CLI does on its own
(cf. anomalyco/opencode#53530). Provider-executed calls are also **not** OpenCode tools: the
`edit`/`bash`/… rules gate what the agent *asks about*, not a tool schema OpenCode controls.
