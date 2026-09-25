# Yap: end-to-end functional test plan

Prepared September 14, 2026 (Pacific). This English test plan covers Yap's native Mac integration, each requested OAuth scope, and the roles and sample data needed to exercise them. **These are test instructions and expected results, not a record of completed tests.** Use synthetic content and keep account credentials, meeting invitations, passcodes, tokens and private evidence in the review portal's private fields.

## Domain migration addendum — September 25, 2026

The current source configuration moves the authorization service to `https://auth.yap.enterprises` and its Zoom redirect to `https://auth.yap.enterprises/oauth/zoom/callback`. It keeps the same OAuth client and scopes. The build comparison below records the earlier review candidate; it is not the identity or test record of a newly packaged migration build. Record the new version/build, source commit, installer hash, service deployment and saved Zoom redirect configuration before running these checks.

1. Run Z01 and X01–X03 on the newly packaged app. Confirm its session, token and SDK-signature requests stay on `auth.yap.enterprises`, Zoom returns to the exact new callback, and the native `yap://oauth/zoom` handoff completes. Record only public origin/path information, never codes, handoffs, tokens or state.
2. Repeat fresh sign-in and token refresh using an existing signed app that contains `meeting-auth.mgrinich.workers.dev`. Its requests must continue working on that origin, with its original HTTPS callback; the service must not substitute the new callback or require an application update to finish sign-in.
3. Confirm cancellation, an expired handoff, and an authorization response containing the other build's callback do not connect the app. The native tests cover strict callback matching independently of these live checks.
4. Verify Google Calendar still uses the canonical bundled Google desktop client and its existing flow. The Zoom domain migration must not introduce Google developer configuration or alter Google scopes.

## Choose and record the exact test build

The next review target is **Yap 0.1.7, build 8**, with the revised managed HTTPS authorization flow. Its final source commit, installer hash and completed acceptance results must be supplied with the packaged candidate; they are not established by this plan. The released baseline remains **Yap 0.1.6, build 7**, tag `v0.1.6`, source `d418d646f03311bf8aa7826a46aab30f03cc9888`. The [0.1.6 handoff](ZoomReview-0.1.6.md) documents that earlier installer's hashes and validation only. The [user guide](../Services/zoom-auth/site/guide.md) supplies baseline feature instructions; the [managed setup](Zoom-Setup.md#upcoming-managed-authorization-flow) explains the revised sign-in. The earlier [0.1.3 submission](ZoomReview.md) is historical evidence for different bytes.

| Configuration | Released 0.1.6 | 0.1.7 / build 8 review target |
| --- | --- | --- |
| OAuth client ID | Public client `_Xz_EnBNS3OPtUmqZ1og3A` | Confidential production client `UHoml3aIQpy86gZeijjfpQ`; its secret stays on the server. Verify the ID against the saved portal configuration and actual authorization request |
| Zoom OAuth return | HTTP loopback at `127.0.0.1`, with a temporary local listener | Source configuration: `https://meeting-auth.mgrinich.workers.dev/oauth/zoom/callback`; a separate encrypted `yap://oauth/zoom` handoff returns to the native app |
| Installer identity | Existing immutable 0.1.6 installer | Version/build 0.1.7 / 8; final commit, installer URL and checksum required after packaging |
| Test status | This plan has not been executed against every feature | Revised flow exists in source; this plan asserts no completed production deployment, packaged-artifact validation or live authorization acceptance |

Client IDs above are public configuration, not credentials. A website or service change alone does not alter the OAuth client and callback logic inside the already signed 0.1.6 application. Before handing over a replacement candidate, record its version/build, source commit, SHA-256, installation URL, authorization landing page, HTTPS callback, service deployment and expected client ID in the private run record. Run the authorization cases against that exact installed build before the remaining tests.

The separately configured development Worker and client credentials are for development tests. For this initial production review target, verify the installed artifact uses the production ID and production service origin above; successful development authorization is not a substitute. The user never needs the production or development client secret.

## Accounts, roles and access

Yap has **no separate Yap account, password, paid Yap subscription, tenant administrator or application role system**. Users authorize their own Zoom account, with an optional separate Google connection. Host, co-host, attendee, waiting-room participant and webinar roles come from Zoom. App developer credentials are not reviewer login credentials and are not needed in the official installer.

