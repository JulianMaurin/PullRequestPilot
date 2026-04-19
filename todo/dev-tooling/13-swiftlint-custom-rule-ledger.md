# 13 — SwiftLint custom rule ledger

## Goal

Freeze the recurring bug classes by encoding them as lint rules that block CI. Audits keep re-finding the same categories in new code; only mechanical enforcement stops the regression.

## Evidence

- Group C summary: "Fragile audit loop … findings overlap heavily (HTTP error handling, Sendable, layer violations, dead code reappear in 3+ sessions). Suggests: bugs/violations regress between sessions or the audits are non-deterministic."
- Every Tier 1 plan references rules that belong here.

## Current state

- No `.swiftlint.yml` in the repo (as of last check — verify).
- SwiftLint is not a dependency; adding it is a small cost since it's a Homebrew install, not a SPM dep.

## Target design

### 1. Add SwiftLint

- Install via Homebrew (not SPM — keeps "no external dependencies" rule intact for runtime; dev-only tool is fine).
- `.swiftlint.yml` at repo root.
- `Makefile` target `make lint` runs `swiftlint --strict`.
- CI step (future) runs `make lint`.

### 2. Rule ledger

Each rule below is a custom regex-based SwiftLint rule. Name + rationale + regex.

```yaml
# .swiftlint.yml (excerpt)

custom_rules:
  force_unwrap_production:
    included: "PullRequestPilot/(?!Tests).*\\.swift"
    excluded: "PullRequestPilotTests"
    name: "Force-unwrap in production"
    regex: '(?<![a-zA-Z0-9_"])\![\s]*(?=[,)]|$)'
    message: "No force-unwraps in production. Use guard/if let. (See CLAUDE.md force-unwrap rule)"
    severity: error

  try_bang_forbidden:
    included: "PullRequestPilot/.*\\.swift"
    regex: '\btry![^A-Za-z_]'
    message: "No `try!` anywhere. Use do/try/catch."
    severity: error

  fatal_error_forbidden:
    regex: '\bfatalError\('
    message: "No fatalError in production. Throw or surface via EventCenter."
    severity: error

  precondition_failure_forbidden:
    regex: '\bpreconditionFailure\('
    message: "No preconditionFailure in production code."
    severity: error

  unchecked_sendable:
    regex: '@unchecked\s+Sendable'
    message: "No @unchecked Sendable. Use actor, @MainActor, or NSLock-backed Sendable."
    severity: error

  user_defaults_standard_outside_appstate:
    included: "PullRequestPilot/(Features|Infrastructure)/.*\\.swift"
    excluded: "PullRequestPilot/App/AppState\\.swift"
    regex: 'UserDefaults\.standard'
    message: "Use injected UserDefaults, not .standard."
    severity: error

  task_sleep_in_tests:
    included: "PullRequestPilotTests/.*\\.swift"
    regex: 'Task\.sleep'
    message: "No Task.sleep as synchronization in tests. Use waitForLoad()."
    severity: error

  is_pr_auto_injection:
    included: "PullRequestPilot/.*\\.swift"
    excluded: "PullRequestPilotTests"
    regex: '"is:\s*pr"'
    message: "Never auto-inject is:pr. See memory/feedback_no_is_pr_injection.md"
    severity: error

  try_without_log:
    # soft rule — warning; hard to perfect statically
    regex: '\btry\?\b'
    message: "try? silently swallows errors. Pair with os.Logger + EventCenter.post."
    severity: warning

  bare_catch_block:
    regex: 'catch\s*\{\s*\}'
    message: "Bare catch swallows all errors including CancellationError."
    severity: error

  cancellation_rethrow_hint:
    # warning, heuristic; real enforcement needs AST
    included: "PullRequestPilot/.*\\.swift"
    regex: 'catch\s*\{[^}]*(?!CancellationError)'
    message: "Async catch blocks must rethrow CancellationError."
    severity: warning

  subprocess_forbidden:
    regex: '(Process\(\)|NSTask|/bin/sh|/usr/bin/env)'
    message: "App Store sandbox forbids subprocess spawning."
    severity: error

  hardcoded_home_path:
    regex: '"(?:~|/tmp|/usr/local|/Users/)'
    message: "Sandbox-unsafe hardcoded path. Use NSOpenPanel or app group container."
    severity: error

  bang_delete_add_keychain:
    included: "PullRequestPilot/Infrastructure/Keychain/.*\\.swift"
    regex: 'SecItemDelete.*\n.*SecItemAdd'
    message: "Keychain writes must be atomic. Use SecItemUpdate, not Delete+Add."
    severity: error
    # (Multi-line matching requires SwiftLint's multi-line option enabled.)

  security_scoped_imbalance:
    # heuristic — flags startAccessing without stopAccessing in same file
    # (enforcement is advisory; see plan 10 for the proper helper)
    regex: 'startAccessingSecurityScopedResource'
    message: "Pair startAccessing with stopAccessing. Use LocalRepositoryService.withAccess."
    severity: warning

  dictionary_unique_keys_api_data:
    regex: 'Dictionary\(uniqueKeysWithValues:'
    message: "Dictionary(uniqueKeysWithValues:) crashes on duplicate keys. Use uniquingKeysWith:."
    severity: error

  subtitle_forbidden_terms:
    # doesn't really fit here — runs as part of metadata lint (plan 15)

  ui_appkit_observer_hint:
    included: "PullRequestPilot/Features/.*\\.swift"
    regex: 'NSWindowWillUpdateNotification'
    message: "Prefer SwiftUI scene modifiers over AppKit observers. (CLAUDE.md)"
    severity: warning
```

