#!/bin/bash
# Build "NightCity Console.app" (ad-hoc signed, for dev/testing).
# Bundles the runtime payload into Contents/Resources so the app can install it into the game.
# Release signing + notarization + .dmg is a separate step: tools/sign-notarize.sh
set -e
cd "$(dirname "$0")/.."   # repo root
APP="build/NightCity Console.app"

echo "==> overlay + deps"
./overlay/build.sh
./tools/fetch-deps.sh

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp launcher/Info.plist "$APP/Contents/Info.plist"

echo "==> compiling launcher"
MODULE_CACHE="$PWD/build/module-cache"
mkdir -p "$MODULE_CACHE/clang" "$MODULE_CACHE/swift"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE/clang" swiftc \
  -module-cache-path "$MODULE_CACHE/swift" \
  -O -parse-as-library -target arm64-apple-macos12 \
  -o "$APP/Contents/MacOS/NightCityConsole" \
  launcher/Sources/*.swift

echo "==> bundling payload into Resources"
cp runtime/red4ext_hooks.js runtime/red4ext_hooks_gog.js \
   runtime/FridaGadget.config runtime/cet_catalog.tsv "$APP/Contents/Resources/"
cp deps/RED4ext.dylib deps/FridaGadget.dylib            "$APP/Contents/Resources/"
cp build/libcyberconsole_overlay.dylib                  "$APP/Contents/Resources/"
# CyberModMan creator payload: seed the names file + RED4ext's config.ini (enables plugin loading) + AddressLib.
cp runtime/cybermodman/cybermodman_names.json "$APP/Contents/Resources/"
cp deps/config.ini deps/cyberpunk2077_addresses.json "$APP/Contents/Resources/" 2>/dev/null \
  || echo "  [warn] config.ini / cyberpunk2077_addresses.json missing from deps/ (re-run tools/fetch-deps.sh)"
# Vendor the RED4ext plugins (TweakXL + ArchiveXL) so they ship SELF-CONTAINED: both link against Homebrew
# spdlog/fmt/yaml-cpp (/opt/homebrew/...), which do not exist on a user's Mac -> the plugins fail to load and
# the cybermodman_tweakReload/archiveReload exports go missing. vendor-plugin.sh copies each plugin + those 3
# dylibs into its plugin folder with @loader_path refs. The launcher deploys Resources/plugins -> red4ext/plugins.
mkdir -p "$APP/Contents/Resources/plugins"
bash tools/vendor-plugin.sh deps/TweakXL.dylib   "$APP/Contents/Resources/plugins/TweakXL"
bash tools/vendor-plugin.sh deps/ArchiveXL.dylib "$APP/Contents/Resources/plugins/ArchiveXL"

echo "==> bundling nctool mod engine (drag-drop installer)"
# nctool is the cp2077 archive/mod engine. Publish it self-contained (multi-file: the single-file variant
# tucks libkraken into a lib/ subfolder the runtime can't find) so the shipped app needs no dotnet; the
# launcher shells out to Resources/nctool/nctool. Set NCTOOL_SRC to override the location.
NCTOOL_SRC="${NCTOOL_SRC:-$HOME/cp2077/_tools/nctool}"
if [ -d "$NCTOOL_SRC" ]; then
  DOTNET="$(command -v dotnet || echo "$HOME/.dotnet/dotnet")"
  rm -rf build/nctool-pub
  "$DOTNET" publish "$NCTOOL_SRC" -c Release -r osx-arm64 --self-contained true \
    -p:PublishSingleFile=false -o build/nctool-pub >/dev/null
  rm -f build/nctool-pub/*.pdb
  # Bundle the whole self-contained publish (exe + .NET runtime + libkraken.dylib) into Resources/nctool/.
  rm -rf "$APP/Contents/Resources/nctool"
  ditto build/nctool-pub "$APP/Contents/Resources/nctool"
  echo "  bundled nctool self-contained ($(ls "$APP/Contents/Resources/nctool" | wc -l | tr -d ' ') files)"
else
  echo "  [warn] nctool source not found at $NCTOOL_SRC - the mod installer will show 'helper missing'."
  echo "         Set NCTOOL_SRC=/path/to/cp2077/_tools/nctool and rebuild to enable drag-drop mod install."
fi

echo "==> bundling redscript compiler (scc)"
# jac3km4/redscript's scc (arm64) + its dylib. The launcher deploys them to <game>/engine/tools/ and
# runs scc -compile before every launch so drag-dropped .reds script mods just work. Rust AOT binary:
# no JIT entitlements needed; sign-notarize.sh's Resources Mach-O loop signs both automatically.
mkdir -p "$APP/Contents/Resources/scc"
if cp deps/scc deps/libscc_lib.dylib "$APP/Contents/Resources/scc/" 2>/dev/null; then
  chmod +x "$APP/Contents/Resources/scc/scc"
  echo "  bundled scc + libscc_lib.dylib"
else
  echo "  [warn] scc missing from deps/ (re-run tools/fetch-deps.sh) - script mods won't compile"
fi

if [ -f assets/icon.png ]; then
  echo "==> generating app icon (AppIcon.icns from assets/icon.png)"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"             assets/icon.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "==> ad-hoc signing"
codesign -s - --deep --force "$APP" >/dev/null
echo "built $APP"
echo "Run it:  open \"$APP\"   (first launch may need right-click -> Open until notarized)"