Two reviewer-owned Zoom accounts can exercise basic authorization, hosting, joining, audio, video and chat. They cover the complete Zoom scope set only if the recording owner's account has cloud-recording access and the prepared files below. An empty or Basic-only account cannot prove recording playback. A third endpoint is needed to verify private-message isolation and a waiting room while two participants are admitted. This describes a technically usable arrangement, not confirmation that reviewers agreed to supply their own accounts or that required fixtures have been provisioned. Resolve that access arrangement privately before handing over the plan as ready to run.

| Alias / role | Required access and use | Login / provisioning status |
| --- | --- | --- |
| **A — recording owner and host** | A consenting Zoom user with cloud recording enabled, adequate storage and completed sample video/chat/transcript files; starts meetings in Yap. Confirm its actual plan and cloud-recording capability. | Reviewer-owned qualified account or an approved dedicated test arrangement; no account supplied in this document |
| **B — independent participant / external host** | A different consenting Zoom user. Joins A's meeting in Zoom Workplace, then runs Yap on a second supported Mac to test the reverse direction. Hosts a separate meeting outside A's account for external-meeting coverage when access is available. | Reviewer-owned account; actual authorization/external access must be checked |
| **C — unintended recipient / waiting-room participant** | A third independent endpoint using Zoom Workplace. Remains admitted for private-message isolation, and later joins a waiting room. A guest can serve this role when the meeting allows guests. | Dedicated endpoint or guest; no separate Yap login required for this role |
| **B as co-host** | In a separate meeting hosted by A in Zoom Workplace, A promotes B using Zoom's host controls; B tests the restricted recording controls in Yap. | Conditional on A's account settings; record unavailable separately from a pass |
| **G — optional Google Calendar user** | Consenting Google account with two selected test calendars and the prepared events below. No Google Workspace administrator role is needed for normal user consent; organization restrictions may require its administrator's approval. | Reviewer-owned account or approved dedicated access; Google remains unverified and its warning/user cap may affect access |
| **Optional webinar roles** | Licensed webinar organizer plus panelist and attendee endpoints, only when testing those SDK-provided chat audiences | Webinar entitlement and sessions not supplied; standard meetings do not prove webinar interoperability |

Yap itself has no 2FA. Zoom or Google may require password, SSO, email verification or a second factor. Reviewers using their own provider accounts complete those challenges themselves. If a dedicated test identity is arranged, its private handoff must identify the owner, login method, entitlement, permitted use, access expiry, and a workable way for the reviewer to complete any required factor. Do not rely on the developer's personal session or silently weaken account security. Never include developer secrets, provider access/refresh tokens, authentication codes or recovery codes in this public plan.

Zoom's published guidance asks for instructions for all relevant user roles, scope coverage and usable paid/seeded access where needed; it distinguishes application test logins from Zoom account credentials. Since Yap has no application account, state that fact in the portal and describe the provider accounts and fixtures actually available. Do not enter fabricated Yap credentials. [Zoom test-plan guidance](https://developers.zoom.us/docs/distribute/app-submission/common-rejection-issues/), [test-account fields](https://developers.zoom.us/docs/build-flow/publish/).

## Environment and synthetic fixtures

Use two Apple silicon Macs running macOS 26 or newer to test both A and B in Yap, plus C's independent Zoom endpoint. A single Mac with a second Zoom client can demonstrate some interactions but does not replace independent installation and authorization checks. Record the OS versions, Yap version/build, Zoom Workplace versions and tested hardware. Use headphones to prevent feedback. Allow camera, microphone and screen/system-audio access only through normal macOS prompts for the test.

Prepare the following before review; record actual dates and names in the private run record. **These fixtures have not been created by writing this document.**

