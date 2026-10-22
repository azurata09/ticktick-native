import Foundation
import Security

nonisolated struct TickConnection: Codable, Sendable {
    let clientID: String
    let clientSecret: String
    let accessToken: String
}

enum ConnectionKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.azurata.TickTickNative",
         kSecAttrAccount as String: "oauth-connection"]
    }

    static func load() throws -> TickConnection? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TickTickError.keychain(status) }
        guard let data = result as? Data else { throw TickTickError.invalidResponse }
        return try JSONDecoder().decode(TickConnection.self, from: data)
    }

    static func save(_ connection: TickConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw TickTickError.keychain(added) }
        } else if status != errSecSuccess {
            throw TickTickError.keychain(status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TickTickError.keychain(status)
        }
    }
}
