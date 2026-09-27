# Lane definitions

Each lane agent receives the preamble plus its own section. Lane agents already have CLAUDE.md: point at its sections, don't paste them.

## Preamble (every lane)

Audit one lane of Pull Request Pilot and return findings matching the schema. An empty list is a valid answer; a plausible finding without evidence is not.

- Out of scope: anything SwiftLint (`.swiftlint.yml`), warnings-as-errors, `make metadata-lint` or `make bundle-check` already enforce. `make build` fails on those, so hunting them wastes the lane.
- In scope: CLAUDE.md "Rules tooling can't check", plus the focus of your lane below.
- Every finding carries evidence: the quoted code at file:line. A claim about GitHub or Apple API behaviour is checked against live data (`gh api graphql`, read-only) or the documentation, never assumed.
- Report a finding once, in the lane that owns its file; cross-cutting lanes report only what spans modules.

---

## domain

**Scope:** `PullRequestPilot/Domain/**`.

**Focus:** value semantics; Equatable, Hashable and Identifiable identity (IDs unique across pages and across views); derived properties that disagree with the data they derive from; date parsing and formatting (CLAUDE.md Concurrency, format styles).

**Non-scope:** networking payloads (infrastructure), view-model behaviour (features).

## features

**Scope:** `PullRequestPilot/Features/**`: view models and views.

**Focus:** CLAUDE.md Concurrency (state stale after an `await`, task ownership, idempotent `start…()`), SwiftUI / Observation, and Errors (every failure reaches `EventReporter`). Views that carry behaviour a view model should own and test.

**Non-scope:** cross-module cancellation and Sendable issues (concurrency).

## infrastructure

**Scope:** `PullRequestPilot/Infrastructure/**`: GitHub client, identity and Keychain, persistence, local repositories, networking, notifications, logging.

**Focus:** CLAUDE.md GitHub API behaviour, Identity & data, and Errors: status classified before decoding, saved data never lost silently on load, decode or migrate, security-scoped access paired and kept as documented, nothing logged `.public` that holds a token or user data.

**Non-scope:** UI and view models (features).

## appshell

**Scope:** `PullRequestPilot/App/**`, `PullRequestPilot/Shared/**`, `Shared/**`, `PullRequestPilotWidget/**`.

**Focus:** `AppState` as the composition root (dependencies wired there and injected); `AppDelegate` status item and window lifecycle; `EventCenter`; deep links. Widget: CLAUDE.md Widget (the app may not be running, timeline providers stay light, reloads only when content changes, `DashboardViewEntity` keeps its name).

**Non-scope:** feature internals (features).

## tests

**Scope:** `PullRequestPilotTests/**`.

**Focus:** CLAUDE.md Tests. Tests that cannot fail (the assertion is unreachable or trivially true); success-only coverage; waiting on time instead of state; state leaking into the real app container, Keychain, notifications or widgets; view-model or infrastructure behaviour added in the last few dozen commits with no test; file-URL comparisons that break outside the sandbox.

**Non-scope:** production defects (the other lanes).

## concurrency

**Scope (cross-cutting):** Sendable and actor isolation, cancellation propagation, task lifecycle, refresh coalescing.

**Focus:** CLAUDE.md Concurrency across module boundaries: a generic `catch` that turns `CancellationError` into a failure, `try? await Task.sleep` in long-lived loops, check-then-act across an `await` (TOCTOU caches without a generation counter), concurrent refreshes of one view that don't join, tight loops when the work set is empty.

**Non-scope:** task-lifecycle issues local to one feature (features).

## appstore

**Scope:** `project.yml`, entitlements, `Info.plist` settings, both `PrivacyInfo.xcprivacy`, `metadata/appstore.yml`, sandbox-sensitive code anywhere.

**Focus:** CLAUDE.md App Store, on what the scripts can't judge: an entitlement or capability without a stated need; a required-reason API declared with the wrong reason; environment variables outside `#if DEBUG`; private API, `dlopen`, `performSelector` on private selectors; placeholder UI; a Help menu item without a Help Book.

**Non-scope:** code quality (the other lanes).

## performance

**Scope:** hot paths: auto-refresh, pagination, list rendering, avatar and image decoding, local repository scans, widget sync.

**Focus:** work repeated on every `body` evaluation; decoding or file I/O on the main actor; timers or refreshes while the window is hidden, the Mac is asleep, or the app is idle; unbounded caches; widget reloads that spend the WidgetKit budget without a content change.

**Non-scope:** micro-optimisations with no user-visible effect; rewrites without measurement.

## ux

**Scope:** every user-facing surface: window, menu bar, menus, Settings, notifications, widgets.

**Focus:** CLAUDE.md Errors from the user's side (wording from `AppError`, standing errors that resolve when the subsystem recovers); empty and first-run states; the app offline, with an invalid or revoked token, and while rate-limited; icon-only controls without an accessibility label; primary actions unreachable from the keyboard or menus; destructive actions without confirmation.

**Non-scope:** visual polish that doesn't affect use.

## architecture

**Scope (cross-cutting):** the whole target structure.

**Focus:** CLAUDE.md Layout: layering the SwiftLint layering rules don't catch, features reaching into each other, collaborators built outside `AppState`, types that grew into a second composition root, duplicated implementations, dead code. A statement in CLAUDE.md that the code contradicts is a finding.

**Also returns** `assessment`: the structure's strengths and weaknesses in a few sentences.

## macos-platform

**Scope (cross-cutting):** platform behaviour: window and scene lifecycle, full screen, the menu bar item, notifications, sleep and wake, network changes, launch at login, appearance.

**Focus:** behaviour that is wrong on the platform, checked against Apple documentation.

**Also returns** `opportunities`: platform features the app lacks (confirmed absent by searching the code), with their APIs, effort and value. Opportunities are not findings.
