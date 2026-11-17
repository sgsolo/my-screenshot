#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
identity="${MYSCREENSHOT_SIGNING_IDENTITY:?Set MYSCREENSHOT_SIGNING_IDENTITY to a Developer ID Application identity}"
profile="${MYSCREENSHOT_NOTARY_PROFILE:-MyScreenshot}"
fingerprint="$(security find-identity -v -p codesigning | awk -F '"' -v identity="$identity" '
    $2 ~ /^Developer ID Application: / {
        split($1, fields, " ")
        if ($2 == identity || fields[2] == identity) print fields[2]
    }
')"
if [[ -z "$fingerprint" || "$fingerprint" == *$'\n'* ]]; then
    printf '%s\n' 'Specify one valid Developer ID Application identity from Keychain.' >&2
    exit 1
fi

bundle="$(MYSCREENSHOT_SIGNING_IDENTITY="$fingerprint" "$project_dir/build.sh")"
build_dir="$(dirname "$bundle")"
stage="$(mktemp -d "$build_dir/.notarize.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT

ditto -c -k --keepParent "$bundle" "$stage/submission.zip"
if ! result="$(xcrun notarytool submit "$stage/submission.zip" --keychain-profile "$profile" --wait --output-format json)"; then
    printf '%s\n' "$result" >&2
    exit 1
fi
printf '%s\n' "$result"
if [[ "$(printf '%s\n' "$result" | plutil -extract status raw -o - -)" != "Accepted" ]]; then
    printf '%s\n' 'Apple did not accept the notarization submission.' >&2
    exit 1
fi

xcrun stapler staple "$bundle"
ditto -c -k --keepParent "$bundle" "$stage/MyScreenshot-macOS.zip"
ditto -x -k "$stage/MyScreenshot-macOS.zip" "$stage/extracted"
extracted_app="$stage/extracted/$(basename "$bundle")"
codesign --verify --strict "$extracted_app"
xcrun stapler validate "$extracted_app"
syspolicy_check distribution "$extracted_app"

mv "$stage/MyScreenshot-macOS.zip" "$build_dir/MyScreenshot-macOS.zip"
printf '%s\n' "$build_dir/MyScreenshot-macOS.zip"
