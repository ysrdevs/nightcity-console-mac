#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d -t nightcity-flight-capture)"
trap 'rm -rf "$test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror -O1 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer -pthread \
  tests/flight-capture.cpp -o "$test_dir/flight-capture"
"$test_dir/flight-capture"
