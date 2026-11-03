#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
simulator="${1:?Pass the booted NeoMusic simulator UDID}"
output="${2:-build/artist-backdrop-capture-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$output"
xcrun simctl io "$simulator" recordVideo "$output/scroll.mp4" > "$output/recording.log" 2>&1 &
recorder=$!
trap 'kill -INT "$recorder" 2>/dev/null || true' EXIT
xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath build/artist-preview-derived \
  -resultBundlePath "$output/capture.xcresult" \
  -only-testing:NeoMusicNavigationUITests/ArtistIntegrationUITests/testCaptureArtistBackdrop \
  test > "$output/test.log" 2>&1
kill -INT "$recorder"
wait "$recorder" || true
trap - EXIT
xcrun xcresulttool export attachments --path "$output/capture.xcresult" --output-path "$output/screenshots"
mkdir -p "$output/frames"
ffmpeg -loglevel error -i "$output/scroll.mp4" -vf fps=12 "$output/frames/%05d.png"
printf '%s\n' "$output"
