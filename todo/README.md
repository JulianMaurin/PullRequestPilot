# Engineering todo

Maintenance work the team should do on the codebase itself: critical fixes, refactors, lint/tooling. Product features are **not** here — they live in [`../product-roadmap/`](../product-roadmap/README.md).

Plans derived from an analysis of ~29 Claude Code sessions (Mar 25 → Apr 19, 2026).
Each file is self-contained enough for a fresh agent (no conversation context) to execute.

## Layout

```
todo/
├── 00-claude-md-improvements.md     — CLAUDE.md patches that prevent half the recurring bugs (foundational)
├── critical-fixes/                  — bugs and architecture that block everything else
│   ├── 01-auth-identity-lifecycle-hardening.md
│   ├── 02-dashboard-viewmodel-decomposition.md
│   ├── 03-unified-error-surface.md
│   └── 04-request-coalescing-and-cancellation-hygiene.md
└── dev-tooling/                     — lint, skills, build scripts
    ├── 13-swiftlint-custom-rule-ledger.md
    ├── 14-audit-and-fix-skill.md
    └── 15-build-and-xcodegen-tooling.md
```

## How to use

1. Pick one plan. Each is independent unless it lists explicit prerequisites.
2. Follow the "Implementation steps" in order. Each step has **Files**, **Changes**, and **Tests**.
3. Check off the "Done criteria" before claiming completion.

## Suggested order

1. [00-claude-md-improvements.md](00-claude-md-improvements.md) — ship first; everything else benefits.
2. [critical-fixes/01-auth-identity-lifecycle-hardening.md](critical-fixes/01-auth-identity-lifecycle-hardening.md) — the single biggest risk surface in the app.
3. [critical-fixes/03-unified-error-surface.md](critical-fixes/03-unified-error-surface.md) — kills the "silent failure" bug class at the source.
4. [critical-fixes/04-request-coalescing-and-cancellation-hygiene.md](critical-fixes/04-request-coalescing-and-cancellation-hygiene.md) — freezes the race-condition bug family.
5. [critical-fixes/02-dashboard-viewmodel-decomposition.md](critical-fixes/02-dashboard-viewmodel-decomposition.md) — big refactor; do after 01/03/04 so decomposition lands on clean foundations.
6. [dev-tooling/13-swiftlint-custom-rule-ledger.md](dev-tooling/13-swiftlint-custom-rule-ledger.md) — freezes recurring bug classes in CI; complements 00.
7. [dev-tooling/15-build-and-xcodegen-tooling.md](dev-tooling/15-build-and-xcodegen-tooling.md) — compact build output, auto-xcodegen, metadata lint.
8. [dev-tooling/14-audit-and-fix-skill.md](dev-tooling/14-audit-and-fix-skill.md) — codify the "ultrathink audit" ritual.

## Conventions

- Absolute paths relative to the repo root (e.g., `PullRequestPilot/Features/...`).
- Tests in `PullRequestPilotTests/` mirroring source layout. Swift Testing (`@Suite`/`@Test`).
- Every plan runs `make build` (zero warnings) and `make test` (all green) before done.
- Any new/deleted Swift file requires `xcodegen generate` before building (plan 15 automates this).
