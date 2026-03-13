import AppIntents

struct DashboardViewEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dashboard View")
    static let defaultQuery = DashboardViewQuery()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct DashboardViewQuery: EntityQuery, Sendable {
    func entities(for identifiers: [String]) async throws -> [DashboardViewEntity] {
        let all = allEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DashboardViewEntity] {
        allEntities()
    }

    func defaultResult() async -> DashboardViewEntity? {
        allEntities().first
    }

    private func allEntities() -> [DashboardViewEntity] {
        guard let data = WidgetData.load() else { return [] }
        return data.views.map { DashboardViewEntity(id: $0.id, title: $0.title) }
    }
}
