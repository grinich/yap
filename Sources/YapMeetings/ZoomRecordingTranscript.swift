import CryptoKit
import Foundation

public struct ZoomRecordingTranscriptCue: Identifiable, Sendable, Equatable {
    public let id: String
    /// Seconds from the beginning of this transcript's recording segment.
    public let start: TimeInterval
    public let end: TimeInterval
    public let speaker: String?
    public let text: String

    public init(id: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public enum ZoomRecordingTranscriptError: Error, LocalizedError, Sendable, Equatable {
    case invalidFormat
    case invalidTimestamp
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "This recording’s transcript could not be read as a WebVTT transcript."
        case .invalidTimestamp: "This recording’s transcript contains invalid timing information."
        case .tooLarge: "This recording’s transcript exceeds the viewing limit."
        }
    }
}

/// Reads Zoom's WebVTT transcript export without interpreting HTML or executing styling.
/// Cue order and segment-relative times are preserved; the player maps each segment
/// onto the meeting timeline. Overlapping cues are valid.
public enum ZoomRecordingTranscriptParser {
    // These are viewing limits, not restrictions imposed by the WebVTT format.
    static let maximumByteCount = 8 * 1_024 * 1_024
    static let maximumCueCount = 100_000
    static let maximumTimestamp: TimeInterval = 7 * 24 * 3_600

    public static func parse(_ text: String) throws -> [ZoomRecordingTranscriptCue] {
        try Task.checkCancellation()
        guard text.utf8.count <= maximumByteCount else { throw ZoomRecordingTranscriptError.tooLarge }
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        guard !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ZoomRecordingTranscriptError.invalidFormat
        }
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let lines = normalized.components(separatedBy: "\n")
        guard let signature = lines.first,
              signature == "WEBVTT" || signature.hasPrefix("WEBVTT ") || signature.hasPrefix("WEBVTT\t"),
              !signature.contains("-->") else { throw ZoomRecordingTranscriptError.invalidFormat }

