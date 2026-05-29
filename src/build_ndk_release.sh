#!/usr/bin/env bash
set -euo pipefail

API="${API:-24}"
NDK_ROOT="${NDK_ROOT:-${ANDROID_NDK_ROOT:-}}"
ABI="arm64-v8a"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$ROOT_DIR/bin/$ABI"
mkdir -p "$OUT_DIR"

if [ -z "$NDK_ROOT" ] || [ ! -d "$NDK_ROOT" ]; then
  echo "[ASB] NDK_ROOT/ANDROID_NDK_ROOT is not set or invalid" >&2
  exit 1
fi

HOST_TAG="linux-x86_64"
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CC="$TOOLCHAIN/aarch64-linux-android${API}-clang"
STRIP="$TOOLCHAIN/llvm-strip"

if [ ! -x "$CC" ]; then
  echo "[ASB] compiler not found: $CC" >&2
  exit 1
fi

ASB_BUILD_MODE="${ASB_BUILD_MODE:-release}"
case "$ASB_BUILD_MODE" in
  release) ASB_BIN_NAME="asb" ;;
  debug)   ASB_BIN_NAME="asb-debug" ;;
  *) echo "[ASB] ASB_BUILD_MODE must be 'release' or 'debug' (got: $ASB_BUILD_MODE)" >&2; exit 1 ;;
esac

CFLAGS=(
  -O2 -fstack-protector-strong -fPIE -pie
  -D_FORTIFY_SOURCE=2
  -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare
  -I"$SCRIPT_DIR"
)
if [ "$ASB_BUILD_MODE" = "debug" ]; then
  CFLAGS+=(-DASB_DEBUG_BUILD=1)
fi
LDFLAGS=(-lm)

"$CC" "${CFLAGS[@]}" "$SCRIPT_DIR/asb_governor.c" "${LDFLAGS[@]}" -o "$OUT_DIR/$ASB_BIN_NAME"
"$STRIP" "$OUT_DIR/$ASB_BIN_NAME" || true
chmod 0755 "$OUT_DIR/$ASB_BIN_NAME"
ls -lh "$OUT_DIR/$ASB_BIN_NAME"
