import SwiftUI
import WidgetKit

struct ViewCountEntry: TimelineEntry {
    let date: Date
    let views: [WidgetViewData]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ViewCountEntry {
        ViewCountEntry(
            date: .now,
            views: [WidgetViewData(id: "placeholder", title: "Review Requests", count: 3)]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ViewCountEntry) -> Void) {
        let entry: ViewCountEntry
        if let data = WidgetData.load() {
            entry = ViewCountEntry(date: data.lastUpdated, views: data.views)
        } else {
            entry = placeholder(in: context)
        }
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ViewCountEntry>) -> Void) {
        let entry: ViewCountEntry
        if let data = WidgetData.load() {
            entry = ViewCountEntry(date: data.lastUpdated, views: data.views)
        } else {
            entry = ViewCountEntry(date: .now, views: [])
        }
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }
}

// MARK: - Widget Views

struct SingleViewRow: View {
    let viewData: WidgetViewData

    var body: some View {
        HStack {
            Text(viewData.title)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text("\(viewData.count)")
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(viewData.count > 0 ? .primary : .secondary)
        }
    }
}

struct SmallWidgetView: View {
    let entry: ViewCountEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("PRs", systemImage: "pull.request")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entry.views.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.views.prefix(4), id: \.id) { viewData in
                    SingleViewRow(viewData: viewData)
                }
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct MediumWidgetView: View {
    let entry: ViewCountEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Pull Requests", systemImage: "pull.request")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !entry.views.isEmpty {
                    let total = entry.views.reduce(0) { $0 + $1.count }
                    Text("\(total) total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if entry.views.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("Open Pull Request Pilot to load data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                Spacer()
            } else {
                let columns = [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(entry.views.prefix(6), id: \.id) { viewData in
                        HStack {
                            Circle()
                                .fill(viewData.count > 0 ? Color.blue : Color.gray.opacity(0.3))
                                .frame(width: 6, height: 6)
                            Text(viewData.title)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(viewData.count)")
                                .font(.system(.caption, design: .rounded, weight: .bold))
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct PullRequestPilotWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: ViewCountEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget

@main
struct PullRequestPilotWidget: Widget {
    let kind = "PullRequestPilotWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            PullRequestPilotWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("PR Counts")
        .description("Shows pull request counts for each dashboard view.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    PullRequestPilotWidget()
} timeline: {
    ViewCountEntry(date: .now, views: [
        WidgetViewData(id: "1", title: "Review Requests", count: 5),
        WidgetViewData(id: "2", title: "My PRs", count: 2),
    ])
}

#Preview(as: .systemMedium) {
    PullRequestPilotWidget()
} timeline: {
    ViewCountEntry(date: .now, views: [
        WidgetViewData(id: "1", title: "Review Requests", count: 5),
        WidgetViewData(id: "2", title: "My PRs", count: 2),
        WidgetViewData(id: "3", title: "Team PRs", count: 8),
    ])
}
