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

# ---------------------------------------------------------------------------
# ASB DSP audio effect (libasbdsp.so)
# A shared library loaded by audioserver, so it needs -shared/-fPIC instead of
# the PIE flags used for the governor binary. Built only for the release name;
# the debug build reuses the same .so.
# ---------------------------------------------------------------------------
# Accept either src/dsp or src/DSP: Linux CI is case-sensitive and the directory has
# lived under both spellings, which silently skipped the DSP build (no .so, no effect).
DSP_SRC=""; DSP_INC=""
for _d in dsp DSP; do
  if [ -f "$SCRIPT_DIR/$_d/asb_dsp.c" ]; then
    DSP_SRC="$SCRIPT_DIR/$_d/asb_dsp.c"; DSP_INC="$SCRIPT_DIR/$_d"; break
  fi
done
if [ -n "$DSP_SRC" ]; then
  # Build BOTH ABIs. /vendor/lib/soundfx and /vendor/lib64/soundfx both exist on the
  # target, and an effect library has to match the bitness of the process that dlopens
  # it - a 64-bit .so dropped into lib/soundfx simply fails to load. This is why
  # ViperFX and every other effect ships a pair.
  for _abi in arm64-v8a armeabi-v7a; do
    case "$_abi" in
      arm64-v8a)   _dcc="$TOOLCHAIN/aarch64-linux-android${API}-clang" ;;
      armeabi-v7a) _dcc="$TOOLCHAIN/armv7a-linux-androideabi${API}-clang" ;;
    esac
    if [ ! -x "$_dcc" ]; then
      echo "[ASB] note: no compiler for $_abi ($_dcc) - skipping that ABI"
      continue
    fi
    _dout="$ROOT_DIR/bin/$_abi"
    mkdir -p "$_dout"
    DSP_CFLAGS=(
      -O2 -fPIC -shared
      -fstack-protector-strong
      -D_FORTIFY_SOURCE=2
      -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare
      -fvisibility=hidden
      -I"$DSP_INC"
    )
    "$_dcc" "${DSP_CFLAGS[@]}" "$DSP_SRC" -lm -llog -o "$_dout/libasbdsp.so"
    "$STRIP" "$_dout/libasbdsp.so" || true
    chmod 0644 "$_dout/libasbdsp.so"
    # The AELI symbol MUST be exported or audioserver cannot load the effect.
    if command -v "$TOOLCHAIN/llvm-nm" >/dev/null 2>&1; then
      "$TOOLCHAIN/llvm-nm" -D --defined-only "$_dout/libasbdsp.so" | grep -q " AELI$" \
        || { echo "[ASB] ERROR: AELI symbol not exported from $_abi/libasbdsp.so" >&2; exit 1; }
    fi
    ls -lh "$_dout/libasbdsp.so"
  done
else
  echo "[ASB] note: asb_dsp.c not found under src/dsp or src/DSP - skipping DSP build"
fi
