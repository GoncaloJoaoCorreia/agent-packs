# vibe-acp pack

Use a **Mistral Vibe subscription from OpenCode** by driving the `vibe-acp` binary over the
Agent Client Protocol and exposing it as a normal `vibe/<model>` provider — **no fork of
OpenCode**: a server plugin registers the provider on supported extension points, and a small
provider runtime package (AI SDK model) speaks ACP to the CLI.

Tracked by Linear G-83 (sub-issues G-84…G-88: spike, provider package, plugin, permission
semantics, packaging). Plan: [../vibe/docs/acp-interop-plan.md](../vibe/docs/acp-interop-plan.md);
M1 spike notes: [../vibe/docs/acp-spike/notes.md](../vibe/docs/acp-spike/notes.md).

## Install

```sh
./install.sh vibe-acp          # or: install.sh all
```

Installs `plugins/vibe-acp/` into the OpenCode config dir
(`${XDG_CONFIG_HOME:-~/.config}/opencode`), which OpenCode auto-discovers — no config edit
needed. `--dest DIR` targets a different config dir; `--no-plugin` skips the plugin.

## Use

```sh
vibe-acp --setup               # sign in once with the Vibe CLI (or /connect → "Sign in with Vibe CLI")
```

Then in OpenCode: `/models` lists the discovered `vibe/<model>` entries (from the CLI's model
select), pick one or set `"model": "vibe/<model>"` — see `snippets/opencode.jsonc`.

## Layout

```
packs/vibe-acp/
  pack.conf                          # pack manifest (payload: plugins/, ship-only: snippets/)
  plugins/vibe-acp/
    index.ts                         # server plugin: provider transform, model discovery, vibe login
    package.json
    provider/                        # provider runtime package (loaded via aisdk:file://…/src/index.ts)
      package.json
      src/                           # jsonrpc/client/sessions/renderer/language-model/permissions/protocol
      test/                          # node --test unit tests + sandboxed real-turn e2e (VIBE_ACP_E2E=1)
      README.md
  snippets/opencode.jsonc            # sample config snippet (shipped, not installed)
  scripts/validate.sh                # repo-only: JSON/TS checks, provider tests, throwaway-install tests
  docs/permissions.md                # repo-only: permission semantics (M4)
  README.md, AGENTS.md               # repo-only docs (stripped from the release payload)
```

## Decisions (recorded per G-87)

- **`file://` inside the installed pack, not npm** — zero-publish path; the provider package is
  referenced as `aisdk:file://<config>/plugins/vibe-acp/provider/src/index.ts` (entry file — a
  bare directory does not resolve in the compiled CLI runtime). Publishing to npm is possible
  later.
- **Host-resolved dependencies**: `@opencode/plugin` and `@ai-sdk/provider` (type-only) resolve
  against the OpenCode runtime; the provider package itself has **zero runtime deps** (hand-rolled
  NDJSON JSON-RPC), so installs need no `node_modules` (release payloads strip them anyway).
  Requires OpenCode ≥ 2.4.x (the `aisdk:` package bridge + `ctx.provider.transform`).
- **workerd/console**: the ACP client (node:child_process) is imported lazily; on runtimes
  without child processes the plugin loads but cannot spawn the CLI — the pack is scoped to
  CLI installs.
- **ToS**: Mistral's consumer ToS §3(g) forbids integrating Vibe with third-party products
  without prior written authorization (see the M1 spike notes). Personal ACP use is the intended
  path; **get Mistral's written OK before distributing this pack publicly**.

## Verify

```sh
sh scripts/validate.sh                     # root dispatcher runs this pack's validator too
sh packs/vibe-acp/scripts/validate.sh      # JSON/TS checks, provider unit tests, throwaway install
cd packs/vibe-acp/plugins/vibe-acp/provider && npm test
```
