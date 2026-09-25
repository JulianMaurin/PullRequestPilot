# CLAUDE.md — Pull Request Pilot

## Project Overview

A native macOS menu bar/window app for monitoring GitHub pull request review queues. Built with SwiftUI, targeting macOS 14+ (Sonoma), Swift 6 with strict concurrency.

## Build & Run

A `Makefile` wraps all build commands. `DEVELOPER_DIR` is set automatically.

```bash
make build            # Regenerates xcodeproj if stale + lint + Release build (terse output)
make debug            # Debug build + run (sources .env for GITHUB_TOKEN)
make run              # Release build + run
make install          # Build + copy to /Applications/Pull Request Pilot.app
make uninstall        # Remove from /Applications
make test             # Lint + run unit tests
make lint             # SwiftLint --strict (blocks on errors and warnings)
make lint-errors-only # SwiftLint without --strict (dev iteration)
make metadata-lint    # App Store subtitle/keywords/version/privacy checks
make release-check    # Pre-submission gate (lint + test + metadata + build + codesign)
make clean            # Clean build artifacts
make clean-deep       # Wipes DerivedData + Xcode caches + NotificationCenter (ghost-error reset)
```

Build output is piped through `scripts/xcb-filter.sh` (falls back to `xcpretty` if installed), which drops per-file compile/link chatter and keeps errors, warnings, and test results. The `make build` xcodegen step is file-dependency-driven: adding, removing, or modifying any `.swift` file under `PullRequestPilot/`, `Shared/`, `PullRequestPilotTests/`, or `PullRequestPilotWidget/` triggers regeneration on the next build.

**SwiftLint is required.** `brew install swiftlint`. Both `make build` and `make test` run `make lint` first — lint failures block the build. Rules live in `.swiftlint.yml` at the repo root and cover the tests too.

In debug builds, `IdentityActor.readStoredToken(from:)` prefers `GITHUB_TOKEN` from the environment over the Keychain (`#if DEBUG`). Create a `.env` file at the project root and `make debug` will source it automatically.

```bash
# Open in Xcode
open PullRequestPilot.xcodeproj
```

**Always verify builds from the command line** (`make build`) after changes — don't rely on Xcode's index alone.

**Source of truth for project configuration is `project.yml` (XcodeGen).** Never edit `*.xcodeproj` files directly — regenerate with `xcodegen generate`.

**After creating or deleting any Swift file**, you MUST run `xcodegen generate` before building — otherwise the Xcode project won't include the new files and builds will fail with "cannot find type" errors.

### When the build seems wrong

**Trust `make build`, not Xcode's in-editor errors.** SourceKit shows phantom errors with `@Observable`, cross-target types (`Shared/`), and after XcodeGen regenerations. Don't refactor to "fix" something only Xcode flags.

**When Xcode and reality diverge, run `make clean-deep`.** Wipes DerivedData, Xcode caches, and kicks NotificationCenter (clears widget registrations). Use when CLI errors persist, `make test` crashes with stale binaries, or Xcode shows unreachable errors.

## Architecture

**MVVM + Clean Architecture** with three layers:

```
Domain/Models/        — Pure data models, no dependencies
Features/             — Feature modules (View + ViewModel pairs)
Infrastructure/       — External service adapters (GitHub API, Keychain, Persistence)
App/                  — App entry point, DI root (AppState), root navigation
Shared/               — Cross-cutting constants (app target only)
```

These live under `PullRequestPilot/`. The top-level `Shared/` directory is different: it's compiled into both the app and the widget (see Widget Extension Rules).

**Dependency flow:** Features → Infrastructure → Domain (arrows point at dependencies). Features never reference each other; Infrastructure never references Features or App, and holds no views; Domain imports only Foundation. Everything is one module, so SwiftLint's layering rules enforce this (`domain_imports_foundation_only`, `infrastructure_knows_no_ui`, `*_feature_isolated`). `EventReporter` lives in Domain so every layer can post events. The one composite screen is `ReviewQueue`: `ReviewQueueViewModel` drives `DashboardViewModel` and `PRDetailViewModel`. When a feature needs another's capability, it declares a protocol and `AppState` supplies the conformance (`DashboardActionsProtocol`).

