# Packs

This repo (`agent-packs`) is a collection of **packs** — one per agent harness. Each pack
under `packs/<name>/` is self-contained and installs into that harness's config directory.

```
packs/
  <name>/
    pack.conf       # REQUIRED — the pack manifest, sourced by the root install.sh
    <payload dirs>  # whatever the harness discovers at its config root (PACK_PAYLOAD)
    snippets/…      # optional ship-only extras (PACK_SHIP_ONLY) — in the tarball, not installed
    scripts/        # repo-only dev/validation tooling — STRIPPED from the release payload
    docs/           # repo-only docs — STRIPPED from the release payload
    README.md, AGENTS.md  # repo-only docs — STRIPPED from the release payload
```

Packs are self-contained: all shipped code lives under `packs/<name>/` (there is no
top-level `shared/` dir). `PACK_COMPOSE` remains available if a future pack ever needs to
compose code from elsewhere in the payload root.

## The pack contract (`pack.conf`)

A POSIX-sh-sourceable file with these keys:

| Key | Required | Meaning |
|---|---|---|
| `PACK_NAME` | yes | must equal the directory name |
| `PACK_DESCRIPTION` | yes | one-liner shown by `--list` and the interactive picker |
| `PACK_DEFAULT_DEST` | yes | default install target (e.g. `${XDG_CONFIG_HOME:-$HOME/.config}/opencode`) |
| `PACK_META_PREFIX` | yes | installer writes `<prefix>.version` + `<prefix>.manifest` into the dest |
| `PACK_PAYLOAD` | yes | space-separated dirs copied from `packs/<name>/` to the dest root. The dir named `plugins` is skipped by `--no-plugin` |
| `PACK_SHIP_ONLY` | no | dirs shipped in the release tarball but never installed |
| `PACK_COMPOSE` | no | space-separated `src:dst` entries — `src` relative to the payload root (e.g. `packs/<other-pack>/lib`), `dst` relative to the dest root; copied in at install time. Currently unused: packs keep their code in their own payload dirs |
| `PACK_PREREQS` | no | space-separated tools that must execute (`tool --version`); hard-fail before anything is installed |
| `PACK_LEGACY_MANIFEST` | no | old manifest filename in the dest — its stale files are cleaned once, then it is removed |
| `PACK_LEGACY_CLEANUP` | no | extra legacy files in the dest removed after install |

Optional hooks (functions defined in `pack.conf`, called by the installer):

- `pack_extra_checks()` — print warnings (never fail), e.g. optional CLIs
- `pack_next_steps()` — print next-step hints after a successful install

## Installer behavior

- `install.sh` (no args, on a TTY) lists the packs and asks which to install — multiple
  selectable. No TTY (CI, `curl | sh` piped): installs the default pack (`opencode` when
  present). `install.sh opencode vibe ...` / `install.sh all` never prompt; `--list` just
  prints the packs. `--dest DIR` requires a single pack.
- Installs are **copy-based** (`cp -RL`) — never symlink payload dirs into a config dir.
- `.agent/` and `__pycache__/` are stripped from everything installed and never listed in
  the manifest.
- The manifest drives stale-file cleanup on reinstall: files listed in a previous
  `<prefix>.manifest` (under the pack's managed dirs) that no longer exist upstream are
  removed.

## Release payload

Each GitHub release carries `agent-packs.tar.gz` (top-level `agent-packs/` dir with
`packs/ install.sh LICENSE`) plus `agent-packs.tar.gz.sha256`. The release workflow
strips `packs/*/scripts/`, `packs/*/docs/`, pack-level `README.md`/`AGENTS.md`, `test/` dirs
under `plugins/`, plus any `node_modules/`, `.agent/` and `__pycache__/` from the payload
(`packs/README.md`, the pack contract, ships on purpose). The installer downloads the
tarball, verifies the checksum, and installs only the selected packs. The release also
carries a legacy
`opencode-agents.tar.gz` (old flat layout) + `SHA256SUMS` for pre-rename installers.

## Adding a pack

1. `mkdir packs/<name>/` and write `pack.conf` per the contract above.
2. Add the payload dirs — keep the pack self-contained (code lives under `packs/<name>/`);
   use `PACK_COMPOSE` only if you must compose code from elsewhere in the payload root.
3. Add `packs/<name>/scripts/validate.sh` if the pack needs its own validation — the root
   `scripts/validate.sh` dispatcher runs every pack's validator automatically.
4. `scripts/validate.sh` (root) checks every `pack.conf` for required keys and existing
   payload/compose paths — run it locally and in CI before pushing.
