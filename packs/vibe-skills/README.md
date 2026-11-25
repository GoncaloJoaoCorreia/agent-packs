# vibe-skills pack

A repository of [Mistral Vibe](https://github.com/mistralai/mistral-vibe) skills —
one source of truth, installable on the **local CLI** and publishable to **cloud Vibe**.
(Repo-only doc; stripped from release payloads.)

## What's here

```
packs/vibe-skills/
  pack.conf                  # installs skills/ into ${VIBE_HOME:-~/.vibe}/ (user-level skills)
  skills/<name>/SKILL.md     # the skills — Agent Skills format (agentskills.io), one dir each
  scripts/validate.sh        # repo-only: validates every skill + installer smoke test (CI)
  scripts/publish-to-cloud.py# repo-only: pushes skills to the Mistral registry (/v2/skills)
  docs/local-and-cloud.md    # repo-only: how skills reach local CLI and cloud Vibe
```

## Local install

```sh
./install.sh vibe-skills        # copies skills/ into ${VIBE_HOME:-~/.vibe}/skills/
# then in Vibe: /reload          # skills appear in /skills as user-level skills
```

Without the installer, point `skill_paths` at the checkout in `~/.vibe/config.toml`.

## Cloud publish

Automated: the manual **Release** workflow (`release.yml`) runs
`publish-to-cloud.py --apply` on every release (needs the `MISTRAL_API_KEY` repo
secret; skip with the `publish_skills=false` workflow input). Manual fallback:

```sh
MISTRAL_API_KEY=... python3 packs/vibe-skills/scripts/publish-to-cloud.py --apply
# then in Studio: Share with workspace + "Publish to Vibe" per skill
```

See [docs/local-and-cloud.md](docs/local-and-cloud.md) for the full research and the
local↔cloud sync loop.
