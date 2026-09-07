#!/bin/bash
set -euo pipefail
# Exercise CI credential import, timestamping, Apple notarization, stapling,
# and Gatekeeper without needing to transfer the proprietary Zoom SDK.
# This fixture validates credentials; the real Zooom bundle needs its own check.
: "${WHOOSH_SIGNING_IDENTITY:?Set the Developer ID identity}"
: "${ZOOOM_NOTARY_PROFILE:?Set the notarytool credential profile}"
: "${ZOOOM_SIGNING_REPORT_DIR:?Set a directory for non-secret validation reports}"
test "$WHOOSH_SIGNING_IDENTITY" != '-'
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zooom-signing-check.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$ZOOOM_SIGNING_REPORT_DIR"
app="$stage/Zooom Signing Check.app"
mkdir -p "$app/Contents/MacOS"
cat > "$stage/main.swift" <<'SWIFT'
import Foundation
print("Zooom release signing verification")
SWIFT
xcrun swiftc -O "$stage/main.swift" -o "$app/Contents/MacOS/ZooomSigningCheck"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({
        'CFBundleIdentifier': 'com.grinich.zooom.signing-check',
        'CFBundleName': 'Zooom Signing Check',
        'CFBundleExecutable': 'ZooomSigningCheck',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '26.0',
        'LSUIElement': True,
    }, stream)
PY
codesign --force --sign "$WHOOSH_SIGNING_IDENTITY" --options runtime --timestamp "$app"
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2> "$ZOOOM_SIGNING_REPORT_DIR/signature.txt"
grep -q '^Authority=Developer ID Application:' "$ZOOOM_SIGNING_REPORT_DIR/signature.txt"
grep -q '^TeamIdentifier=VSVHNQP588$' "$ZOOOM_SIGNING_REPORT_DIR/signature.txt"
grep -q '^Timestamp=' "$ZOOOM_SIGNING_REPORT_DIR/signature.txt"
grep -q 'flags=.*runtime' "$ZOOOM_SIGNING_REPORT_DIR/signature.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/signing-check.zip"
notary_args=(--keychain-profile "$ZOOOM_NOTARY_PROFILE")
if [[ -n "${ZOOOM_NOTARY_KEYCHAIN:-}" ]]; then
    notary_args+=(--keychain "$ZOOOM_NOTARY_KEYCHAIN")
fi
if ! xcrun notarytool submit "$stage/signing-check.zip" "${notary_args[@]}" \
    --wait --timeout 20m --output-format json > "$ZOOOM_SIGNING_REPORT_DIR/notarization.json"; then
    echo 'Apple notarization failed or timed out; see the retained report.' >&2
    cat "$ZOOOM_SIGNING_REPORT_DIR/notarization.json"
    exit 1
fi
submission_id="$(python3 - "$ZOOOM_SIGNING_REPORT_DIR/notarization.json" <<'PY'
import json, sys, uuid
with open(sys.argv[1]) as stream:
    print(uuid.UUID(json.load(stream)['id']))
PY
)"
xcrun notarytool log "$submission_id" "${notary_args[@]}" "$ZOOOM_SIGNING_REPORT_DIR/apple-log.json"
python3 - "$ZOOOM_SIGNING_REPORT_DIR/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept the signing verification app')
print('Apple accepted the CI signing verification app.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app" > "$ZOOOM_SIGNING_REPORT_DIR/stapler.txt" 2>&1
spctl --assess --type execute --verbose=2 "$app" > "$ZOOOM_SIGNING_REPORT_DIR/gatekeeper.txt" 2>&1
echo 'Developer ID import, timestamp, notarization, staple, and Gatekeeper checks passed.'
