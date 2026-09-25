import SwiftUI

struct PRDetailView: View {
    @Bindable var viewModel: PRDetailViewModel

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
                            PullRequestStateIconView(
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
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Refreshing")
                        .accessibilityLabel("Refreshing pull request details")
                }
                Button {
                    viewModel.deselect()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close pull request details")
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
                Button("Retry") {
                    viewModel.retry()
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !viewModel.reviewers.isEmpty {
                        reviewersSection
                        Divider()
                    }
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
                .scrollTargetLayout()
            }
            .scrollPosition(id: $viewModel.scrollAnchor)
        }
    }

    // MARK: - Reviewers Section

    private var reviewersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.isReviewersExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isReviewersExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text("Reviewers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(viewModel.isReviewersExpanded ? "Expanded" : "Collapsed")

            if viewModel.isReviewersExpanded {
                ForEach(viewModel.reviewers) { reviewer in
                    reviewerRow(reviewer)
                }
            }
        }
        .id("reviewers")
    }

    private func reviewerRow(_ reviewer: Reviewer) -> some View {
        HStack(spacing: 8) {
            CachedAvatarView(
                url: reviewer.avatarURL,
                size: 20,
                shape: reviewer.isTeam ? .roundedRect(cornerRadius: 4) : .circle,
                placeholder: reviewer.isTeam
                    ? AnyView(
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    )
                    : nil
            )

            Text(reviewer.displayName)
                .font(.caption)
                .lineLimit(1)

            if reviewer.isTeam {
                Text("team")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: reviewer.state.iconName)
                .font(.caption)
                .foregroundStyle(iconColor(reviewer.state.iconColor))

            Text(reviewer.state.label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Checks Section

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.isChecksExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isChecksExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text("Checks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    checksSummaryBadge
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(viewModel.isChecksExpanded ? "Expanded" : "Collapsed")

            if viewModel.isChecksExpanded {
                ForEach(viewModel.checkRuns) { check in
                    checkRow(check)
                    if check.id != viewModel.checkRuns.last?.id {
                        Divider()
                            .padding(.leading, 36)
                    }
                }
            }
        }
        .id("checks")
    }

    private var checksSummaryBadge: some View {
        let total = viewModel.checkRuns.count
        let passed = viewModel.checkRuns.filter { $0.conclusion == .success }.count
        return Text("\(passed)/\(total)")
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
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

            if check.isRequired {
                Text("Required")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

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

    /// No wrapping VStack: the header and rows must stay direct children of
    /// the enclosing LazyVStack, or every timeline row (up to 20 pages x 100
    /// events) is built eagerly the moment the section enters layout.
    @ViewBuilder
    private var timelineSection: some View {
        Text("Activity")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
            .id("activity")

        ForEach(viewModel.timelineEvents) { event in
            timelineRow(event)
                .id(event.id)
            if event.id != viewModel.timelineEvents.last?.id {
                Divider()
                    .padding(.leading, 36)
            }
        }
    }

    private func timelineRow(_ event: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                CachedAvatarView(url: event.actor?.avatarURL, size: 20)

                Image(systemName: event.iconName)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(iconColor(event.iconColor))
                    .padding(2)
                    .background(.background)
                    .clipShape(Circle())
                    .offset(x: 4, y: 4)
            }
            .frame(width: 24)
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

                if let body = event.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
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
