import Testing
import Foundation
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

    @Test("KeychainError descriptions are user-facing")
    func errorDescriptions() {
        let encodingError = KeychainError.encodingError
        #expect(encodingError.errorDescription?.contains("encode") == true)

        let notFound = KeychainError.itemNotFound
        #expect(notFound.errorDescription?.contains("not found") == true)

        let statusError = KeychainError.unexpectedStatus(-25300)
        #expect(statusError.errorDescription?.contains("Keychain") == true)
    }
}
