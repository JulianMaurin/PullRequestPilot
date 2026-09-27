---
name: release-review
description: Pre-release review of Pull Request Pilot. Checks every change since the last version tag for App Store compliance and test gaps, runs the release gate, and prepares the release text (version, App Store listing, website changelog, What's New). Run before uploading a build.
disable-model-invocation: true
---

# release-review

Reviews everything since the last version tag. `make release-check` covers what can be checked mechanically; this review covers what needs judgment, and prepares the text that ships with the release. Leaves its changes uncommitted.

## 1. Range

The last release is the newest `v*` tag (`git tag --sort=-creatordate`). Read `git log <tag>..HEAD --oneline`, then the diff file by file (`git diff <tag>..HEAD -- <file>`).

## 2. Release gate

Run `make release-check`: lint, tests, metadata-lint, Release build with warnings as errors, bundle-check. Fix every failure before going on.

Don't re-check by hand what it already enforces: force-unwraps, `fatalError`, subprocesses, sandbox-unsafe paths, deprecated APIs, subtitle and keyword terms, versions above the last tag, a declared reason for every required-reason API, widget entitlements within the app's.

## 3. Compliance the gate can't judge

For each changed file, against CLAUDE.md App Store and Identity & data:
- A new entitlement or capability: stop and discuss it with the user before anything else.
- A new required-reason API: the declared reason is the one that matches the use, in the right target's manifest.
- Logging: no token or user data with `privacy: .public`.
- Environment variables only under `#if DEBUG`; no private API, `dlopen`, or `performSelector` on private selectors.
- No placeholder or unfinished UI in a Release build.
- New network-dependent surfaces still work offline, with an invalid or revoked token, and while rate-limited.
- Widget changes keep timeline providers light and reload only when content changes.

Report each problem with file:line and why, then fix it.

## 4. Test gaps

For each changed source file, against CLAUDE.md Tests:
- New behaviour has tests for its success and error paths.
- Changed behaviour has updated tests.
- A test for a fix fails when the fix is reverted.

Add the missing tests, then run `make test`.

## 5. Release text

Draft each of these and let the user confirm before it lands:
- **Version:** propose the next `MARKETING_VERSION` from the changes (a user-visible feature is a minor bump, fixes only a patch) and bump `CURRENT_PROJECT_VERSION` in `project.yml`.
- **App Store listing:** `metadata/appstore.yml` mirrors App Store Connect; update the promotional text ("New in X.Y: …") and the description where the release changes what they say.
- **Website:** add the release to `docs/changelog.html`. `docs/` is published from `main`, so write it for users.
- **What's New:** draft it from the `Add:`, `Fix:` and `Update:` commits, in user terms; it is entered in App Store Connect by hand.

## 6. Summary

- Commits reviewed, and the gate result.
- Compliance problems found and fixed; any still open.
- Test gaps found and filled; any still open.
- Release text drafted, and the proposed version.
- Manual checks owed: the checklist `make release-check` prints, plus UI and system behaviour this release changed that tests can't reach.
