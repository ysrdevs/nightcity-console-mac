#!/bin/bash
# Populate deps/ with the third-party runtime binaries CyberConsole injects.
# These are NOT committed to git (FridaGadget is ~57 MB). They are bundled into the
# release .dmg at package time.
#
# Primary path: copy from a known-good local Cyberpunk 2077 install (if present).
# Otherwise, download from upstream (see URLs below) and place the files in deps/.
set -euo pipefail
cd "$(dirname "$0")/.."

# Release inputs are explicit and isolated from the developer deps/ directory and live game.
if [ "${NIGHTCITY_BUILD_MODE:-development}" = "release" ]; then
  : "${NIGHTCITY_BASELINE_ZIP:?release requires the public v1.5.0 ZIP}"
  : "${NATIVE25_DIR:?release requires a built native 2.5 red4ext tree}"
  : "${NCTOOL_PUBLISH_DIR:?release requires a self-contained osx-arm64 nctool publish directory}"
  CACHE="build/release-downloads"
  mkdir -p "$CACHE"
  download_checked() {
    local target="$1" expected="$2" url="$3"
    if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$expected" ]; then return; fi
    local pending
    pending="$(mktemp "$CACHE/download.XXXXXX")"
    if ! curl -fSL --retry 2 -o "$pending" "$url" || [ "$(shasum -a 256 "$pending" | cut -d' ' -f1)" != "$expected" ]; then
      rm -f "$pending"
      echo "Release dependency download/checksum failed: $url" >&2
      return 1
    fi
    mv "$pending" "$target"
  }
  download_checked "$CACHE/redscript-v0.5.32-macos.zip" \
    b9df6cc0144d786dff9590eb6db913d20744055ab694e52fc8c4584eaee39a8a \
    https://github.com/jac3km4/redscript/releases/download/v0.5.32/redscript-v0.5.32-macos.zip
  download_checked "$CACHE/ArchiveXL-1.27.4.zip" \
    6c638dc1108a565ff4806835a17f704cbb2ab2afeb8ccf700080797c3f70591c \
    https://github.com/psiberx/cp2077-archive-xl/releases/download/v1.27.4/ArchiveXL-1.27.4.zip
  python3 tools/prepare-release-deps.py \
    --baseline "$NIGHTCITY_BASELINE_ZIP" --native25 "$NATIVE25_DIR" --nctool "$NCTOOL_PUBLISH_DIR" \
    --redscript "$CACHE/redscript-v0.5.32-macos.zip" --archivexl "$CACHE/ArchiveXL-1.27.4.zip" \
    --config runtime/native25/config.ini --output build/release-deps
  exit 0
fi
if [ "${NIGHTCITY_BUILD_MODE:-development}" != "development" ]; then
  echo "Unknown NIGHTCITY_BUILD_MODE; use development or release." >&2
  exit 1
fi
mkdir -p deps
GAME="${CP2077_DIR:-$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077}/red4ext"

copy_if() { if [ -f "$1" ]; then cp "$1" "deps/$(basename "$1")" && echo "  got $(basename "$1")"; fi; }   # a missing source must not trip set -e

echo "Fetching runtime deps into deps/ ..."
if [ -d "$GAME" ]; then
  echo "Found local install - copying from: $GAME"
  copy_if "$GAME/RED4ext.dylib"
  copy_if "$GAME/FridaGadget.dylib"
  copy_if "$GAME/plugins/TweakXL/TweakXL.dylib"       # TweakXL creator engine (RED4ext plugin)
  copy_if "$GAME/plugins/ArchiveXL/ArchiveXL.dylib"   # ArchiveXL content engine (RED4ext plugin) - REQUIRED for mods
  copy_if "$GAME/config.ini"                          # RED4ext config ([plugins] enabled=true) - without it no plugins load
  copy_if "$GAME/cyberpunk2077_addresses.json"        # RED4ext AddressLib
fi

# redscript compiler (jac3km4/redscript macOS arm64 release) - bundled so the app can compile .reds
# script mods into r6/cache/final.redscripts before every launch. Pinned to v0.5.32: 0.5.31 cannot read
# the script bundle of game 2.5; 0.5.32 only adds reading the 2.5 header, so 2.3.1 bundles are unchanged.
RS_VER=v0.5.32
RS_ZIP_SHA=b9df6cc0144d786dff9590eb6db913d20744055ab694e52fc8c4584eaee39a8a
SCC_SHA=a3b9f6216c66ff6674332e52ce828f3d9930f7c7f210731eb1910ac6d2bf95a3
if [ "$(shasum -a 256 deps/scc 2>/dev/null | cut -d' ' -f1)" != "$SCC_SHA" ]; then
  TMP="$(mktemp -d)"
  if curl -fsSL -o "$TMP/rs.zip" "https://github.com/jac3km4/redscript/releases/download/$RS_VER/redscript-$RS_VER-macos.zip" \
     && [ "$(shasum -a 256 "$TMP/rs.zip" | cut -d' ' -f1)" = "$RS_ZIP_SHA" ]; then
    unzip -qo "$TMP/rs.zip" -d "$TMP/x"
    cp "$TMP/x/engine/tools/scc" "$TMP/x/engine/tools/libscc_lib.dylib" deps/
    echo "  got redscript $RS_VER (scc + libscc_lib.dylib)"
  else
    echo "  [warn] could not download redscript $RS_VER (or its checksum did not match)"
  fi
  rm -rf "$TMP"
