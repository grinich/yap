import SwiftUI
import AppKit
import WhooshMeetings

struct MeetingShareChooser: View {
    @Bindable var meeting: MeetingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MeetingShareSourceSnapshot?
    @State private var selectedID: String?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var localError: String?
    @State private var permissionRequired = false
    @State private var refreshID = UUID()
    @State private var previews = MeetingSharePreviewProvider()

    private var selectedTarget: ShareTarget? { snapshot?.target(for: selectedID, currentSessionID: meeting.sessionID) }
    private var visibleSources: [ShareTarget] { snapshot?.presentationTargets ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(meeting.isDemo ? "Preview sharing" : "Share screen").font(.headline)
                Spacer()
                if !meeting.isDemo {
                    Button("Refresh windows and displays", systemImage: "arrow.clockwise") { refreshID = UUID() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Refresh windows and displays")
                        .disabled(isLoading || isSubmitting || !meeting.isConnected)
                }
            }
            sourceGrid.frame(height: 316)
            Divider()
            if let localError, !visibleSources.isEmpty, !permissionRequired {
                Text(localError).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if localError == nil, selectedTarget?.kind == .display {
                Label("Everything on this display will be visible.", systemImage: "display")
                    .font(.callout).foregroundStyle(.secondary)
            } else if localError == nil {
                Text(meeting.sharing.isSharing ? "Your current share continues until you select Share." : meeting.isDemo ? "Sample controls stay on this Mac. Nothing is broadcast." : "Choose a window or display, then select Share.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if isSubmitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSubmitting)
                Button(meeting.isDemo ? "Preview share" : meeting.sharing.isSharing ? "Switch share" : "Share", action: share)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedTarget == nil || permissionRequired || isLoading || isSubmitting || meeting.isApplyingControl || !meeting.isConnected)
            }
        }
        .padding(20).frame(width: 620)
        .task(id: refreshID) { await loadSources() }
        .onChange(of: meeting.sessionID) { _, _ in dismiss() }
        .onDisappear { previews.clear() }
        .interactiveDismissDisabled(isSubmitting)
    }

    @ViewBuilder private var sourceGrid: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Finding windows and displays…").font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if permissionRequired {
            VStack(spacing: 12) {
                Image(systemName: "lock.rectangle").font(.title2).foregroundStyle(.secondary)
                Text("Screen access required").font(.headline)
                Text(localError ?? MeetingError.screenCapturePermissionRequired.localizedDescription)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                HStack {
                    Button("Open System Settings…") {
                        NSWorkspace.shared.open(URL(filePath: "/System/Applications/System Settings.app"))
                    }
                    Button("Try again") { refreshID = UUID() }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !visibleSources.isEmpty {
            MeetingSharePreviewGrid(sources: visibleSources, previews: previews.previews,
                previewsLoading: previews.isLoading, isEnabled: !isSubmitting, selectedID: $selectedID)
        } else if let localError {
            VStack(spacing: 12) {
                Text("Couldn’t load sharing sources").font(.headline)
                Text(localError).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                Button("Try again") { refreshID = UUID() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No windows or displays available",
                systemImage: "macwindow",
                description: Text("Open the content you want to share, then refresh."))
        }
    }

    private func loadSources() async {
        guard let sessionID = meeting.sessionID, meeting.isConnected else { dismiss(); return }
        isLoading = true
        localError = nil
        permissionRequired = false
        previews.clear()
        let targets: [ShareTarget]
        if meeting.isDemo {
            targets = [ShareTarget(id: "sample-presentation", title: "Sample presentation", kind: .demo),
                       ShareTarget(id: "sample-document", title: "Sample document", kind: .demo)]
        } else {
            guard meeting.capabilities.canShare, meeting.capabilities.canEnumerateShareTargets else {
                localError = "Window sharing isn’t available in this meeting."
                isLoading = false
                return
            }
            do { targets = try await meeting.availableShareTargetsForChooser() }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, sessionID == meeting.sessionID, meeting.isConnected else { return }
                localError = error.localizedDescription
                permissionRequired = (error as? MeetingError) == .screenCapturePermissionRequired
                snapshot = nil
                selectedID = nil
                isLoading = false
                return
            }
        }
        guard !Task.isCancelled, sessionID == meeting.sessionID else { return }
        snapshot = MeetingShareSourceSnapshot(sessionID: sessionID, targets: targets, isDemo: meeting.isDemo)
        if !meeting.isDemo, let snapshot {
            previews.start(targets: snapshot.targets)
        }
        if selectedTarget == nil { selectedID = nil }
        isLoading = false
    }

    private func share() {
        guard !isSubmitting, !isLoading, meeting.isConnected, !meeting.isApplyingControl,
              let target = selectedTarget, let sessionID = meeting.sessionID else { return }
        isSubmitting = true
        localError = nil
        permissionRequired = false
        Task {
            defer { if sessionID == meeting.sessionID { isSubmitting = false } }
            do {
                try await meeting.startShareFromChooser(target)
                guard sessionID == meeting.sessionID, meeting.isConnected else { return }
                dismiss()
            } catch is CancellationError {
            } catch {
                guard sessionID == meeting.sessionID, meeting.isConnected else { return }
                localError = error.localizedDescription
                permissionRequired = (error as? MeetingError) == .screenCapturePermissionRequired
            }
            // Only the driver's sharing callback displays the persistent banner.
        }
    }
}
