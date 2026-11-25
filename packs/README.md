# Packs

This repo (`agent-packs`) is a collection of **packs** — one per agent harness. Each pack
under `packs/<name>/` is self-contained and installs into that harness's config directory.

```
packs/
  <name>/
    pack.conf       # REQUIRED — pack METADATA, sourced by the root install.sh + the pack's install.sh
    install.sh      # REQUIRED — the pack-owned installer (payload dirs, hooks, cleanup)
    <payload dirs>  # whatever the harness discovers at its config root (PACK_PAYLOAD_DIRS in install.sh)
    snippets/…      # optional extras — in the tarball, not installed (anything not in PACK_PAYLOAD_DIRS)
    scripts/        # repo-only dev/validation tooling + release.sh — STRIPPED from the release payload
    docs/           # repo-only docs — STRIPPED from the release payload
    README.md, AGENTS.md  # repo-only docs — STRIPPED from the release payload
```

Packs are self-contained: all shipped code lives under `packs/<name>/` (there is no
top-level `shared/` dir).

## The pack contract

**`pack.conf`** — metadata only, a POSIX-sh-sourceable file with these keys:

| Key | Required | Meaning |
|---|---|---|
| `PACK_NAME` | yes | must equal the directory name |
| `PACK_DESCRIPTION` | yes | one-liner shown by `--list` and the interactive picker |
| `PACK_DEFAULT_DEST` | yes | default install target (e.g. `${XDG_CONFIG_HOME:-$HOME/.config}/opencode`) |
| `PACK_META_PREFIX` | yes | installer writes `<prefix>.version` + `<prefix>.manifest` into the dest |
| `PACK_PREREQS` | no | space-separated tools that must execute (`tool --version`); hard-fail before anything is installed |
| `PACK_LEGACY_MANIFEST` | no | old manifest filename in the dest — its stale files are cleaned once, then it is removed |
| `PACK_LEGACY_CLEANUP` | no | extra legacy files in the dest removed after install |

**`packs/<name>/install.sh`** — the pack-owned installer. It owns the payload dirs
(`PACK_PAYLOAD_DIRS="…"` — space-separated dirs copied from `packs/<name>/` to the dest
root; the dir named `plugins` is skipped by `--no-plugin`), the hooks, and the update
cleanup. Invoked by the root `install.sh` with `AGENT_PACKS_ROOT=<payload root>` as:

```sh
sh packs/<name>/install.sh check                                  # prereqs + payload dirs + warnings
sh packs/<name>/install.sh install <dest> <version> [--no-plugin] # the actual install
```

It sources the shared mechanics from
`${AGENT_PACKS_INSTALL_LIB:-$AGENT_PACKS_ROOT/scripts/install-lib.sh}` and the metadata
from its own `pack.conf`. Optional hooks it defines:

- `pack_extra_checks()` — print warnings (never fail), e.g. optional CLIs; run by `check`
- `pack_next_steps()` — print next-step hints after a successful install

## Installer behavior

- Root `install.sh` is a pure orchestrator: mode detection (`--source`/`--release`), pack
  discovery (from `packs/*/pack.conf` in source mode, from the release `manifest.json` in
  release mode), the pack picker, and dispatch to each pack's own `install.sh` (the
  vendored copy inside the pack tarball in release mode). It ends with a per-pack
  OK/FAILED summary (name, resolved version, dest) and exits non-zero if any pack failed.
- CLI: `install.sh [PACK[@VERSION] ...] [--source|--release] [--dest DIR] [--no-plugin]
  [--plain] [--list]`. PACK args never prompt. No args + TTY → ANSI checkbox TUI over
  `/dev/tty` (arrows navigate, space toggles, left/right cycles the pack's version across
  the release manifest history, enter confirms, q aborts); `--plain` forces the numbered
  multi-select prompt. No TTY + no args → exit 2 with a clear message (no silent default).
  `--list` prints the packs with their versions. `--dest DIR` requires a single pack.
- Installs are **copy-based** (`cp -RL`) — never symlink payload dirs into a config dir.
- `.agent/` and `__pycache__/` are stripped from everything installed and never listed in
  the manifest.
- The manifest drives stale-file cleanup on reinstall: files listed in a previous
  `<prefix>.manifest` (under the pack's managed dirs) that no longer exist upstream are
  removed.

## Release payload

Each GitHub release (tag `vX.Y.Z`, cut automatically on pushes to `main` that touch
`packs/**`, `install.sh`, `scripts/**` or `.github/workflows/**`; docs-only diffs release
nothing) carries:

- `manifest.json` — schema (assembled by `scripts/assemble-manifest.py`):

  ```json
  {
    "schema": 1,
    "release": "vX.Y.Z",
    "packs": {
      "<name>": {
        "asset": "<name>.tar.gz",
        "description": "<PACK_DESCRIPTION from pack.conf>",
        "sha256": "<sha256 of the tarball>",
        "version": "<per-pack version, e.g. v2.3.0>"
      }
    }
  }
  ```

  Per-pack versions are computed from conventional commits since the last release tag
  (`feat`→minor, `fix`→patch, `!`/`BREAKING CHANGE:`→major, highest wins;
  path-changed without prefix → patch), seeded from the latest `v*` tag. The repo tag
  `vX.Y.Z` is only a release cursor. The installer parses this fixed layout with awk
  (indent=2, sorted keys, `ensure_ascii=False`) — keep `assemble-manifest.py` output in
  exactly this shape.
- `<name>.tar.gz` per pack — top-level `<name>/` with the payload + `pack.conf` +
  `install.sh` + a vendored `install-lib.sh` (repo-only `scripts/`, `docs/`, pack-level
  `README.md`/`AGENTS.md`, plugin `test/` dirs, plus any `node_modules/`, `.agent/`,
  `__pycache__/` stripped). Unchanged packs are carried over from the previous release,
  so every release is self-contained.

The release pipeline (`.github/workflows/release.yml`) detects changed packs
(`scripts/release-detect.sh`), runs each changed pack's own `packs/<name>/scripts/release.sh`
to compute its version and build its tarball, assembles `manifest.json`
(`scripts/assemble-manifest.py`), then tags and publishes. The installer's release mode
fetches `releases/latest/download/manifest.json` (0 API calls), downloads the selected
packs' tarballs, verifies each sha256 against the manifest entry, extracts, and dispatches
to the vendored `install.sh`. `PACK@<version>` pins an older release tag (1 paginated
releases-API call + direct manifest downloads).

## Adding a pack

1. `mkdir packs/<name>/` and write `pack.conf` (metadata only, per the contract above).
2. Write `packs/<name>/install.sh` (payload dirs + hooks — copy an existing pack's as
   the template) and add the payload dirs — keep the pack self-contained (code lives
   under `packs/<name>/`).
3. Write `packs/<name>/scripts/release.sh` — a thin wrapper calling
   `ap_release_pack` from `scripts/release-lib.sh` (add pack-specific release steps,
   e.g. vibe-skills' cloud publish, after the call).
4. Add `packs/<name>/scripts/validate.sh` if the pack needs its own validation — the root
   `scripts/validate.sh` dispatcher runs every pack's validator automatically.
5. `scripts/validate.sh` (root) checks every `pack.conf` for the required metadata keys
   (and rejects removed keys), `sh -n` + shellcheck on every installer/release script,
   smoke-installs every pack into a `mktemp` dest, unit-tests the release classification,
   and runs an offline release-mode installer E2E against a `file://` fake release —
   run it locally and in CI before pushing.
