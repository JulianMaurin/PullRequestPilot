# Contributing

Thanks for helping with Pull Request Pilot.

## Bugs and ideas

Open an [issue](https://github.com/JulianMaurin/PullRequestPilot/issues/new). For a bug, include the version (shown in Settings), your macOS version, what you did, and what happened. Security problems go through the [security policy](SECURITY.md) instead, never a public issue.

## Changes

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach before you write it.
2. Fork the repository and branch from `main`.
3. Make the change, with tests for any new behaviour: every change in behaviour comes with a Swift Testing test that fails without it.
4. Run `make build` and `make test`. Both must pass with no warnings; lint runs first.
5. Open a pull request against `main`. CI runs the same checks, plus CodeQL and a secret scan, and must pass before merge.

The maintainer reviews every pull request.

## Requirements

- **Setup**: Xcode 16 or later, `brew install xcodegen swiftlint`, and optionally `make hooks` to block commits that contain secrets.
- **Code**: Swift 6 with strict concurrency, SwiftUI, and no third-party dependencies. [`.swiftlint.yml`](../.swiftlint.yml) enforces the layering and the rules that keep shipped bugs from coming back.
- **Conventions**: the architecture, concurrency, error-handling and testing rules are in [`CLAUDE.md`](../CLAUDE.md). It's written for AI assistants, and it's also the project's style guide.
- **App Store**: the app is sandboxed and ships on the Mac App Store. Changes can't add subprocesses, private APIs or paths outside the sandbox, and a new entitlement needs an issue first.
- **Project file**: edit `project.yml`, then run `make generate`; never edit `PullRequestPilot.xcodeproj` by hand.
- **Commits**: one commit per change, titled `Fix: <Area> — …`, `Add: <Area> — …`, `Update: <Area> — …` or `Refactor: …`.

By contributing, you agree that your contribution is licensed under the [MIT license](../LICENSE).
