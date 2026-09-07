import Foundation
import Testing
@testable import YapCalendar

@Suite("Calendar adversarial state")
struct CalendarAdversarialTests {
    let configuration = GoogleOAuthConfiguration(clientID: "calendar-tests.apps.googleusercontent.com")
    let calendarA = GoogleCalendar(id: "a", name: "A")
    let calendarB = GoogleCalendar(id: "b", name: "B")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var end: Date { start.addingTimeInterval(86_400) }

    @Test func cacheIsBoundToTheConnectedAccount() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = AdversarialTokenStore()
        let network = CalendarNetworkScript([.init(body: eventPage("first"))])
        let client = makeClient(store, network, path)
        _ = try await client.events(in: [calendarA], from: start, to: end)
        #expect(try await client.cachedSnapshot()?.events.count == 1)
        await store.replaceWithAnotherAccount()
        let newClient = makeClient(store, network, path)
        #expect(try await newClient.cachedSnapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func cacheSurvivesTokenRefreshForSameConnection() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = AdversarialTokenStore()
        let network = CalendarNetworkScript([.init(body: eventPage("first")),
                                             .init(body: #"{"access_token":"refreshed","expires_in":3600,"token_type":"Bearer"}"#),
                                             .init(body: #"{"items":[{"id":"a","summary":"A","accessRole":"reader"}]}"#)])
        _ = try await makeClient(store, network, path).events(in: [calendarA], from: start, to: end)
        let originalID = await store.tokens?.connectionID
        await store.expireAccessToken()
        let restarted = makeClient(store, network, path)
        _ = try await restarted.calendars()
        #expect(await store.tokens?.connectionID == originalID)
        #expect(try await restarted.cachedSnapshot()?.events.count == 1)
    }

    @Test func wrongOAuthClientCannotLoadCredentialsOrAgenda() async throws {
        let store = AdversarialTokenStore(clientID: "another.apps.googleusercontent.com")
        let network = CalendarNetworkScript([])
        let client = makeClient(store, network, nil)
        await #expect(throws: GoogleCalendarError.signInExpired) { try await client.hasCredentials() }
        #expect(await network.requests.isEmpty)
    }

    @Test func disconnectClearsCacheEvenWhenKeychainDeletionFails() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = AdversarialTokenStore()
        let network = CalendarNetworkScript([.init(body: eventPage("first"))])
        let client = makeClient(store, network, path)
        _ = try await client.events(in: [calendarA], from: start, to: end)
        await store.setDeleteFailure()
        await #expect(throws: GoogleCalendarError.keychain(-1)) { try await client.disconnect() }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try await !client.hasCredentials())
        #expect(try await client.cachedSnapshot() == nil)
    }

    @Test func clearingCacheCannotBeUndoneByAnOlderRequest() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let network = CalendarNetworkScript([.init(body: eventPage("late"), pause: true)])
        let client = makeClient(AdversarialTokenStore(), network, path)
        let request = Task { try await client.events(in: [calendarA], from: start, to: end) }
        await network.waitUntilPaused()
        try await client.clearCachedEvents()
        await network.release()
        _ = try await request.value
        #expect(try await client.cachedSnapshot() == nil)
    }

    @Test func failedRefreshKeepsOnlySelectedCalendarsInCache() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let network = CalendarNetworkScript([.init(body: eventPage("a")), .init(body: eventPage("b")), .init(status: 503, body: "{}")])
        let client = makeClient(AdversarialTokenStore(), network, path)
        _ = try await client.events(in: [calendarA, calendarB], from: start, to: end)
        await #expect(throws: GoogleCalendarError.httpStatus(503)) { try await client.events(in: [calendarA], from: start, to: end) }
        #expect(try await client.cachedSnapshot()?.events.map(\.calendarID) == ["a"])
        #expect(try await client.cachedSnapshot()?.calendarIDs == ["a"])
    }

