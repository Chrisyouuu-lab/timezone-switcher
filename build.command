#!/bin/bash
# 把源码编译成「时区切换.app」并安装到 ~/Applications。
set -e
cd "$(dirname "$0")"

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
WORK="$(mktemp -d)"
APP="$WORK/时区切换.app"
ARCH="$(uname -m)"
export CLANG_MODULE_CACHE_PATH="$WORK/mc"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "没有找到 Swift 编译器，请先运行：xcode-select --install"
    exit 1
fi

# 默认 SDK 可能和编译器版本不匹配，所以依次尝试已安装的 SDK，用第一个能编译通过的。
compile() { # 参数：SDK 路径
    swiftc -O -parse-as-library -sdk "$1" -target "$ARCH-apple-macos13" -module-cache-path "$WORK/mc" \
        main.swift -o "$APP/Contents/MacOS/TimeZoneSwitcher" 2>"$WORK/error.log"
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK/AppIcon.iconset"
SDK_DIR="$(dirname "$(xcrun --show-sdk-path)")"
SDK=""
for candidate in $(ls -d "$SDK_DIR"/MacOSX[0-9]*.sdk | sort -rV); do
    echo "尝试 SDK：$(basename "$candidate")"
    if compile "$candidate"; then
        SDK="$candidate"
        break
    fi
done
if [ -z "$SDK" ]; then
    echo "编译失败，最后一次的错误信息："
    tail -20 "$WORK/error.log"
    exit 1
fi

swiftc -sdk "$SDK" -target "$ARCH-apple-macos13" -module-cache-path "$WORK/mc" icon.swift -o "$WORK/icon"
"$WORK/icon" "$WORK/icon.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"

mkdir -p "$INSTALL_DIR"
cp -R "$APP" "$INSTALL_DIR/"
codesign --force --deep -s - "$INSTALL_DIR/时区切换.app"
codesign --verify "$INSTALL_DIR/时区切换.app"
echo "完成，已安装到：$INSTALL_DIR/时区切换.app"
