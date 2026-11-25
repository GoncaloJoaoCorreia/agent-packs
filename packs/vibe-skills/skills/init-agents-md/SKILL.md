---
name: init-agents-md
description: Initialize or update a repository's AGENTS.md — preloaded with your standing conventions (no inline comments ever, conventional commits without PR number, clarify-before-assuming, approval-first boundaries); inspects the repo, then writes a concise AGENTS.md at the repo root. Use when the user wants to set up, create, or refresh AGENTS.md in a project.
license: Unlicense
compatibility: Requires a git repository; run from the repo root. Interactive (asks before overwriting / adjusting preferences).
user-invocable: true
---

# Init AGENTS.md

Create or refresh the root `AGENTS.md` of the current repository. Your standing
conventions are **preloaded below** — write them into the file verbatim unless you
adjust them for this repo; never re-ask each rule one by one.

## Preloaded conventions

Write this block (adjusted only if the user says so) as the `## Conventions`
section of the AGENTS.md:

```md
## Conventions

- Code comments: no inline comments, ever. Javadoc-style comments are allowed only
  for interface contract declarations, and only if needed.
- Commits: conventional commits — `type(scope): subject`, imperative mood, no PR
  number in the message.
- When a request is ambiguous, ask one short clarifying question before assuming.
- Ask for explicit approval before: destructive git operations (`reset --hard`,
  `clean -fd`, `branch -D`, ...), non-local database writes (migrations, deletes,
  anything but a local dev database), and deploys / package publishing /
  customer-visible notifications.
```

## Workflow

1. **Locate the repo root** (`git rev-parse --show-toplevel`) and check whether
   `AGENTS.md` already exists there. If it does, read it first and ask the user
   whether to replace it, merge into it, or abort.
2. **Inspect the repo** (read-only) to ground the file in facts — do not guess:
   primary language(s), package manager + lockfile, test runner and commands,
   linter/formatter, CI workflows, existing `CONTRIBUTING.md` / README conventions,
   and the commit style from `git log`.
3. **Ask one question**: "Use the preloaded conventions as-is for this
   repo, or adjust them?" Apply the answer; if they adjust, change only what they
   mention.
4. **Write `AGENTS.md`** at the repo root — concise, factual, imperative. Sections:
   **Repo** (stack + build/test/lint commands from step 2) and **Conventions**
   (the preloaded block). Keep it under ~100 lines; link to
   `CONTRIBUTING.md` or other docs instead of inlining them.
5. **Verify**: re-read the written file, confirm the preloaded block is intact
   (unless adjusted), and summarize what was written and where.

## Rules

- The preloaded block above is the only source for these conventions — never
  invent or "improve" them, and do not add a communication-style or test/lint
  verification policy (the user deliberately omits those).
- AGENTS.md is instructions for agents, not a README: no marketing, no history.
- When writing any file (including AGENTS.md itself): no inline comments, ever —
  Javadoc-style only for interface contract declarations, if needed.
- Ask before overwriting an existing `AGENTS.md`; reference existing convention
  docs instead of duplicating them.
