import Foundation

/// Zoom can accept a background before its selected-item getter catches up.
/// Wait without repeating setters, and never read a disposed SDK after a yield.
@MainActor
enum CameraEffectsConfirmation {
    static func wait(initialResult: Int, isPending: () -> Bool, isCurrent: () -> Bool,
                     confirm: () -> Int, interval: Duration = .milliseconds(100), attempts: Int = 30) async throws -> Int {
        var result = initialResult
        for _ in 0..<attempts {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if result == 0 || !isPending() { return result }
            try await Task.sleep(for: interval)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            result = confirm()
        }
        return result
    }
}
