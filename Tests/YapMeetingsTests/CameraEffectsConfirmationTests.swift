import Foundation
import Testing
@testable import YapMeetings

@Suite("Camera effects readback") @MainActor
struct CameraEffectsConfirmationTests {
    @Test func confirmsDelayedSelectionWithoutReapplying() async throws {
        var reads = 0
        let result = try await CameraEffectsConfirmation.wait(initialResult: 1, isPending: { true }, isCurrent: { true },
            confirm: { reads += 1; return reads == 2 ? 0 : 1 }, interval: .milliseconds(1))
        #expect(result == 0)
        #expect(reads == 2)
    }

    @Test func hardFailureDoesNotRetryAndPendingFailureIsBounded() async throws {
        var reads = 0
        let rejected = try await CameraEffectsConfirmation.wait(initialResult: 8, isPending: { false }, isCurrent: { true },
            confirm: { reads += 1; return 0 }, interval: .milliseconds(1))
        #expect(rejected == 8)
        #expect(reads == 0)
        let pending = try await CameraEffectsConfirmation.wait(initialResult: 1, isPending: { true }, isCurrent: { true },
            confirm: { reads += 1; return 1 }, interval: .milliseconds(1), attempts: 3)
        #expect(pending == 1)
        #expect(reads == 3)
    }

    @Test func closingOrReplacingTheSessionRejectsLateReadback() async throws {
        var current = true
        var reads = 0
        let task = Task { @MainActor in
            try await CameraEffectsConfirmation.wait(initialResult: 1, isPending: { true }, isCurrent: { current },
                confirm: { reads += 1; return 0 }, interval: .milliseconds(20))
        }
        await Task.yield()
        current = false
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reads == 0)
    }

    @Test func taskCancellationNeverConfirmsOrUnmutes() async throws {
        var reads = 0
        let task = Task { @MainActor in
            try await CameraEffectsConfirmation.wait(initialResult: 1, isPending: { true }, isCurrent: { true },
                confirm: { reads += 1; return 0 }, interval: .seconds(10))
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reads == 0)
    }
}
