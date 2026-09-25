import Testing
import Foundation
import Security
@testable import PullRequestPilot

@Suite("KeychainService", .keychainCleanup)
struct KeychainServiceTests {
    private let keychain = KeychainService.forTesting(service: "com.pullrequestpilot.tests.\(UUID().uuidString)")

    @Test("save overwrites existing value")
    func saveOverwrites() throws {
        try keychain.save(key: "overwrite-key", value: "first")
        try keychain.save(key: "overwrite-key", value: "second")
        #expect(try keychain.readItem(key: "overwrite-key") == "second")
        try keychain.delete(key: "overwrite-key")
    }

    @Test("delete removes the item")
    func deleteRemoves() throws {
        try keychain.save(key: "delete-key", value: "data")
        try keychain.delete(key: "delete-key")
        #expect(try keychain.readItem(key: "delete-key") == nil)
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
