import Foundation
import SwiftUI

@Observable
final class SettingsViewModel {
    var token: String = ""
    private(set) var viewerLogin: String?
    private(set) var validationState: ValidationState = .idle
    private(set) var saveError: String?

    private let keychain: KeychainService
    private let gitHubClient: GitHubClientProtocol

    enum ValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    init(keychain: KeychainService, gitHubClient: GitHubClientProtocol) {
        self.keychain = keychain
        self.gitHubClient = gitHubClient
        self.token = keychain.read(key: Constants.Keychain.githubToken) ?? ""
    }

    var hasToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func save() async {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        saveError = nil
        validationState = .validating

        do {
            try keychain.save(key: Constants.Keychain.githubToken, value: trimmedToken)
        } catch {
            saveError = error.localizedDescription
            validationState = .idle
            return
        }

        do {
            let login = try await gitHubClient.fetchViewerLogin()
            viewerLogin = login
            validationState = .valid
        } catch {
            validationState = .invalid(error.localizedDescription)
        }
    }

    func clearToken() {
        try? keychain.delete(key: Constants.Keychain.githubToken)
        token = ""
        viewerLogin = nil
        validationState = .idle
    }
}
