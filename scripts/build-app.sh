#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"

swift build -c release --arch x86_64 --arch arm64
BIN_DIR="$(swift build -c release --arch x86_64 --arch arm64 --show-bin-path)"
APP_DIR="$PROJECT_ROOT/build/CanonTalk Native.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/CanonTalkNative" "$CONTENTS_DIR/MacOS/CanonTalkNative"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
