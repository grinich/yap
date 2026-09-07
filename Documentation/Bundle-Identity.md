# Zooom bundle identity

The macOS bundle identifier is `com.grinich.zooom`, effective September 7, 2026. The app display name remains Zooom, installed at `~/Applications/Zooom.app`. Its internal Swift package/modules and executable remain Whoosh.

## Packaging and migration

`Resources/Info.plist` supplies the identifier to code signing and packaged App Intents metadata. Signing continues to use the existing Apple-issued Developer ID certificate for Team `VSVHNQP588`. The installer verifies both code and designated requirements before replacing the app. The explicit `--migrate-from-woosh` option accepts only a verified `com.grinich.woosh` app from that team; normal subsequent updates require `com.grinich.zooom`.

```sh
Scripts/build-app.sh debug
# Quit Zooom, then perform the one-time identity migration:
Scripts/install-personal-app.sh --migrate-from-woosh
# Subsequent updates use Scripts/install-personal-app.sh with no migration flag.
```

## Existing data

Before constructing the app model, the new app migrates five supported preferences: display name, selected calendar IDs, reminder enabled state, reminder minutes, and selected Settings pane. Existing values in the new domain win, including false and empty values. Migration uses the most recent existing old domain (`com.grinich.woosh`, otherwise `app.whoosh.personal`) and leaves it intact. It does not combine missing keys with older domains, which could resurrect settings the user removed. A separate completion marker makes this migration run once even if the older migration had completed.

Keychain item service/account names, OAuth configuration, the existing agenda cache location, and the `whoosh` invitation URL scheme remain compatible. Credentials are neither exported nor rewritten for this change. macOS permissions and Keychain access controls are separate from preference migration and may require normal user approval for the new application identity.

## Verification

All 470 tests in 63 suites pass, including migration priority, idempotence, malformed values, empty/false value preservation, and missing-key behavior. Plist and shell syntax checks pass. The package validates three App Intents and three App Shortcuts and embeds the existing Zoom SDK with verified nested signatures.

Logs: [tests](../../work/zooom-bundle-migration-tests.log), [build](../../work/zooom-bundle-migration-build.log), [installation](../../work/zooom-bundle-migration-install.log). The signed package is installed at `~/Applications/Zooom.app`. Its plist and standard Apple/team designated requirement both identify `com.grinich.zooom`; deep strict verification passed. First launch completed the migration, and all four preferences present in the old domain matched in the new domain (reminder minutes was absent). [Read-back verification](../../work/zooom-bundle-migration-verification.json). The native app inventory reports the new identity running; UI inspection still cached the previous identifier, so account access and media permissions were not reverified in this migration pass.
