# GitHub releases and automatic updates

Yap's source and release destination are `grinich/yap`. The first release is planned as **0.1.0, build 1**, under tag `v0.1.0`. Raw proprietary SDK dependencies remain in a separate private repository; no SDK archive belongs in the public source repository or its releases. The release workflow verifies that separation before downloading the SDK. Publishing the source is separate from authorizing a distributable Zoom integration: complete the [team and public distribution requirements](Distribution.md) before publishing a working installer.

The workflow can also publish to a separately configured public binary repository. Private installers would require an authenticated feed/download service and additional client support; do not point Sparkle at private GitHub asset URLs or ship a GitHub token.

## First release: v0.1.0

The release is being prepared; these immutable URLs become available only after the tag's release is published. They are the actual names produced by the packaging workflow, not alternate or renamed copies.

| Asset | Purpose |
| --- | --- |
| [Yap.dmg](https://github.com/grinich/yap/releases/download/v0.1.0/Yap.dmg) | Installer for Apple silicon, macOS 26 or newer |
| [Yap.dmg.sha256](https://github.com/grinich/yap/releases/download/v0.1.0/Yap.dmg.sha256) | DMG checksum |
| [Yap-macOS.zip](https://github.com/grinich/yap/releases/download/v0.1.0/Yap-macOS.zip) | App archive and Sparkle update payload |
| [Yap-macOS.zip.sha256](https://github.com/grinich/yap/releases/download/v0.1.0/Yap-macOS.zip.sha256) | ZIP checksum |
| [appcast.xml](https://github.com/grinich/yap/releases/download/v0.1.0/appcast.xml) | Signed update feed for this release |

Once published, download `Yap.dmg`, open it, drag **Yap.app** to **Applications**, eject the disk image, and open Yap from Applications. The ZIP can instead be expanded and its Yap.app moved to Applications. The expected identity is `com.grinich.yap`, version `0.1.0`, build `1`, signed by Michael Grinich's Developer ID team `VSVHNQP588`. Use the normal macOS verification flow; do not remove quarantine attributes or disable Gatekeeper.

For an optional integrity check, download the matching checksum beside the artifact, then run `shasum -a 256 -c Yap.dmg.sha256` or `shasum -a 256 -c Yap-macOS.zip.sha256` in that directory. A checksum is separate from Apple's signature/notarization verification.

New users need Zoom authorization that is available to their account; production onboarding and external approval remain unverified/pending. Google Calendar is optional and requires an eligible OAuth configuration. Previous app users should quit the older app first, retain it until the new app's account access is confirmed, and review the [identity migration](Bundle-Identity.md).

The prepared [release notes](ReleaseNotes/v0.1.0.md) describe the first version and its current availability limits. Before publication, record the exact notarized artifacts, test results and approved audience; change the availability wording only when that evidence exists. Push the tag **or** dispatch its preparation workflow, not both. A tag push builds, notarizes and uploads a **draft** release; it does not publish the release or update the latest feed. For a fresh release, publication requires an explicit manual dispatch with `publish=true` after the distribution permission and acceptance checks are complete. A verified existing draft is promoted separately as described below; rerunning the workflow does not overwrite it.

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

[Apple Signing passed on a fresh GitHub runner](https://github.com/grinich/yap/actions/runs/34149118682), including credential import, secure timestamping, Apple notarization, stapling, and Gatekeeper. The earlier branded release build with its embedded Zoom and Sparkle components was also accepted by Apple without issues and passed Gatekeeper as `Notarized Developer ID`. Repeat packaging, notarization and Gatekeeper verification for the new `com.grinich.yap` artifact.

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
5. Complete the signer/onboarding and Zoom distribution work in [Distribution](Distribution.md). Commit the final source and `Package.resolved` to main. Increase both `CFBundleShortVersionString` (x.y.z) and integer `CFBundleVersion` for every release. Tag the commit, e.g. `v0.1.0`. A tag push or manual dispatch with `publish=false` prepares a GitHub draft and leaves the public release/feed unchanged. SDK-integrated Actions artifact uploads are disabled on that draft path. Only explicit `publish=true` for a fresh release publishes the complete release and allows its Actions artifact upload. The workflow rejects an existing draft or published release rather than overwriting it. [GitHub artifact access](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

Once Zoom approval covers public distribution and the draft's exact artifacts have passed acceptance, update the draft's review-only release notes and explicitly promote those verified bytes:

```sh
gh release edit v0.1.0 --repo grinich/yap --draft=false --latest
```

That operation makes the installers and latest update feed public. Do not run it while approval is pending, delete a verified draft just to rerun the workflow, or repack its signed artifacts during promotion.

## First-release acceptance

The **Apple Signing** workflow independently checks the saved GitHub credentials. It runs manually or when its workflow/signing scripts change on a trusted source branch. It uses the same temporary-keychain import as a release, then signs, notarizes, staples, and checks a disposable app with Gatekeeper. This needs no Zoom SDK upload or public distribution repository. It does not publish or install anything. Its report distinguishes successful credential validation from notarization of the actual Yap/Zoom/Sparkle bundle.

Personal installs made before the update feed was configured need a one-time normal install of the first notarized updater-enabled release. Installations on `com.grinich.zooom`, `com.grinich.woosh` or `app.whoosh.personal` need the explicit identity migration described in [Bundle Identity](Bundle-Identity.md). Subsequent `com.grinich.yap` updates retain the new identity; Sparkle does not change application identity.

Before calling the updater live, install version N from the DMG, publish N+1, and verify manual update, automatic discovery, on-quit installation, relaunch, retained accounts/preferences, call-in-progress veto, offline errors, and denied folder-write access. Apple signing and notarization have been exercised independently. The full publishing workflow and an actual N → N+1 installation have **not yet run**. Signing success does not establish end-to-end update delivery.

Local production packaging uses `Scripts/package-release.sh` with the same variables as CI plus `YAP_ZOOM_SDK_PATH`, `YAP_SIGNING_IDENTITY`, `YAP_NOTARY_PROFILE`, optional `YAP_NOTARY_KEYCHAIN`, and `YAP_UPDATE_PRIVATE_KEY_FILE`. It fails if notarization or update signing is unavailable. It does not publish or launch the app. Personal debug builds remain available through `Scripts/build-app.sh` without release credentials. Set `YAP_OUTPUT_DIR` to stage a separate build while someone is running `outputs/Yap.app`; the builder refuses to replace a running output bundle.

## Public-preview verification

**Historical pre-Yap package, September 7, 2026:** 608 Swift tests in 73 suites passed with the real Zoom SDK, and 18 Python release/signing/dependency tests passed. The signed app was built, installed, and restarted; Help → Report a Bug opened this repository’s issue-creation page in the default browser. Bundled Sparkle and Zoom notices matched their upstream files byte-for-byte. GitHub CI passed the SDK-free test/build/signature checks, and the Apple Signing workflow independently passed its disposable-app notarization check. README screenshots use sample data and original local recording content. This validates the public source preview; the binary distribution and updater acceptance items above still apply.

## Recovery

- If a public release is bad, stop offering it by publishing a higher build number with the fix; do not overwrite archive bytes or reuse a signed version. Removing its latest status/feed can halt discovery but cannot undo already installed updates.
- If draft publication fails, inspect/delete that incomplete draft before retrying the same tag. Older published versions remain available.
- When publication is explicitly enabled, Actions artifacts are retained for 14 days. The draft-only path does not upload those SDK-integrated artifacts. Signing keys are deleted with the temporary runner/keychain. The app contains only the public update key, public feed URL, and normal OAuth setup UI.
- This pipeline does not certify Zoom redistribution/account onboarding, guest-call behavior, large-meeting capacity, or other production-readiness items in the existing QA documents.
