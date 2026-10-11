#!/bin/bash
# Build "WWB Overlay.app" into build/ with swiftc. Needs Xcode or the command line tools.
#   app/build.sh            # arm64 build, ad-hoc signed
#   app/build.sh --run      # build, then launch
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/WWB Overlay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
cp player.html tline.py shw.py render.py "$APP/Contents/Resources/"
[ -f app/AppIcon.icns ] && cp app/AppIcon.icns "$APP/Contents/Resources/" || true
echo "compiling…"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers \
  app/main.swift -o "$APP/Contents/MacOS/WWB Overlay"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(ad-hoc codesign skipped)"
echo "built $APP"
if [ "${1:-}" = "--run" ]; then open "$APP"; fi
