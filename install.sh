#!/bin/bash
# 编译 + 安装到 ~/Applications + 安装 Python 工具 + 重新注册 + 启动
# 改完代码后跑这个，一步到位。
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="RestReminder.app"
DEST="$HOME/Applications/$APP_NAME"
SUPPORT="$HOME/Library/Application Support/RestReminder"
LOGS="$HOME/Library/Logs/RestReminder"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "==> 1/6 编译"
"$DIR/build.sh"

echo "==> 2/6 停止旧实例"
killall RestReminder 2>/dev/null || true
sleep 1

echo "==> 3/6 安装到 $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$DIR/$APP_NAME" "$HOME/Applications/"

echo "==> 4/6 安装播报工具到 $SUPPORT/tools"
mkdir -p "$SUPPORT/tools" "$SUPPORT/stats" "$SUPPORT/screentime" "$SUPPORT/reports" "$LOGS"
cp "$DIR/tools/"*.py "$SUPPORT/tools/"

# 迁移：旧版本把日志写在源码目录，新版统一到 ~/Library/Logs
if [ -f "$DIR/debug.log" ] && [ ! -f "$LOGS/debug.log" ]; then
    mv "$DIR/debug.log" "$LOGS/debug.log"
    echo "    已把历史日志迁移到 $LOGS/debug.log"
fi

echo "==> 5/6 重新签名并向 LaunchServices 注册"
xattr -cr "$DEST"
codesign --force --deep --sign - "$DEST"
"$LSR" -f "$DEST"

echo "==> 6/6 启动"
open "$DEST"
sleep 3

if pgrep -x RestReminder >/dev/null; then
    echo
    echo "完成！图标应出现在屏幕右上角菜单栏。"
    echo "日志：$LOGS/debug.log"
    echo "数据：$SUPPORT"
else
    echo
    echo "启动失败，请检查日志：$LOGS/debug.log"
    exit 1
fi
