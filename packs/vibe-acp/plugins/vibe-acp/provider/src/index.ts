// @agent-packs/vibe-acp-provider — the provider runtime package (plan §2 piece 1).
//
// Loaded by OpenCode as `providers.vibe.package = "aisdk:file://<pack>/plugins/vibe-acp/provider"`.
// Core's dynamic-provider plugin looks for an export whose name starts with `create`, calls it
// with the provider's `settings`, and expects an AI SDK provider back: `{ languageModel(id) }`.
// Each language model drives the `vibe-acp` binary over ACP (see client.ts / sessions.ts).
//
// The pack's server plugin (../index.ts) calls `configureVibeAcp()` once at setup to hand in the
// project directory, the permission `assert` hook, and a model-catalog callback.

import { SessionManager, type SessionManagerOptions } from "./sessions.ts"
import { VibeAcpLanguageModel } from "./language-model.ts"
import type { DiscoveredCatalog } from "./acp.ts"
import type { PermissionCheck } from "./permissions.ts"

export interface VibeAcpProviderOptions {
  /** Project directory the ACP sessions run in. Defaults to the configured directory or cwd. */
  directory?: string
  /** CLI to spawn. Default "vibe-acp" (Vibe 3.1.4; try ["vibe", "acp"] on versions that alias it). */
  command?: string
  args?: string[]
}

export interface VibeAcpHooks {
  directory?: string
  /** Asks OpenCode whether the ACP agent may act (permission.assert). */
  assert?: (check: PermissionCheck) => Promise<boolean>
  /** Called when the CLI reports a new model catalog — the plugin reloads the provider. */
  onModels?: (catalog: DiscoveredCatalog) => void
}

let manager: SessionManager | undefined
let hooks: VibeAcpHooks = {}

/** Called by the pack's server plugin at setup. Safe to call again (merges). */
export function configureVibeAcp(next: VibeAcpHooks): void {
  hooks = { ...hooks, ...next }
}

function sharedManager(options: VibeAcpProviderOptions): SessionManager {
  if (!manager) {
    const managerOptions: SessionManagerOptions = {
      directory: hooks.directory ?? options.directory ?? process.cwd(),
      client: { command: options.command, args: options.args },
      assert: hooks.assert,
      onModels: hooks.onModels,
    }
    manager = new SessionManager(managerOptions)
  }
  return manager
}

/**
 * The `create*` export OpenCode's `aisdk:` bridge looks for. Returns an AI SDK provider whose
 * `languageModel(modelID)` is the ACP-backed model.
 */
export function createVibeAcpProvider(options: VibeAcpProviderOptions = {}) {
  const manager = sharedManager(options)
  return {
    languageModel: (modelID: string) => new VibeAcpLanguageModel(modelID, manager),
  }
}

/** Lists the models the signed-in `vibe` reports (throwaway ACP session). For the plugin. */
export async function discoverModels(options: VibeAcpProviderOptions = {}): Promise<DiscoveredCatalog> {
  return sharedManager(options).discover()
}

/** Closes the shared ACP process. Called by the plugin on unload. */
export async function closeVibeAcp(): Promise<void> {
  const current = manager
  manager = undefined
  await current?.close()
}

/** Closes the ACP session of a deleted OpenCode session. Called by the plugin's event hook. */
export async function removeSession(sessionID: string): Promise<void> {
  await manager?.remove(sessionID)
}

export { SessionManager } from "./sessions.ts"
export { VibeAcpLanguageModel, SESSION_HEADER, AGENT_HEADER, KIND_HEADER } from "./language-model.ts"
export { AcpClient } from "./client.ts"
export { catalogOf, choose, refuse } from "./protocol.ts"
export { makeRenderer, finishReason, usageOf } from "./renderer.ts"
export { ACTIONS, toPermission } from "./permissions.ts"
export type { DiscoveredCatalog, DiscoveredModel } from "./acp.ts"
export type { PermissionCheck } from "./permissions.ts"
