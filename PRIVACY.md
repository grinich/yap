# Privacy in the developer preview

Zooom is an independent macOS client. This page describes the current source and developer preview, as of September 7, 2026. A future hosted sign-in or SDK signing service will need an updated policy before it launches.

## Your accounts and meetings

- **Zoom:** the app connects directly to Zoom for account authorization, meeting access, meeting creation, cloud recording lists, playback, saved chat, and spoken transcripts. Zoom's Meeting SDK carries meeting audio, video, sharing, and in-meeting chat. Zoom's own terms and privacy policy govern its service and SDK.
- **Google Calendar, if connected:** the app requests read-only calendar-list and event access, then displays upcoming Zoom meetings from your selected calendars. It does not create events, send invitations, or change RSVPs.
- **No Zooom-hosted meeting service:** the current app does not upload your calendar, chat, or transcripts to a project-operated server. Third-party services still receive the network requests needed to provide their features.

## What stays on your Mac

Account configuration and OAuth tokens are stored in the macOS Keychain. Selected calendar metadata is cached locally so the agenda can open promptly. Meeting links in that cache may contain passcodes; it is stored with user-only permissions.

Recording metadata, chat, transcript text, and playback caches are kept in memory while in use. Download-to-play can create a temporary local video file, removed when playback is stopped or replaced. Explicitly saved videos and transcript exports remain at the destination you choose. Participant thumbnails use an in-memory cache; the Zoom SDK manages its original avatar files.

Disconnecting an account clears its local authorization and associated app caches. Files you explicitly exported remain yours to remove. Disconnecting locally does not claim to revoke the provider's server-side authorization; you can also revoke access from your Zoom or Google account.

## Updates, links, and support

When an update feed is configured, Sparkle contacts the configured release host to check for and download updates. Sparkle system-profile sending is disabled. Unconfigured developer builds do not check an update feed.

Links you open in chat and Help → Report a Bug open in your browser. GitHub Issues are public once the repository is public. The app does not automatically attach logs, credentials, meeting links, or transcripts to bug reports. Remove private information before posting.

## Permissions

Camera, microphone, screen sharing, and notification access are controlled by macOS and requested as their features require them. Meeting recording and access remain subject to Zoom's permissions and consent flows.

For implementation details, see [credential storage](Documentation/Credential-Storage.md), [calendar access](Documentation/GoogleCalendar.md), and [recordings](Documentation/Recordings.md). For general questions, use [GitHub Issues](https://github.com/grinich/zooom/issues); do not post secrets or private meeting data there.
