import Testing
import Foundation
@testable import PullRequestPilot

@Suite("AppError.rateLimited")
struct AppErrorRateLimitedTests {
    private static let genericMessage = "GitHub rate limit exceeded. Try again in a few minutes."

    @Test("Past resetAt falls back to the generic message")
    func pastResetAtFallsBack() {
        let error = AppError.rateLimited(resetAt: Date(timeIntervalSinceNow: -120))
        #expect(error.errorDescription == Self.genericMessage)
    }

    @Test("resetAt within a second falls back to the generic message")
    func nearNowResetAtFallsBack() {
        let error = AppError.rateLimited(resetAt: Date(timeIntervalSinceNow: 0.4))
        #expect(error.errorDescription == Self.genericMessage)
    }

    @Test("Future resetAt renders a forward-looking retry phrase")
    func futureResetAtRendersPhrase() throws {
        let error = AppError.rateLimited(resetAt: Date(timeIntervalSinceNow: 300))
        let message = try #require(error.errorDescription)
        #expect(message.contains("GitHub rate limit exceeded. Try again"))
        #expect(message != Self.genericMessage)
    }

    @Test("nil resetAt uses the generic message")
    func nilResetAtUsesGenericMessage() {
        let error = AppError.rateLimited(resetAt: nil)
        #expect(error.errorDescription == Self.genericMessage)
    }
}

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
