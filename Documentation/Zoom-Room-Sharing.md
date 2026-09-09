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
The exact reason for the SDK permission result remains unconfirmed; it must not be
assumed to be a macOS microphone permission or Zoom Marketplace approval issue.

## APIs

- [Zoom's Direct Share guide](https://developers.zoom.us/docs/meeting-sdk/macos/default-ui/advanced-features/share-to-zoom-room/)
- [Direct Share helper reference](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_direct_share_helper.html)
- [Custom content handler reference](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_direct_share_specify_content_handler.html)

The guide is documented for default UI. The SDK also declares custom content
handler callbacks. Current room-sharing builds use default UI, while regular
calls retain Yap's custom UI. The explicit `AllOption` sharing preference is set
before starting discovery to avoid inheriting automatic desktop sharing.
