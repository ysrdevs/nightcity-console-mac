#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d -t nightcity-output-snapshot)"
trap 'rm -rf "$test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror -O1 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer -pthread \
  tests/output-snapshot.cpp -o "$test_dir/output-snapshot"
"$test_dir/output-snapshot"
