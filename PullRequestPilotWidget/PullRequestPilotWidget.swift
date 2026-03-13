import SwiftUI
import WidgetKit

// MARK: - Widget Bundle

@main
struct PullRequestPilotWidgets: WidgetBundle {
    var body: some Widget {
        SummaryWidget()
        ViewDetailWidget()
    }
}

// MARK: - Summary Timeline

struct SummaryEntry: TimelineEntry {
    let date: Date
    let views: [WidgetViewData]
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in _: Context) -> SummaryEntry {
        SummaryEntry(date: .now, views: [
            WidgetViewData(id: "1", title: "Review Requests", count: 5, pullRequests: []),
            WidgetViewData(id: "2", title: "My PRs", count: 3, pullRequests: []),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        if let data = WidgetData.load() {
            completion(SummaryEntry(date: data.lastUpdated, views: data.views))
        } else {
            completion(placeholder(in: context))
        }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let entry: SummaryEntry
        if let data = WidgetData.load() {
            entry = SummaryEntry(date: data.lastUpdated, views: data.views)
        } else {
            entry = SummaryEntry(date: .now, views: [])
        }
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// MARK: - Summary Widget

struct SummaryWidget: Widget {
    let kind = "PullRequestPilotSummary"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummaryProvider()) { entry in
            SummaryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("PR Overview")
        .description("Summary of all your dashboard views.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Summary Entry View

struct SummaryWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: SummaryEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SummarySmallView(entry: entry)
        case .systemLarge:
            SummaryLargeView(entry: entry)
        default:
            SummaryMediumView(entry: entry)
        }
    }
}

// MARK: - Summary Small

struct SummarySmallView: View {
    let entry: SummaryEntry

    private var totalCount: Int {
        entry.views.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(totalCount)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Pull Requests")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 4)

            if !entry.views.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(entry.views.prefix(3).enumerated()), id: \.element.id) { index, view in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetColors.accent(for: index).opacity(0.8))
                                .frame(width: 3, height: 12)
                            Text(view.title)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Spacer()
                            Text("\(view.count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.15, green: 0.15, blue: 0.35), Color(red: 0.1, green: 0.1, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Summary Medium

struct SummaryMediumView: View {
    let entry: SummaryEntry

    private var totalCount: Int {
        entry.views.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack(alignment: .center) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Pull Requests")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(totalCount)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                if entry.views.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        WidgetEmptyState(message: "Open Pull Request Pilot\nto load data")
                        Spacer()
                    }
                    Spacer()
                } else {
                    let columns = [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ]
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(entry.views.prefix(4).enumerated()), id: \.element.id) { index, viewData in
                            ViewCardCompact(viewData: viewData, accentColor: WidgetColors.accent(for: index))
                        }
                    }

                    Spacer(minLength: 0)

                    LastUpdatedFooter(date: entry.date)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Summary Large

struct SummaryLargeView: View {
    let entry: SummaryEntry

    private var totalCount: Int {
        entry.views.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack(alignment: .center) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Pull Requests")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(totalCount)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                if entry.views.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        WidgetEmptyState(message: "Open Pull Request Pilot\nto load data")
                        Spacer()
                    }
                    Spacer()
                } else {
                    ForEach(Array(entry.views.prefix(3).enumerated()), id: \.element.id) { index, viewData in
                        ViewSection(viewData: viewData, accentColor: WidgetColors.accent(for: index))
                        if index < min(entry.views.count, 3) - 1 {
                            Divider()
                        }
                    }

                    Spacer(minLength: 0)

                    LastUpdatedFooter(date: entry.date)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - View Card (compact, for medium)

private struct ViewCardCompact: View {
    let viewData: WidgetViewData
    let accentColor: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewData.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 3) {
                    Text("\(viewData.count)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))

                    if viewData.count > 0 {
                        ReviewBreakdownBar(viewData: viewData)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Review Breakdown Bar (tiny inline indicator)

private struct ReviewBreakdownBar: View {
    let viewData: WidgetViewData

    var body: some View {
        HStack(spacing: 2) {
            if viewData.approvedCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                    Text("\(viewData.approvedCount)")
                        .font(.system(size: 8, design: .rounded))
                }
                .foregroundStyle(.green)
            }
            if viewData.changesRequestedCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                    Text("\(viewData.changesRequestedCount)")
                        .font(.system(size: 8, design: .rounded))
                }
                .foregroundStyle(.red)
            }
            if viewData.pendingReviewCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "clock")
                        .font(.system(size: 7))
                    Text("\(viewData.pendingReviewCount)")
                        .font(.system(size: 8, design: .rounded))
                }
                .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - View Section (for large summary)

private struct ViewSection: View {
    let viewData: WidgetViewData
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section header
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 3, height: 14)

                Text(viewData.title)
                    .font(.system(size: 11, weight: .semibold))

                Spacer()

                Text("\(viewData.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            // Top PRs
            if viewData.pullRequests.isEmpty {
                Text("No pull requests")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 9)
            } else {
                ForEach(viewData.pullRequests.prefix(3)) { pr in
                    Link(destination: pr.url) {
                        HStack(spacing: 4) {
                            ReviewDecisionIcon(decision: pr.reviewDecision)
                            Text(pr.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            AgeBadge(age: pr.compactAge)
                        }
                    }
                    .padding(.leading, 9)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    SummaryWidget()
} timeline: {
    SummaryEntry(date: .now, views: [
        WidgetViewData(id: "1", title: "Review Requests", count: 5, pullRequests: []),
        WidgetViewData(id: "2", title: "My PRs", count: 2, pullRequests: []),
        WidgetViewData(id: "3", title: "Team PRs", count: 8, pullRequests: []),
    ])
}

#Preview("Medium", as: .systemMedium) {
    SummaryWidget()
} timeline: {
    SummaryEntry(date: .now, views: [
        WidgetViewData(id: "1", title: "Review Requests", count: 5, pullRequests: []),
        WidgetViewData(id: "2", title: "My PRs", count: 2, pullRequests: []),
        WidgetViewData(id: "3", title: "Team PRs", count: 8, pullRequests: []),
        WidgetViewData(id: "4", title: "Urgent", count: 1, pullRequests: []),
    ])
}
