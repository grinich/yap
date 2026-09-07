#!/bin/bash
set -euo pipefail
: "${ZOOOM_RELEASE_REPOSITORY:?Set the binary distribution repository}"
: "${ZOOOM_RELEASE_TAG:?Set the release tag}"
test "$(gh api "repos/$ZOOOM_RELEASE_REPOSITORY" --jq .visibility)" = public
# Never overwrite a release clients may already have downloaded.
if gh release view "$ZOOOM_RELEASE_TAG" --repo "$ZOOOM_RELEASE_REPOSITORY" >/dev/null 2>&1; then
    echo "Release already exists. Inspect it before retrying; published assets are immutable." >&2
    exit 1
fi
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
printf 'Zooom %s\n\nRequires Apple silicon and macOS 26 or later. Download Zooom.dmg, then drag Zooom into Applications.\n\nIncludes signed, notarized installers and a signed in-app update feed.\n' "$ZOOOM_RELEASE_TAG" > "$notes"
gh release create "$ZOOOM_RELEASE_TAG" --repo "$ZOOOM_RELEASE_REPOSITORY" --draft \
    --title "Zooom $ZOOOM_RELEASE_TAG" --notes-file "$notes" \
    dist/Zooom-macOS.zip dist/Zooom-macOS.zip.sha256 dist/Zooom.dmg dist/Zooom.dmg.sha256 dist/appcast.xml
# The latest-feed URL changes only after all archives and signatures are uploaded.
gh release edit "$ZOOOM_RELEASE_TAG" --repo "$ZOOOM_RELEASE_REPOSITORY" --draft=false --latest
