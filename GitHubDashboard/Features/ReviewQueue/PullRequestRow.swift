import SwiftUI

struct PullRequestRow: View {
    let pullRequest: PullRequest
    var stackSize: Int = 0
    var onToggleStack: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stackBadge
            authorAvatar
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                detailRow
            }
            Spacer()
            metadata
        }
        .padding(.vertical, 4)
    }

    // MARK: - Subviews

    private var authorAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: pullRequest.author.avatarURL) { image in
                image.resizable()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                .help(statusLabel)
        }
        .padding(.top, 2)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(pullRequest.title)
                .font(.body)
                .lineLimit(2)

            if pullRequest.isDraft {
                Text("Draft")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
        }
    }

    private var detailRow: some View {
        HStack(spacing: 8) {
            Text(pullRequest.author.login)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("#\(pullRequest.number)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            statusBadge

            labelTags
        }
    }

    private var statusBadge: some View {
        Group {
            if !pullRequest.isDraft, pullRequest.reviewDecision != nil {
                Text(statusLabel)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
            }
        }
    }

    private var isStacked: Bool { stackSize > 1 }

    private var stackBadge: some View {
        Button(action: onToggleStack) {
            ZStack {
                Image(systemName: "square.stack.3d.up")
                    .font(.caption)
                if isStacked {
                    Text("\(stackSize)")
                        .font(.system(size: 7, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 12, height: 12)
                        .background(Color.purple)
                        .clipShape(Circle())
                        .offset(x: 7, y: -7)
                }
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(isStacked ? Color.purple : Color.gray.opacity(0.3))
        }
        .buttonStyle(.plain)
        .disabled(!isStacked)
        .help(isStacked ? "Stacked PRs — click to expand" : "Not stacked")
        .padding(.top, 4)
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
