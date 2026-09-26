#!/bin/bash
# Pre-submission gate. Runs lint, test, metadata-lint, release build, and
# codesign verification. Prints a manual-steps checklist at the end.
# Exits non-zero on any failure.

set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { echo; echo "=== $* ==="; }

step "1/5  swiftlint --strict"
make lint

step "2/5  tests"
make test

step "3/5  metadata-lint"
make metadata-lint

step "4/5  release build"
make build

step "5/5  codesign verify"
make bundle-check

cat <<'CHECKLIST'

=== release-check: automated gates passed ===

Manual steps before submitting to App Store Connect:

  [ ] Smoke-test core flows (auth, PR list, refresh, settings, widget)
      with a fresh Keychain (make nuke).
  [ ] Bump MARKETING_VERSION above the last tag and CURRENT_PROJECT_VERSION
      above the last uploaded build (project.yml top-level settings.base).
  [ ] Update metadata/appstore.yml if the App Store Connect subtitle or
      promotional text changed.
  [ ] Capture or refresh screenshots (assets/*.png) if UI changed.
  [ ] Draft the "What's New" text for this build.
  [ ] Draft app-review notes if new capabilities were added.
  [ ] Tag the release (git tag vX.Y.Z && git push --tags) and attach the
      archive to the tagged release.
CHECKLIST
