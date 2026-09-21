import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Zoom connect link requests") @MainActor
struct ZoomConnectLinkRequestTests {
    @Test func disconnectDuringStatusCheckDoesNotRestartSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let request = ZoomConnectLinkRequest(connection: fixture.model.zoomConnection)
        let task = Task { await request.perform(on: fixture.model) }
        await fixture.store.waitForStatusRead()
        await fixture.model.zoomConnection.disconnect()
        let disconnectedRevision = fixture.model.zoomConnection.accountRevision
        await fixture.store.resumeStatusRead()
        await task.value
        #expect(await fixture.network.requestCount == 0)
        #expect(fixture.model.zoomConnection.accountRevision == disconnectedRevision)
        #expect(!fixture.model.zoomConnection.hasSavedConnection)
    }

    @Test func previewDuringStatusCheckDoesNotStartLiveSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let request = ZoomConnectLinkRequest(connection: fixture.model.zoomConnection)
        let revision = fixture.model.zoomConnection.accountRevision
        let task = Task { await request.perform(on: fixture.model) }
        await fixture.store.waitForStatusRead()
        fixture.model.enterPreview()
        await fixture.store.resumeStatusRead()
        await task.value
        #expect(fixture.model.isPreview)
        #expect(await fixture.network.requestCount == 0)
        #expect(fixture.model.zoomConnection.accountRevision == revision)
    }

    @Test func cancelledRequestDoesNotStartSignInWhenStatusReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let request = ZoomConnectLinkRequest(connection: fixture.model.zoomConnection)
        let task = Task { await request.perform(on: fixture.model) }
        await fixture.store.waitForStatusRead()
        task.cancel()
        await fixture.store.resumeStatusRead()
        await task.value
        #expect(await fixture.network.requestCount == 0)
    }

    @Test func failedStatusCheckDoesNotTreatUnknownCredentialsAsSignedOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let request = ZoomConnectLinkRequest(connection: fixture.model.zoomConnection)
        let task = Task { await request.perform(on: fixture.model) }
        await fixture.store.waitForStatusRead()
        await fixture.store.resumeStatusRead(failing: true)
        await task.value
        #expect(fixture.model.zoomConnection.statusError != nil)
        #expect(await fixture.network.requestCount == 0)
    }

    @Test(arguments: [false, true])
    func completedStatusCheckStartsSignInOnlyWithoutSavedCredentials(connected: Bool) async throws {
        let fixture = try Fixture(connected: connected)
        defer { fixture.cleanUp() }
        let request = ZoomConnectLinkRequest(connection: fixture.model.zoomConnection)
        let task = Task { await request.perform(on: fixture.model) }
        await fixture.store.waitForStatusRead()
        await fixture.store.resumeStatusRead()
        await task.value
        #expect(await fixture.network.requestCount == (connected ? 0 : 1))
        #expect(fixture.model.zoomConnection.hasSavedConnection == connected)
    }

    @MainActor private struct Fixture {
        let store: ConnectLinkStore
        let network = ConnectLinkNetwork()
        let model: YapModel
        let preferences: UserDefaults
        let suite = "yap-connect-link-\(UUID().uuidString)"

        init(connected: Bool = false) throws {
            preferences = try #require(UserDefaults(suiteName: suite))
            store = ConnectLinkStore(connected: connected)
            let network = network
            let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { request in
                await network.rejectSession(request)
            }, publicConfiguration: ZoomPublicConfiguration(oauthPublicClientID: "fixture-public",
                sdkClientID: "fixture-sdk", sdkSignerURL: URL(string: "https://fixture.example/v1/meeting-sdk/signature")!))
            let connection = ZoomConnectionModel(client: client, openURL: { _ in
                Issue.record("The fixture must never open a real authorization page")
            }, onSignInCompleted: {})
            model = YapModel(preview: false, preferences: preferences,
                meeting: MeetingCoordinator(driver: DemoMeetingDriver()), zoomConnection: connection,
                reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
        }

        func cleanUp() { preferences.removePersistentDomain(forName: suite) }
    }
}

private actor ConnectLinkStore: ZoomCredentialStore {
    private var tokens: ZoomOAuthTokens?
    private var shouldPause = true
    private var statusRead: CheckedContinuation<Void, Error>?
    private var waitingForRead: CheckedContinuation<Void, Never>?

    init(connected: Bool) {
        if connected {
            tokens = ZoomOAuthTokens(clientID: "fixture-public", accessToken: "fixture-access",
                refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3_600))
        }
    }

    func loadConfiguration() async throws -> ZoomPersonalConfiguration? {
        if shouldPause {
            shouldPause = false
            try await withCheckedThrowingContinuation { continuation in
                statusRead = continuation
                waitingForRead?.resume()
                waitingForRead = nil
            }
        }
        return nil
    }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) {}
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ tokens: ZoomOAuthTokens) { self.tokens = tokens }
    func deleteTokens() { tokens = nil }
    func deleteAll() { tokens = nil }
    func waitForStatusRead() async {
        if statusRead != nil { return }
        await withCheckedContinuation { waitingForRead = $0 }
    }
    func resumeStatusRead(failing: Bool = false) {
        let continuation = statusRead
        statusRead = nil
        if failing { continuation?.resume(throwing: ZoomAccountError.keychain(-1)) }
        else { continuation?.resume() }
    }
}

private actor ConnectLinkNetwork {
    private(set) var requestCount = 0

    func rejectSession(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requestCount += 1
        // Stop at the first authorization request; this test does not open a browser.
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
    }
}
