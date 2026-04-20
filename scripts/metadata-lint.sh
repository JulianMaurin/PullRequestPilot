#!/bin/bash
# App Store metadata lint.
#
# Checks:
#   1. MARKETING_VERSION in project.yml is semver (X.Y.Z)
#   2. CURRENT_PROJECT_VERSION >= last tag's build number (warn if equal,
#      fail if lower)
#   3. metadata/appstore.yml subtitle — MUST be populated with the live
#      App Store Connect value, OR explicitly set to "<unset>" to declare
#      that no subtitle is live. An empty string is a hard failure because
#      the resulting silent-skip would hide the brand-term rejection
#      pattern that cost two prior submissions.
#      Populated values are checked for <= 30 chars and forbidden brand
#      terms from metadata/forbidden-terms.txt.
#   4. metadata/appstore.yml keywords — <= 100 chars total (App Store
#      hard limit). Same <unset>/empty contract as subtitle.
#   5. metadata/appstore.yml description — <= 4000 chars (App Store hard
#      limit). Same <unset>/empty contract; no forbidden-terms check
#      because product names are allowed in context.
#   6. CFBundleDisplayName (project.yml) — no forbidden brand terms
#   7. Privacy manifests exist for main app + widget
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
# Empty is a hard failure: an unchecked subtitle is exactly the silent-skip
# that hid the brand-term rejections on two prior submissions. The escape
# valve for apps with no live subtitle is the explicit "<unset>" sentinel,
# which forces a conscious decision and leaves an auditable trail.
SUBTITLE_SENTINEL_UNSET="<unset>"
if [[ -n "${SUBTITLE_OVERRIDE+x}" ]]; then
  # Explicitly-empty override is honoured (for testing the failure path).
  SUBTITLE="$SUBTITLE_OVERRIDE"
elif [[ -f metadata/appstore.yml ]]; then
  SUBTITLE=$(sed -nE 's/^subtitle:[[:space:]]*"([^"]*)".*/\1/p' metadata/appstore.yml | head -1)
else
  SUBTITLE=""
fi

if [[ -z "$SUBTITLE" ]]; then
  fail "subtitle in metadata/appstore.yml is empty — populate with the live App Store Connect value, or set to \"$SUBTITLE_SENTINEL_UNSET\" if no subtitle is live"
elif [[ "$SUBTITLE" == "$SUBTITLE_SENTINEL_UNSET" ]]; then
  ok "subtitle declared absent via $SUBTITLE_SENTINEL_UNSET sentinel — ensure App Store Connect listing has no subtitle"
else
  SUBTITLE_LEN=${#SUBTITLE}
  if (( SUBTITLE_LEN > 30 )); then
    fail "subtitle is $SUBTITLE_LEN chars (max 30): \"$SUBTITLE\""
  else
    ok "subtitle length $SUBTITLE_LEN/30"
  fi
  check_forbidden_terms "subtitle" "$SUBTITLE" || true
fi

# --- Keywords
if [[ -f metadata/appstore.yml ]]; then
  KEYWORDS=$(sed -nE 's/^keywords:[[:space:]]*"([^"]*)".*/\1/p' metadata/appstore.yml | head -1)
else
  KEYWORDS=""
fi

if [[ -z "$KEYWORDS" ]]; then
  fail "keywords in metadata/appstore.yml is empty — populate with the live value, or set to \"$SUBTITLE_SENTINEL_UNSET\" if no keywords are live"
elif [[ "$KEYWORDS" == "$SUBTITLE_SENTINEL_UNSET" ]]; then
  ok "keywords declared absent via $SUBTITLE_SENTINEL_UNSET sentinel"
else
  KEYWORDS_LEN=${#KEYWORDS}
  if (( KEYWORDS_LEN > 100 )); then
    fail "keywords is $KEYWORDS_LEN chars (max 100): \"$KEYWORDS\""
  else
    ok "keywords length $KEYWORDS_LEN/100"
  fi
fi

# --- Description
# Extracted from the `description: |` block literal. `awk` pulls the indented
# lines that follow until the first non-indented line (next top-level key).
if [[ -f metadata/appstore.yml ]]; then
  DESCRIPTION=$(awk '
    /^description:[[:space:]]*"<unset>"/ { print "<unset>"; exit }
    /^description:[[:space:]]*"/ {
      sub(/^description:[[:space:]]*"/, "")
      sub(/".*$/, "")
      print
      exit
    }
    /^description:[[:space:]]*\|/ { in_block = 1; next }
    in_block {
      if (/^[^[:space:]]/) exit
      sub(/^  /, "")
      print
    }
  ' metadata/appstore.yml)
else
  DESCRIPTION=""
fi

if [[ -z "$DESCRIPTION" ]]; then
  fail "description in metadata/appstore.yml is empty — populate with the live value, or set to \"$SUBTITLE_SENTINEL_UNSET\" if no description is live"
elif [[ "$DESCRIPTION" == "$SUBTITLE_SENTINEL_UNSET" ]]; then
  ok "description declared absent via $SUBTITLE_SENTINEL_UNSET sentinel"
else
  DESCRIPTION_LEN=${#DESCRIPTION}
  if (( DESCRIPTION_LEN > 4000 )); then
    fail "description is $DESCRIPTION_LEN chars (max 4000)"
  else
    ok "description length $DESCRIPTION_LEN/4000"
  fi
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
