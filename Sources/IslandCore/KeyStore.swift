import Foundation
import Security

public protocol KeyStore: Sendable {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}
public enum KeyStoreError: Error, Equatable, Sendable { case emptyKey, keychain(OSStatus), invalidData }
private func normalizedKey(_ key: String) throws -> String {
    let result = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw KeyStoreError.emptyKey }
    return result
}
public struct KeychainKeyStore: KeyStore {
    public init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.ksotis.dynamic-island",
         kSecAttrAccount as String: "management-key",
         kSecAttrSynchronizable as String: false]
    }
    public func read() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw KeyStoreError.invalidData }
        return key
    }
    public func save(_ key: String) throws {
        let data = Data(try normalizedKey(key).utf8)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError.keychain(status) }
    }
}
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    public init(key: String? = nil) { self.key = key?.trimmingCharacters(in: .whitespacesAndNewlines); if self.key?.isEmpty == true { self.key = nil } }
    public func read() throws -> String? { lock.withLock { key } }
    public func save(_ key: String) throws { let normalized = try normalizedKey(key); lock.withLock { self.key = normalized } }
    public func delete() throws { lock.withLock { key = nil } }
}
