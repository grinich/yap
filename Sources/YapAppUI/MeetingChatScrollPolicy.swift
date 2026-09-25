import Foundation

struct MeetingChatScrollGeometry: Equatable {
    var contentHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
    var contentWidth: CGFloat = 0
    var viewportWidth: CGFloat = 0
}

/// Content growth alone must not turn a bottom-pinned reader into a history reader.
struct MeetingChatScrollPolicy {
    private(set) var followsLatest = true
    private(set) var hasNewMessages = false
    private var sessionID: UUID?

    mutating func reopen(sessionID: UUID?) {
        self.sessionID = sessionID
        jumpToLatest()
    }

    @discardableResult mutating func synchronize(sessionID: UUID?) -> Bool {
        guard self.sessionID != sessionID else { return false }
        reopen(sessionID: sessionID)
        return true
    }

    mutating func geometryChanged(from old: MeetingChatScrollGeometry, to new: MeetingChatScrollGeometry) {
        let layoutChanged = abs(new.contentHeight - old.contentHeight) > 0.5 ||
            abs(new.contentWidth - old.contentWidth) > 0.5 ||
            abs(new.viewportWidth - old.viewportWidth) > 0.5 ||
            abs((new.visibleMaxY - new.visibleMinY) - (old.visibleMaxY - old.visibleMinY)) > 0.5
        guard !layoutChanged, abs(new.visibleMinY - old.visibleMinY) > 0.5 else { return }
        userScrolled(to: new)
    }

    /// A real scroll gesture wins over simultaneous lazy-row remeasurement.
    mutating func userScrolled(to geometry: MeetingChatScrollGeometry) {
        followsLatest = geometry.contentHeight - geometry.visibleMaxY <= 48
        if followsLatest { hasNewMessages = false }
    }

    mutating func receivedMessage(isFromSelf: Bool, isReply: Bool = false) -> Bool {
        // A reply sent from a historical thread stays with that conversation,
        // and the sender's own message is never marked as unread.
        if isFromSelf && isReply && !followsLatest { return false }
        if followsLatest || isFromSelf {
            jumpToLatest()
            return true
        }
        hasNewMessages = true
        return false
    }

    mutating func jumpToLatest() {
        followsLatest = true
        hasNewMessages = false
    }
}
