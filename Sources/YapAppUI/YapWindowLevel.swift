import AppKit
import Observation

@MainActor @Observable
final class YapWindowLevel {
    static let shared = YapWindowLevel()
    var isEnabled = false {
        didSet { for window in windows.allObjects { apply(to: window) } }
    }
    @ObservationIgnored private let windows = NSHashTable<NSWindow>.weakObjects()

    func register(_ window: NSWindow) {
        windows.add(window)
        apply(to: window)
    }

    private func apply(to window: NSWindow) {
        window.level = isEnabled ? .floating : .normal
    }
}
