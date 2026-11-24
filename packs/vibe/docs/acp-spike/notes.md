# M1 spike notes — driving `vibe-acp` from an external ACP client (G-84)

Date: 2026-11-24. Client under test: Mistral Vibe CLI **3.1.4** (`vibe` / `vibe-acp` from the
`mistral-vibe` uv tool), signed-in INDIVIDUAL plan. Spike scripts: `spike.mjs` (main run) and
`spike-ask-mode.mjs` (follow-up); excerpts of the raw NDJSON transcripts:
`transcript-excerpt.ndjson`, `transcript-ask-mode-excerpt.ndjson`. Run them with
`npm i @agentclientprotocol/sdk@1.6.0 && node spike.mjs` from a scratch directory (they spawn
`vibe-acp` with the scratch dir as cwd, so no real project or running instance is touched).

## Exact invocation & protocol

- In Vibe **3.1.4 the ACP server is a separate binary: `vibe-acp`** (console script
  `vibe.acp.entrypoint:main`). `vibe acp` is **not** a subcommand — clap parses `acp` as the
  initial prompt and vibe answers "Interactive mode needs a terminal". (The plan/issue text says
  `vibe acp`; record the real spelling for this version. Newer Vibe releases may alias it —
  re-check per version.)
- Transport: **newline-delimited JSON-RPC over stdio** (`ndJsonStream` of
  `@agentclientprotocol/sdk`), no Content-Length headers.
- **ACP protocol version 1** (`PROTOCOL_VERSION = 1` in the bundled `acp` python package).
  Client sends `initialize` with `protocolVersion: 1`.
- `initialize` response (agent side):
  - `agentInfo`: `{ name: "@mistralai/mistral-vibe", title: "Mistral Vibe", version: "3.1.4" }`
  - `agentCapabilities`: `loadSession: true`, `promptCapabilities: { image: true, audio: false, embeddedContext: true }`,
    `sessionCapabilities: { list: {}, fork: {}, close: {} }`
  - `authMethods`: one **browser** method — `browser-auth` "Sign in through Mistral AI Studio"
    (plus a `terminal` method `vibe-setup` when the client sets the `terminal-auth` client meta flag).
    So sign-in is Vibe's own; the API key never needs to enter OpenCode — matches the plan.

## Sessions, models, config

