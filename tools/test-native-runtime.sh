#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/NativeRuntimeManifest.swift \
  launcher/Sources/NativeRuntimeInstallation.swift \
  launcher/Sources/NativeRuntimeLaunch.swift tests/NativeRuntimeTests.swift \
  -o "$TEST_DIR/native-runtime-tests"
"$TEST_DIR/native-runtime-tests"
