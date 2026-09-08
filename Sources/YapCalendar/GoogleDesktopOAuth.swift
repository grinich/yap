import CryptoKit
import Foundation
import Network
import Security
import YapOAuth

enum GoogleDesktopOAuth {
    struct Authorization: Sendable {
        let code: String
        let verifier: String
        let redirectURI: String
    }

    static func authorize(configuration: GoogleOAuthConfiguration,
                          timeout: Duration = .seconds(180),
                          openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> Authorization {
        let verifier = try randomToken()
        let state = try randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let listener = OAuthLoopbackListener(expectedState: state)
        // Cover listener startup and browser handoff too, not only the final callback wait.
        let deadline = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            await listener.stop(error: GoogleCalendarError.authorizationTimedOut)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let redirect = try await listener.start()
                var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                components.queryItems = [
                    URLQueryItem(name: "client_id", value: configuration.clientID),
                    URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: GoogleOAuthConfiguration.scopes.joined(separator: " ")),
                    URLQueryItem(name: "state", value: state),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent")
                ]
                guard let url = components.url else { throw GoogleCalendarError.invalidResponse }
                try Task.checkCancellation()
                await openURL(url)
                let code = try await listener.waitForCode()
                try Task.checkCancellation()
                await listener.stop()
                return Authorization(code: code, verifier: verifier, redirectURI: redirect.absoluteString)
            } catch {
                await listener.stop(error: error)
                throw error
            }
        } onCancel: {
            Task { await listener.stop(error: CancellationError()) }
        }
    }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw GoogleCalendarError.keychain(status) }
        return Data(bytes).base64URL
    }

    static func callbackCode(target: String, expectedState: String) throws -> String {
        guard target.hasPrefix("/?"), let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == "/", components.fragment == nil else { throw GoogleCalendarError.invalidCallback }
        let parameters = components.queryItems ?? []
        let states = parameters.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { throw GoogleCalendarError.invalidCallback }
        let codes = parameters.filter { $0.name == "code" }
        let errors = parameters.filter { $0.name == "error" }
        if !errors.isEmpty {
            guard errors.count == 1, codes.isEmpty, errors[0].value?.isEmpty == false else { throw GoogleCalendarError.invalidCallback }
            throw GoogleCalendarError.authorizationDenied
        }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty, code.utf8.count <= 8_192,
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GoogleCalendarError.invalidCallback
        }
        return code
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

/// The listener is bound to 127.0.0.1, never a LAN interface, and lives for one sign-in attempt.
private actor OAuthLoopbackListener {
    private let expectedState: String
    private let queue = DispatchQueue(label: "app.yap.google-oauth-loopback")
    private var listener: NWListener?
    private var port: UInt16?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var stopped = false
    private var connections: [UUID: NWConnection] = [:]

    init(expectedState: String) { self.expectedState = expectedState }

    func start() async throws -> URL {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let actualPort = listener?.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(actualPort)/") else {
                stop(error: GoogleCalendarError.invalidCallback)
                return
            }
            port = actualPort
            startContinuation?.resume(returning: url)
            startContinuation = nil
        case .failed:
            stop(error: GoogleCalendarError.invalidCallback)
        default: break
        }
    }

    func waitForCode() async throws -> String {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { codeContinuation = $0 }
    }

    func stop(error: any Error = CancellationError()) {
        stopped = true
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        startContinuation?.resume(throwing: error)
        startContinuation = nil
        if result == nil { finish(.failure(error)) }
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        codeContinuation?.resume(with: result)
        codeContinuation = nil
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let connectionID = UUID()
        connections[connectionID] = connection
        defer { connections.removeValue(forKey: connectionID) }
        connection.start(queue: queue)
        // A short deadline also closes clients that connect without sending a request.
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); connection.cancel() }
        defer { timeout.cancel() }
        var buffer = Data()
        do {
            while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                let part: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete { continuation.resume(throwing: GoogleCalendarError.invalidCallback) }
                        else { continuation.resume(returning: Data()) }
                    }
                }
                buffer += part
                guard buffer.count <= 16_384 else { throw GoogleCalendarError.invalidCallback }
            }
            guard let request = String(data: buffer, encoding: .utf8), let port else { throw GoogleCalendarError.invalidCallback }
            let lines = request.components(separatedBy: "\r\n")
            let requestParts = (lines.first ?? "").split(separator: " ")
            let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }
            guard requestParts.count == 3, requestParts[0] == "GET",
                  requestParts[2] == "HTTP/1.0" || requestParts[2] == "HTTP/1.1",
                  hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)" else {
                throw GoogleCalendarError.invalidCallback
            }
            do {
                let code = try GoogleDesktopOAuth.callbackCode(target: String(requestParts[1]), expectedState: expectedState)
                await respond(connection, status: "200 OK", outcome: .received)
                finish(.success(code))
            } catch GoogleCalendarError.authorizationDenied {
                await respond(connection, status: "200 OK", outcome: .denied)
                finish(.failure(GoogleCalendarError.authorizationDenied))
            }
        } catch {
            await respond(connection, status: "400 Bad Request", outcome: .invalid)
        }
    }

    private func respond(_ connection: NWConnection, status: String, outcome: OAuthCompletionPage.Outcome) async {
        let icon = Bundle.main.url(forResource: "YapIcon", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
        let page = OAuthCompletionPage(provider: .googleCalendar, outcome: outcome, iconPNG: icon)
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: \(page.contentSecurityPolicy)\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n\(page.body)"
        await withCheckedContinuation { continuation in
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }
}
