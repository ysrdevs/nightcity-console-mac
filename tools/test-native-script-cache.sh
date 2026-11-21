#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/NativeRuntimeManifest.swift \
  launcher/Sources/NativeRuntimeInstallation.swift \
  launcher/Sources/PluginScriptStager.swift launcher/Sources/NativeRuntimeCommand.swift \
  launcher/Sources/NativeRuntimeLaunch.swift tests/NativeScriptCacheTests.swift \
  -o "$TEST_DIR/native-script-cache-tests"
"$TEST_DIR/native-script-cache-tests" "$@"