**Dependency injection:** All wiring happens in `AppState.swift` — the single composition root, created by `AppDelegate` so the status item and menus work before any window opens. ViewModels receive their dependencies via constructor injection.

## Code Conventions

### Swift & Concurrency

- **Swift 6** with `SWIFT_STRICT_CONCURRENCY: complete` — all concurrency warnings are errors. Every type crossing concurrency boundaries must be `Sendable`.
- **`@MainActor`** on all ViewModels and UI-bound classes.
- **`@Observable`** (Observation framework) for state — not `ObservableObject`/`@Published`.
- **`async/await`** exclusively — no completion handlers, no Combine for new code.
- **`Task` groups** for concurrent operations (e.g., refreshing multiple views).
- **Classes that spawn `Task`s must implement `deinit`** and cancel them. Classes that observe `NotificationCenter` must remove observers. Bug history: `DashboardViewModel` leaked an observer and stranded refresh tasks; auto-refresh kept firing after the view was gone.

### Naming

- Protocols: `*Protocol` (e.g., `GitHubClientProtocol`)
- ViewModels: `*ViewModel`
- Views: `*View`
- Services: `*Service`
- Stores: `*Store`
- Constants: nested enums in `Constants` (e.g., `Constants.Keychain.githubToken`)

### Code Organization

- Use `// MARK: - Section` to organize file sections.
- Explicit access control: `private`, `internal`, `public` — default to most restrictive.
- Mark classes `final` unless designed for inheritance.
- Group file contents: properties → init → public methods → private methods → extensions.

### Prefer declarative SwiftUI over AppKit observers

When adding menu items, window chrome, or lifecycle reactions, try SwiftUI scene modifiers **before** reaching for `NSWindowWillUpdateNotification`, KVO, or `NSApp.mainMenu` mutations.

Observed pattern: building an `NSWindowWillUpdateNotification` observer to fix an empty Window menu, then the fix turning out to be a one-line `.navigationTitle("PR Views")`. If your first instinct is an observer, re-check the declarative API surface.

Applies to: window title, dock menu, command menus, status bar item appearance, menu bar extras.

### Error Handling

- Define error types as enums conforming to `LocalizedError` with user-facing `errorDescription`.
- Surface errors in UI — never silently swallow.
- Use `do/catch` with typed errors at the call site.

#### Silent failures are forbidden

The recurring bug pattern in this codebase is `try?` + empty return, which destroys user data. Rules:

- **No `try?` without a log** on any `load`, `decode`, or `migrate` path. If decode fails, surface an error to the user. Losing saved views, directories, or widget data without telling the user is an App Review risk and a trust breaker.
- **No bare `catch {}` or `catch { return [] }`.** If you can't recover, rethrow; if you must swallow, log with `os.Logger` at `.error` and emit a user-visible toast.
- **HTTP error codes must be classified before JSON decoding.** 403/429/5xx should short-circuit into typed errors, not fall through to "invalid response" when the body isn't JSON.

#### Force-unwraps forbidden

`!`, `try!`, `fatalError()`, `preconditionFailure()` are instant crashes — including `preconditionFailure` in lazily-invoked closures (e.g., URL constants).

This has shipped one production crash: `Dictionary(uniqueKeysWithValues:)` on PR `headRefName` blew up when two PRs shared a branch name (force-push, forks, reopened PRs). Users on v1.2.1 saw the app die on launch.

- **No `!` in production** — use `guard let`/`if let` and surface an error.
- **No `Dictionary(uniqueKeysWithValues:)` on API data** — use `Dictionary(_, uniquingKeysWith:)` or `reduce(into:)`.
- **No `!` in tests either** — use `try #require(...)`. A crash in a test hides what failed.
- **`Date` math must handle clock skew** — future-dated timestamps (server drift, timezone bugs) have crashed real data paths.

