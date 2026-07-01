import Foundation
import os

/// Mock URL protocol for tests, with handlers keyed per session. Each
/// `MockHTTPSession` injects a unique key header via its
/// `URLSessionConfiguration.httpAdditionalHeaders`; `startLoading()` resolves
/// the handler for its own request by that key, so suites running in parallel
/// can never serve each other's requests. The handler closure is *not*
/// required to be `@Sendable` — tests often capture mutable local state
/// (e.g. to record requests) and rely on `.serialized` at the suite level
/// for that safety.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    fileprivate static let sessionKeyHeader = "X-Mock-Session-Key"

    private static let handlerStorage = OSAllocatedUnfairLock<[String: Handler]>(uncheckedState: [:])

    fileprivate static func handler(forKey key: String) -> Handler? {
        handlerStorage.withLockUnchecked { $0[key] }
    }

    fileprivate static func setHandler(_ handler: Handler?, forKey key: String) {
        handlerStorage.withLockUnchecked { $0[key] = handler }
    }

    fileprivate static func removeHandler(forKey key: String) {
        handlerStorage.withLockUnchecked { $0[key] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: Self.sessionKeyHeader),
              let handler = Self.handler(forKey: key) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - MockHTTPSession

/// Pairs a `URLSession` with its `MockURLProtocol` handler registration.
/// Requests from `urlSession` carry this handle's key header, so assigning
/// `handler` only affects this session. `deinit` unregisters the handler,
/// keeping the process-global handler table from growing across suites.
final class MockHTTPSession: Sendable {

    let urlSession: URLSession

    private let key: String

    init() {
        let key = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [MockURLProtocol.sessionKeyHeader: key]
        self.key = key
        self.urlSession = URLSession(configuration: configuration)
    }

    var handler: MockURLProtocol.Handler? {
        get { MockURLProtocol.handler(forKey: key) }
        set { MockURLProtocol.setHandler(newValue, forKey: key) }
    }

    deinit {
        MockURLProtocol.removeHandler(forKey: key)
    }
}
