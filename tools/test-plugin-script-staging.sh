#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/PluginScriptStager.swift tests/PluginScriptStagerTests.swift -o "$TEST_DIR/script-staging-tests"
"$TEST_DIR/script-staging-tests"
swiftc launcher/Sources/ScriptLaunchGate.swift tests/ScriptLaunchGateTests.swift -o "$TEST_DIR/script-launch-tests"
"$TEST_DIR/script-launch-tests"
