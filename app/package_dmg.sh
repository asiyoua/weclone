#!/bin/bash

# 免费分发版 DMG 打包脚本（无需苹果开发者账号）
# 用法: ./package_dmg.sh

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="WeClone.app"
# 版本号取自项目根目录 VERSION，DMG 命名 WeClone-x.y.z.dmg（自动更新按此名拼直链）
VERSION="$(tr -d '[:space:]' < ../VERSION 2>/dev/null || true)"
VERSION="${VERSION:-0.0.0}"
DMG_NAME="WeClone-$VERSION"
OUT_DIR="dist"
STAGE_DIR="/tmp/WeCloneDmgStage"
DMG_PATH="$OUT_DIR/${DMG_NAME}.dmg"

echo "📦 开始打包免费分发版 DMG..."

if [ ! -d "$APP_NAME" ]; then
  echo "ℹ️ 未检测到 $APP_NAME，先执行构建..."
  ./build.sh
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
mkdir -p "$OUT_DIR"

cp -R "$APP_NAME" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "WeClone" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "✅ 打包完成: $(pwd)/$DMG_PATH"
echo ""
echo "分发说明:"
echo "  1) 发送该 dmg 给用户"
echo "  2) 用户双击后拖拽 WeClone.app 到 Applications"
echo "  3) 首次如被拦截，在 系统设置 > 隐私与安全性 点击“仍要打开”"
