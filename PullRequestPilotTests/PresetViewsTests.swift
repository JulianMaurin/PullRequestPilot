import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.presetViews")
struct PresetViewsTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String) throws -> DashboardViewModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        return DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
    }

    @Test("presets don't pin a base branch, so repos on master or develop still match")
    func presetsHaveNoBaseQualifier() {
        for preset in DashboardView.presetViews {
            #expect(!preset.query.contains("base:"), "\(preset.title) pins a base branch")
        }
    }

    // MARK: - presetConflicts

    @Test("presetConflicts returns titles that match existing views")
    func conflictsDetected() throws {
        let viewModel = try makeViewModel(suiteName: "PresetConflicts")
        let preset = DashboardView.presetViews[0]
        viewModel.addView(DashboardView(id: UUID(), title: preset.title, query: "custom query"))

        let conflicts = viewModel.presetConflicts()
        #expect(conflicts.contains(preset.title))
        #expect(conflicts.count == 1)
    }

    @Test("presetConflicts returns empty when no conflicts")
    func conflictsEmpty() throws {
        let viewModel = try makeViewModel(suiteName: "PresetNoConflicts")
        let conflicts = viewModel.presetConflicts()
        #expect(conflicts.isEmpty)
    }

    // MARK: - createPresetViews

    @Test("createPresetViews adds all presets when no conflicts")
    func addsAllPresets() throws {
        let viewModel = try makeViewModel(suiteName: "CreatePresetsClean")

        viewModel.createPresetViews(replacingConflicts: false)

        #expect(viewModel.views.count == DashboardView.presetViews.count)
        for preset in DashboardView.presetViews {
            #expect(viewModel.views.contains(where: { $0.title == preset.title && $0.query == preset.query }))
        }
    }

    @Test("createPresetViews skips conflicting presets when not replacing")
    func skipsConflicts() throws {
        let viewModel = try makeViewModel(suiteName: "CreatePresetsSkip")
        let preset = DashboardView.presetViews[0]
        viewModel.addView(DashboardView(id: UUID(), title: preset.title, query: "custom query"))

        viewModel.createPresetViews(replacingConflicts: false)

        let matchingView = viewModel.views.first(where: { $0.title == preset.title })
        #expect(matchingView?.query == "custom query")
    }

    @Test("createPresetViews replaces conflicting presets when replacing")
    func replacesConflicts() throws {
        let viewModel = try makeViewModel(suiteName: "CreatePresetsReplace")
        let preset = DashboardView.presetViews[0]
        let originalID = UUID()
        viewModel.addView(DashboardView(id: originalID, title: preset.title, query: "custom query"))

        viewModel.createPresetViews(replacingConflicts: true)

        let matchingView = viewModel.views.first(where: { $0.title == preset.title })
        #expect(matchingView?.query == preset.query)
        #expect(matchingView?.id == originalID)
    }

    @Test("createPresetViews sets selectedViewID when none was selected")
    func setsSelection() throws {
        let viewModel = try makeViewModel(suiteName: "CreatePresetsSelect")

        #expect(viewModel.selectedViewID == nil)
        viewModel.createPresetViews(replacingConflicts: false)
        #expect(viewModel.selectedViewID != nil)
    }
}
