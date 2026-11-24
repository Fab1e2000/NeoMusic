#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

simulator_id=$(python3 - <<'PY'
import json
import re
import subprocess

try:
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
    ))["devices"]
except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError):
    raise SystemExit("无法读取 CoreSimulator 设备列表")
candidates = []
for runtime, group in devices.items():
    if not re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-27(?:-\d+)*", runtime):
        continue
    candidates.extend(device for device in group if device.get("isAvailable")
                      and device["name"].startswith("iPhone") and "Duo" not in device["name"])
if not candidates:
    raise SystemExit("需要已安装 iOS 27 的标准 iPhone 模拟器")
device = min(candidates, key=lambda d: (d["state"] != "Booted", d["name"] != "iPhone 18 Pro", d["name"], d["udid"]))
print(device["udid"])
PY
)

xcodegen generate
mkdir -p build/ci
result=build/ci/SmokeUIResults.xcresult
previous=build/ci/SmokeUIResults.previous.xcresult
if [ -e "$result" ] || [ -L "$result" ]; then
  rm -rf "$previous"
  mv "$result" "$previous"
fi

echo "Smoke UI · Debug · iOS 27 iPhone ($simulator_id)"
if xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "${NEOMUSIC_DERIVED_DATA:-build/ci/DerivedData}" \
  -resultBundlePath "$result" -parallel-testing-enabled NO \
  -only-testing:NeoMusicNavigationUITests/SmokeJourneyUITests CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | tee build/ci/smoke-ui.log; then
  echo "Smoke UI 通过，结果位于 $result"
else
  status=$?
  printf 'Smoke UI 失败（退出码 %s），日志位于 build/ci/smoke-ui.log\n' "$status" >&2
  exit "$status"
fi
