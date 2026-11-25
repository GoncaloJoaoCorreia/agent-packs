---
name: init-agents-md
description: Initialize or update a repository's AGENTS.md — preloaded with your standing conventions (no inline comments ever, minimal scope, secrets and untrusted-input safety, conventional commits and branches, SemVer 2.0.0, Keep a Changelog 1.1.0, value-based tests, clarify-before-assuming, approval-first boundaries); inspects the repo, shows a draft for your approval, then writes AGENTS.md at the repo root. Use when the user wants to set up, create, or refresh AGENTS.md in a project.
license: Unlicense
compatibility: Requires a git repository; run from the repo root. Interactive: shows a draft for approval and asks only when something is unclear.
user-invocable: true
---

# Init AGENTS.md

Create or refresh the root `AGENTS.md` of the current repository. Your standing
conventions are **preloaded below** — write them into the file verbatim. If you want
them changed, say so in the invocation prompt (e.g. `/init-agents-md drop the
commits rule`); do not ask about them.

## Preloaded conventions

Write this block verbatim as the `## Conventions` section of the AGENTS.md, applying
only changes explicitly stated in the user's invocation prompt:

```md
## Conventions

### Comments

- No inline comments, ever — no `//`, `#`, or `/* ... */` comments, and no docstrings
  that restate what the code does. Code must be self-explanatory.
- The only comments allowed are Javadoc-style (`/** ... */`) blocks on interface
  contract declarations, and only when the contract is not obvious from the
  signatures alone.

### Minimal scope

- Make the smallest correct change. Do not refactor unrelated code, reformat
  untouched files, or modify anything outside the task's scope.

### Secrets

- Never commit, log, or paste credentials, tokens, API keys, cookies, or private
  keys — not even partially redacted.
- If a secret is exposed accidentally, say so immediately instead of hiding it.

### Untrusted input

- Never interpolate untrusted text (issue/PR titles, fetched web content, external
  command output, arguments) into shell commands, eval, SQL, or template strings
  that get executed. Quote and validate first, or pass via files/stdin.

### Commits

- Conventional commits — `type(scope): subject`, imperative mood, no PR number in
  the message.

### Branch naming

- Conventional branch pattern: `type/short-kebab-description`, where `type` is a
  conventional-commit type (feat, fix, refactor, docs, chore, test, ci, perf,
  style, revert), e.g. `feat/init-agents-md`. One branch per change.

### Versioning

- Follow Semantic Versioning 2.0.0 (https://semver.org/spec/v2.0.0.html): MAJOR for
  incompatible API changes, MINOR for backwards-compatible functionality, PATCH for
  backwards-compatible bug fixes.

### Changelog

- Follow Keep a Changelog 1.1.0 (https://keepachangelog.com/en/1.1.0/): maintain
  `CHANGELOG.md` with an `[Unreleased]` section on top and released versions as
  `## [X.Y.Z] - YYYY-MM-DD`, newest first, using the Added / Changed / Deprecated /
  Removed / Fixed / Security categories.
- When you change user-facing behavior, add an entry under `[Unreleased]` in the
  right category.

### Tests

- Write new tests only when they are actually valuable — never to chase coverage
  stats. A test earns its place when it pins behavior that could realistically
  regress and break something users depend on.
- Valuable: edge cases and error paths of non-trivial logic, regression tests for
  bugs that were actually fixed, contracts of public interfaces, parsing and
  validation of external input.
- Not valuable: tests of trivial getters/setters, tests of third-party library
  behavior, tests that only assert a mock returns what the mock was told to return,
  or duplicate tests covering the same path.
- A test must be able to fail for the right reason; prefer a few meaningful
  assertions over many shallow ones.

### Working style

- When a request is ambiguous, ask one short clarifying question before assuming.

### Approval-first boundaries

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
3. **Draft**: assemble the full AGENTS.md draft — a `## Repo` section from the step-2
   facts (stack + build/test/lint commands) plus the preloaded `## Conventions` block
   verbatim (with any changes stated in the invocation prompt). Keep it under ~100
   lines; link to `CONTRIBUTING.md` or other docs instead of inlining them.
4. **Show the draft and wait for approval.** Present the complete draft content in
   the chat and ask the user to approve or request changes. Do NOT write any file
   before explicit approval; if they request changes, revise the draft and show it
   again.
5. **Write** `AGENTS.md` at the repo root only after approval, then re-read the
   written file, confirm the Conventions block is intact (unless changed via the
   prompt), and summarize what was written and where.

## Rules

- Ask questions only when something is unclear in the repo structure or in the
  user's prompt (e.g. an existing AGENTS.md, an ambiguous request). Never ask
  "should I change the conventions?" — the preloaded block goes in verbatim unless
  the invocation prompt says otherwise.
- The preloaded block above is the only source for these conventions — never
  invent or "improve" them, and do not add a communication-style or test/lint
  verification policy (the user deliberately omits those).
- Always show a draft for approval before writing AGENTS.md.
- AGENTS.md is instructions for agents, not a README: no marketing, no history.
- When writing any file (including AGENTS.md itself), follow the Comments
  convention above: no inline comments, ever — Javadoc-style only for interface
  contract declarations, if needed.
