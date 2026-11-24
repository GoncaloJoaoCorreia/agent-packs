---
name: init-agents-md
description: Initialize or update a repository's AGENTS.md with the user's personal development preferences — inspect the repo, ask a short set of preference questions, then write a concise AGENTS.md at the repo root. Use when the user wants to set up, create, or refresh AGENTS.md in a project.
license: Unlicense
compatibility: Requires a git repository; run from the repo root. Interactive (asks the user questions).
user-invocable: true
---

# Init AGENTS.md

Create or refresh the root `AGENTS.md` of the current repository so it encodes the
user's personal development preferences alongside repo-specific facts.

## Workflow

1. **Locate the repo root** (`git rev-parse --show-toplevel`) and check whether
   `AGENTS.md` already exists there. If it does, read it first and ask the user
   whether to replace it, merge into it, or abort.
2. **Inspect the repo** (read-only) to ground the file in facts — do not guess:
   primary language(s), package manager + lockfile, test runner and how tests are
   run, linter/formatter and their commands, CI workflows, existing
   `CONTRIBUTING.md` / README conventions, and the commit style from `git log`
   (e.g. conventional commits, imperative mood).
3. **Ask the user their personal preferences** in a short batch of questions; skip
   anything they don't care about:
   - Communication: terse or detailed? Any wording or formatting to avoid?
   - Code style: naming conventions, comments policy, error handling, preferred
     patterns or libraries?
   - Workflow: always run tests/lint before finishing? Commit message style? PR and
     changelog conventions?
   - Boundaries: operations to always ask about first (force-push, migrations,
     production deploys, deleting files, publishing)?
   - Anything else they always want done, or never done?
4. **Write `AGENTS.md`** at the repo root — concise, factual, imperative. Suggested
   sections: **Repo** (stack + build/test/lint commands), **Personal preferences**
   (from step 3), **Workflow** (test/commit/PR rules), **Boundaries** (ask-first
   list). Keep it under ~100 lines; link to larger docs instead of inlining them.
5. **Verify**: re-read the written file, confirm it matches what the user answered,
   and summarize what was written and where.

## Rules

- AGENTS.md is instructions for agents, not a README: no marketing, no history.
- Never invent preferences — if the user didn't answer something, omit it.
- If the repo already has conventions (`CONTRIBUTING.md`, an existing `AGENTS.md`),
  follow them and reference them instead of duplicating.
- Ask before overwriting an existing `AGENTS.md`.
