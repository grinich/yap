import Foundation
import Security
import Synchronization
import Testing
@testable import YapCredentials

@Suite("Consolidated credential access")
struct CredentialVaultTests {
    private let keys = [
        CredentialKey(service: "app.yap.personal.configuration", account: "google-desktop"),
        CredentialKey(service: "app.yap.google-calendar", account: "personal"),
        CredentialKey(service: "app.yap.zoom-personal", account: "configuration"),
        CredentialKey(service: "app.yap.zoom-personal", account: "oauth-tokens")
    ]

    @Test func fourLegacyItemsMigrateOnceThenNeedOnlyOneVaultReadPerLaunch() throws {
        let storage = MemoryCredentialStorage()
        for (index, key) in keys.enumerated() { storage.put(Data("record-\(index)".utf8), for: key) }
        let first = CredentialVault(storage: storage)
        for (index, key) in keys.enumerated() {
            #expect(try first.load(key) == Data("record-\(index)".utf8))
            #expect(try first.load(key) == Data("record-\(index)".utf8))
            #expect(storage.loads(key) == 1)
        }
        #expect(storage.loads(CredentialVault.storageKey) == 1)
        let nextLaunch = CredentialVault(storage: storage)
        for key in keys { #expect(try nextLaunch.load(key) != nil); #expect(storage.loads(key) == 1) }
        #expect(storage.loads(CredentialVault.storageKey) == 2)
        #expect(storage.deletions.isEmpty)
    }

    @Test func missingSetupDoesNotCreateAnItemAndIsCachedForThisProcess() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        #expect(try vault.load(keys[0]) == nil)
        #expect(try vault.load(keys[0]) == nil)
        #expect(storage.loads(keys[0]) == 1)
        #expect(storage.saves == 0)
    }

