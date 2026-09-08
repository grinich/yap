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
    // Explicit aliases for the released predecessor's secure storage. Never
    // search arbitrary Keychain services or weaken an item's access controls.
    static let legacyStorageKey = CredentialKey(service: "app.whoosh.credentials", account: "personal-connections-v1")
    private static let legacyServices = [
        "app.yap.personal.configuration": "app.whoosh.personal.configuration",
        "app.yap.google-calendar": "app.whoosh.google-calendar",
        "app.yap.zoom-personal": "app.whoosh.zoom-personal"
    ]

    private struct Snapshot: Codable {
        var version = 1
        var records: [String: Data] = [:]
        // Tombstones prevent removed credentials from being resurrected by an
        // older item left behind during migration or a failed legacy deletion.
        var migrated: Set<String> = []
    }

    private let storage: any CredentialStorage
    private let lock = NSLock()
    // All access, including failed-write handling, is protected by lock.
    private var cached: Snapshot?

    public init(storage: any CredentialStorage) { self.storage = storage }

    public func load(_ key: CredentialKey) throws -> Data? {
        try lock.withLock {
            var snapshot = try current()
            if snapshot.migrated.contains(key.identifier) { return snapshot.records[key.identifier] }
            // Read old items only during their first successful migration. They
            // retain their existing protection and may need one final approval.
            var legacy = try storage.load(key)
            if legacy == nil, let previous = Self.legacyKey(for: key) { legacy = try storage.load(previous) }
            snapshot.migrated.insert(key.identifier)
            snapshot.records[key.identifier] = legacy
            if legacy != nil { try commit(snapshot) }
            else { cached = snapshot } // Missing setup does not create an item.
            return legacy
        }
    }

    public func save(_ data: Data, for key: CredentialKey) throws {
        try lock.withLock {
            var snapshot = try current()
            snapshot.records[key.identifier] = data
            snapshot.migrated.insert(key.identifier)
            try commit(snapshot)
        }
    }

    public func delete(_ key: CredentialKey) throws {
        try delete([key])
    }

    /// Remove related active records in one durable write before cleaning up
    /// their explicitly named legacy items. Cleanup failures remain visible.
    public func delete(_ keys: [CredentialKey]) throws {
        guard !keys.isEmpty else { return }
        try lock.withLock {
            var snapshot = try current()
            var cleanupKeys: [CredentialKey] = []
            var seen: Set<CredentialKey> = []
            for key in keys {
                snapshot.records.removeValue(forKey: key.identifier)
                snapshot.migrated.insert(key.identifier)
                if seen.insert(key).inserted { cleanupKeys.append(key) }
                if let previous = Self.legacyKey(for: key), seen.insert(previous).inserted {
                    cleanupKeys.append(previous)
                }
            }
            try commit(snapshot)
            // A denied old item must not prevent removal of the other scoped
            // items. Durable tombstones prevent any failed cleanup reviving them.
            var firstError: (any Error)?
            for key in cleanupKeys {
                do { try storage.delete(key) }
                catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }

    private func current() throws -> Snapshot {
        if let cached { return cached }
        if let data = try storage.load(Self.storageKey) {
            let value = try decode(data)
            cached = value
            return value
        }
        guard let data = try storage.load(Self.legacyStorageKey) else {
            let empty = Snapshot()
            cached = empty
            return empty
        }
        var value = try decode(data)
        for (currentService, legacyService) in Self.legacyServices {
            let prefix = legacyService + "\u{0}"
            let identifiers = Set(value.records.keys).union(value.migrated).filter { $0.hasPrefix(prefix) }
            for oldID in identifiers {
                let newID = currentService + "\u{0}" + String(oldID.dropFirst(prefix.count))
                if !value.migrated.contains(newID), value.records[newID] == nil {
                    value.records[newID] = value.records[oldID]
                    // Preserve removals as well as saved records. A stale legacy
                    // token must not reappear after the app's identity changes.
                    value.migrated.insert(newID)
                }
                value.records.removeValue(forKey: oldID)
                value.migrated.remove(oldID)
            }
        }
        // Do not cache a migration until its new Keychain write succeeds. The
        // previous app's item remains untouched if access or saving is denied.
        try commit(value)
        return value
    }

    private func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= 1_048_576, let value = try? JSONDecoder().decode(Snapshot.self, from: data),
              value.version == 1 else { throw CredentialVaultError.invalidData }
        return value
    }

    private static func legacyKey(for key: CredentialKey) -> CredentialKey? {
        legacyServices[key.service].map { CredentialKey(service: $0, account: key.account) }
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
