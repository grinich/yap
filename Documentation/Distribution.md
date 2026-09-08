# Sharing the app with a team or the public

Requirements checked against official documentation on **September 7, 2026**. Publishing project-owned source is separate from distributing the integrated SDK application; a public repository does not establish Zoom or Google approval.

**Current candidate: Yap 0.1.3 (build 4)**, `com.grinich.yap`, source `b920870e4a4a1f53b31d6f73c818c5aa2f75e5cf`. The [actual-SDK release](https://github.com/grinich/yap/actions/runs/34185478572), independent downloaded-package/signature verification and [exact-tag CodeQL](SecurityEvidence.md#codeql-configuration-and-coverage) passed. The normally installed, downloaded app passed managed-account persistence, real recording playback/chat/transcript, keyboard/fullscreen controls, a solo hosted meeting, About/icon and login switching. Local managed PKCE reauthorization and disconnect also passed with correct state handling when protected legacy cleanup was denied. Fresh-Mac, multiuser/external meetings, live token refresh, provider-side revocation and N → N+1 updates remain unverified. [Exact artifacts and native scope](Releases.md#current-candidate-evidence).

The five verified assets remain in unpublished draft **384441843**. The release operator confirmed the four-face Yap icon, including dark mode, the architecture and SSDLC attachments, and the separate Zoom App Gallery after reload. The completed submission retained **Overview 5/5** and **Security 3/3**. The portal records submission on **September 7, 2026 at 21:46 PDT**. At the **04:47:04 UTC on September 8, 2026** observation checkpoint, Publish showed **In review**, at the **Functional review** stage; persistent tracking confirmed it was waiting for Zoom approval. Reviewer instructions and manual activation were included in the submission. The current 0.1.3 SAST PDF, architecture and SSDLC attachments persisted in a fresh browser-tab server readback. Private reviewer delivery is verified against the exact DMG checksum, with access expiring October 8, 2026 at 04:29:19 UTC. The app is submitted for review; **external-use approval, external activation and public release remain pending**. Manual activation will still be required after approval. The selected initial audience excludes the EU. The production Beta authorization URL was regenerated successfully and its warning cleared; native public-client configuration was unchanged.

The final native PNG gallery, agenda and recording screenshots are published in the README through [PR #9](https://github.com/grinich/yap/pull/9); their [capture provenance](Images/README.md) distinguishes sample content from live private meetings. Google consent is **Yap**; its desktop client and project display names are **Yap for Mac**. The current Zoom development and production identity is **Yap**. Google remains **Testing**, without public verification approval or a new public rollout decision. [Provider branding checkpoint](#provider-branding-checkpoint).

The managed authorization service is `https://meeting-auth.mgrinich.workers.dev`; public Home, Guide, Privacy, Terms and Support use GitHub. [Service evidence](SecurityEvidence.md#production-service-acceptance). Google Calendar remains optional and uses manual desktop-client JSON setup; no public Google rollout is asserted. The immutable 0.1.2, 0.1.1 and 0.1.0 candidates are superseded. Their [historical evidence](Releases.md#superseded-candidate-v012) is retained without reusing versions or replacing assets.

## Provider branding checkpoint

The release operator verified the correct Google Auth Platform project by matching the candidate desktop-client filename to the exact OAuth Clients row. Project number **696553061357** retains the immutable project ID `whoosh-personal`. Its display name is now **Yap for Mac**, saved and confirmed after reload; Google's four-character minimum prevented using **Yap** as the project display name.

| Provider field | Saved and reloaded value |
| --- | --- |
| Google consent app name | **Yap**, with the current app logo present |
| Google desktop OAuth client name | **Yap for Mac** |
| Exact desktop client | `696553061357-u7j8v96hlg5qms17kc9rea8cjtb8ksoh.apps.googleusercontent.com` |
| Google project display name | **Yap for Mac** |
| Google publishing status | **Testing**; no Google verification approval is asserted |
| Current Zoom development app | **Yap**, confirmed in Created Apps and the development header |
| Current Zoom production app | **Yap** with the selected icon, as confirmed in the production readback |

The Google client ID and project identifiers are public configuration, not credential values. The retained project ID is an immutable identifier, not the displayed product name. The native Google callback already uses Yap. The repository audit found older names only in compatibility/migration or historical references. These branding checks do not establish a fresh OAuth authorization test, provider approval or release readiness. Unrelated Zoom apps were outside this rename.

## What approval covers

Zoom's current API Terms explicitly include client SDKs and address third-party **publication and distribution of the application**, not only OAuth authorization. Section 6.1 requires Marketplace publication or advance written Zoom approval for that use. Its internal exception is limited to employees or agents bound in writing to the required use/confidentiality restrictions. Section 7 supplies trademark permissions, not a separate distribution exemption. On that published wording, signing a public DMG, disabling managed sign-in, or asking downloaders to bring developer credentials does not establish permission to distribute the integrated SDK app. [API Terms, sections 1, 6 and 7](https://www.zoom.com/en/trust/legal/zoom-api-license-and-tou/)

There are also separate operational restrictions: private authorization is limited to members of the developer's Zoom account; external beta sharing needs approval; and access to meetings hosted outside the developer account requires app review and user authorization. A company email address alone establishes none of these. [Private/beta access](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/), [Meeting SDK authorization](https://developers.zoom.us/docs/meeting-sdk/auth/)

The available limited path is the project-owned source and SDK-free sample interface, plus properly authorized internal testing. Developers can obtain the SDK directly from Zoom for their own permitted setup. A private external beta must follow its specific approval conditions; it is not a general public download route. For the integrated **Yap 0.1.3 (build 4)** candidate, finish Marketplace publication or obtain written approval covering the intended distribution before making it public. Apple packaging, independent artifact checks and scoped managed-native acceptance passed; broader acceptance remains unverified. None provides Zoom distribution approval. [Candidate artifacts and installation](Releases.md#first-release-v013)

The selected first-release audience excludes the EU, and that availability setting is saved in the production listing. This is a listing choice, not Zoom approval or a data-residency promise.

## Choose the audience

| Audience | Zoom | Google Calendar |
| --- | --- | --- |
| Internal team | A private app can be shared within the **same Zoom account as the app developer**. Same company or email domain alone is insufficient. | Use **Internal** only when the Cloud project belongs to the team's Workspace or Cloud Identity organization and all users belong to that organization. |
| External testers | Obtain **Request to Share** approval before sharing the authorization URL outside the developer's Zoom account. | An **External / Testing** project permits up to 100 named test users. Calendar consent and refresh tokens expire after seven days. |
| External team or public users | Use a reviewed **listed or unlisted** app, or obtain applicable advance written Zoom approval. | Configure the production OAuth project and complete applicable branding and data-access verification; publishing status alone does not complete verification. |

Sources: [Zoom distribution](https://developers.zoom.us/docs/distribute/), [Zoom private/beta sharing](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/), [Google audience settings](https://support.google.com/cloud/answer/15549945?hl=en), [Google verification exceptions](https://support.google.com/cloud/answer/13464323?hl=en).

Google organization administrators may also need to allow the app. Personal-use and testing exceptions can permit limited unverified use, with warnings and user caps; they are not a general public-release approval. [Google verification exceptions](https://support.google.com/cloud/answer/13464323?hl=en)

## Prepare Zoom distribution

1. **Keep the SDK secret off teammates' Macs.** Use the implemented managed connection and authenticated signing service, which holds the SDK secret and returns short-lived SDK JWTs. Verify that the distributed build selects this configuration; the personal `ZoomSDKJWT.make` path is for an owner's own developer setup. Each person still authorizes their own Zoom identity. ZAK identifies the human user; it does **not** replace the SDK JWT or its signer. Public-client PKCE addresses OAuth, not SDK-secret distribution. [Meeting SDK authorization](https://developers.zoom.us/docs/meeting-sdk/auth/)
2. **Confirm the intended meeting accounts.** Internal users joining meetings outside the SDK app developer's account still fall under the external-meeting policy. Current policy requires review/approval plus ZAK or OBF authorization. This app implements the human-user ZAK path. For approved beta external meetings, Zoom specifically instructs developers to share the authorization URL with the external host. [SDK authorization](https://developers.zoom.us/docs/meeting-sdk/auth/), [beta sharing](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/)
3. **Prepare the General app's production configuration.** Keep the Meeting SDK enabled, configure public-client OAuth and the supported redirect, and justify the actual scopes: `user:read:zak`, `meeting:write:meeting`, and `cloud_recording:read:list_user_recordings`. Supply the required listing information, technical/security documentation, privacy policy, terms, support and user documentation. Test authorization, installation and removal as a new user. Unlisted distribution still receives review. [Production preparation](https://developers.zoom.us/docs/build-flow/prep-app-for-prod/), [review process](https://developers.zoom.us/docs/distribute/app-review-process/), [setup](Zoom-Setup.md)
4. **Keep the verified Yap branding consistent.** Google consent, its desktop-client/project display names, and the current Zoom development/production identity have been saved and read back as documented above. Keep the binary and final review screenshots aligned with that identity. The prior Zoom-variant name has been retired. Zoom's naming rules prohibit variations of “Zoom” in app names and related URLs; compatibility wording such as “Yap for Zoom” is permitted. Selecting Yap does not itself constitute trademark clearance or provider approval. [Naming requirements](https://developers.zoom.us/docs/build-flow/app-listing/app-icon-and-app-name/)

Approved external beta sharing normally lasts four weeks. During that window, its conditions prohibit making information about the app public or publicizing it as a Zoom integration. Resolve that restriction with Zoom before relying on beta approval alongside a public source launch. [Beta conditions](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/)

## Prepare Google Calendar distribution

Google Calendar is optional. The current app imports a user-supplied desktop-client JSON; it does not bundle a public Google client. The renamed project remains Testing. No change to production publishing or public Google onboarding has been selected. The following is preparation guidance, not a completed rollout.

Use a Google **Desktop app** OAuth client, enable the Calendar API, and retain the browser/PKCE/loopback flow. The client identifier is public configuration; user tokens remain private. Current scopes are `https://www.googleapis.com/auth/calendar.events.readonly` and `https://www.googleapis.com/auth/calendar.calendarlist.readonly`. Declare both in Data Access; do not expand access for distribution. [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Calendar scopes](https://developers.google.com/workspace/calendar/api/auth), [implementation](GoogleCalendar.md)

For public use, use a separate production project, verify authorized-domain ownership, provide accurate branding and a public homepage/privacy policy, and complete the applicable scope verification. Prepare scope justifications and a demonstration of consent and each Calendar feature. The privacy policy must describe actual local caching, access, storage and deletion behavior. Check the current scope classifications and approval status in Data Access/Verification Center. Changing the audience to In production does not itself verify the app. [Verification preparation](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification), [audience and publishing status](https://support.google.com/cloud/answer/15549945?hl=en)

## Separate source publication from binary delivery

Source publication is limited to project-owned files and permitted dependencies; exclude credentials, user data, signing keys and proprietary SDK files. No new source license is selected by this release checklist. The integrated app remains subject to the approval conditions above. The SDK must not be distributed as a standalone public dependency. [API Terms, section 2.7.20](https://www.zoom.com/en/trust/legal/zoom-api-license-and-tou/)

The release workflow now requires a **separate private dependency repository** for the raw Zoom SDK ZIP and verifies its visibility before downloading. Configure its repository name, release asset ID, and narrowly scoped read-only token; never publish the SDK archive as a public dependency asset. Shared binaries must use managed signing rather than distributing an owner's SDK secret. Follow [Releases](Releases.md) for the actual artifact destination and updater configuration.

## Finish macOS release acceptance

Use the existing Developer ID pipeline for team and public downloads: sign the app and all nested components, enable hardened runtime, notarize and staple the deliverables, then verify Gatekeeper. Apple notarization checks software security/signing; it is separate from provider approval. The current Zoom macOS SDK does **not support App Sandbox**, so this integration does not currently provide a Mac App Store distribution route. [Apple Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Zoom macOS requirements](https://developers.zoom.us/docs/meeting-sdk/macos/get-started/)

- On a fresh supported Mac, install the downloaded DMG, verify first launch without developer tooling, complete account onboarding and normal camera/microphone/screen-sharing permissions, and exercise calls, Calendar and recordings with the intended audience. Current releases target Apple silicon and macOS 26 or later.
- Install release N, publish N+1 through the configured feed, and verify discovery, signature validation, installation/relaunch, retained accounts/preferences, call-in-progress deferral, and failure recovery. Successful signing or notarization alone does not demonstrate update delivery.

Record that evidence and the provider approvals before describing the binary as ready for team or public use. [Release acceptance](Releases.md#first-release-acceptance)
