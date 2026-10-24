#!/bin/bash
# Sign (Developer ID + hardened runtime), notarize, and package "NightCity Console.app" into a .dmg and a .zip.
# YOU run this with YOUR Apple Developer ID - it never asks the assistant for credentials.
#
# One-time setup (stores your notary credentials in the keychain):
#   xcrun notarytool store-credentials cyberconsole-notary \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Then run:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="cyberconsole-notary" \
#   ./tools/sign-notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/NightCity Console.app"
BUILD_APP=1
SIGN_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --existing-app)
      [ "$#" -ge 2 ] || { echo "--existing-app requires a path" >&2; exit 1; }
      APP="$2"; BUILD_APP=0; shift 2 ;;
    --sign-only) SIGN_ONLY=1; shift ;;
    *) echo "Usage: $0 [--existing-app path] [--sign-only]" >&2; exit 1 ;;
  esac
done
DMG="dist/NightCity-Console-for-Mac.dmg"
ZIP="dist/NightCity-Console-for-Mac.zip"          # distributable zip (made from the stapled app)
SUBZIP="dist/_notarize.zip"     # temporary zip used only for the notarization upload

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to 'Developer ID Application: NAME (TEAMID)'}"
if [ "$SIGN_ONLY" = 0 ]; then
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"
fi

if [ "$BUILD_APP" = 1 ]; then
  echo "==> building release from explicit inputs, then signing with Developer ID"
  NIGHTCITY_BUILD_MODE=release ./launcher/build-app.sh
else
  echo "==> signing the existing app without rebuilding or fetching dependencies"
fi
python3 tools/verify-release-bundle.py "$APP"

# The bundled nctool is a self-contained .NET helper that JITs. Under hardened runtime CoreCLR SIGKILLs the
# instant it writes executable memory unless these entitlements are present (validated locally: JIT + a full
# Kraken rawrepack run clean with them). Entitlements apply to the apphost EXECUTABLE, not the dylibs.
NCTOOL_ENTS="$(mktemp -t nctool-ents)"
trap 'rm -f "$NCTOOL_ENTS"' EXIT
cat > "$NCTOOL_ENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
NCTOOL_EXE="$APP/Contents/Resources/nctool/nctool"

# Sign every nested Mach-O inside-out with hardened runtime + secure timestamp (required for notarization).
# This is ALL Mach-O, not just *.dylib: the nctool bundle also ships helper executables (createdump) and the
# .NET runtime dylibs. The nctool apphost is skipped here and signed next, with the JIT entitlements.
find "$APP/Contents/Resources" -type f -print0 | while IFS= read -r -d '' f; do
  [ "$f" = "$NCTOOL_EXE" ] && continue
  if file "$f" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
  fi
done
codesign --force --options runtime --timestamp --entitlements "$NCTOOL_ENTS" --sign "$SIGN_IDENTITY" "$NCTOOL_EXE"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$SIGN_ONLY" = 1 ]; then
  echo "Signed locally: $APP (no notarization upload or packaging requested)."
  exit 0
fi

echo "==> notarizing the app"
mkdir -p dist
rm -f "$SUBZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBZIP"
xcrun notarytool submit "$SUBZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"          # staple the ticket onto the app on disk
rm -f "$SUBZIP"

echo "==> packaging the stapled app (.zip + .dmg)"
# 1) distributable .zip: the app inside is stapled, so it passes Gatekeeper offline
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
# 2) .dmg with an /Applications shortcut + drag-here layout, then notarize + staple
#    the dmg itself so the downloaded image also passes Gatekeeper offline.
rm -f "$DMG"
VOL="NightCity Console"; STAGE="build/dmg"; APPNAME="$(basename "$APP")"
# This path creates directly from a staging folder and does not touch existing mounted volumes.
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APPNAME"
ln -s /Applications "$STAGE/Applications"            # the drag-here shortcut
# Create the compressed .dmg DIRECTLY from the staging folder - no attach/Finder-style/convert dance (that was
# flaky on macOS 27's deprecated hdiutil and accumulated stale /Volumes mounts). Reliable; the Applications
# shortcut conveys "drag the app here" (the fancy icon layout is dropped for a build that always succeeds).
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "done (signed, notarized, stapled - no Gatekeeper warnings):"
echo "  $DMG"
echo "  $ZIP"
