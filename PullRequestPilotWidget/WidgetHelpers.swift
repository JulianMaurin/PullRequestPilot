import SwiftUI

// MARK: - Color Palette

enum WidgetColors {
    static let viewAccents: [Color] = [
        .blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint,
    ]

    static func accent(for index: Int) -> Color {
        viewAccents[index % viewAccents.count]
    }

    static func reviewColor(for decision: String?) -> Color {
        switch decision {
        case "APPROVED": .green
        case "CHANGES_REQUESTED": .red
        case "REVIEW_REQUIRED": .orange
        default: .secondary
        }
    }

    static func checkColor(for status: String?) -> Color {
        switch status {
        case "SUCCESS": .green
        case "FAILURE", "ERROR": .red
        case "PENDING", "EXPECTED": .orange
        default: .secondary
        }
    }
}

// MARK: - Review Decision Icon

struct ReviewDecisionIcon: View {
    let decision: String?

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(WidgetColors.reviewColor(for: decision))
    }

    private var iconName: String {
        switch decision {
        case "APPROVED": "checkmark.circle.fill"
        case "CHANGES_REQUESTED": "xmark.circle.fill"
        case "REVIEW_REQUIRED": "clock.fill"
        default: "circle.dashed"
        }
    }
}

// MARK: - Check Status Dot

struct CheckStatusDot: View {
    let status: String?

    var body: some View {
        Circle()
            .fill(WidgetColors.checkColor(for: status))
            .frame(width: 6, height: 6)
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
            ReviewDecisionIcon(decision: pr.reviewDecision)
            CheckStatusDot(status: pr.checkStatus)

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

            if pr.isDraft {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
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
