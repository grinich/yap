import Foundation

public extension GoogleOAuthConfiguration {
    /// One public desktop OAuth client for every Yap build. Account tokens stay in Keychain.
    /// The packaged app uses its own resource; swift run/tests use the SwiftPM resource bundle.
    static func yap() throws -> GoogleOAuthConfiguration {
        let url: URL?
        if Bundle.main.bundleURL.pathExtension == "app" {
            url = Bundle.main.url(forResource: "GoogleOAuth", withExtension: "plist")
        } else {
            url = Bundle.module.url(forResource: "GoogleOAuth", withExtension: "plist")
        }
        guard let url else { throw GoogleCalendarError.notConfigured }
        let data = try Data(contentsOf: url)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let clientID = info["YapGoogleClientID"],
              let secret = info["YapGoogleClientSecret"], !secret.isEmpty,
              !secret.contains(where: \.isWhitespace) else { throw GoogleCalendarError.notConfigured }
        let configuration = GoogleOAuthConfiguration(clientID: clientID, clientSecret: secret)
        guard configuration.isValid else { throw GoogleCalendarError.notConfigured }
        return configuration
    }
}
