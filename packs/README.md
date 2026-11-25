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
    scripts/        # repo-only dev/validation tooling — STRIPPED from the release payload
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

- Root `install.sh` is a pure orchestrator: mode detection (`--source`/`--release`),
  pack discovery from `packs/*/pack.conf`, the pack picker, and dispatch to each
  `packs/<name>/install.sh`. It ends with a per-pack OK/FAILED summary and exits non-zero
  if any pack failed.
- `install.sh` (no args, on a TTY) lists the packs and asks which to install — multiple
  selectable. No TTY (CI, `curl | sh` piped): installs the default pack (`opencode` when
  present). `install.sh opencode vibe-skills ...` / `install.sh all` never prompt; `--list` just
  prints the packs. `--dest DIR` requires a single pack.
- Installs are **copy-based** (`cp -RL`) — never symlink payload dirs into a config dir.
- `.agent/` and `__pycache__/` are stripped from everything installed and never listed in
  the manifest.
- The manifest drives stale-file cleanup on reinstall: files listed in a previous
  `<prefix>.manifest` (under the pack's managed dirs) that no longer exist upstream are
  removed.

## Release payload

Each GitHub release carries `agent-packs.tar.gz` (top-level `agent-packs/` dir with
`packs/ install.sh scripts/install-lib.sh LICENSE`) plus `agent-packs.tar.gz.sha256`. The
release workflow strips `packs/*/scripts/`, `packs/*/docs/`, pack-level
`README.md`/`AGENTS.md`, `test/` dirs under `plugins/`, plus any `node_modules/`,
`.agent/` and `__pycache__/` from the payload (`packs/README.md`, the pack contract,
ships on purpose). The installer downloads the tarball, verifies the checksum, and
installs only the selected packs. The release also carries a legacy
`opencode-agents.tar.gz` (old flat layout) + `SHA256SUMS` for pre-rename installers.

## Adding a pack

1. `mkdir packs/<name>/` and write `pack.conf` (metadata only, per the contract above).
2. Write `packs/<name>/install.sh` (payload dirs + hooks — copy an existing pack's as
   the template) and add the payload dirs — keep the pack self-contained (code lives
   under `packs/<name>/`).
3. Add `packs/<name>/scripts/validate.sh` if the pack needs its own validation — the root
   `scripts/validate.sh` dispatcher runs every pack's validator automatically.
4. `scripts/validate.sh` (root) checks every `pack.conf` for the required metadata keys
   (and rejects removed keys), `sh -n` + shellcheck on every `packs/*/install.sh`, and
   smoke-installs every pack into a `mktemp` dest — run it locally and in CI before
   pushing.