- `session/new { cwd, mcpServers: [] }` → `{ sessionId, modes, configOptions, ... }`.
  There is **no `models` field** on the session (that's the `agy` shape); models come from
  `configOptions`:
  - `mode` (category `mode`): select of `ask` / `accept-edits` / `smart-approve` / `auto-approve`;
    **default is `accept-edits`** — see the permission section below.
  - `model` (category `model`): select, `currentValue` = active alias; options are
    `{ value: alias, name: displayName, description: upstreamModelId }`. Observed list (6 models):
    `mistral-large-4-0` ("Mistral Large 4"), `mistral-medium-latest`, `zai-glm-5-3`,
    `zai-glm-5-3-flash`, `deepseek-v4-1-flash-1017`, `mistral-large-4`.
  - `thinking` (category `thinking`): select of effort levels `low` / `medium` / `high`
    (current `high`).
- **Effort levels are NOT part of model names** (unlike `agy`). Model id = the alias; effort is a
  separate config option. So OpenCode models map 1:1 to ACP model aliases; effort becomes a
  per-model variant setting (`thinking`), not a name suffix. Plan §2's "effort suffixes group as
  variants" needs this vibe-specific adjustment.
- Setting model/effort: **`session/set_config_option { sessionId, configId: "model" | "thinking", value }`**
  (standard ACP method; the response echoes all `configOptions`). There is no `session/set_model`
  extension method in vibe (that was `agy`). Only send it when the selection changed.
- `session/set_session_mode { sessionId, modeId }` exists and works (set to `ask` in spike 2).

## Turns: prompt, updates, stop reasons, usage, cancel

- `session/prompt { sessionId, prompt: [{ type: "text", text }] }` →
  `{ stopReason, usage }`. Observed `stopReason`: `end_turn`, `cancelled`. (Plan's
  `max_tokens` / `max_turn_requests` / `refusal` remain to be mapped — same mapping as the plan.)
- `usage`: `{ totalTokens, inputTokens, outputTokens, cachedReadTokens }` (thought tokens not
  reported at top level; reasoning shows up as `agent_thought_chunk` updates).
- Updates arrive as `session/update` notifications with `update.sessionUpdate`:
  `user_message_chunk`, `agent_message_chunk` (text), `agent_thought_chunk` (reasoning),
  `tool_call` (full: `toolCallId`, `title`, `kind`, `status`, `content`, `locations`, `rawInput`,
  `_meta.tool_name`), `tool_call_update` (partial: changed fields only, incl. final
  `status: completed|failed` and `rawOutput`), `usage_update`, `available_commands_update`,
  `session_info_update`.
- **`tool_call` and `tool_call_update` are each delivered TWICE** (duplicate notifications —
  observed consistently). Any consumer must dedupe by `toolCallId` (and never re-emit a settled
  call), exactly the #65489 lesson.
- `session/cancel { sessionId }` notification mid-turn → the pending `session/prompt` resolves with
  `stopReason: "cancelled"`. (Cancel works; no separate error.)
- `session/close { sessionId }` → `{}`. `session/delete` also exists (capability `close`).

## Tool calls & permission requests

- Tool calls are **provider-executed**: the agent runs its own tools (`write_file`, bash, …);
  `_meta.tool_name` / `effect_kind` identify the real tool, `kind` is the ACP category
  (`edit`, `execute`, `read`, …), `locations[].path` gives affected paths, `rawInput` holds the
  arguments (e.g. `{ command: "touch …" }` for execute).
- `session/request_permission` (agent→client **request**, has an id to answer) carries
  `toolCall: { toolCallId }` **only** — kind/locations/rawInput must be looked up from the
  earlier `tool_call` update with the same id. `options`: `allow_once`, `allow_always`
  (twice, one with `_meta.required_permissions` for permanent), `reject_once`. Answer with
  `{ outcome: { outcome: "selected", optionId } }` or `{ outcome: { outcome: "cancelled" } }`.
- When refused (`reject_once`), the call settles as `tool_call_update status: "failed"` and the
  agent retries/explains.
- **Gotcha (mode bypass):** with the default mode `accept-edits`, a `write_file` (kind `edit`)
  is executed **without any `session/request_permission`** — in spike 1 the agent was denied
  `bash touch denied-marker.txt` three times, then created the file via `write_file` anyway.
  With `session/set_session_mode` → `ask`, the same write **did** trigger `request_permission`.
  ⇒ The provider must set mode `ask` on every new ACP session so all tool calls go through
  OpenCode's permission rules; anything the CLI auto-approves on its own bypasses them (cf.
  anomalyco/opencode#53530). This is the M4 semantics core.

## ToS question (the blocker for public shipping)

Mistral's **consumer Terms of Service** (ROW, effective 2026-10-12,
https://legal.mistral.ai/terms/row-consumer-terms, §3 "Restrictions") — Vibe is a consumer
product covered by these terms — prohibit, among others:

- (g) **"Integrate or combine the Mistral AI Products with any products you may offer or make
  available to third-parties including any other software, hardware, or other technology, nor
  grant any third party access to the Mistral AI Products without our prior written
  authorization"**;
- (d) reverse engineering; (f) extracting content other than as permitted through the products.

This is the same shape as Google's Antigravity terms quoted in #65489/#28889: **wrapping
`vibe-acp` inside a third-party harness that is offered to third parties (like this pack) is not
permitted without Mistral's prior written authorization.** Driving `vibe-acp` as an ACP client
from your own editor for personal use is the intended ACP usage (Zed etc.), but distributing a
pack that does it needs Mistral's blessing. The Additional Product Terms
(https://legal.mistral.ai/terms/additional-terms) don't add an ACP carve-out. The commercial
terms (Mistral AI Studio / API) are a different regime — the retired open API key is API-only.

⇒ Recorded decision: the pack ships with a prominent notice and is positioned for personal use;
**getting Mistral's written OK is a hard prerequisite before any public release/wide
 distribution** (open question for the maintainers, noted on G-83/G-84).

## Consequences for M2–M5 (design inputs)

1. Spawn `vibe-acp` (fall back to `vibe acp` for versions that alias it), NDJSON stdio, ACP v1.
2. Model discovery = throwaway `session/new` → read `configOptions` `model` select (cache between
   starts); variants from the `thinking` select via `session/set_config_option`.
3. One ACP session per OpenCode session; `session/set_session_mode` → `ask` right after
   `session/new`; `set_config_option` model/thinking only on change; turns serialized;
   `session/cancel` on abort; `session/close` on session.deleted.
4. Renderer dedupes `tool_call`/`tool_call_update` by `toolCallId`; emits one `tool-call` +
   one `tool-result` when status reaches completed/failed (duplicates observed — must not
   re-emit); text→text, thought→reasoning.
5. `request_permission`: resolve the tool call by id from tracked updates, map
   `kind` → OpenCode permission action (edit/delete/move→`edit`, execute→`bash`, read→`read`,
   search→`grep`, fetch→`webfetch`), ask OpenCode, answer allow_once/reject_once.
6. Finish reasons: `end_turn`→stop, `max_tokens`/`max_turn_requests`→length, `refusal`→
   content-filter, `cancelled`→other/unknown; usage from `usage` field.
