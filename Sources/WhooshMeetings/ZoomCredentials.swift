import CryptoKit
import Foundation
import Security
import WhooshCredentials

/// Private, single-owner development configuration. Never bundle this in a distributed app.
public struct ZoomPersonalConfiguration: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sdkClientID: String
    public let sdkClientSecret: String
    public let oauthPublicClientID: String

    public init(sdkClientID: String, sdkClientSecret: String, oauthPublicClientID: String) {
        self.sdkClientID = sdkClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sdkClientSecret = sdkClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.oauthPublicClientID = oauthPublicClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        [sdkClientID, sdkClientSecret, oauthPublicClientID].allSatisfy {
            !$0.isEmpty && $0.count <= 1_024 && !$0.contains(where: \.isWhitespace)
        }
    }
    public var description: String { "ZoomPersonalConfiguration(redacted)" }
    public var debugDescription: String { description }
    public static let requiredScope = "user:read:zak"
    public static let hostingScope = "meeting:write:meeting"
    public static let registeredRedirectURI = "http://127.0.0.1/callback"
}

public struct ZoomOAuthTokens: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let clientID: String
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(clientID: String, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.clientID = clientID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
    public var description: String { "ZoomOAuthTokens(redacted)" }
    public var debugDescription: String { description }
}

public struct ZoomMeetingCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sdkJWT: String
    public let zak: String
    public let zakExpiresAt: Date
    public var description: String { "ZoomMeetingCredentials(redacted)" }
    public var debugDescription: String { description }
}

public struct ZoomHostingCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let meetingNumber: Int64
    public let credentials: ZoomMeetingCredentials
    public var description: String { "ZoomHostingCredentials(redacted)" }
    public var debugDescription: String { description }
}

public enum ZoomAccountError: LocalizedError, Sendable, Equatable {
    case notConfigured, invalidConfiguration, notConnected, invalidResponse, invalidCallback
    case localCallbackUnavailable
    case authorizationDenied, authorizationTimedOut, authorizationInProgress, missingScope
    case missingHostingScope, meetingCreationUnconfirmed
    case keychain(Int32), network, rateLimited, rejected(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Set up your personal Zoom developer configuration first."
        case .invalidConfiguration: "The Zoom configuration needs a Client ID, Client Secret, and Public Client ID."
        case .notConnected: "Connect your Zoom account to continue."
        case .invalidResponse: "Zoom returned an unexpected response. Please try again."
        case .invalidCallback: "The Zoom sign-in response could not be verified."
        case .localCallbackUnavailable: "Zooom couldn’t open its local sign-in connection. Please try again."
        case .authorizationDenied: "Zoom access was not granted."
        case .authorizationTimedOut: "Zoom sign-in timed out. Please try again."
        case .authorizationInProgress: "A Zoom sign-in is already in progress."
        case .missingScope: "Enable the user:read:zak scope in your Zoom app, then connect again."
        case .missingHostingScope: "Enable the meeting:write:meeting scope in your Zoom app, then disconnect and connect Zoom again to host meetings."
        case .meetingCreationUnconfirmed: "Zoom did not confirm whether it created the meeting. Check your Zoom meetings before reconnecting and trying again; Zooom has stopped automatic retries."
        case .keychain: "Zooom couldn’t securely access your Zoom connection in Keychain."
        case .network: "Zooom couldn’t reach Zoom. Check your connection and try again."
        case .rateLimited: "Zoom is receiving too many requests. Please wait and try again."
        case .rejected(let status): "Zoom could not complete the request (HTTP \(status))."
        }
    }
}

public protocol ZoomCredentialStore: Sendable {
    func loadConfiguration() async throws -> ZoomPersonalConfiguration?
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) async throws
    func loadTokens() async throws -> ZoomOAuthTokens?
    func saveTokens(_ tokens: ZoomOAuthTokens) async throws
    func deleteTokens() async throws
    func deleteAll() async throws
}

public actor KeychainZoomCredentialStore: ZoomCredentialStore {
    private let service: String
    private let vault: CredentialVault
    public init(service: String = "app.whoosh.zoom-personal", vault: CredentialVault = .shared) {
        self.service = service
        self.vault = vault
    }

    public func loadConfiguration() throws -> ZoomPersonalConfiguration? { try load("configuration") }
    public func saveConfiguration(_ configuration: ZoomPersonalConfiguration) throws { try save(configuration, account: "configuration") }
    public func loadTokens() throws -> ZoomOAuthTokens? { try load("oauth-tokens") }
    public func saveTokens(_ tokens: ZoomOAuthTokens) throws { try save(tokens, account: "oauth-tokens") }
    public func deleteTokens() throws { try delete("oauth-tokens") }
    public func deleteAll() throws { try deleteTokens(); try delete("configuration") }

    private func key(_ account: String) -> CredentialKey { CredentialKey(service: service, account: account) }

    private func load<Value: Decodable>(_ account: String) throws -> Value? {
        guard let data = try access({ try vault.load(key(account)) }) else { return nil }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
            throw ZoomAccountError.invalidConfiguration
        }
        return value
    }

    private func save<Value: Encodable>(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        try access { try vault.save(data, for: key(account)) }
    }

    private func delete(_ account: String) throws { try access { try vault.delete(key(account)) } }

    private func access<Value>(_ action: () throws -> Value) throws -> Value {
        do { return try action() }
        catch CredentialVaultError.keychain(let status) { throw ZoomAccountError.keychain(status) }
        catch CredentialVaultError.invalidData { throw ZoomAccountError.invalidConfiguration }
    }
}

enum ZoomSDKJWT {
    /// Only the owner's imported runtime credential is used. Public distribution needs a trusted signer.
    static func make(configuration: ZoomPersonalConfiguration, now: Date = Date()) throws -> String {
        guard configuration.isValid else { throw ZoomAccountError.invalidConfiguration }
        let issued = Int(now.timeIntervalSince1970) - 30
        let expires = issued + 3_600
        let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8).zoomBase64URL
        let payload = try JSONSerialization.data(withJSONObject: [
            "appKey": configuration.sdkClientID, "iat": issued, "exp": expires, "tokenExp": expires
        ], options: [.sortedKeys]).zoomBase64URL
        let message = "\(header).\(payload)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
            using: SymmetricKey(data: Data(configuration.sdkClientSecret.utf8)))
        return "\(message).\(Data(signature).zoomBase64URL)"
    }
}

extension Data {
    var zoomBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
