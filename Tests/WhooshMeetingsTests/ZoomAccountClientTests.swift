import CryptoKit
import Foundation
import Testing
@testable import WhooshMeetings

@Suite("Zoom authentication")
struct ZoomAccountClientTests {
    private let configuration = ZoomPersonalConfiguration(sdkClientID: "fixture-sdk-id", sdkClientSecret: "fixture-secret",
                                                           oauthPublicClientID: "fixture-public-id")

    @Test func nativeJWTUsesRuntimeSecretAndDocumentedClaims() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try ZoomSDKJWT.make(configuration: configuration, now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let payload = try #require(try JSONSerialization.jsonObject(with: decodeBase64URL(parts[1])) as? [String: Any])
        #expect(payload["appKey"] as? String == configuration.sdkClientID)
        #expect(payload["iat"] as? Int == 1_799_999_970)
        #expect(payload["exp"] as? Int == 1_800_003_570)
        #expect(payload["tokenExp"] as? Int == 1_800_003_570)
        #expect(payload["sdkKey"] == nil)
        #expect(payload["role"] == nil)
        let signature = try decodeBase64URL(parts[2])
        #expect(HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data("\(parts[0]).\(parts[1])".utf8),
            using: SymmetricKey(data: Data(configuration.sdkClientSecret.utf8))))
        #expect(!configuration.description.contains(configuration.sdkClientSecret))
    }

    @Test func importsConfigurationIntoStoreAndClearsPreviousConnection() async throws {
        let store = MemoryZoomStore(configuration: configuration, tokens: fixtureTokens())
        let client = ZoomAccountClient(store: store)
        try await client.configure(fromJSON: JSONEncoder().encode(configuration))
        #expect(try await client.isConfigured())
        #expect(try await !client.hasSavedConnection())
        #expect(await store.savedConfiguration?.sdkClientID == "fixture-sdk-id")
        await #expect(throws: ZoomAccountError.invalidConfiguration) {
            try await client.configure(fromJSON: Data("{}".utf8))
        }
    }

    @Test func validatesCallbackStateAndRejectsAmbiguity() throws {
        #expect(try ZoomDesktopOAuth.callbackCode(target: "/callback?code=example&state=random-state", expectedState: "random-state") == "example")
        for target in ["/callback?code=example&state=wrong", "/callback?code=a&code=b&state=random-state",
                       "/callback?code=a&state=random-state&state=random-state", "/?code=a&state=random-state",
                       "/callback?code=a&state=random-state#fragment", "https://attacker.example/callback?code=a&state=random-state"] {
            #expect(throws: ZoomAccountError.invalidCallback) {
                try ZoomDesktopOAuth.callbackCode(target: target, expectedState: "random-state")
            }
        }
        #expect(throws: ZoomAccountError.authorizationDenied) {
            try ZoomDesktopOAuth.callbackCode(target: "/callback?error=access_denied&state=random-state", expectedState: "random-state")
        }
    }

    @Test func realLoopbackListenerValidatesBrowserCallbackAndPKCE() async throws {
        let observed = ObservedAuthorizationURL()
        let task = Task {
            try await ZoomDesktopOAuth.authorize(publicClientID: "fixture-public-id") { url in
                Task {
                    await observed.record(url)
                    let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    guard let redirect = parameters.first(where: { $0.name == "redirect_uri" })?.value,
                          let state = parameters.first(where: { $0.name == "state" })?.value,
                          var callback = URLComponents(string: redirect) else { return }
                    callback.queryItems = [URLQueryItem(name: "code", value: "fixture-browser-code"),
                                           URLQueryItem(name: "state", value: state)]
                    guard let callbackURL = callback.url else { return }
                    // This hits only the actual 127.0.0.1 listener. No Zoom request is made.
                    _ = try? await URLSession.shared.data(from: callbackURL)
                }
            }
        }
        let deadline = Task { try await Task.sleep(for: .seconds(5)); task.cancel() }
        defer { deadline.cancel() }
        let authorization = try await task.value
        #expect(authorization.code == "fixture-browser-code")
        #expect(authorization.verifier.count >= 43)
        let url = try #require(await observed.url)
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "zoom.us")
        #expect(parameters.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(parameters.first(where: { $0.name == "code_challenge" })?.value ==
                Data(SHA256.hash(data: Data(authorization.verifier.utf8))).zoomBase64URL)
        #expect(URL(string: authorization.redirectURI)?.host == "127.0.0.1")
        #expect(URL(string: authorization.redirectURI)?.path == "/callback")
    }

    @Test func fetchesFreshShortLivedZAKWithMinimumScopeEndpoint() async throws {
        let store = MemoryZoomStore(configuration: configuration, tokens: fixtureTokens())
        let server = FixtureZoomServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        let credentials = try await client.meetingCredentials()
        #expect(credentials.zak == "fixture-zak")
        #expect(credentials.zakExpiresAt.timeIntervalSinceNow > 295)
        #expect(!credentials.description.contains("fixture-zak"))
        let requests = await server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://api.zoom.us/v2/users/me/zak")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
    }

    @Test func concurrentRequestsRefreshOnceAndPersistRotatedRefreshToken() async throws {
        let store = MemoryZoomStore(configuration: configuration, tokens: fixtureTokens(expired: true))
        let server = FixtureZoomServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        async let first = client.meetingCredentials()
        async let second = client.meetingCredentials()
        _ = try await (first, second)
        let requests = await server.requests
        let tokenRequests = requests.filter { $0.url?.path == "/oauth/token" }
        #expect(tokenRequests.count == 1)
        let request = try #require(tokenRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("client_id=fixture-public-id"))
        #expect(body.contains("grant_type=refresh_token"))
        #expect(!body.contains("fixture-secret"))
        #expect(await store.savedTokens?.refreshToken == "fixture-rotated-refresh")
    }

    @Test func expiredAuthorizationClearsTokensWithoutLeakingServerBody() async throws {
        let store = MemoryZoomStore(configuration: configuration, tokens: fixtureTokens(expired: true))
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { request in
            (Data(#"{"error":"invalid_grant","secret":"never-echo-this"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: ZoomAccountError.notConnected) { try await client.meetingCredentials() }
        #expect(try await !client.hasSavedConnection())
        #expect(!ZoomAccountError.notConnected.localizedDescription.contains("never-echo-this"))
    }

    @Test func disconnectAndRemoveConfigurationAreSeparate() async throws {
        let store = MemoryZoomStore(configuration: configuration, tokens: fixtureTokens())
        let client = ZoomAccountClient(store: store)
        try await client.disconnect()
        #expect(try await client.isConfigured())
        #expect(try await !client.hasSavedConnection())
        try await client.removeConfiguration()
        #expect(try await !client.isConfigured())
    }

    @Test func formEncodingCannotSplitSecretFields() {
        let body = String(data: ZoomAccountClient.formBody(["code": "a+b&c=d e", "client_id": "test"]), encoding: .utf8)
        #expect(body == "client_id=test&code=a%2Bb%26c%3Dd%20e")
    }

    @Test func disconnectDuringTokenLoadCannotRefreshOldCredentials() async throws {
        let store = DelayedZoomStore(configuration: configuration, tokens: fixtureTokens(expired: true), delayLoad: true)
        let server = FixtureZoomServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        let credentials = Task { try await client.meetingCredentials() }
        await store.waitForLoad()
        try await client.disconnect()
        await store.resumeLoad()
        await #expect(throws: CancellationError.self) { try await credentials.value }
        #expect(await server.requests.isEmpty)
        #expect(await store.savedTokens == nil)
    }

    @Test func cancelledHostingBeforeTokenLoadCompletesDoesNotCreateAMeeting() async throws {
        let store = DelayedZoomStore(configuration: configuration, tokens: fixtureTokens(), delayLoad: true)
        let server = FixtureZoomServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        let hosting = Task { try await client.hostingCredentials(title: "Cancelled meeting") }
        await store.waitForLoad()
        hosting.cancel()
        let release = Task { try await Task.sleep(for: .milliseconds(25)); await store.resumeLoad() }
        await #expect(throws: CancellationError.self) { try await hosting.value }
        try await release.value
        #expect(await server.requests.isEmpty)
    }

    @Test func disconnectWaitsForPendingSaveThenDeletesRotatedCredentials() async throws {
        let store = DelayedZoomStore(configuration: configuration, tokens: fixtureTokens(expired: true), delaySave: true)
        let server = FixtureZoomServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        let credentials = Task { try await client.meetingCredentials() }
        await store.waitForSave()
        let release = Task { try await Task.sleep(for: .milliseconds(25)); await store.resumeSave() }
        try await client.disconnect()
        try await release.value
        await #expect(throws: CancellationError.self) { try await credentials.value }
        #expect(await store.savedTokens == nil)
    }

    @Test func cancelledSignInCannotLeaveNewTokensInDelayedStore() async throws {
        let store = DelayedZoomStore(configuration: configuration, tokens: fixtureTokens(), delaySave: true)
        let server = FixtureZoomServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        let connection = Task {
            try await client.connect { url in
                Task {
                    let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    guard let redirect = parameters.first(where: { $0.name == "redirect_uri" })?.value,
                          let state = parameters.first(where: { $0.name == "state" })?.value,
                          var callback = URLComponents(string: redirect) else { return }
                    callback.queryItems = [URLQueryItem(name: "code", value: "fixture-code"), URLQueryItem(name: "state", value: state)]
                    guard let callbackURL = callback.url else { return }
                    _ = try? await URLSession.shared.data(from: callbackURL)
                }
            }
        }
        await store.waitForSave()
        connection.cancel()
        await store.resumeSave()
        await #expect(throws: CancellationError.self) { try await connection.value }
        #expect(await store.savedTokens == nil)
    }

    @Test func cancellingCredentialRequestDoesNotReturnUsableTokens() async throws {
        let store = MemoryZoomStore(configuration: configuration, tokens: fixtureTokens())
        let server = SuspendedZAKServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        let credentials = Task { try await client.meetingCredentials() }
        await server.waitForRequest()
        credentials.cancel()
        await server.resume()
        await #expect(throws: CancellationError.self) { try await credentials.value }
    }

    @Test func networkLatencyDoesNotExtendReportedZAKValidity() async throws {
        let store = MemoryZoomStore(configuration: configuration, tokens: fixtureTokens())
        let server = SuspendedZAKServer()
        let client = ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
        let credentials = Task { try await client.meetingCredentials() }
        await server.waitForRequest()
        let requestStartedAt = try #require(await server.requestStartedAt)
        try await Task.sleep(for: .milliseconds(25))
        await server.resume()
        let result = try await credentials.value
        #expect(result.zakExpiresAt <= requestStartedAt.addingTimeInterval(300))
    }

    private func fixtureTokens(expired: Bool = false) -> ZoomOAuthTokens {
        ZoomOAuthTokens(clientID: configuration.oauthPublicClientID, accessToken: "fixture-access",
                        refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(expired ? -60 : 3_600))
    }

    private func decodeBase64URL(_ value: String) throws -> Data {
        let encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return try #require(Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)))
    }
}

private actor MemoryZoomStore: ZoomCredentialStore {
    var savedConfiguration: ZoomPersonalConfiguration?
    var savedTokens: ZoomOAuthTokens?
    init(configuration: ZoomPersonalConfiguration?, tokens: ZoomOAuthTokens?) {
        savedConfiguration = configuration
        savedTokens = tokens
    }
    func loadConfiguration() -> ZoomPersonalConfiguration? { savedConfiguration }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) { savedConfiguration = configuration }
    func loadTokens() -> ZoomOAuthTokens? { savedTokens }
    func saveTokens(_ tokens: ZoomOAuthTokens) { savedTokens = tokens }
    func deleteTokens() { savedTokens = nil }
    func deleteAll() { savedConfiguration = nil; savedTokens = nil }
}

private actor FixtureZoomServer {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        if request.url?.path == "/oauth/token" {
            try await Task.sleep(for: .milliseconds(20))
            body = #"{"access_token":"fixture-new-access","refresh_token":"fixture-rotated-refresh","token_type":"bearer","expires_in":3600,"scope":"user:read:zak"}"#
        } else { body = #"{"token":"fixture-zak"}"# }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ObservedAuthorizationURL {
    var url: URL?
    func record(_ url: URL) { self.url = url }
}

private actor DelayedZoomStore: ZoomCredentialStore {
    var configuration: ZoomPersonalConfiguration?
    var savedTokens: ZoomOAuthTokens?
    let delayLoad: Bool
    let delaySave: Bool
    var loadGate: CheckedContinuation<Void, Never>?
    var saveGate: CheckedContinuation<Void, Never>?
    var loadStarted: CheckedContinuation<Void, Never>?
    var saveStarted: CheckedContinuation<Void, Never>?
    init(configuration: ZoomPersonalConfiguration, tokens: ZoomOAuthTokens, delayLoad: Bool = false, delaySave: Bool = false) {
        self.configuration = configuration
        savedTokens = tokens
        self.delayLoad = delayLoad
        self.delaySave = delaySave
    }
    func loadConfiguration() -> ZoomPersonalConfiguration? { configuration }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) { self.configuration = configuration }
    func loadTokens() async -> ZoomOAuthTokens? {
        let snapshot = savedTokens
        if delayLoad {
            await withCheckedContinuation { continuation in
                loadGate = continuation
                loadStarted?.resume()
                loadStarted = nil
            }
        }
        return snapshot
    }
    func saveTokens(_ tokens: ZoomOAuthTokens) async {
        if delaySave {
            await withCheckedContinuation { continuation in
                saveGate = continuation
                saveStarted?.resume()
                saveStarted = nil
            }
        }
        savedTokens = tokens
    }
    func deleteTokens() { savedTokens = nil }
    func deleteAll() { configuration = nil; savedTokens = nil }
    func waitForLoad() async {
        if loadGate != nil { return }
        await withCheckedContinuation { loadStarted = $0 }
    }
    func waitForSave() async {
        if saveGate != nil { return }
        await withCheckedContinuation { saveStarted = $0 }
    }
    func resumeLoad() { loadGate?.resume(); loadGate = nil }
    func resumeSave() { saveGate?.resume(); saveGate = nil }
}

private actor SuspendedZAKServer {
    var gate: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var requestStartedAt: Date?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestStartedAt = Date()
        await withCheckedContinuation { continuation in
            gate = continuation
            started?.resume()
            started = nil
        }
        return (Data(#"{"token":"fixture-zak"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForRequest() async {
        if gate != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { gate?.resume(); gate = nil }
}
