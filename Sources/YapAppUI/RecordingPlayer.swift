import AVFoundation
import Foundation

/// AVPlayer may deliver a late rate change after Pause during initial preroll.
/// Keep explicit transport commands separate from its asynchronous rate state.
final class RecordingPlayer: AVPlayer, @unchecked Sendable {
    private let transportLock = NSLock()
    private var requestedRate: Float = 0

    var isExplicitlyPaused: Bool { transportLock.withLock { requestedRate == 0 } }

    private func recordTransport(_ rate: Float) {
        transportLock.withLock { requestedRate = rate }
    }

    override var rate: Float {
        get { super.rate }
        set {
            recordTransport(newValue)
            super.rate = newValue
        }
    }

    override func play() {
        recordTransport(defaultRate)
        super.play()
    }

    override func pause() {
        recordTransport(0)
        super.pause()
    }

    override func playImmediately(atRate rate: Float) {
        recordTransport(rate)
        super.playImmediately(atRate: rate)
    }

    override func setRate(_ rate: Float, time itemTime: CMTime, atHostTime hostClockTime: CMTime) {
        recordTransport(rate)
        super.setRate(rate, time: itemTime, atHostTime: hostClockTime)
    }

    @MainActor func preserveExplicitPause() {
        guard isExplicitlyPaused, rate != 0 else { return }
        pause()
    }
}
