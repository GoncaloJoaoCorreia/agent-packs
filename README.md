# agent-packs

[![test](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/test.yml/badge.svg)](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/test.yml)
[![build](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/release.yml/badge.svg)](https://github.com/GoncaloJoaoCorreia/agent-packs/actions/workflows/release.yml)
[![release](https://img.shields.io/github/release/GoncaloJoaoCorreia/agent-packs?display_name=tag)](https://github.com/GoncaloJoaoCorreia/agent-packs/releases/latest)
[![license](https://img.shields.io/badge/license-Unlicense-blue)](LICENSE)

A personal library of agent-harness extensions — **packs**. Each pack under
[`packs/`](packs/) is self-contained and installs into one harness's config directory
(see [`packs/README.md`](packs/README.md) for the pack contract).

## Packs

| Pack | Harness | What you get | Docs |
|---|---|---|---|
| [`opencode`](packs/opencode/) | [OpenCode v2](https://opencode.ai/v2/docs/) | The **driver** — `/driver` runs an entire feature cycle as coordinated subagents — plus **driver-viz**, a TUI sidebar plugin showing the live phase flow chart | [packs/opencode/README.md](packs/opencode/README.md) |
| [`vibe-acp`](packs/vibe-acp/) | [OpenCode v2](https://opencode.ai/v2/docs/) | **Mistral Vibe as an OpenCode provider** — drives `vibe-acp` over ACP (no OpenCode fork): the `vibe/<model>` provider appears in `/models` automatically, `/connect` offers "Sign in with Vibe CLI" | [packs/vibe-acp/README.md](packs/vibe-acp/README.md) |

More harnesses can be added as new packs — see
[AGENTS.md](AGENTS.md) → "Adding a pack".

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/GoncaloJoaoCorreia/agent-packs/main/install.sh | sh
```

The installer lists the available packs and asks which to install (you can pick several).
Without a TTY it installs the default pack (`opencode`). To skip the prompt:

```sh
sh -s -- opencode        # one pack, non-interactive
sh -s -- all             # every pack
install.sh --list        # just list the packs
```

In a local checkout of this repo, run `./install.sh` instead — it installs straight from
source (same copy-based install; nothing is built). Re-run it after pulling changes.

Each release carries one `agent-packs.tar.gz` (containing `packs/` +
`install.sh` + `LICENSE`) plus `SHA256SUMS`; the installer downloads it, verifies the
checksum, and installs only the packs you selected. Installs are copy-based and write a
per-pack `<prefix>.version` + `<prefix>.manifest` into the config dir, which drives
stale-file cleanup on reinstall. The installer requires `python3` and `git` for the
opencode pack (hard prerequisite — it fails with a clear message otherwise).

## Repo layout

```
install.sh            # self-contained installer: pack picker + per-pack install
packs/<name>/         # one self-contained pack per harness (pack.conf + payload; scripts/ + docs/ are repo-only)
scripts/validate.sh   # repo-wide validation dispatcher (CI + local)
.github/workflows/    # test.yml (PRs), release.yml (manual releases)
```

See [AGENTS.md](AGENTS.md) for the full layout, contracts, and extension points.
