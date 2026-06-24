#!/bin/bash
# Build the NightCity Console in-game overlay dylib (arm64). Clones Dear ImGui on first run.
# Output: build/libcyberconsole_overlay.dylib (ad-hoc signed for dev; release signing is in tools/).
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="$ROOT/build/libcyberconsole_overlay.dylib"
IMGUI="imgui"
IMGUI_TAG="v1.92.9"   # pinned

mkdir -p "$ROOT/build"
if [ ! -d "$IMGUI" ]; then
  echo "Cloning Dear ImGui ($IMGUI_TAG)..."
  git clone --depth 1 --branch "$IMGUI_TAG" https://github.com/ocornut/imgui.git "$IMGUI" 2>/dev/null \
    || { echo "tag $IMGUI_TAG not found; cloning default branch"; git clone --depth 1 https://github.com/ocornut/imgui.git "$IMGUI"; }
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SRC="overlay.mm \
  $IMGUI/imgui.cpp $IMGUI/imgui_draw.cpp $IMGUI/imgui_tables.cpp $IMGUI/imgui_widgets.cpp \
  $IMGUI/backends/imgui_impl_metal.mm"

clang++ -ObjC++ -fobjc-arc -std=c++17 -O2 -arch arm64 -dynamiclib \
  -I "$IMGUI" -I "$IMGUI/backends" \
  -isysroot "$SDK" \
  -framework Foundation -framework Metal -framework QuartzCore -framework AppKit \
  -o "$OUT" $SRC

codesign -s - --force --timestamp=none "$OUT"

# Ship the declarative tabs next to the dylib so the overlay's loadTabsFromDir()
# (which reads overlayDir()/tabs) finds them in a dev build.
if [ -d "tabs" ]; then
  rm -rf "$ROOT/build/tabs"
  cp -R "tabs" "$ROOT/build/tabs"
  echo "copied tabs/ -> $ROOT/build/tabs ($(ls tabs | wc -l | tr -d ' ') files)"
fi

echo "built $OUT"