### Testing

- **Swift Testing** framework (`@Suite`, `@Test`) — not XCTest for new tests.
- Protocol-based mocking: mock implementations of protocols (e.g., `MockGitHubClient`).
- Test files live flat in `PullRequestPilotTests/`, named `<TypeUnderTest>Tests.swift`.
- Mock files go in `PullRequestPilotTests/Mocks/`.
- Use isolated `UserDefaults(suiteName:)` in tests — never touch real user defaults. Suites that write the Keychain create it with `KeychainService.forTesting(service:)` and carry the `.keychainCleanup` trait; stores that back up corrupted data take a temporary `backupDirectory`.
- `DashboardViewModel` takes its system endpoints (`notificationCenter`, `widgetDestination`); tests pass `MockUserNotificationCenter()` and `.temporary()`, so no run touches real notifications or widgets.
- **Empty stores in tests**: `ViewsStore` with fresh `UserDefaults` returns `[]` (`defaultViews` is empty). Tests must call `viewModel.addView(...)` before accessing `views.first`. Use `try #require(...)` for unwrapping, never `!`.
- Test both success and error paths. Test edge cases (empty state, invalid input).
- **No `Task.sleep` as synchronization in tests.** Wait for the target state with `TestWait.until { … }`, or await the work itself (`PRDetailViewModel.waitForCurrentLoad()`). Sleep-based waits are flaky under Swift Testing's parallel runner. To prove something does *not* happen, wait for the bad state with a short timeout, then assert it didn't arrive.
- **`MockGitHubClient` must be actor-backed, not `@unchecked Sendable`.** Mock state is read/written concurrently by parallel tests; shared mutable state without isolation produces intermittent failures.

## Key Technical Decisions

- **GraphQL over REST** for GitHub API — single endpoint, precise field selection, cursor pagination.
- **Keychain** for token storage — never persist tokens in UserDefaults or files. `IdentityActor` owns the in-memory identity state (token + viewer login); never read Keychain on every API call (causes repeated macOS permission prompts).
- **Status bar app** — `AppDelegate` owns the `NSStatusItem`. Window hides on close (via `WindowAccessor` intercepting `windowShouldClose`) instead of being destroyed, so the status bar icon can re-show it. Never remove the `@NSApplicationDelegateAdaptor` line.
- **No external dependencies** — everything uses Apple frameworks (URLSession, SwiftUI, Security). Keep it this way unless there's a compelling reason.
- **XcodeGen** for project generation — `project.yml` is the source of truth. The generated `.xcodeproj` is committed, so regenerate it instead of editing it.

### GraphQL pagination safety

- **Every `repeat ... while nextCursor != nil` loop needs `let maxPages = 20`.** Unbounded paging has shipped twice as an infinite loop.
- **Event IDs reset per page** — GitHub's timeline returns indices that are page-local. If you synthesize an ID from the index, include the cursor to avoid collisions in SwiftUI `ForEach`. The canonical bug: page-2 timeline events silently vanished because `ForEach(id:)` deduped against page-1 IDs.
- **Empty-string cursor is not the same as nil.** Filter `""` out before looping.
- **Stale cursors across query edits** — if the user edits the search query, reset the cursor. Reusing the previous query's cursor returns nonsense.
- **Check runs must dedupe by `(name, workflowRunID)` keeping the latest attempt.** Deduping by `name` alone hides failed re-runs.

## Concurrency Pitfalls

Every pitfall below has shipped in this codebase at least once. The fix is always the same: treat concurrency as a boundary problem, not a local one.

### Cancellation
- **`URLError.cancelled` must be caught and rethrown as `CancellationError` in the network layer** — otherwise it surfaces as a user-visible error during normal operation (auto-refresh restart, view switch).
- **Generic `catch` in an async function must rethrow `CancellationError`** — do not treat it as a permanent failure. Bug: `fetchViewerLoginIfNeeded` flipped `viewerLoginFetchFailed = true` on cancellation, permanently disabling the hide-reviewed filter.
- **`try? await Task.sleep` silently swallows cancellation** — prefer `try await Task.sleep` so the outer task exits promptly.

