import SwiftUI
import YapMeetings

/// Standard application-menu items; device names and checkmarks come from Zoom readback.
struct MeetingMediaMenuItems: View {
    @Bindable var meeting: MeetingCoordinator
    let kind: MeetingMediaKind

    private var state: MeetingMediaState { meeting.mediaDevices }
    private var busy: Bool { meeting.isPreparingMediaDevices || meeting.isApplyingMediaControl }
    private var devices: [MeetingMediaDevice] { state.devices(for: kind) }
    private var selected: String { devices.first(where: \.selected)?.id ?? "" }

    var body: some View {
        let microphoneAction = MeetingMediaTestMenuAction(kind: .microphone, isTesting: state.microphoneTest != "idle")
        let speakerAction = MeetingMediaTestMenuAction(kind: .speaker, isTesting: state.speakerTestRunning)
        Group {
            if state.isReady {
                if devices.isEmpty {
                    Text("No \(kind.rawValue) connected").disabled(true)
                } else {
                    Picker("Choose \(kind.rawValue)", selection: Binding(get: { selected }, set: { id in
                        Task { await meeting.selectMediaDevice(id, kind: kind) }
                    })) {
                        ForEach(devices) { device in Text(device.name).tag(device.id) }
                    }
                    .pickerStyle(.inline)
                    .disabled(busy)
                }
                if kind == .microphone {
                    Divider()
                    Toggle("Automatically adjust microphone volume", isOn: Binding(
                        get: { state.automaticMicrophoneVolume },
                        set: { enabled in Task { await meeting.setAutomaticMicrophoneVolume(enabled) } }))
                        .disabled(busy || devices.isEmpty)
                    volumeMenu(value: state.microphoneVolume, enabled: state.canSetMicrophoneVolume && !state.automaticMicrophoneVolume)
                    Button(microphoneAction.title) {
                        Task { await microphoneAction.perform(on: meeting) }
                    }.disabled(microphoneAction.isStarting && (busy || devices.isEmpty))
                    if state.microphoneTest == "recording" { Text("Recording five seconds…").disabled(true) }
                    if state.microphoneTest == "playing" { Text("Playing your microphone recording…").disabled(true) }
                } else if kind == .speaker {
                    Divider()
                    volumeMenu(value: state.speakerVolume, enabled: state.canSetSpeakerVolume)
                    Button(speakerAction.title) {
                        Task { await speakerAction.perform(on: meeting) }
                    }.disabled(speakerAction.isStarting && (busy || devices.isEmpty))
                }
            }
            if let error = meeting.mediaDevicesError {
                Text(error).disabled(true)
            }
            Divider()
            Button(meeting.isPreparingMediaDevices ? "Loading devices…" : state.isReady ? "Refresh devices" : "Load devices") {
                Task { await meeting.prepareMediaDevices() }
            }.disabled(busy)
        }
        .task { if !state.isReady { await meeting.prepareMediaDevices() } }
    }

    private func volumeMenu(value: Int?, enabled: Bool) -> some View {
        Menu(value.map { "Volume: \($0)%" } ?? "Volume") {
            Button("Increase volume") { Task { await meeting.setMediaVolume(min(100, (value ?? 50) + 10), kind: kind) } }
                .disabled(value == nil || value == 100)
            Button("Decrease volume") { Task { await meeting.setMediaVolume(max(0, (value ?? 50) - 10), kind: kind) } }
                .disabled(value == nil || value == 0)
            Divider()
            Picker("Volume", selection: Binding(get: { value ?? -1 }, set: { volume in
                Task { await meeting.setMediaVolume(volume, kind: kind) }
            })) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { Text("\($0)%").tag($0) }
            }.pickerStyle(.inline)
        }.disabled(!enabled || busy)
    }
}
