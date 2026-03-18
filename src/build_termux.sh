#!/system/bin/sh
# build_termux.sh — build asb_governor on-device with Termux
#
# INSTALL DEPENDENCIES (once):
#   pkg update && pkg install clang
#
# BUILD:
#   cd /path/to/AutoSystemBoost/src
#   sh build_termux.sh
#
# OUTPUT:
#   ../bin/asb  (ARM64 PIE binary, ~120KB stripped)

set -e

SRCDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
mkdir -p "$OUTDIR"

echo "[ASB] Compiling asb..."
echo "[ASB] Source: $SRCDIR"
echo "[ASB] Output: $OUTDIR"

if ! command -v clang >/dev/null 2>&1; then
    echo "[ERROR] clang not found. Install: pkg install clang"
    exit 1
fi

CLANG_VERSION=$(clang --version 2>&1 | head -1)
echo "[ASB] Compiler: $CLANG_VERSION"
echo "[ASB] Target: $(uname -m)"

CFLAGS="-O2 -fstack-protector-strong -fPIE -pie"
CFLAGS="$CFLAGS -D_FORTIFY_SOURCE=2"
CFLAGS="$CFLAGS -Wall -Wextra -Wno-unused-parameter"
CFLAGS="$CFLAGS -I$SRCDIR"
LDFLAGS="-lm"

clang $CFLAGS \
    "$SRCDIR/asb_governor.c" \
    $LDFLAGS \
    -o "$OUTDIR/asb"

if command -v strip >/dev/null 2>&1; then
    strip "$OUTDIR/asb"
fi

SIZE=$(wc -c < "$OUTDIR/asb")
echo "[ASB] Binary size: ${SIZE} bytes"

"$OUTDIR/asb" status 2>/dev/null || true

echo "[ASB] Build successful: $OUTDIR/asb"
echo ""
echo "Next step:"
echo "  cp $OUTDIR/asb /data/adb/modules/AutoSystemBoost/bin/"
echo "  chmod 755 /data/adb/modules/AutoSystemBoost/bin/asb"
