# AGENTS.md — agent-packs

Personal library of agent-harness extensions (**packs**): one self-contained pack per
harness under `packs/<name>/`.
Currently ships three packs: **opencode** (`packs/opencode/`) — the **driver**
(`/driver`, a multi-phase feature-cycle orchestrator) and the **driver-viz** TUI plugin —
**vibe-acp** (`packs/vibe-acp/`) — Mistral Vibe (`vibe-acp` over ACP) as an OpenCode
`vibe/<model>` provider, no OpenCode fork — and **vibe-skills** (`packs/vibe-skills/`) —
a repository of Mistral Vibe skills (Agent Skills `SKILL.md`) installed into
`${VIBE_HOME:-~/.vibe}/skills/` and publishable to the cloud Vibe registry
(see `packs/vibe-skills/docs/local-and-cloud.md`).
There is no build or lint at the repo level; each pack may carry its own validation under
`packs/<name>/scripts/` (the root `scripts/validate.sh` dispatcher runs all of them).
Tests + validation run in CI on every PR (`.github/workflows/test.yml`).

## Layout

```
install.sh                      # installer ORCHESTRATOR (mode detection, pack picker, dispatch)
packs/
  README.md                     # the pack contract (pack.conf metadata keys, pack-owned install.sh)
  opencode/
    pack.conf                   # pack metadata sourced by install.sh + the pack's install.sh
    install.sh                  # pack-owned installer (payload dirs, hooks, cleanup)
    agents/  commands/  plugins/  agent-scripts/  skills/  snippets/   # payload (installed into
                                  #   the config dir root; snippets/ is ship-only; plugins/
                                  #   skipped by --no-plugin)
    scripts/                    # repo-only dev tooling (validate.sh, validate-driver-viz.sh,
                                #   driver-viz-render-test/, screenshot-driver-viz.py) — NOT shipped
    docs/  README.md  AGENTS.md # repo-only docs — NOT shipped
  vibe-acp/  vibe-skills/       # same contract: pack.conf + install.sh + payload dirs (+ repo-only scripts/ docs/)
scripts/
  install-lib.sh                # shared install mechanics, sourced by every packs/<name>/install.sh
  validate.sh                   # repo-wide dispatcher: installer syntax, pack contract, smoke installs,
                                #   the opencode pack's agent-scripts tests, every packs/*/scripts/validate*.sh
.github/workflows/
  test.yml                      # PR/push validation
  release.yml                   # manual release pipeline (see Releases)
```

## Install / verify

- `./install.sh` is dual-mode and auto-detects: inside this checkout (`.git/` + `packs/`
  next to the script) it installs by **copying from source** — nothing is built. Run
  standalone (e.g. `curl …/install.sh | sh`, where `$0` is not a file) it downloads the
  latest GitHub release payload and installs from that. Flags: `--source` / `--release`
  force a mode, `--dest DIR` overrides the target of a single pack (each pack otherwise
  uses its `PACK_DEFAULT_DEST`), `--no-plugin` skips every pack's `plugins/` payload dir,
  `--list` prints the packs. With no pack argument the installer asks interactively on a
  TTY (reads `/dev/tty`, so it works with `curl | sh`) and accepts multiple selections;
  without a TTY it installs the default pack (`opencode` when present). OpenCode reloads
  config automatically, no restart. **Re-run `./install.sh` after every edit here.**
- **Prerequisite check:** per pack, `PACK_PREREQS` tools must execute (the opencode pack
  requires `python3` and `git` — the shipped `packs/opencode/agent-scripts/` need both); the
  installer hard-fails with a clear message before touching any config dir. Optional
  tools (a forge CLI `gh`/`glab`/`forgejo-cli`, `shellcheck`) only produce a warning.
- **Release assets convention:** each GitHub release carries `agent-packs.tar.gz` +
  `agent-packs.tar.gz.sha256` (one top-level `agent-packs/` dir with `packs/`
  `install.sh scripts/install-lib.sh LICENSE`; the installer fetches them
  unauthenticated from `releases/latest/download/` — the repo is public), plus a
  **legacy alias**
  `opencode-agents.tar.gz` (old flat layout) + `SHA256SUMS` listing only that legacy
  asset, so pre-rename installers still served from the old raw URL keep working.
  **Releases are cut by the Release workflow (see Releases below), which builds and
  uploads these assets** — don't hand-upload them.
- The release workflow strips repo-only files from the payload: `packs/*/scripts/`,
  `packs/*/docs/`, pack-level `README.md`/`AGENTS.md`, `test/` dirs under `packs/*/plugins/`,
  plus any `node_modules/`, `.agent/` and `__pycache__/` anywhere. The installer additionally
  strips `.agent/`/`__pycache__/` from everything it copies and never lists them in the
  manifest.
- Each pack install writes `<PACK_META_PREFIX>.version` + `<PACK_META_PREFIX>.manifest`
  into the pack's config dir; the manifest drives stale-file cleanup on reinstall
  (files listed there under the pack's managed dirs that no longer exist upstream are
  removed). The opencode pack also cleans up the legacy pre-rename
  `opencode-agents.manifest` / `opencode-agents.version` once.
- Installs are **copy-based on purpose** (`cp -RL`): do NOT symlink pack payload dirs into
  a config dir — OpenCode's discovery skips symlinked agent files (e.g. the
  `packs/opencode/agents/driver/plan-thorough.md` symlink placeholder won't register).
- Sanity check after changes: `sh scripts/validate.sh` must pass, and a throwaway
  `XDG_CONFIG_HOME=$(mktemp -d) ./install.sh --source opencode` must produce a config dir
  with `agents/`, `commands/`, `plugins/`, `agent-scripts/`, and
  `skills/driver-conventions/`.

