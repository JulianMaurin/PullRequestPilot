Review all commits since the last release and audit the codebase for App Store compliance and test coverage.

## Steps

### 1. Identify the last release

Find the most recent git tag (version tag). Use `git tag --sort=-creatordate` to list tags and pick the latest one. Show the tag name and date.

### 2. Gather all changes since that release

Run `git log <last-tag>..HEAD --oneline` to list all commits. Then run `git diff <last-tag>..HEAD` to get the full diff of changes.

### 3. App Store Compliance Audit

Review every changed file against the App Store rules from CLAUDE.md. Check for:

- **Sandbox violations**: any use of `Process()`, `NSTask`, `/bin/sh`, `/usr/bin/env`, subprocess spawning, `dlopen`, `NSBundle.load()`, runtime code loading
- **File access outside sandbox**: hardcoded paths like `~/`, `/tmp`, `/usr/local`; file access not through `NSOpenPanel` or app group containers
- **Private/undocumented APIs**: `@objc` selectors on private APIs, `performSelector` tricks, `IOKit` without entitlement
- **Environment variables in production**: `setenv`/`getenv` outside `#if DEBUG` blocks
- **Deprecated APIs**: usage of APIs deprecated in macOS 14+
- **Entitlement changes**: any new entitlements added without justification
- **Sensitive data logging**: tokens, credentials, or user data logged or printed without `%{private}@`
- **Force unwraps**: `!` force unwraps, `try!`, or `fatalError()` in production code paths
- **Incomplete/placeholder UI**: unfinished features not behind `#if DEBUG`
- **Privacy manifest**: new frameworks or SDKs that require a privacy manifest per Apple's list
- **Widget rules**: widget bundle ID prefix, entitlements subset, no heavy computation in timeline providers

Report each violation with file path, line number, and explanation.

### 4. Test Coverage Audit

For every changed or new source file (excluding test files), check whether corresponding tests exist and cover the changes:

- **New types/features**: do they have corresponding test files in `PullRequestPilotTests/`?
- **New public methods**: are they tested for both success and error paths?
- **Edge cases**: are empty states, invalid inputs, and error conditions tested?
- **Changed behavior**: do existing tests cover the modified behavior, or do they need updating?

List each gap with the source file and what tests are missing.

### 5. Fix issues

If you found compliance violations or missing tests:

1. Fix all App Store compliance violations first. These are blocking for release.
2. Add missing tests for new/changed code. Follow the project conventions: Swift Testing framework (`@Suite`, `@Test`), protocol-based mocking, isolated `UserDefaults`.
3. Run `make build` to verify zero warnings.
4. Run `make test` to verify all tests pass.

### 6. Summary

Provide a summary with:
- Number of commits reviewed
- Compliance issues found (and fixed)
- Test coverage gaps found (and fixed)
- Any remaining concerns or recommendations
