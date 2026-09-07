import Foundation

/// Values remain in memory. A URL's pwd value is an opaque Zoom token, not a decoded passcode.
struct ZoomMeetingLink: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let meetingNumber: Int64
    let vanityID: String?
    let embeddedPasscode: String?
    let registrantToken: String?

    var description: String { "ZoomMeetingLink(<redacted>)" }
    var debugDescription: String { description }

    init(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 16_384,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              parts.scheme?.lowercased() == "https",
              host == "zoom.us" || host.hasSuffix(".zoom.us") else { throw MeetingError.invalidLink }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, ["j", "s", "my", "w"].contains(path[1]) else {
            throw MeetingError.invalidLink
        }
        if path[1] == "my" {
            let value = String(path[2])
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
            guard !value.isEmpty, value.count <= 128,
                  value.unicodeScalars.allSatisfy(allowed.contains) else { throw MeetingError.invalidLink }
            meetingNumber = 0
            vanityID = value
        } else {
            let number = path[2]
            guard (9...11).contains(number.utf8.count), number.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int64(number), parsed > 0 else { throw MeetingError.invalidLink }
            meetingNumber = parsed
            vanityID = nil
        }
        func uniqueValue(_ name: String) throws -> String? {
            let values = (parts.queryItems ?? []).filter { $0.name == name }
            guard values.count <= 1 else { throw MeetingError.invalidLink }
            guard let value = values.first?.value, !value.isEmpty else { return nil }
            guard value.utf8.count <= 8_192, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw MeetingError.invalidLink
            }
            return value
        }
        embeddedPasscode = try uniqueValue("pwd")
        registrantToken = try uniqueValue("tk")
    }
}
