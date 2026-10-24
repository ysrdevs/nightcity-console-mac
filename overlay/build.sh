#!/bin/bash
# Build the NightCity Console in-game overlay dylib (arm64). Clones Dear ImGui on first run.
# Output: build/libcyberconsole_overlay.dylib (ad-hoc signed for dev; release signing is in tools/).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="$ROOT/build/libcyberconsole_overlay.dylib"
IMGUI="imgui"
# Exact source used by the working local baseline (1.92.9 WIP); never fall back to a moving branch.
IMGUI_COMMIT="9a5c070308ae97bf0f884b071d0262ae1cad26f7"

mkdir -p "$ROOT/build"
if [ ! -d "$IMGUI" ]; then
  echo "Fetching Dear ImGui ($IMGUI_COMMIT)..."
  git init -q "$IMGUI"
  git -C "$IMGUI" remote add origin https://github.com/ocornut/imgui.git
  git -C "$IMGUI" fetch -q --depth 1 origin "$IMGUI_COMMIT"
  git -C "$IMGUI" checkout -q --detach FETCH_HEAD
fi
[ "$(git -C "$IMGUI" rev-parse HEAD)" = "$IMGUI_COMMIT" ] \
  || { echo "Dear ImGui must be at the pinned commit $IMGUI_COMMIT" >&2; exit 1; }
git -C "$IMGUI" diff --quiet && git -C "$IMGUI" diff --cached --quiet \
  || { echo "Dear ImGui has local source changes; keep them separate from this release build." >&2; exit 1; }

# Build PUC-Lua 5.1.5 (arm64, interpreter-only, no JIT, W^X-safe) on first run.
# This is the runtime that hosts CET-style Lua mods. Provides lua-5.1.5/src/{lua.h,...} + liblua5.1.a.
LUA_DIR="lua-5.1.5"
# A release never silently reuses an untracked Lua source tree or old static library.
if [ "${NIGHTCITY_BUILD_MODE:-development}" = "release" ]; then
  LUA_DIR="$ROOT/build/lua-5.1.5"
  rm -rf "$LUA_DIR"
fi
LUA_LIB="$LUA_DIR/src/liblua5.1.a"
if [ ! -f "$LUA_LIB" ]; then
  echo "Building PUC-Lua 5.1.5 (arm64, interpreter-only)..."
  if [ ! -d "$LUA_DIR" ]; then
    LUA_ARCHIVE="$ROOT/build/lua-5.1.5.tar.gz"
    # Official checksum: https://www.lua.org/ftp/
    LUA_SHA=2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333
    if [ ! -f "$LUA_ARCHIVE" ] || [ "$(shasum -a 256 "$LUA_ARCHIVE" | cut -d' ' -f1)" != "$LUA_SHA" ]; then
      curl -fSL https://www.lua.org/ftp/lua-5.1.5.tar.gz -o "$LUA_ARCHIVE"
    fi
    [ "$(shasum -a 256 "$LUA_ARCHIVE" | cut -d' ' -f1)" = "$LUA_SHA" ] \
      || { echo "Lua source checksum mismatch" >&2; exit 1; }
    tar xzf "$LUA_ARCHIVE" -C "$(dirname "$LUA_DIR")"
  fi
  LSDK="$(xcrun --sdk macosx --show-sdk-path)"
  ( cd "$LUA_DIR/src"
    for f in *.c; do
      case "$f" in lua.c|luac.c|print.c) continue;; esac   # skip the lua/luac executable mains
      clang -arch arm64 -O2 -DLUA_USE_POSIX -DLUA_DL_DLOPEN -isysroot "$LSDK" -c "$f"
    done
    ar rcs liblua5.1.a *.o )
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SRC="overlay.mm \
  $IMGUI/imgui.cpp $IMGUI/imgui_draw.cpp $IMGUI/imgui_tables.cpp $IMGUI/imgui_widgets.cpp \
  $IMGUI/backends/imgui_impl_metal.mm"

clang++ -ObjC++ -fobjc-arc -std=c++17 -O2 -arch arm64 -dynamiclib \
  -I "$IMGUI" -I "$IMGUI/backends" -I "$LUA_DIR/src" \
  -isysroot "$SDK" \
  -framework Foundation -framework Metal -framework QuartzCore -framework AppKit \
  -o "$OUT" $SRC "$LUA_LIB"

codesign -s - --force --timestamp=none "$OUT"

# Ship the declarative tabs next to the dylib so the overlay's loadTabsFromDir()
# (which reads overlayDir()/tabs) finds them in a dev build.
if [ -d "tabs" ]; then
  rm -rf "$ROOT/build/tabs"
  cp -R "tabs" "$ROOT/build/tabs"
  echo "copied tabs/ -> $ROOT/build/tabs ($(ls tabs | wc -l | tr -d ' ') files)"
fi

# Ship the Lua mods next to the dylib so the overlay's loadLuaMods() (overlayDir()/mods) finds them.
if [ -d "mods" ]; then
  rm -rf "$ROOT/build/mods"
  cp -R "mods" "$ROOT/build/mods"
  echo "copied mods/ -> $ROOT/build/mods ($(ls mods | wc -l | tr -d ' ') mod dir(s))"
fi

echo "built $OUT"
