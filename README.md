# agent-packs

[![test](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/test.yml/badge.svg)](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/test.yml)
[![build](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/release.yml/badge.svg)](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/release.yml)
[![release](https://img.shields.io/github/release/GoncaloJoaoCorreia/agent-packs?display_name=tag)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest)
[![license](https://img.shields.io/badge/license-Unlicense-blue)](UNLICENSE)

A personal library of agent-harness extensions — **packs**. Each pack under
[`packs/`](packs/) is self-contained and installs into one harness's config directory.

## Packs

| Latest | Harness | What you get | Docs |
|---|---|---|---|
| [![open-driver](https://img.shields.io/badge/dynamic/json?url=https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest/download/manifest.json&query=%24%5B%27packs%27%5D%5B%27open-driver%27%5D%5B%27version%27%5D&label=open-driver)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest) | [<img src="https://cdn.simpleicons.org/opencode/black/white" width="18" height="18" alt="OpenCode v2">](https://opencode.ai/v2/docs/) | `/driver` feature-cycle orchestrator | [packs/open-driver/README.md](packs/open-driver/README.md) |
| [![vibe-bridge](https://img.shields.io/badge/dynamic/json?url=https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest/download/manifest.json&query=%24%5B%27packs%27%5D%5B%27vibe-bridge%27%5D%5B%27version%27%5D&label=vibe-bridge)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest) | [<img src="https://cdn.simpleicons.org/opencode/black/white" width="18" height="18" alt="OpenCode v2">](https://opencode.ai/v2/docs/) | Mistral OpenCode provider over ACP | [packs/vibe-bridge/README.md](packs/vibe-bridge/README.md) |
| [![vibe-skills](https://img.shields.io/badge/dynamic/json?url=https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest/download/manifest.json&query=%24%5B%27packs%27%5D%5B%27vibe-skills%27%5D%5B%27version%27%5D&label=vibe-skills)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest) | [<img src="https://cdn.simpleicons.org/mistralai" width="18" height="18" alt="Mistral Vibe CLI">](https://github.com/mistralai/mistral-vibe) | Collection of agent skills for Mistral Vibe | [packs/vibe-skills/README.md](packs/vibe-skills/README.md) |

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/GoncaloJoaoCorreia/agent-packs/main/install.sh | sh
```

The installer opens an interactive pack picker (needs a modern terminal: UTF-8, 256
colors, alternate screen) listing the available packs and their versions — up/down moves,
space toggles, left/right cycles the highlighted pack's version (release mode only),
enter installs, q quits.
On a basic terminal use `--plain` for a numbered prompt. To skip the prompt entirely:

```sh
sh -s -- open-driver          # one pack, latest release, non-interactive
sh -s -- open-driver@v2.2.0   # one pack pinned to a release tag
sh -s -- all                  # every pack
install.sh --list             # just list the packs + versions
install.sh --plain            # numbered prompt instead of the TUI
```

Without a TTY and without pack arguments the installer exits with an error (it never picks
a default silently); with pack arguments it is fully non-interactive (the CI path).

Useful flags: `--dest DIR` installs a single pack into a different config dir,
`--no-plugin` skips a pack's `plugins/` payload, `--source` / `--release` force the install
mode.

## What the installer does

- **Release mode** (the default for `curl ... | sh`): fetches the latest release's
  `manifest.json` from `releases/latest/download/`, downloads each selected pack's
  `<name>.tar.gz`, verifies its sha256 against the manifest, and only then installs.
  `PACK@<version>` pins a specific release tag.
- Installs are **copy-based** into the harness's config dir and write a per-pack
  `<prefix>.version` + `<prefix>.manifest` there — re-running the installer after an update
  removes files that are no longer shipped.
- Release mode requires `curl` and `sha256sum` (or `shasum` on macOS). The **open-driver**
  pack additionally requires `python3` and `git` (a hard prerequisite — the installer fails
  with a clear message otherwise).

## License

Released into the public domain under the [Unlicense](UNLICENSE) — see
<https://unlicense.org>. No restrictions: use it however you like.

## Contributing

- [CONTRIBUTING.md](CONTRIBUTING.md) — development setup, validation, commit conventions,
  and how releases are cut.
- [AGENTS.md](AGENTS.md) — repo layout, contracts, and agent-facing guidance.
- [packs/README.md](packs/README.md) — the pack contract for adding a new pack.
