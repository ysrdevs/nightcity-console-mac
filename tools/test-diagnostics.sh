#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/DiagnosticsProcessSampler.swift \
  launcher/Sources/FlightDiagnosticSummary.swift \
  launcher/Sources/DiagnosticsCollector.swift tests/DiagnosticsCollectorTests.swift \
  -o "$TEST_DIR/diagnostics-tests"
"$TEST_DIR/diagnostics-tests"
bash tools/test-flight-diagnostic-summary.sh
python3 tools/test-diagnostics-process-sampler.py
node tests/runtime-diagnostics.mjs
