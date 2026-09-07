import Foundation

/// Public identifiers and the trusted service URL, safe to include in a signed app.
/// SDK secrets and signing-service credentials are never part of this configuration.
public struct ZoomPublicConfiguration: Sendable, Equatable {
    public let oauthPublicClientID: String
    public let sdkClientID: String
    public let sdkSignerURL: URL

    public init(oauthPublicClientID: String, sdkClientID: String, sdkSignerURL: URL) {
        self.oauthPublicClientID = oauthPublicClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sdkClientID = sdkClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sdkSignerURL = sdkSignerURL
    }

    public var isValid: Bool {
        [oauthPublicClientID, sdkClientID].allSatisfy {
            !$0.isEmpty && $0.count <= 1_024 && !$0.contains(where: \.isWhitespace)
        } && sdkSignerURL.scheme?.lowercased() == "https"
            && !(sdkSignerURL.host?.isEmpty ?? true)
            && sdkSignerURL.user == nil && sdkSignerURL.password == nil
            && (sdkSignerURL.port == nil || sdkSignerURL.port == 443)
            && sdkSignerURL.query == nil && sdkSignerURL.fragment == nil
            && sdkSignerURL.path == "/v1/meeting-sdk/signature"
    }

    /// Both endpoints belong to the same origin fixed by the signed bundle.
    public var oauthTokenURL: URL {
        var components = URLComponents(url: sdkSignerURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/oauth/token"
        return components.url!
    }

    public static func load(info: [String: Any]) throws -> Self? {
        let keys = ["ZooomZoomOAuthClientID", "ZooomZoomSDKClientID", "ZooomZoomSDKSignerURL"]
        guard keys.contains(where: { info[$0] != nil }) else { return nil }
        guard let oauth = info[keys[0]] as? String, let sdk = info[keys[1]] as? String,
              let rawURL = info[keys[2]] as? String, let url = URL(string: rawURL) else {
            throw ZoomAccountError.invalidPublicConfiguration
        }
        let configuration = Self(oauthPublicClientID: oauth, sdkClientID: sdk, sdkSignerURL: url)
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
