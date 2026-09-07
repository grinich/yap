import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whoosh-zoom-ui-\(UUID().uuidString)")
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
