# GitHub releases and automatic updates

Zooom's source and future public installers use `grinich/zooom`. The owner authorized publishing the source repository on September 7, 2026. Raw proprietary SDK dependencies remain in a separate private repository; no SDK archive belongs in the public source repository or its releases. The release workflow verifies that separation before downloading the SDK. Publishing the source is separate from authorizing a distributable Zoom integration: complete the [team and public distribution requirements](Distribution.md) before publishing a working installer.

The workflow can also publish to a separately configured public binary repository. Private installers would require an authenticated feed/download service and additional client support; do not point Sparkle at private GitHub asset URLs or ship a GitHub token.

## Implemented

- CI on pull requests and main/codex branches: Xcode 26.6 on Apple's `macos-26` hosted runner, locked Sparkle dependency, SDK-free application tests, packaging/signature checks, release validation tests, and an offline signed-update tampering test.
- Source `v*` tags trigger `.github/workflows/release.yml`. Manual dispatch accepts an existing tag and defaults to building without publishing.
- Releases require a reviewed tag on main, an increasing version/build number, and the exact private Zoom SDK ZIP pinned by SHA-256 in `Resources/ZoomSDK.lock.json`. A release cannot silently compile without the Zoom bridge.
- The release imports Developer ID and notarization credentials into a temporary CI keychain, then signs nested Zoom/Sparkle helpers inside out. It notarizes/staples the app and DMG, validates Gatekeeper, generates the final ZIP, and signs both the archive and appcast with Sparkle Ed25519.
- Publishing creates a draft in the configured distribution repo with all five artifacts, then marks it published/latest. A failed upload cannot expose a new feed before its archive is available. Existing releases are not overwritten.
- The app includes the complete upstream Sparkle license and Zoom open-source notices in `Contents/Resources/ThirdPartyLicenses`. Packaging fails if either notice is missing.
- Installers: `Zooom.dmg`, `Zooom-macOS.zip`, two SHA-256 files, and `appcast.xml`. Apple silicon and macOS 26 or newer; this is not a universal Intel build.
- In-app Sparkle checks every six hours, downloads updates automatically, verifies signatures, and supports installation on quit or via the standard update dialog. “Zooom → Check for Updates…” is available when configured. Profile sending is off. The menu, update-check delegate, and final relaunch delegate reject updates during an active/joining meeting. If installation was attempted during a call, check again after leaving; the updater does not end calls automatically.
- Unconfigured local/preview builds do not contact an update server. They still bundle Sparkle and show a disabled Check for Updates item.

