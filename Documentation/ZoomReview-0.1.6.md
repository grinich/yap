# Yap 0.1.6 review handoff

Prepared September 14, 2026 (Pacific), for **Yap 0.1.6, build 7**. This identifies the current public installer and its supporting evidence. It does not assert that Zoom has received this updated package, approved the app, or enabled external access. The September 7 submission for 0.1.3 is preserved in the [historical review record](ZoomReview.md).

## Exact installer

Requires an **Apple silicon Mac with macOS 26 or newer**. Download [Yap.dmg](https://github.com/grinich/yap/releases/download/v0.1.6/Yap.dmg), drag Yap to Applications, eject the disk image, and open Yap. [Release notes](ReleaseNotes/v0.1.6.md) describe the supported features and known limits.

| Item | Verified value |
| --- | --- |
| Version / build | 0.1.6 / 7 |
| Source tag / commit | `v0.1.6` / `d418d646f03311bf8aa7826a46aab30f03cc9888` |
| App identifier / signing team | `com.grinich.yap` / `VSVHNQP588` |
| DMG SHA-256 | `01482a63b0b6c3e297da14ed511244f6b310cc25f36c6490691ca2b4699d764b` |
| Update ZIP SHA-256 | `75fc38d63e9c1faa4b4dc0d1261beb01eec0e871bd2fc22e0c467cf9873008a8` |
| Zoom SDK / Sparkle | 7.1.5.84750 / 2.9.6 |
| Release pipeline | [34930690663](https://github.com/grinich/yap/actions/runs/34930690663), passed |

The downloaded app and DMG passed Developer ID signature checks, stapled notarization validation and Gatekeeper. The app inside the DMG matches the ZIP's executable, metadata, signed resource manifest and Google configuration. The ZIP and complete signed update feed passed independent public-key verification, including tamper rejection. All 102 packaged Mach-O files are arm64. Apple notarization is separate from Zoom approval.

The [end-to-end test plan](Zoom-Test-Plan.md) covers each permission, role, prerequisite, and expected result. The HTTPS sign-in correction in the working branch targets a new **0.1.7 (build 8)** review candidate; it is not included in this immutable 0.1.6 installer. Use new artifact identity and verification before handing that candidate to reviewers.

## Reviewer setup and feature coverage

- Use **Yap → Settings → Connections → Sign in to Zoom** and authorize the reviewer's own Zoom account. The release already includes its public client configuration and managed authorization-service address. No developer app, SDK secret, Cloud project, or imported credential file is needed for normal sign-in.
- Google Calendar is optional. **Connect Google Calendar** on the home screen starts browser sign-in directly; the same connection is available in Settings. Its desktop client is bundled. The last verified Google publishing state is In production, unverified, so Google's warning and user cap may apply. Google may be left disconnected while testing Zoom features.
- Test **Start new meeting**, **Join with a link…**, and clicking a Zoom invitation that opens Yap. Use a separate consenting participant for actual media, sharing and chat interoperability. A synthetic interface preview is not a live meeting test.
- Microphone, speaker and camera devices are in the native menu bar. Camera effects are in Settings → Camera. Hand controls appear when more than one person is in a call. Host permissions and hardware determine available controls.
- Test meeting chat, recipients, threaded replies, formatting, attachments and exports using synthetic content. Sent-message editing and per-message emoji reactions are not exposed by this SDK integration.
- Test selected-window sharing and computer-audio-only sharing using synthetic content. **Take photo** is the last layout-menu item; it captures cameras in batches of up to 49 and automatically saves the collage in Downloads. Background-image copies, chat downloads and photos are described in [Privacy](../PRIVACY.md).
- Cloud-recording tests require a consenting licensed test host with completed video, saved chat and transcript files. Test-account credentials must be supplied privately if needed; this document supplies no account or meeting credentials.
- Test disconnect, reconnect and provider-side app removal separately. Local disconnect is not provider-side revocation. The [user guide](../Services/zoom-auth/site/guide.md) describes installation, normal use, removal and troubleshooting.

## Current security and test evidence

[CI 34930641231](https://github.com/grinich/yap/actions/runs/34930641231) and the actual-SDK release passed **772 Swift tests in 96 suites**, **52 Python release-safety tests**, and the authorization-service checks. The release also passed **10 native bridge suites**, covering camera effects, media devices, chat audiences/content, computer audio, photo readiness/shutter, share status, recording policy and render lifecycle. These tests include fixtures; they do not establish live interoperability with every Zoom client or account.

[CodeQL run 34930641218](https://github.com/grinich/yap/actions/runs/34930641218) completed on the exact release commit with CodeQL **2.27.0** and the configured `security-extended` queries:

| Language | Analysis | Rules / results | Completed analysis (UTC, September 15) |
| --- | --- | --- | --- |
| Swift | [1776991012](https://api.github.com/repos/grinich/yap/code-scanning/analyses/1776991012) | 28 / 0 | 05:12:06 |
| JavaScript/TypeScript | [1776939386](https://api.github.com/repos/grinich/yap/code-scanning/analyses/1776939386) | 103 / 0 | 04:55:36 |

Both analysis records have empty error and warning fields. These are uploaded rule counts. The Swift extraction builds the product without the proprietary Zoom SDK; conditional SDK integration, Objective-C, vendor binaries and deployed infrastructure are not covered by this scan. Zero results are not a certification or a guarantee that vulnerabilities are absent. The [security evidence inventory](SecurityEvidence.md) preserves historical assessments and explains the boundaries.

The downloaded 0.1.6 app was launched in local preview. Calendar title/time, threaded chat, local message composition, Raise/Lower hand and native microphone menus were exercised. No live participant messages were sent in that check. Real two-client verification of every new chat/media feature, fresh-Mac onboarding, provider revocation and an installed N → N+1 updater transition are not claimed here. Nearby Zoom Room pairing remains experimental.

## Portal handoff

Before changing the review submission, read every current Zoom review note and map each requested correction to its evidence. If this installer is supplied, use its exact version and hashes above and replace obsolete installation instructions; do not relabel the 0.1.3 SAST attachment as a scan of 0.1.6. Keep reviewer notes and private test credentials out of public source. Portal responses and resubmission are separate from preparing this packet.
