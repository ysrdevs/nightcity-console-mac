#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
clang -Wall -Wextra -Werror tests/NativeRuntimeCommandChild.c -o "$TEST_DIR/command-child"
swiftc -target arm64-apple-macos15.5 launcher/Sources/NativeRuntimeManifest.swift \
  launcher/Sources/NativeRuntimeCommand.swift tests/NativeRuntimeCommandTests.swift \
  -o "$TEST_DIR/native-runtime-command-tests"
"$TEST_DIR/native-runtime-command-tests" "$TEST_DIR/command-child"
