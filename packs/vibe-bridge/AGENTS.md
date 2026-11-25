# AGENTS.md — vibe-bridge pack

The **vibe-bridge** pack of [agent-packs](../../README.md) — Mistral Vibe (`vibe-acp`) as an
OpenCode `vibe/<model>` provider over ACP, with no OpenCode fork. Two pieces on supported
extension points (plan: [../vibe/docs/acp-interop-plan.md](../vibe/docs/acp-interop-plan.md),
Linear G-83):

1. **provider runtime package** — `plugins/vibe-bridge/provider/`: a dependency-free TS package
   exporting `createVibeAcpProvider` (the `create*` factory OpenCode's `aisdk:` package bridge
   loads), whose `languageModel(modelID)` spawns `vibe-acp` and translates ACP stdio into an
   AI SDK `LanguageModelV3` stream.
2. **server plugin** — `plugins/vibe-bridge/index.ts` (auto-discovered at
   `<config>/plugins/vibe-bridge/`): registers the provider via `ctx.provider.transform`, discovers
   models from the CLI (cached in `ctx.storage`, `ctx.provider.reload()` on change), adds the
   `vibe login` command auth method via `ctx.integration.transform`, forwards session/agent/kind
   headers on `model.request`, closes ACP sessions on `session.deleted`, and wires
   `ctx.permission.assert` as the ACP permission handler.

## Install / verify

- `./install.sh vibe-bridge` (root) copies `plugins/` into
  `${XDG_CONFIG_HOME:-~/.config}/opencode` (copy-based; `--dest DIR` for a throwaway config,
  `--no-plugin` skips it). Meta files `agent-packs.vibe-bridge.{version,manifest}` drive stale-file
  cleanup on reinstall (the pre-rename `agent-packs.vibe-acp.*` meta files are cleaned up once).
  `snippets/` is ship-only. The release tarball
  (`packs/vibe-bridge.tar.gz`) strips `scripts/`, `docs/`, and this file automatically and
  carries `install.sh` + a vendored `install-lib.sh`.
- `sh scripts/validate.sh` (root) auto-runs `packs/vibe-bridge/scripts/validate.sh`: pack.conf
  syntax, JSON validity, plugin/provider path references, the `create*` export, the provider
  unit tests, and throwaway-install checks (payload + meta files, stale cleanup, `--no-plugin`,
  `--list`). **Re-run after every edit here.**
- Provider tests: `cd plugins/vibe-bridge/provider && npm test` (node ≥ 22.18 strips TS types, no
  build). `npm run test:e2e` runs one real turn against the signed-in `vibe-acp` in a scratch cwd
  (sandboxed — own child process, temp dir; never touches a running OpenCode/Vibe instance).
- Live smoke (sandboxed: throwaway `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`XDG_STATE_HOME`/
  `XDG_CACHE_HOME`, scratch project): install into the temp config, then `opencode --standalone
  models` lists `vibe/<model>`; `opencode --standalone run --model vibe/<model> "…"` completes a
  real ACP turn.

## Layout

```
pack.conf                # pack metadata (name, description, dest, meta prefix, prereqs); payload dirs live in install.sh
install.sh               # pack-owned installer: PACK_PAYLOAD_DIRS="plugins" (+ hooks)
plugins/vibe-bridge/
  index.ts               # server plugin (provider transform + integration + hooks)
  provider/              # runtime package — src/{jsonrpc,protocol,client,sessions,renderer,
                         #   language-model,permissions,acp}.ts, test/, README.md, package.json
snippets/opencode.jsonc  # sample repo-level config (ship-only)
scripts/validate.sh      # repo-only pack validator (run by root scripts/validate.sh)
docs/permissions.md      # repo-only M4 semantics doc
README.md, AGENTS.md     # repo-only (stripped from release payloads)
```

## Gotchas (hard-earned — do not rediscover)

- Vibe 3.1.4's ACP server is the **separate binary `vibe-acp`** (`vibe acp` is parsed as a
  prompt); ACP protocol v1, NDJSON JSON-RPC on stdio; wire method for the session mode is
  **`session/set_mode`**; models come from `session/new` → `configOptions` `model` select, effort
  from the `thinking` select.
- `providers.vibe.package` must be `aisdk:file://…/provider/src/index.ts` — the **entry file**;
  a bare package directory does not resolve in the compiled CLI runtime.
- vibe-acp sends every `tool_call`/`tool_call_update` **twice** — the renderer dedupes by
  `toolCallId` and emits each call once with its result (OpenCode aborts on duplicate ids).
- Default session mode `accept-edits` auto-approves edits **without** `request_permission` — the
  session manager forces mode `ask` on every new ACP session so OpenCode's rules see every call.
- Updates must reach both the per-prompt listener and the default `onUpdate` (the tool-call
  tracker) — otherwise permission requests map to kind `other` and deny rules don't apply.
- The process-spawning client (`client.ts`, node:child_process) is **lazily imported** so the
  plugin still loads on workerd/console (it just can't spawn the CLI there).
- Installer: `ALL_PACKS` must stay a space-separated word list — a newline-separated list breaks
  the `" $ALL_PACKS "` membership test once 2+ packs exist (fixed in install.sh).
- **ToS**: consumer ToS §3(g) — no integrating Vibe into third-party products without Mistral's
  prior written authorization. Personal use OK; public distribution needs their OK.