### State that crosses tasks
- **`@unchecked Sendable` is almost always wrong.** If you need it, add an `NSLock` (or better, an actor). Bugs: `ViewsStore`, `GitDirectoriesStore`, `DateFormatter` statics all had real data races.
- **Static formatters are shared state.** A `DateFormatter` or `ISO8601DateFormatter` stored in a `static let` is not Sendable. Use a `FormatStyle` (`Date.ISO8601FormatStyle`, `Date.VerbatimFormatStyle`, `.formatted(...)`), which is a Sendable value; where none fits (a relative date against a given reference date, before macOS 15), create the formatter per call.
- **TOCTOU on caches.** Any `get-then-invalidate` pair must serialize through a generation counter or actor (see `IdentityActor.invalidateIfMatchingToken`). Bug history: keychain read on one task revived a token another task had just invalidated.

### Auto-refresh / idempotency
- **`startAutoRefresh()` must be idempotent** — no-op if already running. Cancel in-flight work via `stopAutoRefresh()` first.
- **Concurrent `refreshAll` calls must dedupe.** Coalesce on a `Task` handle; a second caller joins the first.
- **No tight loops when idle.** If the work set is empty, sleep a long interval; do not spin every 5s.

### Observation / SwiftUI
- **`@Observable` does not track computed properties backed by external storage** (e.g., `UserDefaults`). Mirror into a stored property and update on external change.
- **`Task { await ... }` inside a `Binding.set` causes first-click snap-back.** Use `.task(id:)` or move the mutation off the binding.
- **`disabled(...)` changing mid-frame can swallow the concurrent state change.** Don't bind `disabled` to values you also mutate in the same tick.

## File Guidelines

- New features go in `Features/<FeatureName>/` with their own View and ViewModel.
- New domain models go in `Domain/Models/`.
- New external service integrations go in `Infrastructure/<ServiceName>/`.
- DTOs (API response models) stay in Infrastructure — domain models must not know about wire formats.
- Keep views stateless — all logic and state belong in ViewModels.

### `UserDefaults.standard` is banned outside AppState

Classes that accept an injected `UserDefaults` must use the injected value. Reading `UserDefaults.standard` anywhere in `Features/` or `Infrastructure/` bypasses DI, breaks tests, and loses the app-group container in widget contexts.

Bug history: auto-refresh toggle and AppState launched with hardcoded `.standard`; a widget reading the wrong suite would see zero data.

Enforced by SwiftLint (`user_defaults_standard_outside_appstate`).

### Security-scoped bookmarks

Bookmarked git directories get app-lifetime access on purpose, so the periodic repo scan can read them: `GitDirectoriesStore.load()` starts access as each bookmark resolves (at launch, or later once an unavailable disk is back), `SettingsViewModel` stops it when a directory is removed, and `AppState.cleanup()` stops the rest. Don't "fix" that into per-function pairing. A bookmark that doesn't resolve stays stored and is retried on every load; only an explicit removal deletes it.

Any other `url.startAccessingSecurityScopedResource()` must be paired with `stopAccessingSecurityScopedResource()` in the same scope (`defer`). Missing stops leak access counts and eventually break sandbox reads.

## App Store Compliance

This app is distributed via the Mac App Store. **Every line of code must be sandbox-safe, review-safe, and production-ready.**

### Sandbox Rules (MANDATORY)

- **App Sandbox is ON** (`com.apple.security.app-sandbox: true`). All code must work within sandbox constraints.
- **No shell commands** — never use `Process()`, `NSTask`, `/bin/sh`, `/usr/bin/env`, or any subprocess spawning. This is a hard App Store rejection.
- **No dynamic library loading** — no `dlopen`, `NSBundle.load()`, or runtime code loading.
- **No file access outside sandbox** — only access files via user-selected (`NSOpenPanel`) or app group containers. Never hardcode paths like `~/`, `/tmp`, `/usr/local`, etc.
- **No private/undocumented APIs** — only use public Apple frameworks. No `@objc` selectors on private APIs, no `performSelector` tricks, no `IOKit` unless the entitlement is granted.
- **No `setenv`/`getenv` for configuration in production** — environment variables are only for `#if DEBUG` blocks.
- **Entitled operations only** — if a capability isn't declared in the entitlements file, the code must not attempt it. Current entitlements: network client, user-selected file read-only, app groups.

