# 04 — Request coalescing & cancellation hygiene

## Goal

Eliminate two entire bug families at once:
1. **Overlapping concurrent requests** (two views polling the same repo, two `refreshAll` calls, etc.) should coalesce into one network trip.
2. **Cancellation** should propagate cleanly — never surface as a user-visible error, never be treated as a permanent failure.

## Evidence

- **Overlapping `refreshAll` causing double notifications** (ef795a23 H3).
- **Concurrent scans racing on `repoIndex`** (c36d86ce).
- **TokenCache TOCTOU** (ef795a23 C1).
- **Sub-agent finding: "Request deduplication layer — coalesce concurrent identical GraphQL queries across views"** (771b7346).
- **`URLError.cancelled` → user-visible error** (CLAUDE.md Concurrency Pitfalls) — keeps recurring in *new* code.
- **`fetchViewerLoginIfNeeded` flipping `viewerLoginFetchFailed = true` on cancellation** (e2c95ad3) — permanently broke the hide-reviewed filter.
- **`AvatarCache` catching `CancellationError` and logging noise** (d27f2f56).

## Current state

- Every ViewModel calls `GitHubClient` directly.
- Two tabs open on the same repo → two GraphQL calls in flight.
- Cancellation is handled inconsistently — some sites rethrow, some swallow, some classify as failure.

## Target design

### 1. `RequestCoalescer` — one in-flight task per request key

```swift
actor RequestCoalescer<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]

    func run(key: Key, operation: @Sendable @escaping () async throws -> Value) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
    }
}
```

### 2. Two coalescers in `AppState`

- `githubQueryCoalescer: RequestCoalescer<GraphQLQueryKey, GraphQLResponse>` for dashboard PR fetches.
- `avatarCoalescer: RequestCoalescer<URL, Data>` for avatar fetches (today `AvatarCache` racks up duplicates).

### 3. Cancellation discipline (enforced by lint rule — plan 13)

Every `catch` in any `async` function in `Infrastructure/` and `Features/` must:

```swift
} catch is CancellationError {
    throw
} catch let urlError as URLError where urlError.code == .cancelled {
    throw CancellationError()
} catch { /* handle real errors */ }
```

### 4. `AutoRefreshScheduler` (from plan 02) uses `Task` cancellation, not `Task.sleep` swallowing

```swift
func startAutoRefresh() async {
    while !Task.isCancelled {
        do {
            try await Task.sleep(for: interval)
            await tick()
        } catch is CancellationError { return }
    }
}
```

Not:
```swift
try? await Task.sleep(for: interval) // BUG — silently swallows cancellation, next tick fires
```

## Implementation steps

### Step 1 — Build `RequestCoalescer`

**Files**
- New: `PullRequestPilot/Infrastructure/Networking/RequestCoalescer.swift`

**Changes**
- Generic actor as above.
- `run(key:)` guarantees: at most one task per key at any time; concurrent callers await the same result; cancellation of caller N+1 does *not* cancel the underlying task (it still benefits caller 1's cancellation semantics).

**Tests**
- Two concurrent `run(key: "a")` → one execution, both callers get same result.
- Distinct keys run concurrently.
- First caller cancels: coalesced task cancels only if no other caller; if another caller is present, task continues.
- Operation throws → both callers see error.

### Step 2 — Wire into `GitHubClient`

**Files**
- `PullRequestPilot/Infrastructure/GitHub/GitHubClient.swift`

**Changes**
- Every fetch method builds a `GraphQLQueryKey(hash: queryHash, variables: varsHash)`.
- Delegates to `coalescer.run(key:)`.
- `refreshAll()` running across 10 views with overlapping orgs will now coalesce identical queries.

**Tests**
- Mock GraphQL round-trip counter. Two identical queries from concurrent tasks → counter increments once.
- Distinct queries → counter increments twice.

### Step 3 — Wire into `AvatarCache`

**Files**
- `PullRequestPilot/Infrastructure/AvatarCache/AvatarCache.swift`

**Changes**
- `image(for url:)` delegates to `avatarCoalescer.run(key: url)`.
- Catch `CancellationError` and do **not** log or cache as failure.

**Tests**
- Two concurrent requests for same URL → one network fetch.
- Cancellation while fetching → no log, no cached failure, caller sees CancellationError.

### Step 4 — Cancellation audit across the codebase

**Files**
- `PullRequestPilot/Infrastructure/GitHub/GitHubClient.swift`
- `PullRequestPilot/Infrastructure/AvatarCache/AvatarCache.swift`
- `PullRequestPilot/Infrastructure/LocalRepository/*.swift`
- `PullRequestPilot/Features/**/*ViewModel.swift`

**Changes**
- Grep for every `catch` block in these files. Each must be one of:
  - rethrow (with the `is CancellationError` + `URLError.cancelled` pattern).
  - Or: explicit handler that does not treat cancellation as failure.
- `try? await Task.sleep` → `do { try await Task.sleep } catch is CancellationError { return }`.

**Tests** (regression tests, one per site)
- `DashboardViewModel.refreshAll()` + immediate `stopAutoRefresh()` → no user-visible error, no false notifications.
- `fetchViewerLogin` cancelled mid-flight → next call succeeds, no `viewerLoginFetchFailed` set.
- `AvatarCache.image` cancelled → next call for same URL works.

### Step 5 — Lint rule

**Files**
- `.swiftlint.yml`

**Changes**
- Add a custom rule `async_catch_must_rethrow_cancellation` matching regex-based `catch \{` without a `CancellationError` clause inside async functions. See plan 13 for the lint ledger.

## Risks

- **Coalescer deadlocks** — if `run` is called recursively with the same key, the inner call will await the outer which is awaiting the inner. Mitigate with: `Task.currentPriority` check + documentation that recursive same-key calls are not supported.
- **Task priority inversion** — a low-priority background refresh might be coalesced with a high-priority user-initiated fetch. The current actor design doesn't prioritize; the high-priority caller waits. Acceptable for now; revisit if hot.
- **Over-coalescing** — mutating calls (e.g., write actions from plan 07) should **not** coalesce. Apply coalescer to reads only.

## Out of scope

- Webhook/SSE (plan 05) would eliminate most of this, but is a bigger change. This plan hardens polling.
- Auth lifecycle (plan 01).

## Done criteria

- [ ] `RequestCoalescer` exists with full test coverage including race scenarios.
- [ ] `GitHubClient` reads go through the coalescer.
- [ ] `AvatarCache` reads go through the coalescer.
- [ ] Every `catch` in `Features/` and `Infrastructure/` async functions either rethrows `CancellationError` or explicitly handles it non-fatally.
- [ ] No `try? await Task.sleep` remains in the code.
- [ ] Lint rule is in place and CI green.
- [ ] Regression test: 10 concurrent view refreshes with 80% overlap → network call count drops to the distinct-query count.
