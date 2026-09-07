#!/bin/bash
set -euo pipefail
# Only ephemeral GitHub runners. Never alter the developer's login keychain.
test "${GITHUB_ACTIONS:-}" = true
: "${DEVELOPER_ID_P12_BASE64:?Missing Developer ID certificate}"
: "${DEVELOPER_ID_P12_PASSWORD:?Missing certificate password}"
: "${APPLE_API_KEY_ID:?Missing Apple API key ID}"
: "${APPLE_API_ISSUER_ID:?Missing Apple API issuer ID}"
: "${APPLE_API_PRIVATE_KEY_BASE64:?Missing Apple API key}"
: "${SPARKLE_PRIVATE_KEY:?Missing Sparkle private signing key}"
umask 077
keychain="$RUNNER_TEMP/zooom-release.keychain-db"
password="$(openssl rand -hex 32)"
echo "::add-mask::$password"
echo "ZOOOM_NOTARY_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
echo "ZOOOM_UPDATE_PRIVATE_KEY_FILE=$RUNNER_TEMP/sparkle-key.txt" >> "$GITHUB_ENV"
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -D > "$RUNNER_TEMP/developer-id.p12"
printf '%s' "$APPLE_API_PRIVATE_KEY_BASE64" | base64 -D > "$RUNNER_TEMP/notary-key.p8"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$RUNNER_TEMP/sparkle-key.txt"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$RUNNER_TEMP/developer-id.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
xcrun notarytool store-credentials zooom-ci --key "$RUNNER_TEMP/notary-key.p8" \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --keychain "$keychain"
rm -f "$RUNNER_TEMP/developer-id.p12" "$RUNNER_TEMP/notary-key.p8"
