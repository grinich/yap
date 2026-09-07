# Yap bundle identity

The macOS bundle identifier is `com.grinich.yap`, selected September 7, 2026. The display name, Swift package, executable and module prefix are Yap. The canonical installed app is `~/Applications/Yap.app`; the source repository is `grinich/yap`.

## Packaging and migration

`Resources/Info.plist` supplies the identifier to code signing and packaged App Intents metadata. Signing continues to use the existing Apple-issued Developer ID certificate for Team `VSVHNQP588`. The installer verifies the code and designated requirement before staging and replacing Yap. It refuses to proceed while either Yap or a predecessor app is running.

```sh
Scripts/build-app.sh debug
# Quit the old app, then install Yap alongside it:
Scripts/install-personal-app.sh --migrate-from-zooom
# Subsequent Yap updates:
Scripts/install-personal-app.sh
```

The explicit `--migrate-from-zooom` path verifies `~/Applications/Zooom.app`, its `com.grinich.zooom` identifier, `Whoosh` executable and existing Developer ID team. Plain installation also recognizes and verifies that predecessor. Compatibility flags `--migrate-from-woosh` and `--migrate-from-personal` remain available for older identities. The old application is left untouched on disk; verify Yap and account access before archiving it. The migration does not launch either application or grant permissions. Yap-to-Yap updates retain staged verification, atomic replacement and rollback.

## Preferences and saved accounts

Before constructing the app model, Yap copies five supported preferences: display name, selected calendar IDs, reminder enabled state, reminder minutes, and selected Settings pane. Existing Yap values win, including false and empty values. The first existing old domain is used as a whole, in this order: `com.grinich.zooom`, `com.grinich.woosh`, `com.grinich.whoosh`, `app.whoosh.personal`. It never fills missing keys from a second old domain. A new `yap.migratedPreferences.v1` marker makes this migration independent of previous migration runs.

The active credential vault is `app.yap.credentials` / `personal-connections-v1`. If it does not yet exist, Yap reads the explicitly supported previous consolidated vault `app.whoosh.credentials`, maps the known record services and deletion markers, and commits the new protected item before using the migrated snapshot. Existing Yap data wins. The old consolidated vault is retained; once the new vault exists it is not reread. Individual pre-vault records also have explicit aliases. No arbitrary Keychain discovery, plaintext export or ACL rewriting occurs. [Credential details](Credential-Storage.md).

The agenda cache migrates once from `~/Library/Application Support/Whoosh/agenda.json` to `~/Library/Application Support/Yap/agenda.json`. Its `.migrated-legacy-agenda-v1` marker prevents a later empty/cleared Yap cache from falling back to an old snapshot. Account/client checks and user-only file permissions remain in force.

The primary invitation scheme is `yap`; previously shared `whoosh` and `zooom` invitations remain accepted with the same validation. Zoom's official `zoommtg` and `zoomus` schemes retain their separate optional-handler behavior. macOS permissions, login registration and user-created Shortcuts are separate OS identities and may require normal approval or reselection.

## Verification boundary

The release operator reports 642 Swift tests in 77 suites passing with the actual SDK after the Yap rename, including migration regressions and the cache-migration preview guard fix. The 33 Python script tests also pass. Package, installation and live account-retention results still need to be recorded for the renamed build. Earlier validation does not establish that the new bundle identity has already passed live acceptance.

**Historical September 7 predecessor migration:** 470 tests in 63 suites passed when the app moved to `com.grinich.zooom`; its signed package was installed at `~/Applications/Zooom.app`. The identifier, Apple/team designated requirement, preference transfer and deep signature verification were checked. Those evidence filenames and identifiers remain unchanged: [tests](../../work/zooom-bundle-migration-tests.log), [build](../../work/zooom-bundle-migration-build.log), [installation](../../work/zooom-bundle-migration-install.log), [readback](../../work/zooom-bundle-migration-verification.json).
