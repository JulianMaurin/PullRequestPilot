# 15 — Build & xcodegen tooling cleanup

## Goal

Kill the recurring build-tooling friction: xcodegen forgotten after file add, DerivedData rot, Xcode/SourceKit ghost errors, verbose `xcodebuild` output flooding Claude's context, and App Store metadata pitfalls. Each of these cost cycles every session.

## Evidence

- **xcodegen forgotten**: multiple sessions. CLAUDE.md explicitly warns; still missed.
- **DerivedData nuke as ritual**: `rm -rf ~/Library/Developer/Xcode/DerivedData/PullRequestPilot-*` appears as a workaround 3+ times.
- **Xcode/SourceKit ghost errors**: 5+ self-reassurance moments in Group C alone.
- **Build noise in transcripts**: `make build` emits ~90KB of xcodebuild output; Group A noted this is huge context waste.
- **App Store subtitle rejections**: two consecutive submissions rejected on forbidden terms ("macOS", "GitHub").
- **Release artifact missing**: *"there is no the build as on v1.2.0"* — the release flow is manual and error-prone.

## Current state

- `Makefile` wraps xcodebuild commands.
- No automatic xcodegen-before-build hook.
- No metadata lint.
- Release flow is multi-step and partially manual.

## Target design

A set of small Makefile changes and two new scripts.

### 1. `make build` auto-runs xcodegen when stale

Add a dependency: the `PullRequestPilot.xcodeproj/project.pbxproj` target depends on `project.yml` AND on every `*.swift` file under tracked directories.

```makefile
PullRequestPilot.xcodeproj/project.pbxproj: project.yml $(shell find PullRequestPilot Shared PullRequestPilotTests PullRequestPilotWidget -type f -name '*.swift')
	xcodegen generate

build: PullRequestPilot.xcodeproj/project.pbxproj
	xcodebuild ... | scripts/xcb-filter.sh
```

Effect: adding/removing any `.swift` file automatically triggers xcodegen on next build.

### 2. `xcb-filter.sh` — terse xcodebuild output

Filter `xcodebuild` stdout to:
- Errors (ERROR, warning:, error:, linker).
- Build-phase summary lines (`** BUILD SUCCEEDED **`, `** TEST FAILED **`).
- Test names and pass/fail per test.

Drop:
- `CompileSwift ...`, `CompileC ...` per-file lines.
- `Note: ...`, `Indexing ...`.
- 90+% of the current noise.

Script can be a ~30-line awk/sed. Uses `xcpretty` if installed; fallback to the homegrown filter.

### 3. `make clean-deep` — full wipe

```makefile
clean-deep: clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/PullRequestPilot-*
	killall NotificationCenter || true
	rm -rf ~/Library/Caches/com.apple.dt.Xcode
```

Documented in CLAUDE.md as "when Xcode and reality diverge, run `make clean-deep`."

### 4. `make metadata-lint`

Checks `project.yml` / Info.plist / marketing materials for:
- Forbidden terms in subtitle (`macOS`, `Mac`, `iOS`, `iPhone`, `iPad`, `GitHub`, `Apple`).
- Subtitle length ≤ 30 characters (App Store constraint).
- `CURRENT_PROJECT_VERSION` greater than last Git tag (prevents duplicate build-number upload).
- `MARKETING_VERSION` is semver.
- Required privacy keys present if any new framework was added.

Runs in `make release-check`.

### 5. `make release-check`

Pre-submission gate. Runs:
1. `make lint`
2. `make test`
3. `make metadata-lint`
4. `make build` (Release config)
5. Verifies the archive opens with a valid `embedded.provisionprofile`.
6. Emits a checklist for manual steps (screenshots, what's new, app-review notes).

If any step fails, emit the specific file/line; do not proceed.

### 6. `/reshape-commits` helper (bash or Swift script)

Companion for plan 14's audit-and-fix skill. Takes a set of hunks and shapes them into category-labeled commits. Interactively or scripted via a category mapping file.

## Implementation steps

### Step 1 — Add dependency chain + xcb-filter

**Files**
- `Makefile`
- New: `scripts/xcb-filter.sh`

**Changes**
- As described above.
- Handle the `find` command gracefully when new files are staged but not yet tracked.

**Tests**
- Add a new `.swift` file; `make build` regenerates xcodeproj.
- Build output is <5% the size of raw xcodebuild output.

### Step 2 — `make clean-deep`

**Files**
- `Makefile`

**Changes**
- Target as described.

### Step 3 — `make metadata-lint`

**Files**
- New: `scripts/metadata-lint.sh` (or Swift CLI)
- `Makefile`

**Changes**
- Parse subtitle from `project.yml` (INFOPLIST_KEY_CFBundleDisplayName or similar — verify exact key).
- Checks listed in the design.
- Clear error messages with offending value.

**Tests**
- Seed a failing subtitle → script exits non-zero, prints the violation.

### Step 4 — `make release-check`

**Files**
- `Makefile`
- New: `scripts/release-check.sh`

**Changes**
- Orchestrates the checks; reports aggregated result.

### Step 5 — Document in CLAUDE.md

Apply `00-claude-md-improvements.md` Patch 5 (trust make build over Xcode), Patch 9 (metadata forbidden terms referencing `make metadata-lint`), plus insert:

```markdown
### Tooling cheatsheet

- `make build` — regenerates xcodeproj if needed, compiles Release.
- `make test` — runs Swift Testing suite.
- `make lint` — SwiftLint `--strict`.
- `make metadata-lint` — App Store subtitle/version/privacy checks.
- `make clean-deep` — wipes DerivedData + Xcode caches + NotificationCenter.
- `make release-check` — pre-submission gate (runs all the above + archive validation).
```

### Step 6 — `/reshape-commits`

**Files**
- New: `scripts/reshape-commits.sh` or `scripts/reshape_commits.swift`

**Changes**
- Takes a JSON mapping of file-globs → category labels.
- Stashes, applies hunks by category, commits with conventional-commit messages.

**Tests**
- Dry run against a real audit's diff.

## Risks

- **xcb-filter loses signal** — test with every test-failure/linker-error pattern to make sure the filter doesn't hide real errors.
- **`find` heuristic** vs xcodegen — finding every .swift file on every build is fast on this codebase but could slow down as it grows. Cache mtime in a stamp file.
- **`killall NotificationCenter`** will affect the user's other SwiftUI apps briefly. Document clearly; keep as opt-in for the "deep" clean only.
- **Metadata lint drift** — Apple changes App Store rules; keep the forbidden-terms list in a config file, not the script.

## Out of scope

- CI (GitHub Actions) — separate plan if/when CI is added.
- Swift Package Manager migration.

## Done criteria

- [ ] `make build` auto-runs xcodegen when stale.
- [ ] `xcb-filter.sh` in place; build output compact.
- [ ] `make clean-deep` implemented.
- [ ] `make metadata-lint` implemented + catches the two historical rejections (test fixture).
- [ ] `make release-check` implemented.
- [ ] CLAUDE.md updated with the tooling cheatsheet.
- [ ] `/reshape-commits` helper exists and tested on one audit diff.