### App Review Rules

- **No placeholder UI or incomplete features** — every feature must be fully functional. Hide unfinished work behind `#if DEBUG` or don't merge it.
- **Privacy compliance** — if adding any new data collection, add matching `NSPrivacyCollectedDataTypes` in the privacy manifest. The app currently collects no user data beyond the GitHub token.
- **Privacy manifest required** — any new framework or SDK that Apple lists as requiring a privacy manifest must include one. Check Apple's list before adopting any dependency.
- **No misleading metadata** — bundle display name, category, and descriptions must accurately reflect app functionality.
- **Forbidden terms in subtitle** (App Store rejected twice on this): `macOS`, `Mac`, `iOS`, `iPhone`, `iPad`, `GitHub`, `Apple`, or any other trademarked brand. The same terms are banned from keywords. Mirror the App Store Connect subtitle and keywords in `metadata/appstore.yml` and run `make metadata-lint` — it checks forbidden terms (subtitle and keywords), the 30-char limit, version monotonicity, and privacy manifests.
- **Crash-free** — App Review tests basic flows. Any crash during review is an automatic rejection. Test all flows with real and invalid tokens, network failures, and empty states.
- **Graceful degradation** — the app must remain usable (show meaningful UI) when: network is unavailable, token is invalid/expired, GitHub API returns errors, rate limits are hit.
- **No deprecated API usage** — do not use APIs deprecated in macOS 14+. Use the modern replacement immediately.
- **Login/auth must work on first try** — App Review will test the token flow. Provide clear instructions and error messages for authentication.

### Entitlements & Capabilities

- **Never add entitlements without justification** — each entitlement requires explanation during App Review. Only request what the app actively uses.
- **Network entitlement** (`com.apple.security.network.client`) — required for GitHub API. Do not add `network.server`.
- **Keychain sharing** — uses app groups for widget data sharing. The keychain service name must match the bundle ID.
- **No new entitlements without discussion** — if a feature requires a new entitlement, discuss the App Review implications first.

### Code Signing & Versioning

- **Automatic signing** with team `FNR3B372S8`. Never switch to manual signing in `project.yml`.
- **Versions are declared once**, in `project.yml`'s top-level `settings.base`, so the widget always matches the app (App Store Connect rejects a mismatch).
- **Bump `MARKETING_VERSION`** (semver) above the last git tag for every release: App Store Connect closes a version once it's approved.
- **Bump `CURRENT_PROJECT_VERSION`** (build number) for every new archive/upload. App Store Connect rejects duplicate build numbers. `make metadata-lint` enforces both bumps.
- **Hardened runtime is ON** — never disable it. Code must work without JIT, unsigned memory, or DYLD environment variables.

### Widget Extension Rules

