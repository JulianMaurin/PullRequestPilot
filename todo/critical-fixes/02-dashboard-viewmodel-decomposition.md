# 02 — DashboardViewModel decomposition

## Goal

Break `DashboardViewModel` (629 lines, ~10 responsibilities) into single-responsibility collaborators. Every audit session flags this as a god class and every new bug in the dashboard hides behind this monolith.

## Evidence

- Flagged by audits in a2a471bf, f5f9eb04 (A3), d27f2f56 — "DashboardViewModel is a god object".
- Missing `deinit` leaked NotificationCenter observer and stranded refresh tasks (771b7346).
- Concurrent `refreshAll` overlap (ef795a23 H3), badge phantom IDs (3e2c242b), filter bypass on cancellation (e2c95ad3), notification dedup across views (ef795a23) — all live in the same class.
- The recent commit history shows three consecutive fixes to this file; each ripples through unrelated areas.

## Current state

`PullRequestPilot/Features/Dashboard/DashboardViewModel.swift` (629 LOC). Responsibilities today:

1. Fetching PRs per view (GraphQL query building, pagination, cancellation).
2. Auto-refresh timing (start/stop, backoff).
3. Managing the set of `DashboardView` tabs (selection, persistence).
4. Reviewer-login caching (migrating out in plan 01).
5. Hide-reviewed filtering.
6. Per-view error state.
7. Status-bar badge aggregation.
8. Notification emission on new PRs.
9. NotificationCenter observer for `NSWorkspace.didWakeNotification`.
10. Widget data update (writing to app group container).

## Target design

Split into four `@MainActor` classes + two actors. The ViewModel orchestrates; it does not implement.

```
DashboardViewModel (orchestrator, <200 LOC)
 ├── ViewRegistry            — holds DashboardView[] + selection, @Observable
 ├── PRFetcher (actor)       — per-view GraphQL fetch, cursor state, cancellation
 ├── AutoRefreshScheduler    — start/stop, backoff, idle-detection
 ├── BadgeCoordinator        — badge count per view, "new since last visit" tracking
 ├── NotificationDispatcher  — new-PR detection, dedup across concurrent refreshes
 └── WidgetSync              — writes WidgetData to app group on state change
```

Dependencies:
- `PRFetcher` depends on `GitHubClient` + `IdentityActor` (plan 01).
- `BadgeCoordinator` depends on `ViewRegistry` (to know which view is selected) and persists last-seen IDs per view.
- `NotificationDispatcher` depends on `UNUserNotificationCenter` + `BadgeCoordinator` (to know if the view is actively shown).
- `WidgetSync` depends on `ViewRegistry` + per-view `PRFetcher` state.

Each collaborator is owned by `AppState` and passed into `DashboardViewModel`'s init. The view model's job becomes: route user actions (select view, refresh, toggle hide-reviewed) to the right collaborator.

## Implementation steps

### Step 1 — Extract `ViewRegistry`

**Files**
- New: `PullRequestPilot/Features/Dashboard/ViewRegistry.swift`
- `PullRequestPilot/Features/Dashboard/DashboardViewModel.swift`

**Changes**
- `ViewRegistry` owns `views: [DashboardView]`, `selectedViewID: DashboardView.ID?`, `addView`, `removeView`, `reorderViews`, `persistSelection`.
- ViewModel holds a reference; its `@Observable` properties come from the registry.

**Tests**
- Round-trip views to `ViewsStore`.
- Selection persisted across relaunch.

### Step 2 — Extract `PRFetcher` as an actor

**Files**
- New: `PullRequestPilot/Features/Dashboard/PRFetcher.swift`

**Changes**
- `actor PRFetcher { func fetch(view: DashboardView, cursor: String?, maxPages: Int = 20) async throws -> PRPage }`.
- Handles cursor dedup, maxPages guard, cancellation rethrow.
- Coalesces: a second `fetch(view:)` call for a view that's already fetching joins the first's `Task` (see plan 04 request coalescing).

**Tests**
- Cancellation during fetch → CancellationError surfaces, state unchanged.
- Two concurrent calls → single network call, same result.
- maxPages guard trips on malformed cursor.

