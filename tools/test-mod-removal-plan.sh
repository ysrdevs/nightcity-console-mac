#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/ModRemovalPlan.swift tests/ModRemovalPlanTests.swift -o "$TEST_DIR/mod-removal-plan-tests"
"$TEST_DIR/mod-removal-plan-tests"
