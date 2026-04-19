# 14 — `/audit-and-fix` Claude skill

## Goal

Codify the defacto "ultrathink audit" ritual as a first-class Claude skill. Every week or so the user kicks off a prompt like `"ultrathink to analyze the whole code of the application, you can create sub-agent ... to split the work in parallel tasks"`. The skill formalizes what that should do and, critically, holds Claude to a structured contract so findings don't silently drop.

## Evidence

- Group B: `"don't follow recomandation, instead ultrathink to fix all"` appears identically in 3+ sessions.
- Group C: user runs the same prompt 6+ times with near-zero variation.
- Group C high-signal moment: "The user had to re-prompt with 'ultrathink' multiple times to get full coverage" — Claude selectively acted on findings.
- Group D: `/release-review` skill was too lenient; a tighter sibling skill is needed.

## Current state

- Skill `superpowers:writing-plans`, `superpowers:executing-plans`, `superpowers:dispatching-parallel-agents` exist.
- No skill encodes the audit-and-fix workflow.
- No structured finding ledger; findings are embedded in prose and easy to miss.

## Target design

### 1. Skill location

- `.claude/skills/audit-and-fix/SKILL.md` (project-level skill, checked into the repo). Or user-level at `~/.claude/skills/audit-and-fix/SKILL.md` if the user prefers to reuse across projects.

### 2. Skill contract (high level)

The skill:

1. **Splits the audit** into named lanes and dispatches one sub-agent per lane in parallel:
   - Domain (models, pure logic)
   - Features (ViewModels, Views)
   - Infrastructure (GitHub client, persistence, keychain, networking, avatar, local repo)
   - Tests (coverage, flakiness, correctness)
   - Concurrency & cancellation
   - App Store compliance (sandbox, entitlements, metadata, privacy manifest)
   - Performance (hot paths, memory, startup time)
   - UX (error surfaces, empty states, accessibility)

2. **Each sub-agent returns a structured JSON finding list**, not prose:

   ```json
   [
     {
       "id": "FINDING-001",
       "title": "DashboardViewModel missing deinit",
       "severity": "high",
       "file": "PullRequestPilot/Features/Dashboard/DashboardViewModel.swift",
       "lineRange": "120-135",
       "rootCauseCategory": "concurrency",
       "userImpact": "stranded refresh tasks after view dismissal",
       "suggestedFix": "Add deinit that cancels tasks and removes NC observer.",
       "blastRadius": "small",
       "testStrategy": "assert tasks cancelled after view model released"
     }
   ]
   ```

3. **Synthesizer agent merges findings** into a single ledger, dedupes, groups by `rootCauseCategory`, sorts by severity.

4. **Orchestrator (Claude) surfaces the ledger as a TodoWrite checklist** — one todo per finding. No finding is allowed to silently drop.

5. **Default mode is fix-mode**, not propose-mode. The skill executes the suggested fix for each finding. Only findings with `severity: "high"` and `blastRadius: "cross-cutting"` pause for user approval.

6. **After fixes**: run `make build`, `make test`, `make lint`. All must pass.

7. **Commit shaping**: split the resulting diff into one commit per `rootCauseCategory`, with conventional-commit-style messages. Prefixes: `Fix`, `Refactor`, `Add`, `Update`.

8. **Output a markdown report**: `todo/audits/AUDIT-<date>.md` with the ledger + per-finding outcome (fixed / deferred / rejected) + regression test status.

### 3. SKILL.md body (template for writing it)

