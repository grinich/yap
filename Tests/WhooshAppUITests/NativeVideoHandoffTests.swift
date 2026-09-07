import AppKit
import Testing
@testable import WhooshAppUI

@Suite("Native video branch handoff")
@MainActor
struct NativeVideoHandoffTests {
    @Test func pictureInPictureScalesTheExistingSurfaceWithoutChangingRendererGeometry() {
        let video = NSView()
        let canvas = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        canvas.setRenderer(video)
        let originalBounds = video.bounds
        let pip = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 112, height: 63))
        pip.setRenderer(video, preservesSize: true)
        #expect(video.superview === pip)
        #expect(sameSize(video.bounds.size, originalBounds.size))
        #expect(pip.frame.size == NSSize(width: 112, height: 63))
        #expect(pip.convert(video.bounds, from: video) == pip.bounds)
        #expect(sameSize(pip.convert(pip.bounds, to: nil).size, pip.frame.size))
        canvas.dismantle()
        pip.setFrameSize(NSSize(width: 160, height: 90))
        #expect(sameSize(video.bounds.size, originalBounds.size))
        pip.dismantle()
        let restored = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        restored.setRenderer(video)
        #expect(video.superview === restored)
        #expect(sameSize(video.bounds.size, originalBounds.size))
        restored.dismantle()
    }

    @Test func repeatedPictureInPictureTripsRetainTheLatestCanvasSizePerVideo() {
        let video = NSView()
        for size in [NSSize(width: 640, height: 360), NSSize(width: 1280, height: 720)] {
            let canvas = AttachedVideoHost(frame: NSRect(origin: .zero, size: size))
            canvas.setRenderer(video)
            let pip = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 112, height: 63))
            pip.setRenderer(video, preservesSize: true)
            canvas.setRenderer(video) // A late main-window update cannot resize PiP.
            #expect(video.superview === pip)
            #expect(sameSize(video.bounds.size, size))
            canvas.dismantle()
            pip.dismantle()
        }
    }

    @Test func cameraEnabledInPictureInPictureUsesItsInitialSurfaceThenAdoptsMainSize() {
        let video = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let pip = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 112, height: 63))
        pip.setRenderer(video, preservesSize: true)
        #expect(sameSize(video.bounds.size, NSSize(width: 320, height: 180)))
        pip.dismantle()
        let main = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        main.setRenderer(video)
        #expect(video.bounds.size == main.bounds.size)
        main.dismantle()
    }

    @Test func switchingScaledHostToAnotherVideoDoesNotReuseTheFirstVideosSize() {
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let pip = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 112, height: 63))
        pip.setRenderer(first, preservesSize: true)
        pip.setRenderer(second, preservesSize: true)
        #expect(first.superview == nil)
        #expect(sameSize(second.bounds.size, NSSize(width: 320, height: 180)))
        #expect(pip.frame.size == NSSize(width: 112, height: 63))
        pip.setRenderer(second)
        #expect(second.bounds.size == pip.frame.size)
        pip.dismantle()
    }

    @Test func lateGalleryUpdateCannotStealFocusedRenderer() {
        let video = NSView()
        let gallery = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let focus = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        gallery.setRenderer(video)
        focus.setRenderer(video)
        gallery.setRenderer(video)
        gallery.dismantle()
        #expect(video.superview === focus)
        #expect(video.frame == focus.bounds)
        #expect(gallery.subviews.isEmpty)
    }

    @Test func nilUpdateDoesNotRestoreAnOutgoingMountsOwnership() {
        let video = NSView()
        let old = AttachedVideoHost(frame: .zero)
        let replacement = AttachedVideoHost(frame: .zero)
        old.setRenderer(video)
        replacement.setRenderer(video)
        old.setRenderer(nil)
        old.setRenderer(video)
        #expect(video.superview === replacement)
        old.dismantle()
        #expect(video.superview === replacement)
    }

    @Test func outgoingDismantleBeforeIncomingUpdateAlsoWorks() {
        let video = NSView()
        let old = AttachedVideoHost(frame: .zero)
        let replacement = AttachedVideoHost(frame: .zero)
        old.setRenderer(video)
        old.dismantle()
        #expect(video.superview == nil)
        replacement.setRenderer(video)
        old.setRenderer(video)
        #expect(video.superview === replacement)
    }

    @Test func galleryFocusGalleryAndCameraReplacementKeepNewestMount() {
        let video = NSView()
        let gallery = AttachedVideoHost(frame: .zero)
        let focus = AttachedVideoHost(frame: .zero)
        let nextGallery = AttachedVideoHost(frame: .zero)
        gallery.setRenderer(video)
        focus.setRenderer(video)
        nextGallery.setRenderer(video)
        focus.setRenderer(video)
        gallery.dismantle()
        focus.dismantle()
        #expect(video.superview === nextGallery)
        nextGallery.setRenderer(nil)
        #expect(video.superview == nil)
        nextGallery.setRenderer(video)
        #expect(video.superview === nextGallery)
        nextGallery.dismantle()
        #expect(video.superview == nil)
    }

    @Test func unchangedUpdatesDoNotDetachAndResizeUsesCurrentBounds() {
        let video = MoveCountingVideo()
        let host = AttachedVideoHost(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        host.setRenderer(video)
        let moves = video.moves
        for _ in 0..<10 { host.setRenderer(video) }
        #expect(video.moves == moves)
        host.setFrameSize(NSSize(width: 1280, height: 720))
        #expect(video.frame == host.bounds)
        #expect(video.moves == moves)
        host.dismantle()
    }

    @Test func zeroSizedInitialMountForwardsItsFirstRealBounds() {
        let video = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let host = AttachedVideoHost(frame: .zero)
        host.simulatedAttachment = false
        host.setRenderer(video)
        #expect(video.superview == nil)
        host.simulatedAttachment = true
        host.setFrameSize(NSSize(width: 640, height: 360))
        #expect(video.superview === host)
        #expect(video.frame == host.bounds)
        host.dismantle()
    }

    @Test func unattachedProbeDoesNotStealAndReattachedHostCanReturn() {
        let video = NSView()
        let visible = AttachedVideoHost(frame: .zero)
        let probe = AttachedVideoHost(frame: .zero)
        visible.setRenderer(video)
        probe.simulatedAttachment = false
        probe.setRenderer(video)
        #expect(video.superview === visible)
        probe.dismantle()
        visible.setRenderer(video)
        #expect(video.superview === visible)

        let replacement = AttachedVideoHost(frame: .zero)
        replacement.setRenderer(video)
        #expect(video.superview === replacement)
        visible.simulatedAttachment = false
        visible.layout()
        replacement.dismantle()
        visible.simulatedAttachment = true
        visible.layout()
        #expect(video.superview === visible)
        visible.dismantle()
    }

    @Test func outgoingZeroSizeProbeDoesNotRenewItsAttachmentPriority() {
        let video = NSView()
        let outgoing = AttachedVideoHost(frame: .zero)
        let incoming = AttachedVideoHost(frame: .zero)
        outgoing.setRenderer(video)
        incoming.setRenderer(video)
        outgoing.simulatedAttachment = false
        outgoing.layout()
        outgoing.simulatedAttachment = true
        outgoing.layout()
        #expect(video.superview === incoming)
        outgoing.dismantle()
        #expect(video.superview === incoming)
        incoming.dismantle()
    }

    @Test func changingFocusedParticipantReplacesItsOlderMainHost() {
        let videoA = NSView()
        let videoB = NSView()
        let focusA = AttachedVideoHost(frame: .zero)
        let thumbnailB = AttachedVideoHost(frame: .zero)
        focusA.setRenderer(videoA)
        thumbnailB.setRenderer(videoB)

        // NativeVideoContainer.id(participant.id) gives the new focused person
        // a new host, even though the focus branch itself remains in place.
        let focusB = AttachedVideoHost(frame: .zero)
        let thumbnailA = AttachedVideoHost(frame: .zero)
        focusB.setRenderer(videoB)
        thumbnailA.setRenderer(videoA)
        thumbnailB.setRenderer(videoB)
        focusA.setRenderer(videoA)
        focusA.dismantle()
        thumbnailB.dismantle()
        #expect(videoB.superview === focusB)
        #expect(videoA.superview === thumbnailA)

        let nextFocusA = AttachedVideoHost(frame: .zero)
        let nextThumbnailB = AttachedVideoHost(frame: .zero)
        nextFocusA.setRenderer(videoA)
        nextThumbnailB.setRenderer(videoB)
        thumbnailA.dismantle()
        focusB.dismantle()
        #expect(videoA.superview === nextFocusA)
        #expect(videoB.superview === nextThumbnailB)
        nextFocusA.dismantle()
        nextThumbnailB.dismantle()
    }

    @Test func leaseDoesNotRetainReleasedHostOrRenderer() {
        weak var releasedHost: NativeVideoHost?
        weak var releasedVideo: NSView?
        autoreleasepool {
            let host = AttachedVideoHost(frame: .zero)
            let video = NSView()
            releasedHost = host
            releasedVideo = video
            host.setRenderer(video)
            host.dismantle()
        }
        #expect(releasedHost == nil)
        #expect(releasedVideo == nil)
    }

    private func sameSize(_ left: NSSize, _ right: NSSize) -> Bool {
        abs(left.width - right.width) < 0.001 && abs(left.height - right.height) < 0.001
    }
}

@MainActor
private final class MoveCountingVideo: NSView {
    var moves = 0
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        moves += 1
    }
}

@MainActor
private final class AttachedVideoHost: NativeVideoHost {
    var simulatedAttachment = true
    override var hasUsableAttachment: Bool { simulatedAttachment }
}
