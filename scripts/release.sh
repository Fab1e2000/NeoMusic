#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/check-module-boundaries.py
version=$(awk '$1 == "MARKETING_VERSION:" {print $2}' project.yml)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "project.yml 的 MARKETING_VERSION 必须为 X.Y.Z" >&2
  exit 1
fi
tag="v$version"
if [[ "${GITHUB_REF_TYPE:-}" == tag ]]; then
  if [[ "$GITHUB_REF_NAME" != "$tag" ]]; then
    echo "标签 $GITHUB_REF_NAME 与 project.yml 的版本 $tag 不一致" >&2
    exit 1
  fi
  test -f "docs/releases/$tag.md"
fi

xcodegen generate
xcodebuild -version
derived_data="${NEOMUSIC_DERIVED_DATA:-build/release/DerivedData}"
mkdir -p build/release dist
xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
  build 2>&1 | tee build/release/xcodebuild.log

app="$derived_data/Build/Products/Release-iphoneos/NeoMusic.app"
python3 - "$app" "$version" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == sys.argv[2]
assert info["CFBundleIdentifier"] == "com.elsterlee.NeoMusic"
assert info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconName"] == "NeoMusicIcon"
for name in ("AccountReference", "embedded.mobileprovision", "_CodeSignature"):
    assert not (app / name).exists(), f"公开未签名包不应包含 {name}"
assert not list(app.rglob("*.xctest")), "发布包不应包含测试插件"
for name in ("GPL-3.0.txt", "Nuke-LICENSE.txt", "ThirdPartyLicenses.txt", "PlayerSourceNotices.txt", "PlayerSourceManifest.json"):
    assert (app / name).is_file(), f"缺少许可或来源资源：{name}"
PY

staging=$(mktemp -d build/release/package.XXXXXX)
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
ditto "$app" "$staging/Payload/NeoMusic.app"
ipa="NeoMusic-$tag-unsigned.ipa"
ditto -c -k --norsrc --keepParent "$staging/Payload" "dist/$ipa"
(cd dist && shasum -a 256 "$ipa" > SHA256SUMS.txt)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "tag=$tag" >> "$GITHUB_OUTPUT"
fi
echo "已生成 dist/${ipa}（未签名，需自行签名后安装）"
