import Foundation
import YapMeetings

enum MeetingChatArchive {
    static func matches(_ message: MeetingChatMessage, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || [message.senderName, message.recipient.label, message.text]
            .joined(separator: " ").localizedStandardContains(needle)
    }

    static func text(messages: [MeetingChatMessage], attachments: [MeetingChatAttachment], title: String) -> String {
        let format = ISO8601DateFormatter()
        let messageEntries = messages.map { message in
            (message.date, "[\(format.string(from: message.date))] \(message.isFromSelf ? "You" : message.senderName) → \(message.recipient.label)\(message.isReply ? " (thread reply)" : "")\n\(message.text)")
        }
        let fileEntries = attachments.map { file in
            (file.date, "[\(format.string(from: file.date))] \(file.senderName) → \(file.recipient.label)\nAttachment: \(file.name) (\(file.bytes) bytes, \(file.status.rawValue))")
        }
        return "\(title.isEmpty ? "Meeting" : title) — Chat\nMessages available in Yap at export time.\n\n" +
            (messageEntries + fileEntries).sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n") + "\n"
    }

    static func safeFileName(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
        return name.isEmpty || name == "." || name == ".." ? "Attachment" : name
    }
}

enum MeetingChatEntry: Identifiable {
    case thread(MeetingChatThread)
    case attachment(MeetingChatAttachment)
    var id: String {
        switch self {
        case .thread(let thread): "message:\(thread.id)"
        case .attachment(let file): "file:\(file.id)"
        }
    }
    var date: Date {
        switch self {
        case .thread(let thread): thread.root.date
        case .attachment(let file): file.date
        }
    }
}
