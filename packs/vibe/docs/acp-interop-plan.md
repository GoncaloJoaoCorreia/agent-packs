# ACP interop plan: Mistral Vibe (`vibe acp`) as an OpenCode provider

Status: proposed — tracked by the **"ACP interop" milestone** in the Linear project
**Agent Packs** (umbrella issue linked there).

## 1. Context & goal

- [anomalyco/opencode#65867](https://github.com/anomalyco/opencode/issues/65867): Mistral is
  shutting down the open Vibe CLI API key; the closed replacement key only works via the Vibe
  CLI or **ACP**. Goal: keep using that key from OpenCode.
- OpenCode's ACP support is server-side only (`opencode acp` runs OpenCode *as* an ACP agent for
  clients like Zed — [docs](https://opencode.ai/docs/cli/acp/)). There is no ACP client mode, so
  this cannot be done by config alone.
- Decision: ship it as **two pieces on supported extension points — no fork of OpenCode**:
  1. a provider runtime package (the `package` behind `providers.vibe`), and
  2. a server plugin that registers that provider dynamically.

Research basis (read 2026-11-24):

- [Providers — custom providers & packages](https://opencode.ai/docs/providers/):
  `providers.<id>.package` accepts native `@opencode/ai/providers/*` runtimes, npm packages, or
  absolute `file://` paths.
- Provider package contract in anomalyco/opencode: `packages/ai/src/provider-package.ts` — a
  package exports `model(modelID, settings) => LanguageModel`.
- [Server plugins](https://opencode.ai/docs/build/plugins/server/):
  `ctx.provider.transform((editor) => editor.add({ info, models }))` registers providers from a
  plugin; `ctx.integration.transform` can add a command-based login method (`vibe login`).
- Reference implementation to copy: [PR #65489](https://github.com/anomalyco/opencode/pull/65489)
  — the Antigravity ACP provider (`packages/core/src/plugin/provider/antigravity/`, incl.
  `language-model/antigravity-language-model.ts`), still open. Also the built-in `claude-agent`
  provider as the "CLI as provider" precedent.

## 2. The two pieces

### Piece 1 — provider runtime package (`packs/vibe-acp/plugins/vibe-acp/provider/`)

A small TS package implementing the `ProviderPackage` contract
(`export const model = (modelID, settings) => LanguageModel`). Its `doStream`/`doGenerate`:

- spawns `vibe acp` lazily on the first turn, closes it when the plugin scope ends, restarts it
  if the process died;
- speaks ACP over stdio (newline-delimited JSON-RPC; use `@agentclientprotocol/sdk`):
  `initialize` → one `session/new` **per OpenCode session** (closed on `session.deleted`),
  `session/prompt` per turn, turns serialized, `session/cancel` on abort;
- before each turn, `session/set_model` (plus effort/config-option for variants) only when the
  selection changed;
- translates `session/update` into stream parts: text → text-delta, thought → reasoning-delta,
  `tool_call`/`tool_call_update` → **one** tool-call part and **one** tool-result part when the
  call reaches completed/failed (never re-emit — OpenCode stops the turn on duplicate tool call
  IDs, the crash #65489 hit);
- maps the stop reason to a finish reason (`max_tokens`/`max_turn_requests` → length,
  `refusal` → content-filter, `cancelled` → other, else stop) and reports usage;
- answers `session/request_permission` from the host (see M4) instead of refusing;
- discovers models by opening a throwaway session and reading the CLI-reported model list
  (cached between starts); effort suffixes in model names group as variants, the same shape the
  Claude Agent provider uses.

### Piece 2 — registration plugin (`packs/vibe-acp/plugins/vibe-acp/index.ts`)

A server plugin (loaded via `"plugins": [{ "package": "./plugins/vibe-acp" }]` in
`opencode.json(c)`) that:

- registers the provider with
  `ctx.provider.transform((editor) => editor.add({ info: { id: "vibe", name: "Mistral Vibe (ACP)", activation: "enabled" when `vibe` is on PATH, package: "file://" + <plugin install dir> + "/provider" }, models: <discovered list> }))`,
  calling `ctx.provider.reload()` when the CLI reports new models;
- registers a `vibe login` command auth method via `ctx.integration.transform`, so `/connect`
  offers "Sign in with Vibe CLI" — the key never enters OpenCode, `vibe acp` uses Vibe's own
  stored login;
- ships a sample config snippet: `"providers": { "vibe": { "package": "file://…" } }` and
  `"model": "vibe/<model>"`.

## 3. Proposed repo layout (new pack `packs/vibe-acp/`)

```
packs/vibe-acp/
  pack.conf                  # PACK_NAME=vibe-acp, PACK_DEFAULT_DEST=${XDG_CONFIG_HOME:-$HOME/.config}/opencode
  plugins/vibe-acp/
    index.ts                 # Piece 2 (server plugin)
    provider/                # Piece 1 — own package.json, referenced as file:// at runtime
      package.json
      src/index.ts           # exports `model`
  scripts/validate.sh        # JSON/TS syntax, provider package exports `model`, plugin path refs
  docs/  README.md  AGENTS.md
```

Wiring follows the root AGENTS.md extension points: `packs/*/pack.conf` is auto-discovered,
root `scripts/validate.sh` auto-runs the pack validator, the release payload strips
`scripts/` and `docs/`. Alternative considered: shipping the plugin inside `packs/opencode/` —
rejected to keep the opencode pack harness-pure and let `vibe-acp` install standalone.
Alternative: publish the provider package to npm instead of `file://` — decide in M5; `file://`
inside the installed pack is the zero-publish path.

## 4. Cross-cutting semantics & risks

- **Provider-executed tools**: the ACP agent runs its own tools; OpenCode surfaces them as
  provider-executed calls, it does not run them. Map `session/request_permission` to OpenCode's
  permission rules for the running agent (edit/delete/move → `edit`, execute → `bash`,
  read → `read`, search → `grep`, fetch → `webfetch`); plan mode and deny rules then apply to
  what the agent *asks about*. Anything the CLI's own settings allow without asking bypasses
  OpenCode's rules — document this (cf. anomalyco/opencode#53530).
- **ToS risk**: vendors may forbid wrapping their ACP runtime inside a third-party harness
  (Google's Antigravity terms do — quoted in #65489 / #28889). The same question applies to
  Mistral; the M1 spike must record what `vibe acp` advertises, and we should get Mistral's
  blessing before shipping publicly.
- **Runtime**: spawning a child process works in the CLI server (Node/Bun). Core also targets
  workerd (console/Cloudflare) — keep the ACP client behind an import stub like #65489's
  `#antigravity-acp`, or scope the pack to CLI installs.
- **API stability**: the `ProviderPackage`/`LanguageModel` contract lives in `@opencode/ai` and
  is only indirectly documented — pin the version, treat it as semi-public.
- **Not this**: a regular `MISTRAL_API_KEY` with the built-in `mistral` provider keeps working
  but loses the Vibe allowance — that is the fallback, not the goal.

## 5. Milestones & acceptance

- **M1 — spike** (throwaway script, no repo changes): spawn `vibe acp`, `initialize`,
  `session/new`, read the reported models, run one turn incl. a tool call and a permission
  request, observe stop reasons / usage / cancel. Write up the ACP surface and the ToS
  question. Acceptance: transcript + notes on the issue.
- **M2 — provider package**: Piece 1 complete; unit tests feed `tool_call` + `tool_call_update`
  through the stream, finish-reason mapping, one ACP session per OpenCode session, `set_model`
  on change only, dead-process replacement. Acceptance: tests green + one real turn against a
  signed-in `vibe`.
- **M3 — plugin**: Piece 2 complete; OpenCode with the pack installed lists `vibe/<model>` in
  `/models` without manual config; `/connect` offers `vibe login`; reload shows newly reported
  models. Acceptance: manual run + pack validator green.
- **M4 — semantics**: permission mapping + single tool-call/result emission + plan-mode behavior
  verified against a real turn; doc note on what bypasses OpenCode's rules.
- **M5 — packaging**: `./install.sh --source vibe-acp` into a throwaway config dir produces the
  plugin + provider; root `scripts/validate.sh` green; release payload hygiene; README/AGENTS.md;
  `file://` vs npm decision recorded.

## 6. Open questions

- Exact `vibe acp` subcommand/flags and ACP protocol version (confirm in M1).
- Does `vibe` expose effort levels in model names (variants) the way `agy` does?
- Windows support for stdio child processes (should be fine; verify).
- Publish the provider package on npm under the org, or keep `file://` only?
