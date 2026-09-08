# User guide

This guide covers **Yap 0.1.3 (build 4)**, the signed and notarized candidate for the first public installer. Independent package checks, the exact-source security scan, managed sign-in, recording playback and a solo hosted meeting passed within the recorded native scope. Yap 0.1.3 was submitted to Zoom on **September 7, 2026 (Pacific)** and is in functional review; approval and broader acceptance remain pending. There is no public download. Superseded 0.1.2, 0.1.1 and 0.1.0 drafts should not be installed. Check the [release status](https://github.com/grinich/yap/blob/main/Documentation/Distribution.md) for availability; the sample interface and source remain available.

## Install and connect

Yap requires **Apple silicon and macOS 26 or newer**. When the release is published, download **Yap.dmg** from the project's [releases](https://github.com/grinich/yap/releases), open it, drag **Yap.app** to **Applications**, eject the disk image and launch Yap from Applications. **Yap-macOS.zip** is the alternative app archive; expand it and move Yap.app to Applications. Both downloads have a matching `.sha256` file. The current **0.1.3 (build 4)** artifacts remain an unpublished draft. Authorized reviewers receive a private installer through Zoom's review channel; it has the same verified bytes as the draft DMG. [Artifact and checksum details](https://github.com/grinich/yap/blob/main/Documentation/Releases.md#first-release-v013).

Quit any older app before switching to Yap. Keep it until you have verified the new app's account access; supported saved accounts and preferences can migrate through normal macOS permissions. See [migration details](https://github.com/grinich/yap/blob/main/Documentation/Bundle-Identity.md). For the SDK-free sample interface and personal developer setup, see the [source README](https://github.com/grinich/yap#try-yap).

Open **Settings → Connections → Your meetings → Zoom → Sign in with Zoom**. The browser opens Zoom's sign-in and consent page. Approve access with the account you want to use, and return to the app. The app does not ask for your Zoom password directly.

Builds with the managed connection already know the project's public client and authorization service. If a saved personal developer configuration is active, the developer menu offers **Use Yap sign-in** to switch to the bundled managed connection. A build that requires a configuration before sign-in needs the [personal Zoom setup](https://github.com/grinich/yap/blob/main/Documentation/Zoom-Setup.md). The developer menu alone does not indicate which mode is active. Do not use another person's SDK secret. See [Privacy](https://github.com/grinich/yap/blob/main/PRIVACY.md) for the two connection modes and their data flows.

## Join or start a meeting

- Choose **Join with a link…**, paste your Zoom invitation, check your display name, and choose **Join meeting**. If an invitation contains several meeting links, choose the one you intend to join.
- Choose **Start a meeting** to create a meeting using the connected Zoom account. Hosting and admission remain subject to that account's Zoom permissions.
- Meetings begin with the microphone muted and camera off. Use the meeting controls to enable them when you are ready; macOS may request permission.
- Use the chat and participant controls to open their side panes. Choose Share to select the window or display you want to share, and use **Stop sharing** to finish.
- When you leave, the app stops your microphone, camera, and sharing. Hosts can separately choose **End for everyone**; that ends the call for the other participants too.

An optional setting lets the app handle Zoom's native meeting links. Unsupported link types offer an explicit option to open Zoom Workplace. Access to meetings outside the developer's account depends on the applicable Zoom approval and authorization.

## Add your calendar

Google Calendar is optional and currently requires a Google Desktop OAuth client JSON; the app does not bundle a public Google client. Follow the [Calendar setup instructions](https://github.com/grinich/yap/blob/main/Documentation/GoogleCalendar.md), choose **Import Google desktop client…** in Settings, then **Sign in with Google**. Complete browser consent and select the calendars to display. The project consent name is Yap and its desktop-client/project display names are Yap for Mac; its status remains Testing, with no public Google rollout or verification approval asserted. Calendar can stay disconnected while reviewing Zoom features.

The agenda shows upcoming events with supported Zoom links. Join from the agenda or the menu bar. Calendar access is read-only: the app does not create events, invite people, or change your RSVP. You can deselect calendars or disconnect the account in Settings.

## Find and watch a recording

Choose **Recordings** beside the window controls to open the library. Select a meeting to play an available video. Selecting the same row again keeps the current position. Double-click a recording to give it its own window; its video layout, speed, timestamp, and paused or playing state carry over.

Search by title or a date such as `Aug 31`, `8/31`, or `last Monday`. Search covers the months already loaded. Choose **Load earlier month** to include older recordings. Reopening the library refreshes loaded months without restarting the selected video.

The layout menu changes among the video views supplied by Zoom. The speed menu changes playback speed without losing your place or starting a paused video. Use **Copy link** beside the title to copy Zoom's sharing page, or **Save video…** to save an MP4. The save sheet starts in Downloads and lets you choose another location. Existing Zoom sharing permissions still apply.

If streaming cannot start, **Download to play** can retrieve a temporary copy for playback. Cloud recordings require an account with cloud-recording access; computer-only recordings and audio-only files are not included in this player.

## Read chat and transcripts

Open the right pane and choose **Chat** or **Transcript**. These tabs use the saved files attached to the Zoom recording, when available. They do not create a new transcript or a live chat conversation.

The pane highlights messages or passages as the recording plays. Scrolling manually pauses following; choose **Follow playback** to return to the current point. Click a chat timestamp, transcript passage, or transcript timestamp to seek without changing the video's paused or playing state.

Search the transcript to find words or speakers. The previous and next controls, or Return, move between matching passages and seek the video. **Copy passage** includes a timestamp and speaker. **Copy transcript** copies the whole transcript, and **Download transcript** saves UTF-8 TXT or WebVTT. Export includes all passages even when a search is active.

Some recordings have no saved chat or transcript. Cloud settings, completion of Zoom's processing, and account permissions determine which files exist. Pauses or edits inside a recorded video may also limit exact timing alignment.

## Keyboard shortcuts

| While watching a recording | Shortcut |
| --- | --- |
| Play / pause | Space |
| Skip backward / forward | ← / → |
| Cycle playback speed | S |
| Cycle video layout | V |
| Toggle fullscreen | F |
| Show / hide recordings | ⇧⌘R |

Left and Right skip ten seconds at a time. Recording shortcuts apply to the active player and leave search fields and text editing alone.

## Disconnect or remove the app

Leave active calls, then use **Settings → Disconnect Zoom** and disconnect Calendar if connected. Disconnect removes the app's local authorization and clears associated app playback and caches; personal developer configuration can remain. To revoke the provider's server-side grant too, remove the app from Zoom's or Google's connected-app settings.

Quit the app and delete it from Applications to uninstall. Files you explicitly exported stay where you saved them until you delete them. Deleting the app does not remove every preference or SDK-owned item. The [Privacy policy](https://github.com/grinich/yap/blob/main/PRIVACY.md) explains storage, retention, and deletion choices.

## Troubleshooting

- **Sign-in is unavailable:** check the build's connection mode and the provider's approval or account restrictions. After a newly required permission is added, disconnect and sign in again so consent includes it.
- **No recordings appear:** confirm you signed into the recording host's account, that cloud recording is available, and that the relevant month is loaded. A co-host's recording normally belongs to the host's library.
- **No chat or transcript appears:** Zoom must have saved that attachment. The app shows an availability or retry message when the file is absent or cannot be loaded.
- **Camera, microphone, or sharing fails:** check the app's permissions in macOS System Settings and any meeting restrictions. Keep another way to join an important meeting during the preview.

For help with a reproducible problem, see [Support](https://github.com/grinich/yap#support-and-feedback). Send private account or security matters through the contact in the [Privacy policy](https://github.com/grinich/yap/blob/main/PRIVACY.md), rather than a public issue.
