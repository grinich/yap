# Participant profile photos

Yap reads participant photos from the macOS Zoom Meeting SDK. This works in custom meeting UI and does not require a new REST API scope or access to another user’s account.

The bridge requests each admitted participant’s avatar using `requestAvatarForUser:`, reads the SDK-owned local file returned by `getAvatarPath`, and refreshes it when `onInMeetingUserAvatarPathUpdated:` fires. A revision number invalidates cached thumbnails when Zoom replaces a file at the same path. Requests and revisions are cleared when a participant leaves or the meeting ends.

Camera-off tiles, the People list, and the shared picture-in-picture tile use the same circular photo component. Missing, pending, unreadable, or invalid images show initials. A host’s hidden-profile-picture setting removes photos immediately, including during late download callbacks. Showing pictures again requests fresh avatars.

Image decoding runs off the main thread. Inputs are bounded to 8 MiB, decoded thumbnails to 256 pixels, and the memory cache to 128 entries. Cache keys include the meeting session and participant so recycled participant IDs cannot display a previous attendee’s photo. Yap does not persist another copy of the source image or log image paths.

References: [ZoomSDKUserInfo / getAvatarPath](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_user_info.html), [ZoomSDKMeetingActionController](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_meeting_action_controller.html). Verified against the installed macOS Meeting SDK 7.1.5.84750 headers.

Validation: Swift tests cover local path handling, thumbnail decoding, cache identity, same-path revisions, session separation, invalid files and size limits. The Objective-C `AvatarEventsTests.m` fixture exercises the compiled bridge’s request/callback handling, reentrant updates, participant ID reuse and host privacy changes without connecting to a meeting. A native inert preview verified circular photos in the main camera-off tile and People list and immediate fallback when removed. An actual Zoom account profile photo in a live meeting remains unverified.
