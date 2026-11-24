---
name: manage-vibe-skills
description: Create, update, or remove Mistral Vibe skills in the agent-packs repo (packs/vibe-skills/), install them into the local Vibe CLI, and publish them to the cloud Vibe registry so they work in Vibe Work and cloud sessions. Use when the user asks to add or change a Vibe skill or to sync skills between the local CLI and cloud Vibe.
license: Unlicense
compatibility: Requires an agent-packs repo checkout; cloud publishing additionally requires MISTRAL_API_KEY.
user-invocable: true
---

# Manage vibe-skills

The `vibe-skills` pack in this repo is the **single source of truth** for Mistral Vibe
skills: every skill is one directory under `packs/vibe-skills/skills/`, in the
Agent Skills format (`SKILL.md` + YAML frontmatter) that Vibe follows natively.

## Layout

- `packs/vibe-skills/skills/<skill-name>/SKILL.md` — one directory per skill; extra
  files (`references/`, `scripts/`, `assets/`) live beside `SKILL.md`.
- `packs/vibe-skills/scripts/validate.sh` — validates every skill (also run by the
  root `scripts/validate.sh` in CI).
- `packs/vibe-skills/scripts/publish-to-cloud.py` — pushes skills to the Mistral
  registry (the cloud side). Dry-run by default; `--apply` writes.
- `packs/vibe-skills/docs/local-and-cloud.md` — how skills reach the local CLI and
  cloud Vibe, and why this repo is the source of truth.

## Rules for every skill

1. Directory name MUST equal the frontmatter `name`: `^[a-z0-9]+(-[a-z0-9]+)*$`,
   at most 64 chars. `description` is required, single line, at most 1024 chars, and
   must say what the skill does **and when to use it** (the model picks skills by it).
2. Keep skill content harness-agnostic: no references to OpenCode or to the opencode
   pack's driver. Only this management skill may reference repo paths.
3. After adding or editing a skill, from the repo root run `sh scripts/validate.sh`,
   then reinstall with `./install.sh vibe-skills` and `/reload` in Vibe.
4. To update the cloud copy, run
   `MISTRAL_API_KEY=... python3 packs/vibe-skills/scripts/publish-to-cloud.py --apply`
   (unchanged skills are skipped). Then in Studio open the skill, Share it with the
   workspace, and click **Publish to Vibe** so it appears in Vibe Work
   (chat.mistral.ai, invoked with `@skill-name`) and in cloud Vibe sessions.
5. Local Vibe can also pull the cloud copy back: set
   `experimental_enable_registry_skills = true` in `~/.vibe/config.toml` and pin
   skills from the Shared tab of `/skills` (pins live in `~/.vibe/skills.toml`).
   Local files win over registry skills on a name collision — the repo copy stays
   authoritative.
