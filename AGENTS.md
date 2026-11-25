# AGENTS.md — agent-packs

Personal library of agent-harness extensions (**packs**): one self-contained pack per
harness under `packs/<name>/`.
Currently ships three packs: **open-driver** (`packs/open-driver/`) — the **driver**
(`/driver`, a multi-phase feature-cycle orchestrator) and the **driver-viz** TUI plugin —
**vibe-bridge** (`packs/vibe-bridge/`) — Mistral Vibe (`vibe-acp` over ACP) as an OpenCode
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
  open-driver/
    pack.conf                   # pack metadata sourced by install.sh + the pack's install.sh
    install.sh                  # pack-owned installer (payload dirs, hooks, cleanup)
    agents/  commands/  plugins/  agent-scripts/  skills/  snippets/   # payload (installed into
                                  #   the config dir root; snippets/ is ship-only; plugins/
                                  #   skipped by --no-plugin)
    scripts/                    # repo-only dev tooling (validate.sh, validate-driver-viz.sh,
                                #   driver-viz-render-test/, screenshot-driver-viz.py) — NOT shipped
    docs/  README.md  AGENTS.md # repo-only docs — NOT shipped
  vibe-bridge/  vibe-skills/       # same contract: pack.conf + install.sh + payload dirs (+ repo-only scripts/ docs/)
scripts/
  install-lib.sh                # shared install mechanics, sourced by every packs/<name>/install.sh
                                #   (vendored into each pack tarball at release time)
  release-lib.sh                # shared release mechanics (path classification, conventional-commit
                                #   version bumps, pack tarball builder ap_release_pack)
  release-detect.sh             # diff classifier: changed packs / infra / docs-only for a release
  assemble-manifest.py          # assembles a release's manifest.json
  validate.sh                   # repo-wide dispatcher: installer + release script syntax, pack contract,
                                #   smoke installs, release-lib unit tests, offline release-mode E2E,
                                #   the open-driver pack's agent-scripts tests, every packs/*/scripts/validate*.sh
.github/workflows/
  test.yml                      # PR/push validation
  release.yml                   # manifest release pipeline — runs on pushes to main (see Releases)
