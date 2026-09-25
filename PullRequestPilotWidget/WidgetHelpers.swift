import SwiftUI

// MARK: - CI Status Icon

struct WidgetCheckStatusIcon: View {
    let status: CheckStatus?

    var body: some View {
        if let status {
            Image(systemName: status.symbolName)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(status.tint)
        }
    }
}

// MARK: - Age Badge

struct AgeBadge: View {
    let age: String

    var body: some View {
        Text(age)
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(.secondary)
    }
}

// MARK: - PR Row (reusable for medium/large)

struct PRRowView: View {
    let pr: WidgetPullRequest
    let showAuthor: Bool
    let showAge: Bool

    init(pr: WidgetPullRequest, showAuthor: Bool = false, showAge: Bool = false) {
        self.pr = pr
        self.showAuthor = showAuthor
        self.showAge = showAge
    }

    var body: some View {
        HStack(spacing: 6) {
            WidgetCheckStatusIcon(status: pr.checkStatus)

            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title)
                    .font(.system(size: 11))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(pr.repoShortName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)

                    if showAuthor {
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(pr.authorLogin)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            if showAge {
                AgeBadge(age: pr.compactAge)
            }
        }
    }
}

// MARK: - Last Updated Footer

struct LastUpdatedFooter: View {
    let date: Date

    var body: some View {
        Text("Updated \(date, style: .relative) ago")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Empty State

struct WidgetEmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
