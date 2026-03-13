import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct ViewDetailEntry: TimelineEntry {
    let date: Date
    let viewData: WidgetViewData?
}

// MARK: - Timeline Provider

struct ViewDetailProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> ViewDetailEntry {
        ViewDetailEntry(date: .now, viewData: WidgetViewData(
            id: "placeholder",
            title: "Review Requests",
            count: 3,
            pullRequests: [
                WidgetPullRequest(
                    id: "1", number: 42, title: "Add user authentication",
                    url: URL(string: "https://github.com")!,
                    repositoryName: "org/repo", authorLogin: "dev",
                    createdAt: .now.addingTimeInterval(-7200),
                    reviewDecision: "APPROVED", checkStatus: "SUCCESS", isDraft: false
                ),
            ]
        ))
    }

    func snapshot(for configuration: SelectViewIntent, in context: Context) async -> ViewDetailEntry {
        let data = WidgetData.load()
        let view = resolveView(from: data, configuration: configuration)
        return ViewDetailEntry(date: data?.lastUpdated ?? .now, viewData: view)
    }

    func timeline(for configuration: SelectViewIntent, in context: Context) async -> Timeline<ViewDetailEntry> {
        let data = WidgetData.load()
        let view = resolveView(from: data, configuration: configuration)
        let entry = ViewDetailEntry(date: data?.lastUpdated ?? .now, viewData: view)
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func resolveView(from data: WidgetData?, configuration: SelectViewIntent) -> WidgetViewData? {
        guard let data else { return nil }
        if let selectedID = configuration.dashboardView?.id {
            return data.views.first { $0.id == selectedID }
        }
        return data.views.first
    }
}

// MARK: - Widget

