# 03 — Unified error surface (banners + toasts)

## Goal

Give every user-visible failure a **first-class place to appear**. Today errors are either silently swallowed (`try?`), hardcoded as a per-view `errorMessage` string, or surfaced as wrong error messages (403 reported as "invalid search qualifier"). Adding new features keeps paying the silent-failure tax.

## Evidence

- Silent failures flagged in 4+ audits: `ViewsStore` returns `[]` on decode fail wiping saved views; `WidgetData` swallow; `GitDirectoriesStore` silent drop; `parseRetryAfter` silent ignore; hide-reviewed filter falls back silently.
- HTTP 403/5xx fall through to JSON decode (c36d86ce, dfe072ff), producing misleading UI.
- User sees cryptic permission errors after bookmark prune (144aa080) — "Stale-bookmark user feedback" is an open backlog item.
- Every major bug class in this codebase has a "the user would have known sooner" sub-story.

## Current state

- Each ViewModel holds its own `errorMessage: String?`.
- `PullRequestPilot/Infrastructure/GitHub/ErrorNetworkCheck.swift` lives in Infrastructure but is imported by Features (layer violation flagged in 35bfd988 B9).
- No app-global notification/banner system. Users only see errors when they visit the exact view that failed.

## Target design

Three tiers of surface, one type system.

### 1. `AppEvent` — the cross-cutting event type

```swift
enum AppEvent: Sendable, Identifiable {
    case error(AppError)
    case info(String, action: EventAction? = nil)
    case warning(String, action: EventAction? = nil)

    var id: UUID // stable across lifecycle
    var level: Level
    var autoDismissAfter: Duration? // nil = persist until user dismisses
}

enum AppError: LocalizedError, Sendable {
    case rateLimited(resetAt: Date)
    case unauthorized
    case tokenSaveFailed(underlying: String)
    case decodeCorruption(subsystem: String)           // ViewsStore, WidgetData, GitDirs
    case bookmarkPruned(count: Int)                    // N directories lost sandbox access
    case viewerIdentityUnavailable                     // hide-reviewed filter disabled
    case network(underlying: String)                   // generic fallback
    // ... extend as needed
}
```

### 2. `EventCenter` — `@MainActor` bus

```swift
@MainActor
@Observable
final class EventCenter {
    private(set) var events: [AppEvent] = []
    func post(_ event: AppEvent)
    func dismiss(_ id: UUID)
    func dismissAll(of: AppError)
}
```

One per `AppState`. Every subsystem gets injected.

### 3. Three rendering surfaces

- **Toast bar** at the top of the main window — auto-dismiss for transient info; user-dismissible for warnings.
- **Inline banner** in views that are directly impacted (e.g., hide-reviewed disabled shows the banner in the PR list).
- **Settings diagnostic panel** — a permanent log of the last 50 events for support/debugging.

All three read from `EventCenter`, filtered by relevance.

### 4. Classifier at the network boundary

`GitHubClient` classifies HTTP responses **before** JSON decoding:

```swift
func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AppError.network(...) }
    switch http.statusCode {
    case 200...299: return try decode(data)
    case 401: identity.invalidate(.unauthorized); throw AppError.unauthorized
    case 403 where isRateLimit(http): throw AppError.rateLimited(resetAt: parseReset(http))
    case 429: throw AppError.rateLimited(resetAt: parseRetryAfter(http))
    case 500...599: throw AppError.network(...)
    default: throw AppError.network(...)
    }
}
```

## Implementation steps

### Step 1 — Create `AppEvent` + `EventCenter`

**Files**
- New: `PullRequestPilot/Domain/Models/AppEvent.swift`
- New: `PullRequestPilot/App/EventCenter.swift`
- `PullRequestPilot/App/AppState.swift`

**Changes**
- Instantiate `EventCenter` in `AppState`. Inject into every ViewModel.
- `AppError` conforms to `LocalizedError` with user-facing `errorDescription`.

**Tests**
- `EventCenter.post` → stored, observable.
- Auto-dismiss duration expires and removes event.
- `dismissAll(of:)` removes only matching errors.

