#!/bin/bash
set -euo pipefail
: "${YAP_RELEASE_REPOSITORY:?Set the binary distribution repository}"
: "${YAP_RELEASE_TAG:?Set the release tag}"
test "$(gh api "repos/$YAP_RELEASE_REPOSITORY" --jq .visibility)" = public
# Never overwrite a release clients may already have downloaded.
if gh release view "$YAP_RELEASE_TAG" --repo "$YAP_RELEASE_REPOSITORY" >/dev/null 2>&1; then
    echo "Release already exists. Inspect it before retrying; published assets are immutable." >&2
    exit 1
fi
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
printf 'Yap %s\n\nRequires Apple silicon and macOS 26 or later. Download Yap.dmg, then drag Yap into Applications.\n\nIncludes signed, notarized installers and a signed in-app update feed.\n' "$YAP_RELEASE_TAG" > "$notes"
gh release create "$YAP_RELEASE_TAG" --repo "$YAP_RELEASE_REPOSITORY" --draft \
    --title "Yap $YAP_RELEASE_TAG" --notes-file "$notes" \
    dist/Yap-macOS.zip dist/Yap-macOS.zip.sha256 dist/Yap.dmg dist/Yap.dmg.sha256 dist/appcast.xml
# The latest-feed URL changes only after all archives and signatures are uploaded.
gh release edit "$YAP_RELEASE_TAG" --repo "$YAP_RELEASE_REPOSITORY" --draft=false --latest