## Releases

- Cut a release with the manual **Release** workflow (`.github/workflows/release.yml`,
  "Run workflow" button on `main`). Optional `version` input (`vX.Y.Z` or `X.Y.Z`; must be
  new and greater than the latest tag); empty = auto patch-bump of the latest `v*` tag.
- The workflow: runs `./scripts/validate.sh` → tags + pushes `main` → builds
  `agent-packs.tar.gz` + `SHA256SUMS` → creates the GitHub release with an auto changelog
  → self-tests (download, checksum, payload hygiene, diff vs checkout,
  `install.sh --release` into a temp dir, `--list`, legacy-manifest cleanup).
- Run `./scripts/validate.sh` locally before pushing release-relevant changes.
- The workflow operates on remote `main` — commit + push first, or the release ships
  stale content.
- **Repo rename:** the repo was renamed `opencode-agents` → `agent-packs`; GitHub
  redirects git/raw/release URLs of the old name, so old `curl …/opencode-agents/…`
  one-liners keep working.

## Contracts — one source of truth

All driver file formats (`.plan/<slug>/state.json`, `manifest.json`, commit messages,
slug/branch/worktree policy) are defined in `packs/opencode/skills/driver-conventions/SKILL.md`
with JSON schemas in `packs/opencode/skills/driver-conventions/references/`. The opencode
pack ships that directory as payload, installed at `<config>/skills/driver-conventions/`.
**If you change a format, update the schemas too**, and keep the pack READMEs in sync.

## Extension points

- **New pack**: `mkdir packs/<name>/` + `pack.conf` (metadata only — contract in
  `packs/README.md`) + `packs/<name>/install.sh` (the pack-owned installer: payload dirs
  via `PACK_PAYLOAD_DIRS`, `pack_extra_checks()`/`pack_next_steps()` hooks, update cleanup;
  copy an existing pack's as the template — it sources `scripts/install-lib.sh` via
  `AGENT_PACKS_ROOT`/`AGENT_PACKS_INSTALL_LIB`), payload dirs, optional
  `packs/<name>/scripts/validate*.sh` (picked up by the root dispatcher automatically).
  Packs are self-contained — payload lives under `packs/<name>/` (there is no `shared/`
  dir). Nothing else to wire: `--list`, the picker, the release payload and validation
  all discover packs from `packs/*/pack.conf`.
- **New phase** (opencode pack): add `packs/opencode/agents/driver/<phase>.md`,
  `packs/opencode/commands/phases/<phase>.md`, and a row in the phase registry in
  `packs/opencode/agents/driver.md` (section 6) — plus the mirrored row in
  `packs/opencode/plugins/driver-viz/lib/phases.ts` (`validate-driver-viz.sh` fails otherwise).
- **New variant of a phase**: row in the VARIANTS table in `agents/driver.md`; replace the
  `plan-thorough.md` symlink with a real agent file (same output contract) when needed.
- **New `/driver` flag**: parse it in section 1 of `agents/driver.md`, store in `state.params`.
- **New agent-script**: add it under `packs/opencode/agent-scripts/` with unit tests in
  `packs/opencode/agent-scripts/tests/` (wired into `run-tests.sh`), and mirror it in
  `packs/opencode/install.sh` (`PACK_PAYLOAD_DIRS` already covers the install side), the
  opencode pack validator (asset list + syntax/tests section),
  `.github/workflows/release.yml` (self-test diff of `packs/opencode/agent-scripts`),
  plus the pack README/AGENTS.md and an invocation/exit-code entry in
  `packs/opencode/skills/driver-conventions/SKILL.md` §8.

## Gotchas (hard-earned — do not rediscover)

- Slug regex is `^[A-Z][A-Z0-9]*-[0-9]+$`; validate before ANY path use; quote everything.
- Never interpolate untrusted text (issue titles, specs, `$ARGUMENTS`) into shell commands
  or into `!` blocks of command templates — `!` blocks run outside the permission flow.
  `commands/driver.md`'s `!` blocks are static on purpose.
- Agent permissions are scoped to `driver` / `driver/*` only; `git push` is denied
  everywhere EXCEPT `driver/pr` (the PR phase owns pushing). Only `driver/implement`
  commits. Subagent nesting depth is 1 by default → the driver owns all loops/fan-out;
  phases must not spawn subagents and must be spawned in the foreground (`question` tool
  needs an interactive client — headless `opencode run` is NOT supported by the driver).
- Shell is permissive by default in all driver agents (`shell *: allow`, no prompts).
  Safety comes from the `deny` rules (push outside `driver/pr`, subagent spawning, edit
  scopes, Linear writes) plus agent discipline — still never interpolate untrusted text
  into shell commands.
- Phase agents deliberately set no `model:` — they inherit the session's model (user picks
  via `/models`).
- `.plan/` is scratch and gitignored in target repos — the driver writes nothing else into them.
- Don't re-implement routine, scriptable logic inside agent prompts (inline shell/python
  in `packs/opencode/agents/*.md`). If a phase needs mechanical, repeated work — git/forge
  probing, JSON merges of `state.json`, looping over files, parsing command output — put it
  in a shipped, unit-tested `packs/opencode/agent-scripts/` script and call that from the
  prompt instead. Precedent: `detect-forge.sh` + `driver-state.py` (G-20 / PR #1); the
  mechanism and the mandate live in `packs/opencode/skills/driver-conventions/SKILL.md` §8.
  Inline logic in a prompt is only for one-off, phase-specific steps.
- The installer prompt must read from `/dev/tty` (with `curl | sh`, stdin is the script).
