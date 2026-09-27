import Foundation
import CryptoKit
import Testing
@testable import YapMeetings

@Suite("Native Zoom PKCE authorization")
struct ZoomManagedAuthenticationTests {
    private let managed = ZoomPublicConfiguration(oauthPublicClientID: "managed-public",
        oauthRedirectURL: URL(string: "https://auth.yap.enterprises/oauth/zoom/callback")!)
    private let personal = ZoomPersonalConfiguration(sdkClientID: "personal-sdk", sdkClientSecret: "personal-secret-fixture",
                                                     oauthPublicClientID: "personal-public")

    @Test func packagedConfigurationUsesNativePublicClientAndBrandedCodeHandoff() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let configuration = try #require(try ZoomPublicConfiguration.load(info: info))
        #expect(configuration.oauthPublicClientID == "_Xz_EnBNS3OPtUmqZ1og3A")
        #expect(configuration.oauthRedirectURL.absoluteString == "https://auth.yap.enterprises/oauth/zoom/callback")
        #expect(configuration.oauthSessionURL.absoluteString == "https://auth.yap.enterprises/v1/oauth/session")
        #expect(configuration.oauthHandoffURL.absoluteString == "https://auth.yap.enterprises/v1/oauth/handoff")
        #expect(configuration.oauthTokenURL.absoluteString == "https://zoom.us/oauth/token")
        #expect(info["YapZoomSDKClientID"] == nil)
        #expect(info["YapZoomSDKSignerURL"] == nil)
    }

    @Test func configurationNeedsOnlyPublicIDAndFixedHTTPSCallback() throws {
        let valid: [String: Any] = ["YapZoomOAuthClientID": managed.oauthPublicClientID,
                                   "YapZoomOAuthRedirectURL": managed.oauthRedirectURL.absoluteString]
        #expect(try ZoomPublicConfiguration.load(info: [:]) == nil)
        #expect(try ZoomPublicConfiguration.load(info: valid) == managed)
        #expect(throws: ZoomAccountError.invalidPublicConfiguration) {
            try ZoomPublicConfiguration.load(info: ["YapZoomOAuthClientID": "only-one-key"])
        }
        for url in ["http://auth.yap.enterprises/oauth/zoom/callback",
                    "https://user:password@auth.yap.enterprises/oauth/zoom/callback",
                    "https://auth.yap.enterprises:8443/oauth/zoom/callback",
                    "https://auth.yap.enterprises/oauth/zoom/callback?redirect=elsewhere",
                    "https://auth.yap.enterprises/oauth/zoom/callback#fragment",
                    "https://auth.yap.enterprises/different-endpoint"] {
            #expect(throws: ZoomAccountError.invalidPublicConfiguration) {
                try ZoomPublicConfiguration.load(info: valid.merging(["YapZoomOAuthRedirectURL": url]) { _, new in new })
            }
        }
    }

    @Test func freshManagedInstallSupportsCameraSettingsBeforeAccountSignIn() async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        #expect(try await client.configurationMode() == .managed)
        #expect(try await client.isConfigured())
        #expect(try await !client.hasSavedConnection())
        #expect(try await client.cameraSettingsAuthorization() == .publicClientID("managed-public"))
        #expect(await server.requests.isEmpty)
        await #expect(throws: ZoomAccountError.notConnected) { try await client.meetingCredentials() }
        try await client.configure(personal)
        #expect(try await client.configurationMode() == .personal)
        #expect(try await client.cameraSettingsAuthorization().jwt?.split(separator: ".").count == 3)
        await store.saveTokens(tokens(clientID: personal.oauthPublicClientID, method: nil))
        #expect(try await client.meetingCredentials().sdkAuthorization.jwt != nil)
        #expect(await server.requests.count == 1)
        try await client.usePublicConfiguration()
        #expect(try await client.configurationMode() == .managed)
        #expect(try await !client.hasSavedConnection())
        #expect(await store.configuration == nil)
        #expect(await store.tokens == nil)
    }

    @Test func preMigrationConnectionsMustReconnectEvenIfPublicIDMatches() async throws {
        for clientID in ["old-confidential-client", "managed-public"] {
            let store = ManagedZoomStore(tokens: tokens(clientID: clientID, method: nil, grant: "old-service-grant"))
            let server = ManagedZoomServer()
            let client = makeClient(store, server)
            #expect(try await !client.hasSavedConnection())
            await #expect(throws: ZoomAccountError.notConnected) { try await client.meetingCredentials() }
            #expect(await server.requests.isEmpty)
        }
    }

    @Test func legacyTokenRecordDecodesWithoutProvenanceAndRemainsRedacted() throws {
        let value = tokens()
        var record = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        record.removeValue(forKey: "authorizationMethod")
        let legacy = try JSONDecoder().decode(ZoomOAuthTokens.self, from: JSONSerialization.data(withJSONObject: record))
        #expect(legacy.authorizationMethod == nil)
        #expect(!String(describing: value).contains(value.accessToken))
        #expect(!String(reflecting: value).contains(value.refreshToken))
        #expect(!String(reflecting: ZoomSDKAuthorization.jwt("private-developer-jwt")).contains("private-developer-jwt"))
    }

    @Test func authorizationURLPinsClientRedirectPKCEAndEnvelopeVersion() throws {
        let verifier = String(repeating: "v", count: 43)
        var valid = URLComponents(string: "https://zoom.us/oauth/authorize")!
        valid.queryItems = [.init(name: "client_id", value: managed.oauthPublicClientID),
            .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: managed.oauthRedirectURL.absoluteString),
            .init(name: "code_challenge", value: hash(verifier)), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: "v2.fixture.session")]
        #expect(ZoomManagedOAuth.validatedAuthorizeURL(valid.string!, configuration: managed, verifier: verifier) != nil)
        for (key, value) in [("client_id", "another-app"), ("redirect_uri", "http://127.0.0.1:5555/callback"),
                             ("redirect_uri", "https://auth-dev.yap.enterprises/oauth/zoom/callback"),
                             ("code_challenge", "another-challenge"), ("code_challenge_method", "plain"), ("state", "v1.fixture.session")] {
            var changed = valid
            changed.queryItems = valid.queryItems?.map { $0.name == key ? URLQueryItem(name: key, value: value) : $0 }
            #expect(ZoomManagedOAuth.validatedAuthorizeURL(changed.string!, configuration: managed, verifier: verifier) == nil)
        }
        var duplicate = valid; duplicate.queryItems?.append(.init(name: "client_id", value: managed.oauthPublicClientID))
        var wrongHost = valid; wrongHost.host = "zoom.us.attacker.example"
        var credentials = valid; credentials.user = "user"
        var fragment = valid; fragment.fragment = "unexpected"
        for changed in [duplicate, wrongHost, credentials, fragment] {
            #expect(ZoomManagedOAuth.validatedAuthorizeURL(changed.string!, configuration: managed, verifier: verifier) == nil)
        }
    }

    @Test func signInHandsOffOnlyCodeThenExchangesDirectlyWithZoom() async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        try await connect(client, server)
        let requests = await server.requests
        #expect(requests.map { $0.url?.absoluteString } == [managed.oauthSessionURL.absoluteString,
            managed.oauthHandoffURL.absoluteString, "https://zoom.us/oauth/token", "https://api.zoom.us/v2/users/me/zak"])
        let session = try jsonFields(requests[0])
        let handoff = try jsonFields(requests[1])
        let token = formFields(requests[2])
        #expect(Set(session.keys) == Set(["client_id", "state", "code_challenge", "code_challenge_method", "handoff_challenge"]))
        #expect(Set(handoff.keys) == Set(["client_id", "state", "handoff", "handoff_verifier"]))
        let verifier = try #require(token["code_verifier"])
        let handoffVerifier = try #require(handoff["handoff_verifier"])
        #expect(verifier != handoffVerifier)
        #expect(session["code_challenge"] == hash(verifier))
        #expect(session["handoff_challenge"] == hash(handoffVerifier))
        #expect(session["code_challenge_method"] == "S256")
        #expect(handoff["state"] == session["state"])
        #expect(token["grant_type"] == "authorization_code")
        #expect(token["code"] == "fixture-code+with/symbols")
        #expect(token["client_id"] == "managed-public")
        #expect(token["redirect_uri"] == managed.oauthRedirectURL.absoluteString)
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[2].url?.query == nil)
        for request in requests.prefix(3) {
            #expect(!request.httpShouldHandleCookies)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        }
        for request in requests.prefix(2) {
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(!body.contains(verifier))
            #expect(!body.contains("access_token") && !body.contains("refresh_token"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        #expect(try await client.hasSavedConnection())
        #expect(await store.tokens?.authorizationMethod == "nativePKCEv1")
        #expect(await store.tokens?.signingAuthorization == nil)
    }

    @Test func savedNativeConnectionUsesPublicSDKAuthorizationWithoutSigner() async throws {
        let server = ManagedZoomServer()
        let client = makeClient(ManagedZoomStore(tokens: tokens()), server)
        let credentials = try await client.meetingCredentials()
        #expect(credentials.sdkAuthorization == .publicClientID("managed-public"))
        #expect(credentials.zak == "fixture-zak")
        #expect(await server.requests.map { $0.url?.absoluteString } == ["https://api.zoom.us/v2/users/me/zak"])
        #expect(!String(reflecting: credentials).contains(credentials.zak))
    }

    @Test func concurrentExpiredTokensRefreshDirectlyOnceAndRotateInKeychainStore() async throws {
        let store = ManagedZoomStore(tokens: tokens(expired: true))
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        async let first = client.meetingCredentials()
        async let second = client.meetingCredentials()
        _ = try await (first, second)
        let requests = await server.requests
        let refreshes = requests.filter { $0.url?.absoluteString == "https://zoom.us/oauth/token" }
        #expect(refreshes.count == 1)
        let refresh = try #require(refreshes.first)
        #expect(formFields(refresh) == ["grant_type": "refresh_token", "client_id": "managed-public", "refresh_token": "fixture-refresh"])
        #expect(refresh.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests.allSatisfy { ["zoom.us", "api.zoom.us"].contains($0.url?.host ?? "") })
        #expect(await store.tokens?.refreshToken == "rotated-refresh")
        #expect(await store.tokens?.authorizationMethod == "nativePKCEv1")
        #expect(await store.tokens?.signingAuthorization == nil)
    }

    @Test func revokedNativeTokenRefreshesOnceBeforeRetryingZAK() async throws {
        let server = ManagedZoomServer(rejectFirstZAK: true)
        let client = makeClient(ManagedZoomStore(tokens: tokens()), server)
        _ = try await client.meetingCredentials()
        let requests = await server.requests
        #expect(requests.map { $0.url?.host } == ["api.zoom.us", "zoom.us", "api.zoom.us"])
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
    }

    @Test(arguments: ["handoff-client", "handoff-redirect", "handoff-token-response", "handoff-extra-token", "handoff-redirected-response", "session-redirected-response", "handoff-invalid-code", "token-redirected-response"])
    func malformedHandoffOrRedirectedServiceResponseCannotSaveConnection(fault: String) async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer(fault: fault)
        let client = makeClient(store, server)
        await #expect(throws: ZoomAccountError.invalidResponse) { try await connect(client, server) }
        #expect(await store.tokens == nil)
        if fault != "token-redirected-response" {
            #expect(await server.requests.allSatisfy { $0.url?.host == "auth.yap.enterprises" })
        }
    }

    @Test func malformedUnsolicitedAndLegacyCallbacksCannotCompleteSignIn() async throws {
        let server = ManagedZoomServer()
        let client = makeClient(ManagedZoomStore(), server)
        try await client.connect { _ in
            Task {
                let state = await server.sessionFields?["state"] ?? ""
                for raw in ["yap://oauth/zoom?state=unrelated&handoff=v2.fixture.handoff",
                            "yap://oauth/zoom?state=\(state)&state=\(state)&handoff=v2.fixture.handoff",
                            "yap://oauth/zoom?state=\(state)&handoff=v2.fixture.handoff&error=access_denied",
                            "yap://oauth/zoom?state=\(state)&code=plaintext-code",
                            "yap://oauth/zoom?state=\(state)&handoff=v1.fixture.handoff",
                            "yap://oauth/zoom?state=\(state)&handoff=v2.fixture.handoff#fragment",
                            "yap://oauth/other?state=\(state)&handoff=v2.fixture.handoff"] {
                    #expect(ZoomManagedOAuthCallback.receive(URL(string: raw)!))
                }
                #expect(await server.requests.count == 1)
                #expect(!ZoomManagedOAuthCallback.receive(URL(string: "yap://join?meeting=123")!))
                let callback = URL(string: "yap://oauth/zoom?state=\(state)&handoff=v2.fixture.handoff")!
                #expect(ZoomManagedOAuthCallback.receive(callback))
                #expect(ZoomManagedOAuthCallback.receive(callback))
            }
        }
        #expect(await server.requests.filter { $0.url?.path == "/oauth/token" }.count == 1)
    }

    @Test func deniedConsentDoesNotRedeemOrStoreCredentials() async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        await #expect(throws: ZoomAccountError.authorizationDenied) {
            try await client.connect { _ in
                Task {
                    let state = await server.sessionFields?["state"] ?? ""
                    ZoomManagedOAuthCallback.receive(URL(string: "yap://oauth/zoom?state=\(state)&error=access_denied")!)
                }
            }
        }
        #expect(await server.requests.count == 1)
        #expect(await store.tokens == nil)
    }

    @Test func cancelledSignInDiscardsLateCallback() async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        await #expect(throws: CancellationError.self) {
            try await client.connect { _ in
                Task {
                    let state = await server.sessionFields?["state"] ?? ""
                    try await client.disconnect()
                    ZoomManagedOAuthCallback.receive(URL(string: "yap://oauth/zoom?state=\(state)&handoff=v2.fixture.handoff")!)
                }
            }
        }
        #expect(await server.requests.count == 1)
        #expect(await store.tokens == nil)
    }

    @Test(arguments: ["/v1/oauth/handoff", "/oauth/token", "/v2/users/me/zak"])
    func disconnectDuringSignInCannotSaveLateCredentials(path: String) async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer(pausePath: path)
        let client = makeClient(store, server)
        let connection = Task { try await connect(client, server) }
        await server.waitForPause()
        try await client.disconnect()
        await server.resume()
        await #expect(throws: CancellationError.self) { try await connection.value }
        #expect(await store.tokens == nil)
    }

    private func connect(_ client: ZoomAccountClient, _ server: ManagedZoomServer) async throws {
        try await client.connect { _ in
            Task {
                let state = await server.sessionFields?["state"] ?? ""
                ZoomManagedOAuthCallback.receive(URL(string: "yap://oauth/zoom?state=\(state)&handoff=v2.fixture.handoff")!)
            }
        }
    }
    private func makeClient(_ store: ManagedZoomStore, _ server: ManagedZoomServer) -> ZoomAccountClient {
        ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) }, publicConfiguration: managed)
    }
    private func tokens(clientID: String = "managed-public", method: String? = "nativePKCEv1", grant: String? = nil,
                        expired: Bool = false) -> ZoomOAuthTokens {
        .init(clientID: clientID, accessToken: "fixture-access", refreshToken: "fixture-refresh",
              expiresAt: .now.addingTimeInterval(expired ? -60 : 3_600), signingAuthorization: grant, authorizationMethod: method)
    }
}

