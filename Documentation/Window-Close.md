# Main-window close control

September 7, 2026: the quiet top-left close button explicitly hides the retained main window when no meeting is active. It stops recording playback in that window and cancels any outstanding main-window presentation request before hiding. The menu-bar app remains running and can reopen the same window. The close control accepts the first click in an inactive window and does not initiate window dragging.

The main window does not rely on the framework delegate accepting `window.close()`. Both its custom button and the close delegate route through the same hide behavior; Command-W uses the button action. During a meeting they show the existing leave confirmation and keep the window and call intact.

The native welcome fixture was clicked at the actual top-left dot. Its window became invisible and stayed hidden in the settled sample, retaining window number 45720. The standard Open Zooom action restored that same window. Evidence: [close](../../work/close-button-click-verified.json), [reopen](../../work/close-button-reopen-verified.json). The combined suite passed 470 tests in 63 suites, including close behavior with a framework delegate that would veto closing, repeated clicks, Command-W, and active meeting protection.

Logs: [full tests](../../work/zooom-close-button-full-tests.log), [build](../../work/zooom-close-button-build.log), [install](../../work/zooom-close-button-install.log). Native preview verification is separate from installed-app UI verification.
