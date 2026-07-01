import Testing
import Foundation
import Security
@testable import PullRequestPilot

@Suite("KeychainService")
struct KeychainServiceTests {
    private let keychain = KeychainService(service: "com.pullrequestpilot.tests.\(UUID().uuidString)")

    @Test("save and read round-trips a value")
    func saveAndRead() throws {
        try keychain.save(key: "test-key", value: "test-value")
        let result = keychain.read(key: "test-key")
        #expect(result == "test-value")
        try keychain.delete(key: "test-key")
    }

    @Test("read returns nil for missing key")
    func readMissing() {
        let result = keychain.read(key: "nonexistent-key-\(UUID().uuidString)")
        #expect(result == nil)
    }

    @Test("save overwrites existing value")
    func saveOverwrites() throws {
        try keychain.save(key: "overwrite-key", value: "first")
        try keychain.save(key: "overwrite-key", value: "second")
        let result = keychain.read(key: "overwrite-key")
        #expect(result == "second")
        try keychain.delete(key: "overwrite-key")
    }

    @Test("delete removes the item")
    func deleteRemoves() throws {
        try keychain.save(key: "delete-key", value: "data")
        try keychain.delete(key: "delete-key")
        let result = keychain.read(key: "delete-key")
        #expect(result == nil)
    }

    @Test("delete does not throw for missing key")
    func deleteNonExistent() throws {
        try keychain.delete(key: "never-existed-\(UUID().uuidString)")
    }

    @Test("readItem round-trips a saved value")
    func readItemRoundTrip() throws {
        try keychain.save(key: "strict-key", value: "strict-value")
        #expect(try keychain.readItem(key: "strict-key") == "strict-value")
        try keychain.delete(key: "strict-key")
    }

    @Test("readItem returns nil only for a missing item")
    func readItemMissing() throws {
        #expect(try keychain.readItem(key: "nonexistent-key-\(UUID().uuidString)") == nil)
    }

    @Test("readItem throws unexpectedStatus for non-notFound failures")
    func readItemThrowsOnKeychainFailure() {
        let locked = KeychainService(
            service: "com.pullrequestpilot.tests.locked",
            secItemCopyMatching: { _, _ in errSecInteractionNotAllowed }
        )
        #expect(throws: KeychainError.unexpectedStatus(errSecInteractionNotAllowed)) {
            try locked.readItem(key: "any-key")
        }
    }

    @Test("readItem throws invalidData for a non-UTF-8 payload")
    func readItemThrowsOnCorruptData() {
        let corrupt = KeychainService(
            service: "com.pullrequestpilot.tests.corrupt",
            secItemCopyMatching: { _, result in
                result?.pointee = Data([0xFF, 0xFE]) as CFData
                return errSecSuccess
            }
        )
        #expect(throws: KeychainError.invalidData) {
            try corrupt.readItem(key: "any-key")
        }
    }

    @Test("read maps keychain failure to nil (logged fallback)")
    func readFallsBackToNilOnKeychainFailure() {
        let failing = KeychainService(
            service: "com.pullrequestpilot.tests.authfail",
            secItemCopyMatching: { _, _ in errSecAuthFailed }
        )
        #expect(failing.read(key: "any-key") == nil)
    }

    @Test("KeychainError descriptions are user-facing")
    func errorDescriptions() {
        let encodingError = KeychainError.encodingError
        #expect(encodingError.errorDescription?.contains("encode") == true)

        let notFound = KeychainError.itemNotFound
        #expect(notFound.errorDescription?.contains("not found") == true)

        let statusError = KeychainError.unexpectedStatus(-25300)
        #expect(statusError.errorDescription?.contains("Keychain") == true)

        let invalidData = KeychainError.invalidData
        #expect(invalidData.errorDescription?.contains("UTF-8") == true)
    }
}
