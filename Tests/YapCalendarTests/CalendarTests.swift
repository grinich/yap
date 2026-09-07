import Foundation
import Testing
@testable import YapCalendar

@Suite("Zoom invitation parsing")
struct ZoomInvitationTests {
    @Test func acceptsZoomLinksAndPreservesPasscode() {
        let text = "https://us02web.zoom.us/j/12345678901?pwd=abc%2Bdef&omn=93455"
        #expect(ZoomMeetingLinkParser.validatedURL(text)?.absoluteString == text)
        #expect(ZoomMeetingLinkParser.validatedURL("https://zoom.us/s/123456789") != nil)
        #expect(ZoomMeetingLinkParser.validatedURL("https://tenant.zoom.com/j/1234567890") != nil)
    }

    @Test(arguments: [
        "https://zoom.us.evil.test/j/12345678901", "https://notzoom.us/j/12345678901",
        "https://zoom.us@evil.test/j/12345678901", "https://evil@zoom.us/j/12345678901",
        "http://zoom.us/j/12345678901", "javascript:alert(1)", "https://zoom.us:8080/j/12345678901",
        "https://zoom.us./j/12345678901", "https://zoom.us/j/123", "https://zoom.us/j/123456789012",
        "https://zoom.us/j/１２３４５６７８９", "https://zoom.us/j/12345678901/evil",
        "https://zoom.us/j/%31%32%33%34%35%36%37%38%39", "https://zoom.us/wc/join/12345678901",
        "https://zoom.us/redirect?url=https://evil.test", "https://zoom.us//j/12345678901"
    ])
    func rejectsMisleadingOrUnsupportedURLs(_ input: String) {
        #expect(ZoomMeetingLinkParser.validatedURL(input) == nil)
    }

    @Test func extractsHTMLAndDeduplicates() {
        let text = #"Join <a href="https://zoom.us/j/12345678901?pwd=a&amp;omn=1">call</a>. https://zoom.us/j/12345678901?pwd=a&amp;omn=1"#
        #expect(ZoomMeetingLinkParser.links(in: text).map(\.absoluteString) == ["https://zoom.us/j/12345678901?pwd=a&omn=1"])
    }

    @Test func structuredConferenceTakesPrecedence() {
        let links = ZoomMeetingLinkParser.meetingLinks(conferenceURLs: ["https://zoom.us/j/11111111111"],
                                                       location: "https://zoom.us/j/22222222222", description: "https://zoom.us/j/33333333333")
        #expect(links.map(\.absoluteString) == ["https://zoom.us/j/11111111111"])
    }

    @Test func multipleLinksRequireUserChoice() {
        let links = ZoomMeetingLinkParser.links(in: "https://zoom.us/j/11111111111 or https://zoom.us/j/22222222222")
        let event = CalendarEvent(id: "one", title: "Ambiguous", startDate: .now, endDate: .now,
                                  calendarID: "c", calendarName: "Calendar", meetingURLs: links)
        #expect(event.meetingURLs.count == 2)
        #expect(event.meetingURL == nil)
    }
}

@Suite("Google event decoding")
struct GoogleEventDecodingTests {
    let calendar = GoogleCalendar(id: "personal@example.test", name: "Personal")

