import AppKit
import SwiftUI

/// These controls only exist in the explicitly selected interface preview.
/// They exercise the production views using local events, never a Zoom call.
public struct YapPreviewCommands: Commands {
    let model: YapModel
    public init(model: YapModel) { self.model = model }

    public var body: some Commands {
        if model.isPreview {
            CommandMenu("Preview") {
                Text("Local interface preview")
                Divider()
                Button("Start preview call") { Task { await model.hostMeeting() } }
                    .disabled(model.activeCall)
                Menu("People") {
                    ForEach([1, 2, 6, 25, 100], id: \.self) { count in
                        Button("\(count) \(count == 1 ? "person" : "people")") { model.setPreviewPeople(count) }
                    }
                }
                Divider()
                Button("Receive chat message") { model.meeting.demoDriver?.receiveFixtureMessage() }
                    .disabled(!model.meeting.isConnected)
                Button("Receive chat thread") { model.meeting.demoDriver?.receiveFixtureThread() }
                    .disabled(!model.meeting.isConnected)
                Button("Receive private message") { model.meeting.demoDriver?.receiveFixturePrivateMessage() }
                    .disabled(!model.meeting.isConnected)
                Button("Receive formatted message") { model.meeting.demoDriver?.receiveFixtureFormatting() }
                    .disabled(!model.meeting.isConnected)
                Button("Receive waiting-room message") { model.meeting.demoDriver?.receiveFixtureWaitingRoomMessage() }
                    .disabled(!model.meeting.isConnected)
                Button("Receive file") { model.meeting.demoDriver?.receiveFixtureAttachment() }
                    .disabled(!model.meeting.isConnected)
                Menu("Chat permissions") {
                    Button("Disable chat") { model.meeting.demoDriver?.setFixtureChatEnabled(false) }
                    Button("Allow chat") { model.meeting.demoDriver?.setFixtureChatEnabled(true) }
                }.disabled(!model.meeting.isConnected)
                Divider()
                Button("Reject next action") { model.meeting.demoDriver?.rejectNextControl = true }
                Button("Disconnect preview USB devices") { model.meeting.demoDriver?.simulateFixtureDeviceDisconnect() }
                Divider()
                Button("End preview call") { Task { await model.leaveMeeting() } }
                    .disabled(!model.activeCall)
            }
        }
    }
}
