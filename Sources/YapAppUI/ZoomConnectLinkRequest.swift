import Foundation

/// A landing-page request must not outlive a newer account action while Keychain is read.
@MainActor
struct ZoomConnectLinkRequest {
    private let accountRevision: UUID

    init(connection: ZoomConnectionModel) {
        accountRevision = connection.accountRevision
    }

    func perform(on model: YapModel) async {
        guard isCurrent(in: model) else { return }
        let connection = model.zoomConnection
        await connection.loadStatus()
        // loadStatus can discard its result after disconnect, another account
        // operation, or a newer status check. Unknown status is not signed out.
        guard isCurrent(in: model), connection.hasLoadedStatus,
              !connection.isLoadingStatus, connection.statusError == nil,
              connection.isConfigured, !connection.hasSavedConnection else { return }
        await connection.connect()
        if let error = connection.error { model.error = error }
    }

    private func isCurrent(in model: YapModel) -> Bool {
        !Task.isCancelled && !model.isPreview && !model.activeCall
            && !model.zoomConnection.isBusy
            && model.zoomConnection.accountRevision == accountRevision
    }
}