    @Test func inaccessibleCalendarIsRemovedFromCachedSnapshot() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let network = CalendarNetworkScript([.init(body: eventPage("a")), .init(body: eventPage("b")),
                                             .init(body: eventPage("a-new")), .init(status: 404, body: "{}")])
        let client = makeClient(AdversarialTokenStore(), network, path)
        _ = try await client.events(in: [calendarA, calendarB], from: start, to: end)
        await #expect(throws: GoogleCalendarError.httpStatus(404)) { try await client.events(in: [calendarA, calendarB], from: start, to: end) }
        #expect(try await client.cachedSnapshot()?.events.map(\.calendarID) == ["a"])
    }

    @Test func completeCalendarListPrunesRemovedAndFreeBusyOnlyCalendars() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let network = CalendarNetworkScript([
            .init(body: eventPage("a")), .init(body: eventPage("b")),
            .init(body: #"{"items":[{"id":"a","summary":"A renamed","accessRole":"reader"}],"nextPageToken":"next"}"#),
            .init(body: #"{"items":[{"id":"b","summary":"B","accessRole":"freeBusyReader"},{"id":"c","summary":"New calendar","accessRole":"owner"}]}"#)
        ])
        let client = makeClient(AdversarialTokenStore(), network, path)
        _ = try await client.events(in: [calendarA, calendarB], from: start, to: end)
        let listed = try await client.calendars()
        #expect(listed.map(\.id) == ["a", "c"])
        #expect(listed.first?.name == "A renamed")
        #expect(try await client.cachedSnapshot()?.events.map(\.calendarID) == ["a"])
        let query = URLComponents(url: await network.requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "minAccessRole" })?.value == "reader")
        #expect(query.first(where: { $0.name == "showHidden" })?.value == "true")
    }

    @Test func incompleteCalendarListDoesNotRemoveStillAccessibleCachedCalendars() async throws {
        let path = temporaryCache()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let network = CalendarNetworkScript([
            .init(body: eventPage("a")), .init(body: eventPage("b")),
            .init(body: #"{"items":[{"id":"a","summary":"A"}],"nextPageToken":"next"}"#),
            .init(status: 503, body: "{}")
        ])
        let client = makeClient(AdversarialTokenStore(), network, path)
        _ = try await client.events(in: [calendarA, calendarB], from: start, to: end)
        await #expect(throws: GoogleCalendarError.httpStatus(503)) { try await client.calendars() }
        #expect(try await client.cachedSnapshot()?.events.map(\.calendarID) == ["a", "b"])
    }

    @Test func concurrentExpiredRequestsShareOneRefreshAndOneSave() async throws {
        let store = AdversarialTokenStore(expired: true)
        let network = CalendarNetworkScript([
            .init(body: #"{"access_token":"refreshed","expires_in":3600,"token_type":"Bearer"}"#, pause: true),
            .init(body: #"{"items":[]}"#), .init(body: #"{"items":[]}"#)
        ])
        let client = makeClient(store, network, nil)
        let one = Task { try await client.calendars() }
        await network.waitUntilPaused()
        let two = Task { try await client.calendars() }
        await network.release()
        _ = try await one.value
        _ = try await two.value
        #expect(await network.requests.filter { $0.url?.host == "oauth2.googleapis.com" }.count == 1)
        #expect(await store.saveCount == 1)
    }

    @Test func disconnectWaitsForPendingSaveThenRemovesTheCredential() async throws {
        let store = AdversarialTokenStore(expired: true, pauseSave: true)
        let network = CalendarNetworkScript([.init(body: #"{"access_token":"refreshed","expires_in":3600,"token_type":"Bearer"}"#)])
        let client = makeClient(store, network, nil)
        let refresh = Task { try await client.calendars() }
        await store.waitUntilSaving()
        let disconnect = Task { try await client.disconnect() }
        for _ in 0..<100 where try await client.hasCredentials() { await Task.yield() }
        #expect(try await !client.hasCredentials())
        await store.releaseSave()
        try await disconnect.value
        do { _ = try await refresh.value; Issue.record("The cancelled refresh unexpectedly completed.") }
        catch is CancellationError { }
        #expect(await store.tokens == nil)
        #expect(try await !client.hasCredentials())
    }

    @Test func lateRefreshCannotRestoreCredentialsAfterDisconnect() async throws {
        let store = AdversarialTokenStore(expired: true)
        let network = CalendarNetworkScript([.init(body: #"{"access_token":"late","expires_in":3600,"token_type":"Bearer"}"#, pause: true)])
        let client = makeClient(store, network, nil)
        let refresh = Task { try await client.calendars() }
        await network.waitUntilPaused()
        try await client.disconnect()
        await network.release()
        do { _ = try await refresh.value; Issue.record("The disconnected refresh unexpectedly completed.") }
        catch is CancellationError { }
        #expect(await store.tokens == nil)
        #expect(await store.saveCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAP_TEST_LOOPBACK"] == "1"))
    func anOldRefreshCannotOverwriteANewAccountDuringCredentialSave() async throws {
        let store = AdversarialTokenStore(expired: true, pauseSave: true)
        let network = CalendarNetworkScript([
            .init(body: #"{"access_token":"old-account-refreshed","expires_in":3600,"token_type":"Bearer"}"#, pause: true),
            .init(body: #"{"access_token":"new-account","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#),
            .init(body: #"{"items":[]}"#)
        ])
        let client = makeClient(store, network, nil)
        let oldRefresh = Task { try await client.calendars() }
        await network.waitUntilPaused()
        let newConnection = Task {
            try await client.connect { url in Task { await sendSyntheticCallback(for: url) } }
        }
        await store.waitUntilSaving()
        await network.release()
        await #expect(throws: CancellationError.self) { try await oldRefresh.value }
        await store.releaseSave()
        _ = try await newConnection.value
        #expect(await store.tokens?.accessToken == "new-account")
        #expect(await store.tokens?.refreshToken == "new-refresh")
        #expect(await store.saveCount == 1)
    }

    private func makeClient(_ store: AdversarialTokenStore, _ network: CalendarNetworkScript, _ path: URL?) -> GoogleCalendarClient {
        GoogleCalendarClient(configuration: configuration, tokenStore: store, transport: network.transport, cacheURL: path)
    }
    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("YapAdversarial-\(UUID())").appendingPathComponent("agenda.json")
    }
    private func eventPage(_ id: String) -> String {
        "{\"items\":[{\"id\":\"\(id)\",\"start\":{\"dateTime\":\"2027-01-15T10:00:00Z\"},\"end\":{\"dateTime\":\"2027-01-15T10:30:00Z\"}}]}"
    }
}

private func sendSyntheticCallback(for authorizationURL: URL) async {
    let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let redirect = query.first(where: { $0.name == "redirect_uri" })?.value,
          let state = query.first(where: { $0.name == "state" })?.value,
          var callback = URLComponents(string: redirect) else { return }
    callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "fake-code-for-new-account")]
    guard let url = callback.url else { return }
    _ = try? await URLSession.shared.data(from: url)
}

private actor AdversarialTokenStore: GoogleTokenStore {
    var tokens: GoogleOAuthTokens?
    var deleteFails = false
    var pauseSave: Bool
    var saveCount = 0
    var saving = false
    var savedWaiter: CheckedContinuation<Void, Never>?
    var saveContinuation: CheckedContinuation<Void, Never>?

    init(expired: Bool = false, pauseSave: Bool = false, clientID: String? = nil) {
        tokens = GoogleOAuthTokens(accessToken: "test-access", refreshToken: "test-refresh", expiresAt: expired ? .distantPast : .distantFuture, clientID: clientID)
        self.pauseSave = pauseSave
    }
    func load() -> GoogleOAuthTokens? { tokens }
    func save(_ value: GoogleOAuthTokens) async {
        if pauseSave {
            pauseSave = false; saving = true
            savedWaiter?.resume(); savedWaiter = nil
            await withCheckedContinuation { saveContinuation = $0 }
        }
        tokens = value; saveCount += 1
    }
    func delete() throws {
        if deleteFails { throw GoogleCalendarError.keychain(-1) }
        tokens = nil
    }
    func setDeleteFailure() { deleteFails = true }
    func replaceWithAnotherAccount() { tokens = .init(accessToken: "other-access", refreshToken: "other-refresh", expiresAt: .distantFuture) }
    func expireAccessToken() {
        guard let tokens else { return }
        self.tokens = .init(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: .distantPast,
                            connectionID: tokens.connectionID, clientID: tokens.clientID)
    }
    func waitUntilSaving() async {
        if saving { return }
        await withCheckedContinuation { savedWaiter = $0 }
    }
    func releaseSave() { saveContinuation?.resume(); saveContinuation = nil }
}

private actor CalendarNetworkScript {
    struct Response: Sendable { var status = 200; let body: String; var pause = false }
    var responses: [Response]
    var requests: [URLRequest] = []
    var paused = false
    var pauseWaiter: CheckedContinuation<Void, Never>?
    var responseWaiter: CheckedContinuation<Void, Never>?
    init(_ responses: [Response]) { self.responses = responses }
    nonisolated var transport: CalendarHTTPTransport { CalendarHTTPTransport { try await self.send($0) } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw GoogleCalendarError.invalidResponse }
        let response = responses.removeFirst()
        if response.pause {
            paused = true
            pauseWaiter?.resume(); pauseWaiter = nil
            await withCheckedContinuation { responseWaiter = $0 }
        }
        return (Data(response.body.utf8), HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func release() { responseWaiter?.resume(); responseWaiter = nil; paused = false }
}
