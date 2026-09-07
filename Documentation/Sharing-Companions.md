# Sharing companions

Final checkpoint, September 6, 2026. The package is built and canonically installed ([install log](../../work/pip-verified-install.log)). A real meeting verified selected-window delivery, live PiP/handle/Chat after minimizing, and Stop restoring the main window onscreen while removing Chat. Native synthetic QA separately verified dragging, pointer fade, and chat composition. Persistent physical foreground activation and full-display panel exclusion remain unverified. The separate QA harness supplies synthetic meeting state; interface preview never captures or transmits media.

## Native Zoom references

Zoom's macOS participant panel can show speaker or gallery views, shrink, or hide. Moving its gallery panel to the top or bottom of the display produces a horizontal strip. This informs Whoosh's camera-adjacent placement. [Zoom participant video panel](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061332).

Zoom moves sharing controls into a movable floating toolbar with Stop share, Chat, and a hide-controls command. It also offers a separate floating chat window during sharing. Zoom's statement that its own chat window is not shared applies to Zoom's client; it does not establish the same protection for Whoosh's custom panels. [Zoom sharing controls](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060596), [Zoom floating chat](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0064400).

## Whoosh behavior

- **Picture in picture:** when a real meeting is connected and the main meeting is backgrounded, hidden, or minimized, a floating strip presents up to six unique remote participants from the current visible set. It starts near the display's top center, below the menu bar. Bringing the main meeting forward returns its renderers there.
- **Faces:** the strip is translucent and click-through, fading away when the pointer approaches and returning when it leaves. Different enter/exit distances prevent flicker. A separate draggable handle repositions the strip within the display's usable area; the faces stay visible while dragging or approaching that handle. Reduce Motion and Reduce Transparency are respected. Dragging and pointer fade passed the native synthetic checks below; the complete live Zoom transition remains separate.
- **Chat:** a movable, resizable native Chat panel accompanies sharing. Closing it hides it for that share; the menu-bar menu can reopen it. Draft/send state belongs to the meeting session and survives panel presentation changes.
- **Stop and return:** the existing menu-bar Join/Return position becomes Stop sharing only after confirmed sharing state. A confirmed stop removes floating Chat and restores the same connected meeting onscreen. PiP remains eligible if the connected main meeting is then backgrounded again. Failure keeps Stop available; an ended or replaced session cannot trigger a stale return.

The implementation uses public AppKit [floating panels](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel), [click-through windows](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents), and SwiftUI [Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views). Pointer proximity polls [`NSEvent.mouseLocation`](https://developer.apple.com/documentation/appkit/nsevent/mouselocation) only while a real meeting is connected; it installs no global event tap and requests no additional Accessibility permission. This does not make a claim about permissions requested elsewhere by the Zoom SDK.

## Native QA and live boundary

The exact production controller was exercised with six synthetic participants. Dragging moved both the handle and strip by 180 × 140 and preserved the new location. Moving the strip beneath the stationary physical pointer made it transparent (alpha 0); moving away restored approximately 0.90. [Drag facts](../../work/overlay-qa-drag-verified.json), [hover facts](../../work/overlay-qa-hover-facts.json), [restored facts](../../work/overlay-qa-restored-facts.json).

The Chat glass/titlebar was visually checked, and native Return sent a synthetic message and cleared the shared composer. [Chat QA capture](../../work/Whoosh-PiP-QA-Chat-Final.png). These are native UI checks without Zoom media, distinct from the pure Swift test suite.

In the final installed build (process 32970), a native Zoom second endpoint received the selected safe fixture B window. Minimizing the main meeting produced the real PiP strip, drag handle, and Chat panel. The SDK measured received PiP **160 × 90 at 11–12 fps** and outgoing camera **640 × 360 at 26 fps**; current 720p is not claimed. Stop restored the main window onscreen and removed Chat. [Receiver capture](../../outputs/Whoosh-Companion-Share-Receiver.jpg), [minimized panels](../../work/final-live-minimized-panels.json), [Stop return](../../work/final-live-stop-return.json).

CUA's virtual/background interaction can restore another physical foreground app after an action. The check therefore establishes onscreen restoration, not persistent foreground activation or a complete repeated gallery/focus/PiP stress test. Production `.none` panels were absent/black in screenshot capture; that does not prove exclusion from Zoom's full-display sharing pipeline.

## Capture boundary

Whoosh cannot promise these panels are excluded from a full-display share. `NSWindow.sharingType = .none` is a legacy hint: Apple's DTS response to a macOS 15.4+ ScreenCaptureKit report says there is no public API for universally preventing capture. [Apple sharing type](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none), [Apple DTS explanation](https://developer.apple.com/forums/thread/792152).

Whoosh checks `isSupportShowZoomWindowWhenShare` before requesting `setShowZoomWindowWhenShare:NO`. The SDK setting may be unsupported, and its documentation covers Zoom meeting windows, not arbitrary custom panels. No public arbitrary-window exclusion API was found in the reviewed macOS Meeting SDK 7.1.5 headers. [Zoom SDK setting](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_share_screen_setting.html).

[`SCContentFilter`](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) can exclude content from a ScreenCaptureKit stream the app owns. Whoosh's current Zoom window/display sharing route does not accept that filter. Receiver-side checks must therefore establish what is actually transmitted; floating chat must not be described as private from the shared display.

Source: [overlay controller](../Sources/WhooshAppUI/WhooshSharingOverlayController.swift), [menu-bar actions](../Sources/WhooshAppUI/WhooshMenuBarController.swift). [Companion fixtures](../Tests/WhooshAppUITests/WhooshSharingOverlayTests.swift) cover state, geometry, handle placement, and chat lifecycle. The complete pure Swift checkpoint passed 247 tests in 34 suites, with no failures, skips, or compiler warnings ([test log](../../outputs/Whoosh-Pure-Swift-Test-Log.txt)); it does not prove live rendering or capture exclusion.
