# Security policy

## Supported versions

Fixes ship in the latest version on the Mac App Store. Older versions don't get updates.

## Reporting a vulnerability

Please report it privately through [GitHub's private vulnerability reporting](https://github.com/JulianMaurin/PullRequestPilot/security/advisories/new), not in a public issue.

Useful details: the version (Settings shows it), what an attacker could do, and the steps to reproduce. You'll get a reply within a week, and credit in the advisory if you'd like it.

Especially interesting:

- anything that exposes the GitHub token, which the app keeps only in the Keychain
- ways out of the App Sandbox, or access beyond the folders a user picked
- requests to hosts other than GitHub's, or user data leaving the Mac
