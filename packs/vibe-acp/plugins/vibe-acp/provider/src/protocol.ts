// ACP protocol helpers with no Node.js imports, so modules that only need them (sessions,
// permissions, the plugin) also load on runtimes without child processes (workerd/console).
// The process-spawning client (client.ts) is imported lazily by the session manager.

import type { NewSessionResponse, RequestPermissionRequest, RequestPermissionResponse, DiscoveredCatalog } from "./acp.ts"

/** A session/new result: the ACP session id plus the catalog read from its configOptions. */
export interface AcpSessionInfo {
  sessionId: string
  catalog: DiscoveredCatalog
}

/** Refuse a permission request by picking reject_once, else cancel — the agent may not act. */
export function refuse(request: RequestPermissionRequest): RequestPermissionResponse {
  const reject = request.options.find((option) => option.kind === "reject_once")
  return reject
    ? { outcome: { outcome: "selected", optionId: reject.optionId } }
    : { outcome: { outcome: "cancelled" } }
}

/** Pick allow_once / reject_once from the agent's offered options. */
export function choose(request: RequestPermissionRequest, allowed: boolean): RequestPermissionResponse {
  const kinds = allowed ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
  for (const kind of kinds) {
    const option = request.options.find((candidate) => candidate.kind === kind)
    if (option) return { outcome: { outcome: "selected", optionId: option.optionId } }
  }
  return { outcome: { outcome: "cancelled" } }
}

/** Read the model catalog out of a session/new response's configOptions. */
export function catalogOf(response: NewSessionResponse): DiscoveredCatalog {
  const options = response.configOptions ?? []
  const model = options.find((c) => c.category === "model" || c.id === "model")
  const thinking = options.find((c) => c.category === "thinking" || c.id === "thinking")
  const mode = options.find((c) => c.category === "mode" || c.id === "mode")
  return {
    models: (model?.options ?? []).map((o) => ({ id: o.value, name: o.name ?? o.value, description: o.description })),
    thinking: { current: thinking?.currentValue, levels: (thinking?.options ?? []).map((o) => o.value) },
    modes: {
      current: response.modes?.currentModeId ?? mode?.currentValue,
      available: (response.modes?.availableModes ?? mode?.options ?? []).map((m) => m.id ?? m.value),
    },
  }
}
