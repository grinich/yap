import Foundation
import CryptoKit
import Testing
@testable import YapMeetings

@Suite("Managed Zoom authorization")
struct ZoomManagedAuthenticationTests {
    private let managed = ZoomPublicConfiguration(oauthPublicClientID: "managed-public", sdkClientID: "managed-sdk",
        sdkSignerURL: URL(string: "https://signer.example/v1/meeting-sdk/signature")!)
    private let personal = ZoomPersonalConfiguration(sdkClientID: "personal-sdk", sdkClientSecret: "personal-secret-fixture",
                                                     oauthPublicClientID: "personal-public")

    @Test func packagedConfigurationKeepsEveryManagedEndpointOnYapDomain() throws {
        let configuration = try packagedConfiguration()
        #expect(configuration.sdkSignerURL.absoluteString == "https://auth.yap.enterprises/v1/meeting-sdk/signature")
        #expect(configuration.oauthSessionURL.absoluteString == "https://auth.yap.enterprises/v1/oauth/session")
        #expect(configuration.oauthTokenURL.absoluteString == "https://auth.yap.enterprises/v1/oauth/token")
        #expect(configuration.oauthRedirectURL.absoluteString == "https://auth.yap.enterprises/oauth/zoom/callback")
    }

    @Test func domainMigrationPreservesExactCallbackValidationForNewAndInstalledApps() throws {
        let current = try packagedConfiguration()
        let installed = ZoomPublicConfiguration(oauthPublicClientID: current.oauthPublicClientID,
            sdkClientID: current.sdkClientID,
            sdkSignerURL: URL(string: "https://meeting-auth.mgrinich.workers.dev/v1/meeting-sdk/signature")!)
        let verifier = String(repeating: "v", count: 43)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).zoomBase64URL
        for configuration in [current, installed] {
            var authorization = URLComponents(string: "https://zoom.us/oauth/authorize")!
            authorization.queryItems = [.init(name: "client_id", value: configuration.oauthPublicClientID),
                .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: configuration.oauthRedirectURL.absoluteString),
                .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: "v1.fixture.session")]
            #expect(ZoomManagedOAuth.validatedAuthorizeURL(authorization.string!, configuration: configuration, verifier: verifier) != nil)

            let other = configuration == current ? installed : current
            #expect(ZoomManagedOAuth.validatedAuthorizeURL(authorization.string!, configuration: other, verifier: verifier) == nil)
            for callback in ["https://auth.yap.enterprises.attacker.example/oauth/zoom/callback",
                             "https://auth.yap.enterprises/oauth/zoom/callback?redirect=elsewhere",
                             "https://auth.yap.enterprises/oauth/zoom/callback#fragment",
                             "http://auth.yap.enterprises/oauth/zoom/callback"] {
                var changed = authorization
                changed.queryItems = authorization.queryItems?.map {
                    $0.name == "redirect_uri" ? URLQueryItem(name: "redirect_uri", value: callback) : $0
                }
                #expect(ZoomManagedOAuth.validatedAuthorizeURL(changed.string!, configuration: configuration, verifier: verifier) == nil)
            }
        }
    }

    private func packagedConfiguration() throws -> ZoomPublicConfiguration {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let info = try #require(propertyList as? [String: Any])
        let configuration = try ZoomPublicConfiguration.load(info: info)
        return try #require(configuration)
    }

    @Test func publicBundleConfigurationNeedsNoSecretAndRejectsPartialOrRedirectableSetup() throws {
        let valid: [String: Any] = ["YapZoomOAuthClientID": managed.oauthPublicClientID,
                                   "YapZoomSDKClientID": managed.sdkClientID,
                                   "YapZoomSDKSignerURL": managed.sdkSignerURL.absoluteString]
        #expect(try ZoomPublicConfiguration.load(info: [:]) == nil)
        #expect(try ZoomPublicConfiguration.load(info: valid) == managed)
        #expect(managed.oauthTokenURL.absoluteString == "https://signer.example/v1/oauth/token")
        #expect(managed.oauthSessionURL.absoluteString == "https://signer.example/v1/oauth/session")
        #expect(managed.oauthRedirectURL.absoluteString == "https://signer.example/oauth/zoom/callback")
        #expect(throws: ZoomAccountError.invalidPublicConfiguration) {
            try ZoomPublicConfiguration.load(info: ["YapZoomOAuthClientID": "only-one-key"])
        }
        for url in ["http://signer.example/v1/meeting-sdk/signature",
                    "https://user:password@signer.example/v1/meeting-sdk/signature",
                    "https://signer.example:8443/v1/meeting-sdk/signature",
                    "https://signer.example/v1/meeting-sdk/signature?redirect=elsewhere",
                    "https://signer.example/v1/meeting-sdk/signature#fragment",
                    "https://signer.example/different-endpoint"] {
            #expect(throws: ZoomAccountError.invalidPublicConfiguration) {
                try ZoomPublicConfiguration.load(info: valid.merging(["YapZoomSDKSignerURL": url]) { _, new in new })
            }
        }
    }

    @Test func freshManagedInstallIsConfiguredWhilePersonalOverrideRemainsExplicit() async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        #expect(try await client.configurationMode() == .managed)
        #expect(try await client.isConfigured())
        #expect(try await !client.hasSavedConnection())
        #expect(await store.configuration == nil)
        try await client.configure(personal)
        #expect(try await client.configurationMode() == .personal)
        await store.saveTokens(tokens(clientID: personal.oauthPublicClientID, grant: nil))
        _ = try await client.meetingCredentials()
        #expect(await server.requests.count == 1)
        #expect(await server.requests.first?.url?.host == "api.zoom.us")
        try await client.usePublicConfiguration()
        #expect(try await client.configurationMode() == .managed)
        #expect(try await client.isConfigured())
        #expect(try await !client.hasSavedConnection())
        #expect(await store.configuration == nil)
        #expect(await store.tokens == nil)
    }

    @Test func authorizationURLFromBrokerMustMatchZoomClientCallbackAndOriginalPKCE() throws {
        let verifier = "v".padding(toLength: 43, withPad: "v", startingAt: 0)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).zoomBase64URL
        var valid = URLComponents(string: "https://zoom.us/oauth/authorize")!
        valid.queryItems = [.init(name: "client_id", value: managed.oauthPublicClientID),
            .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: managed.oauthRedirectURL.absoluteString),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: "v1.fixture.session")]
        #expect(ZoomManagedOAuth.validatedAuthorizeURL(valid.string!, configuration: managed, verifier: verifier) != nil)
        for (key, value) in [("client_id", "another-app"), ("redirect_uri", "http://127.0.0.1:5555/callback"),
                             ("code_challenge", "another-challenge"), ("code_challenge_method", "plain"), ("state", "unsealed")] {
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

    @Test func oldStoredTokensDecodeWithoutGrantAndManagedTokensRedactIt() throws {
        let encoder = JSONEncoder()
        let original = tokens(grant: "private-signing-grant-fixture")
        let encoded = try encoder.encode(original)
        #expect(try JSONDecoder().decode(ZoomOAuthTokens.self, from: encoded).signingAuthorization == original.signingAuthorization)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "signingAuthorization")
        let decoded = try JSONDecoder().decode(ZoomOAuthTokens.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.signingAuthorization == nil)
        #expect(!String(describing: original).contains("private-signing-grant-fixture"))
        #expect(!String(reflecting: original).contains("fixture-access"))
    }

    @Test func cameraSettingsAuthorizeWithoutFetchingZAKOrCreatingMeeting() async throws {
        let store = ManagedZoomStore(tokens: tokens())
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        let signature = try await client.cameraSettingsSignature()
        #expect(!signature.isEmpty)
        #expect(await server.requests.map { $0.url?.absoluteString } == [managed.sdkSignerURL.absoluteString])
        try await client.configure(personal)
        #expect(try await !client.cameraSettingsSignature().isEmpty)
        #expect(await server.requests.count == 1)
    }

    @Test func cameraSettingsRefreshExpiredSigningAuthorizationWithoutZAK() async throws {
        let server = ManagedZoomServer(rejectFirstSignature: true)
        let client = makeClient(ManagedZoomStore(tokens: tokens()), server)
        _ = try await client.cameraSettingsSignature()
        let requests = await server.requests
        #expect(requests.filter { $0.url?.path == "/v1/oauth/token" }.count == 1)
        #expect(requests.filter { $0.url?.path == "/v1/meeting-sdk/signature" }.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "signer.example" })
    }

    @Test func cancelledCameraSettingsCannotReturnLateSignature() async throws {
        let server = ManagedZoomServer(pauseSignature: true)
        let client = makeClient(ManagedZoomStore(tokens: tokens()), server)
        let request = Task { try await client.cameraSettingsSignature() }
        await server.waitForSignature()
        request.cancel()
        await server.resumeSignature()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await server.requests.allSatisfy { $0.url?.host == "signer.example" })
    }

    @Test func signsOnlyAtPinnedEndpointWithMatchedAccessAndServiceGrant() async throws {
        let store = ManagedZoomStore(tokens: tokens())
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        let credentials = try await client.meetingCredentials()
        #expect(credentials.zak == "fixture-zak")
        let requests = await server.requests
        #expect(requests.map { $0.url?.absoluteString } == [
            "https://api.zoom.us/v2/users/me/zak", managed.sdkSignerURL.absoluteString
        ])
        let request = try #require(requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        #expect(request.value(forHTTPHeaderField: "X-Signing-Authorization") == "fixture-signing-grant")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(!request.httpShouldHandleCookies)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!String(describing: credentials).contains(credentials.sdkJWT))
    }

    @Test func missingGrantRefreshesThroughManagedEndpointOnceForConcurrentRequests() async throws {
        let store = ManagedZoomStore(tokens: tokens(grant: nil))
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        async let first = client.meetingCredentials()
        async let second = client.meetingCredentials()
        _ = try await (first, second)
        let requests = await server.requests
        let exchanges = requests.filter { $0.url?.path == "/v1/oauth/token" }
        #expect(exchanges.count == 1)
        let exchange = try #require(exchanges.first)
        #expect(exchange.url?.host == "signer.example")
        #expect(exchange.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(data: exchange.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("client_id=managed-public"))
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=fixture-refresh"))
        #expect(!body.contains("secret"))
        #expect(await store.tokens?.signingAuthorization == "refreshed-signing-grant")
        #expect(await store.tokens?.refreshToken == "rotated-refresh")
        let signatures = requests.filter { $0.url?.path == "/v1/meeting-sdk/signature" }
        #expect(signatures.count == 2)
        #expect(signatures.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access" })
        #expect(signatures.allSatisfy { $0.value(forHTTPHeaderField: "X-Signing-Authorization") == "refreshed-signing-grant" })
    }

    @Test func expiredSigningAuthorizationRefreshesOnceAndRetriesWithNewGrant() async throws {
        let server = ManagedZoomServer(rejectFirstSignature: true)
        let client = makeClient(ManagedZoomStore(tokens: tokens()), server)
        _ = try await client.meetingCredentials()
        let requests = await server.requests
        #expect(requests.filter { $0.url?.path == "/v1/oauth/token" }.count == 1)
        let signatures = requests.filter { $0.url?.path == "/v1/meeting-sdk/signature" }
        #expect(signatures.count == 2)
        #expect(signatures.first?.value(forHTTPHeaderField: "X-Signing-Authorization") == "fixture-signing-grant")
        #expect(signatures.last?.value(forHTTPHeaderField: "X-Signing-Authorization") == "refreshed-signing-grant")
    }

    @Test func productionHTTPSExchangeReturnsOnlyBoundHandoffToDesktopAndStoresGrant() async throws {
        let store = ManagedZoomStore()
        let server = ManagedZoomServer()
        let client = makeClient(store, server)
        try await client.connect { url in
            Task {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.first(where: { $0.name == "redirect_uri" })?.value == "https://signer.example/oauth/zoom/callback")
                #expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
                guard let state = await server.sessionFields?["state"],
                      var callback = URLComponents(string: "yap://oauth/zoom") else { return }
                callback.queryItems = [.init(name: "handoff", value: "v1.fixture.handoff"), .init(name: "state", value: state)]
                guard let callbackURL = callback.url else { return }
                #expect(ZoomManagedOAuthCallback.receive(callbackURL))
                #expect(ZoomManagedOAuthCallback.receive(callbackURL)) // A second delivery is ignored.
            }
        }
        let request = try #require(await server.requests.first { $0.url?.path == "/v1/oauth/token" })
        #expect(request.url?.absoluteString == "https://signer.example/v1/oauth/token")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=urn%3Ayap%3Aparams%3Aoauth%3Agrant-type%3Ahandoff"))
        #expect(body.contains("handoff=v1.fixture.handoff"))
        #expect(body.contains("code_verifier="))
        #expect(!body.contains("redirect_uri="))
        #expect(!body.contains("code="))
        #expect(!body.contains("client_secret"))
        #expect(try await client.hasSavedConnection())
        #expect(await store.tokens?.signingAuthorization == "refreshed-signing-grant")
        #expect(await server.requests.filter { $0.url?.path == "/v1/oauth/token" }.count == 1)
    }

    @Test func malformedAndUnsolicitedDesktopCallbacksCannotCompleteSignIn() async throws {
        let server = ManagedZoomServer()
        let client = makeClient(ManagedZoomStore(), server)
        try await client.connect { _ in
            Task {
                let state = await server.sessionFields?["state"] ?? ""
                for raw in ["yap://oauth/zoom?state=unrelated&handoff=v1.fixture.handoff",
                            "yap://oauth/zoom?state=\(state)&state=\(state)&handoff=v1.fixture.handoff",
                            "yap://oauth/zoom?state=\(state)&handoff=v1.fixture.handoff&error=access_denied",
                            "yap://oauth/zoom?state=\(state)&code=plaintext-code",
                            "yap://oauth/zoom?state=\(state)&handoff=v1.fixture.handoff#fragment",
                            "yap://oauth/other?state=\(state)&handoff=v1.fixture.handoff"] {
                    #expect(ZoomManagedOAuthCallback.receive(URL(string: raw)!))
                }
                #expect(await server.requests.count == 1)
                #expect(!ZoomManagedOAuthCallback.receive(URL(string: "yap://join?meeting=123")!))
                ZoomManagedOAuthCallback.receive(URL(string: "yap://oauth/zoom?state=\(state)&handoff=v1.fixture.handoff")!)
            }
        }
        #expect(await server.requests.filter { $0.url?.path == "/v1/oauth/token" }.count == 1)
    }

    @Test func cancelledManagedSignInDiscardsLateDesktopCallback() async throws {
        let server = ManagedZoomServer()
        let store = ManagedZoomStore()
        let client = makeClient(store, server)
        await #expect(throws: CancellationError.self) {
            try await client.connect { _ in
                Task {
                    let state = await server.sessionFields?["state"] ?? ""
                    try await client.disconnect()
                    ZoomManagedOAuthCallback.receive(URL(string: "yap://oauth/zoom?state=\(state)&handoff=v1.fixture.handoff")!)
                }
            }
        }
        #expect(await server.requests.filter { $0.url?.path == "/v1/oauth/token" }.isEmpty)
        #expect(await store.tokens == nil)
    }

    @Test func managedExchangeWithoutBoundGrantCannotSaveUnusableAuthorization() async throws {
        let store = ManagedZoomStore(tokens: tokens(grant: nil))
        let server = ManagedZoomServer(omitSigningGrant: true)
        let client = makeClient(store, server)
        await #expect(throws: ZoomAccountError.invalidSigningResponse) { try await client.meetingCredentials() }
        #expect(await server.requests.count == 1)
        #expect(await store.tokens?.accessToken == "fixture-access")
        #expect(await store.tokens?.signingAuthorization == nil)
    }

    @Test func disconnectOrCancellationDuringSigningCannotReturnCredentials() async throws {
        for disconnect in [false, true] {
            let server = ManagedZoomServer(pauseSignature: true)
            let store = ManagedZoomStore(tokens: tokens())
            let client = makeClient(store, server)
            let request = Task { try await client.meetingCredentials() }
            await server.waitForSignature()
            if disconnect { try await client.disconnect() } else { request.cancel() }
            await server.resumeSignature()
            await #expect(throws: CancellationError.self) { try await request.value }
            if disconnect { #expect(await store.tokens == nil) }
        }
    }

    @Test(arguments: [401, 403, 429, 302, 500])
    func signerErrorsDoNotExposeRemoteResponseBodies(status: Int) async throws {
        let transport = ZoomHTTPTransport { request in
            (Data(#"{"error":"private upstream response fixture"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await ZoomRemoteSDKSigner.signature(configuration: managed, tokens: tokens(), transport: transport)
            Issue.record("Expected signer failure")
        } catch {
            #expect(!error.localizedDescription.contains("private upstream"))
            let expected: ZoomAccountError = switch status {
            case 401: .notConnected
            case 403: .signingDenied
            case 429: .rateLimited
            default: .signingUnavailable
            }
            #expect(error as? ZoomAccountError == expected)
        }
    }

    @Test func signerRejectsWrongAppMalformedLongLivedOrExpiredJWTs() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.timeIntervalSince1970 - 30 + 3_600
        let valid = try managedJWT(now: now)
        try ZoomRemoteSDKSigner.validate(valid, expiresAt: expiry, sdkClientID: managed.sdkClientID, now: now)
        for candidate in ["", "a.b.c", valid + ".extra", String(repeating: "a", count: 9_000),
                          try managedJWT(now: now, sdkClientID: "wrong-app"),
                          try managedJWT(now: now.addingTimeInterval(-3_600)),
                          try managedJWT(now: now.addingTimeInterval(120))] {
            #expect(throws: ZoomAccountError.invalidSigningResponse) {
                try ZoomRemoteSDKSigner.validate(candidate, expiresAt: expiry, sdkClientID: managed.sdkClientID, now: now)
            }
        }
        #expect(throws: ZoomAccountError.invalidSigningResponse) {
            try ZoomRemoteSDKSigner.validate(valid, expiresAt: expiry + 1, sdkClientID: managed.sdkClientID, now: now)
        }
        #expect(!ZoomRemoteSDKSigner.validHeaderToken("grant\ninjected"))
        #expect(!ZoomRemoteSDKSigner.validHeaderToken(""))
    }

    @Test func signerRejectsRedirectedAndOversizedResponses() async throws {
        for redirected in [false, true] {
            let transport = ZoomHTTPTransport { request in
                let url = redirected ? URL(string: "https://other.example/v1/meeting-sdk/signature")! : request.url!
                return (Data(repeating: 0x20, count: 16_385),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            await #expect(throws: ZoomAccountError.invalidSigningResponse) {
                try await ZoomRemoteSDKSigner.signature(configuration: managed, tokens: tokens(), transport: transport)
            }
        }
    }

    private func makeClient(_ store: ManagedZoomStore, _ server: ManagedZoomServer) -> ZoomAccountClient {
        ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) }, publicConfiguration: managed)
    }
    private func tokens(clientID: String = "managed-public", grant: String? = "fixture-signing-grant") -> ZoomOAuthTokens {
        .init(clientID: clientID, accessToken: "fixture-access", refreshToken: "fixture-refresh",
              expiresAt: .now.addingTimeInterval(3_600), signingAuthorization: grant)
    }
}

