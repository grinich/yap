#!/bin/bash
set -euo pipefail

# Install an already packaged personal build. Never sign, launch, or grant access.
WHOOSH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHOOSH_SOURCE="${WHOOSH_SOURCE_APP:-$WHOOSH_ROOT/../outputs/Zooom.app}"
WHOOSH_PARENT="$HOME/Applications"
WHOOSH_DESTINATION="$WHOOSH_PARENT/Zooom.app"
WHOOSH_PREVIOUS_NAME="$WHOOSH_PARENT/Whoosh.app"
WHOOSH_PREVIOUS_PATH=""
WHOOSH_STAGE=""
WHOOSH_COMMITTED=0
WHOOSH_MIGRATE=0
WHOOSH_BUNDLE_ID="com.grinich.zooom"
WHOOSH_TEAM_ID="VSVHNQP588"
WHOOSH_MIGRATION_IDENTITY="9E5ACA63C3AA07131DF1644F56AC1C9EAA6E794F"
WHOOSH_LEGACY_REQUIREMENT='identifier "app.whoosh.personal" and certificate leaf = H"b2a226828a24564805a129b57b95be93784191f2"'

fail() { printf '%s\n' "$*" >&2; exit 1; }
if [[ $# -eq 1 && "$1" == --migrate-from-personal ]]; then
    WHOOSH_MIGRATE=1
elif [[ $# -eq 1 && "$1" == --migrate-from-woosh ]]; then
    WHOOSH_MIGRATE=2
elif [[ $# -ne 0 ]]; then
    fail 'Usage: install-personal-app.sh [--migrate-from-personal | --migrate-from-woosh]'
fi

require_stopped() {
    local matching_pids lookup_status process_id executable
    matching_pids="$(/usr/bin/pgrep -x Whoosh)" && lookup_status=0 || lookup_status=$?
    [[ "$lookup_status" -eq 1 ]] && return 0
    [[ "$lookup_status" -eq 0 ]] || fail 'Could not check whether the app is running.'
    while IFS= read -r process_id; do
        executable="$(/bin/ps -p "$process_id" -o comm=)" || fail 'Could not inspect a Zooom process. Retry the update.'
        # Isolated previews share the executable name. Only the installed
        # bundle being replaced (or migrated) must be stopped.
        case "$executable" in
            "$WHOOSH_DESTINATION/"*|"$WHOOSH_PREVIOUS_NAME/"*)
                fail 'Quit the installed Zooom app before installing or updating it.' ;;
        esac
    done <<< "$matching_pids"
}

WHOOSH_IDENTITY="$(python3 "$WHOOSH_ROOT/Scripts/resolve-signing-identity.py" "$WHOOSH_ROOT")"
[[ "$WHOOSH_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] || fail 'Configure the exact persistent certificate fingerprint before installing.'
WHOOSH_IDENTITY="$(printf '%s' "$WHOOSH_IDENTITY" | /usr/bin/tr '[:lower:]' '[:upper:]')"
# The configured fingerprint pins this package; Apple's chain and team keep the
# normal designated requirement stable when a Developer ID certificate renews.
WHOOSH_STANDARD_REQUIREMENT="$(/usr/bin/csreq -r "=identifier \"$WHOOSH_BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$WHOOSH_TEAM_ID\"" -t)"
WHOOSH_REQUIREMENT="$WHOOSH_STANDARD_REQUIREMENT and certificate leaf = H\"$WHOOSH_IDENTITY\""
WHOOSH_PREVIOUS_BUNDLE_ID="com.grinich.woosh"
WHOOSH_PREVIOUS_REQUIREMENT="$(/usr/bin/csreq -r "=identifier \"$WHOOSH_PREVIOUS_BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$WHOOSH_TEAM_ID\"" -t)"
if [[ "$WHOOSH_MIGRATE" -eq 1 ]]; then
    [[ "$WHOOSH_IDENTITY" == "$WHOOSH_MIGRATION_IDENTITY" ]] || fail 'The one-time migration requires the explicitly approved Developer ID certificate.'
fi

verify_bundle() {
    [[ -d "$1" && ! -L "$1" ]] || fail "Expected a real app bundle: $1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "$2" ]] || fail "Refusing an app with a different bundle identifier: $1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist")" == Whoosh ]] || fail "Unexpected app executable: $1"
    /usr/bin/codesign --verify --deep --strict "$1"
    /usr/bin/codesign --verify --strict -R "=$3" "$1"
}

verify_app() {
    verify_bundle "$1" "$WHOOSH_BUNDLE_ID" "$WHOOSH_REQUIREMENT"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$1/Contents/Info.plist")" == Zooom ]] || fail "Expected the renamed Zooom bundle: $1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$1/Contents/Info.plist")" == Zooom ]] || fail "Expected the Zooom display name: $1"
}

designated_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'
}

