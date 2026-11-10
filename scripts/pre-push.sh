#!/bin/bash
# 推送前跑与 GitHub CI 相同的检查。纯文档、设计参考和许可证与 CI 的 paths-ignore 一样跳过。
set -euo pipefail
cd "$(dirname "$0")/.."

zero=0000000000000000000000000000000000000000
paths=$(mktemp)
commits=$(mktemp)
trap 'rm -f "$paths" "$commits"' EXIT

while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    if [ "$local_sha" = "$zero" ]; then
        continue
    fi
    commit=$(git rev-parse "$local_sha^{commit}")
    if [ "$remote_sha" = "$zero" ]; then
        base=$(git merge-base "$commit" origin/main 2>/dev/null || true)
        if [ -n "$base" ]; then
            git diff --name-only --no-renames "$base" "$commit" >"$paths"
        else
            # 没有已知基线时检查整棵树，也覆盖根提交和合并提交。
            git ls-tree -r --name-only "$commit" >"$paths"
        fi
    else
        git diff --name-only --no-renames "$remote_sha" "$commit" >"$paths"
    fi

    if python3 - "$paths" <<'PY'
import sys
path = sys.argv[1]
lines = [line.strip() for line in open(path, encoding="utf-8") if line.strip()]
def ignored(name: str) -> bool:
    return name == "LICENSE" or name.startswith(("docs/", "design/")) or name.endswith(".md")
sys.exit(0 if lines and any(not ignored(name) for name in lines) else 2)
PY
    then
        printf '%s\n' "$commit" >>"$commits"
    else
        result_code=$?
        if [ "$result_code" -ne 2 ]; then
            exit "$result_code"
        fi
    fi
done

if [ ! -s "$commits" ]; then
    echo "推送内容与 CI 的忽略范围相同，跳过本地 CI。"
    exit 0
fi

head_commit=$(git rev-parse HEAD)
while read -r commit; do
    if [ "$commit" != "$head_commit" ]; then
        echo "需要 CI 的待推提交必须是当前 HEAD，请切换到对应提交后推送。" >&2
        exit 1
    fi
done <"$commits"
working_tree=$(git status --porcelain --untracked-files=normal)
if [ -n "$working_tree" ]; then
    echo "需要 CI 的推送要求干净工作区，请先保存已跟踪和未跟踪的修改。" >&2
    exit 1
fi

if [ -e build/ci/TestResults.xcresult ]; then
    rm -rf build/ci/TestResults.previous.xcresult
    mv build/ci/TestResults.xcresult build/ci/TestResults.previous.xcresult
fi
if [ -f build/ci/source-state.json ]; then
    mv -f build/ci/source-state.json build/ci/source-state.previous.json
fi

echo "推送前运行与 GitHub 相同的 CI：脚本回归、边界检查、XcodeGen、NeoMusicTests Release。"
bash scripts/ci.sh
