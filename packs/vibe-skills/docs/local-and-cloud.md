# vibe-skills — one source of truth for Mistral Vibe skills, local + cloud

Status: implemented (pack scaffold + publish script). Research basis:
[mistralai/mistral-vibe](https://github.com/mistralai/mistral-vibe) (skill manager,
config schema) and [docs.mistral.ai/vibe](https://docs.mistral.ai/vibe) (CLI skills,
Studio skills, beta Skills API), read 2026-11-24.

Goal: keep every Mistral Vibe skill in **this repo** (`packs/vibe-skills/skills/<name>/`,
Agent Skills format — Vibe follows [agentskills.io](https://agentskills.io), so the
files are portable), and make the same skills available in both:

1. the **local Vibe CLI**, and
2. **cloud Vibe** (Vibe Work at chat.mistral.ai, Vibe cloud sessions, Studio agents).

## How the local CLI discovers skills

From `vibe/core/skills/manager.py` + `docs.mistral.ai/vibe/code/cli/skills`, in
resolution order:

| Source | Location | Notes |
|---|---|---|
| `skill_paths` in `config.toml` | any dirs you list | searched first |
| project-level | `./.vibe/skills/` or `./.agents/skills/` | only in trusted folders |
| user-level | `~/.vibe/skills/` or `~/.agents/skills/` | always loaded; `VIBE_HOME` env var overrides `~/.vibe` |
| plugins | `~/.vibe/plugins/`, project `.vibe/plugins/` | skills prefixed `/<plugin>:<skill>` |
| registry (experimental) | pulled from api.mistral.ai | `experimental_enable_registry_skills = true`; pins in `~/.vibe/skills.toml` / project `.vibe/skills.toml`, managed in the `/skills` Shared tab |

Runtime behavior: `/reload` picks up added/edited skills without a restart; `/skills`
lists and toggles them (toggling writes `disabled_skills`); `enabled_skills` /
`disabled_skills` filter by exact name, glob, or `re:` regex. On a name collision,
project skills win over user skills, and local files win over registry skills.

**This pack installs into the user-level path**: `pack.conf` sets
`PACK_DEFAULT_DEST=${VIBE_HOME:-$HOME/.vibe}` and `install.sh` declares
`PACK_PAYLOAD_DIRS="skills"`, so `install.sh vibe-skills` copies
`packs/vibe-skills/skills/` → `~/.vibe/skills/`
(copy-based, per repo convention — never symlink; re-run the installer after
pulling changes, then `/reload` in Vibe). Alternative without the installer:
`skill_paths = ["/abs/path/to/agent-packs/packs/vibe-skills/skills"]` in
`~/.vibe/config.toml`.

Skill format contract (enforced by `scripts/validate.sh`): a skill is a directory with
`SKILL.md`; frontmatter `name` (`^[a-z0-9]+(-[a-z0-9]+)*$`, ≤64 chars) must equal the
directory name; `description` is required, ≤1024 chars, and must state what the skill
does and when to use it. `user-invocable: true` (default) exposes it as `/<name>`;
`disable-model-invocation: true` makes it model-only. Extra files (`references/`,
`scripts/`, `assets/`) ship beside `SKILL.md`.

## How cloud Vibe gets skills

- **Studio (La Plateforme)** is the cloud home of skills. Beta Skills API on
  `api.mistral.ai` (`docs.mistral.ai/api/endpoint/beta/skills`): `GET/POST /v2/skills`,
  `GET/PATCH/DELETE /v2/skills/{id}`, `GET/POST /v2/skills/{id}/versions`,
  `GET /v2/skills/{id}/versions/{version}`. A skill is versioned; payload is
  `{name, definition: {description, body, assets: {path: {textContent | rawContent(base64), isExecutable}}},
  sharingScope: private|workspace, aliases, notes}`; `POST .../versions` answers
  `{version, deduplicated}`. SDKs: `mistral.beta.skills.*`.
- In the Studio UI, **Share** keeps a skill private or shares it with the workspace,
  and **Publish to Vibe** on the skill's page makes it available in **Vibe Work**
  (chat.mistral.ai — invoke with `@skill-name`) and in **cloud Vibe sessions**.
- Deployed Studio agents attach skills in code:
  `skills=[agents.LocalSkillBundle.from_directory(...), agents.RegistrySkill(id=uuid, version=n)]`
  — registry skills must be shared with the workspace before deploy.

**This pack publishes to the registry**: `scripts/publish-to-cloud.py` maps each
`skills/<name>/` directory to a registry skill (SKILL.md body → `definition.body`,
other files → `definition.assets`, frontmatter description → `definition.description`),
creating the skill on first run and a **new version** on every change
(idempotent via the API's `deduplicated` flag). Existing skills are found by name via
the API (every published version carries the `agent-packs` alias), so the script works
from a fresh checkout; `scripts/cloud-manifest.json` is only a local name → id cache
(repo-only, stripped from release payloads).

It runs **automatically on releases of this pack** — the release workflow
(`.github/workflows/release.yml`) calls this pack's `scripts/release.sh` whenever
`packs/vibe-skills/**` payload changes, and that script runs
`publish-to-cloud.py --apply` (before the release tag is pushed). The workflow needs the
`MISTRAL_API_KEY` repository secret — without it the publish is skipped with a warning.
To publish by hand instead:

```sh
MISTRAL_API_KEY=... python3 packs/vibe-skills/scripts/publish-to-cloud.py --apply
```

Afterwards: in Studio, Share each skill with the workspace and click **Publish to Vibe**.

## The loop closes: cloud skills back into the local CLI

Set `experimental_enable_registry_skills = true` in `~/.vibe/config.toml` (needs the
Mistral provider + API key): the CLI lists workspace-shared registry skills in the
**Shared** tab of `/skills`, where you can pin a version or the `latest` alias
(pins stored in `~/.vibe/skills.toml`). Local files still win on name collisions, so the
repo copy remains authoritative — the registry is the distribution channel, not a
second editor.

## Recommended setup (single source of truth)

1. **Edit skills only in this repo** (`packs/vibe-skills/skills/<name>/`), validated by
   `scripts/validate.sh` in CI on every PR.
2. **Local**: `./install.sh vibe-skills` (or `skill_paths` pointing at the checkout),
   then `/reload` in Vibe.
3. **Cloud**: every release of this pack runs `publish-to-cloud.py --apply` (or run it
   by hand) → workspace-shared registry skills → **Publish to Vibe** in
   Studio → available in Vibe Work and cloud sessions.
   Optionally pin them back locally via the `/skills` Shared tab.

## Open questions / risks

- The `/v2/skills` API is **beta** — field names may change; `publish-to-cloud.py` is the
  single place that talks to it, so updates are localized.
- Registry skills in the CLI are behind `experimental_enable_registry_skills` — monitor
  the mistral-vibe CHANGELOG; until it graduates, local install relies on the file copy.
- "Publish to Vibe" is currently a Studio UI action; if an API field appears, wire it
  into `publish-to-cloud.py`.
- Registry skills need a Mistral provider + API key on the machine; on machines without
  one, only the local file copy is used.
