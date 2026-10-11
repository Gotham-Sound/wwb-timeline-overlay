#!/bin/bash
# Build "WWB Overlay.app" into build/ with swiftc. Needs Xcode or the command line tools.
#   app/build.sh                 # arm64 build, ad-hoc signed (fast, for development)
#   app/build.sh --universal     # arm64 + x86_64 slices (used by app/release.sh)
#   app/build.sh --run           # build, then launch
set -euo pipefail
cd "$(dirname "$0")/.."
UNIVERSAL=0; RUN=0
for a in "$@"; do case "$a" in --universal) UNIVERSAL=1;; --run) RUN=1;; esac; done
APP="build/WWB Overlay.app"
BIN="$APP/Contents/MacOS/WWB Overlay"
SRC="app/main.swift app/Timeline.swift app/Panel.swift app/Render.swift"
FLAGS="-O -swift-version 5 -framework Cocoa -framework WebKit -framework AVFoundation -framework VideoToolbox -framework UniformTypeIdentifiers"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
cp player.html "$APP/Contents/Resources/"
[ -f app/AppIcon.icns ] && cp app/AppIcon.icns "$APP/Contents/Resources/" || true
if [ "$UNIVERSAL" = 1 ]; then
  echo "compiling arm64…";  swiftc $FLAGS -target arm64-apple-macosx13.0  $SRC -o build/wwb-arm64
  echo "compiling x86_64…"; swiftc $FLAGS -target x86_64-apple-macosx13.0 $SRC -o build/wwb-x86_64
  lipo -create build/wwb-arm64 build/wwb-x86_64 -output "$BIN"
  rm -f build/wwb-arm64 build/wwb-x86_64
else
  echo "compiling arm64…"; swiftc $FLAGS -target arm64-apple-macosx13.0 $SRC -o "$BIN"
fi
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP ($(lipo -archs "$BIN"))"
if [ "$RUN" = 1 ]; then open "$APP"; fi
