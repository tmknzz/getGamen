#!/bin/bash
set -euo pipefail

: "${GETGAMEN_SIGN_IDENTITY:?Set GETGAMEN_SIGN_IDENTITY to the full certificate name, e.g. Developer ID Application: NAME (TEAMID)}"
: "${GETGAMEN_NOTARY_KEY:?Set GETGAMEN_NOTARY_KEY to the .p8 path}"
: "${GETGAMEN_NOTARY_KEY_ID:?Set GETGAMEN_NOTARY_KEY_ID}"
: "${GETGAMEN_NOTARY_ISSUER:?Set GETGAMEN_NOTARY_ISSUER}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$(GETGAMEN_SIGN_IDENTITY="$GETGAMEN_SIGN_IDENTITY" "$repo_dir/scripts/build-app.sh")"
signature="$(codesign -dv --verbose=4 "$app" 2>&1 | tee /dev/stderr)"
grep -Eq 'flags=[^[:space:]]*[(]([^)]*,)?runtime([,)])' <<< "$signature"
grep -Fqx "Authority=$GETGAMEN_SIGN_IDENTITY" <<< "$signature"
grep -Fqx 'TeamIdentifier=4PRU2H4FP5' <<< "$signature"
grep -Fqx 'Identifier=com.tmknzz.getGamen' <<< "$signature"
archs="$(lipo -archs "$app/Contents/MacOS/getGamen")"
printf '%s\n' "$archs" >&2
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :getGamenBuildNumber' "$app/Contents/Info.plist")"
stage="$(mktemp -d "$repo_dir/.build/getGamen-dmg.XXXXXX")"
ditto "$app" "$stage/getGamen.app" >&2
ln -s /Applications "$stage/Applications"
dmg="$repo_dir/.build/getGamen-$version-$build.dmg"
rm -f "$dmg"
diskutil image create from --format UDZO --volumeName getGamen "$stage" "$dmg" >&2
rm -rf "$stage"
codesign --force --sign "$GETGAMEN_SIGN_IDENTITY" --timestamp "$dmg" >&2
notary_status="$(xcrun notarytool submit "$dmg" --key "$GETGAMEN_NOTARY_KEY" --key-id "$GETGAMEN_NOTARY_KEY_ID" --issuer "$GETGAMEN_NOTARY_ISSUER" --wait 2>&1 | tee /dev/stderr)"
grep -Eq '^[[:space:]]*status: Accepted[[:space:]]*$' <<< "$notary_status"
xcrun stapler staple "$dmg" >&2
xcrun stapler validate "$dmg" >&2
spctl -a -t open --context context:primary-signature -vv "$dmg" >&2
mount_dir="$(mktemp -d "$repo_dir/.build/getGamen-mount.XXXXXX")"
trap 'diskutil eject "$mount_dir" >&2 || true; rmdir "$mount_dir" 2>/dev/null || true' EXIT
diskutil image attach --readOnly --nobrowse --mountPoint "$mount_dir" "$dmg" >&2
assessment="$(spctl -a -vv "$mount_dir/getGamen.app" 2>&1 | tee /dev/stderr)"
grep -q '^source=Notarized Developer ID$' <<< "$assessment"
printf '%s\n' "$dmg"
