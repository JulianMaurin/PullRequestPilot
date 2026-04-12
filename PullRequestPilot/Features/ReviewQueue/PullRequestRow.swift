import SwiftUI

struct PullRequestRow<RowMenu: View>: View {
    let pullRequest: PullRequest
    var stackSize: Int = 0
    var now: Date = .now
    var onToggleStack: () -> Void = {}
    var onFilterBy: ((String) -> Void)?
    @ViewBuilder var rowContextMenu: () -> RowMenu

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stackBadge
            authorAvatar
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                detailRow
                activityRow
            }
            Spacer()
            metadata
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            rowContextMenu()
            if let onFilterBy {
                Divider()
                filterMenuItems(onFilterBy)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [pullRequest.title]
        parts.append("by \(pullRequest.author.login)")
        parts.append("number \(pullRequest.number)")
        parts.append(statusLabel)
        if pullRequest.isDraft { parts.append("draft") }
        if stackSize > 1 { parts.append("\(stackSize) stacked pull requests") }
        parts.append("plus \(pullRequest.additions) minus \(pullRequest.deletions)")
        return parts.joined(separator: ", ")
    }

    // MARK: - Filter Menu

    @ViewBuilder
    private func filterMenuItems(_ onFilterBy: @escaping (String) -> Void) -> some View {
        Button {
            onFilterBy("author:\(pullRequest.author.login)")
        } label: {
            SwiftUI.Label(
                "Filter by author \"\(pullRequest.author.login)\"",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }

        if pullRequest.labels.count == 1, let label = pullRequest.labels.first {
            Button {
                let value = label.name.contains(" ") ? "\"\(label.name)\"" : label.name
                onFilterBy("label:\(value)")
            } label: {
                SwiftUI.Label(
                    "Filter by label \"\(label.name)\"",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
        } else if pullRequest.labels.count > 1 {
            Menu {
                ForEach(Array(pullRequest.labels.prefix(10)), id: \.name) { label in
                    Button {
                        let value = label.name.contains(" ") ? "\"\(label.name)\"" : label.name
                        onFilterBy("label:\(value)")
                    } label: {
                        SwiftUI.Label(
                            label.name,
                            systemImage: "tag"
                        )
                    }
                }
            } label: {
                SwiftUI.Label("Filter by label", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    // MARK: - Subviews

    private var authorAvatar: some View {
        CachedAvatarView(url: pullRequest.author.avatarURL, size: 32)
            .padding(.top, 2)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            statusIndicator
                .help(stateLabel)
            Text(pullRequest.title)
                .font(.body)
                .lineLimit(2)

            checkStatusBadge

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

            Text(verbatim: "#\(pullRequest.number)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            threadsBadge

            labelTags
        }
    }

    @ViewBuilder
    private var activityRow: some View {
        if let activity = pullRequest.lastActivity {
            HStack(spacing: 4) {
                CachedAvatarView(url: activity.actor?.avatarURL, size: 14)

                Image(systemName: activity.kind.iconName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(activity.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(activity.timestampText(relativeTo: now))
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private var statusIndicator: some View {
        PullRequestStateIcon(
            state: pullRequest.state,
            isDraft: pullRequest.isDraft,
            size: 10
        )
    }

    @ViewBuilder
    private var checkStatusBadge: some View {
        if let icon = checkStatusIcon {
            let isPending = icon.name == "circle.fill"
            Image(systemName: icon.name)
                .font(isPending ? .system(size: 6) : .caption2.weight(.bold))
                .foregroundStyle(icon.color)
                .help(checkStatusLabel)
        }
    }

    @ViewBuilder
    private var threadsBadge: some View {
        if pullRequest.totalThreads > 0 {
            HStack(spacing: 3) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                if pullRequest.unresolvedThreads > 0 {
                    Text("\(pullRequest.unresolvedThreads)/\(pullRequest.totalThreads)")
                        .font(.caption2)
                } else {
                    Text("\(pullRequest.totalThreads)")
                        .font(.caption2)
                }
            }
            .foregroundStyle(pullRequest.unresolvedThreads > 0 ? Color.orange : Color.gray)
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
        .accessibilityLabel(isStacked ? "\(stackSize) stacked pull requests" : "Not stacked")
        .accessibilityHint(isStacked ? "Click to expand stacked pull requests" : "")
        .padding(.top, 4)
    }

    private var metadata: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(pullRequest.age(relativeTo: now))
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

    private var checkStatusIcon: (name: String, color: Color)? {
        switch pullRequest.checkStatus {
        case .success: return ("checkmark", .blue)
        case .pending, .expected: return ("circle.fill", .yellow)
        case .failure, .error: return ("xmark", .red)
        case nil: return nil
        }
    }

    private var stateLabel: String {
        switch pullRequest.state {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .open: return pullRequest.isDraft ? "Draft" : "Open"
        }
    }

    private var checkStatusLabel: String {
        switch pullRequest.checkStatus {
        case .pending, .expected: return "Checks running"
        case .failure, .error: return "Checks failing"
        case .success: return "Checks passing"
        case nil: return "No checks"
        }
    }

    private var statusLabel: String {
        "\(stateLabel) · \(checkStatusLabel)"
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 else {
            self.init(white: 0.5)
            return
        }
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
