# Meeting windows and self-view

The background picture-in-picture and floating sharing-chat windows have been removed. Switching away from Yap no longer opens companion windows. Use the **Keep on Top** pin beside the close button, or **View → Keep on Top**, to keep the main meeting window and recording players above ordinary windows. Turn it off to return them to normal window ordering; it starts off each time Yap launches.

Active-speaker view displays only the speaker and your local self-view. Self-view starts at the top right, slides below the toolbar when controls appear, can be dragged to any corner, and snaps on release while leaving the toolbar and call controls clear. VoiceOver actions also move it between corners.

## Historical companion-window implementation

The following records describe the removed implementation and are retained as historical test evidence only.

# Sharing companions

**Historical evidence:** recorded checks in this document predate the Yap rename. References to earlier app identities and original evidence files describe those checkpoints, not validation of the renamed build. See [Bundle Identity](Bundle-Identity.md).

Updated September 7, 2026. Background picture in picture is now a larger, interactive window with uncropped video, whole-window dragging, and a visible resize grip. Current native fixture verification is described below. Earlier live Zoom sharing evidence is retained separately; it does not establish the new window’s live video performance. The separate QA harness supplies synthetic meeting state; interface preview never captures or transmits media.

## Native Zoom references

Zoom's macOS participant panel can show speaker or gallery views, shrink, or hide. Moving its gallery panel to the top or bottom of the display produces a horizontal strip. This informs Yap's camera-adjacent placement. [Zoom participant video panel](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061332).

Zoom moves sharing controls into a movable floating toolbar with Stop share, Chat, and a hide-controls command. It also offers a separate floating chat window during sharing. Zoom's statement that its own chat window is not shared applies to Zoom's client; it does not establish the same protection for Yap's custom panels. [Zoom sharing controls](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060596), [Zoom floating chat](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0064400).

## Yap behavior

- **Picture in picture:** when a real meeting is connected and the main meeting is backgrounded, hidden, or minimized, a floating window presents up to six unique remote participants from the current visible set. A solo call shows self-view. It starts near the display’s upper-right corner, below the menu bar. A single landscape video starts at 384 × 216 points inside a 400 × 248 window; portrait and group layouts adapt to the available display area.
- **Video:** tiles use each camera’s aspect ratio and fit the complete frame. Native renderer bounds match the actual viewport, including while resizing. Returning to the main meeting reuses the same renderer and subscription.
- **Move and resize:** drag anywhere on the video or its background to reposition the window. Drag the visible lower-right grip to resize, or use its accessibility increment/decrement actions. The window stays visible under the mouse; the former pointer fade and separate grab handle have been removed. Size and position are retained while the app runs, including foreground round trips and subsequent calls. Placement is clamped to an available display when necessary.
- **Chat:** a movable, resizable native Chat panel accompanies sharing. Closing it hides it for that share; the menu-bar menu can reopen it. Draft/send state belongs to the meeting session and survives panel presentation changes.
- **Stop and return:** the existing menu-bar Join/Return position becomes Stop sharing only after confirmed sharing state. A confirmed stop removes floating Chat and restores the same connected meeting onscreen. PiP remains eligible if the connected main meeting is then backgrounded again. Failure keeps Stop available; an ended or replaced session cannot trigger a stale return.

The implementation uses public AppKit floating panels and native pointer events, with SwiftUI Liquid Glass and Reduce Transparency support. The video surface handles drag and resize without activating the main meeting. No global pointer event tap or additional Accessibility permission is needed for these controls.

## Native QA and live boundary

The September 7 native fixture exercised the production controller with synthetic native camera views. Dragging the video moved the window by −100 × −40 points. Dragging the lower-right grip resized it from 400 × 248 to 580 × 348 while keeping its top-left corner fixed. Foregrounding and backgrounding the meeting restored that exact frame. Its alpha stayed 1 with the pointer over the video. A portrait camera retained both visible edge markers and its complete frame after resizing to 240 × 508. Renderer bounds matched the fitted viewport throughout. Evidence: [before drag](../../work/liquid-glass-qa/pip-before-drag.json), [after drag](../../work/liquid-glass-qa/pip-after-drag.json), [resized](../../work/liquid-glass-qa/pip-after-resize.json), [restored](../../work/liquid-glass-qa/pip-after-return.json), [portrait](../../work/liquid-glass-qa/pip-portrait-resized.json).

The current pure suite passed 364 tests in 53 suites. Geometry, resize limits, renderer identity/bounds through a PiP round trip, and presentation/chat lifecycle are covered. This does not measure live Zoom frame rate, transition latency, or capture exclusion.

Earlier September 6 synthetic checks verified the superseded small strip, separate drag handle, and pointer fade. Those interactions are no longer the current design.

The Chat glass/titlebar was visually checked, and native Return sent a synthetic message and cleared the shared composer. [Chat QA capture](../../work/Whoosh-PiP-QA-Chat-Final.png). These are native UI checks without Zoom media, distinct from the pure Swift test suite.

In the earlier September 6 installed build (process 32970), a native Zoom second endpoint received the selected safe fixture B window. Minimizing the main meeting produced the real PiP strip, drag handle, and Chat panel. The SDK measured received PiP **160 × 90 at 11–12 fps** and outgoing camera **640 × 360 at 26 fps**; current 720p is not claimed. Stop restored the main window onscreen and removed Chat. [Receiver capture](../../outputs/Whoosh-Companion-Share-Receiver.jpg), [minimized panels](../../work/final-live-minimized-panels.json), [Stop return](../../work/final-live-stop-return.json).

CUA's virtual/background interaction can restore another physical foreground app after an action. The check therefore establishes onscreen restoration, not persistent foreground activation or a complete repeated gallery/focus/PiP stress test. Production `.none` panels were absent/black in screenshot capture; that does not prove exclusion from Zoom's full-display sharing pipeline.

## Capture boundary

Yap cannot promise these panels are excluded from a full-display share. `NSWindow.sharingType = .none` is a legacy hint: Apple's DTS response to a macOS 15.4+ ScreenCaptureKit report says there is no public API for universally preventing capture. [Apple sharing type](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none), [Apple DTS explanation](https://developer.apple.com/forums/thread/792152).

Yap checks `isSupportShowZoomWindowWhenShare` before requesting `setShowZoomWindowWhenShare:NO`. The SDK setting may be unsupported, and its documentation covers Zoom meeting windows, not arbitrary custom panels. No public arbitrary-window exclusion API was found in the reviewed macOS Meeting SDK 7.1.5 headers. [Zoom SDK setting](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_share_screen_setting.html).

[`SCContentFilter`](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) can exclude content from a ScreenCaptureKit stream the app owns. Yap's current Zoom window/display sharing route does not accept that filter. Receiver-side checks must therefore establish what is actually transmitted; floating chat must not be described as private from the shared display.

Source: [overlay controller](../Sources/YapAppUI/YapSharingOverlayController.swift), [menu-bar actions](../Sources/YapAppUI/YapMenuBarController.swift). [Companion fixtures](../Tests/YapAppUITests/YapSharingOverlayTests.swift) cover state, geometry, resize bounds, and chat lifecycle. The earlier September 6 pure Swift checkpoint passed 247 tests in 34 suites, with no failures, skips, or compiler warnings ([test log](../../outputs/Whoosh-Pure-Swift-Test-Log.txt)); it does not prove live rendering or capture exclusion.
