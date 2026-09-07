import AppKit
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Share chooser preview lifetime") @MainActor
struct MeetingSharePreviewProviderTests {
    @Test func closingChooserReleasesImagesAndRejectsLateCapture() async {
        let gate = PreviewCaptureGate()
        let target = window("1")
        let provider = MeetingSharePreviewProvider { _ in [source(target, capture: { await gate.capture() })] }
        provider.start(targets: [target])
        await gate.waitForStart(1)
        provider.clear()
        #expect(provider.previews.isEmpty)
        #expect(!provider.isLoading)
        gate.finishNext()
        await provider.loadingTask?.value
        #expect(provider.previews.isEmpty)
    }

    @Test func refreshSerializesCaptureAndDropsOldGeneration() async {
        let gate = PreviewCaptureGate()
        let first = window("1"), second = window("2")
        let provider = MeetingSharePreviewProvider { targets in
            targets.map { target in source(target, capture: { await gate.capture() }) }
        }
        provider.start(targets: [first])
        await gate.waitForStart(1)
        provider.start(targets: [second])
        await Task.yield()
        #expect(gate.started == 1)
        gate.finishNext()
        await gate.waitForStart(2)
        #expect(provider.previews[first.pickerID] == nil)
        gate.finishNext()
        await provider.loadingTask?.value
        #expect(gate.maximumActive == 1)
        #expect(provider.previews[second.pickerID]?.image != nil)
        #expect(!provider.isLoading)
    }

    @Test func onlyValidRequestedIDsAreCapturedAndNamespacesStaySeparate() async {
        let window = window("7")
        let display = ShareTarget(id: "7", title: "Display", kind: .display)
        let extra = self.window("8")
        var enumerated: [ShareTarget] = []
        var captured: [String] = []
        let provider = MeetingSharePreviewProvider { targets in
            enumerated = targets
            return [window, display, extra, window].map { target in
                source(target, capture: { captured.append(target.pickerID); return image() })
            }
        }
        provider.start(targets: [window, display, window,
            ShareTarget(id: "99", title: "Demo", kind: .demo),
            self.window("invalid"), self.window("0")])
        await provider.loadingTask?.value
        #expect(enumerated == [window, display])
        #expect(captured == ["window:7", "display:7"])
        #expect(Set(provider.previews.keys) == Set(["window:7", "display:7"]))
    }

    @Test func reopeningChooserDoesNotOverlapAnUncancellableScreenshot() async {
        let firstGate = PreviewCaptureGate(), secondGate = PreviewCaptureGate()
        let target = window("1")
        let first = MeetingSharePreviewProvider { _ in [source(target, capture: { await firstGate.capture() })] }
        let second = MeetingSharePreviewProvider { _ in [source(target, capture: { await secondGate.capture() })] }
        first.start(targets: [target])
        await firstGate.waitForStart(1)
        first.clear()
        second.start(targets: [target])
        await Task.yield()
        #expect(secondGate.started == 0)
        firstGate.finishNext()
        await secondGate.waitForStart(1)
        secondGate.finishNext()
        await second.loadingTask?.value
        #expect(first.previews.isEmpty)
        #expect(second.previews[target.pickerID]?.image != nil)
    }

    @Test func captureBudgetAndFailureKeepDescriptiveFallbacks() async {
        let targets = [window("1"), window("2"), window("3")]
        var captures = 0
        let provider = MeetingSharePreviewProvider(maximumImageCount: 2) { _ in
            targets.map { target in source(target, capture: {
                captures += 1
                if target.id == "1" { throw PreviewFailure.closedWindow }
                return image()
            }) }
        }
        provider.start(targets: targets)
        await provider.loadingTask?.value
        #expect(captures == 2)
        #expect(provider.previews["window:1"]?.applicationName == "Test app")
        #expect(provider.previews["window:1"]?.image == nil)
        #expect(provider.previews["window:2"]?.image != nil)
        #expect(provider.previews["window:3"]?.image == nil)
        #expect(provider.previews["window:3"]?.applicationName == "Test app")
    }

    @Test func previewAndEmptySourcesNeverRequestScreenContent() async {
        var loads = 0
        let provider = MeetingSharePreviewProvider { _ in loads += 1; return [] }
        provider.start(targets: [ShareTarget(id: "1", title: "Sample", kind: .demo)])
        await provider.loadingTask?.value
        #expect(loads == 0)
        #expect(!provider.isLoading)
    }

    private func window(_ id: String) -> ShareTarget { ShareTarget(id: id, title: "Window", kind: .window) }
    private func image() -> NSImage { NSImage(size: NSSize(width: 16, height: 16)) }
    private func source(_ target: ShareTarget, capture: @escaping @MainActor () async throws -> NSImage) -> MeetingSharePreviewSource {
        MeetingSharePreviewSource(pickerID: target.pickerID, applicationName: "Test app", applicationIcon: nil, capture: capture)
    }
}

private enum PreviewFailure: Error { case closedWindow }

@MainActor
private final class PreviewCaptureGate {
    private(set) var started = 0
    private(set) var maximumActive = 0
    private var active = 0
    private var captures: [CheckedContinuation<Void, Never>] = []
    private var starts: [(Int, CheckedContinuation<Void, Never>)] = []

    func capture() async -> NSImage {
        started += 1
        active += 1
        maximumActive = max(maximumActive, active)
        let ready = starts.filter { $0.0 <= started }
        starts.removeAll { $0.0 <= started }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { captures.append($0) }
        active -= 1
        return NSImage(size: NSSize(width: 16, height: 16))
    }

    func waitForStart(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { starts.append((count, $0)) }
    }

    func finishNext() { captures.removeFirst().resume() }
}