verify_destination() {
    WHOOSH_PREVIOUS_PATH=""
    if [[ -e "$WHOOSH_DESTINATION" || -L "$WHOOSH_DESTINATION" ]]; then
        [[ ! -e "$WHOOSH_PREVIOUS_NAME" && ! -L "$WHOOSH_PREVIOUS_NAME" ]] || fail 'Both ~/Applications/Zooom.app and Whoosh.app exist. Resolve the duplicate before updating.'
        [[ "$WHOOSH_MIGRATE" -ne 1 ]] || fail 'The one-time personal identity migration only applies to ~/Applications/Whoosh.app.'
        WHOOSH_PREVIOUS_PATH="$WHOOSH_DESTINATION"
    elif [[ -e "$WHOOSH_PREVIOUS_NAME" || -L "$WHOOSH_PREVIOUS_NAME" ]]; then
        WHOOSH_PREVIOUS_PATH="$WHOOSH_PREVIOUS_NAME"
    fi
    if [[ -n "$WHOOSH_PREVIOUS_PATH" ]]; then
        if [[ "$WHOOSH_MIGRATE" -eq 1 ]]; then
            verify_bundle "$WHOOSH_PREVIOUS_PATH" app.whoosh.personal "$WHOOSH_LEGACY_REQUIREMENT"
            [[ "$(designated_requirement "$WHOOSH_PREVIOUS_PATH")" == "$WHOOSH_LEGACY_REQUIREMENT" ]] || fail 'The existing app is not the approved original personal identity.'
        elif [[ "$WHOOSH_MIGRATE" -eq 2 ]]; then
            verify_bundle "$WHOOSH_PREVIOUS_PATH" "$WHOOSH_PREVIOUS_BUNDLE_ID" "$WHOOSH_PREVIOUS_REQUIREMENT"
            [[ "$(designated_requirement "$WHOOSH_PREVIOUS_PATH")" == "$WHOOSH_PREVIOUS_REQUIREMENT" ]] || fail 'The existing app is not the expected Apple Developer ID Whoosh identity.'
        else
            # Validate the existing build against the source's stable Apple/team
            # requirement, allowing a configured certificate renewal in this team.
            verify_bundle "$WHOOSH_PREVIOUS_PATH" "$WHOOSH_BUNDLE_ID" "$WHOOSH_SOURCE_REQUIREMENT"
            [[ "$(designated_requirement "$WHOOSH_PREVIOUS_PATH")" == "$WHOOSH_SOURCE_REQUIREMENT" ]] || fail 'Refusing to change the installed app’s designated requirement.'
        fi
    elif [[ "$WHOOSH_MIGRATE" -eq 1 ]]; then
        fail 'The one-time migration requires the original personal app at ~/Applications/Whoosh.app.'
    elif [[ "$WHOOSH_MIGRATE" -eq 2 ]]; then
        fail 'The bundle migration requires an existing com.grinich.woosh app.'
    fi
}

require_stopped
verify_app "$WHOOSH_SOURCE"
WHOOSH_SOURCE_REQUIREMENT="$(designated_requirement "$WHOOSH_SOURCE")"
[[ "$WHOOSH_SOURCE_REQUIREMENT" == "$WHOOSH_STANDARD_REQUIREMENT" ]] || fail 'The source must use the standard stable Apple Developer ID designated requirement for the configured team.'
[[ ! -L "$WHOOSH_PARENT" ]] || fail 'The Applications destination must not be a symbolic link.'
verify_destination

/bin/mkdir -p "$WHOOSH_PARENT"
WHOOSH_STAGE="$(/usr/bin/mktemp -d "$WHOOSH_PARENT/.whoosh-install.XXXXXX")"
cleanup() {
    # Keep the previous verified app recoverable if replacement is interrupted.
    if [[ "$WHOOSH_COMMITTED" -eq 0 && -d "$WHOOSH_STAGE/Previous.app" ]]; then
        if [[ ! -e "$WHOOSH_DESTINATION" && ! -L "$WHOOSH_DESTINATION" && ! -e "$WHOOSH_PREVIOUS_PATH" && ! -L "$WHOOSH_PREVIOUS_PATH" ]]; then
            /bin/mv "$WHOOSH_STAGE/Previous.app" "$WHOOSH_PREVIOUS_PATH" || {
                printf 'Previous app retained at %s\n' "$WHOOSH_STAGE/Previous.app" >&2
                return
            }
        else
            printf 'Previous app retained at %s\n' "$WHOOSH_STAGE/Previous.app" >&2
            return
        fi
    fi
    /bin/rm -rf "$WHOOSH_STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ditto "$WHOOSH_SOURCE" "$WHOOSH_STAGE/Zooom.app"
verify_app "$WHOOSH_STAGE/Zooom.app"
[[ "$(designated_requirement "$WHOOSH_STAGE/Zooom.app")" == "$WHOOSH_SOURCE_REQUIREMENT" ]] || fail 'The staged signature differs from the packaged source.'
require_stopped
verify_destination
if [[ -n "$WHOOSH_PREVIOUS_PATH" ]]; then
    /bin/mv "$WHOOSH_PREVIOUS_PATH" "$WHOOSH_STAGE/Previous.app"
fi
/bin/mv "$WHOOSH_STAGE/Zooom.app" "$WHOOSH_DESTINATION"
WHOOSH_COMMITTED=1
# Keep Launch Services pointed at the installed app after a name/identity migration.
# The generated output is a packaging artifact, not another installed client.
WHOOSH_REGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
unregister_previous_path() {
    # Already-unregistered/moved packages can return application-not-found.
    # That must not prevent registering the successfully installed app below.
    "$WHOOSH_REGISTER" -u "$1" >/dev/null 2>&1 || true
}
if [[ "$WHOOSH_PREVIOUS_PATH" == "$WHOOSH_PREVIOUS_NAME" ]]; then
    # The previous pathname is intentionally absent after the successful move.
    unregister_previous_path "$WHOOSH_PREVIOUS_NAME"
fi
unregister_previous_path "$WHOOSH_SOURCE"
if [[ -d "$WHOOSH_ROOT/../outputs/Whoosh.app" ]]; then
    unregister_previous_path "$WHOOSH_ROOT/../outputs/Whoosh.app"
fi
"$WHOOSH_REGISTER" -f "$WHOOSH_DESTINATION"
printf 'Installed %s\n' "$WHOOSH_DESTINATION"
