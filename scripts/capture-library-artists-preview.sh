#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

simulator="${1:-booted}"
if ! xcrun simctl list devices booted >/dev/null; then
    printf '%s\n' '无法连接 CoreSimulator，请在宿主机终端运行此脚本。' >&2
    exit 1
fi
if ! xcrun simctl getenv "$simulator" HOME >/dev/null; then
    printf '%s\n' '请先启动一个 iOS 27 iPhone 模拟器，或传入已启动设备的 UDID。' >&2
    exit 1
fi

output="$PWD/build/library-artists-preview"
derived="$output/DerivedData"
mkdir -p "$output"
bundle_id="com.elsterlee.NeoMusic.ArtistsPreview"
if ! xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    'PRODUCT_BUNDLE_IDENTIFIER=com.elsterlee.$(PRODUCT_NAME:rfc1034identifier).ArtistsPreview' \
    CODE_SIGNING_ALLOWED=NO build > "$output/host-build.log" 2>&1; then
    tail -n 40 "$output/host-build.log" >&2
    exit 1
fi

app="$derived/Build/Products/Debug-iphonesimulator/NeoMusic.app"
xcrun simctl install "$simulator" "$app"
for scene in artists-list artist-detail-grid artist-detail-list pinned-artist; do
    xcrun simctl launch --terminate-running-process "$simulator" "$bundle_id" \
        -libraryArtistsPreview "$scene" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
    sleep 4
    xcrun simctl io "$simulator" screenshot "$output/$scene.png"
done
