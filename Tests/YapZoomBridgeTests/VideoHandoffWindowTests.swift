import AppKit
import Combine
import SwiftUI

/// Standalone fixture: compile with the production NativeVideoHost.swift and
/// WHZoomRenderHost.m. Opens its own small window; never loads Zoom or Yap.
@MainActor
private final class FixtureState: ObservableObject { @Published var focused = false }

@MainActor
private struct FixtureCanvas: View {
    @ObservedObject var state: FixtureState
    let renderer: NSView
    var body: some View {
        if state.focused {
            VStack {
                tile.frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.gray.frame(height: 40)
            }
        } else {
            HStack {
                tile
                Color.gray.frame(width: 40)
            }
        }
    }
    private var tile: some View {
        GeometryReader { _ in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black)
                NativeRendererContainer(renderer: renderer).id("remote")
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

@main
@MainActor
struct VideoHandoffWindowTests {
    static func pump(_ seconds: TimeInterval = 0.25) {
        let deadline = Date().addingTimeInterval(seconds)
        while deadline.timeIntervalSinceNow > 0 {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                          inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    static func require(_ success: @autoclosure () -> Bool, _ message: String) {
        guard success() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let renderer = WHZoomRenderHost(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        var usableSizes: [NSSize] = []
        renderer.resizeRenderer = { usableSizes.append($0.size) }
        let state = FixtureState()
        let root = NSHostingView(rootView: FixtureCanvas(state: state, renderer: renderer)
            .frame(minWidth: 480, minHeight: 300))
        // Match an application window whose scene supplies its own dimensions,
        // rather than resizing this fixture window to the canvas's ideal size.
        root.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 480, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Yap native video fixture"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        window.contentView = content
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        defer { window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        pump(0.6)
        print("initial windowVisible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) root=\(root.bounds) owner=\(String(describing: renderer.superview?.bounds)) renderer=\(renderer.bounds) visible=\(renderer.visibleRect) resizeCount=\(usableSizes.count)")
        require(renderer.window === window, "gallery renderer must join the native window")
        require(renderer.isReadyForRenderer, "initial zero-sized SwiftUI mount must become usable")
        require(!usableSizes.isEmpty, "initial SwiftUI layout must forward real bounds")
        let galleryOwner = renderer.superview
        state.focused = true
        pump()
        require(renderer.window === window && renderer.isReadyForRenderer, "focus handoff must remain visible")
        require(renderer.superview !== galleryOwner, "focus must use its replacement mount")
        state.focused = false
        pump()
        require(renderer.window === window && renderer.isReadyForRenderer, "return to gallery must remain visible")
        window.setContentSize(NSSize(width: 600, height: 400))
        pump()
        require(renderer.bounds.width > 500 && renderer.bounds.height >= 390, "resize must forward the new gallery bounds")
        window.miniaturize(nil)
        pump(0.5)
        require(!renderer.isReadyForRenderer, "minimized window must suspend the renderer")
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
        require(renderer.isReadyForRenderer, "restored window must resume the renderer")
        print("PASS: actual SwiftUI zero-size attachment, gallery/focus/gallery, resize, minimize/restore (\(usableSizes.count) renderer sizes)")
    }
}
