# @agent-packs/vibe-acp-provider

The provider runtime package for Mistral Vibe over ACP (plan §2 piece 1, G-86). OpenCode loads
it through the `aisdk:` package bridge:

```jsonc
{
  "providers": {
    "vibe": {
      "name": "Mistral Vibe (ACP)",
      "package": "aisdk:file:///abs/path/to/plugins/vibe-acp/provider"
    }
  }
}
```

Core's dynamic-provider plugin finds the `create*` export (`createVibeAcpProvider`), calls it with
the provider's `settings`, and expects an AI SDK provider back; each `languageModel(modelID)`
drives the `vibe-acp` binary over the Agent Client Protocol (NDJSON JSON-RPC on stdio, protocol
version 1 — see `src/protocol.ts` and `src/acp.ts` for the wire surface this package implements).

## Layout

- `src/jsonrpc.ts` — dependency-free newline-delimited JSON-RPC connection (loads in any runtime).
- `src/client.ts` — spawns `vibe-acp`, `initialize`, `session/new`, `session/set_mode` ("ask"),
  `session/set_config_option` (model / thinking), `session/prompt`, `session/cancel`,
  `session/close`; answers `session/request_permission`.
- `src/sessions.ts` — one ACP session per OpenCode session (header `x-opencode-session-id`),
  turns serialized, config set only on change, dead process replaced, permission requests routed
  through the `assert` hook.
- `src/renderer.ts` — ACP updates → AI SDK `LanguageModelV3` stream parts; each agent tool call
  is emitted exactly once with its result on completed/failed (vibe-acp duplicates every
  `tool_call`/`tool_call_update` notification — never re-emit).
- `src/language-model.ts` — the `LanguageModelV3` handed to OpenCode.
- `src/permissions.ts` — ACP tool `kind` → OpenCode permission action mapping.
- `src/index.ts` — `createVibeAcpProvider` (the `aisdk:` factory), `configureVibeAcp` (called by the
  pack's plugin), `discoverModels`, `closeVibeAcp`.

## Tests

```sh
npm test            # unit tests: node --test (node >= 22.18 strips types; no build, no deps)
npm run test:e2e    # one real turn against the signed-in vibe-acp, in a scratch cwd (sandboxed)
```

`test/e2e-real.test.ts` is skipped unless `VIBE_ACP_E2E=1`; it spawns its own `vibe-acp` process
with a fresh temp cwd, so it never touches a running OpenCode/Vibe instance.

## Notes / gotchas

- In Vibe 3.1.4 the ACP binary is **`vibe-acp`**; `vibe acp` is parsed as a prompt. The wire
  method for changing the session mode is **`session/set_mode`** (not `session/set_session_mode`).
- Models are reported in `session/new` → `configOptions` → the `model` select (aliases);
  effort levels are the separate `thinking` select. There is no `session/set_model` extension.
- The default session mode `accept-edits` auto-approves edits without `session/request_permission`;
  the manager always sets mode `ask` so OpenCode's permission rules see every tool call.
- `@ai-sdk/provider` is a type-only import (erased at runtime); the package has no runtime deps.
