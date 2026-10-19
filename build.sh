#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="RestReminder.app"
APP_DIR="$DIR/$APP_NAME"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
CACHE_DIR="$DIR/cache"

echo "==> Building $APP_NAME..."

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$CACHE_DIR"

cp "$DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

swiftc -O \
    -module-cache-path "$CACHE_DIR" \
    -target arm64-apple-macosx13.0 \
    -framework IOKit \
    -framework AVFoundation \
    -o "$MACOS_DIR/RestReminder" \
    "$DIR/Sources/"*.swift

# 循环影片是可选的：有就拷进 bundle，没有就跳过 —— app 会自动退回「真熄屏」行为，
# 不会因为缺资源起不来。
if [ -f "$DIR/assets/rest-loop.mp4" ]; then
    cp "$DIR/assets/rest-loop.mp4" "$RESOURCES_DIR/rest-loop.mp4"
    echo "==> 已打包循环影片 rest-loop.mp4 ($(du -h "$DIR/assets/rest-loop.mp4" | cut -f1))"
else
    rm -f "$RESOURCES_DIR/rest-loop.mp4"
    echo "==> 未找到 assets/rest-loop.mp4 —— 本次构建不含循环影片，将退回真熄屏"
fi

echo "==> Signing $APP_NAME..."
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Build complete: $APP_DIR"
