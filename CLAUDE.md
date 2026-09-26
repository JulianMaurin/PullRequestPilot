# CLAUDE.md — Pull Request Pilot

Native macOS menu-bar/window app for GitHub pull-request review queues, with a WidgetKit extension. SwiftUI, macOS 14+, Swift 6 strict concurrency, Mac App Store (sandboxed). No third-party dependencies.

## Build & verify

```bash
make build            # regenerate project if stale + lint + Release build
make test             # lint + unit tests
make debug            # Debug build + run; sources .env (GITHUB_TOKEN=…)
make install          # build + copy to /Applications
make metadata-lint    # App Store subtitle/keywords/version/privacy checks
make release-check    # lint + test + metadata + build + codesign (app and widget)
make clean-deep       # wipe DerivedData + Xcode caches + NotificationCenter
```

- A change is done when `make build` and `make test` pass. Lint runs first (`brew install swiftlint`); warnings are errors.
- `project.yml` (XcodeGen) is the source of truth. The generated `.xcodeproj` is committed: regenerate, never hand-edit. `make` regenerates when Swift files are added or removed.
- Trust `make build`, not Xcode's editor errors (SourceKit shows phantom errors around `@Observable`, `Shared/` and regeneration). When they diverge, `make clean-deep`.
- `IdentityActor.readStoredToken(from:)` prefers `GITHUB_TOKEN` over the Keychain in DEBUG builds.

## Layout

```
PullRequestPilot/
  App/              entry point, AppState (composition root), AppDelegate (status item), EventCenter
  Domain/Models/    pure value types, Foundation only
  Features/         view + view-model pairs
  Infrastructure/   GitHub client, Keychain, persistence, local repositories, system monitors
  Shared/           app-only constants and helpers
Shared/             compiled into the app AND the widget (WidgetData)
PullRequestPilotWidget/
PullRequestPilotTests/   flat, <TypeUnderTest>Tests.swift; Mocks/, Helpers/
docs/               public website (GitHub Pages serves main:/docs); everything here is published
```

- Dependencies point Features → Infrastructure → Domain; features don't reference each other. SwiftLint's layering rules enforce it. `ReviewQueueViewModel` is the one composite: it drives `DashboardViewModel` and `PRDetailViewModel`. A feature that needs another's capability declares a protocol; `AppState` conforms (`DashboardActionsProtocol`).
- Wire dependencies in `AppState` (created by `AppDelegate`) and inject them. `DashboardViewModel` takes its system endpoints (notification center, widget destination) but still builds its pure collaborators; don't add more.
- Views hold no logic beyond layout state; behaviour goes in the view model, where it can be tested.
- `Features/Dashboard` has no view: it is the data behind the review queue (fetching, auto-refresh, badges, notifications, widget sync). A saved view is a `ViewDefinition`, not a SwiftUI view.
- `AppDelegate` owns the status item and `AppState`; closing the window hides it (`WindowAccessor`) so the status item can bring it back. Keep the `@NSApplicationDelegateAdaptor` line.
- Try SwiftUI scene and view modifiers before AppKit observers, KVO or `NSApp.mainMenu` edits.

## Enforced by tooling — don't restate, don't work around

- **SwiftLint** (`.swiftlint.yml`): the layering above; no `fatalError`/`preconditionFailure` in production; no `!` or `try!` anywhere, tests included; no `Dictionary(uniqueKeysWithValues:)`; no `@unchecked Sendable` in production; no `catch {}` or `catch { return nil/[]/false }`; no `UserDefaults.standard` outside `AppState`; no hard-coded `is:pr` (the app supports issue queries); no subprocesses or sandbox-unsafe paths; no TODO/FIXME; no audit finding IDs in source.
- **metadata-lint**: no brand terms (Mac, macOS, iOS, GitHub, Apple, …) in subtitle or keywords — two rejections so far; subtitle ≤ 30 chars; `MARKETING_VERSION` above the last tag; build number not below the last tag's; privacy manifests declare no tracking or collected data and a reason for every required-reason API their target calls.
- **release-check**: sandbox and hardened runtime on app and widget; widget entitlements ⊆ app entitlements.

## Rules tooling can't check

### Concurrency
- State read before an `await` may be stale after it. Re-check before committing (generation counter in `IdentityActor`, `Task.isCancelled` gates in `PRFetcher`).
- The network layer turns `URLError.cancelled` into `CancellationError`. Generic `catch` blocks must let `CancellationError` through. `try? await Task.sleep` swallows cancellation.
- A class that owns long-lived `Task`s keeps them in lock-backed storage and cancels them in `deinit` (which is nonisolated); one that observes `NotificationCenter` removes its observers.
- `start…()` is idempotent. Concurrent refreshes of one view join, keyed on view and query.
- Dates format and parse through `FormatStyle` values, which are Sendable; never a `DateFormatter` in a `static let`. Where no style fits (a relative date against a given reference date before macOS 15), create the formatter per call.

