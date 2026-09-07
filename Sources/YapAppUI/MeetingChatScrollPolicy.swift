import Foundation

struct MeetingChatScrollGeometry: Equatable {
    var contentHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
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
        let viewportUnchanged = abs(new.visibleMinY - old.visibleMinY) < 0.5 &&
            abs(new.visibleMaxY - old.visibleMaxY) < 0.5
        if new.contentHeight > old.contentHeight && viewportUnchanged { return }
        followsLatest = new.contentHeight - new.visibleMaxY <= 48
        if followsLatest { hasNewMessages = false }
    }

    mutating func receivedMessage(isFromSelf: Bool) -> Bool {
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
