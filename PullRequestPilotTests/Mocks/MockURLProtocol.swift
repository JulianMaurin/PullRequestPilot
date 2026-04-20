import Foundation
import os

/// Thread-safe mock URL protocol for tests. The request handler is stored
/// behind an `OSAllocatedUnfairLock` so parallel suites can read/write without
/// racing. The closure itself is *not* required to be `@Sendable` — tests
/// often capture mutable local state (e.g. to record requests) and rely on
/// `.serialized` at the suite level for that safety. The prior implementation
/// was `@unchecked Sendable` on the protocol class plus `nonisolated(unsafe)`
/// on the static; this version keeps the same capture contract for tests but
/// replaces the `nonisolated(unsafe)` with a real lock.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerStorage = OSAllocatedUnfairLock<Handler?>(uncheckedState: nil)

    static var requestHandler: Handler? {
        get { handlerStorage.withLockUnchecked { $0 } }
        set { handlerStorage.withLockUnchecked { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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
