#!/bin/bash
# 推送前跑与 GitHub CI 相同的检查。纯文档、设计参考和许可证与 CI 的 paths-ignore 一样跳过。
set -euo pipefail
cd "$(dirname "$0")/.."

zero=0000000000000000000000000000000000000000
paths=$(mktemp)
trap 'rm -f "$paths"' EXIT

while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    if [ "$local_sha" = "$zero" ]; then
        continue
    fi
    if [ "$remote_sha" = "$zero" ]; then
        base=$(git merge-base "$local_sha" origin/main 2>/dev/null || true)
        if [ -n "$base" ]; then
            git diff --name-only "$base" "$local_sha"
        else
            git diff-tree --no-commit-id --name-only -r "$local_sha"
        fi
    else
        git diff --name-only "$remote_sha" "$local_sha"
    fi
done >"$paths"

if python3 - "$paths" <<'PY'
import sys
path = sys.argv[1]
lines = [line.strip() for line in open(path, encoding="utf-8") if line.strip()]
def ignored(name: str) -> bool:
    return name == "LICENSE" or name.startswith(("docs/", "design/")) or name.endswith(".md")
sys.exit(0 if lines and any(not ignored(name) for name in lines) else 2)
PY
then
    :
else
    status=$?
    if [ "$status" -eq 2 ]; then
        echo "推送内容与 CI 的忽略范围相同，跳过本地 CI。"
        exit 0
    fi
    exit "$status"
fi

if [ -e build/ci/TestResults.xcresult ]; then
    rm -rf build/ci/TestResults.previous.xcresult
    mv build/ci/TestResults.xcresult build/ci/TestResults.previous.xcresult
fi

echo "推送前运行与 GitHub 相同的 CI：边界检查、XcodeGen、NeoMusicTests Release。"
exec bash scripts/ci.sh
