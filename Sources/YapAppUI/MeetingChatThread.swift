import Foundation
import YapMeetings

struct MeetingChatThread: Identifiable {
    var id: UUID { root.id }
    let root: MeetingChatMessage
    let replies: [MeetingChatMessage]

    static func group(_ messages: [MeetingChatMessage]) -> [Self] {
        func scopedKey(_ message: MeetingChatMessage, key: String?) -> String? {
            key.map { $0 + "|" + (message.replyRecipient?.id ?? "unavailable:\(message.id)") }
        }
        let roots = messages.filter { !$0.isReply }
        let keys = Set(roots.compactMap { scopedKey($0, key: $0.threadID ?? $0.sdkID) })
        var repliesByThread: [String: [MeetingChatMessage]] = [:]
        for message in messages where message.isReply {
            if let key = scopedKey(message, key: message.threadID) { repliesByThread[key, default: []].append(message) }
        }
        return messages.compactMap { message in
            if message.isReply, let thread = scopedKey(message, key: message.threadID), keys.contains(thread) { return nil }
            let key = scopedKey(message, key: message.threadID ?? message.sdkID)
            let replies = !message.isReply ? key.flatMap { repliesByThread[$0] } ?? [] : []
            // A reply whose parent predates the retained history remains visible.
            return Self(root: message, replies: replies)
        }
    }

    struct ScrollTarget: Equatable {
        let messageID: UUID
        let expandedThreadID: UUID?
    }

    /// The latest message may live inside a collapsed thread, far from the bottom.
    static func latestScrollTarget(in messages: [MeetingChatMessage]) -> ScrollTarget? {
        guard let latest = messages.last else { return nil }
        let parent = group(messages).first { $0.replies.contains { $0.id == latest.id } }
        return ScrollTarget(messageID: latest.id, expandedThreadID: parent?.id)
    }
}
