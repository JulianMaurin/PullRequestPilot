import Foundation

extension Error {
    var isNetworkError: Bool {
        if let clientError = self as? GitHubClientError,
           case .networkError = clientError {
            return true
        }
        if let urlError = self as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code) {
            return true
        }
        return false
    }
}
