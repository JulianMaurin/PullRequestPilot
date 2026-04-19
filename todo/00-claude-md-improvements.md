# CLAUDE.md improvements

Patches to the project's `CLAUDE.md` that, if applied, would have prevented a large fraction of the bugs and workflow friction observed across 29 sessions. Apply each patch by inserting under the indicated section.

## Context

The current CLAUDE.md already encodes many lessons (force-unwraps forbidden, `URLError.cancelled` → `CancellationError`, DerivedData ritual, xcodegen after file add). Yet sessions show the same bug classes recurring in *new* code, and the same friction repeating every session. The gap is either coverage (missing rule) or teeth (rule exists but isn't operationalized into test/lint).

Priority order matches the patches below. Apply the first five at minimum.

---

## Patch 1 — Expand "Concurrency Pitfalls" section

**Current text** (~4 lines) is too thin. Replace with:

```markdown
## Concurrency Pitfalls

Every pitfall below has shipped in this codebase at least once. The fix is always the same: treat concurrency as a boundary problem, not a local one.

### Cancellation
- **`URLError.cancelled` must be caught and rethrown as `CancellationError` in the network layer** — otherwise it surfaces as a user-visible error during normal operation (auto-refresh restart, view switch).
- **Generic `catch` in an async function must rethrow `CancellationError`** — do not treat it as a permanent failure. Bug: `fetchViewerLoginIfNeeded` flipped `viewerLoginFetchFailed = true` on cancellation, permanently disabling the hide-reviewed filter.
- **`try? await Task.sleep` silently swallows cancellation** — prefer `try await Task.sleep` so the outer task exits promptly.

### State that crosses tasks
- **`@unchecked Sendable` is almost always wrong.** If you need it, add an `NSLock` (or better, an actor). Bugs: `ViewsStore`, `GitDirectoriesStore`, `DateFormatter` statics all had real data races.
- **Static formatters are shared state.** `ISO8601DateFormatter` / `DateFormatter` as file-level `let` is not thread-safe. Wrap in a lock or make them per-thread.
- **TOCTOU on caches.** Any `get-then-invalidate` pair (e.g., `TokenCache`) must serialize through a generation counter or actor. Bug: keychain read on one task revived a token another task had just invalidated.

### Auto-refresh / idempotency
- **`startAutoRefresh()` must be idempotent** — no-op if already running. Cancel in-flight work via `stopAutoRefresh()` first.
- **Concurrent `refreshAll` calls must dedupe.** Coalesce on a `Task` handle; a second caller joins the first.
- **No tight loops when idle.** If the work set is empty, sleep a long interval; do not spin every 5s.

### Observation / SwiftUI
- **`@Observable` does not track computed properties backed by external storage** (e.g., `UserDefaults`). Mirror into a stored property and update on external change.
- **`Task { await ... }` inside a `Binding.set` causes first-click snap-back.** Use `.task(id:)` or move the mutation off the binding.
- **`disabled(...)` changing mid-frame can swallow the concurrent state change.** Don't bind `disabled` to values you also mutate in the same tick.
```

---

## Patch 2 — Add "Silent Failures Forbidden" section

Insert under "Error Handling":

```markdown
### Silent failures are forbidden

The recurring bug pattern in this codebase is `try?` + empty return, which destroys user data. Rules:

- **No `try?` without a log** on any `load`, `decode`, or `migrate` path. If decode fails, surface an error to the user (see Unified Error Surface). Losing saved views, directories, or widget data without telling the user is an App Review risk and a trust breaker.
- **No bare `catch {}` or `catch { return [] }`.** If you can't recover, rethrow; if you must swallow, log with `os.Logger` at `.error` and emit a user-visible toast.
- **HTTP error codes must be classified before JSON decoding.** 403/429/5xx should short-circuit into typed errors, not fall through to "invalid response" when the body isn't JSON.
- **Cursor-paginated loops need a `maxPages` guard.** `while cursor != nil` without a cap has shipped twice as an infinite loop.
```

---

## Patch 3 — Tighten "Force-unwraps forbidden"

Replace the single bullet with:

```markdown
### Force-unwraps forbidden (production story)

`!`, `try!`, `fatalError()`, and `preconditionFailure()` are instant crashes.

**This has already cost the project one production crash**: `Dictionary(uniqueKeysWithValues:)` on PR `headRefName` blew up when two PRs shared a branch name (force-push, forks, reopened PRs). Users on v1.2.1 saw the app die on launch.

Rules:
- **Never `!` on optionals in production code paths.** Use `guard let`/`if let` and surface an error.
- **Never `try!` or `fatalError` in production.** `preconditionFailure` in a closure that's invoked lazily (URL constants) is the same bug.
- **Never `Dictionary(uniqueKeysWithValues:)` on API data.** Use `Dictionary(_, uniquingKeysWith:)` or `reduce(into:)`.
- **Never force-unwrap in tests either.** Use `try #require(...)` — a crash in a test means you can't see what failed.
- **Every `Date` math path must handle clock skew.** Future-dated timestamps (server clock drift, timezone bugs) have crashed the app in real data.

The rule "find it or file an issue" from the Quality Standards section does **not** excuse `!`. Fix the Optional at its source.
```

---

## Patch 4 — Add "Prefer declarative SwiftUI over AppKit observers"

Insert as a new subsection under "Code Conventions":

```markdown
### Prefer declarative SwiftUI over AppKit observers

When adding menu items, window chrome, or lifecycle reactions, try SwiftUI scene modifiers **before** reaching for `NSWindowWillUpdateNotification`, KVO, or `NSApp.mainMenu` mutations.

Observed pattern: Claude has built `NSWindowWillUpdateNotification` observers to fix an empty Window menu, then the fix turned out to be a one-line `.navigationTitle("PR Views")`. If your first instinct is an observer, re-check the declarative API surface.

Applies to: window title, dock menu, command menus, status bar item appearance, menu bar extras.
```

---

## Patch 5 — Add "Trust `make build` over Xcode diagnostics"

Insert under "Build & Run":

```markdown
### Trust `make build`, not SourceKit / Xcode diagnostics

SourceKit's index frequently shows errors that do not reproduce on the command line — especially with `@Observable`, cross-target types (Shared/), and XcodeGen regenerations. **Do not trust Xcode's in-editor errors.** Trust `make build` output only.

If errors persist on CLI: `rm -rf ~/Library/Developer/Xcode/DerivedData/PullRequestPilot-*` and rebuild.

Do **not** start refactoring to "fix" an error that only appears in Xcode's index.
```

---

## Patch 6 — Encode the `UserDefaults.standard` ban

Insert under "File Guidelines":

```markdown
### `UserDefaults.standard` is banned outside AppState

Classes that accept an injected `UserDefaults` must use the injected value. Reading `UserDefaults.standard` anywhere in `Features/` or `Infrastructure/` bypasses DI, breaks tests, and loses the app-group container in widget contexts.

Bug history: auto-refresh toggle and AppState launched with hardcoded `.standard`; a widget reading the wrong suite would see zero data. This is enforced by lint rule `no_standard_userdefaults` (see `.swiftlint.yml`).
```

---

## Patch 7 — Add pagination/cursor hygiene rules

Insert under "Key Technical Decisions" → GraphQL:

```markdown
### GraphQL pagination safety

- **Every `repeat ... while nextCursor != nil` loop needs `let maxPages = 20`.** Unbounded paging has shipped twice as an infinite loop.
- **Event IDs reset per page** — GitHub's timeline returns indices that are page-local. If you synthesize an ID from the index, include the cursor to avoid collisions in SwiftUI `ForEach`. The canonical bug: page-2 timeline events silently vanished because `ForEach(id:)` deduped against page-1 IDs.
- **Empty-string cursor is not the same as nil.** Filter `""` out before looping.
- **Stale cursors across query edits** — if the user edits the search query, reset the cursor. Reusing the previous query's cursor returns nonsense.
- **Check runs must dedupe by `(name, workflowRunID)` keeping the latest attempt.** Deduping by `name` alone hides failed re-runs.
```

---

## Patch 8 — Add "security-scoped bookmarks" RAII rule

Insert under "File Guidelines":

```markdown
### Security-scoped bookmarks

Every `url.startAccessingSecurityScopedResource()` must be paired with `url.stopAccessingSecurityScopedResource()` in the same scope. Missing stops leak access counts and eventually break sandbox reads.

Use the `LocalRepositoryService.withAccess(_:)` helper (see `product-roadmap/ux-improvements/10-stale-resource-recovery-ux.md`). Do not call `startAccessing` directly.
```

---

## Patch 9 — Tighten App Store Metadata rules

Replace the existing metadata bullets under "App Review Rules" with:

```markdown
- **Privacy compliance** — if adding any new data collection, add matching `NSPrivacyCollectedDataTypes` in the privacy manifest.
- **No misleading metadata** — bundle display name, category, and descriptions must accurately reflect app functionality.
- **Forbidden terms in subtitle** (App Store rejected twice on this): `macOS`, `Mac`, `iOS`, `iPhone`, `iPad`, `GitHub`, `Apple`, or any other trademarked brand. Test the subtitle with `make metadata-lint` (see `todo/dev-tooling/15-build-and-xcodegen-tooling.md`).
- **Bump `CURRENT_PROJECT_VERSION`** for every archive/upload. App Store Connect rejects duplicate build numbers.
```

---

## Patch 10 — Add "deinit required for Task-owning classes"

Insert under "Swift & Concurrency":

```markdown
- **Classes that spawn `Task`s must implement `deinit`** and cancel them. Classes that observe `NotificationCenter` must remove observers. Bug history: `DashboardViewModel` leaked an observer and stranded refresh tasks; auto-refresh kept firing after the view was gone.
```

---

## Patch 11 — Add audit workflow section

New top-level section:

```markdown
## Audit & Fix Workflow

For whole-codebase audits, use the `/audit-and-fix` skill (see `todo/dev-tooling/14-audit-and-fix-skill.md`), not ad-hoc "ultrathink" prompts.

The skill:
1. Dispatches parallel sub-agents across layers (Domain, Features, Infrastructure, Tests, App Store compliance, Concurrency, Performance).
2. Collects findings into a structured ledger (TodoWrite-backed) — no finding is silently dropped.
3. Executes fixes directly; does not propose/approve.
4. Groups the resulting diff into one commit per bug category, with changelog-ready messages.

The user's canonical prompt "don't follow recommendation, instead ultrathink to fix all" is the skill's default mode.
```

---

## Patch 12 — Tests: `Task.sleep` is banned

Insert under "Testing":

```markdown
- **No `Task.sleep` as synchronization in tests.** Use `waitForLoad()`-style helpers that check for the target state. Sleep-based waits are flaky under Swift Testing's parallel runner. Enforced by lint.
- **`MockGitHubClient` must be actor-backed, not `@unchecked Sendable`.** Mock state is read/written concurrently by parallel tests; shared mutable state without isolation produces intermittent failures.
```

---

## Patch 13 — Commit shaping

Insert under "Doing tasks":

```markdown
### Commits for the release changelog

When you finish a batch of fixes (especially from an audit), split them into one commit per user-visible category so the next release's changelog writes itself. Good categories: `Fix <bug>`, `Add <feature>`, `Refactor <subsystem>`, `Update <dependency>`. Bad: `Apply review feedback`, `Bugfixes`.

Use the `/reshape-commits` helper (`todo/dev-tooling/15-build-and-xcodegen-tooling.md`) to split staged changes by category.
```

---

## Summary of expected impact

If patches 1-4 alone ship, the following recurring bug classes should stop appearing:

| Bug class | Root cause addressed | Seen in sessions |
|---|---|---|
| `CancellationError` → UI error | Patch 1 | 3+ |
| `@unchecked Sendable` data race | Patch 1 | 5+ |
| Silent decode failure wipes state | Patch 2 | 4+ |
| Force-unwrap prod crash | Patch 3 | 1 shipped, 3+ found | 
| Unbounded cursor loop | Patch 7 | 2 |
| Page-ID collision in `ForEach` | Patch 7 | 2 |
| UserDefaults DI bypass | Patch 6 | 2 |
| AppKit observer when SwiftUI sufficed | Patch 4 | 2 |

Patches 11-13 are workflow — they pay back every session, not per-bug.
