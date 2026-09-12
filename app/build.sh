#!/bin/bash

# WeClone 构建脚本
# 用法: ./build.sh

set -e

# 切换到脚本所在目录
cd "$(dirname "$0")"

echo "🔨 开始构建 WeClone..."

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查 swift 是否存在
if ! command -v swift &> /dev/null; then
    echo "❌ 错误: 未找到 Swift 编译器"
    echo "   请安装 Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

# 构建项目
echo "📦 正在编译..."
BUILD_PATH="/tmp/WeCloneBuild"
swift build --build-path "$BUILD_PATH" -c release --product WeClone

# 创建 .app 结构
APP_NAME="WeClone.app"
CONTENTS="$APP_NAME/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET_DIR="/tmp/WeClone.iconset"
ICON_PNG="logo.png"
ICON_ICNS="AppIcon.icns"

echo "📁 正在创建 .app 包..."

# 清理旧的构建
rm -rf "$APP_NAME"

# 创建目录结构
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# 复制可执行文件
cp "$BUILD_PATH/arm64-apple-macosx/release/WeClone" "$MACOS/"

# 复制 Info.plist
cp Info.plist "$CONTENTS/"

# 生成图标（优先使用项目根目录 logo.png）
if [ -f "$ICON_PNG" ]; then
    echo "🎨 正在生成应用图标..."
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    sips -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES/$ICON_ICNS"
    rm -rf "$ICONSET_DIR"
elif [ -f "WeClone/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" ]; then
    cp "WeClone/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" "$RESOURCES/$ICON_ICNS"
fi

# 移除隔离属性并签名
echo "🔐 正在签名应用..."
xattr -cr "$APP_NAME" 2>/dev/null || true
codesign --force --deep --sign - "$APP_NAME" 2>/dev/null || true

echo -e "${GREEN}✅ 构建成功!${NC}"
echo ""
echo "📱 应用位置: $(pwd)/$APP_NAME"
echo ""
echo "使用方法:"
echo "  1. 双击 $APP_NAME 启动"
echo "  2. 或拖拽到 Applications 文件夹"
echo ""
echo "⚠️  首次运行可能需要在系统设置中允许:"
echo "   系统设置 > 隐私与安全性 > 开发者 '你的用户名'"
