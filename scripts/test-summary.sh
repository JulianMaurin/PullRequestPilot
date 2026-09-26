#!/bin/bash
# Renders a test result bundle as Markdown: counts, failed tests, and line
# coverage of the shipped targets. CI appends it to the job summary.
#
# Usage: scripts/test-summary.sh [path/to/TestResults.xcresult]

set -euo pipefail

RESULTS="${1:-.build/TestResults.xcresult}"

echo "## Unit tests"
echo
if [[ ! -d "$RESULTS" ]]; then
  echo "No result bundle at \`$RESULTS\`: the build failed before tests ran."
  exit 0
fi

SUMMARY=$(xcrun xcresulttool get test-results summary --path "$RESULTS")

jq -r '
  (if .result == "Passed" then "✅ **Passed**" else "❌ **\(.result)**" end)
  + " — \(.passedTests) passed, \(.skippedTests) skipped, \(.failedTests) failed"
  + " (\(.totalTestCount) tests, \((.finishTime - .startTime) * 10 | round / 10) s)"
' <<< "$SUMMARY"

if [[ "$(jq '.testFailures | length' <<< "$SUMMARY")" != "0" ]]; then
  echo
  echo "| Failed test | Issue |"
  echo "|---|---|"
  jq -r '
    .testFailures[]
    | (.failureText | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|")) as $issue
    | "| `\(.testIdentifierString)` | \(if ($issue | length) > 300 then $issue[:300] + "…" else $issue end) |"
  ' <<< "$SUMMARY"
fi

echo
echo "### Line coverage"
echo
echo "| Target | Coverage | Lines |"
echo "|---|--:|--:|"
xcrun xccov view --report --json "$RESULTS" | jq -r '
  .targets[]
  | select(.name | endswith(".xctest") | not)
  | "| \(.name) | \(.lineCoverage * 1000 | round / 10) % | \(.coveredLines) / \(.executableLines) |"
'
