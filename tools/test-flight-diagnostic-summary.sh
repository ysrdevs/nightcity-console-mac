#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/FlightDiagnosticSummary.swift tests/FlightDiagnosticSummaryTests.swift \
  -o "$TEST_DIR/flight-diagnostic-summary-tests"
"$TEST_DIR/flight-diagnostic-summary-tests"
