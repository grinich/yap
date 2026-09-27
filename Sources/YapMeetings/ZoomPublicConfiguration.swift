import Foundation

/// Native public-client configuration, safe to include in a signed app.
/// The same public client ID authorizes OAuth and ZoomSDKAuthContext.publicAppKey.
public struct ZoomPublicConfiguration: Sendable, Equatable {
    public let oauthPublicClientID: String
    public let oauthRedirectURL: URL

    public init(oauthPublicClientID: String, oauthRedirectURL: URL) {
        self.oauthPublicClientID = oauthPublicClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.oauthRedirectURL = oauthRedirectURL
    }

    public var isValid: Bool {
        [oauthPublicClientID].allSatisfy {
            !$0.isEmpty && $0.count <= 1_024 && !$0.contains(where: \.isWhitespace)
        } && oauthRedirectURL.scheme == "https"
            && !(oauthRedirectURL.host?.isEmpty ?? true)
            && oauthRedirectURL.user == nil && oauthRedirectURL.password == nil
            && oauthRedirectURL.port == nil
            && oauthRedirectURL.query == nil && oauthRedirectURL.fragment == nil
            && oauthRedirectURL.path == "/oauth/zoom/callback"
    }

    /// OAuth tokens travel only between the native app and Zoom.
    public var oauthTokenURL: URL {
        URL(string: "https://zoom.us/oauth/token")!
    }

    public var oauthSessionURL: URL {
        var components = URLComponents(url: oauthRedirectURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/oauth/session"
        return components.url!
    }

    public var oauthHandoffURL: URL {
        var components = URLComponents(url: oauthRedirectURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/oauth/handoff"
        return components.url!
    }

    public static func load(info: [String: Any]) throws -> Self? {
        let keys = ["YapZoomOAuthClientID", "YapZoomOAuthRedirectURL"]
        guard keys.contains(where: { info[$0] != nil }) else { return nil }
        guard let oauth = info[keys[0]] as? String,
              let rawURL = info[keys[1]] as? String, let url = URL(string: rawURL) else {
            throw ZoomAccountError.invalidPublicConfiguration
        }
        let configuration = Self(oauthPublicClientID: oauth, oauthRedirectURL: url)
        guard configuration.isValid else { throw ZoomAccountError.invalidPublicConfiguration }
        return configuration
    }
}

public enum ZoomConfigurationMode: Sendable, Equatable {
    case unconfigured, personal, managed
}

enum ZoomRuntimeConfiguration: Sendable {
    case personal(ZoomPersonalConfiguration)
    case managed(ZoomPublicConfiguration)

    var oauthPublicClientID: String {
        switch self {
        case .personal(let configuration): configuration.oauthPublicClientID
        case .managed(let configuration): configuration.oauthPublicClientID
        }
    }
    var publicConfiguration: ZoomPublicConfiguration? {
        if case .managed(let configuration) = self { configuration } else { nil }
    }
    var mode: ZoomConfigurationMode {
        switch self {
        case .personal: .personal
        case .managed: .managed
        }
    }
}
