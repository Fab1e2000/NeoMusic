#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/check-module-boundaries.py
xcodegen generate
xcodebuild -version

simulator_id=$(python3 - <<'PY'
import json, subprocess
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
# 使用标准 iPhone；折叠机型的安全区与现有导航几何测试不同。
candidates = [d for runtime, group in devices.items() if runtime.endswith(".iOS-27-0")
              for d in group if d.get("isAvailable") and d["name"].startswith("iPhone") and "Duo" not in d["name"]]
if not candidates:
    raise SystemExit("需要已安装 iOS 27.0 的标准 iPhone 模拟器")
device = sorted(candidates, key=lambda d: (d["name"] != "iPhone 18 Pro", d["state"] != "Booted", d["name"], d["udid"]))[0]
print(device["udid"])
PY
)

mkdir -p build/ci
xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Release \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "${NEOMUSIC_DERIVED_DATA:-build/ci/DerivedData}" \
  -resultBundlePath build/ci/TestResults.xcresult \
  -only-testing:NeoMusicTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
  test 2>&1 | tee build/ci/xcodebuild.log
