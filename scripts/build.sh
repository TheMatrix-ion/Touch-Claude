#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$ROOT_DIR/bin"
TARGET_BIN="$BIN_DIR/ClaudeTouchBar"
APP_BUNDLE="$BIN_DIR/Touch Claude.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
BUILD_CACHE="$ROOT_DIR/.build-cache"

mkdir -p "$BIN_DIR"
mkdir -p "$BUILD_CACHE/clang/ModuleCache"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang/ModuleCache"

swiftc \
  -module-name ClaudeTouchBar \
  -o "$TARGET_BIN" \
  "$ROOT_DIR"/Sources/ClaudeTouchBar/*.swift \
  -framework AppKit

chmod +x "$TARGET_BIN"
cp "$TARGET_BIN" "$APP_MACOS/ClaudeTouchBar"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT_DIR/assets/claude-pixel-transparent.png" "$APP_RESOURCES/claude-pixel-transparent.png"
cp "$ROOT_DIR/assets/claude-distressed.png" "$APP_RESOURCES/claude-distressed.png"
cp "$ROOT_DIR/assets/claude-sleeping.png" "$APP_RESOURCES/claude-sleeping.png"
chmod +x "$APP_MACOS/ClaudeTouchBar"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $TARGET_BIN"
echo "Built $APP_BUNDLE"
