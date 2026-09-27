---
name: audit-and-fix
description: Use when the user asks for a whole-codebase audit of this repo, such as "ultrathink" used as a ritual, "analyze the whole code", "audit the repo", "fix all the findings", or parallel sub-agent analysis. Not for one file or one change (use /code-review), nor for the pre-release sweep (use /release-review).
---

# audit-and-fix

Whole-codebase audit of Pull Request Pilot. One agent per lane finds, one independent verifier per finding tries to refute it, and every surviving finding is fixed or put to the user. The report in `todo/audits/` accounts for every finding.

**No finding silently drops.** Each finding a lane returns ends in the ledger with an outcome: fixed, rejected (refuted, with the evidence), reverted, deferred (waiting on a user decision) or closed by a user decision. A prose summary that acts on "the important ones" is the failure this skill exists to prevent.

Fix mode is the default. Stop after the report only when the user asks for an assessment.

## 1. Scope and baseline

Default: all eleven lanes in `references/lane-definitions.md` (domain, features, infrastructure, appshell, tests, concurrency, appstore, performance, ux, architecture, macos-platform). The user can name a subset: `lanes=tests,concurrency`.

Record the baseline on the untouched tree: HEAD, then `make test` and `make build` with their test count. Later failures are then attributable to the fixes.

## 2. Find and verify

Run lanes and verifiers through the Workflow tool; invoking this skill is the opt-in, and an audit exceeds the default workflow size on purpose. Scripts can't read files: inline both schemas from `references/` and each lane's text (preamble + section) into the script. Agents already get CLAUDE.md.

```js
export const meta = {
  name: 'audit',
  description: 'Whole-codebase audit: one finder per lane, one refuting verifier per finding',
  phases: [{ title: 'Find' }, { title: 'Verify' }],
}
const FINDINGS = {/* references/finding-schema.json */}
const VERDICT = {/* references/verdict-schema.json */}
const LANES = [/* { name: 'domain', prompt: '<preamble>\n\n<domain section>' }, … */]
const REFUTE = 'Try to refute this audit finding of Pull Request Pilot. Re-read the cited code and its callers. ' +
  'Check any claim about GitHub or Apple API behaviour against live data (read-only `gh api graphql`) or the documentation. ' +
  'Confirm it, narrow it (state the correction), or refute it; refute when the evidence does not hold.'

const results = await pipeline(
  LANES,
  lane => agent(lane.prompt, { label: `find:${lane.name}`, phase: 'Find', schema: FINDINGS }),
  (found, lane) => found && parallel(found.findings.map(finding => () =>
    agent(`${REFUTE}\n\n${JSON.stringify(finding)}`, { label: `verify:${lane.name}`, phase: 'Verify', schema: VERDICT })
      .then(verdict => ({ ...finding, verdict })),
  )).then(findings => ({ ...found, lane: lane.name, findings })),
)
return results.map((result, index) => result ?? { lane: LANES[index].name, failed: true })
```

A lane that comes back `failed` is re-run once on its own; if it fails again, the report says so. A finding whose verdict is `null` was not verified: verify it yourself before fixing it.

## 3. Ledger

1. Merge duplicates across lanes: same file, overlapping lines, same root cause. Keep the highest verified severity and list every lane that reported it.
2. Number the surviving findings (confirmed, narrowed, or verified by you) `FINDING-001`… by verified severity.
3. Write the report (step 7) now, with every finding in the ledger. The report file is the ledger: update each row's outcome as the work progresses.

Refuted findings go to the Rejected section with the verifier's evidence; they are not fixed.

## 4. Fix

| finding | action |
|---------|--------|
| low or medium, small or medium blast | fix |
| high, small blast | fix |
| critical; any large or cross-cutting blast; a change of behaviour the user may not want (removing a feature, changing a flow) | summarise, ask, mark `deferred` until answered |

Each fix:
- Comes with a test that fails when the fix is reverted: revert it and watch the test fail. What only a person can observe (views, system behaviour) goes to Manual checks in the report instead.
- Works within the tooling. When SwiftLint blocks the direct fix, don't work around the rule: defer the finding with the reason.
- Carries no finding ID in source; lint rejects `FINDING-NNN`.

Group the fixes into slices by user-visible area (Identity, GitHub API, Refresh, Widgets, Tests, Release…), in dependency order. These become the commits.

## 5. Gates and review of the fix wave

After each slice: `make test` (lint + unit tests) and `make build` (Release, warnings as errors); also `make release-check` when the slice touches `project.yml`, entitlements, privacy manifests or `metadata/`. When a slice fails, find the fix that broke it, revert that fix, and mark it `reverted — <reason>`.

Once every slice is green, review the fix wave itself: run refuting verifiers over the baseline..working-tree diff, slice by slice. Earlier fix waves shipped regressions that only a review of the diff caught. A regression becomes a new finding in the ledger and goes through step 4.

## 6. Commits

Don't commit. Leave the changes in the working tree, green, and put a commit plan in the report: one commit per slice, each of which builds and passes the tests on its own.

```
Fix: <Area> — <the user-visible change>

<what changed and why, in a short paragraph>

Audit YYYY-MM-DD: FINDING-012, FINDING-031.
```

The user drives the commits. When they ask you to commit, follow the plan: stage whole files; where one file spans two commits, stage its hunks with `git apply --cached` on a trimmed patch (the agent shell has no interactive `git add -p`). If the hunks can't compile apart, merge those commits and note it in the report.

## 7. Report

`todo/audits/AUDIT-YYYY-MM-DD.md`. `todo/` is excluded from git: never commit or publish a report.

```markdown
# Audit — YYYY-MM-DD

## Summary

- Lanes: {list}. Raw findings N; after merging duplicates M (critical / high / medium / low).
- Verification: confirmed C · narrowed P · refuted R · unverified U.
- Outcome: fixed F · deferred D · reverted V · rejected R · closed by decision X.
- Baseline (HEAD <sha>): lint · build · tests (count). After: lint · build · tests (count) · release-check if run.

## Verdict

A grade and the few themes behind it: what is strong and mechanically enforced, where the code falls short.

## Ledger

| id | severity | category | file:lines | title | verification | outcome |
|----|----------|----------|------------|-------|--------------|---------|

## Rejected

Each refuted finding and the evidence that refuted it.

## Deferred

Each finding waiting on the user, and the decision it needs.

## Manual checks

What tests can't reach, one line each, with its finding ID.

## Opportunities

From the macos-platform lane, ranked by value and effort. Not findings.

## Commit plan

The planned commits in order, with their finding IDs; their SHAs once the user has committed.

## Lane failures

Lanes that failed twice, or "None".
```

## Red flags — stop and re-read this skill

| Thought | Reality |
|---------|---------|
| "The lanes agree, no need to verify" | Two lanes once reported the same high finding from the same wrong assumption about the GitHub API. Verify each one. |
| "Only a few findings really matter" | Every finding gets a ledger row and an outcome. |
| "The fix is obvious, no test needed" | A fix without a test that fails on revert can regress unnoticed. |
| "The gates passed, the fix wave is done" | The gates don't catch behaviour regressions; the review of the diff does. |
| "I'll commit as I go" | The user drives commits. Leave a green tree and a commit plan. |
