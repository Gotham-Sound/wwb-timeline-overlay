#!/bin/bash
# Release build: universal binary, Developer ID signature with hardened runtime, notarization, stapling.
#
#   app/release.sh                 # build, sign, notarize, staple -> build/WWB Overlay.zip
#   app/release.sh --no-notarize   # build and sign only
#
# One-time setup for notarization (stores an app-specific password from appleid.apple.com in your
# keychain; nothing is written to this repo):
#   xcrun notarytool store-credentials wwb-notary --apple-id <your apple id> --team-id LP4782R87F
#
# Override the identity or profile with IDENTITY=... PROFILE=... in the environment.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${IDENTITY:-Developer ID Application: Gotham Sound and Communications, Inc. (LP4782R87F)}"
PROFILE="${PROFILE:-wwb-notary}"
BUILT="build/WWB Overlay.app"
ZIP="build/WWB Overlay.zip"
# Sign a staged copy in a temp dir OUTSIDE this folder: a synced Documents tree (iCloud, Drive) keeps
# re-adding Finder extended attributes to the bundle, and codesign refuses to seal a bundle with them.
STAGE="$(mktemp -d /tmp/wwb-release.XXXXXX)"
APP="$STAGE/WWB Overlay.app"
trap 'rm -rf "$STAGE"' EXIT

app/build.sh --universal
ditto --norsrc --noextattr --noqtn "$BUILT" "$APP"
xattr -cr "$APP"
echo "signing with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
if [ "${1:-}" = "--no-notarize" ]; then echo "signed, not notarized: $ZIP"; exit 0; fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarization profile '$PROFILE' in the keychain. Create it once with:"
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <your apple id> --team-id LP4782R87F"
  echo "then run app/release.sh again. The signed (unnotarized) build is at: $ZIP"
  exit 2
fi
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP"
rm -rf "build/WWB Overlay (notarized).app"; ditto "$APP" "build/WWB Overlay (notarized).app"
echo "notarized and stapled: $ZIP"