| Fixture | Preparation |
| --- | --- |
| Live meeting A | Created by A with Yap during Z02. Use a passcode and waiting room where allowed; copy its invitation privately to B and C. Enable permitted chat/file-transfer options for the positive cases. |
| External meeting B | B creates a separate test meeting under a different Zoom account. Retain its invitation privately. Confirm that both accounts may use the app for the intended review scenario. |
| R1 — complete cloud recording | A owns a completed synthetic meeting called **Yap Review — Complete** in the current month. Include a playable MP4, saved chat file and spoken VTT transcript. Include the spoken phrase **Yap review transcript sample** and a chat message **Yap review chat sample**. Record actual file types and duration. If multiple video views are expected, create and verify those views in Zoom first. |
| R2 — missing text | A owns **Yap Review — Video Only**, with a completed MP4 and no saved chat/transcript. Verify the absence before testing the empty states. |
| R3 — older recording | An owned completed recording in an earlier month for **Load earlier month**. Do not backdate or imply an older fixture exists. If unavailable, provide an authorized account with one or record this case blocked. |
| Independent library | B has its own distinct recording, if its plan permits, so A/B library isolation can be checked. A's R1 must not become B's owned recording merely because B attended it. |
| Screen/audio/photo content | Two plainly labeled synthetic windows, A and B; a short local sound clip; camera feeds showing only consenting participants or sample objects; a harmless background image. |
| Chat attachments | A short `yap-review.txt` containing **Yap review attachment sample**, plus a sample image. Use a larger harmless allowed file only if needed to observe cancellation. Compare the saved file to the sent file. |
| Optional calendars | G creates **Yap Review Main** and **Yap Review Secondary**, with today's timed Zoom event, tomorrow's Zoom event, an all-day event, a non-Zoom event, and a second-calendar Zoom event. Use the private test meeting URLs and dates relative to the test day. Include two invitation links in one event to test explicit choice. |

Cloud recording is an account entitlement, not a Yap purchase. For complete coverage, verify a licensed host with cloud recording and transcript generation enabled, sufficient storage, and completed processing. Account/group policies may restrict features. A Basic account remains useful for a denied/unavailable-recording case. Do not make the review wait for newly recorded files: prepare R1–R3 in advance and use the live recording case separately. [Cloud-recording prerequisites](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0062627), [audio-transcript settings](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0065911).

## Scope coverage

All three Zoom scopes are requested in the bundled managed sign-in. Recording use is optional for a person, but its scope is part of the current authorization request; no optional Zoom scope is silently omitted from this plan. Google authorization is a separate optional flow requesting both read-only scopes below.

| Scope / capability | User action and data use | Test cases |
| --- | --- | --- |
| `user:read:zak` | Reads only the signed-in user's ZAK at `/v2/users/me/zak` to establish and authorize that person's native Meeting SDK identity | Z01, Z02, Z03, X01–X03 |
| `meeting:write:meeting` | Creates an instant meeting for the signed-in user at `/v2/users/me/meetings` when **Start new meeting** is selected | Z02, Z03 |
| `cloud_recording:read:list_user_recordings` | Lists the signed-in user's recording metadata/files at `/v2/users/me/recordings`; returned download URLs supply video and available saved chat/transcripts | R02, R03, X01–X03 |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | Lists G's calendars for selection | G01, G03 |
| `https://www.googleapis.com/auth/calendar.events.readonly` | Reads events from selected calendars for the agenda/menu-bar schedule and supported meeting links | G02, G03 |
| Native SDK meeting capabilities | Audio/video, chat/files, sharing, hand state, participant views, camera effects and live cloud-recording controls follow Zoom's user/meeting permissions; they add no REST OAuth scope | M01–M07, R01 |

The recording transcript tab reads an available VTT recording file; Yap does not call a separate meeting-transcript REST endpoint. No admin/master scope, calendar-write scope, webhook, RTMS or bot is required. Source mapping: [Zoom scopes](../Sources/YapMeetings/ZoomCredentials.swift), [Zoom REST client](../Sources/YapMeetings/ZoomAccountClient.swift), [managed scope validation](../Services/zoom-auth/src/index.ts), [Google scopes](../Sources/YapCalendar/GoogleTokenStore.swift).

## Execute in order

For every case, record **Not run**, **Passed**, **Failed**, or **Blocked**, the exact build and date, accounts by alias, observed result, and a private evidence reference. An unavailable prerequisite is Blocked, not Passed. A fixture or source test is separate from live delivery. Redact private URLs and credentials in screenshots; use synthetic content for recordings.

### Z01 — installation and Zoom authorization