### Step 2 — Render surfaces

**Files**
- New: `PullRequestPilot/Features/Shared/EventBannerView.swift`
- New: `PullRequestPilot/Features/Shared/ToastOverlay.swift`
- `PullRequestPilot/App/RootContentView.swift`
- `PullRequestPilot/Features/Settings/SettingsView.swift`

**Changes**
- Toast overlay at top of `RootContentView`.
- Inline banner component that takes an `AppError` filter.
- Settings "Diagnostics" section lists last 50 events.

**Tests**
- UI tests (if XCUITest infra exists, otherwise skip): toast renders, dismiss clears it.
- Snapshot tests for banner layout.

### Step 3 — Migrate silent failures

One PR per subsystem. For each:

**Files**
- `PullRequestPilot/Infrastructure/Persistence/ViewsStore.swift`
- `PullRequestPilot/Infrastructure/Persistence/GitDirectoriesStore.swift`
- `Shared/WidgetData.swift`

**Changes**
- Every `catch` that previously returned `[]` or `nil` now also calls `events.post(.error(.decodeCorruption(subsystem:)))`.
- `load()` logs via `os.Logger` at `.error` with the raw decode error.
- Corrupted data is **not** overwritten until user acknowledges (prevents accidental wipe). Keep a `.corrupted-YYYY-MM-DD.json` backup copy.

**Tests**
- Corrupt the stored JSON → `load()` returns empty + event posted + backup created.
- Running the app with a partial save → same.

### Step 4 — Migrate per-view error state

**Files**
- `PullRequestPilot/Features/Dashboard/*.swift`
- `PullRequestPilot/Features/PRDetail/PRDetailViewModel.swift`

**Changes**
- Replace `errorMessage: String?` with a call to `events.post(.error(...))`.
- Keep a local `state: .idle | .loading | .loaded | .failed` but don't hold error strings.

**Tests**
- Failed fetch → event posted, state `.failed`.
- Retry → event dismissed on success.

### Step 5 — HTTP classifier

**Files**
- `PullRequestPilot/Infrastructure/GitHub/GitHubClient.swift`
- `PullRequestPilot/Infrastructure/GitHub/ErrorNetworkCheck.swift` — delete (absorbed into the classifier).

**Changes**
- Classifier per the target design.
- 403 rate-limit parsing: check `X-RateLimit-Remaining: 0` + `X-RateLimit-Reset`.
- 429 parsing: `Retry-After` accepts both seconds and HTTP-date.

**Tests**
- Mock 403 with rate headers → `AppError.rateLimited` with correct reset.
- Mock 429 with `Retry-After: 120` → correct date.
- Mock 429 with `Retry-After: Thu, 20 Feb 2026 00:00:00 GMT` → correct date.
- Mock 500 → `AppError.network`, not `.decodeCorruption`.

### Step 6 — Bookmark-prune event

**Files**
- `PullRequestPilot/Infrastructure/LocalRepository/*`

**Changes**
- When `GitDirectoriesStore.load()` drops directories due to expired bookmarks, post `AppError.bookmarkPruned(count:)`.
- See plan 10 for the full recovery UX.

## Risks

- **Toast fatigue** — every subsystem suddenly shouting. Ship with a max-rate throttle and dedupe by `AppError` case.
- **Breaking the App Store rule "no cryptic errors"** — test with real invalid tokens, broken networks, corrupted files before shipping. Every error needs a user-usable `errorDescription`.

## Out of scope

- Designing the full diagnostic panel UX (settings diagnostic can be a plain list in this plan).
- Identity lifecycle (plan 01).

## Done criteria

- [ ] `EventCenter` wired through `AppState`, injected everywhere.
- [ ] No `try?` or bare `catch {}` remains in `Features/` or `Infrastructure/` except with a logged+posted event.
- [ ] `ErrorNetworkCheck.swift` deleted.
- [ ] Toast bar + inline banner rendered in the main window.
- [ ] Corruption backup file is written before first load that returns empty.
- [ ] `make build` clean, `make test` green.
