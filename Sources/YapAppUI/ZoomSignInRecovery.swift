import SwiftUI
import YapMeetings

/// Error surfaces currently retain localized text. Match the account client's
/// known authentication errors rather than treating every Zoom failure as logout.
enum ZoomSignInError {
    static func matches(_ message: String?) -> Bool {
        guard let message else { return false }
        let errors: [ZoomAccountError] = [
            .notConnected, .signingDenied, .authorizationDenied, .authorizationTimedOut,
            .invalidCallback, .localCallbackUnavailable, .missingScope,
            .missingHostingScope, .missingRecordingScope, .rejected(401)
        ]
        return errors.contains { $0.localizedDescription == message }
            || message == "Zoom’s app authentication expired. Reconnect before your next meeting."
    }
}

/// Shared by the library and its detached players without retaining the app.
@MainActor final class ZoomSignInRecovery {
    private weak var model: YapModel?
    init(model: YapModel) { self.model = model }

    var isConnecting: Bool { model?.zoomConnection.isConnecting == true }
    var isEnabled: Bool {
        guard let model else { return false }
        return !model.activeCall && !model.isPreview && !model.zoomConnection.isBusy
    }

    func signIn() async {
        guard isEnabled, let model else { return }
        model.error = nil
        model.meeting.dismissError()
        await model.zoomConnection.connect()
        if let error = model.zoomConnection.error { model.error = error }
    }
}

struct ZoomSignInButton: View {
    let error: String
    let recovery: ZoomSignInRecovery?

    var body: some View {
        if ZoomSignInError.matches(error), let recovery {
            Button(recovery.isConnecting ? "Signing in…" : "Sign in to Zoom") {
                Task { await recovery.signIn() }
            }
            .disabled(!recovery.isEnabled)
            .help("Sign in to reconnect your Zoom account")
        }
    }
}
