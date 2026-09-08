# Google OAuth verification for Yap

## Live checkpoint — September 8, 2026

Project **Yap for Mac**, ID `whoosh-personal`, number `696553061357`, owned by `mgrinich@gmail.com`. The released macOS app is Yap 0.1.4 (build 5), bundle `com.grinich.yap`. Its desktop OAuth client is `696553061357-u7j8v96hlg5qms17kc9rea8cjtb8ksoh.apps.googleusercontent.com`.

The Cloud Console Verification Center reports that the project is in **Testing** and therefore has no verification request in progress. Branding already has the Yap name, logo, support email and developer contact. Homepage, privacy-policy URL, Terms URL and authorized domains are blank. Google review has **not** been submitted.

The live Data Access page matches the two scopes in `GoogleOAuthConfiguration.scopes`:

| Scope | Google classification | Feature |
| --- | --- | --- |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | Non-sensitive | Let the user choose calendars in Settings |
| `https://www.googleapis.com/auth/calendar.events.readonly` | Sensitive | Display upcoming Zoom meetings from selected calendars |

There are **no restricted scopes**. No new scopes or credentials are needed for verification.

## Submission text: event access

Yap is a native macOS meeting client with an optional Google Calendar agenda. The calendar.events.readonly scope lets Yap read event titles, start/end times, calendar/time-zone information and conference links from calendars the user explicitly selects. Yap identifies supported Zoom links in conference data, location or description, displays the upcoming meetings in its agenda and menu bar, and opens a selected meeting when the user chooses Join. Yap does not create or edit events, invite attendees, modify RSVPs, or read Gmail or Drive.

Free/busy access is insufficient because it does not include event titles or Zoom conference links. Read-only event access is sufficient; broader calendar write/manage permissions are not requested. Calendar-list access provides the user's subscribed calendar names and identifiers so they can select which calendars to display, without changing subscriptions or sharing settings.

## Submission text: storage and data handling

The Mac uses the system browser for Google OAuth authorization with PKCE and a loopback callback. Each user authorizes their own Google account. OAuth tokens are stored in the macOS Keychain. Requests go directly from the Mac to Google's Calendar API. Selected event metadata is cached locally with user-only file permissions for prompt agenda startup. The cache is not independently encrypted by Yap. Google tokens and Calendar data are not sent to Yap's Zoom authorization service, sold, used for advertising, or used to train AI models. Deselecting a calendar removes its cached events; disconnecting clears local authorization and the agenda cache. Users can separately revoke the provider grant in their Google Account settings. Details are in the public Privacy policy.

## Reviewer demonstration to record

Use a dedicated demo calendar containing only synthetic meetings; do not upload private work events, conference passwords, tokens or unrelated account content.

1. Show Yap's About panel and Settings → Connections.
2. Start Sign in with Google from the installed official app. Show the browser OAuth address bar with the public desktop client ID and the Yap app name.
3. Show the English consent screen and the two read-only Calendar permissions. Complete consent normally.
4. Return to Yap, show the calendar list and select the dedicated demo calendar.
5. Show its sample Zoom-linked event in the agenda. Open meeting details to demonstrate title, time and meeting-link use; joining a real call is unnecessary.
6. Deselect the demo calendar and show the event disappearing. Explain that Yap never writes Calendar events.
7. Show where Disconnect Google Calendar removes the local connection and cache, and explain that provider-side revocation is separate.
8. Upload the real recording to YouTube as Unlisted and include that URL in the sensitive-scope submission. Do not substitute a mockup or claim a demo was recorded before it exists.

## Remaining submission steps

- Publish the homepage, Privacy and Terms on a verifiable GitHub-hosted site. Verify site ownership in Search Console using the same Google account as the Cloud project. A normal github.com repository URL cannot carry an ownership-verification file; GitHub Pages is the candidate hosting route. Google acceptance of that authorized domain remains to be tested.
- Save the matching branding URLs and authorized domain, then complete brand verification.
- Move the project from Testing to the appropriate production audience as required by the Console. This alone does not remove the unverified warning or constitute approval.
- Submit the existing sensitive event scope with the justification above, the real demo video and the user guide. Publish approved branding when Google marks it ready.
- Record the submitted status and monitor the developer/support contact for Google follow-up. Do not report approval before Google's live status confirms it.

## Official references

- [Google sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification): branding, domain ownership, scope justification and a real unlisted YouTube demonstration. Google gives a typical 3–5 business day review estimate, not a deadline.
- [Manage OAuth app branding](https://support.google.com/cloud/answer/15549049): homepage and matching privacy links, authorized domains and Search Console ownership.
- [Calendar API permissions](https://developers.google.com/workspace/calendar/api/auth): use the narrow permissions needed for the features.
