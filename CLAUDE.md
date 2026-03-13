# CLAUDE.md — Pull Request Pilot

## Project Overview

A native macOS menu bar/window app for monitoring GitHub pull request review queues. Built with SwiftUI, targeting macOS 14+ (Sonoma), Swift 6 with strict concurrency.

## Build & Run

A `Makefile` wraps all build commands. `DEVELOPER_DIR` is set automatically.

```bash
make build        # Regenerate xcodeproj + Release build
make debug        # Debug build + run (sources .env for GITHUB_TOKEN)
make run          # Release build + run
make install      # Build + copy to /Applications/Pull Request Pilot.app
make uninstall    # Remove from /Applications
make test         # Run unit tests
make clean        # Clean build artifacts
```

In debug builds, `TokenCache` reads `GITHUB_TOKEN` from the environment (`#if DEBUG`). Create a `.env` file at the project root and `make debug` will source it automatically.

```bash
# Open in Xcode
open PullRequestPilot.xcodeproj
```

**Always verify builds from the command line** (`make build`) after changes — don't rely on Xcode's index alone.

**Source of truth for project configuration is `project.yml` (XcodeGen).** Never edit `*.xcodeproj` files directly — regenerate with `xcodegen generate`.

**After creating or deleting any Swift file**, you MUST run `xcodegen generate` before building — otherwise the Xcode project won't include the new files and builds will fail with "cannot find type" errors.

**Stale Xcode errors**: If Xcode shows errors that don't reproduce on the command line (especially from `@Observable` macro-generated sources), clear DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData/PullRequestPilot-*`

**Stale test binaries**: `make test` builds and runs tests from DerivedData, not `.build/`. If you see crash dialogs ("Pull Request Pilot quit unexpectedly") during tests that don't match current source, clear DerivedData before re-running: `rm -rf ~/Library/Developer/Xcode/DerivedData/PullRequestPilot-*`

## Architecture

**MVVM + Clean Architecture** with three layers:

```
Domain/Models/        — Pure data models, no dependencies
Features/             — Feature modules (View + ViewModel pairs)
Infrastructure/       — External service adapters (GitHub API, Keychain, Persistence)
App/                  — App entry point, DI root (AppState), root navigation
Shared/               — Cross-cutting constants
```

**Dependency flow:** Domain ← Features ← Infrastructure. Features never import each other. Infrastructure never imports Features.

**Dependency injection:** All wiring happens in `AppState.swift` — the single composition root. ViewModels receive their dependencies via constructor injection.

## Code Conventions

### Swift & Concurrency

- **Swift 6** with `SWIFT_STRICT_CONCURRENCY: complete` — all concurrency warnings are errors. Every type crossing concurrency boundaries must be `Sendable`.
- **`@MainActor`** on all ViewModels and UI-bound classes.
- **`@Observable`** (Observation framework) for state — not `ObservableObject`/`@Published`.
- **`async/await`** exclusively — no completion handlers, no Combine for new code.
- **`Task` groups** for concurrent operations (e.g., refreshing multiple views).

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

### Error Handling

- Define error types as enums conforming to `LocalizedError` with user-facing `errorDescription`.
- Surface errors in UI — never silently swallow. Never force-unwrap or `try!` in production code.
- Use `do/catch` with typed errors at the call site.

### Testing

- **Swift Testing** framework (`@Suite`, `@Test`) — not XCTest for new tests.
- Protocol-based mocking: mock implementations of protocols (e.g., `MockGitHubClient`).
- Test files mirror source structure in `PullRequestPilotTests/`.
- Mock files go in `PullRequestPilotTests/Mocks/`.
- Use isolated `UserDefaults(suiteName:)` in tests — never touch real user defaults.
- **Empty stores in tests**: `ViewsStore` with fresh `UserDefaults` returns `[]` (`defaultViews` is empty). Tests must call `viewModel.addView(...)` before accessing `views.first` — never force-unwrap on data that depends on test setup.
- Test both success and error paths. Test edge cases (empty state, invalid input).

## Key Technical Decisions

- **GraphQL over REST** for GitHub API — single endpoint, precise field selection, cursor pagination.
- **Keychain** for token storage — never persist tokens in UserDefaults or files. Use `TokenCache` for in-memory caching — never read Keychain on every API call (causes repeated macOS permission prompts).
- **Status bar app** — `AppDelegate` owns the `NSStatusItem`. Window hides on close (via `WindowAccessor` intercepting `windowShouldClose`) instead of being destroyed, so the status bar icon can re-show it. Never remove the `@NSApplicationDelegateAdaptor` line.
- **No external dependencies** — everything uses Apple frameworks (URLSession, SwiftUI, Security). Keep it this way unless there's a compelling reason.
- **XcodeGen** for project generation — avoids `.xcodeproj` merge conflicts.

## Concurrency Pitfalls

- **`URLError.cancelled`** must be caught and rethrown as `CancellationError` in the network layer — otherwise it surfaces as a user-visible error when tasks are cancelled during normal operation (e.g., auto-refresh restart).
- **Auto-refresh**: `startAutoRefresh()` should be idempotent (no-op if already running) — calling `stopAutoRefresh()` first cancels in-flight network requests.

## File Guidelines

- New features go in `Features/<FeatureName>/` with their own View and ViewModel.
- New domain models go in `Domain/Models/`.
- New external service integrations go in `Infrastructure/<ServiceName>/`.
- DTOs (API response models) stay in Infrastructure — domain models must not know about wire formats.
- Keep views stateless — all logic and state belong in ViewModels.

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
- **Bump `CURRENT_PROJECT_VERSION`** (build number) for every new archive/upload. App Store Connect rejects duplicate build numbers.
- **`MARKETING_VERSION`** follows semver. Bump appropriately for releases.
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
- **Deep linking** — widgets use `pullrequestpilot://` URL scheme (registered in `Info.plist` via `project.yml`). `Link(destination:)` wraps PR rows for direct GitHub URL opening. `widgetURL` or `pullrequestpilot://view/<viewID>` navigates to a specific dashboard view in the app.

### Data & Persistence

- **UserDefaults for non-sensitive preferences only** — use the app group suite (`group.com.pullrequestpilot.shared`) for data shared with the widget.
- **Keychain for secrets** — tokens, credentials, and API keys must use the Keychain. Never log, print, or persist tokens in UserDefaults, files, or crash reports.
- **Never log sensitive data** — no token values, no full API responses containing user data. Use `os_log` with appropriate privacy levels (`%{private}@`) for any user-identifiable information.

### Build Verification Checklist

Before any PR that touches production code:
1. `make build` succeeds with zero warnings.
2. `make test` passes all tests.
3. App launches and completes core flows (auth, PR list, refresh, settings) in sandbox.
4. Widget renders correctly with both populated and empty data.
5. No new entitlements added without justification.
6. No `Process()`, shell commands, or file access outside sandbox.

## Quality Standards

- All new code must compile with zero warnings under strict concurrency.
- All new functionality must have corresponding tests.
- All errors must be user-visible with actionable messages.
- No `// TODO`, `// FIXME`, or `// HACK` in committed code — fix it or file an issue.
- No dead code, unused imports, or commented-out code.
- No force-unwraps (`!`), `try!`, or `fatalError()` in production code paths — these are instant crashes and App Store rejections.
