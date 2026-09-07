import SwiftUI
import YapMeetings

enum MeetingCloudRecordingAction: String, CaseIterable {
    case start, pause, resume, stop
    var title: String {
        switch self {
        case .start: "Record to Cloud"
        case .pause: "Pause Cloud Recording"
        case .resume: "Resume Cloud Recording"
        case .stop: "Stop Cloud Recording"
        }
    }
    var symbol: String {
        switch self {
        case .start: "record.circle"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .stop: "stop.fill"
        }
    }
}

struct MeetingCloudRecordingControlsState {
    let recording: MeetingCloudRecording
    let isConnected: Bool
    let isBusy: Bool

    var statusLabel: String? {
        switch recording.status {
        case .unavailable, .stopped: nil
        case .connecting: "Starting cloud recording…"
        case .recording: "Recording to Cloud"
        case .paused: "Cloud Recording Paused"
        }
    }
    var progressDescription: String? {
        if recording.status == .connecting { return "Starting cloud recording…" }
        guard isBusy else { return nil }
        return recording.status.isActive ? "Updating cloud recording…" : "Requesting cloud recording…"
    }
    // Compact controls must distinguish a paused recording without relying on text.
    var controlSymbol: String {
        switch recording.status {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        default: "record.circle"
        }
    }
    var actions: [MeetingCloudRecordingAction] {
        switch recording.status {
        case .unavailable, .stopped: [.start]
        case .connecting: []
        case .recording: [.pause, .stop]
        case .paused: [.resume, .stop]
        }
    }
    var disabledReason: String? {
        if !isConnected { return "Cloud recording controls are available after you join the meeting." }
        if recording.status == .connecting || isBusy { return "Waiting for Zoom to update cloud recording." }
        if !recording.canControl || recording.status == .unavailable {
            return recording.unavailableReason ?? "Cloud recording is unavailable for this meeting."
        }
        return nil
    }
    func canPerform(_ action: MeetingCloudRecordingAction) -> Bool {
        disabledReason == nil && actions.contains(action)
    }

    @MainActor init(meeting: MeetingCoordinator) {
        self.init(recording: meeting.cloudRecording, isConnected: meeting.isConnected,
                  isBusy: meeting.isApplyingCloudRecordingControl)
    }
    init(recording: MeetingCloudRecording, isConnected: Bool, isBusy: Bool) {
        self.recording = recording
        self.isConnected = isConnected
        self.isBusy = isBusy
    }
}

@MainActor
enum MeetingCloudRecordingRouting {
    static func perform(_ action: MeetingCloudRecordingAction, sessionID: UUID?, in meeting: MeetingCoordinator) async {
        guard !Task.isCancelled, let sessionID, meeting.sessionID == sessionID,
              MeetingCloudRecordingControlsState(meeting: meeting).canPerform(action) else { return }
        switch action {
        case .start: await meeting.startCloudRecording()
        case .pause: await meeting.pauseCloudRecording()
        case .resume: await meeting.resumeCloudRecording()
        case .stop: await meeting.stopCloudRecording()
        }
    }
}

struct MeetingCloudRecordingMenuItems: View {
    var meeting: MeetingCoordinator
    var body: some View {
        let state = MeetingCloudRecordingControlsState(meeting: meeting)
        let sessionID = meeting.sessionID
        if state.recording.status == .connecting {
            Text("Starting cloud recording…")
        }
        ForEach(state.actions, id: \.self) { action in
            Button(action.title, systemImage: action.symbol) {
                Task { await MeetingCloudRecordingRouting.perform(action, sessionID: sessionID, in: meeting) }
            }
            .disabled(!state.canPerform(action))
            .help(state.disabledReason ?? action.title)
            .accessibilityHint(state.disabledReason ?? "")
        }
    }
}

struct MeetingCloudRecordingCallControl: View {
    var meeting: MeetingCoordinator
    var iconOnly: Bool
    var body: some View {
        let state = MeetingCloudRecordingControlsState(meeting: meeting)
        let sessionID = meeting.sessionID
        if let progress = state.progressDescription, !state.recording.status.isActive {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                if !iconOnly {
                    Text(state.recording.status == .connecting ? "Starting…" : "Requesting…")
                }
            }
            .frame(minWidth: iconOnly ? 24 : 0, minHeight: 22)
            .padding(8)
            .foregroundStyle(.secondary)
            .help(progress)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progress)
        } else if state.recording.status.isActive {
            Menu {
                MeetingCloudRecordingMenuItems(meeting: meeting)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.controlSymbol)
                        .foregroundStyle(.red).accessibilityHidden(true)
                    if !iconOnly {
                        Text(state.recording.status == .paused ? "Paused" : "Recording")
                    }
                    if state.progressDescription != nil {
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                    }
                }
                .frame(minWidth: iconOnly ? 24 : 0, minHeight: 22)
                .padding(8)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
            .controlSize(.large)
            .tint(nil as Color?).foregroundStyle(.primary)
            .yapIconHover(cornerRadius: 12)
            .disabled(state.isBusy)
            .help(state.disabledReason ?? state.statusLabel ?? "Cloud recording controls")
            .accessibilityLabel(state.statusLabel ?? "Cloud recording")
            .accessibilityValue(state.progressDescription ?? "")
        } else {
            Button {
                Task { await MeetingCloudRecordingRouting.perform(.start, sessionID: sessionID, in: meeting) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.controlSymbol)
                    if !iconOnly { Text("Record") }
                }
                .frame(minWidth: iconOnly ? 24 : 0, minHeight: 22)
                .padding(8)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.borderless).controlSize(.large)
            .tint(nil as Color?).foregroundStyle(.primary)
            .yapIconHover(cornerRadius: 12)
            .disabled(!state.canPerform(.start))
            .help(state.disabledReason ?? "Record to Cloud")
            .accessibilityLabel("Record to Cloud")
            .accessibilityHint(state.disabledReason ?? "")
        }
    }
}
