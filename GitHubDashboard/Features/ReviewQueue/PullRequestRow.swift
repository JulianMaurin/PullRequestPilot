import SwiftUI

struct PullRequestRow: View {
    let pullRequest: PullRequest

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator
            details
            Spacer()
            metadata
        }
        .padding(.vertical, 4)
    }

    // MARK: - Subviews

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .padding(.top, 5)
            .help(statusLabel)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(pullRequest.repository.nameWithOwner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("#\(pullRequest.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pullRequest.isDraft {
                    Text("Draft")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }

            Text(pullRequest.title)
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(pullRequest.author.login)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                labelTags
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(pullRequest.age)
                .font(.caption)
                .foregroundStyle(.secondary)

            diffStats
        }
    }

    private var diffStats: some View {
        HStack(spacing: 4) {
            Text("+\(pullRequest.additions)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
            Text("-\(pullRequest.deletions)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var labelTags: some View {
        let visibleLabels = Array(pullRequest.labels.prefix(3))
        if !visibleLabels.isEmpty {
            HStack(spacing: 4) {
                ForEach(visibleLabels, id: \.name) { label in
                    Text(label.name)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color(hex: label.color).opacity(0.2))
                        .foregroundStyle(Color(hex: label.color))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if pullRequest.isDraft { return .gray }
        switch pullRequest.reviewDecision {
        case .approved: return .green
        case .changesRequested: return .red
        case .reviewRequired, nil: return .orange
        }
    }

    private var statusLabel: String {
        if pullRequest.isDraft { return "Draft" }
        switch pullRequest.reviewDecision {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .reviewRequired, nil: return "Review required"
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