```markdown
---
name: audit-and-fix
description: Whole-codebase audit + autonomous fix. Default mode for the "ultrathink audit" ritual on this repo. Dispatches parallel lane-focused sub-agents, collects findings into a structured ledger, fixes high-confidence findings, runs build/test/lint, shapes commits for changelog, and emits an audit report.
---

# audit-and-fix

Use when the user asks for a codebase audit, uses the phrase "ultrathink" on its own, or asks to "fix everything". Do not use for single-file reviews (use superpowers:requesting-code-review instead).

## Lanes

Dispatch one sub-agent per lane in parallel. Lane scope and non-scope is defined below.

### Lane 1: Domain
... (full definition of scope, expected findings, excluded concerns)

### Lane 2: Features
...

[etc.]

## Contract for each sub-agent

Return JSON matching the `Finding` schema. Do not return prose. If you find nothing, return `[]`.

## Synthesizer

After all lanes return:
1. Merge into a single array.
2. Deduplicate by (file, lineRange, rootCauseCategory).
3. Sort by severity desc.
4. Emit as TodoWrite todos (one per finding).

## Fix execution

For each finding in order:
- If `severity in {low, medium}`: apply the suggested fix, commit.
- If `severity == high` and `blastRadius == small`: apply + commit.
- If `severity == high` and `blastRadius >= medium`: ask user first.
- If `severity == critical`: ask user first regardless.

## Verification

After all fixes:
- `make build` clean.
- `make test` green.
- `make lint --strict` green.

If any fail, fix or revert.

## Commit shaping

Split diff by `rootCauseCategory`:
- `Fix: Concurrency — rethrow CancellationError in network layer`
- `Fix: Pagination — cap timeline fetch at 20 pages`
- `Refactor: Dashboard — extract AutoRefreshScheduler`
- ...

## Output

Write report to `todo/audits/AUDIT-YYYY-MM-DD.md`:
- Summary (N findings total, M fixed, K deferred).
- Ledger table (id, title, severity, category, outcome).
- Build/test/lint status.
```

## Implementation steps

### Step 1 — Draft `SKILL.md`

**Files**
- New: `.claude/skills/audit-and-fix/SKILL.md`
- New: `.claude/skills/audit-and-fix/references/finding-schema.json` (JSON Schema for validation)
- New: `.claude/skills/audit-and-fix/references/lane-definitions.md`

**Changes**
- Expand the template above to full-spec.
- Finding schema is JSON Schema; sub-agents are instructed to conform exactly.

### Step 2 — Validate on a dry run

- Run the skill on the current repo with the synthesizer in "report only" mode (no fixes).
- Confirm the ledger size is similar to historical "ultrathink audit" output (~20-30 findings per run).
- Confirm no finding is lost between sub-agent output and synthesizer report.

### Step 3 — Enable fix-mode

- Run the full skill on a small scope first (one lane only).
- Verify commit shaping is clean.
- Run on the whole repo.

### Step 4 — Update CLAUDE.md

- Add the "Audit & Fix Workflow" section from `../00-claude-md-improvements.md` Patch 11.
- Reference the skill by name.

### Step 5 — Deprecate ad-hoc "ultrathink audit" prompts

- When the user types the ritual phrase, Claude should suggest invoking the skill rather than re-deriving the format.

## Risks

- **Sub-agent JSON conformance** — if a sub-agent returns prose instead of JSON, the synthesizer breaks. Include a validation step + one retry in the skill.
- **Commit shaping reshuffling** — `git stash` + selective apply has historically been labor-intensive; the skill should use `git add -p` scripted with file-level hunks when possible, falling back to manual when hunks cross categories.
- **Fix quality variance** — if a lane-focused sub-agent applies a bad fix, we catch it at build/test/lint. Make sure those gates are truly green before commit.
- **Over-agent-ing** — eight parallel sub-agents × a few minutes each is still faster than the current serial pattern, but it costs tokens. Skill should expose a `--lanes=domain,features` selector.

## Out of scope

- Auto-writing new tests for uncovered code paths (separate skill).
- Running the skill autonomously on a schedule (manual invocation only for now).

## Done criteria

- [ ] Skill exists, invokable as `/audit-and-fix`.
- [ ] Lane definitions documented, JSON finding schema defined and validated.
- [ ] Synthesizer emits TodoWrite ledger.
- [ ] Fix-mode passes build/test/lint gates.
- [ ] Commit shaping produces per-category commits with conventional-commit prefixes.
- [ ] Report file `todo/audits/AUDIT-YYYY-MM-DD.md` written.
- [ ] CLAUDE.md references the skill.
- [ ] Tried on at least one full-repo run, compared against the most recent "ultrathink audit" session for coverage parity.