private func hash(_ value: String) -> String { Data(SHA256.hash(data: Data(value.utf8))).zoomBase64URL }
private func jsonFields(_ request: URLRequest) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
}
private func formFields(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private actor ManagedZoomStore: ZoomCredentialStore {
    private(set) var configuration: ZoomPersonalConfiguration?
    private(set) var tokens: ZoomOAuthTokens?
    init(tokens: ZoomOAuthTokens? = nil) { self.tokens = tokens }
    func loadConfiguration() -> ZoomPersonalConfiguration? { configuration }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) { self.configuration = configuration }
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ tokens: ZoomOAuthTokens) { self.tokens = tokens }
    func deleteTokens() { tokens = nil }
    func deleteAll() { configuration = nil; tokens = nil }
}

private actor ManagedZoomServer {
    private(set) var requests: [URLRequest] = []
    private let rejectFirstZAK: Bool
    private let fault: String?
    private let pausePath: String?
    private var zakCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(rejectFirstZAK: Bool = false, fault: String? = nil, pausePath: String? = nil) {
        self.rejectFirstZAK = rejectFirstZAK; self.fault = fault; self.pausePath = pausePath
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.url?.path == pausePath {
            await withCheckedContinuation { continuation in
                gate = continuation; waiter?.resume(); waiter = nil
            }
        }
        var body: Data
        var status = 200
        var responseURL = request.url!
        switch request.url?.path {
        case "/v1/oauth/session":
            let fields = try jsonFields(request)
            var authorize = URLComponents(string: "https://zoom.us/oauth/authorize")!
            authorize.queryItems = [.init(name: "client_id", value: fields["client_id"]),
                .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: "https://auth.yap.enterprises/oauth/zoom/callback"),
                .init(name: "state", value: "v2.fixture.session"), .init(name: "code_challenge", value: fields["code_challenge"]),
                .init(name: "code_challenge_method", value: "S256")]
            body = try JSONSerialization.data(withJSONObject: ["authorize_url": authorize.url!.absoluteString, "expires_in": 180])
            if fault == "session-redirected-response" { responseURL = URL(string: "https://other.example/v1/oauth/session")! }
        case "/v1/oauth/handoff":
            var value = ["code": "fixture-code+with/symbols", "client_id": "managed-public", "redirect_uri": "https://auth.yap.enterprises/oauth/zoom/callback"]
            if fault == "handoff-client" { value["client_id"] = "different-app" }
            if fault == "handoff-redirect" { value["redirect_uri"] = "https://other.example/oauth/zoom/callback" }
            if fault == "handoff-token-response" { value = ["access_token": "old-proxy-token", "refresh_token": "old-proxy-refresh"] }
            if fault == "handoff-extra-token" { value["access_token"] = "old-proxy-token" }
            if fault == "handoff-invalid-code" { value["code"] = "code\ninjected" }
            if fault == "handoff-redirected-response" { responseURL = URL(string: "https://other.example/v1/oauth/handoff")! }
            body = try JSONSerialization.data(withJSONObject: value)
        case "/oauth/token":
            #expect(request.url?.host == "zoom.us")
            try await Task.sleep(for: .milliseconds(20))
            body = Data(#"{"access_token":"refreshed-access","refresh_token":"rotated-refresh","token_type":"bearer","expires_in":3600,"scope":"user:read:zak"}"#.utf8)
            if fault == "token-redirected-response" { responseURL = URL(string: "https://other.example/oauth/token")! }
        case "/v2/users/me/zak":
            zakCount += 1
            if rejectFirstZAK && zakCount == 1 { status = 401 }
            body = Data(#"{"token":"fixture-zak"}"#.utf8)
        default:
            Issue.record("Unexpected endpoint: \(request.url?.path ?? "nil")")
            body = Data("{}".utf8); status = 500
        }
        return (body, HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    var sessionFields: [String: String]? { requests.first { $0.url?.path == "/v1/oauth/session" }.flatMap { try? jsonFields($0) } }
    func waitForPause() async { if gate == nil { await withCheckedContinuation { waiter = $0 } } }
    func resume() { gate?.resume(); gate = nil }
}
