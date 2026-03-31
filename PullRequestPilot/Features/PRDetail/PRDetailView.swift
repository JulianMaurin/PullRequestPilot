import SwiftUI

struct PRDetailView: View {
    let viewModel: PRDetailViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            detailContent
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let pr = viewModel.selectedPR {
                        HStack(spacing: 6) {
                            PullRequestStateIcon(
                                state: pr.state,
                                isDraft: pr.isDraft,
                                size: 14
                            )
                            Text(pr.title)
                                .font(.headline)
                                .lineLimit(3)
                        }
                        HStack(spacing: 6) {
                            Text(pr.repository.nameWithOwner)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: "#\(pr.number)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("by \(pr.author.login)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button {
                    viewModel.deselect()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var detailContent: some View {
        if viewModel.isLoading {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Loading...")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.error != nil {
            VStack(spacing: 8) {
                Spacer()
                if viewModel.isNetworkError {
                    Image(systemName: "wifi.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No Connection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(viewModel.error ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !viewModel.checkRuns.isEmpty {
                        checksSection
                    }
                    if !viewModel.timelineEvents.isEmpty {
                        if !viewModel.checkRuns.isEmpty {
                            Divider()
                        }
                        timelineSection
                    }
                }
            }
        }
    }

    // MARK: - Checks Section

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Checks")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ForEach(viewModel.checkRuns) { check in
                checkRow(check)
                if check.id != viewModel.checkRuns.last?.id {
                    Divider()
                        .padding(.leading, 36)
                }
            }
        }
    }

    @State private var hoveredCheckRunID: String?

    private func checkRow(_ check: CheckRun) -> some View {
        let isHovered = hoveredCheckRunID == check.id
        let hasLink = check.detailsURL != nil

        return HStack(spacing: 8) {
            Image(systemName: check.iconName)
                .font(check.status == .inProgress && check.conclusion == nil ? .system(size: 7) : .caption)
                .foregroundStyle(iconColor(check.iconColor))
                .frame(width: 20, alignment: .center)

            Text(check.name)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text(check.displayStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isHovered && hasLink ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredCheckRunID = hovering ? check.id : nil
        }
        .contextMenu {
            if let url = check.detailsURL {
                Button("Open in Browser") {
                    NSWorkspace.shared.open(url)
                }
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
        .onTapGesture(count: 2) {
            if let url = check.detailsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Timeline Section

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ForEach(viewModel.timelineEvents) { event in
                timelineRow(event)
                if event.id != viewModel.timelineEvents.last?.id {
                    Divider()
                        .padding(.leading, 36)
                }
            }
        }
    }

    private func timelineRow(_ event: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.iconName)
                .font(.caption)
                .foregroundStyle(iconColor(event.iconColor))
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.label)
                        .font(.caption)

                    Spacer()

                    Text(event.timestampText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func iconColor(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "red": return .red
        case "purple": return .purple
        case "blue": return .blue
        case "yellow": return .yellow
        case "gray": return .gray
        default: return .secondary
        }
    }
}