- **Widget must work independently** — it reads from the shared app group container. Never assume the main app is running.
- **Widget bundle ID must be prefixed** with the main app's bundle ID (`com.pullrequestpilot.app.widget`).
- **Widget entitlements must be a subset** of or equal to the main app's entitlements.
- **Widgets must not perform heavy computation** — keep timeline providers lightweight.
- **Shared code lives in `Shared/`** — the `Shared/` directory is included in both the main app and widget extension targets via `project.yml`. Use it for data models shared between the two (e.g., `WidgetData.swift`). Never duplicate files across targets.
- **Widget WidgetBundle** — the extension uses a `WidgetBundle` (`PullRequestPilotWidgets`) to expose multiple widget types. Add new widgets there.
- **AppIntentConfiguration for configurable widgets** — use `AppEntity` + `EntityQuery` + `WidgetConfigurationIntent` for widgets the user can configure (e.g., selecting a dashboard view). Mark static properties as `let` (not `var`) for Swift 6 strict concurrency.
- **macOS caches widget metadata aggressively** — after changing widget kinds/names, you must: clear DerivedData (`rm -rf ~/Library/Developer/Xcode/DerivedData/PullRequestPilot-*`), kill NotificationCenter (`killall NotificationCenter`), and reinstall the app. A debug build in DerivedData can register a conflicting widget extension that shadows the installed app's widgets.
- **Widget extension has its own `Assets.xcassets`** — the widget extension needs a separate asset catalog with an `AppIcon.appiconset` so the widget gallery shows the correct icon. The `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` build setting must be set in `project.yml` for the widget target.
- **Deep linking** — the app registers the `pullrequestpilot://` scheme (`Info.plist` via `project.yml`) and handles only `pullrequestpilot://view/<viewID>` (`DeepLinkRoute`), which selects a view. `DeepLink` (in `Shared/`) builds it for the widgets: clicking a view widget, or a view in the summary widget, opens that view; PR rows `Link` to GitHub.

### Data & Persistence

- **UserDefaults for non-sensitive preferences only.** Data shared with the widget is a JSON file (`widget-data.json`) in the app-group container `FNR3B372S8.com.pullrequestpilot.shared` (`WidgetData.appGroupIdentifier`) — there is no shared UserDefaults suite. Adding one would also need privacy-manifest reason `1C8F.1`.
- **Keychain for secrets** — tokens, credentials, and API keys must use the Keychain. Never log, print, or persist tokens in UserDefaults, files, or crash reports.
- **Never log sensitive data** — no token values, no full API responses containing user data. Log with `Logger(category:)` and mark user-identifiable values `privacy: .private`.

### Build Verification Checklist

Before any PR that touches production code:
1. `make build` succeeds (warnings are errors).
2. `make test` passes all tests.
3. App launches and completes core flows (auth, PR list, refresh, settings) in sandbox.
4. Widget renders correctly with both populated and empty data.
5. No new entitlements added without justification.
6. No `Process()`, shell commands, or file access outside sandbox.

## Audit & Fix Workflow

Whole-codebase audits use the `audit-and-fix` skill (`.claude/skills/audit-and-fix/SKILL.md`), not an ad-hoc "ultrathink" prompt. When the user types the ritual phrase ("ultrathink", "analyze the whole code", "fix all the findings"), invoke the skill rather than re-deriving the format.

The skill enforces the contract:

1. Parallel lane-focused sub-agents (domain, features, infrastructure, tests, concurrency, appstore, performance, ux).
2. Each sub-agent returns JSON matching `references/finding-schema.json`.
3. Synthesizer merges + dedupes + sorts; every finding becomes a TodoWrite todo — no silent drops.
4. Fix-mode is the default. Only `critical` or `high + non-small blast` findings pause for user approval.
5. `make lint` / `make build` / `make test` must all pass before any commit.
6. Diff is split into one commit per `rootCauseCategory`; an audit report lands at `todo/audits/AUDIT-YYYY-MM-DD.md`.

## Commits

After a batch of fixes, split into one commit per user-visible category so the next changelog writes itself.

- Good: `Fix <bug>`, `Add <feature>`, `Refactor <subsystem>`, `Update <dependency>`.
- Bad: `Apply review feedback`, `Bugfixes`, `Misc`.

Use `git add -p` to stage by category; `scripts/reshape-commits.sh` splits a diff by file globs when categories map to whole files.

## Quality Standards

- All new code must compile with zero warnings under strict concurrency.
- All new functionality must have corresponding tests.
- All errors must be user-visible with actionable messages.
- No `// TODO`, `// FIXME`, or `// HACK` in committed code — fix it or file an issue.
- No dead code, unused imports, or commented-out code.
- No force-unwraps (`!`, `try!`, `fatalError`) in production — see Code Conventions → Error Handling → Force-unwraps forbidden.
