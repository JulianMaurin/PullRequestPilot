#!/bin/bash
# Verifies what App Review checks on the built bundle: a valid signature, and
# the hardened runtime and app sandbox on both the app and its widget, whose
# entitlements must be a subset of the app's. Works on ad-hoc signed builds,
# so CI runs it without a signing identity.
#
# Usage: scripts/bundle-check.sh <path/to/PullRequestPilot.app>

set -eo pipefail

APP_PATH="${1:?usage: scripts/bundle-check.sh <path/to/PullRequestPilot.app>}"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/PullRequestPilotWidgetExtension.appex"

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
