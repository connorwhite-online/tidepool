import Foundation
import Security

// MARK: - Keychain Keys

enum KeychainKey: String {
    case spotifyCredentials = "com.tidepool.spotify.credentials"
}

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Item not found in Keychain"
        case .duplicateItem:
            return "Item already exists in Keychain"
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .encodingFailed:
            return "Failed to encode data for Keychain"
        case .decodingFailed:
            return "Failed to decode data from Keychain"
        }
    }
}

// MARK: - Keychain Manager

class KeychainManager {
    static let shared = KeychainManager()

    private let serviceName = "com.tidepool.app"

    init() {}

    // MARK: - Save

    func save<T: Codable>(_ item: T, for key: KeychainKey) throws {
        guard let data = try? JSONEncoder().encode(item) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data
        ]

        // Try to delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Load

    func load<T: Codable>(_ type: T.Type, for key: KeychainKey) throws -> T {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let item = try? JSONDecoder().decode(type, from: data) else {
            throw KeychainError.decodingFailed
        }

        return item
    }

    // MARK: - Delete

    func delete(for key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Exists

    func exists(for key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Update

    func update<T: Codable>(_ item: T, for key: KeychainKey) throws {
        guard let data = try? JSONEncoder().encode(item) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                // Item doesn't exist, create it
                try save(item, for: key)
                return
            }
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
