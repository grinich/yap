# Signing Yap and migrating an existing installation

Yap uses bundle identifier `com.grinich.yap`, executable `Yap`, and the canonical install path `~/Applications/Yap.app`. The existing Apple-issued **Developer ID Application: Michael Grinich (VSVHNQP588)** identity remains the signing identity. Changing the product name does not require generating a new certificate or private key. [Bundle identity and data migration](Bundle-Identity.md).

## Build and install

`Scripts/build-app.sh` and `Scripts/embed-zoom-sdk.sh` accept `YAP_SIGNING_IDENTITY`; otherwise they read the repository's gitignored `signing.local.json`. The existing public certificate selector is:

```json
{"certificateSHA1":"9E5ACA63C3AA07131DF1644F56AC1C9EAA6E794F"}
```

If no identity is configured, a development build uses ad-hoc signing (`-`). An explicitly invalid or unavailable identity fails rather than silently falling back. The selected identity signs the main app and nested SDK code in the established inside-out order, with hardened runtime and strict verification. The scripts do not create identities, export private keys, change trust settings, or rewrite credential ACLs.

```sh
Scripts/build-app.sh debug
Scripts/install-personal-app.sh
```

For an installation under a previous bundle identity, use the explicit migration path documented in [Bundle Identity](Bundle-Identity.md). The installer verifies the identifier, certificate/team, and designated requirement, stages and verifies the new copy, and refuses to replace a running application. Launch Services registration does not launch the app or grant macOS permissions.

For public installers, use [release packaging](Releases.md), including notarization, stapling, Gatekeeper and update-signature verification. Local signing alone is not release approval.

## Credential and permission boundaries

A stable designated requirement is only part of Keychain identity. Apple's `securityd` assigns recognized Developer ID/development code a `teamid:` partition derived from the Apple-issued certificate; other signed code can fall back to a build-specific `cdhash:`. This is why the project moved from self-signed development builds to Developer ID. [Apple Security source](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp#L176-L274), [code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Developer ID signing does not grant access to an existing protected item or silently transfer camera, microphone or screen-capture permission. Yap migrates supported saved data through the existing protection. A new bundle identity may require normal user authorization. It does not rewrite Keychain ACLs, broaden trust, suppress dialogs or directly edit TCC. Zoom's own storage and permission behavior remain separate. [Credential storage](Credential-Storage.md).

## Historical evidence before the Yap rename

The September 6, 2026 build used `com.grinich.woosh` at `~/Applications/Whoosh.app`. Two successive changed builds signed by Team `VSVHNQP588` loaded saved Google/Zoom accounts and hosted meetings without another Keychain or TCC prompt. Read-only vault metadata included `teamid:VSVHNQP588`. These are observed results on one Mac, not evidence that the new Yap identity has already passed migration or that future prompts are impossible. [Installed signature](../../work/developer-id-installed-signature.txt), [install log](../../work/companion-pip-install.log), [vault metadata](../../work/whoosh-credential-acl-after-signed-update.json), [SDK evidence](../../work/live-developer-id-feature-verification.log).

Before Developer ID, the application used `app.whoosh.personal` and the self-signed **Whoosh Personal Development** certificate. Distinct fixture executables retained that certificate-bound designated requirement across changed code, but this did not prove a stable Keychain partition. A recurring app-vault prompt later cleared without establishing its precise cause. The SDK separately requested access to the historically named **Whoosh Safe Meeting Storage** key. Those records explain migration behavior; they are not current Yap branding. [Historical signing fixtures](../../work/signing-fixtures/verification.json), [historical blocked-read sample](../../work/whoosh-final-init-sample.txt).

The earlier notarized package and Apple signing workflow demonstrate that the project's signing credentials and packaging route work. Repeat package and fresh-install acceptance for the renamed app; do not transfer the old binary's validation result to different bytes or a new bundle identifier. [Release evidence](Releases.md).
