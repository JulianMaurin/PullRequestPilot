#!/bin/bash
# Split the current working-tree diff into one commit per category.
#
# Usage: scripts/reshape-commits.sh [--dry-run] <mapping.json>
#
# mapping.json format:
#   {
#     "categories": {
#       "<label>": {
#         "message": "<commit subject>",
#         "globs": ["<git pathspec>", ...]
#       },
#       ...
#     }
#   }
#
# Behaviour:
#   - Iterates categories in the order given.
#   - For each category, stages files matching its globs (using git's pathspec
#     syntax) from the working tree and creates a commit with "message" as the
#     subject. Skips the category if nothing matches.
#   - At the end, warns about any still-modified or untracked files that no
#     glob matched — these are left staged for you to review.
#
# Requires: jq (brew install jq)

set -euo pipefail

DRY=0
MAPPING=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help)
      sed -n '1,/^$/p' "$0" | sed -n '2,$p'
      exit 0
      ;;
    *) MAPPING="$arg" ;;
  esac
done

if [[ -z "$MAPPING" ]]; then
  echo "error: missing mapping file. Usage: $0 [--dry-run] <mapping.json>" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 2
fi

if [[ ! -f "$MAPPING" ]]; then
  echo "error: mapping file not found: $MAPPING" >&2
  exit 2
fi

# Require a clean index so we don't accidentally commit a user's staged work
# under the wrong category label.
if ! git diff --cached --quiet; then
  echo "error: index is not empty. Commit or reset staged changes first." >&2
  exit 2
fi

run() {
  if (( DRY )); then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

CATEGORIES=$(jq -r '.categories | keys_unsorted[]' "$MAPPING")

if [[ -z "$CATEGORIES" ]]; then
  echo "error: mapping has no categories" >&2
  exit 2
fi

while IFS= read -r label; do
  [[ -z "$label" ]] && continue
  MESSAGE=$(jq -r --arg k "$label" '.categories[$k].message' "$MAPPING")
  mapfile_compat=()
  while IFS= read -r g; do
    [[ -n "$g" ]] && mapfile_compat+=("$g")
  done < <(jq -r --arg k "$label" '.categories[$k].globs[]' "$MAPPING")

  if (( ${#mapfile_compat[@]} == 0 )); then
    echo "! category \"$label\" has no globs — skipping"
    continue
  fi

  echo
  echo "=== $label: ${MESSAGE}"
  echo "    globs: ${mapfile_compat[*]}"

  # Stage files matching any of the category's globs.
  MATCHED=$(git status --porcelain -- "${mapfile_compat[@]}" | awk '{print $2}')
  if [[ -z "$MATCHED" ]]; then
    echo "    (no matching changes)"
    continue
  fi
  echo "    files:"
  echo "$MATCHED" | sed 's/^/      /'

  run git add -- "${mapfile_compat[@]}"
  run git commit -m "$MESSAGE"
done <<< "$CATEGORIES"

echo
REMAINING=$(git status --porcelain)
if [[ -n "$REMAINING" ]]; then
  echo "! remaining uncategorized changes:"
  echo "$REMAINING" | sed 's/^/    /'
  exit 1
else
  echo "✓ all changes committed by category"
fi
