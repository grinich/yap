import Testing
@testable import YapAppUI

@Suite("Main window presentation") @MainActor
struct YapMainWindowPresenterTests {
    @Test func waitsForMenuTrackingAndCoalescesRepeatedRequests() {
        let fixture = WindowPresentationFixture()
        fixture.presenter.request()
        fixture.presenter.request()
        #expect(fixture.deferred.count == 1)
        #expect(fixture.openCount == 0)
        #expect(fixture.restoreCount == 0)
        fixture.runDeferred()
        #expect(fixture.openCount == 1)
        #expect(fixture.activations.count == 1)
    }

    @Test func backgroundWindowWaitsForWorkspaceActivationAndThenBecomesKey() {
        let fixture = WindowPresentationFixture()
        fixture.window = .init(isVisible: true, isMiniaturized: false, isKey: false)
        fixture.presenter.request()
        fixture.runDeferred()
        #expect(fixture.presenter.isPending)
        #expect(fixture.activations.count == 1)
        fixture.isActive = true
        fixture.activations[0](true)
        #expect(fixture.window?.isKey == true)
        #expect(!fixture.presenter.isPending)
        #expect(fixture.openCount == 1)
    }

    @Test func hiddenMinimizedWindowIsRestoredWithoutLaunchingAnotherInstance() {
        let fixture = WindowPresentationFixture()
        fixture.isActive = true
        fixture.isHidden = true
        fixture.window = .init(isVisible: false, isMiniaturized: true, isKey: false)
        fixture.presenter.request()
        fixture.runDeferred()
        #expect(!fixture.isHidden)
        #expect(fixture.window?.isVisible == true)
        #expect(fixture.window?.isMiniaturized == false)
        #expect(fixture.window?.isKey == true)
        #expect(fixture.activations.isEmpty)
        #expect(!fixture.presenter.isPending)
    }

    @Test func asynchronousWindowAttachmentCompletesAnAlreadyActivatedRequest() {
        let fixture = WindowPresentationFixture()
        fixture.presenter.request()
        fixture.runDeferred()
        fixture.isActive = true
        fixture.activations[0](true)
        #expect(fixture.presenter.isPending)
        fixture.window = .init(isVisible: false, isMiniaturized: false, isKey: false)
        fixture.presenter.windowOrActivationChanged()
        #expect(!fixture.presenter.isPending)
        #expect(fixture.window?.isKey == true)
        #expect(fixture.openCount == 1)
    }

    @Test func activeApplicationAloneDoesNotFinishUntilTheMainWindowBecomesKey() {
        let fixture = WindowPresentationFixture()
        fixture.isActive = true
        fixture.canBecomeKey = false
        fixture.window = .init(isVisible: true, isMiniaturized: false, isKey: false)
        fixture.presenter.request()
        fixture.runDeferred()
        #expect(fixture.presenter.isPending)
        fixture.canBecomeKey = true
        fixture.presenter.windowOrActivationChanged()
        #expect(!fixture.presenter.isPending)
    }

    @Test func failedActivationCanBeRetriedByAnExplicitClick() {
        let fixture = WindowPresentationFixture()
        fixture.presenter.request()
        fixture.runDeferred()
        fixture.activations[0](false)
        #expect(fixture.presenter.isPending)
        fixture.presenter.request()
        fixture.runDeferred()
        #expect(fixture.activations.count == 2)
        #expect(fixture.openCount == 2)
    }

    @Test func cancelledOrSupersededActivationCannotRestoreAWindowLater() {
        let fixture = WindowPresentationFixture()
        fixture.presenter.request()
        fixture.runDeferred()
        let oldCompletion = fixture.activations[0]
        fixture.presenter.cancel()
        let before = fixture.restoreCount
        oldCompletion(true)
        #expect(fixture.restoreCount == before)
        #expect(!fixture.presenter.isPending)
        fixture.presenter.request()
        oldCompletion(true)
        #expect(fixture.restoreCount == before)
        #expect(fixture.presenter.isPending)
    }
}

@MainActor private final class WindowPresentationFixture {
    var deferred: [@MainActor () -> Void] = []
    var activations: [@MainActor (Bool) -> Void] = []
    var isActive = false
    var isHidden = false
    var canBecomeKey = true
    var window: YapMainWindowState?
    var openCount = 0
    var restoreCount = 0
    lazy var presenter = YapMainWindowPresenter(actions: .init(
        afterMenuTracking: { [unowned self] in deferred.append($0) },
        openWindow: { [unowned self] in openCount += 1 },
        revealApplication: { [unowned self] in isHidden = false },
        applicationIsActive: { [unowned self] in isActive },
        restoreWindow: { [unowned self] in
            restoreCount += 1
            guard window != nil else { return nil }
            window?.isVisible = true
            window?.isMiniaturized = false
            window?.isKey = isActive && canBecomeKey
            return window
        },
        activateApplication: { [unowned self] in activations.append($0) }))

    func runDeferred() {
        let work = deferred
        deferred = []
        for action in work { action() }
    }
}
