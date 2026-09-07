import AppKit
import SwiftUI
import Testing
@testable import YapAppUI

@Suite("Header window dragging", .serialized) @MainActor
struct YapWindowDragSurfaceTests {
    @Test func headerBackgroundAndTitleDragWithWindowBackgroundDraggingDisabled() async throws {
        let fixture = HeaderDragFixture()
        defer { fixture.cleanUp() }
        let surface = try await fixture.surface()

        for point in [NSPoint(x: 80, y: 36), NSPoint(x: 250, y: 36)] {
            #expect(fixture.hosting.hitTest(point) === surface)
            let event = try fixture.event(.leftMouseDown, at: point)
            surface.mouseDown(with: event)
        }
        #expect(fixture.window.dragCount == 2)
        #expect(fixture.window.isMovable)
        #expect(!fixture.window.isMovableByWindowBackground)
    }

    @Test func headerButtonAndTextFieldReceiveTheirPressInsteadOfDragging() async throws {
        let fixture = HeaderDragFixture()
        defer { fixture.cleanUp() }
        let surface = try await fixture.surface()
        let regions = fixture.hosting.descendants(of: YapWindowInteractionTrackingView.self)
        #expect(regions.count == 2)

        for point in [NSPoint(x: 400, y: 36), NSPoint(x: 550, y: 36)] {
            let press = try fixture.event(.leftMouseDown, at: point)
            regions.forEach { $0.handleLocalEvent(press) }
            #expect(!fixture.window.isMovable)
            let hit = fixture.hosting.hitTest(point)
            #expect(hit != nil)
            #expect(hit !== surface)
            surface.mouseDown(with: press)
            #expect(fixture.window.dragCount == 0)
            let release = try fixture.event(.leftMouseUp, at: point)
            regions.forEach { $0.handleLocalEvent(release) }
            #expect(fixture.window.isMovable)
        }
    }
}

@MainActor
private final class HeaderDragFixture {
    let window: HeaderDragTrackingWindow
    let hosting: NSHostingView<HeaderDragFixtureView>

    init() {
        _ = NSApplication.shared
        window = HeaderDragTrackingWindow(contentRect: NSRect(x: 10_000, y: 10_000, width: 640, height: 72),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        hosting = NSHostingView(rootView: HeaderDragFixtureView())
        window.contentView = hosting
        hosting.setFrameSize(NSSize(width: 640, height: 72))
    }

    func surface() async throws -> YapWindowDragView {
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            if let surface = hosting.descendants(of: YapWindowDragView.self).first { return surface }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(hosting.descendants(of: YapWindowDragView.self).first)
    }

    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: hosting.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }

    func cleanUp() {
        hosting.descendants(of: YapWindowInteractionTrackingView.self).forEach { $0.detach() }
        window.contentView = nil
        window.close()
    }
}

private struct HeaderDragFixtureView: View {
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            Text("Recording title").frame(width: 160, height: 72)
            Spacer(minLength: 0)
            Button("Download") {}
                .frame(width: 120, height: 72)
                .background(YapWindowInteractionRegion())
            TextField("Search", text: $search)
                .frame(width: 180, height: 72)
                .background(YapWindowInteractionRegion())
        }
        .frame(width: 640, height: 72)
        .overlay(YapWindowDragSurface())
    }
}

@MainActor private final class HeaderDragTrackingWindow: NSWindow {
    private(set) var dragCount = 0
    override func performDrag(with event: NSEvent) { dragCount += 1 }
}

@MainActor private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        ((self as? T).map { [$0] } ?? []) + subviews.flatMap { $0.descendants(of: type) }
    }
}
