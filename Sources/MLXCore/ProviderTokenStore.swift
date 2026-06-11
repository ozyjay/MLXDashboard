import Foundation
import Security

public protocol ProviderTokenStoring: Sendable {
    func token() throws -> String
    func regenerateToken() throws -> String
}

public final class EphemeralProviderTokenStore: ProviderTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?

    public init(initialToken: String? = nil) {
        self.storedToken = initialToken
    }

    public func token() throws -> String {
        if let storedToken = lock.withLock({ storedToken }) {
            return storedToken
        }
        return try regenerateToken()
    }

    public func regenerateToken() throws -> String {
        let token = Self.makeToken()
        lock.withLock {
            storedToken = token
        }
        return token
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

public final class KeychainProviderTokenStore: ProviderTokenStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.local.MLXDashboard.provider", account: String = "MLXChatProviderToken") {
        self.service = service
        self.account = account
    }

    public func token() throws -> String {
        if let existing = try readToken() {
            return existing
        }
        return try regenerateToken()
    }

    public func regenerateToken() throws -> String {
        let token = EphemeralProviderTokenStore.makeKeychainCompatibleToken()
        try save(token)
        return token
    }

    private func readToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return token
    }

    private func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }
}

public struct KeychainError: Error, CustomStringConvertible, Equatable {
    public let status: OSStatus

    public var description: String {
        "Keychain operation failed with status \(status)"
    }
}

private extension EphemeralProviderTokenStore {
    static func makeKeychainCompatibleToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
