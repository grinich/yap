import SwiftUI
import YapMeetings

struct RoomSharingView: View {
    @Bindable var model: YapModel
    @State private var code = ""
    @State private var showsChooser = false

    private var stage: RoomShareStage? { model.meeting.roomShareStage }
    private var needsCode: Bool { stage == .needsCode || stage == .invalidCode }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: stage == .sharing ? "checkmark.rectangle" : "rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light)).foregroundStyle(YapTheme.accent)
            VStack(spacing: 8) {
                Text(title).font(.system(size: 24, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if model.meeting.status == .leaving || stage == .searching {
                ProgressView().controlSize(.small)
            } else if needsCode {
                VStack(spacing: 10) {
                    TextField("Sharing key or meeting ID", text: $code)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .accessibilityLabel("Room sharing key or meeting ID")
                        .onSubmit(submitCode)
                    Button("Connect to room", action: submitCode)
                        .buttonStyle(.borderedProminent).disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.frame(maxWidth: 300)
            } else if stage == .choosingContent {
                Button("Choose what to share") { showsChooser = true }
                    .buttonStyle(.borderedProminent)
            }
            Button(stage == .sharing ? "Stop sharing" : "Cancel") {
                Task { await model.leaveMeeting() }
            }
            .disabled(model.meeting.status == .leaving)
            .buttonStyle(.bordered)
        }
        .padding(32).frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YapWindowInteractionRegion())
        .sheet(isPresented: $showsChooser) { MeetingShareChooser(meeting: model.meeting) }
        .onChange(of: stage, initial: true) { _, stage in
            showsChooser = stage == .choosingContent
        }
    }

    private var title: String {
        if model.meeting.status == .leaving { return "Stopping room sharing…" }
        switch stage {
        case .sharing: return "Sharing to the room"
        case .choosingContent: return "Room connected"
        case .needsCode, .invalidCode: return "Connect to a Zoom Room"
        default: return "Finding a nearby Zoom Room…"
        }
    }

    private var detail: String {
        if model.meeting.status == .leaving { return "Waiting for Zoom to disconnect." }
        switch stage {
        case .sharing: return "Your selected content is visible in the room. Your meeting camera and microphone are off."
        case .choosingContent: return "Choose a window or display. Nothing is shared until you select Share."
        case .invalidCode: return "That code didn’t work. Check the sharing key on the room display and try again."
        case .needsCode: return "Enter the sharing key or meeting ID shown on the room display."
        default: return "Yap uses your microphone to detect the room’s proximity signal. Make sure your Mac and the room are on the same network."
        }
    }

    private func submitCode() { Task { await model.meeting.submitRoomSharingCode(code) } }
}
