import Foundation
import Security
import Synchronization
import Testing
import YapCredentials
import YapMeetings
@testable import YapAppUI

@Suite("Zoom connection settings") @MainActor
struct ZoomConnectionTests {
    private let configuration = ZoomPersonalConfiguration(sdkClientID: "fixture-sdk", sdkClientSecret: "fixture-secret",
                                                           oauthPublicClientID: "fixture-public")

    @Test func staleStatusErrorCannotOverwriteCompletedDisconnect() async throws {
        let store = ZoomUIFixtureStore(configuration: configuration, delayFirstStatus: true)
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        let staleLoad = Task { await model.loadStatus() }
        await store.waitForStatusRead()
        await model.disconnect()
        #expect(model.isConfigured)
        #expect(!model.hasSavedConnection)
        #expect(!model.isBusy)
        await store.failDelayedStatusRead()
        await staleLoad.value
        #expect(model.error == nil)
        #expect(model.isConfigured)
        #expect(!model.hasSavedConnection)
    }

    @Test func cancelSignInReturnsToDisconnectedStateWithoutError() async throws {
        let store = ZoomUIFixtureStore(configuration: configuration)
        let browser = ZoomBrowserProbe()
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in browser.opened() })
        await model.loadStatus()
        let signIn = Task { await model.connect() }
        let deadline = Task { try await Task.sleep(for: .seconds(5)); signIn.cancel(); browser.opened() }
        defer { deadline.cancel() }
        await browser.waitUntilOpened()
        #expect(model.isConnecting)
        await model.disconnect()
        await signIn.value
        #expect(!model.isConnecting)
        #expect(!model.isUpdatingConfiguration)
        #expect(!model.hasSavedConnection)
        #expect(model.isConfigured)
        #expect(model.error == nil)
    }

    @Test func failedImportPreservesConnectionAndSuccessfulImportClearsOldError() async throws {
        let store = ZoomUIFixtureStore(configuration: configuration, connected: true)
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yap-zoom-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidURL = directory.appendingPathComponent("invalid.json")
        let validURL = directory.appendingPathComponent("valid.json")
        try Data(repeating: 32, count: 32_768).write(to: invalidURL)
        try JSONEncoder().encode(configuration).write(to: validURL)
        await model.loadStatus()
        #expect(model.hasSavedConnection)
        await model.importConfiguration(from: invalidURL)
        #expect(model.error == ZoomAccountError.invalidConfiguration.localizedDescription)
        #expect(model.hasSavedConnection)
        #expect(!model.isBusy)
        await model.importConfiguration(from: validURL)
        #expect(model.error == nil)
        #expect(model.isConfigured)
        #expect(!model.hasSavedConnection)
        #expect(!model.isBusy)
    }

    @Test(arguments: [false, true])
    func disconnectUsesActiveVaultAndReportsOnlyActiveWriteFailures(denyLegacyCleanup: Bool) async throws {
        let configurationKey = CredentialKey(service: "app.yap.zoom-personal", account: "configuration")
        let tokensKey = CredentialKey(service: "app.yap.zoom-personal", account: "oauth-tokens")
        let tokens = ZoomOAuthTokens(clientID: configuration.oauthPublicClientID, accessToken: "fixture-access",
                                    refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3_600))
        let storage = ZoomDisconnectCredentialStorage(records: [
            configurationKey: try JSONEncoder().encode(configuration),
            tokensKey: try JSONEncoder().encode(tokens)
        ])
        let vault = CredentialVault(storage: storage)
        try vault.save(JSONEncoder().encode(configuration), for: configurationKey)
        try vault.save(JSONEncoder().encode(tokens), for: tokensKey)
        let client = ZoomAccountClient(store: KeychainZoomCredentialStore(vault: vault))
        let model = ZoomConnectionModel(client: client, openURL: { _ in })
        await model.loadStatus()
        #expect(model.hasSavedConnection)
        storage.denyNextDisconnect(legacyCleanup: denyLegacyCleanup)

        await model.disconnect()

        #expect(model.hasLoadedStatus)
        #expect(model.isConfigured)
        #expect(model.hasSavedConnection == !denyLegacyCleanup)
        #expect(!model.isBusy)
        #expect(model.statusError == nil)
        #expect(model.error == (denyLegacyCleanup ? nil : ZoomAccountError.keychain(errSecAuthFailed).localizedDescription))
        // Only the active vault determines the durable connection state.
        // Old protected items are never accessed or removed.
        let nextLaunch = CredentialVault(storage: storage)
        #expect((try nextLaunch.load(tokensKey) == nil) == denyLegacyCleanup)
        #expect(storage.contains(tokensKey))
    }

    @Test(arguments: [false, true])
    func managedSwitchUsesAtomicVaultResultAndIgnoresProtectedOldItems(denyLegacyCleanup: Bool) async throws {
        let configurationKey = CredentialKey(service: "app.yap.zoom-personal", account: "configuration")
        let tokensKey = CredentialKey(service: "app.yap.zoom-personal", account: "oauth-tokens")
        let oldTokensKey = CredentialKey(service: "app.whoosh.zoom-personal", account: "oauth-tokens")
        let oldConfigurationKey = CredentialKey(service: "app.whoosh.zoom-personal", account: "configuration")
        let googleKey = CredentialKey(service: "app.yap.google-calendar", account: "personal")
        let tokens = ZoomOAuthTokens(clientID: configuration.oauthPublicClientID, accessToken: "fixture-access",
                                    refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3_600))
        let configurationData = try JSONEncoder().encode(configuration)
        let tokenData = try JSONEncoder().encode(tokens)
        let storage = ZoomDisconnectCredentialStorage(records: [
            configurationKey: configurationData, tokensKey: tokenData,
            oldConfigurationKey: configurationData, oldTokensKey: tokenData
        ])
        let vault = CredentialVault(storage: storage)
        try vault.save(configurationData, for: configurationKey)
        try vault.save(tokenData, for: tokensKey)
        try vault.save(Data("saved-google".utf8), for: googleKey)
        let managed = ZoomPublicConfiguration(oauthPublicClientID: "managed-public", sdkClientID: "managed-sdk",
            sdkSignerURL: URL(string: "https://signer.example/v1/meeting-sdk/signature")!)
        let client = ZoomAccountClient(store: KeychainZoomCredentialStore(vault: vault), publicConfiguration: managed)
        let model = ZoomConnectionModel(client: client, openURL: { _ in Issue.record("Switching mode must not open authorization") })
        await model.loadStatus()
        #expect(model.configurationMode == .personal)
        #expect(model.hasSavedConnection)
        let previousRevision = model.accountRevision
        var invalidations = 0
        model.onAccountWillChange = { invalidations += 1 }
        if denyLegacyCleanup { storage.denyDeletion(oldTokensKey) }
        else { storage.denyNextDisconnect(legacyCleanup: false) }

        await model.usePublicConfiguration()

        #expect(model.configurationMode == (denyLegacyCleanup ? .managed : .personal))
        #expect(model.hasSavedConnection == !denyLegacyCleanup)
        #expect(model.isConfigured)
        #expect(model.hasLoadedStatus)
        #expect(!model.isBusy)
        #expect(!model.isLoadingStatus)
        #expect(model.statusError == nil)
        #expect(model.error == (denyLegacyCleanup ? nil : ZoomAccountError.keychain(errSecAuthFailed).localizedDescription))
        #expect(model.accountRevision != previousRevision)
        #expect(invalidations == 1)
        let nextLaunch = CredentialVault(storage: storage)
        #expect((try nextLaunch.load(configurationKey) == nil) == denyLegacyCleanup)
        #expect((try nextLaunch.load(tokensKey) == nil) == denyLegacyCleanup)
        #expect(try nextLaunch.load(googleKey) == Data("saved-google".utf8))
        #expect(storage.contains(oldTokensKey)) // Its existing protection was honored.
        #expect(storage.contains(oldConfigurationKey))
        #expect(storage.deletions.isEmpty)
    }
}

