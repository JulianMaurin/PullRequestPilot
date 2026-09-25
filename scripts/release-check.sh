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
WIDGET_PATH="$APP_PATH/Contents/PlugIns/PullRequestPilotWidgetExtension.appex"

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
if [[ ! -d "$WIDGET_PATH" ]]; then
  echo "✗ widget extension missing: $WIDGET_PATH" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ENTITLEMENTS_DIR=$(mktemp -d)
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT

# Every executable App Store Connect receives must be sandboxed and use the
# hardened runtime, the widget included.
check_bundle() {
  local bundle="$1" label="$2" plist="$ENTITLEMENTS_DIR/$2.plist" signature
  signature=$(codesign -dvv "$bundle" 2>&1)
  if grep -q 'flags=.*runtime' <<< "$signature"; then
    echo "✓ $label: hardened runtime enabled"
  else
    echo "✗ $label: hardened runtime NOT enabled — rejection risk" >&2
    exit 1
  fi
  if ! codesign -d --entitlements - --xml "$bundle" > "$plist" 2>/dev/null; then
    echo "✗ $label: could not read entitlements" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$plist" 2>/dev/null)" == "true" ]]; then
    echo "✓ $label: app sandbox enabled"
  else
    echo "✗ $label: app sandbox NOT enabled — rejection risk" >&2
    exit 1
  fi
}
check_bundle "$APP_PATH" "app"
check_bundle "$WIDGET_PATH" "widget"

# A widget entitlement the app doesn't have fails App Review.
entitlement_keys() { plutil -p "$1" | sed -nE 's/^  "([^"]+)" =>.*/\1/p'; }
APP_KEYS=$(entitlement_keys "$ENTITLEMENTS_DIR/app.plist")
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  if ! grep -qxF "$key" <<< "$APP_KEYS"; then
    echo "✗ widget has entitlement $key that the app lacks" >&2
    exit 1
  fi
done <<< "$(entitlement_keys "$ENTITLEMENTS_DIR/widget.plist")"
echo "✓ widget entitlements are a subset of the app's"

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
