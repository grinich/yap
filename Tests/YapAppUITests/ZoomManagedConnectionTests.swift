import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Managed Zoom connection setup") @MainActor
struct ZoomManagedConnectionTests {
    private let configuration = ZoomPublicConfiguration(oauthPublicClientID: "fixture-public", sdkClientID: "fixture-sdk",
        sdkSignerURL: URL(string: "https://signer.example/v1/meeting-sdk/signature")!)

    @Test func bundledSetupOffersSignInWithoutWritingDeveloperSecrets() async {
        let store = ManagedConnectionStore()
        let client = ZoomAccountClient(store: store, publicConfiguration: configuration)
        let model = ZoomConnectionModel(client: client, openURL: { _ in })
        await model.loadStatus()
        #expect(model.hasPublicConfiguration)
        #expect(model.hasLoadedStatus)
        #expect(model.isConfigured)
        #expect(model.configurationMode == .managed)
        #expect(!model.hasSavedConnection)
        #expect(model.statusError == nil)
        #expect(await store.configuration == nil)
        #expect(await store.saveCount == 0)
    }

    @Test func switchingFromDeveloperSetupInvalidatesAccountAndUsesBundledSignIn() async throws {
        let store = ManagedConnectionStore()
        await store.saveConfiguration(.init(sdkClientID: "personal-sdk", sdkClientSecret: "fixture-personal-secret",
                                            oauthPublicClientID: "personal-public"))
        await store.saveTokens(.init(clientID: "personal-public", accessToken: "fixture-access",
                                    refreshToken: "fixture-refresh", expiresAt: .now.addingTimeInterval(3_600)))
        let client = ZoomAccountClient(store: store, publicConfiguration: configuration)
        let model = ZoomConnectionModel(client: client, openURL: { _ in })
        await model.loadStatus()
        #expect(model.configurationMode == .personal)
        #expect(model.hasSavedConnection)
        let revision = model.accountRevision
        var accountChanges = 0
        model.onAccountWillChange = { accountChanges += 1 }
        await model.usePublicConfiguration()
        #expect(model.configurationMode == .managed)
        #expect(model.isConfigured)
        #expect(!model.hasSavedConnection)
        #expect(model.accountRevision != revision)
        #expect(accountChanges == 1)
        #expect(await store.configuration == nil)
        #expect(await store.tokens == nil)
        #expect(model.error == nil)
    }
}

private actor ManagedConnectionStore: ZoomCredentialStore {
    private(set) var configuration: ZoomPersonalConfiguration?
    private(set) var tokens: ZoomOAuthTokens?
    private(set) var saveCount = 0
    func loadConfiguration() -> ZoomPersonalConfiguration? { configuration }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) { self.configuration = configuration; saveCount += 1 }
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ tokens: ZoomOAuthTokens) { self.tokens = tokens }
    func deleteTokens() { tokens = nil }
    func deleteAll() { configuration = nil; tokens = nil }
}