1. A and B each download the specified installer, copy Yap to Applications, eject the DMG, and launch the installed copy. Open About and confirm its exact version/build. Do not run the sample interface or import developer credentials.
2. Leave Google disconnected. Open **Yap → Settings → Connections → Sign in to Zoom**. A signs into A's Zoom account in the browser and reviews the consent page. B repeats independently with B's account.
3. Confirm the actual authorization request uses the client ID recorded for this candidate. Record only the public client ID and callback origin/path, with all state, codes and tokens omitted. For 0.1.7, confirm the exact configured HTTPS callback, then choose **Open Yap** and verify the encrypted native handoff completes in the initiating app. No plaintext OAuth code, verifier or token should appear in the custom-scheme URL. **The released 0.1.6 loopback flow cannot pass this new-candidate HTTPS callback check.**
4. Confirm each app reports its Zoom connection and can perform an authenticated action without importing a configuration. Quit and relaunch; the correct account remains connected or a meaningful provider error is shown.
5. After disconnecting, repeat once with browser cancellation or declined consent. Confirm there is no false connected state and another explicit sign-in can succeed. Completing a cancelled or older authorization must not replace a newer account connection.

**Expected:** each user authorizes their own account through Zoom; the app never asks for a Zoom password directly. The observed client/callback match the chosen build, denied consent grants no access, and a successful fresh own-user ZAK request enables subsequent SDK operations. Capture a redacted consent/connected-state pair and any failure text.

**0.1.7 entry-path check:** verify the deployed integration page at the candidate's production `/connect` URL, then start from it in a browser without a pre-existing Yap session. Follow **Connect Zoom in Yap** and the advertised installation/open/connect path, and complete the same flow. Repeat with Yap already installed. Check the download link resolves to the intended current candidate or clearly identifies the older baseline; an older app must not be represented as supporting the new entry route. Source implementation of the page is not evidence of a successfully deployed browser-to-app run.

### Z02 — host identity and meeting creation

1. In A's Yap, choose **Start new meeting** once. Observe startup and copy the new invitation privately.
2. B opens the invitation in Zoom Workplace; A admits B if a waiting room is enabled. C joins as an additional participant.
3. Compare the meeting shown in both clients. Confirm A has host authority; A's meeting creation used A's account rather than B's. Use Zoom's normal account/meeting UI to corroborate ownership where available.
4. With **Join quietly** on (the default), verify actual entry conditions: microphone muted, camera off, and no cloud recording started automatically. Confirm the requested waiting-room/recording defaults against the account's enforced behavior, recording any policy override.
5. Do not close this meeting yet; use it for M01–M07 and R01. Test a second hosting attempt only after leaving the first meeting.

**Expected:** one explicit host action creates one meeting for A and joins it as A. Denied hosting, startup failure or ambiguous creation must show an error rather than claim a working call. This exercises `meeting:write:meeting` plus `user:read:zak`; a static host badge alone is not proof of correct account attribution.

### Z03 — joining, role reversal and invitations

1. After finishing A's call, B creates a separate authorized test meeting in its own account. A pastes B's invitation into **Join with a link…**, checks the display name and joins.
2. Confirm B remains host, A is a participant, and A can perform the permitted media/chat actions below without acquiring host-only controls. Repeat with B using Yap and A using Zoom Workplace.
3. On a test Mac, note the existing default meeting-link handler. If permitted, choose **Yap → Settings → General → Meeting links → Open Zoom links with → Yap**. Open the ordinary Zoom invitation in the browser and choose its open/launch action. Confirm Yap's join sheet preserves the meeting and passcode; join only after the explicit confirmation.
4. Deliver another invitation while already in a call. Confirm it does not silently replace the active meeting. Restore the previous link handler after testing. Try an invalid invitation and an unsupported native link; verify a useful error or explicit **Open Zoom Workplace** option without a redirect loop.

**Expected:** the signed-in user's SDK identity and meeting permissions are preserved in both directions. Cross-account results are recorded separately from same-account meetings. External authorization restrictions are a blocked prerequisite, not evidence that external meetings work.

### M01 — two-way audio/video and native device controls

