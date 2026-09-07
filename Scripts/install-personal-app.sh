#!/bin/bash
set -euo pipefail

# Install an already packaged personal build. Never sign, launch, or grant access.
# Legacy apps remain on disk; account/preferences migration belongs to Yap itself.
YAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YAP_SOURCE="${YAP_SOURCE_APP:-$YAP_ROOT/../outputs/Yap.app}"
YAP_PARENT="$HOME/Applications"
YAP_DESTINATION="$YAP_PARENT/Yap.app"
YAP_STAGE=""
YAP_COMMITTED=0
YAP_MIGRATE=0
YAP_BUNDLE_ID="com.grinich.yap"
YAP_TEAM_ID="VSVHNQP588"
# Explicit compatibility identities for approved historical installations.
YAP_LEGACY_ZOOOM="$YAP_PARENT/Zooom.app"
YAP_LEGACY_WHOOSH="$YAP_PARENT/Whoosh.app"
YAP_MIGRATION_IDENTITY="9E5ACA63C3AA07131DF1644F56AC1C9EAA6E794F"
YAP_LEGACY_PERSONAL_REQUIREMENT='identifier "app.whoosh.personal" and certificate leaf = H"b2a226828a24564805a129b57b95be93784191f2"'

fail() { printf '%s\n' "$*" >&2; exit 1; }
if [[ $# -eq 1 && "$1" == --migrate-from-personal ]]; then
    YAP_MIGRATE=1
elif [[ $# -eq 1 && "$1" == --migrate-from-woosh ]]; then
    YAP_MIGRATE=2
elif [[ $# -eq 1 && "$1" == --migrate-from-zooom ]]; then
    YAP_MIGRATE=3
elif [[ $# -ne 0 ]]; then
    fail 'Usage: install-personal-app.sh [--migrate-from-zooom | --migrate-from-woosh | --migrate-from-personal]'
fi

require_stopped() {
    python3 "$YAP_ROOT/Scripts/install-safety.py" "$YAP_PARENT"
}

YAP_IDENTITY="$(python3 "$YAP_ROOT/Scripts/resolve-signing-identity.py" "$YAP_ROOT")"
[[ "$YAP_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] || fail 'Configure the exact persistent certificate fingerprint before installing.'
YAP_IDENTITY="$(printf '%s' "$YAP_IDENTITY" | /usr/bin/tr '[:lower:]' '[:upper:]')"
# Pin this package's certificate while preserving Apple's stable team requirement.
standard_requirement() {
    /usr/bin/csreq -r "=identifier \"$1\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$YAP_TEAM_ID\"" -t
}
YAP_STANDARD_REQUIREMENT="$(standard_requirement "$YAP_BUNDLE_ID")"
YAP_REQUIREMENT="$YAP_STANDARD_REQUIREMENT and certificate leaf = H\"$YAP_IDENTITY\""
if [[ "$YAP_MIGRATE" -eq 1 ]]; then
    [[ "$YAP_IDENTITY" == "$YAP_MIGRATION_IDENTITY" ]] || fail 'The one-time personal migration requires the explicitly approved Developer ID certificate.'
fi

verify_bundle() {
    [[ -d "$1" && ! -L "$1" ]] || fail "Expected a real app bundle: $1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "$2" ]] || fail "Refusing an app with a different bundle identifier: $1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist")" == "$4" ]] || fail "Unexpected app executable: $1"
    /usr/bin/codesign --verify --deep --strict "$1"
    /usr/bin/codesign --verify --strict -R "=$3" "$1"
}

verify_app() {
    verify_bundle "$1" "$YAP_BUNDLE_ID" "$YAP_REQUIREMENT" Yap
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$1/Contents/Info.plist")" == Yap ]] || fail "Expected the Yap bundle name: $1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$1/Contents/Info.plist")" == Yap ]] || fail "Expected the Yap display name: $1"
}

designated_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'
}

verify_destination() {
    if [[ -e "$YAP_DESTINATION" || -L "$YAP_DESTINATION" ]]; then
        # An ordinary Yap update cannot silently change the installed requirement.
        verify_bundle "$YAP_DESTINATION" "$YAP_BUNDLE_ID" "$YAP_SOURCE_REQUIREMENT" Yap
        [[ "$(designated_requirement "$YAP_DESTINATION")" == "$YAP_SOURCE_REQUIREMENT" ]] || fail 'Refusing to change the installed app’s designated requirement.'
    fi
}

verify_legacy_installations() {
    local requirement
    if [[ -e "$YAP_LEGACY_ZOOOM" || -L "$YAP_LEGACY_ZOOOM" ]]; then
        requirement="$(standard_requirement com.grinich.zooom)"
        verify_bundle "$YAP_LEGACY_ZOOOM" com.grinich.zooom "$requirement" Whoosh
        [[ "$(designated_requirement "$YAP_LEGACY_ZOOOM")" == "$requirement" ]] || fail 'The legacy Zooom app has an unexpected designated requirement.'
    elif [[ "$YAP_MIGRATE" -eq 3 ]]; then
        fail 'The requested migration requires ~/Applications/Zooom.app.'
    fi
    if [[ -e "$YAP_LEGACY_WHOOSH" || -L "$YAP_LEGACY_WHOOSH" ]]; then
        if [[ "$YAP_MIGRATE" -eq 1 ]]; then
            verify_bundle "$YAP_LEGACY_WHOOSH" app.whoosh.personal "$YAP_LEGACY_PERSONAL_REQUIREMENT" Whoosh
            [[ "$(designated_requirement "$YAP_LEGACY_WHOOSH")" == "$YAP_LEGACY_PERSONAL_REQUIREMENT" ]] || fail 'The legacy app is not the approved original personal identity.'
        else
            requirement="$(standard_requirement com.grinich.woosh)"
            verify_bundle "$YAP_LEGACY_WHOOSH" com.grinich.woosh "$requirement" Whoosh
            [[ "$(designated_requirement "$YAP_LEGACY_WHOOSH")" == "$requirement" ]] || fail 'The legacy Whoosh app has an unexpected designated requirement.'
        fi
    elif [[ "$YAP_MIGRATE" -eq 1 || "$YAP_MIGRATE" -eq 2 ]]; then
        fail 'The requested historical migration requires ~/Applications/Whoosh.app.'
    fi
}

[[ ! -L "$YAP_PARENT" ]] || fail 'The Applications destination must not be a symbolic link.'
require_stopped
verify_app "$YAP_SOURCE"
YAP_SOURCE_REQUIREMENT="$(designated_requirement "$YAP_SOURCE")"
[[ "$YAP_SOURCE_REQUIREMENT" == "$YAP_STANDARD_REQUIREMENT" ]] || fail 'The source must use the standard stable Apple Developer ID designated requirement for the configured team.'
verify_destination
verify_legacy_installations

/bin/mkdir -p "$YAP_PARENT"
YAP_STAGE="$(/usr/bin/mktemp -d "$YAP_PARENT/.yap-install.XXXXXX")"
cleanup() {
    # Keep a previous Yap recoverable if replacement is interrupted.
    if [[ "$YAP_COMMITTED" -eq 0 && -d "$YAP_STAGE/Previous.app" ]]; then
        if [[ ! -e "$YAP_DESTINATION" && ! -L "$YAP_DESTINATION" ]]; then
            /bin/mv "$YAP_STAGE/Previous.app" "$YAP_DESTINATION" || {
                printf 'Previous Yap retained at %s\n' "$YAP_STAGE/Previous.app" >&2
                return
            }
        else
            printf 'Previous Yap retained at %s\n' "$YAP_STAGE/Previous.app" >&2
            return
        fi
    fi
    /bin/rm -rf "$YAP_STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ditto "$YAP_SOURCE" "$YAP_STAGE/Yap.app"
verify_app "$YAP_STAGE/Yap.app"
[[ "$(designated_requirement "$YAP_STAGE/Yap.app")" == "$YAP_SOURCE_REQUIREMENT" ]] || fail 'The staged signature differs from the packaged source.'
require_stopped
verify_destination
verify_legacy_installations
if [[ -e "$YAP_DESTINATION" ]]; then
    /bin/mv "$YAP_DESTINATION" "$YAP_STAGE/Previous.app"
fi
/bin/mv "$YAP_STAGE/Yap.app" "$YAP_DESTINATION"
YAP_COMMITTED=1
# Register only the new installed app. Retained legacy applications are untouched.
YAP_REGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$YAP_REGISTER" -u "$YAP_SOURCE" >/dev/null 2>&1 || true
"$YAP_REGISTER" -f "$YAP_DESTINATION"
printf 'Installed %s\n' "$YAP_DESTINATION"
for legacy in "$YAP_LEGACY_ZOOOM" "$YAP_LEGACY_WHOOSH"; do
    if [[ -d "$legacy" ]]; then
        printf 'Legacy app retained at %s. Verify Yap and its saved accounts before archiving the old app.\n' "$legacy"
    fi
done