        // Header metadata (for example Kind, Language, and X-TIMESTAMP-MAP)
        // ends at the first blank line. It is not transcript speech.
        var index = 1
        while index < lines.count, !isBlank(lines[index]) {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let line = lines[index] as NSString
            guard !lines[index].contains("-->"),
                  metadataPattern.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) != nil else {
                throw ZoomRecordingTranscriptError.invalidFormat
            }
            index += 1
        }
        var cues: [ZoomRecordingTranscriptCue] = []
        var occurrences: [String: Int] = [:]
        var cueCount = 0
        while index < lines.count {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if isBlank(lines[index]) { index += 1; continue }
            let blockStart = index
            while index < lines.count, !isBlank(lines[index]) {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                index += 1
            }
            let block = Array(lines[blockStart..<index])
            let first = block[0].trimmingCharacters(in: .whitespaces)
            if first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t")
                || first == "STYLE" || first == "REGION" { continue }

            let timingIndex = first.contains("-->") ? 0 : 1
            guard block.indices.contains(timingIndex) else { throw ZoomRecordingTranscriptError.invalidFormat }
            let (start, end) = try parseTiming(block[timingIndex])
            let payload = block.dropFirst(timingIndex + 1).joined(separator: "\n")
            // A second timing line within the same block indicates a missing cue
            // separator. Do not silently display its timestamps as spoken text.
            guard !payload.contains("-->") else { throw ZoomRecordingTranscriptError.invalidFormat }
            cueCount += 1
            guard cueCount <= maximumCueCount else { throw ZoomRecordingTranscriptError.tooLarge }
            let content = try parseContent(payload)
            guard !content.text.isEmpty else { continue }
            // Export cue numbers can change. Content identity survives renumbering
            // and unrelated insertions; an occurrence suffix retains duplicates.
            let identity = [String(start), String(end), content.speaker ?? "", content.text]
                .map { "\($0.utf8.count):\($0)" }.joined()
            let digest = Data(SHA256.hash(data: Data(identity.utf8))).zoomBase64URL
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            cues.append(.init(id: "transcript-\(digest)-\(occurrence)", start: start, end: end,
                              speaker: content.speaker, text: content.text))
        }
        return cues
    }

    private static let metadataPattern = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9_-]*[=:]"#)

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func parseTiming(_ line: String) throws -> (TimeInterval, TimeInterval) {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 3, tokens[1] == "-->",
              tokens.dropFirst(3).allSatisfy({ $0.contains(":") && !$0.contains("-->") }) else {
            throw ZoomRecordingTranscriptError.invalidFormat
        }
        let start = try parseTimestamp(String(tokens[0]))
        let end = try parseTimestamp(String(tokens[2]))
        guard end > start else { throw ZoomRecordingTranscriptError.invalidTimestamp }
        return (start, end)
    }

    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^(?:([0-9]{2,}):)?([0-9]{2}):([0-9]{2})\.([0-9]{3})$"#)

    private static func parseTimestamp(_ text: String) throws -> TimeInterval {
        let value = text as NSString
        guard let match = timestampPattern.firstMatch(in: text, range: NSRange(location: 0, length: value.length)),
              let minutes = Int(value.substring(with: match.range(at: 2))), minutes < 60,
              let seconds = Int(value.substring(with: match.range(at: 3))), seconds < 60,
              let milliseconds = Int(value.substring(with: match.range(at: 4))) else {
            throw ZoomRecordingTranscriptError.invalidTimestamp
        }
        let hoursRange = match.range(at: 1)
        let hours: Double? = hoursRange.location == NSNotFound ? 0 : Double(value.substring(with: hoursRange))
        guard let hours, hours.isFinite, hours <= maximumTimestamp / 3_600 else {
            throw ZoomRecordingTranscriptError.invalidTimestamp
        }
        let result = hours * 3_600 + Double(minutes * 60 + seconds) + Double(milliseconds) / 1_000
        guard result <= maximumTimestamp else { throw ZoomRecordingTranscriptError.invalidTimestamp }
        return result
    }

    private static let voicePattern = try! NSRegularExpression(pattern: #"^v(?:\.[^\s>]+)*[\t ]+(.+)$"#)
    private static let markupPattern = try! NSRegularExpression(pattern: #"<(/?[A-Za-z][^<>\n]*|[0-9]{2,}:[0-9:.]+)>"#)
    private static let speakerPattern = try! NSRegularExpression(pattern: #"^([^:\n]{1,120}):[\t ]+([\s\S]*)$"#)
    private static let entityPattern = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#)
    private static let namedEntities = ["amp": "&", "lt": "<", "gt": ">", "nbsp": "\u{00A0}",
                                       "lrm": "\u{200E}", "rlm": "\u{200F}", "quot": "\"", "apos": "'"]

    private static func parseContent(_ payload: String) throws -> (speaker: String?, text: String) {
        let source = payload as NSString
        let tags = markupPattern.matches(in: payload, range: NSRange(location: 0, length: source.length))
        var voices: [Int: String] = [:]
        for (ordinal, tag) in tags.enumerated() {
            if ordinal.isMultiple(of: 256) { try Task.checkCancellation() }
            let tagText = source.substring(with: tag.range(at: 1))
            let value = tagText as NSString
            if let voice = voicePattern.firstMatch(in: tagText, range: NSRange(location: 0, length: value.length)) {
                let name = try decodeEntities(value.substring(with: voice.range(at: 1)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { voices[tag.range.location] = name }
            }
        }
        let uniqueVoices = Set(voices.values)
        var speaker = uniqueVoices.count == 1 ? uniqueVoices.first : nil
        var body = ""
        var cursor = 0
        for (ordinal, tag) in tags.enumerated() {
            if ordinal.isMultiple(of: 256) { try Task.checkCancellation() }
            body += try decodeEntities(source.substring(with: NSRange(location: cursor, length: tag.range.location - cursor)))
            if let name = voices[tag.range.location], uniqueVoices.count > 1 {
                // One cue can contain several voices. Keep their attribution in
                // the text instead of assigning every line to the first speaker.
                if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
                body += name + ": "
            } else if source.substring(with: tag.range(at: 1)).lowercased() == "br" {
                body += "\n"
            }
            cursor = tag.range.location + tag.range.length
        }
        body += try decodeEntities(source.substring(from: cursor))
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = body as NSString
        if uniqueVoices.count <= 1,
           let match = speakerPattern.firstMatch(in: body, range: NSRange(location: 0, length: value.length)) {
            let prefix = value.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty, speaker == nil || speaker == prefix {
                speaker = prefix
                body = value.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (speaker, body)
    }

    private static func decodeEntities(_ text: String) throws -> String {
        try Task.checkCancellation()
        let source = text as NSString
        let matches = entityPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        let result = NSMutableString(string: text)
        for (ordinal, match) in matches.reversed().enumerated() {
            if ordinal.isMultiple(of: 256) { try Task.checkCancellation() }
            let entity = source.substring(with: match.range(at: 1))
            var replacement = namedEntities[entity]
            if entity.hasPrefix("#") {
                let isHex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                if let number = UInt32(entity.dropFirst(isHex ? 2 : 1), radix: isHex ? 16 : 10),
                   let scalar = UnicodeScalar(number), number >= 0x20 || number == 9 || number == 10 {
                    replacement = String(scalar)
                }
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}