1. With **Join quietly** on (the default), confirm Yap's microphone/camera start off in A's meeting with B admitted. A then explicitly enables its microphone and camera; B verifies actual audible synthetic speech and changing video. Reverse the direction.
2. Use the native **Microphone**, **Speaker** and **Camera** menus to choose available devices. Test the microphone and speaker, then stop each test. Adjust speaker volume; toggle automatic microphone volume before testing manual adjustment. Use **Refresh devices** after connecting another device, if available.
3. Mute/unmute and turn each camera off/on. B confirms the media stops and resumes as indicated. Deny a permission on a clean test profile or test a missing device, then restore normal access through macOS and retry.
4. In **Settings → General**, turn **Join quietly** off. Confirm this does not change the current call's media. Leave, then join an authorized test meeting and separately start one; verify microphone and camera start on when permitted, including the selected camera background. Check that denied permissions and host restrictions keep media off with accurate controls. After manually muting/stopping video, reconnect the same session and confirm it stays off.
5. Verify the switch persists both ways after relaunch. With it off, **Share screen** to a test Zoom Room must still enter with meeting audio disconnected and video off. Restore **Join quietly** on afterward.

**Expected:** visible controls agree with delivered media and selected devices; errors remain visible and no unavailable device is reported as active. Device changes and audio tests do not silently unmute a participant. Record measured quality if useful; a camera toggle or HD preference is not proof of a specific resolution.

### M02 — people, layouts, hand state and meeting lifecycle

1. With A, B and C admitted, switch **Gallery View** and **Active Speaker** while B and C speak in turn. Pin/unpin a participant, resize the window, open/close Chat and People, and return to Gallery. Verify live video continues in the selected views.
2. Test **Hide self view**, **Show non-video participants**, gallery tile reordering, and the corner self-view where available. Have C leave to exercise the two-person view, then rejoin. Toggle **Keep on Top** and verify the window behavior.
3. A chooses **Raise hand**; B verifies it, then verifies **Lower hand**. Repeat with B in Yap. Confirm the hand control is unavailable when alone.
4. Near the end of the full test, B chooses Leave and confirms A's meeting continues. A chooses **End for everyone** and verifies all endpoints exit. Close the main window during a separate active call and cancel the leave prompt; the meeting remains intact. After leaving, close and reopen the idle main window from the menu bar.

**Expected:** local view changes do not rearrange other participants' clients; hand and meeting state reach the other endpoint. Leave and End have distinct effects. Media/sharing stop after the call ends, and a later meeting does not inherit stale participants or chat.

### M03 — public/private chat, threads and permissions

1. With A, B and C admitted, A sends **Yap review public sample** to Everyone; verify B and C receive it. B replies; verify it in Yap.
2. A selects B explicitly in **To:** and sends **Yap review private sample**. B verifies receipt and private audience; C verifies that it does not appear. Reply from B and confirm it does not go to Everyone.
3. Send a formatted message containing bold/italic text, a harmless HTTPS link and an emoji. Verify the supported formatting at B's endpoint. Exercise Reply, expand a supported thread, Copy and Quote. Delete A's own message when allowed and confirm the deletion at the other endpoint.
4. For policy changes, start a separate meeting with A hosting in Zoom Workplace and B using Yap. A changes chat permissions using Zoom's host controls. Confirm B's available audiences/actions follow the policy and rejected sends show errors. Have a private recipient leave before B sends a prepared reply; it must not become an Everyone message. Yap does not supply the host's full policy-management interface.
5. In a waiting-room-enabled meeting hosted by A in Yap, keep C in the waiting room. A uses the waiting-room chat audience when offered, verifies C's received message, then opens People and chooses **Admit** for C. Verify C moves from waiting to admitted. Record separately if the account policy disables waiting-room chat.
6. Close chat, have B send a message, observe the unread badge/message bubble, and reopen chat. Set Message sound to None and confirm it does not suppress the unread badge. Use **Find in chat** to find sample text.

**Expected:** actual recipients match the displayed audience, policy changes are honored, and permitted replies/deletions update consistently. Yap has no sent-message edit command or per-message emoji reaction command; do not simulate them or mark them tested. If webinar audiences are tested, use real panelist/attendee roles and report those runs separately.

### M04 — chat attachments and chat export