fi

# Native macOS RED4ext + TweakXL + ArchiveXL for game 2.5 (optional). NATIVE25_DIR is a red4ext folder laid
# out as the game uses it: RED4ext.dylib, bin/red4ext_plugin_check, bin/x64/cyberpunk2077_addresses.json and
# plugins/<Name>/{<Name>.dylib, Scripts/, Data/}. Without it the app installs only the console on 2.5.
# Sources: branch game-2.5 of fentz26/RED4ext-macos, RED4ext.SDK-macos, cp2077-tweak-xl-macos, cp2077-archive-xl-macos.
if [ -n "${NATIVE25_DIR:-}" ]; then
  [ -f "$NATIVE25_DIR/RED4ext.dylib" ] || { echo "  NATIVE25_DIR has no RED4ext.dylib: $NATIVE25_DIR"; exit 1; }
  rm -rf deps/native25
  mkdir -p deps/native25/bin/x64 deps/native25/plugins
  cp "$NATIVE25_DIR/RED4ext.dylib" deps/native25/
  cp "$NATIVE25_DIR/bin/red4ext_plugin_check" deps/native25/bin/
  cp "$NATIVE25_DIR/bin/x64/cyberpunk2077_addresses.json" deps/native25/bin/x64/
  for p in TweakXL ArchiveXL Codeware; do
    mkdir -p "deps/native25/plugins/$p"
    cp "$NATIVE25_DIR/plugins/$p/$p.dylib" "deps/native25/plugins/$p/"
    for d in Scripts Data Bundle; do
      [ -d "$NATIVE25_DIR/plugins/$p/$d" ] && rsync -a --exclude '._*' "$NATIVE25_DIR/plugins/$p/$d" "deps/native25/plugins/$p/"
    done
    for f in LICENSE THIRD_PARTY_LICENSES; do
      [ ! -f "$NATIVE25_DIR/plugins/$p/$f" ] || cp "$NATIVE25_DIR/plugins/$p/$f" "deps/native25/plugins/$p/"
    done
  done
  # ArchiveXL's resource bundle (ArchiveXL.archive + the .xl configs) from the official release matching the plugin
  # version; the archive format is the same on macOS. Built by its author from bundle/source with WolvenKit.
  AXL_VER=1.27.4
  AXL_ZIP_SHA=6c638dc1108a565ff4806835a17f704cbb2ab2afeb8ccf700080797c3f70591c
  if [ ! -f deps/native25/plugins/ArchiveXL/Bundle/ArchiveXL.archive ]; then
  TMP="$(mktemp -d)"
  if curl -fsSL -o "$TMP/axl.zip" "https://github.com/psiberx/cp2077-archive-xl/releases/download/v$AXL_VER/ArchiveXL-$AXL_VER.zip" \
     && [ "$(shasum -a 256 "$TMP/axl.zip" | cut -d' ' -f1)" = "$AXL_ZIP_SHA" ]; then
    unzip -qo "$TMP/axl.zip" -d "$TMP/x"
    rsync -a "$TMP/x/red4ext/plugins/ArchiveXL/Bundle" "$TMP/x/red4ext/plugins/ArchiveXL/LICENSE" \
      "$TMP/x/red4ext/plugins/ArchiveXL/THIRD_PARTY_LICENSES" deps/native25/plugins/ArchiveXL/
    echo "  got the ArchiveXL $AXL_VER bundle"
  else
    echo "  [warn] could not download ArchiveXL $AXL_VER (or its checksum did not match) - no ArchiveXL bundle"
  fi
  rm -rf "$TMP"
  fi
  echo "  got native 2.5 payload ($(find deps/native25 -type f | wc -l | tr -d ' ') files)"
fi

MISSING=0
for f in RED4ext.dylib FridaGadget.dylib TweakXL.dylib ArchiveXL.dylib config.ini scc libscc_lib.dylib; do
  [ -f "deps/$f" ] || { echo "  MISSING: deps/$f"; MISSING=1; }
done

if [ "$MISSING" = "1" ]; then
  cat <<'EOF'

Some deps are missing. Obtain them from upstream and drop into deps/:
  - FridaGadget.dylib : frida-gadget (macOS arm64) from https://github.com/frida/frida/releases
                        (download frida-gadget-<ver>-macos-arm64.dylib.gz, gunzip, rename to FridaGadget.dylib)
  - RED4ext.dylib     : RED4ext macOS port release
  - (optional) the native 2.5 payload: set NATIVE25_DIR to a red4ext folder with the 2.5 builds (see above)
Then re-run this script (or just place the files and continue).
EOF
  exit 1
fi
echo "deps ready."
