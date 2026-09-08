# Privacy

Last updated September 7, 2026. Yap is an independent macOS application developed and operated by **Michael Grinich**, an individual. Contact [mgrinich@gmail.com](mailto:mgrinich@gmail.com) for privacy or security matters.

This policy describes personal developer mode and the managed connection option prepared for the free preview. Managed mode is available only in builds configured with the project's authorization service. Publishing the source or this policy does not mean Zoom has approved external use.

## Connecting Zoom

Both modes open Zoom's sign-in and consent page in your browser. The app uses PKCE and receives the authorization response through a temporary listener on your Mac's loopback interface. The app does not receive your Zoom password.

- **Personal developer mode:** you supply your own developer configuration. OAuth code exchange and refresh go directly from your Mac to Zoom. Your SDK secret remains in your Mac's Keychain, and SDK authorization is signed locally. This mode does not use the project-operated authorization service.
- **Managed mode:** the app sends its authorization code, PKCE verifier and loopback redirect, or its refresh token, to the project's HTTPS service hosted on **Cloudflare Workers**. The service forwards accepted fields to Zoom using the fixed public client ID. It handles the returned access token, refresh token, scopes and expiry in request memory and sends them back to your Mac with a signed authorization grant tied to that access token. To authorize a meeting, the app sends the access token and grant to the service; the service checks current authorization with Zoom's ZAK endpoint and returns an SDK JWT. The developer's SDK secret stays on the service.

The authorization service does not maintain a user/token database or write authorization codes, verifiers, OAuth tokens, ZAKs or signing grants to application logs or persistent application storage. It processes them to complete the requested exchange or SDK authorization; this is not a claim that they never transit a server.

For abuse prevention, the service derives rate-limit keys from the source IP address and access-token hashes. Its application error log contains a fixed failure event, not exception text or request content. Worker invocation logs and traces are disabled. Configured application error events follow [Cloudflare Workers Logs retention](https://developers.cloudflare.com/workers/observability/logs/workers-logs/), currently three days on Free or seven days on Paid. Cloudflare also processes network/security information such as IP addresses and traffic metadata under its [privacy policy](https://www.cloudflare.com/privacypolicy/); disabling application request logs does not eliminate that infrastructure processing. No particular country of processing is promised.

## Meetings, recordings and Calendar

The Mac connects to Zoom for meeting creation, recording lists and downloads. Zoom's Meeting SDK carries live audio, video, screen sharing, participant information and meeting chat. The app's authorization service does not receive that content, meeting numbers, recording files, saved chat, transcripts or Google Calendar data. Zoom and its delivery infrastructure receive the requests needed for their services.

Recording playback and saved chat/transcript retrieval use the account's authorized Zoom download URLs. Where Zoom redirects a download to a non-Zoom CDN, the app removes the Zoom OAuth authorization header. Content you explicitly send, share, record, save or export remains subject to your permissions and other participants' rights.

**Google Calendar is optional.** The app requests read-only calendar-list and event access and reads directly from Google. It displays upcoming Zoom meetings from calendars you select; it does not create events, send invitations or change RSVPs. Google tokens and calendar data are not sent to the project-operated authorization service. Use and transfer of Google API data follow the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including its Limited Use requirements. The app does not sell account or meeting data, use it for advertising, or send it to train AI models. Spoken transcripts displayed by the app are existing Zoom recording artifacts.

## Storage, retention and your choices

Account configuration, OAuth tokens and managed signing grants are stored in the macOS Keychain and cached in memory while the app runs. Selected calendar metadata is cached locally so the agenda can open promptly. That account-bound cache has user-only file permissions and can contain meeting links/passcodes; it is not independently encrypted by the app.

Recording metadata, chat and transcript text, participant thumbnails, and playback caches are held in memory while in use. A hidden player may retain a paused item and cache. Download-to-play can create a temporary local video retained for that playback source and removed during normal cleanup. A crash can interrupt cleanup. Explicitly saved videos and transcript exports remain where you choose until you delete them; the app does not independently encrypt or remotely erase those files. Zoom manages its own SDK storage, including original avatar files and a separate safe-meeting Keychain item.

Disconnecting an account removes its local app authorization and clears associated app caches/playback. Personal developer configuration may remain. Disconnecting locally does not revoke Zoom's or Google's server-side grant; you can separately remove access in the provider's account settings. For managed mode, Zoom must accept the access token before the service issues another SDK JWT. A previously issued JWT may remain valid until it expires. The service holds no per-user token database requiring a separate deletion request; rate-limit and provider infrastructure records follow their respective retention rules.

Deleting the app does not automatically erase exported files, every preference or SDK-owned storage. For help accessing, correcting or deleting information you supplied to the developer, email [mgrinich@gmail.com](mailto:mgrinich@gmail.com). Reasonable identity verification may be needed. Support correspondence is kept as needed to handle the request, maintain a record of its resolution, and meet security or legal obligations; you can request deletion.

## Updates, support and permissions

When configured, Sparkle contacts the release host to check for and download updates. System-profile sending is disabled. Unconfigured developer builds do not check a feed. GitHub and other sites you open receive normal web requests under their own policies.

[GitHub Issues](https://github.com/grinich/yap/issues) are public. The app does not automatically attach logs, credentials, meeting links or transcripts to reports. Use email for private matters and avoid including tokens or unnecessary meeting content. App lifecycle diagnostics exist locally; proprietary SDK logging is disabled.

Camera, microphone, screen sharing and notification access are controlled by macOS. Meeting access and recording remain subject to Zoom permissions and consent. You can stop sharing, leave a call, disconnect an account or change macOS permissions. Material changes to these data practices will be reflected in this policy; any additional consent required for a new use will be requested before that use.

Implementation details: [credential storage](Documentation/Credential-Storage.md), [Calendar](Documentation/GoogleCalendar.md), [recordings](Documentation/Recordings.md), and [authorization service](Services/zoom-auth/src/index.ts). The [Terms](TERMS.md) describe the free preview's service terms.

## Moving from a previous app version

Yap can migrate supported preferences, the agenda cache and saved connections from its earlier bundle identities. The active credential vault uses the `app.yap.credentials` Keychain service. The previous consolidated vault is retained under its existing protection; once the Yap vault exists, it takes precedence and the old vault is not reread. Disconnect clears active authorization and records removal markers so legacy data cannot restore that connection. Older app bundles and their protected migration copies are not automatically erased. Normal macOS approval may be needed for the new app identity. See [Bundle identity](Documentation/Bundle-Identity.md) for the exact migration boundaries.
