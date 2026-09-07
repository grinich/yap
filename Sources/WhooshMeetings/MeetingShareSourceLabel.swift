import Foundation

/// Source labels come from SDK-confirmed identifiers. An accepted switch request
/// alone cannot establish that the SDK is already transmitting the selected item.
enum MeetingShareSourceLabel {
    static func target(windowID: UInt32, displayID: UInt32, available: [ShareTarget]) -> ShareTarget {
        guard windowID != 0 || displayID != 0 else {
            return ShareTarget(id: "current-shared-content", title: "Shared screen", kind: .window)
        }
        let kind: ShareTarget.Kind = windowID != 0 ? .window : .display
        let sourceID = String(windowID != 0 ? windowID : displayID)
        return available.first { $0.id == sourceID && $0.kind == kind }
            ?? ShareTarget(id: sourceID, title: kind == .window ? "Shared window" : "Shared display", kind: kind)
    }
}