The signing and artifact pipeline follows [Replay's release workflow](https://github.com/grinich/replay/blob/main/.github/workflows/release.yml). Replay uses a custom updater; Zooom uses [Sparkle's maintained installer](https://sparkle-project.org/documentation/) and [its supported manual signing order](https://sparkle-project.org/documentation/sandboxing/#code-signing).

## Signing credentials

Configured September 7, 2026: the existing Developer ID Application certificate for team `VSVHNQP588`, a dedicated Developer-role `Zooom Notarization` API key, and a dedicated Sparkle key. All six Apple/Sparkle signing secrets and `ZOOOM_UPDATE_PUBLIC_KEY` are configured as GitHub Actions secrets/variables in the source repository; they are not source files or public release assets. Private keys have secure local Keychain copies; temporary exports were removed.

[Apple Signing passed on a fresh GitHub runner](https://github.com/grinich/zooom/actions/runs/34149118682), including credential import, secure timestamping, Apple notarization, stapling, and Gatekeeper. The full Zooom release build with its embedded Zoom and Sparkle components was also accepted by Apple without issues and passed Gatekeeper as `Notarized Developer ID`.

The current Developer ID certificate expires February 1, 2027. Renew it before signing new builds after that date. Existing timestamped releases retain their signature validity after certificate expiry, subject to Apple's normal revocation checks; see [Apple's explanation of secure timestamps](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates).

## Distribution configuration still required

1. Use `grinich/zooom` as the public release destination and `https://github.com/grinich/zooom/releases/latest/download/appcast.xml` as the update feed. No release is available at that feed until the first installer is published. A separate public binary repository is optional.
2. The source repository's `release` environment and Apple/Sparkle credentials are configured. Finish the distribution variables and token below. Any environment branch restrictions must permit both the release tags and the source branches used by the Apple Signing check.

| Type | Name | Value/source |
| --- | --- | --- |
| Variable | `ZOOOM_RELEASE_REPOSITORY` | `grinich/zooom`, or a separate public `owner/name` |
| Variable | `ZOOOM_UPDATE_FEED_URL` | `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml` |
| Variable | `ZOOOM_UPDATE_PUBLIC_KEY` | Zooom's new Sparkle Ed25519 public key |
| Variable | `ZOOM_SDK_REPOSITORY` | Separate private dependency repository, `owner/name` |
| Variable | `ZOOM_SDK_ASSET_ID` | Asset ID of the exact locked SDK ZIP in that private repository |
| Secret | `ZOOM_SDK_READ_TOKEN` | Fine-grained Contents read-only token limited to the private dependency repository |
| Secret | `DEVELOPER_ID_P12_BASE64` | Original Developer ID certificate and private key export, base64 |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | Password for that export |
| Secret | `APPLE_API_KEY_ID` | App Store Connect notarization API key ID |
| Secret | `APPLE_API_ISSUER_ID` | Issuer ID |
| Secret | `APPLE_API_PRIVATE_KEY_BASE64` | Original `.p8` key contents, base64 |
| Secret | `SPARKLE_PRIVATE_KEY` | Exported Zooom update-signing key (base64 text as exported by `generate_keys`) |
| Secret | `ZOOOM_RELEASE_TOKEN` | Only needed for a separate distribution repo; Contents read/write limited to that repo. Same-repo releases use the scoped workflow token. |

The Developer ID must belong to team `VSVHNQP588`, matching existing Zooom installations. Replay's original Apple credentials can be reused; GitHub only exposes secret names and cannot return their saved values. Do not print credentials, commit them, export unrelated Keychain identities, or broaden the developer's login Keychain permissions. The CI keychain script refuses to run outside GitHub Actions.

3. Create a **separate private dependency repository** and store the unmodified `zoom-sdk-macos-7.1.5.84750.zip` as one of its release assets. Set the repository, numeric asset ID, and read-only token above. `download-zoom-sdk.py` requires GitHub to confirm that exact repository is private and different from both source and distribution repositories before requesting any asset bytes. `prepare-zoom-sdk.py` verifies the pinned checksum before extraction. Temporary SDK downloads and extraction are removed after the job; public artifacts contain only the integrated app and installers. Local developers obtain the SDK directly from Zoom.
4. The production Sparkle key is already stored in Keychain account `com.grinich.zooom` and configured in GitHub. When recovering it, export that exact account using `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.grinich.zooom -x /protected/path/sparkle-key.txt`. Do not generate a replacement for an existing update trust chain. `test-update-signatures.py` uses published RFC 8032 test keys only; those **must never be used for releases**.
5. Complete the signer/onboarding and Zoom distribution work in [Distribution](Distribution.md). Commit the final source and `Package.resolved` to main. Increase both `CFBundleShortVersionString` (x.y.z) and integer `CFBundleVersion` for every release. Tag the commit, e.g. `v0.1.0`. Tags will attempt publication; configure credentials and the approved destination first. Manual dispatch with `publish=false` skips GitHub Release and update-feed publication, but still uploads CI artifacts. In a public source repository, those artifacts are accessible to signed-in GitHub users with repository read access; do not use a public workflow run for a confidential build. [GitHub artifact access](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

## First-release acceptance

The **Apple Signing** workflow independently checks the saved GitHub credentials. It runs manually or when its workflow/signing scripts change on a trusted source branch. It uses the same temporary-keychain import as a release, then signs, notarizes, staples, and checks a disposable app with Gatekeeper. This needs no Zoom SDK upload or public distribution repository. It does not publish or install anything. Its report distinguishes successful credential validation from notarization of the actual Zooom/Zoom/Sparkle bundle.

The current personal install predates a configured update feed, so it needs a one-time normal install of the first notarized updater-enabled release. No bundle-ID migration is required for installations already on `com.grinich.zooom`. Older `com.grinich.woosh` builds require the existing explicit migration installer; Sparkle does not change application identity.

Before calling the updater live, install version N from the DMG, publish N+1, and verify manual update, automatic discovery, on-quit installation, relaunch, retained accounts/preferences, call-in-progress veto, offline errors, and denied folder-write access. Apple signing and notarization have been exercised independently. The full publishing workflow and an actual N → N+1 installation have **not yet run**. Signing success does not establish end-to-end update delivery.

Local production packaging uses `Scripts/package-release.sh` with the same variables as CI plus `WHOOSH_ZOOM_SDK_PATH`, `WHOOSH_SIGNING_IDENTITY`, `ZOOOM_NOTARY_PROFILE`, optional `ZOOOM_NOTARY_KEYCHAIN`, and `ZOOOM_UPDATE_PRIVATE_KEY_FILE`. It fails if notarization or update signing is unavailable. It does not publish or launch the app. Personal debug builds remain available through `Scripts/build-app.sh` without release credentials. Set `WHOOSH_OUTPUT_DIR` to stage a separate build while someone is running `outputs/Zooom.app`; the builder refuses to replace a running output bundle.

## Recovery

- If a public release is bad, stop offering it by publishing a higher build number with the fix; do not overwrite archive bytes or reuse a signed version. Removing its latest status/feed can halt discovery but cannot undo already installed updates.
- If draft publication fails, inspect/delete that incomplete draft before retrying the same tag. Older published versions remain available.
- CI artifacts are retained for 14 days. Signing keys are deleted with the temporary runner/keychain. The app contains only the public update key, public feed URL, and normal OAuth setup UI.
- This pipeline does not certify Zoom redistribution/account onboarding, guest-call behavior, large-meeting capacity, or other production-readiness items in the existing QA documents.