struct ViewDetailWidget: Widget {
    let kind = "PullRequestPilotViewDetail"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectViewIntent.self, provider: ViewDetailProvider()) { entry in
            ViewDetailEntryView(entry: entry)
        }
        .configurationDisplayName("PR View")
        .description("Shows pull requests for a specific dashboard view.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry View

struct ViewDetailEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: ViewDetailEntry

    var body: some View {
        if let viewData = entry.viewData {
            switch family {
            case .systemSmall:
                DetailSmallView(viewData: viewData, lastUpdated: entry.date)
            case .systemLarge:
                DetailLargeView(viewData: viewData, lastUpdated: entry.date)
            default:
                DetailMediumView(viewData: viewData, lastUpdated: entry.date)
            }
        } else {
            noDataView
        }
    }

    private var noDataView: some View {
        VStack(spacing: 4) {
            WidgetEmptyState(message: "Open Pull Request Pilot\nand select a view to configure")
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Detail Small

struct DetailSmallView: View {
    let viewData: WidgetViewData
    let lastUpdated: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 4) {
                Text(viewData.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(viewData.count)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
            }

            Divider()

            if viewData.pullRequests.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No PRs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewData.pullRequests.prefix(3)) { pr in
                        HStack(spacing: 4) {
                            ReviewDecisionIcon(decision: pr.reviewDecision)
                            Text(pr.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            LastUpdatedFooter(date: lastUpdated)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Detail Medium

struct DetailMediumView: View {
    let viewData: WidgetViewData
    let lastUpdated: Date

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 3) {
                // Header
                HStack(alignment: .center) {
                    Text(viewData.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()

                    ReviewSummaryPills(viewData: viewData)

                    Text("\(viewData.count)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }

                Divider()

                if viewData.pullRequests.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("No pull requests")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewData.pullRequests.prefix(4)) { pr in
                            Link(destination: pr.url) {
                                PRRowView(pr: pr)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                    LastUpdatedFooter(date: lastUpdated)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Detail Large

struct DetailLargeView: View {
    let viewData: WidgetViewData
    let lastUpdated: Date

    private let maxPRs = 7

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack(alignment: .center) {
                    Text(viewData.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()

                    ReviewSummaryPills(viewData: viewData)

                    Text("\(viewData.count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }

                Divider()

                if viewData.pullRequests.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        WidgetEmptyState(message: "No pull requests")
                        Spacer()
                    }
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(viewData.pullRequests.prefix(maxPRs)) { pr in
                            Link(destination: pr.url) {
                                PRRowView(pr: pr, showAuthor: true, showAge: true)
                            }
                            if pr.id != viewData.pullRequests.prefix(maxPRs).last?.id {
                                Divider()
                                    .padding(.leading, 22)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    HStack {
                        LastUpdatedFooter(date: lastUpdated)
                        Spacer()
                        if viewData.count > maxPRs {
                            Text("+\(viewData.count - maxPRs) more")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Review Summary Pills

private struct ReviewSummaryPills: View {
    let viewData: WidgetViewData

    var body: some View {
        HStack(spacing: 6) {
            if viewData.approvedCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                    Text("\(viewData.approvedCount)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.green)
            }
            if viewData.changesRequestedCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                    Text("\(viewData.changesRequestedCount)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Previews

private let samplePRs: [WidgetPullRequest] = [
    WidgetPullRequest(
        id: "1", number: 142, title: "Add OAuth2 authentication flow",
        url: URL(string: "https://github.com/org/repo/pull/142")!,
        repositoryName: "org/api-service", authorLogin: "alice",
        createdAt: .now.addingTimeInterval(-3600),
        reviewDecision: "APPROVED", checkStatus: "SUCCESS", isDraft: false
    ),
    WidgetPullRequest(
        id: "2", number: 87, title: "Fix race condition in queue processor",
        url: URL(string: "https://github.com/org/repo/pull/87")!,
        repositoryName: "org/worker", authorLogin: "bob",
        createdAt: .now.addingTimeInterval(-86400),
        reviewDecision: "CHANGES_REQUESTED", checkStatus: "FAILURE", isDraft: false
    ),
    WidgetPullRequest(
        id: "3", number: 231, title: "Update dependencies to latest versions",
        url: URL(string: "https://github.com/org/repo/pull/231")!,
        repositoryName: "org/frontend", authorLogin: "carol",
        createdAt: .now.addingTimeInterval(-172800),
        reviewDecision: nil, checkStatus: "PENDING", isDraft: false
    ),
    WidgetPullRequest(
        id: "4", number: 55, title: "Refactor database migration scripts",
        url: URL(string: "https://github.com/org/repo/pull/55")!,
        repositoryName: "org/infra", authorLogin: "dave",
        createdAt: .now.addingTimeInterval(-259200),
        reviewDecision: "REVIEW_REQUIRED", checkStatus: "SUCCESS", isDraft: true
    ),
    WidgetPullRequest(
        id: "5", number: 99, title: "Add comprehensive logging for API calls",
        url: URL(string: "https://github.com/org/repo/pull/99")!,
        repositoryName: "org/api-service", authorLogin: "eve",
        createdAt: .now.addingTimeInterval(-7200),
        reviewDecision: "APPROVED", checkStatus: "SUCCESS", isDraft: false
    ),
]

#Preview("Detail Small", as: .systemSmall) {
    ViewDetailWidget()
} timeline: {
    ViewDetailEntry(date: .now, viewData: WidgetViewData(
        id: "1", title: "Review Requests", count: 5, pullRequests: samplePRs
    ))
}

#Preview("Detail Medium", as: .systemMedium) {
    ViewDetailWidget()
} timeline: {
    ViewDetailEntry(date: .now, viewData: WidgetViewData(
        id: "1", title: "Review Requests", count: 5, pullRequests: samplePRs
    ))
}

#Preview("Detail Large", as: .systemLarge) {
    ViewDetailWidget()
} timeline: {
    ViewDetailEntry(date: .now, viewData: WidgetViewData(
        id: "1", title: "Review Requests", count: 8, pullRequests: samplePRs
    ))
}
