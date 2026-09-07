import CryptoKit
import Foundation

public struct ZoomRecordingChatMessage: Identifiable, Sendable, Equatable {
    public let id: String
    /// Elapsed time since the meeting began, not since a recording segment began.
    public let offset: TimeInterval
    public let sender: String
    public let recipient: String?
    public let text: String

    public init(id: String, offset: TimeInterval, sender: String, recipient: String? = nil, text: String) {
        self.id = id
        self.offset = offset
        self.sender = sender
        self.recipient = recipient
        self.text = text
    }
}

/// Reads Zoom's cloud TXT chat export (`HH:mm:ss\tName:\tmessage`) and
/// legacy `From Name to Recipient:` headers. Continuation lines stay with
/// their message. Offsets remain meeting-relative, in transcript order;
/// the player is responsible for mapping them to its recording segment.
public enum ZoomRecordingChatParser {
    public static func parse(_ text: String) -> [ZoomRecordingChatMessage] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        var messages: [ZoomRecordingChatMessage] = []
        var pending: PendingMessage?
        var occurrences: [String: Int] = [:]

        func append(_ pending: PendingMessage?) {
            guard let pending else { return }
            let body = pending.lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // A deterministic content identity survives repeated parsing and
            // preceding unrelated messages. Number duplicates instead of losing them.
            let identity = [String(pending.offset), pending.sender, pending.recipient ?? "", body]
                .map { "\($0.utf8.count):\($0)" }.joined()
            let digest = Data(SHA256.hash(data: Data(identity.utf8))).zoomBase64URL
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            messages.append(ZoomRecordingChatMessage(id: "chat-\(digest)-\(occurrence)",
                offset: pending.offset, sender: pending.sender, recipient: pending.recipient, text: body))
        }

        for line in normalized.components(separatedBy: "\n") {
            if let header = parseHeader(line) {
                append(pending)
                pending = header
            } else if pending != nil {
                pending?.lines.append(line)
            }
        }
        append(pending)
        return messages
    }

    private struct PendingMessage {
        let offset: TimeInterval
        let sender: String
        let recipient: String?
        var lines: [String]
    }

    private static let headerPattern = try! NSRegularExpression(
        pattern: #"^([0-9]{1,4}):([0-9]{2}):([0-9]{2})(?:[.,]([0-9]{1,3}))?[\t ]+(.+)$"#)

    private static func parseHeader(_ line: String) -> PendingMessage? {
        let value = line as NSString
        guard let match = headerPattern.firstMatch(in: line, range: NSRange(location: 0, length: value.length)),
              let hours = Int(value.substring(with: match.range(at: 1))),
              let minutes = Int(value.substring(with: match.range(at: 2))), minutes < 60,
              let seconds = Int(value.substring(with: match.range(at: 3))), seconds < 60 else { return nil }
        let fractionalRange = match.range(at: 4)
        let fractional = fractionalRange.location == NSNotFound ? 0
            : Double("0." + value.substring(with: fractionalRange)) ?? 0
        let offset = TimeInterval(hours * 3_600 + minutes * 60 + seconds) + fractional
        let remainder = value.substring(with: match.range(at: 5))
        // Prefer the canonical delimiter so a ':' inside a display name survives.
        guard let separator = remainder.range(of: ":\t") ?? remainder.range(of: ": ") ?? remainder.range(of: ":") else {
            return nil
        }
        var sender = String(remainder[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        var recipient: String?
        if sender.lowercased().hasPrefix("from ") {
            let participants = String(sender.dropFirst(5))
            if let to = participants.range(of: " to ", options: [.caseInsensitive, .backwards]) {
                recipient = String(participants[to.upperBound...]).trimmingCharacters(in: .whitespaces)
                sender = String(participants[..<to.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !sender.isEmpty else { return nil }
        if recipient?.isEmpty == true { recipient = nil }
        return PendingMessage(offset: offset, sender: sender, recipient: recipient,
                              lines: [String(remainder[separator.upperBound...])])
    }
}
