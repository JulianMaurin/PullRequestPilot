import Foundation
import os
import Security
import Testing
@testable import PullRequestPilot

/// The Keychain services a test created, so `.keychainCleanup` can delete
/// their items from the login keychain once the test ends.
final class TestKeychainRegistry: Sendable {
    @TaskLocal static var current: TestKeychainRegistry?

    private let services = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func register(_ service: String) {
        services.withLock { _ = $0.insert(service) }
    }

    func deleteAllItems() {
        for service in services.withLock({ $0 }) {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
            SecItemDelete(query as CFDictionary)
        }
    }
}

extension KeychainService {
    /// A Keychain for `service` whose items `.keychainCleanup` deletes after
    /// the test.
    static func forTesting(service: String) -> KeychainService {
        TestKeychainRegistry.current?.register(service)
        return KeychainService(service: service)
    }
}

/// Deletes every Keychain item a test wrote through
/// `KeychainService.forTesting(service:)`, whether the test passed or not.
struct KeychainCleanupTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let registry = TestKeychainRegistry()
        defer { registry.deleteAllItems() }
        try await TestKeychainRegistry.$current.withValue(registry) {
            try await function()
        }
    }
}

extension Trait where Self == KeychainCleanupTrait {
    static var keychainCleanup: Self { KeychainCleanupTrait() }
}
