import AppKit
import Observation
import SwiftUI
import Testing
import WhooshMeetings
@testable import WhooshAppUI

/// Unordered AppKit windows only: no activation, posted events, capture, or SDK.
@MainActor
@Suite("Native share collection interaction", .serialized)
struct MeetingSharePreviewGridTests {
    @Test func directionalNavigationSelectsSourcesAndScrolls() async throws {
        let fixture = ShareGridFixture()
        defer { fixture.window.close() }
        let collection = try await fixture.collection()
        #expect(fixture.window.makeFirstResponder(collection))
        #expect(fixture.state.selectedID == nil)
        let layout = try #require(collection.collectionViewLayout)
        let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let third = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
        #expect(first.frame.minY == third.frame.minY)
        #expect(third.frame.maxX <= collection.enclosingScrollView!.contentSize.width)

        fixture.press(.right, in: collection)
        #expect(fixture.state.selectedID == fixture.state.sources[0].pickerID)
        fixture.press(.right, in: collection)
        #expect(fixture.state.selectedID == fixture.state.sources[1].pickerID)
        fixture.press(.down, in: collection)
        #expect(fixture.state.selectedID == fixture.state.sources[4].pickerID)
        fixture.press(.left, in: collection)
        #expect(fixture.state.selectedID == fixture.state.sources[3].pickerID)
        fixture.press(.up, in: collection)
        #expect(fixture.state.selectedID == fixture.state.sources[0].pickerID)

        for _ in 0..<5 { fixture.press(.down, in: collection) }
        #expect(fixture.state.selectedID == fixture.state.sources[15].pickerID)
        #expect(collection.enclosingScrollView!.contentView.bounds.origin.y > 0)
        #expect(fixture.window.firstResponder === collection)
        #expect(!fixture.window.isVisible)
    }

    @Test func scrollerWidthChangesKeepThreeColumns() async throws {
        let fixture = ShareGridFixture()
        defer { fixture.window.close() }
        let collection = try await fixture.collection()
        let scroll = try #require(collection.enclosingScrollView)
        for style in [NSScroller.Style.legacy, .overlay, .legacy] {
            scroll.scrollerStyle = style
            await fixture.settle()
            let layout = try #require(collection.collectionViewLayout)
            let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
            let third = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
            #expect(first.frame.minY == third.frame.minY)
            #expect(third.frame.maxX <= scroll.contentSize.width)
        }
    }

    @Test func thumbnailUpdatesPreserveSelectionScrollAndFirstResponder() async throws {
        let fixture = ShareGridFixture()
        defer { fixture.window.close() }
        let collection = try await fixture.collection()
        #expect(fixture.window.makeFirstResponder(collection))
        fixture.press(.right, in: collection)
        for _ in 0..<4 { fixture.press(.down, in: collection) }
        let selectedID = try #require(fixture.state.selectedID)
        let selection = collection.selectionIndexPaths
        let scroll = try #require(collection.enclosingScrollView)
        let origin = scroll.contentView.bounds.origin

        fixture.state.previews[selectedID] = MeetingSharePreview(
            image: NSImage(size: NSSize(width: 160, height: 90)),
            applicationName: "Fixture", applicationIcon: nil)
        fixture.state.previewsLoading = false
        await fixture.settle()

        #expect(try await fixture.collection() === collection)
        #expect(fixture.state.selectedID == selectedID)
        #expect(collection.selectionIndexPaths == selection)
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(fixture.window.firstResponder === collection)
        #expect(!fixture.window.isVisible)
    }

    @Test func returnLeavesSelectionUntouchedAndForwardsToTheSheetResponder() async throws {
        let fixture = ShareGridFixture()
        defer { fixture.window.close() }
        let collection = try await fixture.collection()
        let originalResponder = collection.nextResponder
        let sheet = ShareGridReturnResponder()
        collection.nextResponder = sheet
        defer { collection.nextResponder = originalResponder }

        fixture.press(.returnKey, in: collection)
        #expect(fixture.state.selectedID == nil)
        #expect(sheet.returnCount == 1)
        fixture.press(.right, in: collection)
        let selectedID = fixture.state.selectedID
        fixture.press(.returnKey, in: collection)
        #expect(fixture.state.selectedID == selectedID)
        #expect(sheet.returnCount == 2)
    }

    @Test func missingTitlesKeepUsefulAccessibilityLabelsAndTooltips() async throws {
        let sources = [
            ShareTarget(id: "1", title: "", kind: .window),
            ShareTarget(id: "2", title: " \n ", kind: .display),
            ShareTarget(id: "sample", title: "", kind: .demo)
        ]
        let fixture = ShareGridFixture(sources: sources)
        defer { fixture.window.close() }
        fixture.state.previewsLoading = false
        let collection = try await fixture.collection()
        #expect(collection.accessibilityLabel() == "Choose a window or display to share")
        for (index, label) in ["Untitled window", "Display", "Sample content"].enumerated() {
            let item = try #require(collection.item(at: IndexPath(item: index, section: 0)))
            #expect(item.view.accessibilityLabel() == label)
            #expect(item.view.toolTip == label)
        }
    }
}

@MainActor @Observable
private final class ShareGridFixtureState {
    static let defaultSources = (0..<18).map {
        ShareTarget(id: String($0 + 1), title: "Fixture — Window \($0 + 1)", kind: .window)
    }
    let sources: [ShareTarget]
    var selectedID: String?
    var previews: [String: MeetingSharePreview] = [:]
    var previewsLoading = true

    init(sources: [ShareTarget]?) { self.sources = sources ?? Self.defaultSources }
}

@MainActor
private final class ShareGridReturnResponder: NSResponder {
    var returnCount = 0
    override func insertNewline(_ sender: Any?) { returnCount += 1 }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { returnCount += 1 }
    }
}

@MainActor
private struct ShareGridFixtureView: View {
    @Bindable var state: ShareGridFixtureState
    var body: some View {
        MeetingSharePreviewGrid(sources: state.sources, previews: state.previews,
            previewsLoading: state.previewsLoading, isEnabled: true, selectedID: $state.selectedID)
            .frame(width: 580, height: 316)
    }
}

@MainActor
private final class ShareGridFixture {
    let state: ShareGridFixtureState
    let window: NSWindow
    let hosting: NSHostingView<ShareGridFixtureView>

    init(sources: [ShareTarget]? = nil) {
        _ = NSApplication.shared
        state = ShareGridFixtureState(sources: sources)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 316),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: ShareGridFixtureView(state: state))
        window.contentView = hosting
    }

    enum Key {
        case left, right, up, down, returnKey
        var character: String {
            switch self {
            case .left: "\u{F702}"
            case .right: "\u{F703}"
            case .up: "\u{F700}"
            case .down: "\u{F701}"
            case .returnKey: "\r"
            }
        }
        var keyCode: UInt16 {
            switch self {
            case .left: 123
            case .right: 124
            case .down: 125
            case .up: 126
            case .returnKey: 36
            }
        }
    }

    func press(_ arrow: Key, in collection: NSCollectionView) {
        // Delivered only to this unordered fixture view, never the event queue.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: arrow.character, charactersIgnoringModifiers: arrow.character,
            isARepeat: false, keyCode: arrow.keyCode)!
        collection.keyDown(with: event)
    }

    func settle() async {
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func collection() async throws -> NSCollectionView {
        await settle()
        return try #require(find(NSCollectionView.self, in: hosting))
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
}
