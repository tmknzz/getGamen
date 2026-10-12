#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
derived_data="$repo_dir/.build/xcode-release"
# Clean first so removed resources or stale App Intents metadata never ship.
xcodebuild -project getGamen.xcodeproj -scheme getGamen -configuration Release \
    -derivedDataPath "$derived_data" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES clean build >&2
build_dir="$(mktemp -d "$repo_dir/.build/getGamen-app.XXXXXX")"
bundle_dir="$build_dir/getGamen.app"
ditto "$derived_data/Build/Products/Release/getGamen.app" "$bundle_dir" >&2
set -- --force --sign "${GETGAMEN_SIGN_IDENTITY:--}" --options runtime
if [[ -n "${GETGAMEN_SIGN_IDENTITY:-}" ]]; then
    set -- "$@" --timestamp
fi
codesign "$@" "$bundle_dir" >&2
codesign --verify --strict "$bundle_dir" >&2
if [[ -n "${GETGAMEN_SIGN_IDENTITY:-}" ]]; then
    helper_dir="$bundle_dir/Contents/Helpers/GetGamenAutomation.app"
    if ! helper_signature="$(codesign -dv --verbose=4 "$helper_dir" 2>&1)" ||
        ! grep -Fqx "Authority=$GETGAMEN_SIGN_IDENTITY" <<< "$helper_signature"; then
        printf 'Error: helper "%s" is not signed with expected identity "%s".\n' "$helper_dir" "$GETGAMEN_SIGN_IDENTITY" >&2
        exit 1
    fi
fi
printf '%s\n' "$bundle_dir"
