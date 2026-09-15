# Zoom Room sharing: prototype status

The home-screen Share screen button is to the right of Join with a link. It uses
the macOS Meeting SDK Direct Share helper, with room-key entry callbacks and an
explicit content picker. Sharing does not automatically select the desktop.

## Verification on September 9, 2026

- All 657 tests passed before the final default-UI configuration adjustment.
- Both custom-UI and documented default-UI builds compile and pass Developer ID signature verification.
- The button is visible in the installed home screen.
- Live SDK testing on the Mac mini returns `ZoomSDKError_NoPermission` (6) from
  `canDirectShare`, before discovery or code entry. Microphone access was granted
  and an input device was present. Changing to default UI did not resolve it.
- No screen was shared. Room-side reception has **not** been verified.

Do not describe automatic room pairing as working or release-ready. The next
verification is Direct Share eligibility in the target room and account, followed
by room-side checks of pairing, source selection, stopping, and audio/video state.
Binary inspection subsequently identified two eligibility gates that return this
error: Direct Share enablement and native SDK user login. Yap currently uses SDK
JWT authentication and the without-login meeting context; OAuth account access
does not itself satisfy that separate native login requirement. Which gate failed
first at runtime remains unconfirmed. The next targeted experiment is supported
SDK SSO login followed by an eligibility check; microphone permission or
Marketplace approval must not be assumed to be the cause.

Further room-discovery experiments are not part of the supported public API surface.
The release does not claim automatic room pairing is functional.

## APIs

- [Zoom's Direct Share guide](https://developers.zoom.us/docs/meeting-sdk/macos/default-ui/advanced-features/share-to-zoom-room/)
- [Direct Share helper reference](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_direct_share_helper.html)
- [Custom content handler reference](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_direct_share_specify_content_handler.html)

The guide is documented for default UI. The SDK also declares custom content
handler callbacks. Current room-sharing builds use default UI, while regular
calls retain Yap's custom UI. The explicit `AllOption` sharing preference is set
before starting discovery to avoid inheriting automatic desktop sharing.

## Recovery UI follow-up — September 12, 2026

Room-pairing failures now retain their origin after SDK teardown, so the alert
can offer **Open Zoom Workplace** and **Join with a link…**. The latter opens
the ordinary invitation form directly; it does not claim bare meeting-ID input
or successful proximity detection. Error 6 names the SDK rejection without
attributing it to microphone access or app approval. These are recovery paths,
not a fix for automatic pairing.

51 focused room-sharing, session-safety, and join-feedback tests passed. A running
local failure fixture verified the alert and its direct transition to the join
form. A Developer ID signed local build is in the outer workspace at
`work/room-recovery/build/Yap.app`; no release or device transfer was performed.
The native SSO/private detector experiment remains incomplete. Native SSO must
be performed in the same initialized SDK session before retrying eligibility;
current terminal-error teardown uninitializes that session.