1. A selects B as recipient, chooses **Attach file**, and sends `yap-review.txt`. Verify B receives the attachment metadata and C does not receive the private attachment.
2. With B in Yap for the reverse-direction run, choose **Save file**, select a temporary test folder, and compare the saved bytes/content to the sender's file. Cancel a different transfer; use **Retry download** if offered and record the actual result. A retry request that fails must remain an error, not appear completed.
3. Open a send/save dialog, leave the meeting, and start another meeting before completing it. The stale action must not send to the new meeting or overwrite a different meeting's state.
4. Choose **Chat options → Save Chat…**. Inspect the text file for timestamps, audiences, retained messages/thread labels and attachment details. Confirm the attachment itself is not embedded. Keep the saved file through disconnect, then delete it manually.

**Expected:** sending/downloading is explicit, recipient and session remain correct, file progress/error state is accurate, and saved files remain under the user's control. Chat export describes history retained by Yap, not a complete server archive.

### M05 — screen/window sharing and computer audio

1. A chooses **Share → Screen or window**, selects synthetic window A and confirms Share. B verifies actual changing window A content. Switch to window B and confirm both the receiver and Yap's sharing label change. Stop sharing and verify it disappears at B.
2. B shares a synthetic window from Zoom Workplace. A uses **Show people** and **Show shared content**, then verifies the panel clears when B stops.
3. A selects **Computer audio**, confirms sharing, and plays the harmless sound clip. B verifies the audio and confirms no screen is displayed. Check that A's microphone retains its previous state. Stop and verify delivery ends. If switching modes requires stopping first, follow the displayed instruction.
4. Test an entire display only on a test desktop containing synthetic content. Verify the intended display and stopping. Deny screen access or have the host disable sharing; confirm a useful permission/error path without a false Sharing state.

**Expected:** only explicitly selected content is shared; reported sharing agrees with the other endpoint. Incoming and outgoing sharing are separate results. Nearby Zoom Room pairing is experimental: test its error/recovery path if encountered, but do not count it as successful room pairing or as proof of this standard meeting-sharing case.

### M06 — camera effects and persistent background image

1. Outside a call, open **Settings → Camera** and **Preview camera**. Choose None, Blur and a harmless Photo where offered; toggle **Automatically frame me**. Verify the local preview and stop it or close settings.
2. Start a call, enable the camera and let B confirm actual outgoing effects. Close Camera settings and verify it does not create an independent preview during the call. Restart Yap and test restoration before enabling the camera again.
3. Move the original selected image; verify the saved background remains available. Choose None and confirm the effect stops, while the copied image remains under `~/Library/Application Support/Yap/Camera Backgrounds`.

**Expected:** supported effects are confirmed by Zoom and reflected locally/remotely; unsupported options are unavailable or show a clear error. A missing/unusable selected effect must not silently enable an unintended camera view. Copied images persist until separately deleted; the source image is unchanged.

### M07 — group photo and saved-file behavior

1. With A, B and C consented, enable two cameras and leave one camera off. In A's layout menu choose **Take photo**, keep the full window visible and still, and wait through the countdown.
2. Inspect the resulting PNG in Downloads. Verify only active-camera tiles are included, without names or camera-off placeholders. Confirm that leaving/disconnecting does not delete the saved photo; remove it manually after the test.
3. If screen access is denied or capture fails, verify there is an actionable message rather than a successful partial photo. If saving fails, verify retry/discard reflects whether a file was actually written.

**Expected:** successful photos save automatically to Downloads. A test with three people proves that group size only. A separate run with more than 49 real camera endpoints is needed to verify batched capture; without it, record that larger-group case Not run. The batches are not one simultaneous instant.

### R01 — live cloud recording, host/co-host and participant notice

1. A uses the licensed, enabled host account with B and C admitted. Confirm recording is initially off. Choose **Record to Cloud** and observe the confirmed recording state at all endpoints.
2. Complete Zoom's participant notices through explicit human decisions; verify they are presented, including for a participant who joins after recording begins. Do not auto-accept notices on another participant's behalf.
3. A pauses, resumes and stops recording. Compare state at B. Do not expect a playable file until Zoom finishes processing.
4. For the co-host variant, start a separate meeting with A hosting in Zoom Workplace and B using Yap. When allowed by the account, A promotes B to co-host through Zoom's host controls. B repeats permitted recording controls; confirm the resulting files belong to host A. A removes B's co-host role and verifies B's controls become unavailable. This does not imply that Yap provides role-promotion controls.
5. Repeat an unavailable case with a Basic host or disabled cloud-recording policy. Record the actual reason displayed.

