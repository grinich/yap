import Foundation
import YapCredentials

public struct GoogleOAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret
    }

    public var isValid: Bool { clientID.hasSuffix(".apps.googleusercontent.com") && !clientID.contains(where: \.isWhitespace) }

    public static let scopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    ]
}

public struct GoogleOAuthTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let connectionID: UUID
    public let clientID: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, connectionID: UUID = UUID(), clientID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.connectionID = connectionID
        self.clientID = clientID
    }

    private enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expiresAt, connectionID, clientID }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        // Older credentials can reconnect, but never inherit an unbound legacy cache.
        connectionID = try values.decodeIfPresent(UUID.self, forKey: .connectionID) ?? UUID()
        clientID = try values.decodeIfPresent(String.self, forKey: .clientID)
    }
}

public protocol GoogleTokenStore: Sendable {
    func load() async throws -> GoogleOAuthTokens?
    func save(_ tokens: GoogleOAuthTokens) async throws
    func delete() async throws
}

/// Connection credentials never enter UserDefaults, the calendar cache, or diagnostics.
public actor KeychainGoogleTokenStore: GoogleTokenStore {
    private let key: CredentialKey
    private let vault: CredentialVault

    public init(service: String = "app.yap.google-calendar", account: String = "personal",
                vault: CredentialVault = .shared) {
        key = CredentialKey(service: service, account: account)
        self.vault = vault
    }

    public func load() throws -> GoogleOAuthTokens? {
        guard let data = try access({ try vault.load(key) }) else { return nil }
        return try JSONDecoder().decode(GoogleOAuthTokens.self, from: data)
    }

    public func save(_ tokens: GoogleOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try access { try vault.save(data, for: key) }
    }

    public func delete() throws { try access { try vault.delete(key) } }

    private func access<Value>(_ action: () throws -> Value) throws -> Value {
        do { return try action() }
        catch CredentialVaultError.keychain(let status) { throw GoogleCalendarError.keychain(status) }
        catch CredentialVaultError.invalidData { throw GoogleCalendarError.invalidResponse }
    }
}

public struct CalendarHTTPTransport: Sendable {
    public var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    public static var live: CalendarHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoCalendarRedirects(), delegateQueue: nil)
        return CalendarHTTPTransport { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
            return (data, response)
        }
    }
}

/// Prevents a response redirect from forwarding requests or credentials to another endpoint.
private final class NoCalendarRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
