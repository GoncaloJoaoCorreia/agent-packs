// Server plugin (plan §2 piece 2, G-85): makes the ACP-backed `vibe` provider appear in OpenCode
// with zero manual config.
//
// - registers the provider via ctx.provider.transform, with `package` pointing at the provider
//   runtime (./provider) through the `aisdk:file://` bridge, and the model list discovered from
//   the `vibe-acp` CLI (cached in plugin storage so /models works before the CLI is spawned);
// - reloads the provider when the CLI reports a new model catalog;
// - adds a `vibe login` command auth method via ctx.integration.transform, so /connect offers
//   "Sign in with Vibe CLI" — the key never enters OpenCode, `vibe-acp` uses Vibe's own login;
// - forwards session/agent/kind to the provider package via model.request headers, and closes
//   the ACP session when an OpenCode session is deleted.

import { Integration, Model, Plugin, Provider } from "@opencode/plugin"
import { accessSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import {
  AGENT_HEADER,
  closeVibeAcp,
  configureVibeAcp,
  discoverModels,
  KIND_HEADER,
  removeSession,
  SESSION_HEADER,
  type DiscoveredCatalog,
} from "./provider/src/index.ts"

export const PROVIDER_ID = "vibe"
const CATALOG_KEY = "catalog"

const here = dirname(fileURLToPath(import.meta.url))
/**
 * The provider runtime, referenced through OpenCode's `aisdk:` package bridge. The path must
 * name the entry file (importing a bare directory does not resolve package.json exports in the
 * compiled CLI runtime).
 */
const providerPackage = "aisdk:file://" + join(here, "provider", "src", "index.ts")

function onPath(bin: string): boolean {
  for (const dir of (process.env.PATH ?? "").split(":")) {
    if (!dir) continue
    try {
      accessSync(join(dir, bin))
      return true
    } catch {
      // keep scanning PATH
    }
  }
  return false
}

function cliCommand(): { command: string; args: string[] } {
  // Vibe 3.1.4 ships the ACP server as the separate `vibe-acp` binary; `vibe acp` is only a
  // prompt there. Newer versions may alias `vibe acp` — prefer the dedicated binary.
  if (onPath("vibe-acp")) return { command: "vibe-acp", args: [] }
  return { command: "vibe", args: ["acp"] }
}

function toModels(catalog: DiscoveredCatalog | undefined) {
  const providerID = Provider.ID.make(PROVIDER_ID)
  return (catalog?.models ?? []).map((model) => ({
    ...Model.Info.default(providerID, Model.ID.make(model.id)),
    name: model.name,
  }))
}

export default Plugin.define({
  id: "agent-packs.vibe-acp",
  async setup(ctx) {
    const cli = cliCommand()
    const installed = onPath(cli.command)
    const providerID = Provider.ID.make(PROVIDER_ID)

    // Cached catalog: /models lists vibe/<model> immediately, before the CLI is ever spawned.
    const cached = (await ctx.storage.get(CATALOG_KEY)) as DiscoveredCatalog | undefined
    let catalog = cached

    configureVibeAcp({
      directory: ctx.location.directory,
      // Answer the ACP agent's permission requests from OpenCode's rules for the running agent.
      assert: async (check) => {
        try {
          await ctx.permission.assert({
            sessionID: check.sessionID,
            ...(check.agent !== undefined ? { agent: check.agent } : {}),
            action: check.action,
            resources: [...check.resources],
            metadata: check.metadata,
          })
          return true
        } catch {
          return false
        }
      },
      onModels: (next) => {
        catalog = next
        void ctx.storage
          .set(CATALOG_KEY, next as unknown as Record<string, unknown>)
          .then(() => ctx.provider.reload())
          .catch((error) => console.error("vibe-acp: could not persist the model catalog", error))
      },
    })

    await ctx.provider.transform((editor) => {
      if (editor.get(PROVIDER_ID)) return
      editor.add({
        info: {
          ...Provider.Info.empty(providerID),
          name: "Mistral Vibe (ACP)",
          activation: installed ? "enabled" : "disabled",
          package: providerPackage,
          integrationID: Integration.ID.make(PROVIDER_ID),
          settings: { command: cli.command, args: cli.args },
        },
        models: toModels(catalog),
      })
    })

    // /connect → "Sign in with Vibe CLI": runs the CLI's own setup; no key is stored in OpenCode.
    await ctx.integration.transform((editor) => {
      editor.update(PROVIDER_ID, (integration) => {
        integration.name = "Mistral Vibe"
      })
      editor.method.update({
        integrationID: PROVIDER_ID,
        method: {
          id: "vibe-login",
          type: "command",
          label: "Sign in with Vibe CLI",
          command: [cli.command, ...cli.args, "--setup"],
        },
      })
    })

    // Tell the provider package which OpenCode session/agent/kind each model request belongs to.
    await ctx.session.hook(
      "model.request",
      (event) => {
        event.headers[SESSION_HEADER] = event.sessionID
        event.headers[AGENT_HEADER] = event.agent
        event.headers[KIND_HEADER] = event.kind
      },
      { providerID: PROVIDER_ID },
    )

    // Close the ACP session when its OpenCode session is deleted.
    const controller = new AbortController()
    void (async () => {
      for await (const event of ctx.event.subscribe({ types: ["session.deleted"], signal: controller.signal })) {
        const sessionID = (event as { data?: { sessionID?: string } }).data?.sessionID
        if (sessionID) void removeSession(sessionID)
      }
    })()

    // Discover the models in the background when the CLI is installed and nothing is cached yet.
    if (installed && (catalog?.models.length ?? 0) === 0) {
      void discoverModels({ command: cli.command, args: cli.args }).catch((error) =>
        console.error("vibe-acp: model discovery failed", error),
      )
    }

    return () => {
      controller.abort()
      void closeVibeAcp()
    }
  },
})
