# Opening Zoom links

In **Yap → Settings → General → Meeting links**, choose **Yap** or **Zoom Workplace** under **Open Zoom links with**. This reads and updates macOS’s handlers for `zoommtg` and `zoomus`; opening Settings never changes a default. Zoom Workplace must be installed to select it. Yap selects its currently running app bundle, so use the installed copy rather than a temporary development build.

Ordinary `https://…zoom.us/j/…` invitations still open the browser. The Zoom page’s **Open Zoom** / **Launch Meeting** action opens the selected app. This setting does not change your default browser or intercept all HTTPS links. A browser may ask you to allow opening an external app.

Yap opens supported invitations in its join sheet with the meeting ID and passcode preserved. Confirming Join uses your saved display name with the microphone muted and camera off. An incoming invitation does not replace an active meeting. Native links can also be pasted into **Join with a link…**.

Links for unsupported actions, such as Zoom sign-in or starting as host, offer an explicit **Open Zoom Workplace** action. That action targets the official app directly, avoiding a loop through the default handler. Existing `yap://join?url=…` invitations continue to work.

The selector refreshes from macOS when Settings appears and when Yap becomes active. Changes use Apple’s [NSWorkspace default application API](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopenurlswithscheme:completion:)), including any macOS consent prompt. If the operation fails or is cancelled, Yap attempts to restore prior handlers and then displays the actual current state, including mixed defaults if restoration could not finish.

Tests inject handler reads, writes, and app launching, so they do not change the test machine’s defaults. They cover successful switching in both directions, cancellation and partial failures, missing apps, official-app forwarding, native invitation parsing, passcode encoding, and incoming-link join behavior.
