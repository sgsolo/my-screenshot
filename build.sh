#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/build"
app_name='Мой Скриншот.app'
stage="$(mktemp -d "${TMPDIR:-/tmp}/my-screenshot.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT

bundle="$stage/$app_name"
iconset="$stage/AppIcon.iconset"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$iconset" "$build_dir"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
ditto "$project_dir/Resources" "$bundle/Contents/Resources"

for arch in arm64 x86_64; do
    xcrun swiftc -O -swift-version 6 -target "$arch-apple-macosx15.2" \
        "$project_dir/Sources/main.swift" "$project_dir/Sources/CaptureCanvas.swift" -o "$stage/MyScreenshot-$arch"
done
xcrun lipo -create "$stage/MyScreenshot-arm64" "$stage/MyScreenshot-x86_64" \
    -output "$bundle/Contents/MacOS/MyScreenshot"
xcrun swift "$project_dir/Sources/icon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
rm -rf "$build_dir/$app_name"
mv "$bundle" "$build_dir/$app_name"
printf '%s\n' "$build_dir/$app_name"
