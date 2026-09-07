# Recording library

The **Recordings** button beside the window controls opens an animated left sidebar. Select a meeting to play its first available video in the main view. The native player provides playback, seeking, volume, and full-screen controls. Meetings with several video views or recording segments offer a video picker. Closing the library stops inline playback.

The player surface follows the video's decoded aspect ratio as the window resizes, retaining the entire frame. Zoom may include black space inside its saved composite layouts. **Space** plays or pauses the recording in the active player window; typing in search and modified shortcuts retain their normal behavior. **Copy link** in the player header or a recording row's context menu copies Zoom's share page (or its video page when no meeting-wide share URL is returned). Existing Zoom sharing permissions and passcode requirements apply.

**Copy link** and **Save video…** sit immediately beside the recording title as matching neutral icon buttons, with the date below. The Chat heading and toggle remain at the right edge. Long titles truncate to keep both actions visible in narrow players.

Double-click a recording to open its own resizable player window, or choose **Open in New Window** from the row's context menu. The current video view, position, and play/pause state carry over from the library. Each meeting occurrence reuses its existing window when opened again. Clicking the already active row does not restart it. Dedicated windows keep their own playback state and remain open when the main library closes; closing a player stops its recording. Changing accounts or quitting closes every recording window.

Dedicated players can be repositioned by dragging the title/date area or the empty background around the video, including when the window is inactive. Playback controls and chat keep their normal interactions. The inline library retains its existing window behavior.

Selecting a recording already open in a player window brings that window forward. Refreshing the recording list leaves dedicated players open. If the inline player is using **Download to play**, opening its window transfers the temporary local video instead of retrying the cloud stream; the file is removed when that player closes.

The first load searches the current calendar month and the previous two months. **Load earlier month** continues backward, including through empty months. Search filters the meetings already loaded; it does not search the entire Zoom account. **Refresh recordings** reloads recent metadata. Dates, titles, loading failures, and meetings with no completed video remain visible in the library.

Switching video views keeps the current elapsed position, pause state, and playback speed. A shorter view clamps to its final frame. The previous frame stays visible while the new view's metadata loads, and playback resumes after an exact seek. Rapid switches carry the original position through unfinished loads. The three most recently used views stay warm for the current meeting, with an 8 MiB memory range cache per view; changing meetings, closing the library, or changing accounts discards that cache.

The visible **Speed** menu beside **Video** offers 0.5×, 0.75×, 1×, 1.25×, 1.5×, 1.75×, 2×, 2.25×, and 2.5×. Choosing a speed does not start a paused recording. The setting applies when pressing Space or the native play button and follows the recording when it opens in a dedicated window. The native player's speed menu and the visible menu stay synchronized.

## Recorded chat

The **Chat** bubble uses the same control as live meetings and opens a pane on the right of the inline or dedicated player. Its glass extends to the top behind the shared header; the bubble toggles it closed without a separate close button. It displays the meeting's saved Zoom CHAT text file, highlights the latest messages at the current playback position, and scrolls along as playback advances or seeks backward. Scrolling manually pauses automatic following; **Follow playback** returns to the current messages. Clicking a message timestamp seeks the current video without changing its play/pause state. The pane overlays narrow players and sits beside wider players.

Web addresses in saved chat are underlined, clickable links that open in the default browser. Message text remains selectable, and URLs keep their complete query parameters and fragments.

Chat loads only when opened, remains in memory, and moves with a dedicated player window. Account changes and dedicated player window closure cancel pending chat work. Downloads use the existing recording authorization, validate text responses, and enforce an 8 MiB limit. Parsing and merging run off the UI actor. Files from the same meeting are merged without duplicating overlapping exports or losing identical repeated messages within one export.

Zoom chat timestamps measure elapsed meeting time, so synchronization adds the selected video's `recording_start − meeting.start_time` offset to the playback clock. This mapping is inferred from [Zoom's documented chat timestamp baseline](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061246). Separate recording segments use their own start times. Zoom does not provide enough timing data to reconstruct pauses or edits within a single MP4; a timing note appears when the recording's wall-clock span substantially exceeds its video duration. [Pause/resume behavior](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0062627), [Zoom staff on recording duration](https://devforum.zoom.us/t/duration-of-recording-file/53390).

