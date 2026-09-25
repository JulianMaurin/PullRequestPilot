import Foundation
import Security

enum KeychainError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case itemNotFound
    case encodingError
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown (\(status))")"
        case .itemNotFound:
            "Item not found in Keychain."
        case .encodingError:
            "Failed to encode value for Keychain storage."
        case .invalidData:
            "Keychain item data is not a valid UTF-8 string."
        }
    }
}

final class KeychainService: Sendable {
    /// Signature of `SecItemCopyMatching`; injectable so tests can force error
    /// statuses (locked keychain, denied ACL) the real API can't produce on demand.
    typealias SecItemCopy = @Sendable (_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    private let service: String
    private let secItemCopyMatching: SecItemCopy

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.pullrequestpilot",
        secItemCopyMatching: @escaping SecItemCopy = SecItemCopyMatching
    ) {
        self.service = service
        self.secItemCopyMatching = secItemCopyMatching
    }

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingError
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        // Try to update the existing item first (atomic, no delete gap)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            // No existing item — add a new one
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }

        throw KeychainError.unexpectedStatus(updateStatus)
    }

    /// Returns the stored value, or nil only when no item exists
    /// (`errSecItemNotFound`). Any other status throws so callers can
    /// distinguish a missing token from an unreadable keychain (locked at
    /// login-item launch, denied ACL).
    func readItem(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = secItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
