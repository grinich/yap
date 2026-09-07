import Foundation

struct WhooshMainWindowState {
    var isVisible: Bool
    var isMiniaturized: Bool
    var isKey: Bool
}

/// Waits for menu tracking, window attachment and activation independently.
@MainActor
final class WhooshMainWindowPresenter {
    struct Actions {
        var afterMenuTracking: (@escaping @MainActor () -> Void) -> Void
        var openWindow: () -> Void
        var revealApplication: () -> Void
        var applicationIsActive: () -> Bool
        var restoreWindow: () -> WhooshMainWindowState?
        var activateApplication: (@escaping @MainActor (Bool) -> Void) -> Void
    }

    private let actions: Actions
    private var generation = 0
    private var isDeferred = false
    private var isActivating = false
    private var isRestoring = false
    private(set) var isPending = false

    init(actions: Actions) { self.actions = actions }

    func request() {
        guard !isPending || (!isDeferred && !isActivating) else { return }
        generation += 1
        let request = generation
        isPending = true
        isDeferred = true
        actions.afterMenuTracking { [weak self] in
            guard let self, self.generation == request, self.isPending else { return }
            self.isDeferred = false
            self.actions.revealApplication()
            self.actions.openWindow()
            self.windowOrActivationChanged()
            guard self.isPending, !self.actions.applicationIsActive() else { return }
            self.isActivating = true
            self.actions.activateApplication { [weak self] succeeded in
                guard let self, self.generation == request else { return }
                self.isActivating = false
                guard self.isPending, succeeded else { return }
                self.actions.revealApplication()
                self.windowOrActivationChanged()
            }
        }
    }

    func windowOrActivationChanged() {
        guard isPending, !isDeferred, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        guard let window = actions.restoreWindow() else { return }
        if actions.applicationIsActive(), window.isVisible, !window.isMiniaturized, window.isKey {
            isPending = false
        }
    }

    func cancel() {
        generation += 1
        isPending = false
        isDeferred = false
        isActivating = false
    }
}
