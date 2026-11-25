# vibe-skills

Skills for [Mistral Vibe](https://github.com/mistralai/mistral-vibe), kept in one
place so the same skills work on your **local CLI** and in **cloud Vibe** (Vibe Work
at chat.mistral.ai and cloud sessions).

## Included skills

| Skill | What it does | How to use |
|---|---|---|
| `init-agents-md` | Creates or refreshes a repo's root `AGENTS.md`: it inspects the repo, shows you the full draft for approval before writing anything, then writes the file. Ships with preloaded standing conventions — comments, commits & PRs (incl. no AI attribution), branch naming with issue key, SemVer 2.0.0, Keep a Changelog 1.1.0, value-based tests, safety rules — so you don't have to re-explain them in every repo. | Run `/init-agents-md` from the repo root. Pass tweaks in the prompt, e.g. `/init-agents-md drop the commits rule`. |

## Install on the local CLI

From a checkout of this repo:

```sh
./install.sh vibe-skills
```

Or without a checkout (downloads the latest release):

```sh
curl -fsSL https://raw.githubusercontent.com/GoncaloJoaoCorreia/agent-packs/main/install.sh | sh -s -- vibe-skills
```

Then in Vibe run `/reload` — the skills show up in `/skills` as user-level skills and
as slash commands (e.g. `/init-agents-md`). Use `/skills` to toggle individual skills
on or off.

No installer? Point Vibe straight at the skills in `~/.vibe/config.toml`:

```toml
skill_paths = ["/absolute/path/to/agent-packs/packs/vibe-skills/skills"]
```

## Use in cloud Vibe

Every release publishes these skills to the Mistral registry automatically, so they
are available in Vibe Work and cloud sessions: invoke them with `@init-agents-md`
in chat.mistral.ai. In the local CLI you can also pull the shared registry copies
via `experimental_enable_registry_skills = true` in `~/.vibe/config.toml` and the
**Shared** tab of `/skills` — local files win on name collisions, so this repo stays
the source of truth.

## For maintainers

Add a skill as `skills/<name>/SKILL.md` (Agent Skills format, one directory per
skill). CI validates every skill on each PR; the Release workflow publishes them to
the cloud registry. See [docs/local-and-cloud.md](docs/local-and-cloud.md) for how
the local and cloud installs work under the hood.
