import CryptoKit
import Foundation

/// The application routes this dedicated callback before meeting invitations.
/// Unsolicited, malformed, cancelled and already consumed callbacks are ignored.
@MainActor
public enum ZoomManagedOAuthCallback {
    private static var pending: [String: ZoomManagedOAuthPending] = [:]

    @discardableResult public static func receive(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "yap", url.host?.lowercased() == "oauth" else { return false }
        guard url.absoluteString.utf8.count <= 16_384,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/zoom", components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else { return true }
        let items = components.queryItems ?? []
        guard items.allSatisfy({ ["state", "handoff", "error"].contains($0.name) }),
              Set(items.map(\.name)).count == items.count,
              let state = items.first(where: { $0.name == "state" })?.value,
              let attempt = pending[state] else { return true }
        let handoff = items.first(where: { $0.name == "handoff" })?.value
        let error = items.first(where: { $0.name == "error" })?.value
        if let handoff, error == nil, ZoomManagedOAuth.validEnvelope(handoff) {
            pending.removeValue(forKey: state)
            attempt.finish(.success(handoff))
        } else if handoff == nil, let error, ["access_denied", "authorization_failed"].contains(error) {
            pending.removeValue(forKey: state)
            attempt.finish(.failure(error == "access_denied" ? ZoomAccountError.authorizationDenied : .invalidResponse))
        }
        return true
    }

    fileprivate static func register(_ attempt: ZoomManagedOAuthPending, state: String) {
        pending[state] = attempt
    }

    fileprivate static func remove(state: String) { pending.removeValue(forKey: state) }
}

@MainActor
private final class ZoomManagedOAuthPending {
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?

    func wait() async throws -> String {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

enum ZoomManagedOAuth {
    @MainActor
    static func authorize(configuration: ZoomPublicConfiguration, transport: ZoomHTTPTransport,
                          openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> ZoomDesktopOAuth.Authorization {
        let verifier = try ZoomDesktopOAuth.randomToken()
        // Independent proof lets the service release the code without ever
        // receiving the OAuth PKCE verifier that only Zoom needs.
        let handoffVerifier = try ZoomDesktopOAuth.randomToken()
        let state = try ZoomDesktopOAuth.randomToken()
        let attempt = ZoomManagedOAuthPending()
        return try await withTaskCancellationHandler {
            defer { ZoomManagedOAuthCallback.remove(state: state) }
            try Task.checkCancellation()
            var request = URLRequest(url: configuration.oauthSessionURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": configuration.oauthPublicClientID, "code_challenge": challenge(verifier),
                "code_challenge_method": "S256", "handoff_challenge": challenge(handoffVerifier), "state": state
            ])
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard response.url == configuration.oauthSessionURL, response.statusCode == 200, data.count <= 16_384,
                  let session = try? JSONDecoder().decode(Session.self, from: data),
                  session.expires_in > 0, session.expires_in <= 180,
                  let url = validatedAuthorizeURL(session.authorize_url, configuration: configuration, verifier: verifier) else {
                throw ZoomAccountError.invalidResponse
            }
            ZoomManagedOAuthCallback.register(attempt, state: state)
            openURL(url)
            let handoff = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await attempt.wait() }
                group.addTask {
                    try await Task.sleep(for: .seconds(session.expires_in))
                    await attempt.finish(.failure(ZoomAccountError.authorizationTimedOut))
                    throw ZoomAccountError.authorizationTimedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            let code = try await redeem(handoff: handoff, state: state, handoffVerifier: handoffVerifier,
                configuration: configuration, transport: transport)
            try Task.checkCancellation()
            return ZoomDesktopOAuth.Authorization(code: code, verifier: verifier,
                redirectURI: configuration.oauthRedirectURL.absoluteString)
        } onCancel: {
            Task { @MainActor in
                ZoomManagedOAuthCallback.remove(state: state)
                attempt.finish(.failure(CancellationError()))
            }
        }
    }

    private static func redeem(handoff: String, state: String, handoffVerifier: String,
                               configuration: ZoomPublicConfiguration, transport: ZoomHTTPTransport) async throws -> String {
        var request = URLRequest(url: configuration.oauthHandoffURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": configuration.oauthPublicClientID, "handoff": handoff,
            "state": state, "handoff_verifier": handoffVerifier
        ])
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        // Explicitly reject the old token-returning response contract and any
        // service-directed destination for the subsequent native token exchange.
        guard response.url == configuration.oauthHandoffURL, response.statusCode == 200, data.count <= 16_384,
              let fields = try? JSONDecoder().decode([String: String].self, from: data),
              Set(fields.keys) == Set(["code", "client_id", "redirect_uri"]),
              fields["client_id"] == configuration.oauthPublicClientID,
              fields["redirect_uri"] == configuration.oauthRedirectURL.absoluteString,
              let code = fields["code"], code.utf8.count <= 4_096, ZoomOAuthTokens.validToken(code) else {
            throw ZoomAccountError.invalidResponse
        }
        return code
    }

    private static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).zoomBase64URL
    }

    private struct Session: Decodable {
        let authorize_url: String
        let expires_in: Int
    }

    static func validEnvelope(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 12_000 && parts.count == 3 && parts[0] == "v2" &&
            parts.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
    }

    static func validatedAuthorizeURL(_ value: String, configuration: ZoomPublicConfiguration, verifier: String) -> URL? {
        guard value.utf8.count <= 8192, let components = URLComponents(string: value),
              components.scheme == "https", components.host == "zoom.us", components.path == "/oauth/authorize",
              components.port == nil, components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        let items = components.queryItems ?? []
        let names = ["client_id", "response_type", "redirect_uri", "state", "code_challenge", "code_challenge_method"]
        guard items.count == names.count, Set(items.map(\.name)) == Set(names) else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let expectedChallenge = challenge(verifier)
        guard fields["client_id"] == configuration.oauthPublicClientID, fields["response_type"] == "code",
              fields["redirect_uri"] == configuration.oauthRedirectURL.absoluteString,
              fields["code_challenge"] == expectedChallenge, fields["code_challenge_method"] == "S256",
              fields["state"].map(validEnvelope) == true else { return nil }
        return components.url
    }
}
