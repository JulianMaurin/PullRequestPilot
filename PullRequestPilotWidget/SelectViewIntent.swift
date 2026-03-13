import AppIntents
import WidgetKit

struct SelectViewIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Dashboard View"
    static let description = IntentDescription("Choose which dashboard view to display.")

    @Parameter(title: "Dashboard View")
    var dashboardView: DashboardViewEntity?
}
