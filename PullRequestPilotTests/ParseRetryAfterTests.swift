import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubClient.parseRetryAfter")
struct ParseRetryAfterTests {

    private func makeResponse(statusCode: Int = 429, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://api.github.com/graphql"))
        return try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers))
    }

    // MARK: - Retry-After as seconds

    @Test("parses Retry-After header with integer seconds")
    func retryAfterSeconds() throws {
        let response = try makeResponse(headers: ["Retry-After": "120"])
        let result = GitHubClient.parseRetryAfter(from: response)
        #expect(result == 120)
    }

    @Test("parses Retry-After header with fractional seconds")
    func retryAfterFractionalSeconds() throws {
        let response = try makeResponse(headers: ["Retry-After": "30.5"])
        let result = GitHubClient.parseRetryAfter(from: response)
        #expect(result == 30.5)
    }

    // MARK: - Retry-After as HTTP-date

    @Test("parses Retry-After header with HTTP-date format")
    func retryAfterHTTPDate() throws {
        let futureDate = Date().addingTimeInterval(600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.timeZone = TimeZone(identifier: "GMT")
        let dateStr = formatter.string(from: futureDate)

        let response = try makeResponse(headers: ["Retry-After": dateStr])
        let result = try #require(GitHubClient.parseRetryAfter(from: response))
        // Should be approximately 600 seconds (allow for time elapsed during test)
        #expect(result > 590 && result < 610)
    }

    // MARK: - X-RateLimit-Reset fallback

    @Test("falls back to X-RateLimit-Reset when no Retry-After header")
    func rateLimitResetFallback() throws {
        let futureTimestamp = Date().timeIntervalSince1970 + 300
        let response = try makeResponse(headers: ["X-RateLimit-Reset": "\(Int(futureTimestamp))"])
        let result = try #require(GitHubClient.parseRetryAfter(from: response))
        #expect(result > 290 && result < 310)
    }

    // MARK: - No headers

    @Test("returns nil when no retry headers present")
    func noRetryHeaders() throws {
        let response = try makeResponse(headers: [:])
        let result = GitHubClient.parseRetryAfter(from: response)
        #expect(result == nil)
    }

    // MARK: - Priority

    @Test("prefers Retry-After over X-RateLimit-Reset")
    func retryAfterTakesPrecedence() throws {
        let futureTimestamp = Date().timeIntervalSince1970 + 9999
        let response = try makeResponse(headers: [
            "Retry-After": "60",
            "X-RateLimit-Reset": "\(Int(futureTimestamp))",
        ])
        let result = GitHubClient.parseRetryAfter(from: response)
        #expect(result == 60)
    }

    @Test("returns zero or positive for past X-RateLimit-Reset")
    func pastRateLimitReset() throws {
        let pastTimestamp = Date().timeIntervalSince1970 - 100
        let response = try makeResponse(headers: ["X-RateLimit-Reset": "\(Int(pastTimestamp))"])
        let result = try #require(GitHubClient.parseRetryAfter(from: response))
        #expect(result >= 0)
    }
}