Not every rule can be expressed accurately with regex; mark those as `warning` and document in the rule message.

### 3. CI gate

- `make lint` must be green before merge.
- Separate target `make lint-errors-only` for developer iteration (hides warnings).

### 4. Maintenance

- Every new Tier 1 plan that encodes a rule should add a corresponding custom rule here.
- Prune rules only when they stop catching anything for 6 months.

## Implementation steps

### Step 1 — Add SwiftLint

**Files**
- New: `.swiftlint.yml` with the ruleset above.
- `Makefile` — add `lint` and `lint-errors-only` targets.
- `README.md` — add dev-setup section noting `brew install swiftlint`.

**Changes**
- Run `make lint` locally; triage current violations.

### Step 2 — First pass: fix all existing violations

**Changes**
- For each error, fix the code rather than disable the rule.
- If a rule is too noisy (> 20 false positives), downgrade to warning or refine the regex.

**Tests**
- `make lint` passes with `--strict`.

### Step 3 — Add to Makefile `test` and `build` workflows

**Files**
- `Makefile`

**Changes**
- `make build` depends on `make lint` (runs first; fails fast).
- `make test` also depends on `make lint`.

### Step 4 — Pre-commit hook (optional)

**Files**
- New: `.githooks/pre-commit`
- `Makefile` — `make install-hooks` target.

**Changes**
- Hook runs `swiftlint lint --quiet --strict` on staged Swift files.

### Step 5 — Follow-up: AST-based rules

Where regex is inadequate (cancellation-rethrow, for instance), add a thin SwiftSyntax-based rule as a follow-up plan. Not required in v1 of this plan — the warnings are enough to nudge.

## Risks

- **Developer friction** if the rule set is too aggressive. Start with the clear-cut ones marked `severity: error`; keep the fuzzy ones as `warning` until the false-positive rate is proven low.
- **Regex limitations** — some rules (e.g., catch-must-rethrow-CancellationError) cannot be reliably expressed via regex; accept warning-only status.
- **XcodeGen regeneration vs lint** — if SwiftLint runs before xcodegen and the project is out of sync, lint might skip files. Run xcodegen first (already the norm per CLAUDE.md + plan 15).

## Out of scope

- Adopting SwiftLint's full opt-in rule set — keep the ruleset small and targeted to *our* bugs.
- Building AST-based custom rules.

## Done criteria

- [ ] `.swiftlint.yml` checked in.
- [ ] `make lint` passes on the current codebase.
- [ ] `make build` and `make test` depend on `make lint`.
- [ ] Every Tier 1 plan's "encode as lint rule" bullet maps to a rule here.
