import Testing
import Foundation
@testable import PullRequestPilot

@Suite("DashboardView Model")
struct DashboardViewTests {

    @Test("init sets hideReviewed to false by default")
    func initDefaultHideReviewed() {
        let view = DashboardView(id: UUID(), title: "Test", query: "is:pr")
        #expect(view.hideReviewed == false)
    }

    @Test("init accepts explicit hideReviewed value")
    func initExplicitHideReviewed() {
        let view = DashboardView(id: UUID(), title: "Test", query: "is:pr", hideReviewed: true)
        #expect(view.hideReviewed == true)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let id = UUID()
        let original = DashboardView(id: id, title: "My PRs", query: "is:pr author:@me", hideReviewed: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DashboardView.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.title == original.title)
        #expect(decoded.query == original.query)
        #expect(decoded.hideReviewed == original.hideReviewed)
    }

    @Test("Decoding without hideReviewed defaults to false (backward compatibility)")
    func decodingBackwardCompatibility() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","title":"Old View","query":"is:pr"}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(DashboardView.self, from: data)

        #expect(decoded.hideReviewed == false)
        #expect(decoded.title == "Old View")
    }

    @Test("defaultViews is empty (users create views via presets or manually)")
    func defaultViewsStructure() {
        let defaults = DashboardView.defaultViews
        #expect(defaults.isEmpty)
    }

    @Test("DashboardView conforms to Hashable")
    func hashable() {
        let id = UUID()
        let view1 = DashboardView(id: id, title: "Same", query: "q")
        let view2 = DashboardView(id: id, title: "Same", query: "q")
        #expect(view1 == view2)

        let view3 = DashboardView(id: UUID(), title: "Same", query: "q")
        #expect(view1 != view3)
    }
}