private func managedJWT(now: Date = .now, sdkClientID: String = "managed-sdk") throws -> String {
    try ZoomSDKJWT.make(configuration: .init(sdkClientID: sdkClientID, sdkClientSecret: "signing-fixture-secret",
                                            oauthPublicClientID: "managed-public"), now: now)
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
    private let rejectFirstSignature: Bool
    private let omitSigningGrant: Bool
    private let pauseSignature: Bool
    private var signatureCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(rejectFirstSignature: Bool = false, omitSigningGrant: Bool = false, pauseSignature: Bool = false) {
        self.rejectFirstSignature = rejectFirstSignature
        self.omitSigningGrant = omitSigningGrant
        self.pauseSignature = pauseSignature
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: Data
        var status = 200
        switch request.url?.path {
        case "/v1/oauth/session":
            let fields = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
            let verifier = fields["code_verifier"] ?? ""
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            var authorize = URLComponents(string: "https://zoom.us/oauth/authorize")!
            authorize.queryItems = [.init(name: "client_id", value: fields["client_id"]),
                .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: "https://signer.example/oauth/zoom/callback"),
                .init(name: "state", value: "v1.fixture.session"), .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256")]
            body = try JSONSerialization.data(withJSONObject: ["authorize_url": authorize.url!.absoluteString, "expires_in": 180])
        case "/v1/oauth/token":
            try await Task.sleep(for: .milliseconds(20))
            var response: [String: Any] = ["access_token": "refreshed-access", "refresh_token": "rotated-refresh",
                "token_type": "bearer", "expires_in": 3_600, "scope": "user:read:zak"]
            if !omitSigningGrant { response["signing_authorization"] = "refreshed-signing-grant" }
            body = try JSONSerialization.data(withJSONObject: response)
        case "/v1/meeting-sdk/signature":
            signatureCount += 1
            if pauseSignature {
                await withCheckedContinuation { continuation in
                    gate = continuation
                    waiter?.resume()
                    waiter = nil
                }
            }
            if rejectFirstSignature && signatureCount == 1 {
                status = 401
                body = Data("{}".utf8)
            } else {
                let now = Date()
                body = try JSONSerialization.data(withJSONObject: ["signature": try managedJWT(now: now),
                    "expiresAt": Int(now.timeIntervalSince1970) - 30 + 3_600])
            }
        default: body = Data(#"{"token":"fixture-zak"}"#.utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    var sessionFields: [String: String]? {
        requests.first { $0.url?.path == "/v1/oauth/session" }?.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }
    func waitForSignature() async {
        if gate != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resumeSignature() { gate?.resume(); gate = nil }
}
