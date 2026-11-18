#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SpaceStrip"
TARGET="/Applications/$APP_NAME.app"

APP_BUILD="$ROOT/build/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUILD/Contents/MacOS/$APP_NAME"
if [ ! -x "$APP_EXECUTABLE" ] ||
   [ "$ROOT/Package.swift" -nt "$APP_EXECUTABLE" ] ||
   find "$ROOT/Sources" "$ROOT/Resources" -type f -newer "$APP_EXECUTABLE" -print -quit | grep -q .; then
  "$ROOT/build.sh"
fi

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

if [ -d "$TARGET" ]; then
  # Move the old copy aside instead of deleting it.
  mv "$TARGET" "/tmp/$APP_NAME.old.$(date +%s).app"
fi

ditto "$APP_BUILD" "$TARGET"
open "$TARGET"

echo "Installed and started $TARGET"
