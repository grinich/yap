#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
: "${YAP_SIGNING_IDENTITY:?Set a Developer ID signing identity}"
: "${YAP_NOTARY_PROFILE:?Set a notarytool credential profile}"
: "${YAP_UPDATE_FEED_URL:?Set the public HTTPS update feed URL}"
: "${YAP_UPDATE_PUBLIC_KEY:?Set the Sparkle public Ed25519 key}"
: "${YAP_UPDATE_PRIVATE_KEY_FILE:?Set a protected Sparkle key file path}"
: "${YAP_RELEASE_REPOSITORY:?Set the GitHub binary distribution repository}"
: "${YAP_ZOOM_SDK_PATH:?Set the verified Zoom SDK directory}"
test "$YAP_SIGNING_IDENTITY" != '-'
test -f "$YAP_UPDATE_PRIVATE_KEY_FILE"
test -f "$YAP_ZOOM_SDK_PATH/ZoomSDK.framework/Headers/ZoomSDK.h"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
tag="v$version"
if [[ -n "${YAP_RELEASE_TAG:-}" && "$YAP_RELEASE_TAG" != "$tag" ]]; then
    echo "Release tag does not match CFBundleShortVersionString." >&2
    exit 1
fi
export YAP_RELEASE=1
/bin/bash Scripts/build-app.sh release
mkdir -p dist
stage="$(mktemp -d "$root/dist/.release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Yap.app"
ditto "${YAP_OUTPUT_DIR:-$root/../outputs}/Yap.app" "$app"
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
[[ "$signature" == *"Authority=Developer ID Application:"* ]]
[[ "$signature" == *"TeamIdentifier=VSVHNQP588"* ]]
test -f "$app/Contents/Frameworks/ZoomSDK.framework/ZoomSDK"
test -f "$app/Contents/Frameworks/Sparkle.framework/Sparkle"
notary_args=(--keychain-profile "$YAP_NOTARY_PROFILE")
if [[ -n "${YAP_NOTARY_KEYCHAIN:-}" ]]; then
    notary_args+=(--keychain "$YAP_NOTARY_KEYCHAIN")
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/notarization.zip"
xcrun notarytool submit "$stage/notarization.zip" "${notary_args[@]}" --wait --timeout 45m
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

# Create the update archive only after stapling, so its signature covers final bytes.
mkdir "$stage/feed" "$stage/dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/feed/Yap-macOS.zip"
ditto "$app" "$stage/dmg/Yap.app"
ln -s /Applications "$stage/dmg/Applications"
hdiutil create -volname Yap -srcfolder "$stage/dmg" -ov -format UDZO "$stage/Yap.dmg"
codesign --force --sign "$YAP_SIGNING_IDENTITY" --timestamp "$stage/Yap.dmg"
xcrun notarytool submit "$stage/Yap.dmg" "${notary_args[@]}" --wait --timeout 45m
xcrun stapler staple "$stage/Yap.dmg"
xcrun stapler validate "$stage/Yap.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$stage/Yap.dmg"
hdiutil verify "$stage/Yap.dmg"

sparkle_bin="$root/.build/artifacts/sparkle/Sparkle/bin"
"$sparkle_bin/generate_appcast" --ed-key-file "$YAP_UPDATE_PRIVATE_KEY_FILE" \
    --download-url-prefix "https://github.com/$YAP_RELEASE_REPOSITORY/releases/download/$tag/" \
    --maximum-deltas 0 --maximum-versions 1 "$stage/feed"
python3 Scripts/validate-appcast.py "$stage/feed/appcast.xml" "$stage/feed/Yap-macOS.zip" "$app/Contents/Info.plist"
"$sparkle_bin/sign_update" --verify --ed-key-file "$YAP_UPDATE_PRIVATE_KEY_FILE" "$stage/feed/appcast.xml"
for asset in Yap-macOS.zip appcast.xml; do
    cp "$stage/feed/$asset" "dist/$asset"
done
cp "$stage/Yap.dmg" dist/Yap.dmg
(cd dist && shasum -a 256 Yap-macOS.zip > Yap-macOS.zip.sha256 && shasum -a 256 Yap.dmg > Yap.dmg.sha256)
printf 'Signed and notarized release artifacts ready in %s/dist\n' "$root"
