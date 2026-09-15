import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor @Observable
final class ScreenSharingAccess {
    enum State: Equatable { case needsAccess, checking, ready, unavailable }
    private(set) var state: State = .needsAccess
    private(set) var requested = false
    private let preflight: () -> Bool
    private let request: () -> Void
    private let probe: () async throws -> Void

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping () -> Void = { _ = CGRequestScreenCaptureAccess() },
         probe: @escaping () async throws -> Void = {
             _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
         }) {
        self.preflight = preflight; self.request = request; self.probe = probe
    }

    func check(ask: Bool = false) async {
        guard state != .checking else { return }
        state = .checking
        if ask && !requested { requested = true; request() }
        guard requested || preflight() else { state = .needsAccess; return }
        do {
            try await probe()
            state = .ready
        } catch {
            state = preflight() ? .unavailable : .needsAccess
        }
    }

    func prepareForSettings() { requested = true }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct ScreenSharingSetupView: View {
    @State private var access = ScreenSharingAccess()
    let complete: () -> Void

    init(access: ScreenSharingAccess = ScreenSharingAccess(), complete: @escaping () -> Void) {
        _access = State(initialValue: access)
        self.complete = complete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: access.state == .ready ? "checkmark.circle.fill" : "rectangle.on.rectangle")
                .font(.system(size: 36)).foregroundStyle(.tint)
            Text(access.state == .ready ? "You’re ready to share" : "Get ready to share your screen")
                .font(.title2.bold())
            Text("Allow screen and system audio access now, so you’re ready when a meeting starts. Nothing is shared until you choose content and click Share.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if access.state == .checking {
                ProgressView("Checking screen access…").controlSize(.small)
            } else if access.state == .unavailable {
                Text("Screen access is enabled, but macOS hasn’t made it available to Yap yet. Try again. If it still doesn’t work, reopen Yap before your next meeting.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if access.state != .ready {
                Text("In System Settings → Privacy & Security → Screen & System Audio Recording, turn on Yap. We’ll check again when you return.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if access.state != .ready {
                    Button("Set up later", action: complete)
                    Spacer()
                    if access.requested || access.state == .unavailable {
                        Button("Check again") { Task { await access.check() } }
                            .disabled(access.state == .checking)
                        Button("Open System Settings…") {
                            access.prepareForSettings(); ScreenSharingAccess.openSettings()
                        }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Enable screen sharing") { Task { await access.check(ask: true) } }
                            .buttonStyle(.borderedProminent).disabled(access.state == .checking)
                    }
                } else {
                    Spacer()
                    Button("Continue", action: complete).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28).frame(width: 500)
        .task { await access.check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await access.check() }
        }
        .interactiveDismissDisabled()
    }
}
