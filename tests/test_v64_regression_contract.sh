#!/usr/bin/env bash
# tests/test_v64_regression_contract.sh — build and run Session unit tests
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$SCRIPT_DIR/test_v64_regression_contract.c"
BIN="/tmp/asb_test_v64_regression_contract"

CC="${CC:-cc}"
CFLAGS="-Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -I${ROOT_DIR}/src -D_GNU_SOURCE"

echo "Building V64 regression contract..."
"$CC" $CFLAGS "$SRC" -o "$BIN"

echo "Running..."
"$BIN"
RC=$?

rm -f "$BIN"
exit "$RC"
