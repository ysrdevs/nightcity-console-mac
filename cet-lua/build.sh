#!/bin/bash
# Build the cet-lua RED4ext plugin (arm64). Fetches LuaJIT (static, GC64) + sol2 + CET source (reference) +
# links the macOS-patched RED4ext.SDK on first run. Output: build/cet-lua.dylib (ad-hoc signed for dev).
# Deploy: cp build/cet-lua.dylib "<GAME>/red4ext/plugins/cet-lua/" && codesign -f -s - <same>
set -e
cd "$(dirname "$0")"
V=vendor
mkdir -p "$V"

# LuaJIT (arm64, GC64 default; interpreter usable, JIT toggled off at runtime).
if [ ! -f "$V/LuaJIT/src/libluajit.a" ]; then
  echo "== building LuaJIT =="
  [ -d "$V/LuaJIT" ] || git clone --depth 1 https://github.com/LuaJIT/LuaJIT.git "$V/LuaJIT"
  ( cd "$V/LuaJIT" && MACOSX_DEPLOYMENT_TARGET=11.0 make -j8 amalg )
fi

# sol2 (header-only).
[ -f "$V/sol2/include/sol/sol.hpp" ] || git clone --depth 1 https://github.com/ThePhD/sol2.git "$V/sol2"

# CET source (Windows framework we port from - reference only, not compiled).
[ -d "$V/CyberEngineTweaks/src" ] || git clone --depth 1 https://github.com/maximegmd/CyberEngineTweaks.git "$V/CyberEngineTweaks"

# RED4ext.SDK: reuse the macOS-patched fork from the TweakXL vendor tree.
if [ ! -e "$V/RED4ext.SDK" ]; then
  ln -s /Users/ysr/cybermodman/vendor/cp2077-tweak-xl-macos/vendor/RED4ext.SDK "$V/RED4ext.SDK"
fi

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j8
codesign -f -s - build/cet-lua.dylib 2>/dev/null || true
echo "== built build/cet-lua.dylib =="
file build/cet-lua.dylib
