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
SKIP_SIGNING=0
OUTPUT_DIR="dist"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --existing-app)
      [ "$#" -ge 2 ] || { echo "--existing-app requires a path" >&2; exit 1; }
      APP="$2"; BUILD_APP=0; shift 2 ;;
    --sign-only) SIGN_ONLY=1; shift ;;
    --skip-signing) SKIP_SIGNING=1; shift ;;
    --output-dir)
      [ "$#" -ge 2 ] || { echo "--output-dir requires a path" >&2; exit 1; }
      OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 [--existing-app path] [--sign-only | --skip-signing] [--output-dir path]" >&2; exit 1 ;;
  esac
done
[ "$SKIP_SIGNING" = 0 ] || { [ "$BUILD_APP" = 0 ] && [ "$SIGN_ONLY" = 0 ]; } \
  || { echo "--skip-signing requires --existing-app and cannot use --sign-only" >&2; exit 1; }
# Use one spelling for verification, find output and the exact legacy skip list.
APP="$(python3 - "$APP" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve())
PY
)"
DMG="$OUTPUT_DIR/NightCity-Console-for-Mac.dmg"
ZIP="$OUTPUT_DIR/NightCity-Console-for-Mac.zip"  # distributable zip (made from the stapled app)
SUBZIP="$OUTPUT_DIR/_notarize.zip"              # submission copy of the tested app

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to 'Developer ID Application: NAME (TEAMID)'}"
if [ "$SIGN_ONLY" = 0 ]; then
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"
fi

if [ "$BUILD_APP" = 1 ]; then
  echo "==> building release from explicit inputs, then signing with Developer ID"
  NIGHTCITY_BUILD_MODE=release ./launcher/build-app.sh
else
  echo "==> using the existing app without rebuilding or fetching dependencies"
fi
python3 tools/verify-release-bundle.py "$APP"

if [ "$SKIP_SIGNING" = 1 ]; then
  codesign --verify --deep --strict "$APP"
  SIGNED_INFO="$(codesign -d --verbose=4 "$APP" 2>&1)"
  printf '%s\n' "$SIGNED_INFO" | grep -Fq "Authority=$SIGN_IDENTITY" \
    || { echo "The existing app does not match SIGN_IDENTITY" >&2; exit 1; }
  printf '%s\n' "$SIGNED_INFO" | grep -q 'flags=.*runtime' \
    || { echo "The existing app lacks hardened runtime" >&2; exit 1; }
  echo "==> preserving the tested Developer ID signatures"
else

# The bundled nctool is a self-contained .NET helper that JITs. Under hardened runtime CoreCLR SIGKILLs the
# instant it writes executable memory unless these entitlements are present (validated locally: JIT + a full
# Kraken rawrepack run clean with them). Entitlements apply to the apphost EXECUTABLE, not the dylibs.
SIGN_WORK="$(mktemp -d -t nightcity-signing)"
NCTOOL_ENTS="$SIGN_WORK/nctool-entitlements.plist"
PRESERVED_LEGACY="$SIGN_WORK/preserved-legacy.txt"
trap 'rm -rf "$SIGN_WORK"' EXIT
# These are already signed by the same Developer ID. Preserve the exact pinned
# 2.3.1 compatibility files, including their original signatures and deployment
# targets. The 2.5 installer selects its separate native25 runtime instead.
python3 - "$APP" "$PRESERVED_LEGACY" <<'PY'
from pathlib import Path
import runpy
import sys
helpers = runpy.run_path('tools/prepare-release-deps.py')
resources = Path(sys.argv[1]) / 'Contents/Resources'
helpers['validate_legacy_baseline'](resources)
manifest = helpers['legacy_baseline']()
Path(sys.argv[2]).write_text(''.join(str(resources / path) + '\n' for path in sorted(manifest['files'])))
PY
while IFS= read -r legacy; do
  codesign --verify --strict "$legacy"
  LEGACY_INFO="$(codesign -d --verbose=4 "$legacy" 2>&1)"
  printf '%s\n' "$LEGACY_INFO" | grep -Fq "Authority=$SIGN_IDENTITY" \
    || { echo "Pinned legacy signer does not match SIGN_IDENTITY: $legacy" >&2; exit 1; }
  printf '%s\n' "$LEGACY_INFO" | grep -q 'flags=.*runtime' \
    || { echo "Pinned legacy file lacks hardened runtime: $legacy" >&2; exit 1; }
  printf '%s\n' "$LEGACY_INFO" | grep -q '^Timestamp=' \
    || { echo "Pinned legacy file lacks secure timestamp: $legacy" >&2; exit 1; }
done < "$PRESERVED_LEGACY"
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
  if grep -Fqx -- "$f" "$PRESERVED_LEGACY"; then continue; fi
  if file "$f" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
  fi
done
codesign --force --options runtime --timestamp --entitlements "$NCTOOL_ENTS" --sign "$SIGN_IDENTITY" "$NCTOOL_EXE"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
python3 tools/verify-release-bundle.py "$APP"
fi
if [ "$SIGN_ONLY" = 1 ]; then
  echo "Signed locally: $APP (no notarization upload or packaging requested)."
  exit 0
fi

echo "==> notarizing the app"
mkdir -p "$OUTPUT_DIR"

notarize() {
  local artifact="$1" kind="$2" receipt="$OUTPUT_DIR/$2-notarization.json" submission_id
  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$receipt"
  submission_id="$(python3 - "$receipt" <<'PY'
import json, sys, uuid
record = json.load(open(sys.argv[1]))
print(uuid.UUID(record['id']))
PY
)"
  xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$OUTPUT_DIR/$kind-notarization-log.json"
  python3 - "$receipt" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
if record.get('status') != 'Accepted':
    raise SystemExit('Apple notarization was not accepted: ' + str(record.get('status')))
print('Apple accepted submission ' + record['id'])
PY
}

rm -f "$SUBZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBZIP"
notarize "$SUBZIP" app
xcrun stapler staple "$APP"          # staple the ticket onto the app on disk
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
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
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
hdiutil verify "$DMG" >/dev/null
(cd "$OUTPUT_DIR" && shasum -a 256 NightCity-Console-for-Mac.dmg NightCity-Console-for-Mac.zip) > "$OUTPUT_DIR/SHA256SUMS"

echo "done (signed, notarized, stapled - no Gatekeeper warnings):"
echo "  $DMG"
echo "  $ZIP"
