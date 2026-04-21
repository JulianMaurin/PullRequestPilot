import Testing
@testable import PullRequestPilot

@Suite("AppError.logExportFailed")
struct AppErrorLogExportFailedTests {
    @Test("logExportFailed surfaces the underlying reason")
    func logExportFailedDescription() {
        let error = AppError.logExportFailed(underlying: "disk full")
        #expect(error.errorDescription == "Couldn't export logs: disk full")
    }

    @Test("logExportFailed is not classified as a network failure")
    func logExportFailedIsNotNetwork() {
        let error = AppError.logExportFailed(underlying: "io")
        #expect(error.isNetworkFailure == false)
    }
}
