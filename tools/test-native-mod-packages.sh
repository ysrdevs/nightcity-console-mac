#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -target arm64-apple-macos15.5 launcher/Sources/NativeRuntimeManifest.swift launcher/Sources/NativeRuntimeInstallation.swift \
  launcher/Sources/NativeRuntimeCommand.swift launcher/Sources/NativeRuntimeLaunch.swift launcher/Sources/PluginScriptStager.swift \
  launcher/Sources/NativePackageProfiles.swift launcher/Sources/NativeModFiles.swift launcher/Sources/NativeModPackages.swift \
  tests/NativeModPackagesTests.swift -o "$TEST_DIR/native-mod-package-tests"
"$TEST_DIR/native-mod-package-tests"
