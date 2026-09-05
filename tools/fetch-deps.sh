#!/bin/bash
# Populate deps/ without overwriting existing binaries or modifying a game install.
# Import a verified release ZIP explicitly, or fill gaps from a local Steam/GOG install.
# See docs/DEPENDENCIES.md for provenance and optional TweakXL limitations.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP=""
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--from-zip" ]; then
    echo "Usage: $0 [--from-zip /path/to/NightCity-Console-for-Mac.zip]" >&2
    exit 1
  fi
  ZIP="$2"
fi

mkdir -p deps
REQUIRED=(RED4ext.dylib FridaGadget.dylib TweakXL.dylib ArchiveXL.dylib config.ini cyberpunk2077_addresses.json)
PLUGIN_LIBS=(libspdlog.1.17.dylib libfmt.12.dylib libyaml-cpp.0.9.dylib)

copy_if_missing() {
  local src="$1" name="$2"
  if [ ! -f "deps/$name" ] && [ -f "$src" ]; then
    mkdir -p "$(dirname "deps/$name")"
    cp "$src" "deps/$name"
    echo "  got $name from $src"
  fi
}

echo "Collecting runtime deps into deps/ ..."
if [ -n "$ZIP" ]; then
  [ -f "$ZIP" ] || { echo "Release ZIP not found: $ZIP" >&2; exit 1; }
  # GitHub release asset digest for v1.5.0-beta.2, verified against our source ZIP.
  EXPECTED="19f83a8546819cf09091bb836e585940eaed23a87447009184249d5d2f031151"
  ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "ZIP checksum mismatch: expected the official v1.5.0-beta.2 release. See docs/DEPENDENCIES.md." >&2
    exit 1
  fi
  TEMP_FILE=""
  trap 'if [ -n "$TEMP_FILE" ]; then rm -f -- "$TEMP_FILE"; fi' EXIT
  IMPORTS=("${REQUIRED[@]}")
  for plugin in TweakXL ArchiveXL; do
    for lib in "${PLUGIN_LIBS[@]}"; do
      IMPORTS+=("plugins/$plugin/$lib")
    done
  done
  for name in "${IMPORTS[@]}"; do
    if [ -f "deps/$name" ]; then
      echo "  keeping existing $name"
      continue
    fi
    entry="NightCity Console.app/Contents/Resources/$name"
    case "$name" in
      TweakXL.dylib|ArchiveXL.dylib) entry="NightCity Console.app/Contents/Resources/plugins/${name%.dylib}/$name" ;;
    esac
    # Stream only named entries; do not unpack or execute the application.
    TEMP_FILE=$(mktemp "deps/.import.XXXXXX")
    unzip -p "$ZIP" "$entry" > "$TEMP_FILE"
    [ -s "$TEMP_FILE" ] || { echo "Empty dependency in ZIP: $entry" >&2; exit 1; }
    chmod 644 "$TEMP_FILE"
    mkdir -p "$(dirname "deps/$name")"
    mv "$TEMP_FILE" "deps/$name"
    TEMP_FILE=""
    echo "  imported $name from verified v1.5.0-beta.2 ZIP"
  done
else
  if [ -n "${CP2077_DIR:-}" ]; then
    GAME_DIRS=("$CP2077_DIR")
  else
    GAME_DIRS=("$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077" "/Applications/Cyberpunk 2077")
  fi
  for game_dir in "${GAME_DIRS[@]}"; do
    copy_if_missing "$game_dir/red4ext/RED4ext.dylib" RED4ext.dylib
    copy_if_missing "$game_dir/red4ext/FridaGadget.dylib" FridaGadget.dylib
    copy_if_missing "$game_dir/red4ext/plugins/TweakXL/TweakXL.dylib" TweakXL.dylib
    copy_if_missing "$game_dir/red4ext/plugins/ArchiveXL/ArchiveXL.dylib" ArchiveXL.dylib
    copy_if_missing "$game_dir/red4ext/config.ini" config.ini
    copy_if_missing "$game_dir/red4ext/cyberpunk2077_addresses.json" cyberpunk2077_addresses.json
    for plugin in TweakXL ArchiveXL; do
      for lib in "${PLUGIN_LIBS[@]}"; do
        copy_if_missing "$game_dir/red4ext/plugins/$plugin/$lib" "plugins/$plugin/$lib"
      done
    done
    copy_if_missing "$game_dir/engine/tools/scc" scc
    copy_if_missing "$game_dir/engine/tools/libscc_lib.dylib" libscc_lib.dylib
  done
fi

# redscript compiler (jac3km4/redscript macOS arm64 release) - bundled so the app can compile .reds
# script mods into r6/cache/final.redscripts before every launch. Canonical copy lives in the
# cybermodman repo (extracted redscript-v0.5.31-macos.zip); fall back to the game's deployed copy.
SCC_SRC="${SCC_SRC:-$HOME/cybermodman/redscript/engine/tools}"
copy_if_missing "$SCC_SRC/scc" scc
copy_if_missing "$SCC_SRC/libscc_lib.dylib" libscc_lib.dylib

MISSING=0
for name in "${REQUIRED[@]}"; do
  if [ ! -s "deps/$name" ]; then
    echo "  MISSING or empty: deps/$name"
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  echo "Download the official v1.5.0-beta.2 NightCity-Console-for-Mac.zip, then run:"
  echo "  ./tools/fetch-deps.sh --from-zip /path/to/NightCity-Console-for-Mac.zip"
  echo "Source, checksums, and dependency requirements: docs/DEPENDENCIES.md"
  exit 1
fi
if [ ! -s deps/scc ] || [ ! -s deps/libscc_lib.dylib ]; then
  echo "  [warn] Optional redscript compiler missing: provide scc + libscc_lib.dylib via SCC_SRC for Steam script mods."
fi
echo "deps ready (required files present; runtime/plugin compatibility is not checked)."
