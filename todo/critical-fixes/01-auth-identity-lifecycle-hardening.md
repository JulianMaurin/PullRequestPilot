# 01 — Auth / identity lifecycle hardening

## Goal

Make token state and viewer identity **atomic and consistent** across any swap, invalidation, or concurrent fetch. Eliminate the class of bugs where "hide reviewed" filters by the wrong user, stale tokens get resurrected from Keychain, or a failed save leaves an inconsistent in-memory token.

## Evidence (why this is Tier 1)

Across the April audits, the same subsystem produced three CRITICAL findings:

- **Token saved before validation** (f5f9eb04) — an invalid token is persisted, then the validation fails, and the app carries a broken token.
- **TokenCache TOCTOU** (ef795a23 C1) — `getToken()` on task A reads a token after task B called `invalidate()`; tested value is a revived ghost.
- **Viewer login cached against previous token** (802d1bc9 CRITICAL 1) — user swaps tokens; "reviewed by me" filters against the *previous* account's login, silently showing the wrong PRs.
- **`fetchViewerLoginIfNeeded` race** (26bfc843) — flag says "already fetching" but login is still `nil`; the caller returns without filtering.
- **Cancellation mistyped as permanent failure** (e2c95ad3) — `fetchViewerLoginIfNeeded` caught `CancellationError` and set `viewerLoginFetchFailed = true`, disabling the filter forever.
- **Keychain save non-atomic** (d27f2f56) — `SecItemDelete` + `SecItemAdd` leaves a crash window where Keychain has no token and cache has no token.

The commit at `cf88276` on `main` (Fix hide-reviewed filter bypassed after cancelled viewer login fetch) shows this surface is still actively bleeding.

## Current state

- `PullRequestPilot/Infrastructure/Keychain/KeychainService.swift` — persists token via `SecItemDelete` + `SecItemAdd`.
- `PullRequestPilot/Infrastructure/Keychain/TokenCache.swift` — in-memory cache; has an `NSLock` but TOCTOU hole between read and invalidate.
- `PullRequestPilot/Features/Dashboard/DashboardViewModel.swift` — owns `viewerLogin`, `fetchViewerLoginIfNeeded`, `isFetchingViewer`, `viewerLoginFetchFailed`. ~10 responsibilities already.
- `PullRequestPilot/App/AppState.swift` — composition root; sets up `TokenCache` and `KeychainService`.
- Settings screen calls `saveToken`, validates, then may silently leave inconsistent state.

## Target design

### 1. `IdentityActor` — the single source of truth for `(token, viewerLogin)`

Introduce a `@MainActor`-isolated (or `actor`) class in `PullRequestPilot/Infrastructure/Identity/IdentityActor.swift` that owns:

```swift
actor IdentityActor {
    private(set) var state: IdentityState = .unauthenticated
    private var generation: UInt64 = 0

    enum IdentityState: Sendable {
        case unauthenticated
        case authenticating(token: String, generation: UInt64)
        case authenticated(token: String, viewerLogin: String, generation: UInt64)
        case invalid(reason: AuthInvalidReason, generation: UInt64)
    }

    func swap(to token: String) async throws -> String // returns viewerLogin
    func invalidate(reason: AuthInvalidReason)
    func currentViewerLogin() -> String?
    func token() -> String?
}
```

Semantics:
- Every mutation bumps `generation`. Any observer task captures `generation` at start; if it changed by the time the task wants to commit a decision, the task is a no-op.
- `swap(to:)` runs: validate token → write Keychain atomically → update viewerLogin → transition to `.authenticated`. If any step fails, state is `.invalid(.saveFailed | .invalidToken | .network)` — never a partial state.
- `invalidate(reason:)` unconditionally transitions to `.unauthenticated` and bumps generation. Any in-flight validation becomes a no-op.
- `currentViewerLogin()` returns `nil` unless `state == .authenticated`. Filters that need it must check explicitly.

### 2. Atomic Keychain write

`KeychainService.save(token:)` must be a single `SecItemUpdate` with `kSecAttrSynchronizable=false`, falling back to `SecItemAdd` only when the item doesn't exist. Never `Delete` + `Add`.

### 3. Cancellation discipline

Any `catch` in `IdentityActor` methods:
```swift
catch is CancellationError { throw }
catch let urlError as URLError where urlError.code == .cancelled { throw CancellationError() }
catch { /* transition to .invalid(.network) */ }
```

### 4. Filter code reads `currentViewerLogin()` only

`DashboardViewModel.hideReviewedFilter` and any other consumer must read `currentViewerLogin()` each time it filters. Stale local copies are forbidden.

## Implementation steps

### Step 1 — Create `IdentityActor` and types

**Files**
- New: `PullRequestPilot/Infrastructure/Identity/IdentityActor.swift`
- New: `PullRequestPilot/Domain/Models/IdentityState.swift`

