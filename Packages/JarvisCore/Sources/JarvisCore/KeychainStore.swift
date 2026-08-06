import Foundation
import Security

/// Generic-password storage for API keys. Keys never touch UserDefaults or disk.
public struct KeychainStore: Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case anthropicAPIKey = "anthropic-api-key"
        case elevenLabsAPIKey = "elevenlabs-api-key"

        public var displayName: String {
            switch self {
            case .anthropicAPIKey: "Anthropic API key"
            case .elevenLabsAPIKey: "ElevenLabs API key"
            }
        }
    }

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case invalidData
    }

    public let service: String

    public init(service: String = "com.jarvis.assistant") {
        self.service = service
    }

    public func set(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.invalidData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else {
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
        }
    }

    public func get(_ key: Key) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Off-main read.
    ///
    /// `SecItemCopyMatching` can block for a long time — it shows the "wants to
    /// use your confidential information" approval dialog when the app's code
    /// signature is unfamiliar, which happens on every rebuild under ad-hoc
    /// signing. Doing that on the main actor freezes the UI and can stop the
    /// prompt surfacing at all, so reads on any hot path go through here.
    public func value(for key: Key) async throws -> String? {
        let store = self
        return try await Task.detached(priority: .userInitiated) {
            try store.get(key)
        }.value
    }

    public func delete(_ key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
