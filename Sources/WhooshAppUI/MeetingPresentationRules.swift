import Foundation
import WhooshMeetings

enum MeetingPresentationRules {
    /// Preference and observed outbound resolution are independent facts.
    static func videoQualityDescription(_ quality: MeetingVideoQuality?) -> String {
        guard let quality else { return "Video quality is available when the camera is on." }
        var parts = [quality.requestsHD ? "HD preferred" : "HD is not enabled"]
        if let width = quality.sendWidth, let height = quality.sendHeight, width > 0, height > 0 {
            var sending = "Sending \(width) × \(height)"
            if let fps = quality.sendFPS, fps > 0 { sending += " at \(fps) fps" }
            parts.append(sending)
        }
        return parts.joined(separator: " · ")
    }

    /// Copy only a link actually supplied for the current live call. A request
    /// URL, a preview URL, or a stale disconnected session is never an invitation.
    static func invitationToCopy(_ url: URL?, isConnected: Bool, isDemo: Bool) -> URL? {
        guard isConnected, !isDemo, let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              host == "zoom.us" || host.hasSuffix(".zoom.us") else { return nil }
        return url
    }
}

extension ShareTarget {
    /// Window and display identifiers are separate operating-system namespaces.
    var pickerID: String { kind.rawValue + ":" + id }
}

/// A source selection belongs to one enumeration in one meeting. Keeping this
/// value separate prevents an old sheet from sharing a source in a later call.
struct MeetingShareSourceSnapshot {
    let sessionID: UUID
    let targets: [ShareTarget]

    init(sessionID: UUID, targets: [ShareTarget], isDemo: Bool) {
        self.sessionID = sessionID
        var seen: Set<String> = []
        self.targets = targets.filter {
            !$0.id.isEmpty && (isDemo ? $0.kind == .demo : $0.kind != .demo) && seen.insert($0.pickerID).inserted
        }.sorted {
            if $0.kind != $1.kind { return $0.kind == .display }
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    /// The grid's display wording never replaces the actual SDK source title.
    /// Selection and transmission continue to resolve through the original IDs.
    var presentationTargets: [ShareTarget] {
        let displayCount = targets.filter { $0.kind == .display }.count
        var displayNumber = 0
        return targets.map { target in
            guard target.kind == .display else { return target }
            displayNumber += 1
            let name = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = displayCount == 1 ? "Full display" : "Full display · \(name.isEmpty ? "Display \(displayNumber)" : name)"
            return ShareTarget(id: target.id, title: title, kind: target.kind)
        }
    }

    func target(for pickerID: String?, currentSessionID: UUID?) -> ShareTarget? {
        guard sessionID == currentSessionID, let pickerID else { return nil }
        return targets.first { $0.pickerID == pickerID }
    }
}
