import Foundation

extension ZoomMeetingLinkParser {
    /// Accepts existing HTTPS invitations or normalizes an explicit native meeting join.
    /// Native links preserve only the meeting number and opaque, percent-encoded passcode.
    /// Unsupported actions and authentication flows return nil for an explicit Workplace fallback.
    public static func normalizedJoinURL(_ string: String) -> URL? {
        guard string.utf8.count <= 16_384 else { return nil }
        if let url = validatedURL(string) { return url }
        guard let parts = URLComponents(string: string, encodingInvalidCharacters: false),
              let scheme = parts.scheme?.lowercased(), ["zoommtg", "zoomus"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), isNativeZoomHost(host),
              parts.percentEncodedHost?.lowercased() == host,
              parts.percentEncodedPath == parts.path,
              !string.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parameters = nativeJoinParameters(parts.percentEncodedQuery) else { return nil }

        // These fields can request host authority, registration, or account authentication.
        // Discarding them could turn the intended operation into a different kind of join.
        let authorityFields: Set<String> = ["zak", "zpk", "ztk", "tk", "token", "jwt", "auth", "auth_token",
                                            "access_token", "refresh_token", "id_token", "hostkey", "host_key",
                                            "hosttoken", "host_token", "role", "host", "start"]
        guard authorityFields.isDisjoint(with: parameters.keys), parameters["stype"]?.value != "100" else { return nil }

        let meetingNumber: String
        if parts.path == "/join" {
            guard parameters["action"]?.value == "join",
                  let number = parameters["confno"], number.encodedValue == number.value else { return nil }
            meetingNumber = number.value
        } else {
            let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.count == 3, path[0].isEmpty, path[1] == "j", parameters["confno"] == nil,
                  parameters["action"] == nil || parameters["action"]?.value == "join" else { return nil }
            meetingNumber = String(path[2])
        }
        guard (9...11).contains(meetingNumber.utf8.count),
              meetingNumber.utf8.allSatisfy({ (48...57).contains($0) }),
              let numericID = Int64(meetingNumber), numericID > 0 else { return nil }

        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = host
        canonical.path = "/j/" + meetingNumber
        if let passcode = parameters["pwd"] {
            // URLQueryItem would decode/re-encode this opaque value, changing literal '+' or escapes.
            canonical.percentEncodedQuery = "pwd=" + passcode.encodedValue
        }
        return canonical.url
    }

    private struct NativeJoinParameter {
        let value: String
        let encodedValue: String
    }

    private static func nativeJoinParameters(_ query: String?) -> [String: NativeJoinParameter]? {
        guard let query else { return [:] }
        let fields = query.split(separator: "&", omittingEmptySubsequences: false)
        guard fields.count <= 64 else { return nil }
        var parameters: [String: NativeJoinParameter] = [:]
        for field in fields {
            guard let equals = field.firstIndex(of: "="),
                  let name = String(field[..<equals]).removingPercentEncoding?.lowercased(), !name.isEmpty,
                  name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
                  parameters[name] == nil else { return nil }
            let encodedValue = String(field[field.index(after: equals)...])
            guard let value = encodedValue.removingPercentEncoding, value.utf8.count <= 8_192,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            parameters[name] = NativeJoinParameter(value: value, encodedValue: encodedValue)
        }
        return parameters
    }

    private static func isNativeZoomHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253,
              host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com") else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
