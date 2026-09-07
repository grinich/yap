import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Manual Zoom configuration") @MainActor
struct ManualZoomConfigurationTests {
    private let original = ZoomPersonalConfiguration(sdkClientID: "original-sdk", sdkClientSecret: "fixture-original-secret", oauthPublicClientID: "original-public")

    @Test func manualSaveNormalizesAndReplacesTheSavedConnection() async throws {
        let store = ManualZoomCredentialFixture(configuration: original)
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        await model.loadStatus()
        #expect(model.hasSavedConnection)
        let replacement = ZoomPersonalConfiguration(sdkClientID: " replacement-sdk\n", sdkClientSecret: " fixture-replacement-secret\n", oauthPublicClientID: " replacement-public ")
        #expect(await model.saveConfiguration(replacement))
        #expect(model.isConfigured)
        #expect(!model.hasSavedConnection)
        #expect(!model.isBusy)
        #expect(model.error == nil)
        let saved = await store.loadConfiguration()
        #expect(saved?.sdkClientID == "replacement-sdk")
        #expect(saved?.oauthPublicClientID == "replacement-public")
        #expect(await store.loadTokens() == nil)
    }

    @Test func invalidManualValuesNeverReplaceAnExistingConnection() async throws {
        let store = ManualZoomCredentialFixture(configuration: original)
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        await model.loadStatus()
        for secret in ["", "embedded whitespace", String(repeating: "x", count: 1_025)] {
            let invalid = ZoomPersonalConfiguration(sdkClientID: "replacement-sdk", sdkClientSecret: secret, oauthPublicClientID: "replacement-public")
            #expect(!(await model.saveConfiguration(invalid)))
            #expect(model.isConfigured)
            #expect(model.hasSavedConnection)
            #expect(!model.isBusy)
            #expect(model.error == ZoomAccountError.invalidConfiguration.localizedDescription)
        }
        #expect(await store.saveCount == 0)
        #expect(await store.loadConfiguration()?.sdkClientID == original.sdkClientID)
        #expect(await store.loadTokens() != nil)
    }

    @Test func anotherManualSaveCannotInterleaveWithAPendingSave() async throws {
        let store = ManualZoomCredentialFixture(configuration: original, pauseSave: true)
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        let first = ZoomPersonalConfiguration(sdkClientID: "first-sdk", sdkClientSecret: "fixture-secret", oauthPublicClientID: "first-public")
        let second = ZoomPersonalConfiguration(sdkClientID: "second-sdk", sdkClientSecret: "fixture-secret", oauthPublicClientID: "second-public")
        let pending = Task { await model.saveConfiguration(first) }
        await store.waitForSave()
        #expect(model.isUpdatingConfiguration)
        #expect(!(await model.saveConfiguration(second)))
        await store.releaseSave()
        #expect(await pending.value)
        #expect(await store.saveCount == 1)
        #expect(await store.loadConfiguration()?.sdkClientID == first.sdkClientID)
        #expect(!model.isBusy)
    }
}

private actor ManualZoomCredentialFixture: ZoomCredentialStore {
    private var configuration: ZoomPersonalConfiguration?
    private var tokens: ZoomOAuthTokens?
    private var pauseSave: Bool
    private var saveGate: CheckedContinuation<Void, Never>?
    private var saveStarted: CheckedContinuation<Void, Never>?
    private(set) var saveCount = 0

    init(configuration: ZoomPersonalConfiguration, pauseSave: Bool = false) {
        self.configuration = configuration
        self.pauseSave = pauseSave
        tokens = ZoomOAuthTokens(clientID: configuration.oauthPublicClientID, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3_600))
    }

    func loadConfiguration() -> ZoomPersonalConfiguration? { configuration }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) async {
        saveCount += 1
        if pauseSave {
            pauseSave = false
            await withCheckedContinuation { continuation in
                saveGate = continuation
                saveStarted?.resume()
                saveStarted = nil
            }
        }
        self.configuration = configuration
    }
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ tokens: ZoomOAuthTokens) { self.tokens = tokens }
    func deleteTokens() { tokens = nil }
    func deleteAll() { configuration = nil; tokens = nil }
    func waitForSave() async {
        if saveGate != nil { return }
        await withCheckedContinuation { saveStarted = $0 }
    }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
}
