#!/bin/bash
# Purge per-bundle notification state so a reinstall behaves like a fresh
# install. macOS persists authorization state across three files that killall
# alone doesn't touch:
#   1. ~/Library/Preferences/com.apple.ncprefs.plist
#      apps array keyed by bundle-id; powers System Settings › Notifications
#      and the per-app toggles shown there.
#   2. ~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
#      usernoted's own prefs — the apps array here carries the `auth` field
#      that UNUserNotificationCenter.authorizationStatus returns. THIS is the
#      file that decides whether the app thinks it's authorized, and it
#      survives /Applications removal because it's keyed by bundle-id + a
#      cached designated-requirement blob.
#   3. ~/Library/Group Containers/group.com.apple.usernoted/db2/db
#      app table (+ trigger-cascaded record/requests/delivered tables) —
#      notification delivery history, not auth, but still per-bundle state.
#
# Daemons (cfprefsd, usernoted) cache all of this in memory, so we must kill
# them BEFORE editing and let them auto-start on next API call with fresh
# state. tccutil reset does NOT affect notifications — notifications aren't
# in the TCC subsystem.
#
# Usage: nuke-notifications.sh <bundle-id> [<bundle-id> ...]

set -o pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <bundle-id> [<bundle-id> ...]" >&2
    exit 1
fi

BUNDLES=("$@")
NCPREFS="$HOME/Library/Preferences/com.apple.ncprefs.plist"
USERNOTED_PLIST="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
USERNOTED_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"

# Remove bundle-id entries from an `apps` array in a plist. $1 is the plist
# path, remaining args are bundle IDs. Writes back in binary format and
# prints a count; no-ops if file missing or contains no matching entries.
prune_apps_plist() {
    local path="$1"; shift
    if [[ ! -f "$path" ]]; then
        echo "  $path not present; skipping"
        return
    fi
    python3 - "$path" "$@" <<'PY'
import plistlib, sys
path = sys.argv[1]
targets = set(sys.argv[2:])
try:
    with open(path, 'rb') as f:
        data = plistlib.load(f)
except Exception as e:
    print(f"  {path} unreadable ({e}); skipping", file=sys.stderr)
    sys.exit(0)
apps = data.get('apps', [])
kept = [a for a in apps if a.get('bundle-id') not in targets]
removed = len(apps) - len(kept)
if removed:
    data['apps'] = kept
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    print(f"  Removed {removed} entries from {path}")
else:
    print(f"  No matching entries in {path}")
PY
}

echo "Killing notification daemons before editing on-disk state..."
killall cfprefsd 2>/dev/null || true
killall usernoted 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true

# Give the kernel a moment to release file handles.
sleep 1

# Purge with one retry: launchd may respawn usernoted fast enough that it
# re-registers the bundle (via codesign / DR match against BTM's stale
# login-item record) before our edit lands. One verify-and-retry catches it.
for attempt in 1 2; do
    echo "Pruning ncprefs.plist (System Settings › Notifications list)..."
    prune_apps_plist "$NCPREFS" "${BUNDLES[@]}"

    echo "Pruning usernoted prefs (holds the auth field read by UNUserNotificationCenter)..."
    prune_apps_plist "$USERNOTED_PLIST" "${BUNDLES[@]}"

    sleep 1
    stuck=$(python3 - "$USERNOTED_PLIST" "${BUNDLES[@]}" <<'PY'
import plistlib, sys
path, targets = sys.argv[1], set(sys.argv[2:])
try:
    with open(path, 'rb') as f:
        data = plistlib.load(f)
except Exception:
    print(0); sys.exit(0)
print(sum(1 for a in data.get('apps', []) if a.get('bundle-id') in targets))
PY
)
    if [[ "$stuck" == "0" ]]; then
        break
    fi
    echo "  usernoted plist re-populated ($stuck entries) — killing daemons and retrying..."
    killall cfprefsd 2>/dev/null || true
    killall usernoted 2>/dev/null || true
    sleep 1
done

if [[ -f "$USERNOTED_DB" ]]; then
    echo "Removing usernoted db entries for: ${BUNDLES[*]}"
    # Bundle IDs come from the Makefile (not user input), so inlining is safe.
    # Reject anything that isn't a plain bundle-id to keep this script reusable.
    quoted=()
    for b in "${BUNDLES[@]}"; do
        if [[ ! "$b" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "  Refusing unsafe bundle id: $b" >&2
            exit 1
        fi
        quoted+=("'$b'")
    done
    list=$(IFS=,; echo "${quoted[*]}")
    # app_deleted trigger cascades to record/requests/delivered/displayed/snoozed/categories.
    removed=$(sqlite3 "$USERNOTED_DB" "DELETE FROM app WHERE identifier IN ($list) RETURNING identifier;" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$removed" != "0" ]]; then
        echo "  Removed $removed usernoted db entries"
    else
        echo "  No matching usernoted db entries"
    fi
else
    echo "  usernoted db not present; skipping"
fi

echo "Notification state purged — daemons will auto-start with fresh state."
