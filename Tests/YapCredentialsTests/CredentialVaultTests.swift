import Foundation
import Security
import Synchronization
import Testing
@testable import YapCredentials

@Suite("Consolidated credential access")
struct CredentialVaultTests {
    private let google = CredentialKey(service: "app.yap.google-calendar", account: "personal")
    private let zoom = CredentialKey(service: "app.yap.zoom-personal", account: "oauth-tokens")
    private let configuration = CredentialKey(service: "app.yap.zoom-personal", account: "configuration")
    private let oldVault = CredentialKey(service: "app.whoosh.credentials", account: "personal-connections-v1")

    @Test func readsOnlyYapVaultOncePerLaunch() throws {
        let storage = MemoryCredentialStorage()
        let initial = CredentialVault(storage: storage)
        try initial.save(Data("google".utf8), for: google)
        try initial.save(Data("zoom".utf8), for: zoom)
        let next = CredentialVault(storage: storage)
        for _ in 0..<3 {
            #expect(try next.load(google) == Data("google".utf8))
            #expect(try next.load(zoom) == Data("zoom".utf8))
        }
        #expect(storage.loads(CredentialVault.storageKey) == 2)
        #expect(storage.loads(google) == 0)
        #expect(storage.loads(oldVault) == 0)
    }

    @Test func freshInstallIgnoresEarlierAppsWithoutCreatingAnItem() throws {
        let storage = MemoryCredentialStorage()
        storage.put(Data("malformed-old-vault".utf8), for: oldVault)
        storage.put(Data("stale-tokens".utf8), for: google)
        let vault = CredentialVault(storage: storage)
        #expect(try vault.load(google) == nil)
        #expect(try vault.load(google) == nil)
        #expect(storage.loads(CredentialVault.storageKey) == 1)
        #expect(storage.loads(google) == 0)
        #expect(storage.loads(oldVault) == 0)
        #expect(storage.saves == 0)
    }

    @Test func deniedReadCanBeRetried() throws {
        let storage = MemoryCredentialStorage()
        try CredentialVault(storage: storage).save(Data("saved".utf8), for: google)
        let vault = CredentialVault(storage: storage)
        storage.failNextRead()
        #expect(throws: CredentialVaultError.self) { try vault.load(google) }
        #expect(try vault.load(google) == Data("saved".utf8))
    }

    @Test func failedSaveCannotReplaceCachedOrDurableCredentials() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        try vault.save(Data("old".utf8), for: google)
        storage.failNextWrite()
        #expect(throws: CredentialVaultError.self) { try vault.save(Data("unpersisted".utf8), for: google) }
        for source in [vault, CredentialVault(storage: storage)] {
            #expect(try source.load(google) == Data("old".utf8))
        }
    }

    @Test func disconnectIgnoresProtectedLegacyItemsAndPreservesOtherAccount() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        storage.put(Data("old-token".utf8), for: google)
        storage.denyDeletion(google, status: errSecAuthFailed)
        try vault.save(Data("active-google".utf8), for: google)
        try vault.save(Data("active-zoom".utf8), for: zoom)
        try vault.delete(google)
        for source in [vault, CredentialVault(storage: storage)] {
            #expect(try source.load(google) == nil)
            #expect(try source.load(zoom) == Data("active-zoom".utf8))
        }
        #expect(storage.value(google) == Data("old-token".utf8))
        #expect(storage.deletions.isEmpty)
    }

    @Test func batchDisconnectRemovesBothZoomRecordsInOneWrite() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        for key in [google, zoom, configuration] { try vault.save(Data("saved".utf8), for: key) }
        let saves = storage.saves
        try vault.delete([zoom, configuration, zoom])
        #expect(storage.saves == saves + 1)
        let next = CredentialVault(storage: storage)
        #expect(try next.load(zoom) == nil)
        #expect(try next.load(configuration) == nil)
        #expect(try next.load(google) == Data("saved".utf8))
    }

    @Test func failedDisconnectPreservesBothRecords() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        for key in [zoom, configuration] { try vault.save(Data("saved".utf8), for: key) }
        let persisted = storage.value(CredentialVault.storageKey)
        storage.failNextWrite()
        #expect(throws: CredentialVaultError.self) { try vault.delete([zoom, configuration]) }
        #expect(storage.value(CredentialVault.storageKey) == persisted)
        for source in [vault, CredentialVault(storage: storage)] {
            for key in [zoom, configuration] { #expect(try source.load(key) == Data("saved".utf8)) }
        }
    }

    @Test func concurrentSavesDoNotLoseOtherRecords() async throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { try vault.save(Data("value-\(index)".utf8), for: CredentialKey(service: "test", account: String(index))) }
            }
            try await group.waitForAll()
        }
        let next = CredentialVault(storage: storage)
        for index in 0..<20 {
            #expect(try next.load(CredentialKey(service: "test", account: String(index))) == Data("value-\(index)".utf8))
        }
    }

    @Test func malformedCurrentVaultCannotBeOverwritten() throws {
        let storage = MemoryCredentialStorage()
        storage.put(Data("not-json".utf8), for: CredentialVault.storageKey)
        let vault = CredentialVault(storage: storage)
        #expect(throws: CredentialVaultError.self) { try vault.load(google) }
        #expect(throws: CredentialVaultError.self) { try vault.save(Data("new".utf8), for: google) }
        #expect(storage.saves == 0)
    }
}

private final class MemoryCredentialStorage: CredentialStorage, Sendable {
    private struct State {
        var values: [CredentialKey: Data] = [:]
        var loads: [CredentialKey: Int] = [:]
        var saves = 0
        var deletions: [CredentialKey] = []
        var failRead = false
        var failWrite = false
        var failDelete = false
        var deniedDeletions: [CredentialKey: OSStatus] = [:]
    }
    private let state = Mutex(State())
    var saves: Int { state.withLock { $0.saves } }
    var deletions: [CredentialKey] { state.withLock { $0.deletions } }
    func loads(_ key: CredentialKey) -> Int { state.withLock { $0.loads[key, default: 0] } }
    func value(_ key: CredentialKey) -> Data? { state.withLock { $0.values[key] } }
    func put(_ data: Data, for key: CredentialKey) { state.withLock { $0.values[key] = data } }
    func failNextRead() { state.withLock { $0.failRead = true } }
    func failNextWrite() { state.withLock { $0.failWrite = true } }
    func failNextDeletion() { state.withLock { $0.failDelete = true } }
    func denyDeletion(_ key: CredentialKey, status: OSStatus) { state.withLock { $0.deniedDeletions[key] = status } }
    func allowDeletions() { state.withLock { $0.deniedDeletions = [:] } }

    func load(_ key: CredentialKey) throws -> Data? {
        try state.withLock {
            $0.loads[key, default: 0] += 1
            if $0.failRead { $0.failRead = false; throw CredentialVaultError.keychain(-128) }
            return $0.values[key]
        }
    }
    func save(_ data: Data, for key: CredentialKey) throws {
        try state.withLock {
            if $0.failWrite { $0.failWrite = false; throw CredentialVaultError.keychain(-128) }
            $0.saves += 1
            $0.values[key] = data
        }
    }
    func delete(_ key: CredentialKey) throws {
        try state.withLock {
            $0.deletions.append(key)
            if $0.failDelete { $0.failDelete = false; throw CredentialVaultError.keychain(-128) }
            if let status = $0.deniedDeletions[key] { throw CredentialVaultError.keychain(status) }
            $0.values.removeValue(forKey: key)
        }
    }
}