    @Test func deniedReadIsRetriedInsteadOfBeingCachedAsMissing() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        storage.failNextRead()
        #expect(throws: CredentialVaultError.self) { try vault.load(keys[0]) }
        storage.put(Data("saved".utf8), for: keys[0])
        #expect(try vault.load(keys[0]) == Data("saved".utf8))
        #expect(storage.loads(CredentialVault.storageKey) == 2)
    }

    @Test func failedMigrationLeavesLegacyDataAndCanBeRetried() throws {
        let storage = MemoryCredentialStorage()
        storage.put(Data("legacy".utf8), for: keys[0])
        storage.failNextWrite()
        let vault = CredentialVault(storage: storage)
        #expect(throws: CredentialVaultError.self) { try vault.load(keys[0]) }
        #expect(storage.value(keys[0]) == Data("legacy".utf8))
        #expect(storage.value(CredentialVault.storageKey) == nil)
        #expect(try vault.load(keys[0]) == Data("legacy".utf8))
        #expect(storage.loads(keys[0]) == 2)
    }

    @Test func failedUpdateCannotReplaceCachedOrDurableCredentials() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        try vault.save(Data("old".utf8), for: keys[0])
        storage.failNextWrite()
        #expect(throws: CredentialVaultError.self) { try vault.save(Data("unpersisted".utf8), for: keys[0]) }
        #expect(try vault.load(keys[0]) == Data("old".utf8))
        #expect(try CredentialVault(storage: storage).load(keys[0]) == Data("old".utf8))
        #expect(storage.deletions.isEmpty)
    }

    @Test func deletingOneConnectionPreservesOthersAndCannotResurrectLegacyData() throws {
        let storage = MemoryCredentialStorage()
        for key in keys { storage.put(Data("saved".utf8), for: key) }
        let vault = CredentialVault(storage: storage)
        for key in keys { _ = try vault.load(key) }
        try vault.delete(keys[1])
        #expect(storage.value(keys[1]) == nil)
        let nextLaunch = CredentialVault(storage: storage)
        #expect(try nextLaunch.load(keys[1]) == nil)
        for key in [keys[0], keys[2], keys[3]] { #expect(try nextLaunch.load(key) == Data("saved".utf8)) }
    }

    @Test func failedLegacyDeletionReportsFailureButDurableTombstonePreventsResurrection() throws {
        let storage = MemoryCredentialStorage()
        storage.put(Data("legacy-token".utf8), for: keys[1])
        let vault = CredentialVault(storage: storage)
        _ = try vault.load(keys[1])
        storage.failNextDeletion()
        #expect(throws: CredentialVaultError.self) { try vault.delete(keys[1]) }
        #expect(storage.value(keys[1]) != nil)
        #expect(try CredentialVault(storage: storage).load(keys[1]) == nil)
        #expect(storage.loads(keys[1]) == 1)
    }

    @Test(arguments: [false, true])
    func batchDeletionCommitsTogetherAndAttemptsAllCleanupBeforeReportingFirstFailure(denyCurrentItem: Bool) throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        for key in keys {
            storage.put(Data("old".utf8), for: key)
            try vault.save(Data("saved".utf8), for: key)
        }
        let oldTokens = CredentialKey(service: "app.whoosh.zoom-personal", account: "oauth-tokens")
        let oldConfiguration = CredentialKey(service: "app.whoosh.zoom-personal", account: "configuration")
        storage.put(Data("older-tokens".utf8), for: oldTokens)
        storage.put(Data("older-configuration".utf8), for: oldConfiguration)
        // This shared old vault may also hold Google credentials; never delete it.
        storage.put(Data("untouched-old-vault".utf8), for: CredentialVault.legacyStorageKey)
        let firstDenied = denyCurrentItem ? keys[3] : oldTokens
        storage.denyDeletion(firstDenied, status: errSecAuthFailed)
        storage.denyDeletion(oldConfiguration, status: errSecUserCanceled)
        let savesBefore = storage.saves

        do {
            try vault.delete([keys[3], keys[2], keys[3]])
            Issue.record("Expected the first Keychain cleanup failure")
        } catch CredentialVaultError.keychain(let status) {
            #expect(status == errSecAuthFailed)
        }

        #expect(storage.saves == savesBefore + 1)
        #expect(storage.deletions == [keys[3], oldTokens, keys[2], oldConfiguration])
        #expect(storage.value(firstDenied) != nil)
        #expect(storage.value(oldConfiguration) != nil)
        #expect(storage.value(keys[2]) == nil)
        for source in [vault, CredentialVault(storage: storage)] {
            #expect(try source.load(keys[2]) == nil)
            #expect(try source.load(keys[3]) == nil)
            for google in keys.prefix(2) { #expect(try source.load(google) == Data("saved".utf8)) }
        }
        #expect(storage.loads(oldTokens) == 0)
        #expect(storage.loads(oldConfiguration) == 0)
        #expect(storage.value(CredentialVault.legacyStorageKey) == Data("untouched-old-vault".utf8))
        for google in keys.prefix(2) { #expect(storage.value(google) == Data("old".utf8)) }

        storage.allowDeletions()
        try vault.delete([keys[3], keys[2]])
        #expect(storage.value(firstDenied) == nil)
        #expect(storage.value(oldConfiguration) == nil)
        #expect(try CredentialVault(storage: storage).load(keys[3]) == nil)
    }

    @Test func failedBatchCommitPreservesBothRecordsAndNeverAttemptsLegacyCleanup() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        for key in keys { try vault.save(Data("saved".utf8), for: key) }
        let persisted = storage.value(CredentialVault.storageKey)
        storage.failNextWrite()

        #expect(throws: CredentialVaultError.self) { try vault.delete([keys[3], keys[2]]) }

        #expect(storage.deletions.isEmpty)
        #expect(storage.value(CredentialVault.storageKey) == persisted)
        for source in [vault, CredentialVault(storage: storage)] {
            for key in keys { #expect(try source.load(key) == Data("saved".utf8)) }
        }
    }

    @Test func concurrentSavesAreSerializedWithoutLosingOtherRecords() async throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try vault.save(Data("value-\(index)".utf8), for: CredentialKey(service: "test", account: String(index)))
                }
            }
            try await group.waitForAll()
        }
        let nextLaunch = CredentialVault(storage: storage)
        for index in 0..<20 {
            #expect(try nextLaunch.load(CredentialKey(service: "test", account: String(index))) == Data("value-\(index)".utf8))
        }
        #expect(storage.loads(CredentialVault.storageKey) == 2)
    }

    @Test func malformedVaultCannotBeOverwrittenOrSilentlyReimportOldCredentials() throws {
        let storage = MemoryCredentialStorage()
        storage.put(Data("not-json".utf8), for: CredentialVault.storageKey)
        storage.put(Data("old".utf8), for: keys[0])
        let vault = CredentialVault(storage: storage)
        #expect(throws: CredentialVaultError.self) { try vault.load(keys[0]) }
        #expect(throws: CredentialVaultError.self) { try vault.save(Data("new".utf8), for: keys[0]) }
        #expect(storage.loads(keys[0]) == 0)
        #expect(storage.saves == 0)
    }

    @Test func previousVaultMigratesRecordsAndDeletionTombstonesTogether() throws {
        let storage = MemoryCredentialStorage()
        let previousConfig = CredentialKey(service: "app.whoosh.zoom-personal", account: "configuration")
        let previousTokens = CredentialKey(service: "app.whoosh.zoom-personal", account: "oauth-tokens")
        let identifier: (CredentialKey) -> String = { $0.service + "\u{0}" + $0.account }
        let previous = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "records": [identifier(previousConfig): Data("configuration".utf8).base64EncodedString()],
            "migrated": [identifier(previousConfig), identifier(previousTokens)]
        ])
        storage.put(previous, for: CredentialVault.legacyStorageKey)
        storage.put(Data("stale-token".utf8), for: previousTokens)

        let vault = CredentialVault(storage: storage)
        #expect(try vault.load(keys[2]) == Data("configuration".utf8))
        #expect(try vault.load(keys[3]) == nil)
        #expect(storage.loads(previousTokens) == 0)
        #expect(storage.value(CredentialVault.legacyStorageKey) == previous)
        #expect(storage.value(CredentialVault.storageKey) != nil)
        let reopened = CredentialVault(storage: storage)
        #expect(try reopened.load(keys[3]) == nil)
        #expect(storage.loads(CredentialVault.legacyStorageKey) == 1)
    }

    @Test func previousIndividualItemsMigrateThroughExplicitServiceAliases() throws {
        let storage = MemoryCredentialStorage()
        let previous = CredentialKey(service: "app.whoosh.google-calendar", account: "personal")
        storage.put(Data("existing-tokens".utf8), for: previous)
        let vault = CredentialVault(storage: storage)
        #expect(try vault.load(keys[1]) == Data("existing-tokens".utf8))
        #expect(storage.loads(previous) == 1)
        try vault.delete(keys[1])
        #expect(storage.value(previous) == nil)
        #expect(try CredentialVault(storage: storage).load(keys[1]) == nil)
    }

    @Test func failedRenameMigrationDoesNotLoseThePreviousVaultOrCacheAnUnsavedCopy() throws {
        let storage = MemoryCredentialStorage()
        let previousID = "app.whoosh.zoom-personal\u{0}oauth-tokens"
        let previous = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "records": [previousID: Data("tokens".utf8).base64EncodedString()],
            "migrated": [previousID]
        ])
        storage.put(previous, for: CredentialVault.legacyStorageKey)
        storage.failNextWrite()
        let vault = CredentialVault(storage: storage)
        #expect(throws: CredentialVaultError.self) { try vault.load(keys[3]) }
        #expect(storage.value(CredentialVault.storageKey) == nil)
        #expect(storage.value(CredentialVault.legacyStorageKey) == previous)
        #expect(try vault.load(keys[3]) == Data("tokens".utf8))
        #expect(storage.loads(CredentialVault.legacyStorageKey) == 2)
    }

    @Test func currentVaultNeverFallsBackToAnOlderVaultAfterDisconnect() throws {
        let storage = MemoryCredentialStorage()
        let vault = CredentialVault(storage: storage)
        try vault.delete(keys[3])
        // The previous app may still exist or update its own credentials later.
        storage.put(Data("malformed-old-vault".utf8), for: CredentialVault.legacyStorageKey)
        let oldReads = storage.loads(CredentialVault.legacyStorageKey)
        #expect(try CredentialVault(storage: storage).load(keys[3]) == nil)
        #expect(storage.loads(CredentialVault.legacyStorageKey) == oldReads)
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
