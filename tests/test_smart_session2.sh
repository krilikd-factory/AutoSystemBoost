#!/usr/bin/env bash
# tests/test_smart_session2.sh — build and run V48 Session 2 unit tests
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$SCRIPT_DIR/test_smart_session2.c"
BIN="/tmp/asb_test_smart_session2"

CC="${CC:-gcc}"
CFLAGS="-Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -I${ROOT_DIR}/src -D_GNU_SOURCE"

echo "Building V48 Session 2 unit tests..."
"$CC" $CFLAGS "$SRC" -o "$BIN"

echo "Running..."
"$BIN"
RC=$?

rm -f "$BIN"
exit "$RC"
