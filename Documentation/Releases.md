# GitHub releases and automatic updates

Yap's source and release destination are `grinich/yap`. The current candidate for the first public release is **0.1.3, build 4**, tag `v0.1.3`, source `b920870e4a4a1f53b31d6f73c818c5aa2f75e5cf`. It corrects the managed sign-in Keychain transition discovered in 0.1.2 and retains the Sparkle startup fix. Actual-SDK packaging, independent artifact verification, exact-tag CodeQL and scoped managed-native acceptance passed. The installer remains an unpublished draft while the submitted app is in Zoom functional review; approval and broader acceptance remain pending. Earlier 0.1.2, 0.1.1 and 0.1.0 tags/assets remain immutable, superseded evidence.

The final native PNG gallery, agenda and recording screenshots are published in the README through [PR #9](https://github.com/grinich/yap/pull/9); their [capture provenance](Images/README.md) distinguishes sample content from live private meetings. Google consent is **Yap**; its desktop client and project display names are **Yap for Mac**. The current Zoom development and production identity is **Yap**. Google remains **Testing**, without public verification approval or a new public rollout decision. [Provider branding checkpoint](Distribution.md#provider-branding-checkpoint).

Raw proprietary SDK dependencies remain in a separate private repository; no SDK archive belongs in public source or releases. The workflow verifies this separation before downloading. A public source repository does not establish permission to distribute the integrated SDK application. Complete the [distribution requirements](Distribution.md) before publication. A separate public binary repository is supported. Private updater delivery would require authenticated feed/download support; do not embed a GitHub token or point Sparkle at private GitHub URLs.

## First release: v0.1.3

**Signed and notarized GitHub draft; no public download.** Draft **384441843** contains the five independently verified assets below. These planned public URLs become available only after publication:

| Draft asset | Purpose |
| --- | --- |
| [Yap.dmg](https://github.com/grinich/yap/releases/download/v0.1.3/Yap.dmg) | Installer for Apple silicon, macOS 26 or newer |
| [Yap.dmg.sha256](https://github.com/grinich/yap/releases/download/v0.1.3/Yap.dmg.sha256) | DMG checksum |
| [Yap-macOS.zip](https://github.com/grinich/yap/releases/download/v0.1.3/Yap-macOS.zip) | App archive and Sparkle update payload |
| [Yap-macOS.zip.sha256](https://github.com/grinich/yap/releases/download/v0.1.3/Yap-macOS.zip.sha256) | ZIP checksum |
| [appcast.xml](https://github.com/grinich/yap/releases/download/v0.1.3/appcast.xml) | Signed update feed |

Once approved for the intended audience and published, open the DMG, drag **Yap.app** to **Applications**, eject the disk image, and launch Yap. Alternatively expand the ZIP and move its app to Applications. Use normal macOS verification; do not remove quarantine or disable Gatekeeper. Optionally place the matching checksum beside its artifact and run `shasum -a 256 -c Yap.dmg.sha256` or `shasum -a 256 -c Yap-macOS.zip.sha256`. Checksums are separate from Apple signature/notarization verification.

Each user authorizes their own Zoom account through the bundled managed configuration. Google Calendar is optional and currently uses an imported desktop-client JSON; its project remains Testing. Previous app users should quit the older app and review [identity migration](Bundle-Identity.md). The [release notes](ReleaseNotes/v0.1.3.md) describe the correction and availability limits.

A tag push or preparation dispatch creates a draft; it does not publish the installer or latest feed. Use one preparation trigger. Promotion of a verified existing draft is described below and must preserve its exact assets.

## Current candidate evidence

**Yap 0.1.3 (build 4)**, source `b920870e4a4a1f53b31d6f73c818c5aa2f75e5cf`, artifact checkpoint **04:20:13 UTC on September 8, 2026**.

| Check | Result / evidence |
| --- | --- |
| Source and tests | [PR #10](https://github.com/grinich/yap/pull/10) merged as the exact tag/source above. [PR CI 34185005400](https://github.com/grinich/yap/actions/runs/34185005400) passed **647 Swift tests / 77 suites, 40 Python tests and 24 service tests**. The isolated actual-SDK suite also passed 647 tests / 77 suites. |
| Keychain transition regression | Active Zoom tokens and personal configuration are removed in one vault commit; failed writes leave both intact. Scoped legacy cleanup attempts continue after an error, the first denial is reported and UI state reconciles. Tests cover tombstones, retry/no revival, protected cleanup and Google preservation. Keychain ACLs are unchanged. |
| Actual-SDK release | [Run 34185478572](https://github.com/grinich/yap/actions/runs/34185478572) passed actual-SDK tests, packaging, signing, notarization, stapling and Gatekeeper; draft **384441843** is unpublished. |
| App notarization | Apple Accepted; submission `43bbd9f1-2025-46f2-b422-50c6eafe7a30`, **04:09:22 UTC on September 8, 2026**. |
| DMG notarization | Apple Accepted; submission `5954c923-c9fb-4562-ab4b-ff92d99c7d21`, **04:12:36 UTC on September 8, 2026**. |
| Independent downloads | All five GitHub digests, both checksum files, app/DMG Developer ID signatures, stapled notarization, Gatekeeper and DMG integrity passed. Bundle version/identity, managed public configuration, endpoint/feed and both Sparkle prerequisites match. This check did not launch or install the app. |
| Update signatures | The bundled public key independently verified ZIP and complete signed appcast content with CryptoKit. Content length/trailing data checks and tampered-content rejection passed; N → N+1 delivery remains unverified. |
| Exact-tag SAST | [Run 34185481943](https://github.com/grinich/yap/actions/runs/34185481943) passed at **04:33:08 UTC**. Swift analysis **1738803023: 28 rules / 0 results**; JavaScript/TypeScript **1738719791: 103 / 0**; CodeQL 2.26.4, empty analysis errors/warnings. Open tag/repository alerts: **0** at **04:33:54 UTC**. [Exact coverage and limits](SecurityEvidence.md#codeql-configuration-and-coverage). |
| Native acceptance | Normal installation, managed Zoom/Google persistence, real cloud video/chat/transcript, playback shortcuts, fullscreen, solo managed hosting/ending, About/icon and login switch passed. [Scope and remaining tests](#native-acceptance). |
| Distribution | Submitted **September 7, 2026 at 21:46 PDT**, observed **04:47:04 UTC on September 8**; Publish **In review**, **Functional review**, manual activation selected. Current SAST/architecture/SSDLC and gallery are saved, and private reviewer delivery matches the verified DMG. No approval, external activation or public release is asserted. |

**Current 0.1.3 downloaded asset SHA-256**, independently checked against GitHub; ZIP/DMG also match their checksum files:

| Asset | Bytes | GitHub asset ID | SHA-256 |
| --- | ---: | ---: | --- |
| `Yap-macOS.zip` | 291320319 | 549840571 | `13775750dae24b38a52b423035cdf827756ab5b0c6c7b58802fc8df0e64172bf` |
| `Yap-macOS.zip.sha256` | 80 | 549840581 | `9cd4dbd7c83e63016bb9851afe06a1771ef12291483b894c15b05aad21841550` |
| `Yap.dmg` | 351085520 | 549840579 | `9c21f613318d0a3cd7d6e7a71d81e30cb20a355208c07ff3cd2cdbe1eb865175` |
| `Yap.dmg.sha256` | 74 | 549840572 | `c684b3ba4a26a7d4cc1d4af84c6e0953a14b088a30a6ce6615137f7ed9a818e7` |
| `appcast.xml` | 1250 | 549840575 | `660e1a3aa124c325ebfc2b5b67c690bc1b77cec45c5c24013f4b1f78755cf448` |

## Private reviewer delivery

A separate private reviewer endpoint was verified at **04:33:56 UTC on September 8, 2026** by downloading the complete **351,085,520-byte** DMG and matching SHA-256 `9c21f613318d0a3cd7d6e7a71d81e30cb20a355208c07ff3cd2cdbe1eb865175`. Authorized GET/HEAD and byte ranges passed; anonymous and incorrect-token requests were rejected. The temporary uploader was deleted and the final downloader check still passed. The URL is kept private and access expires **October 8, 2026 at 04:29:19 UTC**. This reviewer delivery does not publish the GitHub draft or activate the public update feed.

## Native acceptance

The release operator separately installed the independently verified, downloaded **0.1.3 (build 4)** normally. Startup had no updater error; Google and selected calendars persisted, and Zoom remained connected in **managed mode**. Real cloud video, automatic chat presentation and an actual timestamped transcript loaded. Space paused at 12 seconds, S selected 1.25× and Right moved to 22 seconds; V changed the view while preserving that position, pause and speed. F entered and exited fullscreen. A managed one-person hosted meeting started with microphone muted and camera off, and normal End for Everyone returned to the agenda. About showed Yap 0.1.3 (4) and the clean four-face icon; the login switch was turned on and restored to its original off state. Help → Report a Bug opened the GitHub issue-template chooser without creating an issue. Both accounts ended connected with no active meeting.

The preceding local optimized build at `66dac66` separately passed personal-to-managed switching, local disconnect/account-state clearing, production PKCE reauthorization, restart and Google preservation. macOS still reported denial of protected legacy-item cleanup; the active-vault change and UI state now completed correctly without bypassing Keychain protections. Local disconnect is not provider-side revocation. **Fresh-Mac onboarding, multiuser/external meetings, live token refresh, provider-side revocation and N → N+1 update installation remain unverified.**

<a id="first-release-v012"></a>

## Superseded candidate: v0.1.2

**Do not install or promote the 0.1.2 draft.** Its managed sign-in transition failed after partial credential cleanup; 0.1.3 corrects the active-vault and UI-state behavior. Draft **384418390**, tag/source and all five assets remain unchanged. These historical results do not verify the new 0.1.3 bytes.


**Historical Yap 0.1.2 (build 3)**, artifact checkpoint **03:05:38 UTC on September 8, 2026**. This evidence belongs to `01078d5918db5bd8c33e368ec49fce030e4a03be`, tag `v0.1.2`; older artifact hashes and scan results do not verify this source or its new package.

| Check | Result / evidence |
| --- | --- |
| Source and pre-merge tests | [PR #7](https://github.com/grinich/yap/pull/7) merged at `01078d5918db5bd8c33e368ec49fce030e4a03be`. [PR CI 34180726835](https://github.com/grinich/yap/actions/runs/34180726835) passed; recorded validation is **644 Swift tests / 77 suites, 40 Python tests and 24 authorization-service tests**. |
| Updater startup regression | An offline check calls the actual Sparkle updater: the previous configuration is rejected with error 5, and adding `SUVerifyUpdateBeforeExtraction=true` alongside `SURequireSignedFeed=true` is accepted. Existing signed-feed/archive tamper tests also pass. This does not perform a network update or prove N → N+1 installation. |
| Actual-SDK packaging and delivery | [release run 34181128184](https://github.com/grinich/yap/actions/runs/34181128184) passed actual-SDK tests, packaging, Developer ID signing, app/DMG notarization, stapling and Gatekeeper. Draft **384418390** contains all five assets; it is not published/latest. |
| App notarization | Apple Accepted; submission `23c89640-2a59-4c23-b2b6-f987c6dce891`, recorded at **02:54:03 UTC on September 8, 2026**. |
| DMG notarization | Apple Accepted; submission `9f4d357c-db35-4aad-9ed0-9b53cabdfa65`, recorded at **02:57:23 UTC on September 8, 2026**. |
| Independent downloaded verification | Passed at **03:05:38 UTC on September 8, 2026**. All five GitHub digests and both checksum files match. Strict app/DMG Developer ID signatures, stapled notarization, Gatekeeper and DMG integrity passed. Bundle identity/version, workers.dev endpoint, update feed and both Sparkle verification prerequisites were confirmed. This verification step did not launch or install the app. |
| Downloaded update signatures | CryptoKit verified the ZIP and complete signed appcast content with the bundled public key. Appcast content length and absence of extra unsigned trailing content were checked; an in-memory tampered copy was rejected. These signature checks do not establish native behavior; the separate startup result below passed, while N → N+1 installation remains pending. |
| Exact-tag security scan | [Run 34181127659](https://github.com/grinich/yap/actions/runs/34181127659) passed at **03:16:39 UTC on September 8, 2026** on the exact tag/source above. CodeQL 2.26.4: Swift [1738606742](https://api.github.com/repos/grinich/yap/code-scanning/analyses/1738606742), **28 rules / 0 results**; JavaScript/TypeScript [1738537368](https://api.github.com/repos/grinich/yap/code-scanning/analyses/1738537368), **103 / 0**; empty errors/warnings. Zero open tag/repository alerts at **03:16:43 UTC**. [Coverage](SecurityEvidence.md#codeql-configuration-and-coverage). |
| Native acceptance | Startup, icon/login and personal-mode recording/SDK checks passed. Switching to managed sign-in exposed a Keychain transition bug; that failure superseded 0.1.2. These personal-mode checks are not managed acceptance. The fix and current managed checks belong to 0.1.3 above. |
| Distribution | Draft 384418390 remains superseded and unpublished. Its tag and five assets are preserved unchanged; use the current 0.1.3 candidate above for submission. |

**Historical 0.1.2 downloaded asset SHA-256**, independently checked against GitHub asset digests. ZIP and DMG also match their uploaded checksum-file contents:

| Asset | Bytes | GitHub asset ID | SHA-256 |
| --- | ---: | ---: | --- |
| `Yap-macOS.zip` | 291317392 | 549765036 | `9aac5d9bcec89995072a96d109cc3d6012e7b5c80cfff55abd98e058cb6430fc` |
| `Yap-macOS.zip.sha256` | 80 | 549765032 | `30eaf878bd856cf455b66063a97d9f14123b63ad5548020e0e39ec640b7094b8` |
| `Yap.dmg` | 348928944 | 549765034 | `7857726efcaa18ddd9af87fb36fdb282e804d76818bb9144b605164d9b993d43` |
| `Yap.dmg.sha256` | 74 | 549765031 | `b7bcd3592fe20bc3d4a84b4e65641fb70a5c027148b088c0cad6d3ab105f3082` |
| `appcast.xml` | 1250 | 549765035 | `7805920cfea2c31b342e7c433a1ce0e09e6d6420678f49f9eed3359307afba4c` |

## Superseded candidate: v0.1.1

**Do not install or promote the 0.1.1 draft.** Native testing found a startup modal, “Unable to Check For Updates / The updater failed to start.” Sparkle error 5 identified the missing `SUVerifyUpdateBeforeExtraction` requirement when `SURequireSignedFeed` is enabled. Draft **384360449** has superseded title/notes; tag `v0.1.1`, source `283e37cfddc47cac213be884f5dab6582a8713b0`, and all five asset bytes remain unchanged. The historical integrity checks below do not establish successful updater startup. The correction receives a new version and new artifacts in 0.1.2.

Native 0.1.1 validation passed the installed icon/About presentation, login-item toggle, Help → Report a Bug, and recordings-view chrome. Live account and playback acceptance stopped at a protected macOS Keychain prompt, which was not bypassed. These partial checks and the startup failure are retained in the local native-validation report; repeat acceptance on the corrected release.

**Historical Yap 0.1.1 (build 2) evidence**, reported September 7, 2026. All results and hashes in this section belong only to `283e37cfddc47cac213be884f5dab6582a8713b0` and tag `v0.1.1`.

| Check | Result / evidence |
| --- | --- |
| Source and CI | [Main CI 34169878107](https://github.com/grinich/yap/actions/runs/34169878107) passed on `283e37cfddc47cac213be884f5dab6582a8713b0`. |
| Actual-SDK release | [Release run 34169899197](https://github.com/grinich/yap/actions/runs/34169899197) passed, including actual-SDK tests, Developer ID signing, app/DMG notarization, stapling and Gatekeeper checks. |
| App notarization | Apple Accepted; submission `0e889e8b-488f-43ff-97e8-5d8800edbb18`, recorded at 23:30:54 UTC on September 7, 2026. |
| DMG notarization | Apple Accepted; submission `5f0e64a5-b687-4ca4-b50a-4daab74215c2`, recorded at 23:34:09 UTC on September 7, 2026. |
| Delivery | GitHub draft `384360449`, tag `v0.1.1`, contains all five release assets. It is not published or available through the public latest feed. |
| Independent downloaded verification | Passed at **2026-09-07 23:44:30 UTC**. All five SHA-256 values match GitHub asset digests; ZIP/DMG also match their `.sha256` files. App/DMG strict signature verification, Developer ID identity, stapled notarization and Gatekeeper checks passed; DMG container integrity passed. Bundle version, managed endpoint and update feed were verified. That artifact-verification step did not launch, install or mount the app; later native testing found the startup failure described above. |
| Downloaded update signature | CryptoKit independently verified the downloaded ZIP's Ed25519 signature using the public key bundled in Yap.app. This verifies the archive signature; it is not an independent verification of the entire appcast signature or updater installation. |
| Native acceptance outcome | Subsequent installation testing found the blocking Sparkle updater startup error 5. Icon/About, login-item toggle, Help link and recordings chrome passed; protected Keychain access and live account/SDK/playback checks remain pending. This candidate is superseded, not acceptable for promotion. |

**Historical 0.1.1 downloaded asset SHA-256**, independently checked against GitHub. The ZIP and DMG also match their corresponding checksum-file contents:

| Asset | Bytes | GitHub asset ID | SHA-256 |
| --- | ---: | ---: | --- |
| `Yap-macOS.zip` | 291317123 | 549530344 | `c5696e659cab21d20de37a640583fad2a9bc111f1c27dca3a126cc8f7b7aac24` |
| `Yap-macOS.zip.sha256` | 80 | 549530345 | `1c76096b351485e9c5922f84dd58a206cde3f626522817d1a909d85f18356f9c` |
| `Yap.dmg` | 350847296 | 549530341 | `03c7726832097eb344ee2b8b610e8c20be971ae7924ced4dae6bba088184d988` |
| `Yap.dmg.sha256` | 74 | 549530339 | `7d49bb197c0ce4eb96f10b3482d8497686a0c42a932fe2e5c483a876f7f17a03` |
| `appcast.xml` | 1250 | 549530338 | `51329aef4fc3e4d84746008a852b253b6176a47f5db36343e26a1e1ce0d3acb4` |

## Superseded candidate: v0.1.0

**Do not install or promote the 0.1.0 draft.** Its tag and five signed assets remain unchanged for traceability. It predates the corrected icon and current managed endpoint. The successful packaging evidence below applies only to those historical bytes, not to the current 0.1.3 candidate. See the [historical release notes](ReleaseNotes/v0.1.0.md).

## Release-candidate evidence

**Historical 0.1.0 (build 1) evidence**, reported by the release operator on **September 7, 2026**. The source is [PR #4](https://github.com/grinich/yap/pull/4), merged at `ac394cd9a0834da2d3b58faed5e52efee980d246`. The superseded draft is not for installation. All artifact hashes, notarization submissions and release-run results in this section belong to 0.1.0. Historical 0.1.1/0.1.2 and current 0.1.3 results are recorded separately above.

| Check | Result / evidence |
| --- | --- |
| Source | [PR #4](https://github.com/grinich/yap/pull/4) merged to main as `ac394cd9a0834da2d3b58faed5e52efee980d246`; tag `v0.1.0` exists. |
| Release test baseline | Commit `3c316ce`: [CI run 34166643648](https://github.com/grinich/yap/actions/runs/34166643648) and [CI run 34166640977](https://github.com/grinich/yap/actions/runs/34166640977) passed. Baseline: **644 Swift tests in 77 suites, 39 Python release/script tests, 23 authentication-service tests**. |
| Merged-main validation | [Main CI 34166962118](https://github.com/grinich/yap/actions/runs/34166962118) passed. |
| Security analysis | [Merged-main CodeQL run 34166962123](https://github.com/grinich/yap/actions/runs/34166962123) passed on `ac394cd9a0834da2d3b58faed5e52efee980d246`. CodeQL **2.26.4** completed Swift analysis with **28 rules / 0 results** and JavaScript/TypeScript with **103 rules / 0 results**, without reported analysis errors or warnings. The repository query returned **zero open code-scanning alerts** at this checkpoint. |
| Actual SDK packaging | [Release run 34166976838](https://github.com/grinich/yap/actions/runs/34166976838) passed its actual-SDK tests and completed signing, notarization, stapling and Gatekeeper checks before creating the draft. The workflow completed successfully and uploaded all five assets. |
| App notarization | Accepted; submission `dfc7c892-1b7d-449a-b72b-c6c5f26b31e2`. |
| DMG notarization | Accepted; submission `aa346fce-a30d-44d7-819d-4d900bd57c15`. |
| Delivery | GitHub draft exists; it is **not published**. Downloaded ZIP/DMG hashes match both checksum files and GitHub asset digests. App/DMG notarization and Gatekeeper checks passed again locally; final installation acceptance remains pending. |
| Downloaded update signature | An independent CryptoKit `Curve25519.Signing.PublicKey` check verified the downloaded ZIP's Ed25519 signature using `SUPublicEDKey` from the extracted Yap.app bundle. This public-key check did not require the release signing private key. |

**Historical 0.1.0** downloaded artifact SHA-256 values, independently checked against GitHub asset digests. The ZIP and DMG also match their uploaded `.sha256` files; no separate checksum file is published for `appcast.xml`:

| Asset | SHA-256 |
| --- | --- |
| `Yap-macOS.zip` | `cdac14fc07150cc692dffae0133b416054cb782aecd947bc5c05e47a1f154773` |
| `Yap.dmg` | `cc502c293122d40bff5a5b7fd32f28dfb35706329d15c2074e6eb4c1b05f9040` |
| `appcast.xml` | `ddc1246f00471132e73797bb529179ed551c0c1a08fd564b1da008ea46fb827e` |

The 0.1.0 draft remains private and superseded; its successful checks do not authorize installation or publication. Preserve its workflow logs, assets and notarization results without repacking or reusing the version. Use the separate current-candidate evidence above when evaluating 0.1.3.

## Current service validation

Service fix [`9d4e1dd`](https://github.com/grinich/yap/commit/9d4e1dd) passed **24 service tests** and an actual local `workerd` before/after regression check. Live production browser PKCE/callback, token exchange with all three required scopes, one bounded recordings-list page and an SDK-signature response passed at `https://meeting-auth.mgrinich.workers.dev` on deployment `31a76568-0191-4f73-a3e7-d530fbc52966`. Credentials remained in process memory. The current API-only deployment is `23757fca-b323-4f65-a8ce-42255449c072`; it removes static document serving without changing authentication logic. Its health endpoint returns 200 and `/terms` returns 404. Public documentation and Terms use GitHub. [Scope and limits](SecurityEvidence.md#production-service-acceptance).

The current downloaded 0.1.3 managed-native acceptance and its remaining limits are recorded [above](#native-acceptance). Historical personal-mode checks do not substitute for that evidence.

## Implemented

- CI on pull requests and main/codex branches: Xcode 26.6 on Apple's `macos-26` hosted runner, locked Sparkle dependency, SDK-free application tests, packaging/signature checks, release validation tests, an offline signed-update tampering test, and an actual-Sparkle startup configuration regression check.
- Source `v*` tags trigger `.github/workflows/release.yml` and prepare a draft. Manual dispatch accepts an existing tag and also defaults to a draft; only explicit `publish=true` requests publication.
- Releases require a reviewed tag on main, an increasing version/build number, and the exact private Zoom SDK ZIP pinned by SHA-256 in `Resources/ZoomSDK.lock.json`. A release cannot silently compile without the Zoom bridge.
- The release imports Developer ID and notarization credentials into a temporary CI keychain, then signs nested Zoom/Sparkle helpers inside out. It notarizes/staples the app and DMG, validates Gatekeeper, generates the final ZIP, and signs both the archive and appcast with Sparkle Ed25519.
- Preparation creates a draft in the configured distribution repo with all five artifacts. The explicit publishing path marks the complete release published/latest only after all uploads succeed. A failed upload cannot expose a new feed before its archive is available. Published releases are not overwritten.
- The app includes the complete upstream Sparkle license and Zoom open-source notices in `Contents/Resources/ThirdPartyLicenses`. Packaging fails if either notice is missing.
- Installers: `Yap.dmg`, `Yap-macOS.zip`, two SHA-256 files, and `appcast.xml`. Apple silicon and macOS 26 or newer; this is not a universal Intel build.
- In-app Sparkle checks every six hours, downloads updates automatically, verifies signatures, and supports installation on quit or via the standard update dialog. “Yap → Check for Updates…” is available when configured. Profile sending is off. The menu, update-check delegate, and final relaunch delegate reject updates during an active/joining meeting. If installation was attempted during a call, check again after leaving; the updater does not end calls automatically.
- Unconfigured local/preview builds do not contact an update server. They still bundle Sparkle and show a disabled Check for Updates item.

The signing and artifact pipeline follows [Replay's release workflow](https://github.com/grinich/replay/blob/main/.github/workflows/release.yml). Replay uses a custom updater; Yap uses [Sparkle's maintained installer](https://sparkle-project.org/documentation/) and [its supported manual signing order](https://sparkle-project.org/documentation/sandboxing/#code-signing).

## Signing credentials

Configured September 7, 2026: the existing Developer ID Application certificate for team `VSVHNQP588`, a dedicated Developer-role notarization API key (its existing provider label is `Zooom Notarization`), and a dedicated Sparkle key. The existing Apple/Sparkle credentials were configured before the rename. The release configuration now uses the `YAP_` variable names below; verify the corresponding repository variables before packaging. Credentials are not source files or public release assets. Private keys have secure local Keychain copies; temporary exports were removed.

[Apple Signing passed on a fresh GitHub runner](https://github.com/grinich/yap/actions/runs/34149118682), including credential import, secure timestamping, Apple notarization, stapling, and Gatekeeper. The historical 0.1.0 `com.grinich.yap` candidate passed those checks with its actual Zoom/Sparkle bundle in [release run 34166976838](https://github.com/grinich/yap/actions/runs/34166976838); its app and DMG submission IDs are recorded above. Download and installation acceptance remain separate.

The current Developer ID certificate expires February 1, 2027. Renew it before signing new builds after that date. Existing timestamped releases retain their signature validity after certificate expiry, subject to Apple's normal revocation checks; see [Apple's explanation of secure timestamps](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates).

## Distribution configuration

1. Use `grinich/yap` as the public release destination and `https://github.com/grinich/yap/releases/latest/download/appcast.xml` as the update feed. No release is available at that feed until the first installer is published. A separate public binary repository is optional.
2. The source repository's `release` environment and Apple/Sparkle credentials are configured. Verify the distribution variables and token below before packaging. Any environment branch restrictions must permit both the release tags and the source branches used by the Apple Signing check.

| Type | Name | Value/source |
| --- | --- | --- |
| Variable | `YAP_RELEASE_REPOSITORY` | `grinich/yap`, or a separate public `owner/name` |
| Variable | `YAP_UPDATE_FEED_URL` | `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml` |
| Variable | `YAP_UPDATE_PUBLIC_KEY` | Yap's existing Sparkle Ed25519 public key |
| Variable | `ZOOM_SDK_REPOSITORY` | Separate private dependency repository, `owner/name` |
| Variable | `ZOOM_SDK_ASSET_ID` | Asset ID of the exact locked SDK ZIP in that private repository |
| Secret | `ZOOM_SDK_READ_TOKEN` | Fine-grained Contents read-only token limited to the private dependency repository |
| Secret | `DEVELOPER_ID_P12_BASE64` | Original Developer ID certificate and private key export, base64 |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | Password for that export |
| Secret | `APPLE_API_KEY_ID` | App Store Connect notarization API key ID |
| Secret | `APPLE_API_ISSUER_ID` | Issuer ID |
| Secret | `APPLE_API_PRIVATE_KEY_BASE64` | Original `.p8` key contents, base64 |
| Secret | `SPARKLE_PRIVATE_KEY` | Exported Yap update-signing key (base64 text as exported by `generate_keys`) |
| Secret | `YAP_RELEASE_TOKEN` | Only needed for a separate distribution repo; Contents read/write limited to that repo. Same-repo releases use the scoped workflow token. |

The Developer ID must belong to team `VSVHNQP588`, matching the project's existing signing identity; the Yap bundle identifier is new. Replay's original Apple credentials can be reused; GitHub only exposes secret names and cannot return their saved values. Do not print credentials, commit them, export unrelated Keychain identities, or broaden the developer's login Keychain permissions. The CI keychain script refuses to run outside GitHub Actions.

3. Create a **separate private dependency repository** and store the unmodified `zoom-sdk-macos-7.1.5.84750.zip` as one of its release assets. Set the repository, numeric asset ID, and read-only token above. `download-zoom-sdk.py` requires GitHub to confirm that exact repository is private and different from both source and distribution repositories before requesting any asset bytes. `prepare-zoom-sdk.py` verifies the pinned checksum before extraction. Temporary SDK downloads and extraction are removed after the job; public artifacts contain only the integrated app and installers. Local developers obtain the SDK directly from Zoom.
4. The existing production Sparkle key remains stored under the legacy Keychain account `com.grinich.zooom`; the bundle rename does not create a new update-signing key. When recovering it, export that exact account using `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.grinich.zooom -x /protected/path/sparkle-key.txt`. Do not generate a replacement for an existing update trust chain. `test-update-signatures.py` uses published RFC 8032 test keys only; those **must never be used for releases**.
5. Complete the signer/onboarding and Zoom distribution work in [Distribution](Distribution.md). Commit the final source and `Package.resolved` to main. Increase both `CFBundleShortVersionString` (x.y.z) and integer `CFBundleVersion` for every release. Tag the commit with its new version; the current immutable tag is `v0.1.3`. A tag push or manual dispatch with `publish=false` prepares a GitHub draft and leaves the public release/feed unchanged. SDK-integrated Actions artifact uploads are disabled on that draft path. Only explicit `publish=true` for a fresh release publishes the complete release and allows its Actions artifact upload. The workflow rejects an existing draft or published release rather than overwriting it. [GitHub artifact access](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

Once Zoom approval covers public distribution and the draft's exact artifacts have passed acceptance, update the draft's review-only release notes and explicitly promote those verified bytes:

```sh
gh release edit v0.1.3 --repo grinich/yap --draft=false --latest
```

That operation makes the installers and latest update feed public. Do not run it while approval is pending, delete a verified draft just to rerun the workflow, or repack its signed artifacts during promotion.

## First-release acceptance

The **Apple Signing** workflow independently checks the saved GitHub credentials. It runs manually or when its workflow/signing scripts change on a trusted source branch. It uses the same temporary-keychain import as a release, then signs, notarizes, staples, and checks a disposable app with Gatekeeper. This needs no Zoom SDK upload or public distribution repository. It does not publish or install anything. Its report distinguishes successful credential validation from notarization of the actual Yap/Zoom/Sparkle bundle.

Personal installs made before the update feed was configured need a one-time normal install of the first notarized updater-enabled release. Installations on `com.grinich.zooom`, `com.grinich.woosh` or `app.whoosh.personal` need the explicit identity migration described in [Bundle Identity](Bundle-Identity.md). Subsequent `com.grinich.yap` updates retain the new identity; Sparkle does not change application identity.

Before calling the updater live, install version N from the DMG, publish N+1, and verify manual update, automatic discovery, on-quit installation, relaunch, retained accounts/preferences, call-in-progress veto, offline errors, and denied folder-write access. The superseded 0.1.1 app/DMG passed signing and notarization but failed native updater startup. The corrected 0.1.3 package passed artifact/signature checks and native updater startup. The unpublished draft feed cannot deliver a public update; the preceding 0.1.2 check received HTTP 404 for that reason. Current managed-native results are recorded above; N → N+1 update installation and broader acceptance remain unverified. Public publication and an actual N → N+1 installation have **not yet run**. Signing success does not establish end-to-end update delivery.

Local production packaging uses `Scripts/package-release.sh` with the same variables as CI plus `YAP_ZOOM_SDK_PATH`, `YAP_SIGNING_IDENTITY`, `YAP_NOTARY_PROFILE`, optional `YAP_NOTARY_KEYCHAIN`, and `YAP_UPDATE_PRIVATE_KEY_FILE`. It fails if notarization or update signing is unavailable. It does not publish or launch the app. Personal debug builds remain available through `Scripts/build-app.sh` without release credentials. Set `YAP_OUTPUT_DIR` to stage a separate build while someone is running `outputs/Yap.app`; the builder refuses to replace a running output bundle.

## Public-preview verification

**Historical pre-Yap package, September 7, 2026:** 608 Swift tests in 73 suites passed with the real Zoom SDK, and 18 Python release/signing/dependency tests passed. The signed app was built, installed, and restarted; Help → Report a Bug opened this repository’s issue-creation page in the default browser. Bundled Sparkle and Zoom notices matched their upstream files byte-for-byte. GitHub CI passed the SDK-free test/build/signature checks, and the Apple Signing workflow independently passed its disposable-app notarization check. README screenshots use sample data and original local recording content. This validates the public source preview; the binary distribution and updater acceptance items above still apply.

## Recovery

- If a public release is bad, stop offering it by publishing a higher build number with the fix; do not overwrite archive bytes or reuse a signed version. Removing its latest status/feed can halt discovery but cannot undo already installed updates.
- If draft publication fails, inspect/delete that incomplete draft before retrying the same tag. Older published versions remain available.
- When publication is explicitly enabled, Actions artifacts are retained for 14 days. The draft-only path does not upload those SDK-integrated artifacts. Signing keys are deleted with the temporary runner/keychain. The app contains only the public update key, public feed URL, and normal OAuth setup UI.
- This pipeline does not certify Zoom redistribution/account onboarding, guest-call behavior, large-meeting capacity, or other production-readiness items in the existing QA documents.
