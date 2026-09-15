import Foundation
import OSLog

enum MeetingMediaSnapshotDecoder {
    static let unavailableMessage = "Yap couldn’t read the device settings from Zoom. Refresh the device list and try again."
    private static let logger = Logger(subsystem: "app.yap.zoom", category: "media-devices")

    static func decode(_ data: Data) throws -> MeetingMediaState {
        do { return try JSONDecoder().decode(MeetingMediaState.self, from: data) }
        catch {
            // Never log JSON, device names/identifiers, or decoder descriptions.
            logger.error("Device snapshot rejected: \(diagnostic(for: error), privacy: .public)")
            throw MeetingError.unavailable(unavailableMessage)
        }
    }

    static func diagnostic(for error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(let type, let context):
            return "typeMismatch expected=\(String(reflecting: type)) path=\(path(context.codingPath))"
        case DecodingError.valueNotFound(let type, let context):
            return "valueNotFound expected=\(String(reflecting: type)) path=\(path(context.codingPath))"
        case DecodingError.keyNotFound(let key, let context):
            return "keyNotFound path=\(path(context.codingPath + [key]))"
        case DecodingError.dataCorrupted(let context):
            return "dataCorrupted path=\(path(context.codingPath))"
        default:
            return "errorType=\(String(reflecting: type(of: error))) path=$"
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        let fields: Set<String> = ["isReady", "isInMeeting", "microphones", "speakers", "cameras",
            "microphoneVolume", "speakerVolume", "automaticMicrophoneVolume", "canSetMicrophoneVolume",
            "canSetSpeakerVolume", "microphoneTest", "speakerTestRunning", "error", "id", "name", "selected"]
        return keys.reduce("$") { result, key in
            if let index = key.intValue { return result + "[\(index)]" }
            return result + "." + (fields.contains(key.stringValue) ? key.stringValue : "field")
        }
    }
}
