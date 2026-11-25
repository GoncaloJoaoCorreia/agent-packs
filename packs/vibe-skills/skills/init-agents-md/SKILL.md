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
- If the current task has an issue key (Linear, Jira, GitHub issue, ...), include
  it: `type/ISSUE-KEY-short-kebab-description`, e.g. `feat/G-20-driver-state`.
  Take the key from the task itself (issue URL, key in the prompt, or the forge
  CLI) — never invent one. No issue → omit the key.

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

- Tests are not free — each one costs review attention, maintenance, and tokens on
  every future change to the code it touches. Write a new test only when it can
  catch a realistic regression in behavior someone depends on: be able to name a
  concrete bug that would make this test fail while the rest of the suite passes.
  No nameable bug → don't write it. Never chase coverage stats or test counts.
- Concentrate tests where failure is expensive: money/billing/quantities/rounding,
  data integrity and migrations, auth/authz and tenant isolation, external
  contracts (API, serialization, wire/storage formats), concurrency/retries/
  recovery, irreversible side effects (sends, deletes, publishes). Trivial glue on
  a non-critical path needs no test.
- Real value: business rules, branching, calculations, invariants, normalization,
  validation; error handling, retries, permission checks, boundary conditions,
  fallbacks; state transitions and externally visible side effects; module/API
  boundary contracts; regression tests for real past bugs.
- Low value — don't write: getter/DTO echo assertions, stub-only assertions with no
  decision-making behind them, mock-interaction checks with no visible outcome,
  asserting framework/library behavior, re-implementing the production code inside
  the test, `not null`/size-only assertions, trivial mappers or generated code
  written just for coverage, duplicate tests of the same branch with different
  literals, and tests pinned to implementation structure that fail on
  behavior-preserving refactors.
- May look trivial but can still be valuable: constructors/factories that validate,
  normalize, parse, or reject input; value objects whose equality, ordering, or
  hashing encode business rules; mapping/serialization code with contract risk;
  wrappers that enforce invariants.

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
   verbatim (with any changes stated in the invocation prompt). The preloaded block
   alone is ~100 lines, so keep the `## Repo` section tight; link to
   `CONTRIBUTING.md` or other docs instead of inlining them.
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
