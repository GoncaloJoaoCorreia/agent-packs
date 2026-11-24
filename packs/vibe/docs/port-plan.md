# Port plan: `packs/vibe/` — driver SDLC for Mistral Vibe

Status: proposed (tracked by the Linear issue in project **Agent Packs**).
Research basis: [mistralai/mistral-vibe](https://github.com/mistralai/mistral-vibe) +
[docs.mistral.ai/vibe](https://docs.mistral.ai/vibe/code/overview) (CLI config, agents,
skills, plugins, hooks, MCP/connectors, programmatic mode), read 2026-11-24.

## 1. Goal

Ship a second pack, `packs/vibe/`, that runs the **driver** feature cycle on
[Mistral Vibe](https://github.com/mistralai/mistral-vibe) (Apache-2.0, Python CLI + Rust
TUI). The pack reuses the harness-agnostic assets **unchanged**:

- `shared/driver-conventions/` (SKILL.md + `references/` JSON schemas) — the single source
  of truth for `.plan/<slug>/state.json`, `manifest.json`, commit messages, slug/branch/
  worktree policy.
- `shared/agent-scripts/` (`driver-state.py`, `detect-forge.sh`, `qa-command.sh`,
  `save-linear-attachments.py` + tests).

The opencode pack (`packs/opencode/`) stays the reference implementation; both packs compose
the same `shared/` dirs, so the on-disk driver contracts stay byte-compatible across
harnesses.

## 2. Vibe extension points we map onto (research summary)

| Vibe mechanism | Config location | Used for |
|---|---|---|
| Skills (agentskills.io spec, `SKILL.md`) | `~/.vibe/skills/`, `./.vibe/skills/`, `./.agents/skills/`, `skill_paths` | `/driver` slash command + `driver-conventions` skill |
| Agents / subagents (TOML) | `~/.vibe/agents/*.toml`, `agent_type = "agent" \| "subagent"` | driver orchestrator + 8 phase subagents; prompts via `system_prompt_id` → `~/.vibe/prompts/*.md` |
| Hooks (`hooks.toml`) | `~/.vibe/hooks.toml` (+ project `.vibe/hooks.toml`, trusted) | push guard, spawn guard, phase-summary enforcement, progress notifications |
| Tool permissions | `enabled_tools`/`disabled_tools`, `[tools.<t>] permission/allowlist/denylist` | permission mapping (push deny, Linear read-only, edit scoping) |
| MCP servers | `[[mcp_servers]]` in `config.toml` | `linear-project` (https://mcp.linear.app/mcp) |
| Connectors | Mistral-managed | optional GitHub connector for the pr phase |
| Programmatic mode | `vibe -p --auto-approve --output-dir DIR`, exit codes, `export.json`, `--agent-socket`, `vibe run-server` | headless/CI driver cycles |
| Worktree | native `vibe --worktree` | `--worktree` flag |

## 3. Target layout

```
packs/vibe/
  pack.conf                  # PACK_NAME=vibe, PACK_DEFAULT_DEST=${VIBE_HOME:-$HOME/.vibe},
                             # PACK_PAYLOAD="agents skills prompts hook-scripts-as-compose?" (see below),
                             # PACK_FILES="hooks.toml:hooks.toml" (new installer key, §6),
                             # PACK_COMPOSE="shared/agent-scripts:agent-scripts
                             #   shared/driver-conventions:skills/driver-conventions
                             #   packs/vibe/hook-scripts:agent-scripts",
                             # PACK_PREREQS="vibe python3 git"
  agents/
    driver.toml              # orchestrator, agent_type="agent", system_prompt_id="driver"
    driver-<phase>.toml      # 8 phase subagents (preplan, plan, implement, spec-audit,
                             #   code-review, quality-gate, pr, plan-thorough variant)
    <phase>.toml             # user-facing twins (replace commands/phases/*.md wrappers)
  prompts/
    driver.md                # ported body of packs/opencode/agents/driver.md
    driver-<phase>.md        # ported bodies of packs/opencode/agents/driver/*.md
  skills/
    driver/SKILL.md          # /driver command (from packs/opencode/commands/driver.md)
  hook-scripts/              # python/shell hook payloads (push guard, spawn guard, ...)
  hooks.toml                 # installed to $VIBE_HOME/hooks.toml via PACK_FILES
  scripts/validate.sh        # pack validator, auto-run by root scripts/validate.sh
  docs/  README.md  AGENTS.md
```

Installed result under `${VIBE_HOME:-~/.vibe}`: `agents/`, `prompts/`, `skills/driver/`,
`skills/driver-conventions/` (composed), `agent-scripts/` (composed shared + hook-scripts),
`hooks.toml`, plus `agent-packs.vibe.version` / `.manifest`.

## 4. Component mapping

| opencode pack | vibe pack | Notes |
|---|---|---|
| `agents/driver.md` (frontmatter permissions + prose) | `agents/driver.toml` + `prompts/driver.md` | prose mostly unchanged; `SCRIPTS` path → `${VIBE_HOME:-$HOME/.vibe}/agent-scripts`; `OPENCODE_SESSION_ID` → `VIBE_SESSION` |
| `agents/driver/<phase>.md` ×8 | `agents/driver-<phase>.toml` (subagent) + `prompts/driver-<phase>.md` | prompt bodies port verbatim |
| `commands/driver.md` (`!` static blocks, `$ARGUMENTS`) | `skills/driver/SKILL.md` (user-invocable → `/driver`) | no template engine: flags parsed from the message text; repo root/branch/dirty list via read-only git commands the agent runs itself, or a `session_start` hook injecting `additional_context` |
| `commands/phases/<phase>.md` | user-facing `agents/<phase>.toml` (`agent_type="agent"`, same `system_prompt_id`) | selectable via `--agent` / Shift+Tab instead of `/phases/<phase>` |
| frontmatter `permissions:` | TOML `enabled_tools`/`disabled_tools`/`[tools.x]` + `hooks.toml` | see §5 |
| `opencode.json` MCP `linear-project` | `[[mcp_servers]]` in user `config.toml`; `pack_extra_checks()` warns + prints `vibe mcp add linear --url https://mcp.linear.app/mcp` | never write user `config.toml` from the installer |
| `--worktree` + session move | native `vibe --worktree <path>` (auto-trusted) | simpler than the OpenCode session-move |
| `plugins/driver-viz/` (TUI sidebar) | **does not port** — see §5.3 | hooks + CLI watcher instead |
| `snippets/gitignore.txt` | same snippet in `packs/vibe/snippets/` (ship-only) | `.plan/` gitignore hint in `pack_next_steps()` |

## 5. Ports unchanged / compromises / does-not-port

### 5.1 Unchanged

- `shared/driver-conventions/` → `skills/driver-conventions/SKILL.md`: Vibe follows the
  agentskills.io spec, so the file ports with frontmatter normalization only (`name` must be
  lowercase-hyphenated, description ≤1024 chars). `references/*.json` ship as extra files.
- `shared/agent-scripts/` → `$VIBE_HOME/agent-scripts/`: logic unchanged; only the install
  path and the session-env detection (`VIBE_SESSION=1`) change.
- All `.plan/<slug>/` file contracts (state.json, manifest.json, commit format, slug regex
  `^[A-Z][A-Z0-9]*-[0-9]+$`) — byte-compatible; same schemas in `references/`.
- Phase prompt prose, the phase registry, VARIANTS table, golden rules (idempotent state,
  thin context, driver owns loops, foreground spawns, no untrusted interpolation).

### 5.2 Compromises

- **No command templates.** No `!` blocks / `$ARGUMENTS` interpolation in skills. Static
  repo context moves into the skill text as read-only commands the agent runs, or into a
  `session_start` hook (`hook_specific_output.additional_context`).
- **Subagents cannot use MCP/connector/plugin tools** (built-in tools only, text-only
  results). Consequences:
  - `preplan`'s Linear fetch happens in the **main agent** (MCP `linear-project_*`) and is
    passed to the subagent as text, or via `bash` + curl. Read-only enforcement stays via
    tool permissions: `disabled_tools = ["linear_project_save_*", "linear_project_create_*",
    "linear_project_update_*", "linear_project_delete_*", …]` on every agent.
  - Text-only subagent results fit the existing phase-summary contract (phases already
    return short summaries).
- **Subagents cannot ask the user questions** (and `ask_user_question` is off in
  `vibe -p`). Preplan confirmations (QA command, forge, dirty tree) rely on flags plus the
  existing `git config driver.qa` / `driver.forge` caches; anything unresolved uses a safe
  default in headless mode and a question in the interactive main session. This also removes
  the OpenCode "headless not supported" limitation — `vibe -p` is fully supported.
- **Depth-1 nesting**: `enable_subagents = false` in every phase agent + a `pre_tool` hook
  with `match = "agents_spawn"` as defense-in-depth.
- **Permission model is tool-centric**: `git push` denied everywhere except the pr agent via
  `[tools.bash] denylist = ["git push"]` (prefix match; chained `x; git push` is blocked
  unless every part is allowed — stricter than the OpenCode glob). Driver gets
  `disabled_tools = ["edit", "write_file"]` and writes state only through `driver-state.py`
  over bash (which the conventions already mandate). `permission = "always"` on bash
  replaces `shell *: allow`.

### 5.3 Does not port

- **driver-viz TUI sidebar.** Vibe's Agent Plugins 1.0 format has no UI/TUI components and
  the Rust TUI is closed. Replacement, in increasing order of effort:
  1. `post_agent` hooks (matched per phase subagent) emitting a one-line phase status as
     `system_message`, plus `notification` hooks on turn completion.
  2. A harness-agnostic CLI watcher `shared/agent-scripts/driver-viz.py` that renders the
     7-phase stepper from `.plan/<slug>/state.json` to stdout (port of
     `plugins/driver-viz/lib/state.ts` derivations — pure logic) for tmux/terminal splits.
  3. Headless: `vibe -p --output-dir` writes `export.json` (usage, cost, steps, outcome,
     warnings) per run — the machine-readable equivalent of the completion block.

## 6. Installer / repo wiring changes

1. **`install.sh` + `scripts/validate.sh`: add `PACK_FILES`** — `src:dst` file entries
   copied into the dest root and tracked in the manifest (payload/compose stay dirs-only).
   Needed for `hooks.toml` → `$VIBE_HOME/hooks.toml`. Safety: if `hooks.toml` exists and is
   not ours (not in the manifest), skip with a warning and print the block for manual merge
   — never clobber user config. This key is generic; future packs (e.g. a `config.toml`
   snippet) will want it too.
2. `packs/vibe/pack.conf`: `PACK_PREREQS="vibe python3 git"`; `pack_extra_checks()` warns when
   no `linear` MCP server is in `~/.vibe/config.toml` (prints the `vibe mcp add …` command),
   mirroring the opencode pack's warning; `pack_next_steps()` prints the `.plan/` gitignore
   line and a `/driver G-1` example.
3. Root `scripts/validate.sh` already discovers `packs/*/pack.conf` and runs every
   `packs/*/scripts/validate*.sh` — no dispatcher change needed; add
   `packs/vibe/scripts/validate.sh` (parse all TOML with python `tomllib`, validate
   `plugin`-free skill frontmatter, hooks.toml syntax, compose/payload paths, prompt-file
   references `system_prompt_id` ↔ `prompts/*.md`).
4. Root `README.md`: list the vibe pack. `packs/README.md` "Adding a pack" already covers the
   flow. Release workflow payload is `packs/ shared/ install.sh LICENSE` (generic) — verify
   its self-test handles two packs and that `packs/vibe/scripts|docs` are stripped.
5. `install.sh` no-TTY default stays `opencode when present`; the picker lists both.

## 7. Milestones & acceptance criteria

- **M1 — PoC (spike, throwaway `VIBE_HOME`)**: hand-install a `driver` skill + orchestrator
  agent + one phase subagent + one hook into a temp `~/.vibe/`; verify in a scratch repo:
  skill appears as `/driver`, subagent spawns and returns text, `agents_spawn` hook fires,
  `denylist = ["git push"]` blocks `git push` (incl. chained), MCP tools are absent in
  subagents, `vibe -p --auto-approve` runs headless. Document surprises in this file.
- **M2 — scaffold**: `packs/vibe/` per §3 + `PACK_FILES` in installer/validator; acceptance:
  `VIBE_HOME=$(mktemp -d) ./install.sh --source vibe` produces the full dest tree incl.
  composed `agent-scripts/` and `skills/driver-conventions/` + meta files; root
  `scripts/validate.sh` green; re-run cleans stale files via the manifest.
- **M3 — port assets**: conventions skill, agent-scripts, orchestrator + 8 phase agents +
  `/driver` skill + user-facing phase agents + `hooks.toml`; permissions mapped per §5.2.
  Acceptance: `packs/vibe/scripts/validate.sh` green; TOML parses; every `system_prompt_id`
  has a prompt file; prompt bodies diff clean against the opencode originals except for the
  documented path/harness substitutions.
- **M4 — end-to-end**: in a scratch repo, an interactive `/driver <test-issue>` runs all 7
  phases and writes a schema-valid `.plan/<slug>/state.json`; a headless
  `vibe --agent driver -p "…" --auto-approve --output-dir out/` run exits 0 and produces
  `export.json`; `--worktree` uses native `vibe --worktree`.
- **M5 — viz replacement + docs + release**: hooks-based progress + `driver-viz.py` watcher;
  pack README/AGENTS.md, root README; release workflow self-test passes with both packs;
  `./install.sh --list` shows both.

## 8. Vibe-native opportunities to adopt

- **Headless cycles & CI**: `vibe -p` with `--max-turns/--max-price/--max-tokens/
  --time-limit`, defined exit codes, `export.json` → generate the cycle `report.md` partly
  from the harness export. `vibe run-server` + `--agent-socket` sandboxes run many cycles in
  one process (JSON-RPC `run/start` → `run/ended`); Vibe ships a GitHub `action.yml` —
  follow-up: drive one cycle per Linear issue label in CI, fully sandboxed.
- **`vibe --worktree`** (auto-trusted) for `--worktree`; `/pr` (session PRs, jump to first
  failing CI check), `/loop` (recurring prompts — a lightweight monitor), `/rewind` +
  `/resume` map to driver resume/fix-rounds.
- **Hooks as the guardrail layer**: push denylist, spawn guard, `post_agent` deny+retry
  (≤3) to mechanically enforce the phase-summary/state contract; hooks inherit into
  subagents transitively.
- **Connectors**: Mistral-managed GitHub connector as an alternative to `gh/glab` in the pr
  phase (keeps forge CLIs as fallback via `detect-forge.sh`).
- **Admin-managed config** can centrally pin driver policy (e.g. block `auto-approve`
  outside CI); `strict_config = true` + `vibe config schema` validate our shipped config.

## 9. Risks & open questions

- **Vibe plugin format is experimental** — we avoid plugins entirely (loose user-level
  install into `$VIBE_HOME`), so only stable surfaces are used (skills/agents/hooks/MCP).
  Still: monitor Vibe's CHANGELOG for agentskills/hooks breaking changes.
- **Trusted folders**: project-level `.vibe/` requires trust; our pack installs user-level
  (`~/.vibe/`), which always loads. Document that `--add-dir`/project installs need trust.
- **MCP tool naming** is `{server}_{tool}`; confirm exact Linear server name/prefix
  (`linear` vs `linear-project`) in M1 and pin the `disabled_tools` globs accordingly.
- **Windows**: `run-server`/`--agent-socket` unsupported on Windows; the interactive CLI and
  `vibe -p` work — keep CI fan-out POSIX-only.
- **Concurrency defaults**: `max_subagents` default 32 — driver fan-out is sequential per
  phase, fine; depth-1 enforced per §5.2.
- OpenCode-specific leftovers to consciously drop: `!` blocks, `hidden: true` (driver agent
  becomes user-selectable — acceptable), subagent MCP access, driver-viz TUI.