**Expected:** SDK permissions and host policy determine controls; participants see the required notices; confirmed recording/paused/stopped states are distinct. No new REST scope or silent recording/AI-summary enablement is needed. This test does not replace R02's prepared completed files.

### R02 — own-user recording list and monthly loading

1. Sign into A in Yap, open **Recordings**, and locate R1 and R2 in their prepared month. Search the exact sample title and a recorded fixture date.
2. Choose **Load earlier month** until R3's month is loaded. Verify its metadata. If the account has enough records for pagination, verify the subsequent page without duplicate or missing entries; otherwise record pagination at production volume Not run.
3. Open and close the library while a selected video is paused/playing. Reopening refreshes loaded months without resetting that item's position.
4. After leaving all calls, disconnect A and connect B. Confirm A's list is cleared and B sees only B's own recording library or its genuine empty/unavailable state. Attending A's recorded meeting does not make it B's recording.

**Expected:** `cloud_recording:read:list_user_recordings` accesses the consenting user's list only. Title/date searches cover loaded months. Missing eligibility, loading failures and an empty library are distinguishable from a fabricated success.

### R03 — video, saved chat/transcript and explicit exports

1. As A, play R1. Pause, seek, change speed, use another available video layout and double-click the row to open its own player. Verify paused/playing state, position and speed carry over. Test Space, Left/Right, S, V and F while focus is outside a text field.
2. Open Chat and Transcript. Find the prepared sample phrases. Click a timestamp/cue to seek, search the transcript, scroll away and use **Follow playback**. Copy a passage/transcript, export TXT and VTT, and inspect the actual sample content.
3. Save the video to a chosen test folder and verify playback of the saved MP4. If streaming fails and **Download to play** is offered, exercise that fallback and record it separately rather than forcing a failure in a private session.
4. Play R2. Confirm unavailable chat/transcript state without invented text. Test a missing/unavailable video variant if present. Keep explicit video/text exports through disconnect and remove them manually afterward.

**Expected:** returned authorized file URLs deliver the owned files; available text follows the recording timeline; unavailable files are honest empty/error states. Copying a sharing link does not grant new Zoom access. Explicit saves persist; temporary playback storage is separate.

### G01 — optional Google authorization and calendar-list scope

1. Finish the mandatory Zoom scope cases with Google disconnected first. Then G chooses **Connect Google Calendar** in the agenda, or **Settings → Connections → Sign in with Google**.
2. Complete Google's own consent, including any unverified-app warning according to the test account's policy. Confirm no Cloud project or imported client file is required. Record a user-cap or organization restriction as Blocked.
3. Verify both prepared calendars appear. Select Main only, then select Secondary. Repeat once with cancelled consent and verify no false connected state.

**Expected:** `calendar.calendarlist.readonly` supports selection of G's calendars; Google data is optional and independent of Zoom hosting. No extra Google roles or Yap credentials are requested.

### G02 — optional calendar-event scope and meeting entry

1. With Main selected, verify today's/tomorrow's events and the all-day event in the agenda/menu-bar schedule. Verify the non-Zoom event does not offer a false Zoom join. Select Secondary and confirm its fixture appears; deselect it and confirm the corresponding agenda entry is removed.
2. Join the prepared Zoom meeting from the agenda and from the menu bar in separate runs. Confirm the meeting title/time match the calendar event when applicable. Open an event's day in Google Calendar.
3. Open the event containing two Zoom links; confirm an explicit choice rather than an arbitrary silent join. Verify Calendar event content and RSVP were not changed by reading or joining.

**Expected:** `calendar.events.readonly` reads only selected calendars for display and supported invitations. Yap does not create, edit or delete events, invite people, or change RSVP state.

### G03 — optional Google removal and account isolation

1. Disconnect Google in Settings. Confirm selected calendar/event state clears while the Zoom connection still works.
2. Reconnect explicitly; revoke Yap separately in Google's connected-app settings, then request a fresh calendar refresh. Observe the actual provider rejection/reconnection path without treating old cached events as fresh access.
3. If testing with a second Google identity, connect it and confirm G's events do not reappear as that account's data.

