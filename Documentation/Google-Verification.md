# Google OAuth verification for Yap

## Live checkpoint — September 8, 2026

Project **Yap for Mac**, ID `whoosh-personal`, number `696553061357`, owned by `mgrinich@gmail.com`. The released macOS app is Yap 0.1.4 (build 5), bundle `com.grinich.yap`. Its desktop OAuth client is `696553061357-u7j8v96hlg5qms17kc9rea8cjtb8ksoh.apps.googleusercontent.com`.

The project began this check in Testing with empty website fields. It is now **In production**, still **unverified** and subject to Google's warning and 100-user cap. No new OAuth scopes or credentials were added.

Completed:

- Published the existing allowlisted homepage, guide, Privacy and effective Terms using [GitHub Pages](https://grinich.github.io/yap/), without a custom domain or changes to grinich.app. [PR #18](https://github.com/grinich/yap/pull/18), [successful deployment](https://github.com/grinich/yap/actions/runs/34201825375).
- Saved homepage `https://grinich.github.io/yap/`, privacy `/yap/privacy/`, Terms `/yap/terms/`, and authorized domain `grinich.github.io` in Google branding. All four public pages return HTTP 200, with original full-resolution PNGs and no private app files.
- Search Console confirmed **Ownership verified**, using an HTML tag, for the exact URL-prefix property `https://grinich.github.io/yap/` under the same Google account as the Cloud project. The public tag is retained in `Resources/GoogleSiteVerification.txt` and the generated homepage.
- Started automated brand verification. Google returned the single finding that the homepage was not registered to the developer, despite the exact-property verification above.
- Opened **I believe the issues found are incorrect → Request additional review**. The resulting combined submission form still requires the sensitive-scope justification and an unlisted YouTube demo URL. The justification is prepared below and staged in the live form, but Save and final Confirm remain unavailable without the video.

**The final manual-review/sensitive-scope request has not been submitted.** Search Console ownership is not itself OAuth brand approval. A dedicated private `Yap Review Demo` calendar was created with no real meeting content; creating a sample event for the video is awaiting the user's explicit approval. No event, demonstration video or YouTube upload has been created yet.

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

1. Create the explicitly approved synthetic demo event and record the actual Google authorization and Yap Calendar flow, then inspect the recording before sharing it. The video must show the real client/consent screens and functionality; do not substitute rendered mockups.
2. Upload the reviewed demo to YouTube as Unlisted and add its URL plus the prepared justification to Data Access. No private work events, passcodes, tokens or unrelated account content should be in it.
3. Complete the ownership appeal with the exact Search Console property and HTML-tag verification evidence. The OAuth checker may require additional domain-ownership proof; do not claim that the GitHub Pages domain is approved yet.
4. Submit the completed form and record Google's acknowledgement. Publish approved branding if Google requires that step, and finish any separate Calendar-scope review steps it then exposes.
5. Respond to review follow-up through the configured developer/support contact. Do not report approval until the live status confirms it.

### Ownership appeal text (prepared)

The exact submitted homepage, https://grinich.github.io/yap/, was verified in Google Search Console on September 8, 2026 using an HTML meta tag by mgrinich@gmail.com, the same account that owns Cloud project whoosh-personal. Search Console displayed Ownership verified for this URL-prefix property. The verification meta tag remains in the public homepage. The website is served from the grinich/yap repository through GitHub Pages, with matching publicly accessible Privacy and Terms pages. Please review this ownership evidence; we can provide additional proof if the OAuth verification system requires it.

## Official references

- [Google sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification): branding, domain ownership, scope justification and a real unlisted YouTube demonstration. Google gives a typical 3–5 business day review estimate, not a deadline.
- [Manage OAuth app branding](https://support.google.com/cloud/answer/15549049): homepage and matching privacy links, authorized domains and Search Console ownership.
- [Calendar API permissions](https://developers.google.com/workspace/calendar/api/auth): use the narrow permissions needed for the features.
