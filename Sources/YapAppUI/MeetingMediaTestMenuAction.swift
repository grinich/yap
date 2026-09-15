import YapMeetings

/// NSMenu can keep its displayed item after the underlying test finishes.
/// Capture the command with the label instead of toggling the latest state.
enum MeetingMediaTestMenuAction: Equatable {
    case start(MeetingMediaKind)
    case stop(MeetingMediaKind)

    init(kind: MeetingMediaKind, isTesting: Bool) {
        self = isTesting ? .stop(kind) : .start(kind)
    }

    var isStarting: Bool {
        if case .start = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .start(.microphone): "Test microphone…"
        case .start(let kind): "Test \(kind.rawValue)"
        case .stop(let kind): "Stop \(kind.rawValue) test"
        }
    }

    @MainActor func perform(on meeting: MeetingCoordinator) async {
        switch self {
        case .start(let kind): await meeting.setMediaTest(kind, running: true)
        case .stop: meeting.stopMediaTests()
        }
    }
}
