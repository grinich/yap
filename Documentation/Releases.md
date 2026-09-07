# GitHub releases and automatic updates

Zooom uses a private source repository and a separately configured binary distribution repository. The source repo stays private. The release workflow does not create or change repository visibility. Public distribution is awaiting the owner's choice; do not publish until that choice is made. Private downloads would require an authenticated feed/download service and additional client support; this implementation must not be pointed at private GitHub asset URLs or ship a GitHub token.

## Implemented

- CI on pull requests and main/codex branches: Xcode 26.6 on Apple's `macos-26` hosted runner, locked Sparkle dependency, SDK-free application tests, packaging/signature checks, release validation tests, and an offline signed-update tampering test.
- Source `v*` tags trigger `.github/workflows/release.yml`. Manual dispatch accepts an existing tag and defaults to building without publishing.
- Releases require a reviewed tag on main, an increasing version/build number, and the exact private Zoom SDK ZIP pinned by SHA-256 in `Resources/ZoomSDK.lock.json`. A release cannot silently compile without the Zoom bridge.
- The release imports Developer ID and notarization credentials into a temporary CI keychain, then signs nested Zoom/Sparkle helpers inside out. It notarizes/staples the app and DMG, validates Gatekeeper, generates the final ZIP, and signs both the archive and appcast with Sparkle Ed25519.
- Publishing creates a draft in the configured distribution repo with all five artifacts, then marks it published/latest. A failed upload cannot expose a new feed before its archive is available. Existing releases are not overwritten.
- Installers: `Zooom.dmg`, `Zooom-macOS.zip`, two SHA-256 files, and `appcast.xml`. Apple silicon and macOS 26 or newer; this is not a universal Intel build.
- In-app Sparkle checks every six hours, downloads updates automatically, verifies signatures, and supports installation on quit or via the standard update dialog. “Zooom → Check for Updates…” is available when configured. Profile sending is off. The menu, update-check delegate, and final relaunch delegate reject updates during an active/joining meeting. If installation was attempted during a call, check again after leaving; the updater does not end calls automatically.
- Unconfigured local/preview builds do not contact an update server. They still bundle Sparkle and show a disabled Check for Updates item.

The signing and artifact pipeline follows [Replay's release workflow](https://github.com/grinich/replay/blob/main/.github/workflows/release.yml). Replay uses a custom updater; Zooom uses [Sparkle's maintained installer](https://sparkle-project.org/documentation/) and [its supported manual signing order](https://sparkle-project.org/documentation/sandboxing/#code-signing).

## One-time configuration still required

1. Choose public installers with private source, or request a private authenticated distribution design. For public installers, create a distribution-only repository (for example `grinich/zooom-releases`) with a README/default branch. Keep `grinich/zooom` private.
2. In the **source repository**, create a `release` environment and configure these variables/secrets. Restrict its deployment branches to release tags once the initial dry run works.

| Type | Name | Value/source |
| --- | --- | --- |
| Variable | `ZOOOM_RELEASE_REPOSITORY` | Public binary repository, `owner/name` |
| Variable | `ZOOOM_UPDATE_FEED_URL` | `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml` |
| Variable | `ZOOOM_UPDATE_PUBLIC_KEY` | Zooom's new Sparkle Ed25519 public key |
| Variable | `ZOOM_SDK_ASSET_ID` | Private source-repo release asset containing the exact locked SDK ZIP |
| Secret | `DEVELOPER_ID_P12_BASE64` | Original Developer ID certificate and private key export, base64 |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | Password for that export |
| Secret | `APPLE_API_KEY_ID` | App Store Connect notarization API key ID |
| Secret | `APPLE_API_ISSUER_ID` | Issuer ID |
| Secret | `APPLE_API_PRIVATE_KEY_BASE64` | Original `.p8` key contents, base64 |
| Secret | `SPARKLE_PRIVATE_KEY` | Exported Zooom update-signing key (base64 text as exported by `generate_keys`) |
| Secret | `ZOOOM_RELEASE_TOKEN` | Fine-grained token with Contents read/write on **only the distribution repo** |

The Developer ID must belong to team `VSVHNQP588`, matching existing Zooom installations. Replay's original Apple credentials can be reused; GitHub only exposes secret names and cannot return their saved values. Do not print credentials, commit them, export unrelated Keychain identities, or broaden the developer's login Keychain permissions. The CI keychain script refuses to run outside GitHub Actions.

3. Store the unmodified downloaded `zoom-sdk-macos-7.1.5.84750.zip` as an asset of a draft dependency release in the **private source repo**, then set its numeric asset ID. CI reads it with its source-repository `GITHUB_TOKEN`. This archive must never go into the public distribution repo. `prepare-zoom-sdk.py` checks its checksum before extracting. The original developer setup still obtains the SDK from Zoom.
4. Generate a dedicated production Sparkle key with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.grinich.zooom`. Export that exact account using `--account com.grinich.zooom -x /protected/path/sparkle-key.txt` and provision the `SPARKLE_PRIVATE_KEY` secret from the file. Keep a secure backup; losing the key breaks the existing update trust chain. `test-update-signatures.py` uses published RFC 8032 test keys only; those **must never be used for releases**.
5. Commit the final source and `Package.resolved` to main. Increase both `CFBundleShortVersionString` (x.y.z) and integer `CFBundleVersion` for every release. Tag the commit, e.g. `v0.1.0`. Tags will attempt publication; configure credentials and the approved destination first. Manual dispatch with `publish=false` only produces private CI artifacts.

## First-release acceptance

The current personal install predates a configured update feed, so it needs a one-time normal install of the first notarized updater-enabled release. No bundle-ID migration is required for installations already on `com.grinich.zooom`. Older `com.grinich.woosh` builds require the existing explicit migration installer; Sparkle does not change application identity.

Before calling the updater live, install version N from the DMG, publish N+1, and verify manual update, automatic discovery, on-quit installation, relaunch, retained accounts/preferences, call-in-progress veto, offline errors, and denied folder-write access. The GitHub workflow, Apple's notarization service, and an actual N → N+1 installation have **not yet run**. Local checks prove app packaging, signature generation/tamper rejection, and the meeting update gate, not end-to-end delivery.

Local production packaging uses `Scripts/package-release.sh` with the same variables as CI plus `WHOOSH_ZOOM_SDK_PATH`, `WHOOSH_SIGNING_IDENTITY`, `ZOOOM_NOTARY_PROFILE`, optional `ZOOOM_NOTARY_KEYCHAIN`, and `ZOOOM_UPDATE_PRIVATE_KEY_FILE`. It fails if notarization or update signing is unavailable. It does not publish or launch the app. Personal debug builds remain available through `Scripts/build-app.sh` without release credentials. Set `WHOOSH_OUTPUT_DIR` to stage a separate build while someone is running `outputs/Zooom.app`; the builder refuses to replace a running output bundle.

## Recovery

- If a public release is bad, stop offering it by publishing a higher build number with the fix; do not overwrite archive bytes or reuse a signed version. Removing its latest status/feed can halt discovery but cannot undo already installed updates.
- If draft publication fails, inspect/delete that incomplete draft before retrying the same tag. Older published versions remain available.
- CI artifacts are retained for 14 days. Signing keys are deleted with the temporary runner/keychain. The app contains only the public update key, public feed URL, and normal OAuth setup UI.
- This pipeline does not certify Zoom redistribution/account onboarding, guest-call behavior, large-meeting capacity, or other production-readiness items in the existing QA documents.
