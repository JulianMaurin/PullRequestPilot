import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("ExternalEditorLauncher")
struct ExternalEditorLauncherTests {

    private struct LaunchFailure: Error {}

    @Test("an editor that isn't installed reports it instead of doing nothing")
    func missingEditorReports() async {
        let recorder = EventRecorder()
        let launcher = ExternalEditorLauncher(
            reporter: recorder.reporter(),
            locateApplication: { _ in nil },
            openDirectory: { _, _ in Issue.record("nothing to open with") }
        )

        await launcher.open(URL(fileURLWithPath: "/tmp/repo"), in: .visualStudioCode)

        #expect(recorder.events.map(\.payload) == [.error(.externalAppLaunchFailed(appName: "VS Code"))])
    }

    @Test("a launch the system refuses is reported")
    func failedLaunchReports() async {
        let recorder = EventRecorder()
        let launcher = ExternalEditorLauncher(
            reporter: recorder.reporter(),
            locateApplication: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            openDirectory: { _, _ in throw LaunchFailure() }
        )

        await launcher.open(URL(fileURLWithPath: "/tmp/repo"), in: .iTerm)

        #expect(recorder.events.map(\.payload) == [.error(.externalAppLaunchFailed(appName: "iTerm"))])
    }
}
