# Contributing

Thanks for contributing to **agent-packs**! The repo is a collection of self-contained
**packs** — one per agent harness — installed by the root [`install.sh`](install.sh)
orchestrator. Repo structure, contracts, and agent-facing guidance live in
[`AGENTS.md`](AGENTS.md); the pack contract (what every pack must contain) is
[`packs/README.md`](packs/README.md).

## Workflow

- Work on a feature branch and open a PR against `main`.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix(scope):`, `docs:`, `refactor:`, …) — they drive the automatic per-pack
  SemVer bumps when a release is cut (see Releases below).
- Run `./scripts/validate.sh` locally before pushing; CI (`.github/workflows/test.yml`)
  runs the same validation on every PR and push to `main`.

## Local development

- In a checkout of this repo, `./install.sh` auto-detects **source mode** (`.git/` +
  `packs/` next to the script) and installs by copying from the checkout — nothing is
  built or compiled. **Re-run `./install.sh` after every edit here.**
- Throwaway smoke test into a temp config dir:
  `XDG_CONFIG_HOME=$(mktemp -d) ./install.sh --source open-driver` must produce a config
  dir with `agents/`, `commands/`, `plugins/`, `agent-scripts/`, and
  `skills/driver-conventions/`.
- There is no repo-level build or lint; each pack may carry its own validation under
  `packs/<name>/scripts/validate*.sh`, which the root `scripts/validate.sh` dispatcher
  runs automatically (plus an optional shellcheck pass when installed).

## Installer modes and the pack picker

- `install.sh` is dual-mode: **source** inside a checkout, **release** when run standalone
  (e.g. `curl ... | sh`) — latest GitHub release, manifest-driven, sha256-verified.
  `--source` / `--release` force a mode.
- Packs are selected as `PACK[@VERSION] ...` or `all`; given on the command line, the
  installer never prompts. With a TTY and no pack args, an interactive picker TUI opens
  over `/dev/tty` (modern terminal: UTF-8 glyphs, 256 colors, alternate screen; arrows
  move, space toggles, left/right cycles the highlighted pack's version, enter confirms,
  q quits); `--plain` forces the numbered prompt. No TTY + no
  pack args → exit 2 (never picks a default silently). `--list` prints the packs with
  versions, `--dest DIR` targets a single pack, `--no-plugin` skips every pack's
  `plugins/` payload.
- The TUI/prompt must read from `/dev/tty` — with `curl | sh`, stdin is the script.

## Releases

- Every push to `main` that touches `packs/**`, `install.sh`, `scripts/**` or
  `.github/workflows/**` cuts one release automatically (`.github/workflows/release.yml`);
  docs-only diffs (README / CONTRIBUTING / AGENTS / UNLICENSE changes) release nothing.
  Don't hand-upload release assets.
- Pipeline: `./scripts/validate.sh` → `scripts/release-detect.sh` classifies the diff
  (baseline = previous `main` SHA, fallback latest `v*` tag) → per changed pack,
  `packs/<name>/scripts/release.sh` computes the pack version from conventional commits
  since the last tag (`feat`→minor, `fix`→patch, `!`/`BREAKING CHANGE:`→major, highest
  wins) and builds `<name>.tar.gz` + a meta fragment → `scripts/assemble-manifest.py`
  merges them with carried-over unchanged packs (every release is self-contained) → tag +
  push → `gh release create` → self-test (checksums vs manifest, payload hygiene,
  non-interactive installs of the changed packs, `--list`).
- Each release carries `manifest.json`
  (`{schema, release, packs: {<name>: {version, description, asset, sha256}}}`) plus one
  `<name>.tar.gz` per pack (top-level `<name>/` with payload + `pack.conf` + `install.sh`
  + a vendored `install-lib.sh`; repo-only `scripts/`, `docs/`, pack-level
  `README.md`/`AGENTS.md`, plugin `test/` dirs, `node_modules/` stripped). The installer
  fetches the manifest unauthenticated from `releases/latest/download/` (0 API calls) and
  `releases/download/<tag>/` for `PACK@<version>` — the repo is public, no token needed.
- The repo tag `vX.Y.Z` is only a **release cursor** — per-pack versions live in the
  release's `manifest.json`.

## Adding or extending a pack

See [`AGENTS.md`](AGENTS.md) → "Extension points": a new pack is `packs/<name>/` with
`pack.conf` + a pack-owned `install.sh` + `packs/<name>/scripts/release.sh` + payload
dirs — discovered automatically by `--list`, the TUI picker, validation, and the release
pipeline, so nothing else needs wiring. The same section has checklists for new driver
phases, phase variants, `/driver` flags, and agent-scripts.

## Repo layout

```
install.sh            # installer orchestrator: mode detection, pack picker (TUI/--plain), per-pack dispatch
packs/<name>/         # one self-contained pack per harness (pack.conf + install.sh + payload; scripts/ + docs/ are repo-only)
scripts/              # install-lib.sh (shared install mechanics) + release pipeline + validate.sh dispatcher
.github/workflows/    # test.yml (PR/push validation), release.yml (cuts a manifest release on pushes to main)
```

See [`AGENTS.md`](AGENTS.md) for the full layout, contracts, and gotchas.
