import Foundation
import Security

public struct KeychainStore: CredentialStore {
    private let service: String
    private let account: String
    /// `account` names the item, so the donor and partner sessions are stored apart.
    public init(service: String, account: String = "donor-session") {
        self.service = service
        self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> Credentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountError.secureStorage(status) }
        // An undecodable item is a storage fault, not a request failure; callers already handle secureStorage.
        do { return try JSONDecoder().decode(Credentials.self, from: data) } catch { throw AccountError.secureStorage(errSecDecode) }
    }
    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccountError.secureStorage(status) }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.secureStorage(status) }
    }
}