```

## Install / verify

- `./install.sh` is dual-mode and auto-detects: inside this checkout (`.git/` + `packs/`
  next to the script) it installs by **copying from source** — nothing is built. Run
  standalone (e.g. `curl …/install.sh | sh`, where `$0` is not a file) it installs from
  the latest GitHub release (manifest-driven). Packs are selected as `PACK[@VERSION] ...`
  or `all`. Flags: `--source` / `--release` force a mode, `--dest DIR` overrides the
  target of a single pack (each pack otherwise uses its `PACK_DEFAULT_DEST`),
  `--no-plugin` skips every pack's `plugins/` payload dir, `--list` prints the packs with
  versions, `--plain` forces the numbered prompt. With no pack argument on a TTY the
  installer opens an ANSI checkbox TUI (reads `/dev/tty`, so it works with `curl | sh`;
  arrows navigate, space toggles, left/right cycles the pack's version, enter confirms);
  without a TTY and without pack args it **exits 2** (never picks a default silently).
  OpenCode reloads config automatically, no restart. **Re-run `./install.sh` after every
  edit here.**
- **Prerequisite check:** per pack, `PACK_PREREQS` tools must execute (the open-driver pack
  requires `python3` and `git` — the shipped `packs/open-driver/agent-scripts/` need both); the
  installer hard-fails with a clear message before touching any config dir. Optional
  tools (a forge CLI `gh`/`glab`/`forgejo-cli`, `shellcheck`) only produce a warning.
- **Release assets convention:** each GitHub release carries `manifest.json`
  (`{schema, release, packs: {<name>: {version, description, asset, sha256}}}`) plus one
  `<name>.tar.gz` per pack (top-level `<name>/` with payload + `pack.conf` +
  `install.sh` + a vendored `install-lib.sh`). The installer fetches the manifest
  unauthenticated from `releases/latest/download/` (0 API calls), and
  `releases/download/<tag>/` for `PACK@<version>` — the repo is public, no token needed.
  **Releases are cut automatically by the release workflow on pushes to `main` (see
  Releases below)** — don't hand-upload assets.
- Per-pack tarballs strip repo-only files: `scripts/`, `docs/`, pack-level
  `README.md`/`AGENTS.md`, `test/` dirs under `plugins/`, plus any `node_modules/`,
  `.agent/` and `__pycache__/` anywhere. The installer additionally strips
  `.agent/`/`__pycache__/` from everything it copies and never lists them in the manifest.
- Each pack install writes `<PACK_META_PREFIX>.version` + `<PACK_META_PREFIX>.manifest`
  into the pack's config dir; the manifest drives stale-file cleanup on reinstall
  (files listed there under the pack's managed dirs that no longer exist upstream are
  removed). The open-driver pack also cleans up legacy meta files once: the pre-rename
  repo's `opencode-agents.manifest` / `opencode-agents.version` and the old pack name's
  `agent-packs.opencode.manifest` / `agent-packs.opencode.version`.
- Installs are **copy-based on purpose** (`cp -RL`): do NOT symlink pack payload dirs into
  a config dir — OpenCode's discovery skips symlinked agent files (e.g. the
  `packs/open-driver/agents/driver/plan-thorough.md` symlink placeholder won't register).
- Sanity check after changes: `sh scripts/validate.sh` must pass, and a throwaway
  `XDG_CONFIG_HOME=$(mktemp -d) ./install.sh --source open-driver` must produce a config dir
  with `agents/`, `commands/`, `plugins/`, `agent-scripts/`, and
  `skills/driver-conventions/`.

## Releases

- Every push to `main` that touches `packs/**`, `install.sh`, `scripts/**` or
  `.github/workflows/**` cuts one release automatically (`.github/workflows/release.yml`;
  docs-only diffs release nothing). `workflow_dispatch` stays for manual re-runs with an
  optional `version` input (`vX.Y.Z`); empty = auto patch-bump of the latest `v*` tag.
  The repo tag `vX.Y.Z` is only a **release cursor** — per-pack versions live in the
  release's `manifest.json`.
- The pipeline: runs `./scripts/validate.sh` → `scripts/release-detect.sh` classifies the
  diff (baseline = previous `main` SHA, fallback latest `v*` tag; pack payload paths → that
  pack, infra paths → all packs) → per changed pack, `packs/<name>/scripts/release.sh`
  computes the pack version from conventional commits since the last tag (`feat`→minor,
  `fix`→patch, `!`/`BREAKING CHANGE:`→major, highest wins, no-prefix→patch, seeded from
  the latest `v*` tag) and builds `<name>.tar.gz` + a meta fragment →
  `scripts/assemble-manifest.py` merges them with carried-over unchanged packs (every
  release is self-contained) → tag + push → `gh release create` with `manifest.json` +
  all pack tarballs → self-test (checksums vs manifest, payload hygiene, non-interactive
  `install.sh --release` of each changed pack into a temp dir, `--list`).
- Run `./scripts/validate.sh` locally before pushing release-relevant changes.
- The workflow operates on remote `main` — commit + push first, or the release ships
  stale content.
- **Repo rename:** the repo was renamed `opencode-agents` → `agent-packs`; GitHub
  redirects git/raw URLs of the old name. Note: new releases no longer carry the legacy
  pre-rename tarball asset (G-113 decision — no backwards compat with pre-rename
  one-liners), so pre-rename installers only keep working against old releases; the
  open-driver pack's local legacy-manifest cleanup stays.

## Contracts — one source of truth

All driver file formats (`.plan/<slug>/state.json`, `manifest.json`, commit messages,
slug/branch/worktree policy) are defined in `packs/open-driver/skills/driver-conventions/SKILL.md`
with JSON schemas in `packs/open-driver/skills/driver-conventions/references/`. The open-driver
pack ships that directory as payload, installed at `<config>/skills/driver-conventions/`.
**If you change a format, update the schemas too**, and keep the pack READMEs in sync.

## Extension points

- **New pack**: `mkdir packs/<name>/` + `pack.conf` (metadata only — contract in
  `packs/README.md`) + `packs/<name>/install.sh` (the pack-owned installer: payload dirs
  via `PACK_PAYLOAD_DIRS`, `pack_extra_checks()`/`pack_next_steps()` hooks, update cleanup;
  copy an existing pack's as the template — it sources the vendored `install-lib.sh` next to
  it in release tarballs, or `scripts/install-lib.sh` via `AGENT_PACKS_ROOT` in a checkout)
  + `packs/<name>/scripts/release.sh` (pack-owned release builder — thin wrapper over
  `ap_release_pack` in `scripts/release-lib.sh`; add pack-specific steps like cloud
  publishing after the call), payload dirs, optional `packs/<name>/scripts/validate*.sh`
  (picked up by the root dispatcher automatically). Packs are self-contained — payload
  lives under `packs/<name>/` (there is no `shared/` dir). Nothing else to wire: `--list`,
  the TUI picker, the release pipeline and validation all discover packs from
  `packs/*/pack.conf`.
- **New phase** (open-driver pack): add `packs/open-driver/agents/driver/<phase>.md`,
  `packs/open-driver/commands/phases/<phase>.md`, and a row in the phase registry in
  `packs/open-driver/agents/driver.md` (section 6) — plus the mirrored row in
  `packs/open-driver/plugins/driver-viz/lib/phases.ts` (`validate-driver-viz.sh` fails otherwise).
- **New variant of a phase**: row in the VARIANTS table in `agents/driver.md`; replace the
  `plan-thorough.md` symlink with a real agent file (same output contract) when needed.
- **New `/driver` flag**: parse it in section 1 of `agents/driver.md`, store in `state.params`.
- **New agent-script**: add it under `packs/open-driver/agent-scripts/` with unit tests in
  `packs/open-driver/agent-scripts/tests/` (wired into `run-tests.sh`), and mirror it in
  `packs/open-driver/install.sh` (`PACK_PAYLOAD_DIRS` already covers the install side), the
  open-driver pack validator (asset list + syntax/tests section),
  `.github/workflows/release.yml` (self-test: the open-driver tarball ships `agent-scripts/`
  and the release-mode install asserts the script lands in the temp config),
  plus the pack README/AGENTS.md and an invocation/exit-code entry in
  `packs/open-driver/skills/driver-conventions/SKILL.md` §8.

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
  in `packs/open-driver/agents/*.md`). If a phase needs mechanical, repeated work — git/forge
  probing, JSON merges of `state.json`, looping over files, parsing command output — put it
  in a shipped, unit-tested `packs/open-driver/agent-scripts/` script and call that from the
  prompt instead. Precedent: `detect-forge.sh` + `driver-state.py` (G-20 / PR #1); the
  mechanism and the mandate live in `packs/open-driver/skills/driver-conventions/SKILL.md` §8.
  Inline logic in a prompt is only for one-off, phase-specific steps.
- The installer's TUI/prompt must read from `/dev/tty` (with `curl | sh`, stdin is the
  script); with no TTY and no pack args it exits 2 instead of guessing.