Saved cloud chat is optional and contains public messages captured while cloud recording was active, when chat saving was enabled. Recordings without that attachment show **No chat saved**. This is the meeting's recorded conversation, not a live chat composer or Zoom Team Chat. [Zoom's cloud chat requirements](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0067312).

## Zoom setup

This library uses the signed-in user's Zoom cloud recordings. It needs a Pro or higher account with cloud recording enabled. Recordings started by a co-host appear in the host's library. Recordings saved only to a computer are not fetched from this API. [Zoom recording requirements and locations](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0058006).

Add **`cloud_recording:read:list_user_recordings`** to the existing user-managed General app in Zoom Marketplace. Keep the existing public-client OAuth configuration and its other scopes. Then reconnect Zoom in Zooom's settings so the newly issued authorization includes recording access. Refreshing an old access token cannot add a permission that was not previously granted. See [Zoom setup](Zoom-Setup.md) for the existing native sign-in configuration and [Zoom's scope reference](https://developers.zoom.us/docs/integrations/oauth-scopes-granular/) for the recording scope.

The implementation calls `GET /v2/users/me/recordings`, preserving the host's meeting-occurrence UUID and individual file IDs. It exhausts opaque pagination tokens within each UTC month, deduplicates occurrences, and sorts the results newest first. Zoom limits recording queries to one month per request; pagination tokens expire after 15 minutes. Only completed MP4 files with a supported download address are playable. Audio-only recordings, speech transcripts, and local computer recordings are outside this feature. [Zoom Meetings API](https://developers.zoom.us/docs/api/meetings/), [Zoom staff on query windows](https://devforum.zoom.us/t/zoom-meeting-api-returns-incorrect-dates/116887).

## Streaming and downloads

Selecting a video starts an authenticated media request through `AVAssetResourceLoader`, which supplies bounded byte ranges to `AVPlayer`. Zoom OAuth tokens are sent in authorization headers. The transport validates range responses and media types, follows HTTPS download redirects, and removes Zoom authorization when redirecting to a CDN outside Zoom's trusted hosts. It uses ephemeral HTTP sessions and does not put bearer tokens in media URLs. [Zoom download authentication and redirects](https://developers.zoom.us/docs/api/using-zoom-apis/).

Zoom documents its download URL for file retrieval; its `play_url` opens Zoom's hosted web player. Availability of byte ranges must be verified against the particular recording. If streaming fails, **Download to play** retrieves the complete MP4 to a temporary local file and then opens it in the same player. **Save video…** opens in the user's Downloads folder and lets them choose a different location, with cancellation and **Show in Finder** feedback. Temporary playback files are removed when playback is stopped or replaced. Metadata and media are cleared when the connected account changes. [Zoom staff on independent playback](https://devforum.zoom.us/t/meeting-recording/37588).

Live-account setup and verification on September 6, 2026: added the recording-list scope to the existing user-managed Zoom app and reauthorized the native PKCE connection. The live library returned 91 recordings across the first three months and 125 after loading June. Both a short recording and a 59-minute recording streamed through the native player. Switching Active speaker → Gallery view → Active speaker preserved the paused position at 32:58, with the return view served from the warm cache. **Save video…** successfully saved a valid MP4 at an explicit destination; the final installed build opens its save dialog in Downloads. The updated app is installed at `~/Applications/Zooom.app` with its existing Developer ID identity. Streaming failures and download fallback remain covered by fixtures rather than an induced live-account failure.

Validation on September 7, 2026: 467 tests in 62 suites passed with the real Zoom SDK enabled, including chat parsing, authenticated transcript loading, clock synchronization, safe share-link selection, keyboard event handling, native player-window lifecycle tests, and real synthetic-video tests for window/chat resizing, active-row clicks, position transfer, chat seeking and window transfer, and temporary-file ownership. The signed app passed strict signature verification with 97 embedded Mach-O images. Sign-out also reconciles actual saved status if an old Keychain item's cleanup fails after the active credential was already removed; this has memory-backed regression coverage.

Live dedicated-window acceptance: a single click on the active recording left its native player paused at 21:30. Double-clicking the same row opened a separate titled window, preserving the Screen and speaker view, 21:30 position, and paused state. Its video frame and native playback controls were verified in the installed app.

Live recorded-chat acceptance: the installed app fetched a real meeting's saved chat into the right pane of a dedicated player. Clicking the 28:42 timestamp sought the paused native video to 1,722 seconds, highlighted the message, and scrolled it into view. Playback across 31:21 automatically advanced the highlight and scroll position. Manual scrolling revealed **Follow playback**, which restored the current message when clicked.

Live player-controls acceptance: **Copy link** worked from both the recording row context menu and the dedicated player's header, producing a Zoom `/rec/share/` URL without an OAuth access token. Space paused inline playback and toggled play/pause in the dedicated window. The transcript's glass reached the top behind the shared header, with no separate close button, and the bubble toggle closed and reopened it. The Screen and speaker video used its decoded aspect ratio in both layouts, with the complete frame visible.

Live speed acceptance: the visible menu offered all seven speeds and transferred a 1.5× selection from the library into a dedicated player. Selecting 2× while paused preserved the 25:44 position and paused state. Changing speed through the native player updated the visible menu. Switching Active speaker to Screen and speaker retained 1.5×, 25:44, and pause; the menu remained visible alongside the open chat pane.

Extended-speed acceptance: 2.25× and 2.5× appear in the installed speed controls. A live recording played at both settings, and changing to 2.5× through the native control updated the visible menu. Selecting 2.25× while paused kept the 50:04 position. All 17 playback tests passed, including paused-position and resume checks at both added speeds.

Title-action layout validation: native offscreen fixtures at 900 and 439 points confirmed the title, adjacent Copy/Save actions, date, and trailing Chat controls fit with chat open; a 900-point fixture also covered chat closed. All 25 existing playback and player-window tests passed. The change is queued for the combined updater build.

Chat-link validation: 23 focused tests across link detection, recorded-chat synchronization, and player windows passed with the real Zoom SDK enabled. The seven link tests cover punctuation, Unicode ranges, long query parameters and fragments, literal Markdown, bare www addresses, and non-web schemes.

Live chat-link acceptance: the installed app displayed the real transcript's web addresses as underlined native links. Clicking a link in the highlighted message opened the exact destination in Chrome. Playback remained paused; the player's previous 50:04 position, Active speaker view, 2× speed, and chat following were restored after verification.

## Isolated worktree checks

Run feature tests from the recordings worktree with an isolated SwiftPM build directory and caches. The fixture clients do not access Zoom or Keychain. Disabling the proprietary SDK makes these checks independent of a live meeting runtime; disabling loopback tests also avoids unrelated OAuth listeners.

```sh
WHOOSH_ZOOM_SDK_PATH=/nonexistent \
WHOOSH_TEST_LOOPBACK=0 \
CLANG_MODULE_CACHE_PATH=/tmp/zooom-recordings-checks/module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/zooom-recordings-checks/module-cache \
swift test --disable-sandbox \
  --scratch-path /tmp/zooom-recordings-checks/build \
  --cache-path /tmp/zooom-recordings-checks/spm-cache \
  --filter 'RecordingLibraryTests|ZoomRecordingsTests|RecordingMediaLoaderTests|RecordingPlaybackTests|RecordingPlayerWindowTests|ZoomRecordingChatTests|RecordingChatLoaderTests|RecordingChatModelTests'
```

`RecordingLibraryTests` covers UTC calendar boundaries, leap years, pagination exhaustion, duplicate occurrences, descending order, empty months, repeated tokens, cancellation, and account clearing while a request is in flight. `ZoomRecordingsTests` covers decoding, scope failures, authentication, and API requests. `RecordingMediaLoaderTests` also decodes a real MP4 video frame through AVFoundation with authenticated fixture ranges and an expired-token refresh.

`RecordingPlaybackTests` exercises real native players with synthetic local videos: paused timestamp continuity, rapid switches during preparation, playback-speed preservation, shorter-view clamping, source reuse and eviction, switching meetings, and dismissal during a switch. Media cache tests verify adjacent and overlapping byte ranges, the memory limit, and invalidation.

Launch with `--preview --recordings-preview` to inspect the library with clearly labeled sample meetings. Preview never requests recording media or reads the live cloud library.

The existing `Scripts/test.sh` writes caches into `../work`, and `Scripts/build-app.sh` writes the signed application into `../outputs/Zooom.app`. Sibling worktrees therefore share those destinations. Use the isolated command above while other tasks are building. Coordinate release packaging and installation separately so a worktree does not overwrite another task's generated or installed app.
