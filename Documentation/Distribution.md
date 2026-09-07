# Sharing the app with a team or the public

Requirements checked against official documentation on **September 7, 2026**. Publishing this project's source is authorized separately from distributing a ready-to-use binary. A public repository does not establish Zoom or Google approval for other users.

**Current state:** the actual app, including its Zoom and Sparkle components, has passed Apple notarization and Gatekeeper. The personal runtime still signs Meeting SDK JWTs with the owner's locally imported SDK secret; a signing service for shared distribution is pending. External Zoom publication/review and Google public OAuth verification have not been established. A fresh-Mac release acceptance run and an actual updater version N → N+1 installation remain pending. See [release evidence and packaging](Releases.md).

## Choose the audience

| Audience | Zoom | Google Calendar |
| --- | --- | --- |
| Internal team | A private app can be shared within the **same Zoom account as the app developer**. Same company or email domain alone is insufficient. | Use **Internal** only when the Cloud project belongs to the team's Workspace or Cloud Identity organization and all users belong to that organization. |
| External testers | Obtain **Request to Share** approval before sharing the authorization URL outside the developer's Zoom account. | An **External / Testing** project permits up to 100 named test users. Calendar consent and refresh tokens expire after seven days. |
| External team or public users | Use a reviewed **listed or unlisted** app, or obtain applicable advance written Zoom approval. | Configure the production OAuth project and complete applicable branding and data-access verification; publishing status alone does not complete verification. |

Sources: [Zoom distribution](https://developers.zoom.us/docs/distribute/), [Zoom private/beta sharing](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/), [Google audience settings](https://support.google.com/cloud/answer/15549945?hl=en), [Google verification exceptions](https://support.google.com/cloud/answer/13464323?hl=en).

Google organization administrators may also need to allow the app. Personal-use and testing exceptions can permit limited unverified use, with warnings and user caps; they are not a general public-release approval. [Google verification exceptions](https://support.google.com/cloud/answer/13464323?hl=en)

## Prepare Zoom distribution

1. **Keep the SDK secret off teammates' Macs.** Replace the personal `ZoomSDKJWT.make` path with an authenticated signing service that holds the SDK secret and returns short-lived SDK JWTs. Each person still authorizes their own Zoom identity. ZAK identifies the human user; it does **not** replace the SDK JWT or its signer. Public-client PKCE addresses OAuth, not SDK-secret distribution. [Meeting SDK authorization](https://developers.zoom.us/docs/meeting-sdk/auth/)
2. **Confirm the intended meeting accounts.** Internal users joining meetings outside the SDK app developer's account still fall under the external-meeting policy. Current policy requires review/approval plus ZAK or OBF authorization. This app implements the human-user ZAK path. For approved beta external meetings, Zoom specifically instructs developers to share the authorization URL with the external host. [SDK authorization](https://developers.zoom.us/docs/meeting-sdk/auth/), [beta sharing](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/)
3. **Prepare the General app's production configuration.** Keep the Meeting SDK enabled, configure public-client OAuth and the supported redirect, and justify the actual scopes: `user:read:zak`, `meeting:write:meeting`, and `cloud_recording:read:list_user_recordings`. Supply the required listing information, technical/security documentation, privacy policy, terms, support and user documentation. Test authorization, installation and removal as a new user. Unlisted distribution still receives review. [Production preparation](https://developers.zoom.us/docs/build-flow/prep-app-for-prod/), [review process](https://developers.zoom.us/docs/distribute/app-review-process/), [setup](Zoom-Setup.md)
4. **Resolve the name before external release.** Zoom's naming rules prohibit variations of “Zoom” in app names and related URLs. “Zooom” likely conflicts with this rule; that is an interpretation, not an individual ruling from Zoom. Choose a distinct name or obtain written permission. Compatibility wording such as “[Name] for Zoom” is permitted. [Naming requirements](https://developers.zoom.us/docs/build-flow/app-listing/app-icon-and-app-name/)

Approved external beta sharing normally lasts four weeks. During that window, its conditions prohibit making information about the app public or publicizing it as a Zoom integration. Resolve that restriction with Zoom before relying on beta approval alongside a public source launch. [Beta conditions](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/)

## Prepare Google Calendar distribution

Use a Google **Desktop app** OAuth client, enable the Calendar API, and retain the browser/PKCE/loopback flow. The client identifier is public configuration; user tokens remain private. Current scopes are `https://www.googleapis.com/auth/calendar.events.readonly` and `https://www.googleapis.com/auth/calendar.calendarlist.readonly`. Declare both in Data Access; do not expand access for distribution. [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Calendar scopes](https://developers.google.com/workspace/calendar/api/auth), [implementation](GoogleCalendar.md)

For public use, use a separate production project, verify authorized-domain ownership, provide accurate branding and a public homepage/privacy policy, and complete the applicable scope verification. Prepare scope justifications and a demonstration of consent and each Calendar feature. The privacy policy must describe actual local caching, access, storage and deletion behavior. Check the current scope classifications and approval status in Data Access/Verification Center. Changing the audience to In production does not itself verify the app. [Verification preparation](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification), [audience and publishing status](https://support.google.com/cloud/answer/15549945?hl=en)

## Separate source publication from binary delivery

Publish project-owned source under its chosen license; exclude credentials, user data, signing keys and proprietary SDK files. Zoom's API terms separately govern the integrated Meeting SDK: third-party app distribution requires Marketplace publication or advance written approval, and standalone SDK redistribution is prohibited. The terms' internal-use exception also requires employees/agents to be contractually bound to the relevant restrictions. [API terms, sections 2 and 6](https://www.zoom.com/en/trust/legal/zoom-api-license-and-tou/)

The release workflow now requires a **separate private dependency repository** for the raw Zoom SDK ZIP and verifies its visibility before downloading. Configure its repository name, release asset ID, and narrowly scoped read-only token; never publish the SDK archive as a public dependency asset. Sharing source does not make the current owner-secret setup suitable for a shared binary. Follow [Releases](Releases.md) for the actual artifact destination and updater configuration.

## Finish macOS release acceptance

Use the existing Developer ID pipeline for team and public downloads: sign the app and all nested components, enable hardened runtime, notarize and staple the deliverables, then verify Gatekeeper. Apple notarization checks software security/signing; it is separate from provider approval. The current Zoom macOS SDK does **not support App Sandbox**, so this integration does not currently provide a Mac App Store distribution route. [Apple Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Zoom macOS requirements](https://developers.zoom.us/docs/meeting-sdk/macos/get-started/)

- On a fresh supported Mac, install the downloaded DMG, verify first launch without developer tooling, complete account onboarding and normal camera/microphone/screen-sharing permissions, and exercise calls, Calendar and recordings with the intended audience. Current releases target Apple silicon and macOS 26 or later.
- Install release N, publish N+1 through the configured feed, and verify discovery, signature validation, installation/relaunch, retained accounts/preferences, call-in-progress deferral, and failure recovery. Successful signing or notarization alone does not demonstrate update delivery.

Record that evidence and the provider approvals before describing the binary as ready for team or public use. [Release acceptance](Releases.md#first-release-acceptance)
