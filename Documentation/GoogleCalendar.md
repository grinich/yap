# Google Calendar connection

Whoosh is now installed with the requested `com.grinich.woosh` bundle ID and existing Apple-issued Developer ID Team `VSVHNQP588`. First-launch background configuration loading is waiting for normal macOS authorization of the existing credential vault. Real account loading and calendar refresh under this new identity are not yet verified. The live results below belong to the previous identity. Credential service names remain compatible, and their existing protection is preserved. [Credential access status](Credential-Storage.md).

Whoosh reads selected Google calendars directly from the Mac. It does not create events, send invitations, change RSVPs, or send calendar data to a Whoosh server. This integration uses the owner's Google desktop OAuth configuration.

**Live verification:** the personal project and desktop client were created, configuration was imported into Keychain, and real read-only consent completed. Whoosh displayed Connected, fetched the actual calendar list and upcoming events, and completed a manual refresh. Deselecting the calendar immediately removed its events; the selection was restored afterward. The live agenda now hides calendar items without Zoom links and shows only Zoom meeting candidates. Calendar-triggered entry into a working Zoom meeting remains unverified.

## Personal setup

1. In Google Cloud, create or select a project and enable the Google Calendar API.
2. Configure the OAuth consent screen. For a personal testing project, add your Google account as a test user.
3. Create an OAuth client of type **Desktop app** and download its JSON configuration.
4. In Whoosh Settings, import that downloaded configuration, then choose **Connect Google Calendar**. Sign-in opens your default browser; consent returns to a temporary listener on `127.0.0.1`.
5. Select the calendars that should appear in Whoosh.

The requested scopes are `calendar.events.readonly` and `calendar.calendarlist.readonly`. Google grants these scopes across calendars that the account can access; Whoosh enforces your calendar selection when fetching and displaying events. No Google Calendar write scope is requested. Installed app credentials are public client identifiers; the optional desktop client secret is accepted because some Google desktop configurations include it, but it is never treated as a server-held secret.

Google may expire refresh tokens for an OAuth app in Testing after seven days, depending on the scopes and project configuration. If Google reports an expired or revoked grant, Whoosh asks you to reconnect. Moving the OAuth project to a broader release has separate Google verification requirements; this build is for personal use.

## Implementation and limits

- Browser OAuth uses a fresh random state and PKCE S256 challenge, an ephemeral loopback port bound only to `127.0.0.1`, and a three-minute timeout covering startup and browser handoff. Cancellation or disconnect closes the listener and its connections. The callback validates state, one authorization code, the request path, and Host header. It never accepts a remote redirect destination or echoes a code into its response page. Responses prohibit caching, referrals, and external page content.
- Access and refresh tokens are kept in the device Keychain, with no token logging. Google configuration and tokens now use the shared cached credential vault; [migration and update-permission details](Credential-Storage.md). Calendar requests use an ephemeral URL session without cookies or caching and do not follow HTTP redirects.
- Events are read using a bounded time window, `singleEvents=true`, and every page. Google expands recurring instances; cancelled instances disappear when a complete new window replaces the previous snapshot. A transient failed request leaves the last complete snapshot available with its original freshness time. Deselecting a calendar removes its cached data even if the replacement fetch fails. Access-denied or missing-calendar responses remove the affected calendar from the cache; loss of calendar-list access removes the agenda cache. The visible agenda reconciles that reduced snapshot, and an expired connection clears the visible agenda. Incremental sync tokens are deliberately not combined with a moving time window.
- The app caches selected-event metadata locally to make the agenda available at launch. The cache is bound to the OAuth client and connection identity; switching accounts cannot reuse the previous account’s agenda. Each cache replacement is created with user-only file permissions before invitation data is written, then renamed atomically. It contains no OAuth credentials. Meeting links can contain invitation passcodes, so the cache is private data. Disconnect removes the local cache independently of credential deletion and closes pending sign-in attempts. An older request cannot restore a cleared cache or overwrite a newer account’s credentials. Disconnect does not revoke Google's grant; the user can separately remove access in their Google account.
- Calendar extraction recognizes an HTTPS Zoom `/j/<9–11 digit meeting ID>` or `/s/<meeting ID>` URL on `zoom.us`, `zoom.com`, or a subdomain. The complete URL and passcode query are preserved. Pasted links are also checked against the native meeting validator before the Join sheet closes; invalid input is explained inline without a delayed global alert. Structured video conference entry points take priority, followed by location and description. Multiple candidate links remain ambiguous for an explicit user choice. Vanity URLs, URL shorteners, registration pages, and redirector URLs are not silently converted into meeting IDs.
- The initial client represents one connected Google account. Account switching should disconnect the preceding account and clear its selected calendars/cache before connecting another.
- Automated validation covers the parser, request construction, pagination, token refresh, cancellation tombstones, calendar time zones/DST, cache replacement, and callback validation. Real Google sign-in and event retrieval were also verified separately through the native app, as described above.

The calendar suite includes adversarial URL cases, suspended network and credential-store operations, account-switch races, access revocation, cache identity, and application-state recovery. Loopback integration tests are enabled with `WHOOSH_TEST_LOOPBACK=1 swift test`; they open temporary local listeners and use synthetic browser callbacks to verify handoff, timeout, cancellation, and account switching without contacting Google. Restricted test sandboxes may forbid local listeners, so those cases are opt-in. They passed in the complete September 6, 2026 run of 247 pure Swift tests across 34 suites, with zero failures, skips, or compiler warnings. That run also includes first-import settings observation and all eight nonblocking calendar-bootstrap regressions for background configuration reads, cancellation, replacement, and retry. These automated results are distinct from the completed real account sign-in.

## Official references

- [Google desktop OAuth flow and PKCE](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google Calendar read-only scopes](https://developers.google.com/workspace/calendar/api/auth)
- [Calendar list pagination](https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list)
- [Event-list query and pagination](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)
- [Event time zones, recurring instances, and cancellations](https://developers.google.com/workspace/calendar/api/v3/reference/events)
- [Incremental synchronization restrictions](https://developers.google.com/workspace/calendar/api/guides/sync)
- [OAuth token expiration conditions](https://developers.google.com/identity/protocols/oauth2)