**Changes**
- Implement the actor per the design above. Inject `KeychainService` and `GitHubClient` via init.
- `swap` calls `github.validateToken(_:)` (new method on `GitHubClientProtocol` — returns `viewerLogin`).

**Tests** (`PullRequestPilotTests/Infrastructure/Identity/IdentityActorTests.swift`)
- Happy path: `swap` → `.authenticated`.
- Invalid token: `swap` → `.invalid(.invalidToken)`, Keychain untouched.
- Keychain failure: `swap` → `.invalid(.saveFailed)`, cache cleared.
- Concurrent swaps: second wins, first's observer sees `generation` mismatch and no-ops.
- Cancellation during `swap`: `state` unchanged, `CancellationError` rethrown.
- `invalidate` during `swap`: final state `.unauthenticated`.

### Step 2 — Atomic Keychain write

**Files**
- `PullRequestPilot/Infrastructure/Keychain/KeychainService.swift`

**Changes**
- Replace the `save(token:)` body: try `SecItemUpdate`; on `errSecItemNotFound`, `SecItemAdd`; on any other error, throw.
- Delete the `SecItemDelete` path entirely; use `delete()` only for explicit sign-out.

**Tests**
- Update existing tests; add: save-over-existing succeeds without losing in-flight reads on another thread.

### Step 3 — Retire `TokenCache` TOCTOU

**Files**
- Delete: `PullRequestPilot/Infrastructure/Keychain/TokenCache.swift` (after migration).
- `PullRequestPilot/App/AppState.swift` — replace `TokenCache` wiring with `IdentityActor`.

**Changes**
- All call sites that read the token go through `IdentityActor.token()`.
- Debug `#if DEBUG` env-var token injection moves to `IdentityActor.bootstrap()`.

**Tests**
- Remove TokenCache tests; assert no references remain.

### Step 4 — Migrate `DashboardViewModel.fetchViewerLogin*`

**Files**
- `PullRequestPilot/Features/Dashboard/DashboardViewModel.swift`

**Changes**
- Delete `viewerLogin`, `isFetchingViewer`, `viewerLoginFetchFailed`, `fetchViewerLoginIfNeeded`, any local cache.
- The hide-reviewed filter calls `identity.currentViewerLogin()` each time it filters. If `nil`, the filter shows all PRs **and** surfaces a banner: "Sign in to hide PRs you've already reviewed" (via the Unified Error Surface from plan 03).

**Tests** (`DashboardViewModelTests`)
- Test: swap token, previous user's login is no longer used for filtering.
- Test: cancel viewer-login fetch → filter still works after retry.
- Test: `invalidate(reason: .unauthorized)` → filter shows all PRs and banner visible.

### Step 5 — Settings screen contract

**Files**
- `PullRequestPilot/Features/Settings/SettingsViewModel.swift`

**Changes**
- `saveToken(_:)` awaits `identity.swap(to:)` and surfaces the terminal state.
- On `.invalid(.invalidToken)`: show inline error, don't touch Keychain.
- On `.invalid(.saveFailed)`: show "Keychain write failed — try again" and keep the old token active.

**Tests**
- Invalid token: Keychain not written.
- Save failure: old token still works for dashboard fetches.

### Step 6 — 401 handler

**Files**
- `PullRequestPilot/Infrastructure/GitHub/GitHubClient.swift`

**Changes**
- On HTTP 401, call `identity.invalidate(reason: .unauthorized)` and throw `GitHubError.unauthorized`.
- Bar any retry loop that would re-enter Keychain read with the same token (the "infinite retry with revoked token" bug in `dfe072ff`).

**Tests**
- Mock 401 → `IdentityActor.state == .invalid(.unauthorized)`.
- Subsequent calls on same token produce no network request (short-circuit).

## Risks

- **Widening the IdentityActor's responsibilities** — resist adding GitHub data to it. It owns token + viewerLogin only.
- **Migration breaks in-flight Keychain data** — existing users have tokens stored under the current service name. Keep the schema compatible; write a one-shot migration that reads the old format and writes the new.
- **Concurrency testing** — use `TaskGroup` in tests and loop 100× for each race scenario; flakes here are real bugs.

## Out of scope

- Multi-account support (see plan 06). This plan assumes one active identity; multi-account will wrap multiple `IdentityActor`s behind a registry.
- OAuth / GitHub App auth flows. Token-based auth only.

## Done criteria

- [ ] `IdentityActor` exists, is `actor`-isolated, and is the sole owner of `(token, viewerLogin)`.
- [ ] `TokenCache` is deleted.
- [ ] `DashboardViewModel` holds no viewer-login state.
- [ ] Keychain writes are atomic (no delete+add).
- [ ] All `catch` blocks in the auth path rethrow `CancellationError`.
- [ ] Token-swap regression test passes: "switch to a second token; previously-reviewed PRs appear for the new user."
- [ ] `make build` clean, `make test` green.
- [ ] No `@unchecked Sendable` introduced anywhere in `Infrastructure/Identity/`.
