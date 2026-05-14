import Foundation
import Security

// MARK: - Keychain Keys

enum KeychainKey: String {
    case spotifyCredentials = "com.tidepool.spotify.credentials"
    case backendCredentials = "com.tidepool.backend.credentials"
}

// MARK: - Backend Credentials

struct BackendCredentials: Codable {
    let token: String
    let deviceID: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Item not found in Keychain"
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

    private init() {}

    // MARK: - Save

    func save<T: Codable>(_ item: T, for key: KeychainKey) throws {
        guard let data = try? JSONEncoder().encode(item) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            // Background visit uploads need keychain access after first unlock.
            // ThisDeviceOnly so a restored backup doesn't carry our JWT (which
            // identifies the original device) to a new device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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

}
