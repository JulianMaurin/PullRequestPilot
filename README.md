# Pull Request Pilot

A native macOS menu bar app for monitoring GitHub pull request review queues. Built with SwiftUI, targeting macOS 14+ (Sonoma), Swift 6 with strict concurrency. Zero external dependencies.

## Features

**Custom dashboard views** — Create filtered views using any GitHub search query (e.g., `is:pr is:open review-requested:@me`). Switch between views with tabs. Queries are editable inline.

**Rich PR display** — Each pull request shows author avatar, title, review status, CI checks, comment threads (with unresolved count), labels, last activity, lines changed, and age. PRs are grouped by organization and repository with collapsible sections.

**PR stack detection** — Automatically detects stacked PRs (where one PR's base is another PR's head branch) and displays them as expandable chains.

**Local repository integration** — Configure directories containing your git repos in Settings. The app indexes branches, worktrees, and recent commit history in the background. Right-click a PR to:
- **Open in VS Code** — opens the matched local directory
- **Open in iTerm** — opens a new tab and `cd`s to the matched directory

Matching strategies (in priority order): exact branch name, worktree branch name, commit SHA in recent history.

**Auto-refresh** — Configurable intervals for both PR data refresh and local repo scanning.

**Menu bar app** — Lives in your menu bar. Closing the window hides it; click the status bar icon to bring it back.

**Launch at Login** — Optional, via Settings.

## Requirements

- macOS 14 (Sonoma) or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38+
- A GitHub Personal Access Token with the `repo` scope — [create one here](https://github.com/settings/tokens)

## Setup

```bash
git clone https://github.com/your-username/pull-request-pilot.git
cd pull-request-pilot
make build
```

On first launch, go to Settings and paste your GitHub token. Click **Save & Validate**.

### Development

Create a `.env` file at the project root:

```
GITHUB_TOKEN=ghp_your_token_here
```

Then run:

```bash
make debug    # Debug build + run (reads token from .env)
```

## Build Commands

```bash
make build      # Regenerate xcodeproj + Release build
make debug      # Debug build + run (sources .env for GITHUB_TOKEN)
make run        # Release build + run
make install    # Build + copy to /Applications
make uninstall  # Remove from /Applications
make test       # Run unit tests
make clean      # Clean build artifacts
```

## Architecture

MVVM with three layers. No external dependencies — pure Apple frameworks (URLSession, SwiftUI, Security).

```
Domain/Models/        Pure data models
Features/             View + ViewModel pairs (isolated per feature)
Infrastructure/       GitHub API, Keychain, Persistence, Local repo scanning
App/                  Entry point, DI composition root (AppState)
Shared/               Constants
```

**GitHub API** uses GraphQL for precise field selection and cursor-based pagination.

**Token storage** uses the macOS Keychain with an in-memory cache to avoid repeated permission prompts.

**Local repo indexing** runs off the main thread. The index maps repositories by remote URL, branches, worktrees, and recent commit SHAs — lookups at display time are pure in-memory with zero I/O.

## License

MIT
