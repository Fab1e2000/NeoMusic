#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/ci
if [ -e build/ci/TestResults.xcresult ] || [ -L build/ci/TestResults.xcresult ]; then
  rm -rf build/ci/TestResults.previous.xcresult
  mv build/ci/TestResults.xcresult build/ci/TestResults.previous.xcresult
  if [ -f build/ci/source-state.json ]; then
    mv -f build/ci/source-state.json build/ci/source-state.previous.json
  else
    rm -f build/ci/source-state.previous.json
  fi
fi
python3 - <<'PY'
from datetime import datetime, timezone
import json, subprocess
from pathlib import Path

state = {
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "dirty": bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"])),
    "startedAt": datetime.now(timezone.utc).isoformat(),
    "status": "running",
}
Path("build/ci/source-state.json").write_text(json.dumps(state, indent=2) + "\n")
PY

record_result() {
  local result_code=$?
  python3 - "$result_code" <<'PY'
from datetime import datetime, timezone
import json, subprocess, sys
from pathlib import Path

path = Path("build/ci/source-state.json")
state = json.loads(path.read_text())
state["exitCode"] = int(sys.argv[1])
state["status"] = "passed" if state["exitCode"] == 0 else "failed"
state["finishedAt"] = datetime.now(timezone.utc).isoformat()
state["finishedDirty"] = bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"]))
path.write_text(json.dumps(state, indent=2) + "\n")
PY
  exit "$result_code"
}
trap record_result EXIT

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests
python3 scripts/check-module-boundaries.py
python3 scripts/check-vendor-notices.py
swift test --package-path Packages/AudioStreaming 2>&1 | tee build/ci/audio-streaming.log
xcodegen generate
xcodebuild -version

simulator_id=$(python3 - <<'PY'
import json, subprocess
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
candidates = [d for runtime, group in devices.items() if runtime.endswith(".iOS-27-0")
              for d in group if d.get("isAvailable") and d["name"].startswith("iPhone") and "Duo" not in d["name"]]
if not candidates:
    raise SystemExit("需要已安装 iOS 27.0 的标准 iPhone 模拟器")
device = sorted(candidates, key=lambda d: (d["name"] != "iPhone 18 Pro", d["state"] != "Booted", d["name"], d["udid"]))[0]
print(device["udid"])
PY
)

xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Release \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "${NEOMUSIC_DERIVED_DATA:-build/ci/DerivedData}" \
  -resultBundlePath build/ci/TestResults.xcresult \
  -only-testing:NeoMusicTests -only-testing:FullScreenPlayerTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
  test 2>&1 | tee build/ci/xcodebuild.log
