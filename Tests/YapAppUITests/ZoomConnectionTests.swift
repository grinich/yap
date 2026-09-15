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
        var completed = false
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in browser.opened() },
                                        onSignInCompleted: { completed = true })
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
        #expect(!completed)
    }

    @Test(arguments: [true, false])
    func returnsToAppOnlyAfterSuccessfulTokenExchange(succeeds: Bool) async throws {
        let store = ZoomUIFixtureStore(configuration: configuration)
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { request in
            let body = request.url?.path == "/v2/users/me/zak" ? #"{"token":"fixture-zak"}"#
                : #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","token_type":"bearer","expires_in":3600,"scope":"user:read:zak"}"#
            let data = Data(body.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: succeeds ? 200 : 400,
                                         httpVersion: nil, headerFields: nil)!)
        })
        var completed = 0
        let model = ZoomConnectionModel(client: client, openURL: { url in
            Task {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let redirect = query.first(where: { $0.name == "redirect_uri" })?.value,
                      let state = query.first(where: { $0.name == "state" })?.value,
                      var callback = URLComponents(string: redirect) else { return }
                callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
                if let callbackURL = callback.url { _ = try? await URLSession.shared.data(from: callbackURL) }
            }
        }, onSignInCompleted: { completed += 1 })
        await model.connect()
        #expect(completed == (succeeds ? 1 : 0))
        #expect(model.hasSavedConnection == succeeds)
        #expect((model.error == nil) == succeeds)
    }

    @Test(arguments: [true, false])
    func recoverySignsInDirectlyAndSurfacesFailuresOutsideSettings(succeeds: Bool) async throws {
        let store = ZoomUIFixtureStore(configuration: configuration)
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { request in
            let body = request.url?.path == "/v2/users/me/zak" ? #"{"token":"fixture-zak"}"#
                : #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","token_type":"bearer","expires_in":3600,"scope":"user:read:zak"}"#
            let data = Data(body.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: succeeds ? 200 : 400,
                                         httpVersion: nil, headerFields: nil)!)
        })
        var browserOpens = 0
        let connection = ZoomConnectionModel(client: client, openURL: { url in
            browserOpens += 1
            Task {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let redirect = query.first(where: { $0.name == "redirect_uri" })?.value,
                      let state = query.first(where: { $0.name == "state" })?.value,
                      var callback = URLComponents(string: redirect) else { return }
                callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
                if let url = callback.url { _ = try? await URLSession.shared.data(from: url) }
            }
        }, onSignInCompleted: {})
        let suite = "yap-recovery-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let app = YapModel(preview: false, preferences: preferences,
                           meeting: MeetingCoordinator(driver: DemoMeetingDriver()), zoomConnection: connection,
                           reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
        let recovery = try #require(app.recordings.zoomSignInRecovery)
        app.recordings.isPresented = true
        app.error = ZoomAccountError.notConnected.localizedDescription
        let revision = connection.accountRevision
        #expect(recovery.isEnabled)
        await recovery.signIn()
        #expect(browserOpens == 1)
        #expect(connection.accountRevision != revision)
        #expect(connection.hasSavedConnection == succeeds)
        #expect(app.error == (succeeds ? nil : ZoomAccountError.notConnected.localizedDescription))
        #expect(app.recordings.isPresented)
        #expect(!app.showSettings)
        #expect(!recovery.isConnecting)

        await app.meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Fixture")
        let callRevision = connection.accountRevision
        #expect(!recovery.isEnabled)
        await recovery.signIn()
        #expect(browserOpens == 1)
        #expect(connection.accountRevision == callRevision)
        #expect(app.activeCall)
        await app.leaveMeeting()
    }

    @Test func signInRecoveryOnlyMatchesAuthenticationFailures() {
        for error: ZoomAccountError in [.notConnected, .signingDenied, .authorizationDenied,
                                       .authorizationTimedOut, .missingScope, .missingHostingScope,
                                       .missingRecordingScope, .rejected(401)] {
            #expect(ZoomSignInError.matches(error.localizedDescription))
        }
        for error: ZoomAccountError in [.network, .rateLimited, .recordingUnavailable,
                                       .notConfigured, .invalidPublicConfiguration, .rejected(500),
                                       .meetingCreationUnconfirmed] {
            #expect(!ZoomSignInError.matches(error.localizedDescription))
        }
        #expect(!ZoomSignInError.matches(nil))
        #expect(!ZoomSignInError.matches("Google sign-in expired"))
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
