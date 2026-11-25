# agent-packs

[![test](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/test.yml/badge.svg)](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/test.yml)
[![build](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/release.yml/badge.svg)](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/release.yml)
[![release](https://img.shields.io/github/release/GoncaloJoaoCorreia/agent-packs?display_name=tag)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest)
[![license](https://img.shields.io/badge/license-Unlicense-blue)](LICENSE)

A personal library of agent-harness extensions — **packs**. Each pack under
[`packs/`](packs/) is self-contained and installs into one harness's config directory
(see [`packs/README.md`](packs/README.md) for the pack contract).

## Packs

| Latest | Harness | What you get | Docs |
|---|---|---|---|
| [![open-driver](https://img.shields.io/badge/dynamic/json?url=https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest/download/manifest.json&query=%24%5B%27packs%27%5D%5B%27open-driver%27%5D%5B%27version%27%5D&label=open-driver)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest) | [<img src="https://cdn.simpleicons.org/opencode/black/white" width="18" height="18" alt="OpenCode v2">](https://opencode.ai/v2/docs/) | `/driver` feature-cycle orchestrator | [packs/open-driver/README.md](packs/open-driver/README.md) |
| [![vibe-bridge](https://img.shields.io/badge/dynamic/json?url=https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest/download/manifest.json&query=%24%5B%27packs%27%5D%5B%27vibe-bridge%27%5D%5B%27version%27%5D&label=vibe-bridge)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest) | [<img src="https://cdn.simpleicons.org/opencode/black/white" width="18" height="18" alt="OpenCode v2">](https://opencode.ai/v2/docs/) | Mistral OpenCode provider over ACP | [packs/vibe-bridge/README.md](packs/vibe-bridge/README.md) |
| [![vibe-skills](https://img.shields.io/badge/dynamic/json?url=https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest/download/manifest.json&query=%24%5B%27packs%27%5D%5B%27vibe-skills%27%5D%5B%27version%27%5D&label=vibe-skills)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest) | [<img src="https://cdn.simpleicons.org/mistralai" width="18" height="18" alt="Mistral Vibe CLI">](https://github.com/mistralai/mistral-vibe) | Collection of agent skills for Mistral Vibe | [packs/vibe-skills/README.md](packs/vibe-skills/README.md) |

More harnesses can be added as new packs — see
[AGENTS.md](AGENTS.md) → "Adding a pack".

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/GoncaloJoaoCorreia/agent-packs/main/install.sh | sh
```

The installer opens a checkbox TUI listing the available packs and their versions (pick
several; left/right cycles the highlighted pack's version). To skip the prompt:

```sh
sh -s -- open-driver          # one pack, latest release, non-interactive
sh -s -- open-driver@v2.2.0   # one pack pinned to a release tag
sh -s -- all               # every pack
install.sh --list          # just list the packs + versions
install.sh --plain         # numbered prompt instead of the TUI
```

Without a TTY and without pack arguments the installer exits with an error (it never picks
a default silently); with pack arguments it is fully non-interactive (the CI path).

In a local checkout of this repo, run `./install.sh` instead — it installs straight from
source (same copy-based install; nothing is built). Re-run it after pulling changes.

Each GitHub release carries a `manifest.json` (per-pack `version`, `description`, `asset`,
`sha256`) plus one `packs/<name>.tar.gz` per pack; the installer fetches the manifest from
`releases/latest/download/`, downloads the selected packs' tarballs, verifies each sha256
against the manifest, and installs only the packs you selected. Installs are copy-based and
write a per-pack `<prefix>.version` + `<prefix>.manifest` into the config dir, which drives
stale-file cleanup on reinstall. The installer requires `python3` and `git` for the
open-driver pack (hard prerequisite — it fails with a clear message otherwise).

## Repo layout

```
install.sh            # installer: TUI/--plain pack picker + per-pack dispatch (source or release mode)
packs/<name>/         # one self-contained pack per harness (pack.conf + install.sh + payload; scripts/ + docs/ are repo-only)
scripts/              # install-lib.sh (shared install mechanics) + release pipeline (release-lib.sh, release-detect.sh,
                      #   assemble-manifest.py) + validate.sh (repo-wide validation dispatcher, CI + local)
.github/workflows/    # test.yml (PR/push validation), release.yml (cuts a manifest release on pushes to main)
```

See [AGENTS.md](AGENTS.md) for the full layout, contracts, and extension points.
