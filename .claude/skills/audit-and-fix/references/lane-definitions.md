# Lane definitions

Each sub-agent receives exactly one of these definitions plus the finding schema and a pointer to CLAUDE.md.

The **scope** / **non-scope** split matters: overlapping lanes produce duplicate findings that the synthesizer then has to dedupe. Keep lanes tight.

---

## Lane: domain

**Scope:**
- `PullRequestPilot/Domain/Models/**`
- Pure data types, value semantics, Equatable/Hashable correctness.
- Initialiser preconditions, derived-property correctness.

**Non-scope:**
- No ViewModel behaviour (that's `features`).
- No networking DTOs (that's `infrastructure`).
- No tests (that's `tests`).

**What counts as a bug here:**
- `Dictionary(uniqueKeysWithValues:)` on data that can collide (shipped crash pattern).
- Force-unwrap (`!`, `try!`, `fatalError`) anywhere.
- Non-`Sendable` types that cross actor boundaries.
- `Date` arithmetic that assumes monotonic clocks.
- Missing `Equatable`/`Hashable` on types used as `ForEach` identifiers.

---

## Lane: features

**Scope:**
- `PullRequestPilot/Features/**`
- ViewModels, Views, navigation.
- `@MainActor` correctness, `@Observable` wiring.
- Task lifecycle in ViewModels.

**Non-scope:**
- Pure data shape (→ `domain`).
- Networking (→ `infrastructure`).
- Cross-cutting cancellation/Sendable issues → `concurrency` will catch those; only flag here if feature-local.

**What counts as a bug here:**
- Classes spawning `Task`s without `deinit` cancelling them.
- `NotificationCenter` observers without paired removal.
- `@Observable` property backed by `UserDefaults` without a mirror.
- `Task { await … }` inside `Binding.set` (first-click snap-back).
- `disabled(...)` bound to a value mutated in the same tick.
- Views carrying non-derived state (state belongs in ViewModels).
- `UserDefaults.standard` used anywhere outside AppState.
- Silent `try?` on load/decode/migrate paths.

---

## Lane: infrastructure

**Scope:**
- `PullRequestPilot/Infrastructure/**`
- GitHub client, Keychain, persistence stores, avatar, local repository service, networking.

**Non-scope:**
- UI or ViewModel code (→ `features`).
- Widget shared types in `Shared/` (flag these as `persistence` or `dependency-injection` only if they touch storage).

**What counts as a bug here:**
- HTTP error codes not classified before JSON decoding (403/429/5xx falling into "invalid response").
- `URLError.cancelled` surfaced as a user-visible error instead of being rethrown as `CancellationError`.
- `@unchecked Sendable` without a lock or actor.
- Static `DateFormatter` / `ISO8601DateFormatter` without synchronisation.
- Keychain reads on every API call (causes permission prompts).
- `repeat … while nextCursor != nil` without a page cap.
- Empty-string cursor treated as non-nil.
- Check-run dedupe by `name` alone instead of `(name, workflowRunID)`.
- Security-scoped `startAccessingSecurityScopedResource()` without a paired `stop` in the same scope.
- Page-local event IDs used as SwiftUI `ForEach` IDs across pages.

---

## Lane: tests

**Scope:**
- `PullRequestPilotTests/**`
- Test correctness, coverage of new public API, isolation.

**Non-scope:**
- Production code changes (those come from other lanes).

**What counts as a bug here:**
- `Task.sleep` used as synchronisation (flaky under parallel runner).
- Force-unwrap `!` in tests (should be `try #require`).
- `UserDefaults.standard` (should be `UserDefaults(suiteName:)`).
- `MockGitHubClient` or similar as `@unchecked Sendable` instead of actor-backed.
- Missing test for a recently-added public ViewModel method (check last 10 commits for new API).
- Tests asserting against only success path (no error-path coverage).
- Tests that assume a non-empty default `ViewsStore` (post-change, `defaultViews` is empty).

---

## Lane: concurrency

**Scope (cross-cutting):**
- Sendable conformance correctness across the codebase.
- Actor isolation, `@MainActor` placement.
- Cancellation propagation.
- Task lifecycle (deinit, idempotency of `start*`).
- Concurrent cache invalidation (TOCTOU).

**Non-scope:**
- Feature-local `Task` lifecycle that a `features` agent will find (avoid double-report).
- Keep this lane for issues that span modules.

**What counts as a bug here:**
- Generic `catch` swallowing `CancellationError` as a permanent failure.
- `try? await Task.sleep` in long-lived loops.
- `startAutoRefresh` that is not idempotent.
- Concurrent `refreshAll` that doesn't coalesce on a `Task` handle.
- Tight-loop fallback when the work set is empty.
- `get-then-invalidate` caches without a generation counter or actor.

---

## Lane: appstore

**Scope:**
- `metadata/appstore.yml`
- Entitlements files, `Info.plist` (via `project.yml`).
- Privacy manifest.
- Sandbox-violating code patterns anywhere in the repo.

**Non-scope:**
- Code quality (other lanes).

**What counts as a bug here:**
- `Process()`, `NSTask`, `/bin/sh`, `dlopen`, `NSBundle.load()` — instant rejection.
- Hardcoded paths outside sandbox (`~/`, `/tmp`, `/usr/local`).
- Private/undocumented APIs, `performSelector` on private selectors.
- `setenv`/`getenv` outside `#if DEBUG`.
- Entitlement added without justification.
- Subtitle contains forbidden terms (`macOS`, `Mac`, `iOS`, `GitHub`, `Apple`, …) or exceeds 30 chars.
- Version not monotonic in `metadata/appstore.yml`.
- Privacy manifest missing a collected data type that the code actually collects.
- `CURRENT_PROJECT_VERSION` not bumped for a new upload (flag if build script shows drift).
- Widget bundle ID not prefixed with main bundle ID.
- Widget entitlements exceeding main app entitlements.

---

## Lane: performance

**Scope:**
- Hot paths: auto-refresh loop, GraphQL pagination, list rendering.
- Startup allocation.
- Retain cycles, unbounded caches.

**Non-scope:**
- Micro-optimisations without a user-visible impact.
- Algorithmic rewrites without benchmark evidence.

**What counts as a bug here:**
- Work happening on every `body` recomputation (should be `.task` / `.onAppear`).
- Unbounded caches (no eviction policy).
- Timers firing when the window is hidden / app is inactive.
- Large image decode on the main thread.
- Full refresh on every keystroke instead of debounced.
- Retain cycle in `Task { [self] … }` closures.

---

## Lane: ux

**Scope:**
- Error surface completeness (every thrown error reaches a banner/toast).
- Empty-state views.
- Accessibility labels on icon-only buttons.
- Keyboard navigation on primary surfaces.
- Visible in the Menu Bar / Dock menu / Window menu.

**Non-scope:**
- Visual polish that doesn't affect usability.
- Layout that depends on user preference.

**What counts as a bug here:**
- A `throw` path that dead-ends (caller logs or swallows).
- `bare catch { }` or `catch { return [] }`.
- Empty state renders as blank screen with no explanation.
- Icon-only button without `accessibilityLabel`.
- Primary action not reachable without a mouse.
- Reactive state that doesn't reach the UI (the `@Observable` + `UserDefaults` mirror bug).
- Destructive action without confirmation (e.g., "Delete View").
