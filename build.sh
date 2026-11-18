#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SpaceStrip"
BUNDLE="$ROOT/build/$APP_NAME.app"

cd "$ROOT"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.png" "$BUNDLE/Contents/Resources/AppIcon.png"

# Ad-hoc signature; fail the build if signing or verification fails.
codesign --force --sign - "$BUNDLE"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"

echo "Built $BUNDLE"
