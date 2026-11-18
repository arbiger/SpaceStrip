#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/SpaceStrip.app"

if [ ! -x "$APP/Contents/MacOS/SpaceStrip" ] ||
   [ "$ROOT/Package.swift" -nt "$APP/Contents/MacOS/SpaceStrip" ] ||
   find "$ROOT/Sources" "$ROOT/Resources" -type f -newer "$APP/Contents/MacOS/SpaceStrip" -print -quit | grep -q .; then
  "$ROOT/build.sh"
fi

# Quit any running copy so the new build takes over cleanly.
pkill -x SpaceStrip 2>/dev/null || true
open "$APP"
