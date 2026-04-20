#!/bin/bash
# App Store metadata lint.
#
# Checks:
#   1. MARKETING_VERSION in project.yml is semver (X.Y.Z)
#   2. CURRENT_PROJECT_VERSION >= last tag's build number (warn if equal,
#      fail if lower)
#   3. metadata/appstore.yml subtitle (if non-empty) — <= 30 chars, no
#      forbidden brand terms from metadata/forbidden-terms.txt
#   4. CFBundleDisplayName (project.yml) — no forbidden brand terms
#   5. Privacy manifests exist for main app + widget
#
# Env overrides (for tests):
#   SUBTITLE_OVERRIDE  — override subtitle (bypass metadata/appstore.yml)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0
WARN=0

fail() { echo "✗ $*" >&2; FAIL=$((FAIL+1)); }
warn() { echo "! $*" >&2; WARN=$((WARN+1)); }
ok()   { echo "✓ $*"; }

# --- Load forbidden terms
FORBIDDEN_FILE="metadata/forbidden-terms.txt"
if [[ ! -f "$FORBIDDEN_FILE" ]]; then
  fail "missing $FORBIDDEN_FILE"
  exit 1
fi
FORBIDDEN_TERMS=()
while IFS= read -r line; do
  [[ -z "$line" || "${line:0:1}" = "#" ]] && continue
  FORBIDDEN_TERMS+=("$line")
done < "$FORBIDDEN_FILE"

check_forbidden_terms() {
  # $1 = label (for messages), $2 = value
  local label="$1" value="$2" term hit=0
  for term in "${FORBIDDEN_TERMS[@]}"; do
    if echo "$value" | grep -iqw -- "$term"; then
      fail "$label contains forbidden term: \"$term\" (value: \"$value\")"
      hit=1
    fi
  done
  return $hit
}

# --- MARKETING_VERSION semver
MARKETING_VERSION=$(sed -nE 's/.*MARKETING_VERSION: "([^"]*)".*/\1/p' project.yml | head -1)
if [[ -z "$MARKETING_VERSION" ]]; then
  fail "MARKETING_VERSION not found in project.yml"
elif [[ ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "MARKETING_VERSION \"$MARKETING_VERSION\" is not semver (expected X.Y.Z)"
else
  ok "MARKETING_VERSION $MARKETING_VERSION (semver)"
fi

# --- CURRENT_PROJECT_VERSION monotonic
CURRENT_VERSION=$(sed -nE 's/.*CURRENT_PROJECT_VERSION: "([^"]*)".*/\1/p' project.yml | head -1)
if [[ -z "$CURRENT_VERSION" ]]; then
  fail "CURRENT_PROJECT_VERSION not found in project.yml"
elif [[ ! "$CURRENT_VERSION" =~ ^[0-9]+$ ]]; then
  fail "CURRENT_PROJECT_VERSION \"$CURRENT_VERSION\" is not an integer"
else
  LAST_TAG=$(git tag --sort=-v:refname 2>/dev/null | head -1 || true)
  if [[ -n "$LAST_TAG" ]]; then
    LAST_BUILD=$(git show "$LAST_TAG:project.yml" 2>/dev/null | sed -nE 's/.*CURRENT_PROJECT_VERSION: "([^"]*)".*/\1/p' | head -1 || true)
    if [[ -n "$LAST_BUILD" && "$LAST_BUILD" =~ ^[0-9]+$ ]]; then
      if (( CURRENT_VERSION < LAST_BUILD )); then
        fail "CURRENT_PROJECT_VERSION $CURRENT_VERSION is lower than $LAST_TAG ($LAST_BUILD)"
      elif (( CURRENT_VERSION == LAST_BUILD )); then
        warn "CURRENT_PROJECT_VERSION $CURRENT_VERSION matches $LAST_TAG — bump before next upload"
      else
        ok "CURRENT_PROJECT_VERSION $CURRENT_VERSION > $LAST_TAG ($LAST_BUILD)"
      fi
    else
      warn "could not read CURRENT_PROJECT_VERSION from $LAST_TAG"
    fi
  else
    warn "no git tags yet — skipping build-number monotonicity check"
  fi
fi

# --- Subtitle
SUBTITLE="${SUBTITLE_OVERRIDE:-}"
if [[ -z "$SUBTITLE" && -f metadata/appstore.yml ]]; then
  SUBTITLE=$(sed -nE 's/^subtitle:[[:space:]]*"([^"]*)".*/\1/p' metadata/appstore.yml | head -1)
fi

if [[ -z "$SUBTITLE" ]]; then
  warn "subtitle is empty in metadata/appstore.yml — skipping subtitle check"
else
  SUBTITLE_LEN=${#SUBTITLE}
  if (( SUBTITLE_LEN > 30 )); then
    fail "subtitle is $SUBTITLE_LEN chars (max 30): \"$SUBTITLE\""
  else
    ok "subtitle length $SUBTITLE_LEN/30"
  fi
  check_forbidden_terms "subtitle" "$SUBTITLE" || true
fi

# --- CFBundleDisplayName
DISPLAY_NAME=$(sed -nE 's/.*CFBundleDisplayName:[[:space:]]*(.*)/\1/p' project.yml | head -1 | sed 's/^"\(.*\)"$/\1/')
if [[ -n "$DISPLAY_NAME" ]]; then
  check_forbidden_terms "CFBundleDisplayName" "$DISPLAY_NAME" || true
fi

# --- Privacy manifests
for manifest in \
  PullRequestPilot/Resources/PrivacyInfo.xcprivacy \
  PullRequestPilotWidget/PrivacyInfo.xcprivacy; do
  if [[ -f "$manifest" ]]; then
    ok "privacy manifest present: $manifest"
  else
    fail "missing privacy manifest: $manifest"
  fi
done

echo
if (( FAIL > 0 )); then
  echo "metadata-lint: $FAIL error(s), $WARN warning(s)" >&2
  exit 1
elif (( WARN > 0 )); then
  echo "metadata-lint: clean ($WARN warning(s))"
else
  echo "metadata-lint: clean"
fi
