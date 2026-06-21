#!/bin/bash
# Developer launch path: install the runtime payload into the game and launch with injection.
# (Players use the NightCity Console.app launcher instead - this is the from-source dev workflow.)
#
# Steps: build overlay -> stage payload (runtime + deps + overlay) into <game>/red4ext/ -> launch.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME="${CP2077_DIR:-$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077}"
BIN="$GAME/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
RED4="$GAME/red4ext"

[ -f "$BIN" ] || { echo "Game not found at: $GAME  (set CP2077_DIR to override)"; exit 1; }

echo "==> building overlay"
"$ROOT/overlay/build.sh"

echo "==> fetching deps"
"$ROOT/tools/fetch-deps.sh"

echo "==> staging payload into $RED4"
mkdir -p "$RED4"
cp "$ROOT/runtime/red4ext_hooks.js"   "$RED4/red4ext_hooks.js"
cp "$ROOT/runtime/FridaGadget.config" "$RED4/FridaGadget.config"
cp "$ROOT/deps/RED4ext.dylib"         "$RED4/RED4ext.dylib"
cp "$ROOT/deps/FridaGadget.dylib"     "$RED4/FridaGadget.dylib"
OVERLAY="$ROOT/build/libcyberconsole_overlay.dylib"
cp "$ROOT/runtime/cet_catalog.tsv" "$ROOT/build/cet_catalog.tsv"   # the overlay reads the catalog from its own dir
# strip quarantine from anything we just wrote so dyld will load it
xattr -dr com.apple.quarantine "$RED4" "$OVERLAY" 2>/dev/null || true

# Stock Cyberpunk is signed without the JIT entitlements Frida needs, so the game gets
# SIGKILL'd (CODESIGNING, Invalid Page) the instant Frida generates code. Re-sign the binary
# ad-hoc with allow-jit / allow-unsigned-executable-memory. Idempotent; Steam verify reverts it.
if ! codesign -d --entitlements :- "$BIN" 2>/dev/null | grep -q allow-jit; then
  echo "==> re-signing game with JIT entitlements (Frida needs them)"
  ENTS="$(mktemp /tmp/cetmac-ents.XXXXXX.plist)"
  cat > "$ENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-executable-page-protection</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
  find "$GAME/Cyberpunk2077.app" -name '._*' -delete 2>/dev/null   # exFAT AppleDouble sidecars break codesign
  codesign -f -s - --entitlements "$ENTS" "$BIN"
  rm -f "$ENTS"
fi

export DYLD_INSERT_LIBRARIES="$RED4/RED4ext.dylib:$RED4/FridaGadget.dylib:$OVERLAY"
export DYLD_FORCE_FLAT_NAMESPACE=1
export SteamAppId=1091500

cd "$GAME"
echo "==> launching (toggle the console in-game with \` or F1)"
exec "$BIN" "$@"
