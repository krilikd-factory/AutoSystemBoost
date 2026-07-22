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
    # Do not hard-code the API in the wrapper name. The NDK ships one clang wrapper per
    # (triple, API) pair and which APIs exist moves between NDK releases - a missing
    # armv7a-linux-androideabi24-clang silently dropped the whole 32-bit build and the
    # only symptom was /system/vendor/lib/soundfx never appearing in the module.
    # Prefer the requested API, otherwise take the lowest one the NDK actually has.
    case "$_abi" in
      arm64-v8a)   _dtriple="aarch64-linux-android" ;;
      armeabi-v7a) _dtriple="armv7a-linux-androideabi" ;;
    esac
    _dcc="$TOOLCHAIN/${_dtriple}${API}-clang"
    if [ ! -x "$_dcc" ]; then
      _dcc="$(ls "$TOOLCHAIN/${_dtriple}"[0-9]*-clang 2>/dev/null \
               | sed "s|.*/${_dtriple}||; s|-clang$||" | sort -n | head -1 \
               | sed "s|^|$TOOLCHAIN/${_dtriple}|; s|$|-clang|")"
    fi
    if [ -z "$_dcc" ] || [ ! -x "$_dcc" ]; then
      echo "[ASB] WARNING: no clang for $_abi (triple ${_dtriple}) in $TOOLCHAIN"
      echo "[ASB]          available wrappers for this triple:"
      ls "$TOOLCHAIN/${_dtriple}"*-clang 2>/dev/null | sed 's|^|[ASB]            |' \
        || echo "[ASB]            (none - this NDK has no $_abi support)"
      echo "[ASB]          -> /vendor/lib/soundfx will NOT get the effect"
      continue
    fi
    echo "[ASB] $_abi: using $(basename "$_dcc")"
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
    _aidl_pre="${ASB_DSP_AIDL_DIR:-$SCRIPT_DIR/DSP_AIDL/prebuilt}/$_abi/libasbdsp_aidl.so"
    if [ "${ASB_DSP_AIDL:-0}" = "1" ] || [ -f "$_aidl_pre" ]; then
      # AIDL build path. The AIDL effect (src/DSP_AIDL) needs AOSP effect-AIDL + FMQ
      # headers that plain NDK clang does not ship, so it is built by soong, not here.
      # This branch VERIFIES a pre-built libasbdsp_aidl.so has been dropped in and
      # copies it to the on-disk name the installer registers (libasbdsp.so). It fires
      # automatically when a prebuilt is present, so a missing flag can't silently ship
      # the legacy effect that Android 13+ will not load.
      if [ ! -f "$_aidl_pre" ]; then
        echo "[ASB] ERROR: ASB_DSP_AIDL=1 but $_aidl_pre not found (build it with soong: mm libasbdsp_aidl)" >&2
        exit 1
      fi
      cp -f "$_aidl_pre" "$_dout/libasbdsp.so"
      if [ "$SCRIPT_DIR/DSP_AIDL/asb_effect_aidl.cpp" -nt "$_aidl_pre" ] || \
         [ "$SCRIPT_DIR/DSP_AIDL/asb_dsp_core.h" -nt "$_aidl_pre" ]; then
        echo "[ASB] WARNING: $_abi prebuilt libasbdsp_aidl.so is OLDER than the effect"
        echo "[ASB]   source - it may be a stale build. Rebuild it with soong from the"
        echo "[ASB]   current src/DSP_AIDL (mm libasbdsp_aidl) before shipping." >&2
      fi
      "$STRIP" "$_dout/libasbdsp.so" || true
      chmod 0644 "$_dout/libasbdsp.so"
      if command -v "$TOOLCHAIN/llvm-nm" >/dev/null 2>&1; then
        "$TOOLCHAIN/llvm-nm" -D --defined-only "$_dout/libasbdsp.so" | grep -q " createEffect$" \
          || { echo "[ASB] ERROR: createEffect (AIDL) symbol not exported from $_abi/libasbdsp.so" >&2; exit 1; }
      fi
      echo "[ASB] DSP: AIDL effect for $_abi (createEffect verified)"
      ls -lh "$_dout/libasbdsp.so"
      continue
    fi
    "$_dcc" "${DSP_CFLAGS[@]}" "$DSP_SRC" -lm -llog -o "$_dout/libasbdsp.so"
    "$STRIP" "$_dout/libasbdsp.so" || true
    chmod 0644 "$_dout/libasbdsp.so"
    # The AELI symbol MUST be exported or audioserver cannot load the effect.
    if command -v "$TOOLCHAIN/llvm-nm" >/dev/null 2>&1; then
      "$TOOLCHAIN/llvm-nm" -D --defined-only "$_dout/libasbdsp.so" | grep -q " AELI$" \
        || { echo "[ASB] ERROR: AELI symbol not exported from $_abi/libasbdsp.so" >&2; exit 1; }
    fi
    echo "[ASB] ============================================================"
    echo "[ASB] WARNING: built the LEGACY DSP effect for $_abi."
    echo "[ASB]   The legacy HAL effect is NOT loaded by audioserver on Android 13+"
    echo "[ASB]   (OxygenOS 16 / SM8850) - dsp_loudness will have NO audible effect."
    echo "[ASB]   Build the AIDL effect with soong (mm libasbdsp_aidl), put it in"
    echo "[ASB]   src/DSP_AIDL/prebuilt/$_abi/libasbdsp_aidl.so and rebuild."
    echo "[ASB] ============================================================"
    ls -lh "$_dout/libasbdsp.so"
  done
else
  echo "[ASB] note: asb_dsp.c not found under src/dsp or src/DSP - skipping DSP build"
fi
