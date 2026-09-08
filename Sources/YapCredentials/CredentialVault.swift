import Foundation
import Security

public struct CredentialKey: Hashable, Sendable {
    public let service: String
    public let account: String
    public init(service: String, account: String) { self.service = service; self.account = account }
    fileprivate var identifier: String { service + "\u{0}" + account }
}

public enum CredentialVaultError: Error, Sendable {
    case keychain(OSStatus)
    case invalidData
}

/// Synchronous so callers can share one serialized process-wide cache. UI
/// bootstrap invokes credential reads off the main actor; token stores are actors.
public protocol CredentialStorage: Sendable {
    func load(_ key: CredentialKey) throws -> Data?
    func save(_ data: Data, for key: CredentialKey) throws
    func delete(_ key: CredentialKey) throws
}

/// One normal Keychain item for the app's four connection records. No custom
/// access controls, trust overrides, plaintext files, or security-prompt bypasses.
public final class CredentialVault: @unchecked Sendable {
    public static let shared = CredentialVault(storage: SystemCredentialStorage())
    public static let storageKey = CredentialKey(service: "app.yap.credentials", account: "personal-connections-v1")
    private struct Snapshot: Codable {
        var version = 1
        var records: [String: Data] = [:]
    }

    private let storage: any CredentialStorage
    private let lock = NSLock()
    // All access, including failed-write handling, is protected by lock.
    private var cached: Snapshot?

    public init(storage: any CredentialStorage) { self.storage = storage }

    public func load(_ key: CredentialKey) throws -> Data? {
        try lock.withLock { try current().records[key.identifier] }
    }

    public func save(_ data: Data, for key: CredentialKey) throws {
        try lock.withLock {
            var snapshot = try current()
            snapshot.records[key.identifier] = data
            try commit(snapshot)
        }
    }

    public func delete(_ key: CredentialKey) throws {
        try delete([key])
    }

    /// Disconnect removes active records atomically. Earlier apps' separate
    /// Keychain items are neither read nor deleted by Yap.
    public func delete(_ keys: [CredentialKey]) throws {
        guard !keys.isEmpty else { return }
        try lock.withLock {
            var snapshot = try current()
            for key in keys { snapshot.records.removeValue(forKey: key.identifier) }
            try commit(snapshot)
        }
    }

    private func current() throws -> Snapshot {
        if let cached { return cached }
        let value: Snapshot
        if let data = try storage.load(Self.storageKey) { value = try decode(data) }
        else { value = Snapshot() }
        cached = value
        return value
    }

    private func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= 1_048_576, let value = try? JSONDecoder().decode(Snapshot.self, from: data),
              value.version == 1 else { throw CredentialVaultError.invalidData }
        return value
    }

    private func commit(_ value: Snapshot) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw CredentialVaultError.invalidData }
        try storage.save(data, for: Self.storageKey)
        // A failed secure write never turns unpersisted credentials into a hit.
        cached = value
    }
}

private struct SystemCredentialStorage: CredentialStorage {
    private func query(_ key: CredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: key.service, kSecAttrAccount as String: key.account,
         kSecAttrSynchronizable as String: false]
    }

    func load(_ key: CredentialKey) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVaultError.keychain(status) }
        guard let data = item as? Data else { throw CredentialVaultError.invalidData }
        return data
    }

    func save(_ data: Data, for key: CredentialKey) throws {
        var status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(key)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        // Update in place preserves the existing item's user-approved access.
        guard status == errSecSuccess else { throw CredentialVaultError.keychain(status) }
    }

    func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVaultError.keychain(status) }
    }
}
