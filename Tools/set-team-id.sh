#!/usr/bin/env bash
# 把项目里的 Apple Developer Team ID 换成你自己的。
#
# 用法：Tools/set-team-id.sh ABCDE12345
#
# Team ID 在四个地方要保持一致：签名配置、两个 entitlements 里的 App Group、
# 以及代码里读 App Group 的常量。少改一处，宿主 App 和小组件就会读到不同的容器，
# 表现是小组件永远显示「后台没在运行」。
set -euo pipefail

NEW_TEAM="${1:-}"
if [[ -z "$NEW_TEAM" ]]; then
    echo "用法: $0 <你的 Team ID>"
    echo
    echo "查自己的 Team ID："
    echo "  security find-certificate -c 'Developer ID Application' -p |"
    echo "    openssl x509 -noout -subject"
    echo "  取 OU= 后面那一段"
    exit 1
fi

cd "$(dirname "$0")/.."

OLD_TEAM=$(grep -o 'DEVELOPMENT_TEAM: [A-Z0-9]*' project.yml | head -1 | awk '{print $2}')
if [[ -z "$OLD_TEAM" ]]; then
    echo "没能从 project.yml 里读出当前的 Team ID"
    exit 1
fi

if [[ "$OLD_TEAM" == "$NEW_TEAM" ]]; then
    echo "已经是 $NEW_TEAM，无需改动"
    exit 0
fi

for f in project.yml App/App.entitlements Widget/Widget.entitlements Shared/SharedModel.swift; do
    if grep -q "$OLD_TEAM" "$f"; then
        sed -i '' "s/$OLD_TEAM/$NEW_TEAM/g" "$f"
        echo "  已更新 $f"
    fi
done

echo
echo "Team ID: $OLD_TEAM → $NEW_TEAM"
echo "接着执行 xcodegen generate 重新生成工程。"
