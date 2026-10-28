#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/ExplorationScripts.swift tests/ExplorationScriptsTests.swift -o "$TEST_DIR/exploration-install-tests"
"$TEST_DIR/exploration-install-tests"
python3 tools/test-exploration-payload.py