    @Test func parsesOffsetsAndRecurringInstancesIndependently() throws {
        let data = Data(#"""
        {"items":[
          {"id":"series_20260906T170000Z","summary":"Design","recurringEventId":"series","start":{"dateTime":"2026-09-06T10:00:00-07:00"},"end":{"dateTime":"2026-09-06T10:30:00-07:00"},"conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://zoom.us/j/12345678901?pwd=stay"}]}},
          {"id":"series_20260907T170000Z","summary":"Design","recurringEventId":"series","start":{"dateTime":"2026-09-07T17:00:00.123Z"},"end":{"dateTime":"2026-09-07T17:30:00.123Z"},"location":"https://zoom.us/j/12345678901"},
          {"id":"series_cancelled","status":"cancelled"}
        ]}
        """#.utf8)
        let events = try JSONDecoder().decode(GoogleEventPage.self, from: data).parsedEvents(calendar: calendar)
        #expect(events.count == 2)
        #expect(events[0].startDate.ISO8601Format() == "2026-09-06T17:00:00Z")
        #expect(events[0].endDate.timeIntervalSince(events[0].startDate) == 1_800)
        #expect(events[0].id != events[1].id)
        #expect(events[0].recurringEventID == "series")
        #expect(events[0].meetingURL?.query == "pwd=stay")
    }

    @Test func allDayUsesCalendarTimeZoneAcrossDST() throws {
        let data = Data(#"""
        {"timeZone":"America/Los_Angeles","items":[{"id":"day","start":{"date":"2026-03-08"},"end":{"date":"2026-03-09"}}]}
        """#.utf8)
        let events = try JSONDecoder().decode(GoogleEventPage.self, from: data).parsedEvents(calendar: calendar)
        #expect(events.first?.isAllDay == true)
        #expect(events.first?.startDate.ISO8601Format() == "2026-03-08T08:00:00Z")
        #expect(events[0].endDate.timeIntervalSince(events[0].startDate) == 82_800.0)
        #expect(events.first?.title == "Untitled meeting")
    }

    @Test func malformedActiveEventFailsInsteadOfInventingTime() throws {
        let page = try JSONDecoder().decode(GoogleEventPage.self, from: Data(#"{"items":[{"id":"bad","start":{"dateTime":"tomorrow"},"end":{"dateTime":"later"}}]}"#.utf8))
        #expect(throws: GoogleCalendarError.invalidResponse) { try page.parsedEvents(calendar: calendar) }
    }

    @Test func explicitTimeZoneSupportsOffsetFreeTimestamp() throws {
        let page = try JSONDecoder().decode(GoogleEventPage.self, from: Data(#"{"items":[{"id":"zoned","start":{"dateTime":"2026-09-06T10:00:00","timeZone":"America/Los_Angeles"},"end":{"dateTime":"2026-09-06T11:00:00","timeZone":"America/Los_Angeles"}}]}"#.utf8))
        #expect(try page.parsedEvents(calendar: calendar).first?.startDate.ISO8601Format() == "2026-09-06T17:00:00Z")
    }
}

@Suite("Google OAuth validation")
struct GoogleOAuthTests {
    @Test func cryptographicVerifierIsValidPKCE() throws {
        let one = try GoogleDesktopOAuth.randomToken()
        let two = try GoogleDesktopOAuth.randomToken()
        #expect(one.count == 43)
        #expect(one != two)
        #expect(one.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    @Test func callbackMustMatchStateAndContainOneCode() throws {
        #expect(try GoogleDesktopOAuth.callbackCode(target: "/?code=abc%2B123&state=expected", expectedState: "expected") == "abc+123")
        for target in ["/?code=abc&state=wrong", "/?code=abc", "/?code=a&code=b&state=expected",
                       "/?code=abc&state=expected&state=wrong", "/another?code=abc&state=expected",
                       "//evil.test/?code=abc&state=expected", "/?code=abc&state=expected#ignored",
                       "/?code=abc&error=denied&state=expected", "/?code=abc%00secret&state=expected",
                       "/?error=denied&error=other&state=expected"] {
            #expect(throws: GoogleCalendarError.invalidCallback) {
                try GoogleDesktopOAuth.callbackCode(target: target, expectedState: "expected")
            }
        }
        #expect(throws: GoogleCalendarError.authorizationDenied) {
            try GoogleDesktopOAuth.callbackCode(target: "/?error=access_denied&state=expected", expectedState: "expected")
        }
    }

    @Test func encodesFormFieldsWithoutQueryInjection() {
        let encoded = String(data: GoogleCalendarClient.formBody(["code": "a+b&c=d%", "client_id": "one"]), encoding: .utf8)
        #expect(encoded == "client_id=one&code=a%2Bb%26c%3Dd%25")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAP_TEST_LOOPBACK"] == "1"))
    func desktopLoopbackCompletesWithoutOpeningBrowserOrContactingGoogle() async throws {
        let observed = OAuthBrowserProbe()
        let result = try await withThrowingTaskGroup(of: GoogleDesktopOAuth.Authorization.self) { group in
            group.addTask {
                try await GoogleDesktopOAuth.authorize(configuration: .init(clientID: "local-test.apps.googleusercontent.com")) { url in
                    Task { await observed.simulateBrowserCallback(url) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw GoogleCalendarError.authorizationTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(result.code == "local-test-code")
        #expect(result.redirectURI.hasPrefix("http://127.0.0.1:"))
        #expect(result.verifier.count == 43)
        #expect(await observed.waitForStatus() == 200)
        #expect(await !observed.callbackBody.contains("local-test-code"))
        #expect(await observed.cacheControl == "no-store")
        #expect(await observed.referrerPolicy == "no-referrer")
        let items = await observed.authorizationQuery
        #expect(items.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(items.first(where: { $0.name == "scope" })?.value == GoogleOAuthConfiguration.scopes.joined(separator: " "))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAP_TEST_LOOPBACK"] == "1"))
    func abandonedBrowserSignInTimesOutWithoutGoogleContact() async {
        await #expect(throws: GoogleCalendarError.authorizationTimedOut) {
            try await GoogleDesktopOAuth.authorize(configuration: .init(clientID: "local-test.apps.googleusercontent.com"), timeout: .milliseconds(100)) { _ in }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAP_TEST_LOOPBACK"] == "1"))
    func cancellingSignInClosesItsLoopbackListener() async throws {
        let probe = AuthorizationURLProbe()
        let authorization = Task {
            try await GoogleDesktopOAuth.authorize(configuration: .init(clientID: "local-test.apps.googleusercontent.com")) { url in
                Task { await probe.record(url) }
            }
        }
        let url = await probe.waitForURL()
        authorization.cancel()
        await #expect(throws: CancellationError.self) { try await authorization.value }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirect = try #require(items.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URL.init(string:)))
        do {
            _ = try await URLSession.shared.data(from: redirect)
            Issue.record("A cancelled sign-in left its local listener open.")
        } catch { }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAP_TEST_LOOPBACK"] == "1"))
    func disconnectCancelsBrowserSignInAndAllowsANewAttempt() async throws {
        let client = GoogleCalendarClient(configuration: .init(clientID: "local-test.apps.googleusercontent.com"),
                                          tokenStore: MemoryTokens(), transport: HTTPResponseTape([]).transport)
        for _ in 0..<2 {
            let probe = AuthorizationURLProbe()
            let attempt = Task {
                try await client.connect { url in Task { await probe.record(url) } }
            }
            _ = await probe.waitForURL()
            try await client.disconnect()
            await #expect(throws: CancellationError.self) { try await attempt.value }
        }
        #expect(try await !client.hasCredentials())
    }
}

@Suite("Google Calendar requests")
struct GoogleCalendarClientTests {
    let configuration = GoogleOAuthConfiguration(clientID: "yap-test.apps.googleusercontent.com")
    let from = Date(timeIntervalSince1970: 1_783_440_000)
    var to: Date { from.addingTimeInterval(14 * 86_400) }

    @Test func missingConfigurationRequiresSetup() async throws {
        let client = GoogleCalendarClient(configuration: nil, tokenStore: MemoryTokens())
        #expect(try await !client.hasCredentials())
        await #expect(throws: GoogleCalendarError.notConfigured) { try await client.calendars() }
    }

    @Test func readsAllCalendarPagesAndSkipsDeleted() async throws {
        let tape = HTTPResponseTape([
            .init(body: #"{"items":[{"id":"secondary","summary":"Work"}],"nextPageToken":"second"}"#),
            .init(body: #"{"items":[{"id":"primary","summary":"Personal","primary":true},{"id":"old","deleted":true}]}"#)
        ])
        let client = makeClient(tape)
        let calendars = try await client.calendars()
        #expect(calendars.map(\.id) == ["primary", "secondary"])
        let requests = await tape.requests
        #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageToken" })?.value == "second")
    }

    @Test func fetchesEveryEventPageWithEscapedCalendarAndBoundedWindow() async throws {
        let tape = HTTPResponseTape([
            .init(body: eventPage(id: "first", nextPage: "two")),
            .init(body: eventPage(id: "second"))
        ])
        let client = makeClient(tape)
        let events = try await client.events(in: [GoogleCalendar(id: "a/b?#@example.test", name: "Personal")], from: from, to: to)
        #expect(events.count == 2)
        let requests = await tape.requests
        #expect(requests.count == 2)
        #expect(requests[0].url!.absoluteString.contains("a%2Fb%3F%23%40example%2Etest"))
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first(where: { $0.name == "singleEvents" })?.value == "true")
        #expect(query.first(where: { $0.name == "timeMin" })?.value == from.ISO8601Format())
        #expect(query.first(where: { $0.name == "timeMax" })?.value == to.ISO8601Format())
        #expect(!query.contains(where: { $0.name == "syncToken" }))
    }

    @Test func refreshesExpiredTokenAndPreservesRefreshCredential() async throws {
        let store = MemoryTokens(tokens: GoogleOAuthTokens(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast))
        let tape = HTTPResponseTape([
            .init(body: #"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#),
            .init(body: #"{"items":[]}"#)
        ])
        let client = GoogleCalendarClient(configuration: configuration, tokenStore: store, transport: tape.transport)
        _ = try await client.calendars()
        let requests = await tape.requests
        #expect(requests[0].url?.host == "oauth2.googleapis.com")
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new")
        #expect(try await store.load()?.refreshToken == "refresh")
    }

    @Test func retriesUnauthorizedOnlyOnce() async throws {
        let tape = HTTPResponseTape([
            .init(status: 401, body: "{}"),
            .init(body: #"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#),
            .init(status: 401, body: "{}")
        ])
        await #expect(throws: GoogleCalendarError.signInExpired) { try await makeClient(tape).calendars() }
        #expect(await tape.requests.count == 3)
    }

    @Test func invalidGrantClearsStoredConnection() async throws {
        let store = MemoryTokens(tokens: GoogleOAuthTokens(accessToken: "expired", refreshToken: "invalid", expiresAt: .distantPast))
        let tape = HTTPResponseTape([.init(status: 400, body: #"{"error":"invalid_grant"}"#)])
        let client = GoogleCalendarClient(configuration: configuration, tokenStore: store, transport: tape.transport)
        await #expect(throws: GoogleCalendarError.signInExpired) { try await client.calendars() }
        #expect(try await store.load() == nil)
    }

    @Test func rejectsRepeatingPageTokenWithoutLooping() async throws {
        let tape = HTTPResponseTape([
            .init(body: #"{"items":[],"nextPageToken":"same"}"#),
            .init(body: #"{"items":[],"nextPageToken":"same"}"#)
        ])
        await #expect(throws: GoogleCalendarError.invalidResponse) { try await makeClient(tape).calendars() }
        #expect(await tape.requests.count == 2)
    }

    @Test func failedRefreshDoesNotReplaceCachedAgendaWithPartialResult() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YapCalendarTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("agenda.json")
        let tape = HTTPResponseTape([
            .init(body: eventPage(id: "original")),
            .init(body: eventPage(id: "partial", nextPage: "next")),
            .init(status: 503, body: "{}")
        ])
        let client = makeClient(tape, cacheURL: cache)
        let calendars = [GoogleCalendar(id: "personal", name: "Personal")]
        _ = try await client.events(in: calendars, from: from, to: to)
        await #expect(throws: GoogleCalendarError.httpStatus(503)) { try await client.events(in: calendars, from: from, to: to) }
        #expect(try await client.cachedSnapshot()?.events.map(\.id) == ["personal:original"])
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await client.disconnect()
        #expect(try await client.cachedSnapshot() == nil)
        #expect(try await !client.hasCredentials())
    }

    @Test func nextFullWindowRemovesCancelledMeeting() async throws {
        let tape = HTTPResponseTape([
            .init(body: eventPage(id: "later-cancelled")),
            .init(body: #"{"items":[{"id":"later-cancelled","status":"cancelled"}]}"#)
        ])
        let client = makeClient(tape)
        let calendars = [GoogleCalendar(id: "personal", name: "Personal")]
        #expect(try await client.events(in: calendars, from: from, to: to).count == 1)
        #expect(try await client.events(in: calendars, from: from, to: to).isEmpty)
    }

    private func makeClient(_ tape: HTTPResponseTape, cacheURL: URL? = nil) -> GoogleCalendarClient {
        GoogleCalendarClient(configuration: configuration, tokenStore: MemoryTokens(tokens: .init(accessToken: "valid", refreshToken: "refresh", expiresAt: .distantFuture)),
                             transport: tape.transport, cacheURL: cacheURL)
    }

    private func eventPage(id: String, nextPage: String? = nil) -> String {
        let suffix = nextPage.map { ",\"nextPageToken\":\"\($0)\"" } ?? ""
        return "{\"items\":[{\"id\":\"\(id)\",\"start\":{\"dateTime\":\"2026-07-06T10:00:00Z\"},\"end\":{\"dateTime\":\"2026-07-06T10:30:00Z\"}}]\(suffix)}"
    }
}

private actor MemoryTokens: GoogleTokenStore {
    var tokens: GoogleOAuthTokens?
    init(tokens: GoogleOAuthTokens? = nil) { self.tokens = tokens }
    func load() throws -> GoogleOAuthTokens? { tokens }
    func save(_ tokens: GoogleOAuthTokens) throws { self.tokens = tokens }
    func delete() throws { tokens = nil }
}

private actor OAuthBrowserProbe {
    var authorizationQuery: [URLQueryItem] = []
    var callbackStatus: Int?
    var callbackBody = ""
    var cacheControl: String?
    var referrerPolicy: String?
    var completion: CheckedContinuation<Int, Never>?

    func waitForStatus() async -> Int {
        if let callbackStatus { return callbackStatus }
        return await withCheckedContinuation { completion = $0 }
    }

    func simulateBrowserCallback(_ authorizationURL: URL) async {
        let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        authorizationQuery = items
        guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value,
              var callback = URLComponents(string: redirect) else { return }
        callback.queryItems = [URLQueryItem(name: "code", value: "local-test-code"), URLQueryItem(name: "state", value: state)]
        guard let url = callback.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            callbackStatus = (response as? HTTPURLResponse)?.statusCode
            callbackBody = String(decoding: data, as: UTF8.self)
            cacheControl = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control")
            referrerPolicy = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Referrer-Policy")
        } catch { callbackStatus = -1 }
        completion?.resume(returning: callbackStatus ?? -1)
        completion = nil
    }
}

private actor AuthorizationURLProbe {
    var url: URL?
    var waiter: CheckedContinuation<URL, Never>?
    func record(_ url: URL) { self.url = url; waiter?.resume(returning: url); waiter = nil }
    func waitForURL() async -> URL {
        if let url { return url }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private actor HTTPResponseTape {
    struct Response: Sendable { var status = 200; let body: String }
    var responses: [Response]
    var requests: [URLRequest] = []
    init(_ responses: [Response]) { self.responses = responses }
    nonisolated var transport: CalendarHTTPTransport { CalendarHTTPTransport { try await self.send($0) } }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw GoogleCalendarError.invalidResponse }
        let next = responses.removeFirst()
        return (Data(next.body.utf8), HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