private final class ZoomDisconnectCredentialStorage: CredentialStorage, Sendable {
    private struct State {
        var records: [CredentialKey: Data]
        var denyWrite = false
        var denyDelete = false
        var deniedKey: CredentialKey?
        var deletions: [CredentialKey] = []
    }
    private let state: Mutex<State>

    init(records: [CredentialKey: Data]) { state = Mutex(State(records: records)) }

    func denyNextDisconnect(legacyCleanup: Bool) {
        state.withLock {
            $0.denyWrite = !legacyCleanup
            $0.denyDelete = legacyCleanup
        }
    }
    func contains(_ key: CredentialKey) -> Bool { state.withLock { $0.records[key] != nil } }
    func denyDeletion(_ key: CredentialKey) { state.withLock { $0.deniedKey = key } }
    var deletions: [CredentialKey] { state.withLock { $0.deletions } }
    func load(_ key: CredentialKey) -> Data? { state.withLock { $0.records[key] } }
    func save(_ data: Data, for key: CredentialKey) throws {
        try state.withLock {
            if $0.denyWrite { throw CredentialVaultError.keychain(errSecAuthFailed) }
            $0.records[key] = data
        }
    }
    func delete(_ key: CredentialKey) throws {
        try state.withLock {
            $0.deletions.append(key)
            if $0.denyDelete || $0.deniedKey == key { throw CredentialVaultError.keychain(errSecAuthFailed) }
            $0.records.removeValue(forKey: key)
        }
    }
}

private actor ZoomUIFixtureStore: ZoomCredentialStore {
    private var configuration: ZoomPersonalConfiguration?
    private var tokens: ZoomOAuthTokens?
    private var delayFirstStatus: Bool
    private var statusGate: CheckedContinuation<Void, Error>?
    private var statusStarted: CheckedContinuation<Void, Never>?

    init(configuration: ZoomPersonalConfiguration, connected: Bool = false, delayFirstStatus: Bool = false) {
        self.configuration = configuration
        self.delayFirstStatus = delayFirstStatus
        if connected {
            tokens = ZoomOAuthTokens(clientID: configuration.oauthPublicClientID, accessToken: "fixture-access",
                                     refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3_600))
        }
    }

    func loadConfiguration() async throws -> ZoomPersonalConfiguration? {
        if delayFirstStatus {
            delayFirstStatus = false
            try await withCheckedThrowingContinuation { continuation in
                statusGate = continuation
                statusStarted?.resume()
                statusStarted = nil
            }
        }
        return configuration
    }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) { self.configuration = configuration }
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ tokens: ZoomOAuthTokens) { self.tokens = tokens }
    func deleteTokens() { tokens = nil }
    func deleteAll() { configuration = nil; tokens = nil }
    func waitForStatusRead() async {
        if statusGate != nil { return }
        await withCheckedContinuation { statusStarted = $0 }
    }
    func failDelayedStatusRead() { statusGate?.resume(throwing: ZoomAccountError.keychain(-1)); statusGate = nil }
}

@MainActor
private final class ZoomBrowserProbe {
    private var didOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func opened() { didOpen = true; waiter?.resume(); waiter = nil }
    func waitUntilOpened() async {
        if didOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
