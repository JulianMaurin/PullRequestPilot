#!/bin/bash
# Pre-submission gate. Runs lint, test, metadata-lint, release build, and
# codesign verification. Prints a manual-steps checklist at the end.
# Exits non-zero on any failure.

set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR=".build"
BUNDLE_NAME="PullRequestPilot.app"
CONFIG="Release"
APP_PATH="$BUILD_DIR/$CONFIG/$BUNDLE_NAME"

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
if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ build bundle missing: $APP_PATH" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
# Hardened runtime check
if codesign -dvv "$APP_PATH" 2>&1 | grep -q 'flags=.*runtime'; then
  echo "✓ hardened runtime enabled"
else
  echo "✗ hardened runtime NOT enabled — rejection risk" >&2
  exit 1
fi
# Sandbox check
if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q 'com.apple.security.app-sandbox.*true'; then
  echo "✓ app sandbox enabled"
else
  echo "✗ app sandbox NOT enabled — rejection risk" >&2
  exit 1
fi

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
