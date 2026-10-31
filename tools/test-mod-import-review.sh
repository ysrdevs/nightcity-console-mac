#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc launcher/Sources/ModImportReview.swift tests/ModImportReviewTests.swift -o "$TEST_DIR/mod-import-review-tests"
"$TEST_DIR/mod-import-review-tests"