### Errors
- Every failure reaches the user through `EventReporter` (toast or banner) or is logged at `.error` with a reason it's safe to drop. Never lose saved data silently on load, decode or migrate.
- User-facing wording lives in `AppError`; other errors map through `Error.asAppError`, so the inline error and the toast read the same.
- Standing errors (`AppError.isStanding`) stay on the banner until dismissed; the subsystem that recovers calls `EventReporter.resolve(matching:)`.
- Classify HTTP status and GraphQL errors before decoding. GitHub reports GraphQL rate limits as HTTP 200 with an error body.

### GitHub API behaviour
- Queries send their inputs as GraphQL variables (`GraphQLRequest`); never interpolate user input into a document.
- Search `nodes` can be `null` (results withheld, e.g. SAML SSO) and arrive with partial `errors`. Non-PR matches arrive as `{"__typename": "Issue"}`.
- Pagination: cap loops at `maxPages = 20`; treat `""` as no cursor; reset the cursor when the query changes; synthesized IDs must be unique across pages.
- Reviewer state comes from `latestOpinionatedReviews` + `latestReviews`; a pending request means "awaiting review" even after an earlier review.
- Bot authors need `author:app/<login>`. Fork PRs (`isCrossRepository`) can't be matched to a local checkout by branch name.
- Check runs dedupe by `(name, workflowRunID)`, keeping the latest attempt, once over every page (`deduplicatedLatest()`).
- Check API assumptions against live data (`gh api graphql`, read-only) before encoding them.

### SwiftUI / Observation
- `@Observable` doesn't track computed properties backed by external storage (UserDefaults): mirror into a stored property.
- No `Task { … }` inside a `Binding.set` (first-click snap-back); use `.task(id:)` or move the mutation off the binding.

### Tests
- Swift Testing. `try #require`, not `!`. Mocks are actors. New behaviour comes with tests.
- Isolate state: `UserDefaults(suiteName:)`; Keychain services from `KeychainService.forTesting(service:)` in suites with `.keychainCleanup`; temporary backup directories and widget destinations; `MockUserNotificationCenter` — never the real app container, notifications or widgets.
- Wait for state (`TestWait.until`), not for time. A new test must fail when its fix is reverted.

## App Store

- Automatic signing with team `FNR3B372S8`; never manual. Sandbox and hardened runtime on both targets. Entitlements: app = sandbox, network client, user-selected read-only files, app group; widget = sandbox, app group. A new entitlement needs a discussion first.
- No subprocesses, private APIs, `dlopen`, or paths outside the sandbox. Environment variables only under `#if DEBUG`.
- Versions are declared once in `project.yml` (the widget must match the app). Bump `MARKETING_VERSION` above the last tag for each release and `CURRENT_PROJECT_VERSION` for each upload.
- Update the privacy manifests for any new required-reason API (an app-group `UserDefaults` suite needs reason `1C8F.1`; file timestamps need their own).
- No placeholder UI. There is no Help Book, so don't bring back the system Help menu item.
- The app must stay usable offline, with an invalid or revoked token, and while rate-limited.

## Widget

- Reads `widget-data.json` from the app-group container `FNR3B372S8.com.pullrequestpilot.shared` (`WidgetData.appGroupIdentifier`). Never assume the app is running; keep timeline providers light.
- Timeline reloads are budgeted by WidgetKit: reload only when content changes (`WidgetSync`).
- After changing widget kinds or names: `make clean-deep` and reinstall — a stale debug build shadows the installed widget.
- The widget has its own `AppIcon` asset catalog. Add widgets to `PullRequestPilotWidgets` (a `WidgetBundle`); configurable ones use `AppIntentConfiguration` with `let` statics.
- Keep the name `DashboardViewEntity`: configured widgets refer to it.
- The app handles `pullrequestpilot://view/<viewID>`; the widgets build it with `DeepLink` to open a view.

## Identity & data

- The token lives only in the Keychain. `IdentityActor` reads it once at launch and owns it; never read the Keychain per request (it prompts). A confirmed 401 invalidates, and `SettingsViewModel` observes `invalidations`.
- The Keychain is the file-based one on purpose (`KeychainService` says why); moving to the data protection keychain needs a new entitlement.
- Git directories keep security-scoped access for the app's lifetime (the repo scan needs it): `GitDirectoriesStore.load()` starts it as each bookmark resolves, `SettingsViewModel` stops it on removal. Unresolvable bookmarks stay stored and are retried; only an explicit removal deletes one. Any other `startAccessingSecurityScopedResource()` pairs with a `defer` stop.
- Never log tokens or user data as `.public`.

## Commits & audits

- One commit per user-visible category: `Fix: <Area> — …`, `Add: <Area> — …`, `Refactor: …`, `Update: …`. Not `Bugfixes`, not `Apply review feedback`.
- Whole-codebase audits ("ultrathink", "analyze the whole code", "fix all the findings") use the `audit-and-fix` skill; reports go to `todo/audits/AUDIT-YYYY-MM-DD.md`.
