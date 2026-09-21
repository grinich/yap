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
    struct Handoff: Sendable {
        let value: String
        let verifier: String
        let state: String
    }

    @MainActor
    static func authorize(configuration: ZoomPublicConfiguration, transport: ZoomHTTPTransport,
                          openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> Handoff {
        let verifier = try ZoomDesktopOAuth.randomToken()
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
                "client_id": configuration.oauthPublicClientID, "code_verifier": verifier, "state": state
            ])
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard response.statusCode == 200, data.count <= 16_384,
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
            return Handoff(value: handoff, verifier: verifier, state: state)
        } onCancel: {
            Task { @MainActor in
                ZoomManagedOAuthCallback.remove(state: state)
                attempt.finish(.failure(CancellationError()))
            }
        }
    }

    private struct Session: Decodable {
        let authorize_url: String
        let expires_in: Int
    }

    static func validEnvelope(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 12_000 && parts.count == 3 && parts[0] == "v1" &&
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
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).zoomBase64URL
        guard fields["client_id"] == configuration.oauthPublicClientID, fields["response_type"] == "code",
              fields["redirect_uri"] == configuration.oauthRedirectURL.absoluteString,
              fields["code_challenge"] == challenge, fields["code_challenge_method"] == "S256",
              fields["state"].map(validEnvelope) == true else { return nil }
        return components.url
    }
}
