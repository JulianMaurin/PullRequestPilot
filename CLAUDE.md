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

## Quality Standards

- All new code must compile with zero warnings under strict concurrency.
- All new functionality must have corresponding tests.
- All errors must be user-visible with actionable messages.
- No `// TODO`, `// FIXME`, or `// HACK` in committed code — fix it or file an issue.
- No dead code, unused imports, or commented-out code.
