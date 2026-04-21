import Foundation

/// Shared helpers for mock HTTP handlers in tests. Replaces the scattered
/// `HTTPURLResponse(url: request.url!, statusCode: 200, ...)!` pattern —
/// a crash there obscures which test failed.
enum TestHTTP {

    enum MockError: Error, CustomStringConvertible {
        case missingURL
        case responseConstructionFailed(url: URL, status: Int)

        var description: String {
            switch self {
            case .missingURL:
                "MockURLProtocol handler: request.url was nil"
            case .responseConstructionFailed(let url, let status):
                "MockURLProtocol handler: HTTPURLResponse construction failed for \(url) status \(status)"
            }
        }
    }

    /// Build a `(HTTPURLResponse, Data)` tuple for a `MockURLProtocol` handler.
    /// Throws instead of force-unwrapping — the handler signature already
    /// supports `throws` and propagates errors to the URLSession call site.
    static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        body: Data = Data(),
        headers: [String: String]? = nil
    ) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw MockError.missingURL }
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers) else {
            throw MockError.responseConstructionFailed(url: url, status: statusCode)
        }
        return (response, body)
    }

    /// Variant for handlers that already have a concrete URL (no request).
    static func response(
        url: URL,
        statusCode: Int = 200,
        body: Data = Data(),
        headers: [String: String]? = nil
    ) throws -> (HTTPURLResponse, Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers) else {
            throw MockError.responseConstructionFailed(url: url, status: statusCode)
        }
        return (response, body)
    }
}
