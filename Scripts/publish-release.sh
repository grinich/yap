#!/bin/bash
set -euo pipefail
publish=false
if [[ $# -eq 1 && "$1" == --publish ]]; then
    publish=true
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--publish]" >&2
    exit 2
fi
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
if [[ "$publish" == false ]]; then
    printf '\nRelease candidate for review. This draft is held pending required Zoom approval.\n' >> "$notes"
fi
gh release create "$YAP_RELEASE_TAG" --repo "$YAP_RELEASE_REPOSITORY" --draft \
    --title "Yap $YAP_RELEASE_TAG" --notes-file "$notes" \
    dist/Yap-macOS.zip dist/Yap-macOS.zip.sha256 dist/Yap.dmg dist/Yap.dmg.sha256 dist/appcast.xml
# A draft retains the verified SDK-integrated app without exposing downloads or
# changing the latest update feed. Publishing requires an explicit opt-in.
if [[ "$publish" == true ]]; then
    gh release edit "$YAP_RELEASE_TAG" --repo "$YAP_RELEASE_REPOSITORY" --draft=false --latest
else
    echo "Created draft $YAP_RELEASE_TAG. No public downloads or latest-feed change."
fi
