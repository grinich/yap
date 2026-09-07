# GitHub releases and automatic updates

Yap's source and release destination are `grinich/yap`. The current candidate for the first public release is **0.1.1, build 2**, packaged under tag `v0.1.1` as an unpublished GitHub draft. It includes the corrected native icon and the managed endpoint `https://meeting-auth.mgrinich.workers.dev`. Its actual-SDK release workflow completed packaging, signing, app/DMG notarization, stapling and Gatekeeper checks. Independent downloaded-artifact verification passed on September 7, 2026; native installation acceptance remains pending. The immutable `v0.1.0` tag and draft are superseded: retain them as historical evidence, but do not install or promote that candidate. Raw proprietary SDK dependencies remain in a separate private repository; no SDK archive belongs in the public source repository or its releases. The release workflow verifies that separation before downloading the SDK. Publishing the source is separate from authorizing a distributable Zoom integration: complete the [team and public distribution requirements](Distribution.md) before publishing a working installer.

The workflow can also publish to a separately configured public binary repository. Private installers would require an authenticated feed/download service and additional client support; do not point Sparkle at private GitHub asset URLs or ship a GitHub token.

## First release: v0.1.1

**Signed and notarized GitHub draft; not published.** [Release run 34169899197](https://github.com/grinich/yap/actions/runs/34169899197) succeeded for `283e37cfddc47cac213be884f5dab6582a8713b0` and uploaded the five assets below. Independent downloaded-artifact verification passed at 23:44:30 UTC on September 7, 2026. These URLs become publicly available only after publication, which also requires Zoom approval and native acceptance.

| Draft asset | Purpose |
| --- | --- |
| [Yap.dmg](https://github.com/grinich/yap/releases/download/v0.1.1/Yap.dmg) | Installer for Apple silicon, macOS 26 or newer |
| [Yap.dmg.sha256](https://github.com/grinich/yap/releases/download/v0.1.1/Yap.dmg.sha256) | DMG checksum |
| [Yap-macOS.zip](https://github.com/grinich/yap/releases/download/v0.1.1/Yap-macOS.zip) | App archive and Sparkle update payload |
| [Yap-macOS.zip.sha256](https://github.com/grinich/yap/releases/download/v0.1.1/Yap-macOS.zip.sha256) | ZIP checksum |
| [appcast.xml](https://github.com/grinich/yap/releases/download/v0.1.1/appcast.xml) | Signed update feed for this release |

Once published, download `Yap.dmg`, open it, drag **Yap.app** to **Applications**, eject the disk image, and open Yap from Applications. The ZIP can instead be expanded and its Yap.app moved to Applications. The downloaded bundle identity was verified as `com.grinich.yap`, version `0.1.1`, build `2`, signed by Michael Grinich's Developer ID team `VSVHNQP588`. Its workers.dev managed endpoint and configured update feed also matched the release configuration. These checks did not launch or install the app. Use the normal macOS verification flow; do not remove quarantine attributes or disable Gatekeeper.

For an optional integrity check, download the matching checksum beside the artifact, then run `shasum -a 256 -c Yap.dmg.sha256` or `shasum -a 256 -c Yap-macOS.zip.sha256` in that directory. A checksum is separate from Apple's signature/notarization verification.

New users need Zoom authorization that is available to their account. Production browser authentication/service checks passed within the in-memory scope below; native onboarding and external approval remain pending. Google Calendar is optional and requires an eligible OAuth configuration. Previous app users should quit the older app first, retain it until the new app's account access is confirmed, and review the [identity migration](Bundle-Identity.md).

The prepared [release notes](ReleaseNotes/v0.1.1.md) describe this candidate and its availability limits. Before publication, record the exact notarized artifacts, test results and approved audience; change the availability wording only when that evidence exists. Push the tag **or** dispatch its preparation workflow, not both. A tag push builds, notarizes and uploads a **draft** release; it does not publish the release or update the latest feed. For a fresh release, publication requires an explicit manual dispatch with `publish=true` after the distribution permission and acceptance checks are complete. A verified existing draft is promoted separately as described below; rerunning the workflow does not overwrite it.

## Current candidate evidence

**Yap 0.1.1 (build 2)**, reported September 7, 2026. These results belong to `283e37cfddc47cac213be884f5dab6582a8713b0` and tag `v0.1.1`; they are separate from the superseded 0.1.0 evidence below.

| Check | Result / evidence |
| --- | --- |
| Source and CI | [Main CI 34169878107](https://github.com/grinich/yap/actions/runs/34169878107) passed on `283e37cfddc47cac213be884f5dab6582a8713b0`. |
| Actual-SDK release | [Release run 34169899197](https://github.com/grinich/yap/actions/runs/34169899197) passed, including actual-SDK tests, Developer ID signing, app/DMG notarization, stapling and Gatekeeper checks. |
| App notarization | Apple Accepted; submission `0e889e8b-488f-43ff-97e8-5d8800edbb18`, recorded at 23:30:54 UTC on September 7, 2026. |
| DMG notarization | Apple Accepted; submission `5f0e64a5-b687-4ca4-b50a-4daab74215c2`, recorded at 23:34:09 UTC on September 7, 2026. |
| Delivery | GitHub draft `384360449`, tag `v0.1.1`, contains all five release assets. It is not published or available through the public latest feed. |
| Independent downloaded verification | Passed at **2026-09-07 23:44:30 UTC**. All five SHA-256 values match GitHub asset digests; ZIP/DMG also match their `.sha256` files. App/DMG strict signature verification, Developer ID identity, stapled notarization and Gatekeeper checks passed; DMG container integrity passed. Bundle version, managed endpoint and update feed were verified. The app was not launched, installed or mounted. |
| Downloaded update signature | CryptoKit independently verified the downloaded ZIP's Ed25519 signature using the public key bundled in Yap.app. This verifies the archive signature; it is not an independent verification of the entire appcast signature or updater installation. |
| Remaining acceptance | Native installation/Keychain integration, SDK initialization, token refresh/revocation, fresh-Mac onboarding and an N → N+1 update remain pending. Zoom submission and approval are also pending. |

**Current 0.1.1 downloaded asset SHA-256**, independently checked against GitHub. The ZIP and DMG also match their corresponding checksum-file contents:

| Asset | Bytes | GitHub asset ID | SHA-256 |
| --- | ---: | ---: | --- |
| `Yap-macOS.zip` | 291317123 | 549530344 | `c5696e659cab21d20de37a640583fad2a9bc111f1c27dca3a126cc8f7b7aac24` |
| `Yap-macOS.zip.sha256` | 80 | 549530345 | `1c76096b351485e9c5922f84dd58a206cde3f626522817d1a909d85f18356f9c` |
| `Yap.dmg` | 350847296 | 549530341 | `03c7726832097eb344ee2b8b610e8c20be971ae7924ced4dae6bba088184d988` |
| `Yap.dmg.sha256` | 74 | 549530339 | `7d49bb197c0ce4eb96f10b3482d8497686a0c42a932fe2e5c483a876f7f17a03` |
| `appcast.xml` | 1250 | 549530338 | `51329aef4fc3e4d84746008a852b253b6176a47f5db36343e26a1e1ce0d3acb4` |

## Superseded candidate: v0.1.0

**Do not install or promote the 0.1.0 draft.** Its tag and five signed assets remain unchanged for traceability. It predates the corrected icon and current managed endpoint. The successful packaging evidence below applies only to those historical bytes, not to 0.1.1. See the [historical release notes](ReleaseNotes/v0.1.0.md).

## Release-candidate evidence

**Historical 0.1.0 (build 1) evidence**, reported by the release operator on **September 7, 2026**. The source is [PR #4](https://github.com/grinich/yap/pull/4), merged at `ac394cd9a0834da2d3b58faed5e52efee980d246`. The superseded draft is not for installation. All artifact hashes, notarization submissions and release-run results in this section belong to 0.1.0. Current 0.1.1 results are recorded separately above.

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

The 0.1.0 draft remains private and superseded; its successful checks do not authorize installation or publication. Preserve its workflow logs, assets and notarization results without repacking or reusing the version. Use the separate current-candidate evidence above when evaluating 0.1.1.

## Current service validation

Service fix [`9d4e1dd`](https://github.com/grinich/yap/commit/9d4e1dd) passed **24 service tests** and an actual local `workerd` before/after regression check. Live production browser PKCE/callback, token exchange with all three required scopes, one bounded recordings-list page and an SDK-signature response passed at `https://meeting-auth.mgrinich.workers.dev` on deployment `31a76568-0191-4f73-a3e7-d530fbc52966`. Credentials remained in process memory. The current API-only deployment is `23757fca-b323-4f65-a8ce-42255449c072`; it removes static document serving without changing authentication logic. Its health endpoint returns 200 and `/terms` returns 404. Public documentation and Terms use GitHub. [Scope and limits](SecurityEvidence.md#production-service-acceptance).

Fresh-Mac installation, native GUI/Keychain integration, SDK initialization, refresh/revocation and N → N+1 update acceptance remain pending. These service checks do not verify the new app package.

## Implemented

- CI on pull requests and main/codex branches: Xcode 26.6 on Apple's `macos-26` hosted runner, locked Sparkle dependency, SDK-free application tests, packaging/signature checks, release validation tests, and an offline signed-update tampering test.
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
5. Complete the signer/onboarding and Zoom distribution work in [Distribution](Distribution.md). Commit the final source and `Package.resolved` to main. Increase both `CFBundleShortVersionString` (x.y.z) and integer `CFBundleVersion` for every release. Tag the commit, e.g. `v0.1.1`. A tag push or manual dispatch with `publish=false` prepares a GitHub draft and leaves the public release/feed unchanged. SDK-integrated Actions artifact uploads are disabled on that draft path. Only explicit `publish=true` for a fresh release publishes the complete release and allows its Actions artifact upload. The workflow rejects an existing draft or published release rather than overwriting it. [GitHub artifact access](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

Once Zoom approval covers public distribution and the draft's exact artifacts have passed acceptance, update the draft's review-only release notes and explicitly promote those verified bytes:

```sh
gh release edit v0.1.1 --repo grinich/yap --draft=false --latest
```

That operation makes the installers and latest update feed public. Do not run it while approval is pending, delete a verified draft just to rerun the workflow, or repack its signed artifacts during promotion.

## First-release acceptance

The **Apple Signing** workflow independently checks the saved GitHub credentials. It runs manually or when its workflow/signing scripts change on a trusted source branch. It uses the same temporary-keychain import as a release, then signs, notarizes, staples, and checks a disposable app with Gatekeeper. This needs no Zoom SDK upload or public distribution repository. It does not publish or install anything. Its report distinguishes successful credential validation from notarization of the actual Yap/Zoom/Sparkle bundle.

Personal installs made before the update feed was configured need a one-time normal install of the first notarized updater-enabled release. Installations on `com.grinich.zooom`, `com.grinich.woosh` or `app.whoosh.personal` need the explicit identity migration described in [Bundle Identity](Bundle-Identity.md). Subsequent `com.grinich.yap` updates retain the new identity; Sparkle does not change application identity.

Before calling the updater live, install version N from the DMG, publish N+1, and verify manual update, automatic discovery, on-quit installation, relaunch, retained accounts/preferences, call-in-progress veto, offline errors, and denied folder-write access. The current 0.1.1 app/DMG passed release-workflow signing and notarization; native acceptance remains separate. Public publication and an actual N → N+1 installation have **not yet run**. Signing success does not establish end-to-end update delivery.

Local production packaging uses `Scripts/package-release.sh` with the same variables as CI plus `YAP_ZOOM_SDK_PATH`, `YAP_SIGNING_IDENTITY`, `YAP_NOTARY_PROFILE`, optional `YAP_NOTARY_KEYCHAIN`, and `YAP_UPDATE_PRIVATE_KEY_FILE`. It fails if notarization or update signing is unavailable. It does not publish or launch the app. Personal debug builds remain available through `Scripts/build-app.sh` without release credentials. Set `YAP_OUTPUT_DIR` to stage a separate build while someone is running `outputs/Yap.app`; the builder refuses to replace a running output bundle.

## Public-preview verification

**Historical pre-Yap package, September 7, 2026:** 608 Swift tests in 73 suites passed with the real Zoom SDK, and 18 Python release/signing/dependency tests passed. The signed app was built, installed, and restarted; Help → Report a Bug opened this repository’s issue-creation page in the default browser. Bundled Sparkle and Zoom notices matched their upstream files byte-for-byte. GitHub CI passed the SDK-free test/build/signature checks, and the Apple Signing workflow independently passed its disposable-app notarization check. README screenshots use sample data and original local recording content. This validates the public source preview; the binary distribution and updater acceptance items above still apply.

## Recovery

- If a public release is bad, stop offering it by publishing a higher build number with the fix; do not overwrite archive bytes or reuse a signed version. Removing its latest status/feed can halt discovery but cannot undo already installed updates.
- If draft publication fails, inspect/delete that incomplete draft before retrying the same tag. Older published versions remain available.
- When publication is explicitly enabled, Actions artifacts are retained for 14 days. The draft-only path does not upload those SDK-integrated artifacts. Signing keys are deleted with the temporary runner/keychain. The app contains only the public update key, public feed URL, and normal OAuth setup UI.
- This pipeline does not certify Zoom redistribution/account onboarding, guest-call behavior, large-meeting capacity, or other production-readiness items in the existing QA documents.