**Expected:** Google disconnect/revocation is independent of Zoom. Local removal clears the app's associated calendar state; server-side access is controlled by Google's grant. Record propagation delays rather than claiming immediate provider behavior.

### X01 — local disconnect and account change

1. Finish any calls, open a recording and its separate player, then choose **Settings → Connections → Disconnect Zoom**.
2. Verify the Zoom connected state, recording library, active playback and account-owned recording text clear. Confirm Google remains connected if it was connected before.
3. Reconnect A explicitly, then disconnect and connect B. Confirm no A data or stale async result restores A's connection or library. Developer configuration, user exports and SDK-owned files are distinct from cleared account state.

**Expected:** local Zoom tokens/grant and associated app state are removed; unrelated Google state and user-selected files remain. Local Disconnect is not represented as Zoom-side revocation.

### X02 — Zoom provider removal and fresh-access refusal

1. With A connected and no meeting active, use Zoom Marketplace's **Manage → Added Apps**, find Yap and remove it. Keep the app installed for the following check. Use the correct app entry matching the candidate's authorization.
2. In Yap, request a fresh recording-list refresh and attempt a new meeting authorization. Observe Zoom's actual revocation behavior and timing. Do not infer failure or success from already cached text, downloaded files or a previously issued SDK JWT alone.
3. If a token/JWT remains valid temporarily, record issuance/expiry timing without recording its secret value, repeat a new authorization after expiry, and report the result accurately. Explicitly authorize A again to recover.

**Expected:** once Zoom rejects the removed grant, fresh list/ZAK/token requests fail visibly; the managed service must not issue a new SDK signature for rejected Zoom authorization. Old exported files remain local. This flow uses provider removal; Yap does not claim an implemented deauthorization webhook.

### X03 — refresh, recovery and teardown

1. Keep a consenting test account connected until its actual access-token refresh is due; exercise a fresh own-user recordings/meeting action, recording safe timestamps and observable success. Never edit or expose live token values to simulate expiry.
2. Repeat a fresh action while offline, restore networking and retry. Verify an error is not shown as a successful new meeting, list or download. Confirm stale responses cannot restore a disconnected account.
3. Leave all calls, disconnect both providers, remove the providers' Yap grants, quit Yap, and delete the app if this is a temporary review installation. Delete only the test exports/photos/attachments and copied test backgrounds. Restore the original meeting-link handler.

**Expected:** refresh/recovery preserves the correct account, failures are visible, teardown stops media and does not claim to erase SDK internals or user exports. Actual live refresh is a separate observation from unit-test coverage. In-app N → N+1 update installation needs a separately published newer signed version; it is not demonstrated by this same-version installation plan.

## Private handoff and completion record

Before a reviewer depends on this plan, complete the following privately. No item is fulfilled merely by this document existing.

| Required handoff item | Current state |
| --- | --- |
| Exact 0.1.7 / build 8 candidate and HTTPS authorization entry/callback | Source configuration is documented above; final packaged identity, deployment and validated live handoff results must be supplied separately |
| Reviewer agreement on using their own provider identities, or usable dedicated test access | Not established in this document |
| A's cloud-recording entitlement and completed R1/R2/R3 data with actual dates | Not provisioned or verified by this plan |
| B's independent account and allowed external-meeting access | Not established in this document |
| C's endpoint and private-message/waiting-room schedule | Not arranged by this plan |
| Test account SSO/2FA/email-verification access and expiry, if supplied | Must be completed by the identity owner in a private channel |
| Optional Google fixtures and current consent eligibility | Not provisioned or verified by this plan |
| Optional co-host, webinar, >49-camera and high-volume pagination prerequisites | Record available, blocked or not run individually |
| Completed case results and private evidence | No comprehensive live run attached to this plan |

Use a private result row with **case ID; build/commit; date; role aliases; observed result; status; evidence link; blocker/retest owner**. Include the link to this test plan in the reviewer handoff, together with exact candidate identity and the private fixture/access information. A short synthetic walkthrough may supplement it; no demonstration video or new live acceptance is asserted here.
