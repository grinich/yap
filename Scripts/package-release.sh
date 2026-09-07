#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
: "${WHOOSH_SIGNING_IDENTITY:?Set a Developer ID signing identity}"
: "${ZOOOM_NOTARY_PROFILE:?Set a notarytool credential profile}"
: "${ZOOOM_UPDATE_FEED_URL:?Set the public HTTPS update feed URL}"
: "${ZOOOM_UPDATE_PUBLIC_KEY:?Set the Sparkle public Ed25519 key}"
: "${ZOOOM_UPDATE_PRIVATE_KEY_FILE:?Set a protected Sparkle key file path}"
: "${ZOOOM_RELEASE_REPOSITORY:?Set the GitHub binary distribution repository}"
: "${WHOOSH_ZOOM_SDK_PATH:?Set the verified Zoom SDK directory}"
test "$WHOOSH_SIGNING_IDENTITY" != '-'
test -f "$ZOOOM_UPDATE_PRIVATE_KEY_FILE"
test -f "$WHOOSH_ZOOM_SDK_PATH/ZoomSDK.framework/Headers/ZoomSDK.h"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
tag="v$version"
if [[ -n "${ZOOOM_RELEASE_TAG:-}" && "$ZOOOM_RELEASE_TAG" != "$tag" ]]; then
    echo "Release tag does not match CFBundleShortVersionString." >&2
    exit 1
fi
export ZOOOM_RELEASE=1
/bin/bash Scripts/build-app.sh release
mkdir -p dist
stage="$(mktemp -d "$root/dist/.release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Zooom.app"
ditto "${WHOOSH_OUTPUT_DIR:-$root/../outputs}/Zooom.app" "$app"
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
[[ "$signature" == *"Authority=Developer ID Application:"* ]]
[[ "$signature" == *"TeamIdentifier=VSVHNQP588"* ]]
test -f "$app/Contents/Frameworks/ZoomSDK.framework/ZoomSDK"
test -f "$app/Contents/Frameworks/Sparkle.framework/Sparkle"
notary_args=(--keychain-profile "$ZOOOM_NOTARY_PROFILE")
if [[ -n "${ZOOOM_NOTARY_KEYCHAIN:-}" ]]; then
    notary_args+=(--keychain "$ZOOOM_NOTARY_KEYCHAIN")
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/notarization.zip"
xcrun notarytool submit "$stage/notarization.zip" "${notary_args[@]}" --wait --timeout 45m
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

# Create the update archive only after stapling, so its signature covers final bytes.
mkdir "$stage/feed" "$stage/dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/feed/Zooom-macOS.zip"
ditto "$app" "$stage/dmg/Zooom.app"
ln -s /Applications "$stage/dmg/Applications"
hdiutil create -volname Zooom -srcfolder "$stage/dmg" -ov -format UDZO "$stage/Zooom.dmg"
codesign --force --sign "$WHOOSH_SIGNING_IDENTITY" --timestamp "$stage/Zooom.dmg"
xcrun notarytool submit "$stage/Zooom.dmg" "${notary_args[@]}" --wait --timeout 45m
xcrun stapler staple "$stage/Zooom.dmg"
xcrun stapler validate "$stage/Zooom.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$stage/Zooom.dmg"
hdiutil verify "$stage/Zooom.dmg"

sparkle_bin="$root/.build/artifacts/sparkle/Sparkle/bin"
"$sparkle_bin/generate_appcast" --ed-key-file "$ZOOOM_UPDATE_PRIVATE_KEY_FILE" \
    --download-url-prefix "https://github.com/$ZOOOM_RELEASE_REPOSITORY/releases/download/$tag/" \
    --maximum-deltas 0 --maximum-versions 1 "$stage/feed"
python3 Scripts/validate-appcast.py "$stage/feed/appcast.xml" "$stage/feed/Zooom-macOS.zip" "$app/Contents/Info.plist"
"$sparkle_bin/sign_update" --verify --ed-key-file "$ZOOOM_UPDATE_PRIVATE_KEY_FILE" "$stage/feed/appcast.xml"
for asset in Zooom-macOS.zip appcast.xml; do
    cp "$stage/feed/$asset" "dist/$asset"
done
cp "$stage/Zooom.dmg" dist/Zooom.dmg
(cd dist && shasum -a 256 Zooom-macOS.zip > Zooom-macOS.zip.sha256 && shasum -a 256 Zooom.dmg > Zooom.dmg.sha256)
printf 'Signed and notarized release artifacts ready in %s/dist\n' "$root"