### Step 3 — Extract `AutoRefreshScheduler`

**Files**
- New: `PullRequestPilot/Features/Dashboard/AutoRefreshScheduler.swift`

**Changes**
- Idempotent `start()`; `stop()` cancels the loop.
- Backoff on consecutive failures (exponential, capped at 5 min).
- No-op when view set is empty (fixes 5s tight loop).
- Takes a closure `() async -> Void` to invoke each tick.

**Tests**
- Empty view set → no fetches.
- Failure streak → exponential backoff.
- `start()` twice → still only one loop.
- `stop()` mid-tick → cancellation propagates.

### Step 4 — Extract `BadgeCoordinator`

**Files**
- New: `PullRequestPilot/Features/Dashboard/BadgeCoordinator.swift`

**Changes**
- Per-view "last seen PR IDs" set, persisted to UserDefaults (app-group suite, injected).
- `newCount(for viewID:) -> Int` — delta since last visit.
- `markViewVisited(_ viewID:)` — clears the delta for that view only.
- `totalBadge()` — sum across views, respecting per-view "badge enabled" toggle.

**Tests**
- New PR in view A appears in badge; visiting A clears only A.
- Phantom IDs (PR merged/closed) removed from "last seen" set.
- Badge respects per-view toggle.

### Step 5 — Extract `NotificationDispatcher`

**Files**
- New: `PullRequestPilot/Features/Dashboard/NotificationDispatcher.swift` (rename existing `NotificationService.swift` content into this).

**Changes**
- Subscribes to new-PR events from `BadgeCoordinator`.
- Dedupes: same PR ID across concurrent refreshes produces one notification (use an in-memory `Set<PRID>` with TTL).
- Suppresses notification if the view containing the PR is currently selected and visible.
- Tap handler routes to the view via `pullrequestpilot://view/<viewID>?pr=<prID>` URL.

**Tests**
- Same PR across two concurrent refreshes → one notification.
- PR in selected-and-visible view → no notification.
- Tap deep-link builds correctly.

### Step 6 — Extract `WidgetSync`

**Files**
- New: `PullRequestPilot/Features/Dashboard/WidgetSync.swift`

**Changes**
- Listens to `ViewRegistry` + `PRFetcher` state. On change, writes `WidgetData` to app group.
- Includes `lastUpdated: Date` for the staleness indicator (plan 10).
- Throttles writes to once per 500ms to avoid widget flood.

**Tests**
- State change → single write to app group.
- Rapid changes → throttled.
- Sign-out → writes empty `WidgetData`.

### Step 7 — Slim `DashboardViewModel`

**Files**
- `PullRequestPilot/Features/Dashboard/DashboardViewModel.swift`

**Changes**
- Delete all code moved into collaborators.
- Only keep: init (wires collaborators), `selectView(_:)`, `refresh(_:)`, `refreshAll()`, `toggleHideReviewed()`.
- Add `deinit { scheduler.stop(); observers.forEach { ... } }`.

**Tests**
- Smoke: full flow still works (fetch, switch view, badge updates, notification fires).
- Memory: ARC release deinit is called when the view model is freed.

## Risks

- **Over-splitting** — resist creating a 7th or 8th collaborator. Stop at the list above.
- **Test re-write** — existing `DashboardViewModelTests` will need to move/rename. Use this as an opportunity to improve coverage, not a blocker.
- **Observation boundaries** — SwiftUI views bind to `@Observable` state; make sure the collaborators that expose observable state are `@Observable` and `@MainActor`, while actors remain actor-isolated and expose `AsyncSequence` for subscribers.

## Out of scope

- Identity / token state (plan 01).
- Request coalescing across multiple viewmodels (plan 04).

## Done criteria

- [ ] `DashboardViewModel.swift` under 250 LOC.
- [ ] Six collaborators created, each under 200 LOC.
- [ ] All existing dashboard tests green.
- [ ] `deinit` tested for `DashboardViewModel` and any Task-owning collaborator.
- [ ] No `@unchecked Sendable` anywhere in `Features/Dashboard/`.
- [ ] No feature cross-import (Dashboard → Settings, etc.).
- [ ] `make build` clean.
