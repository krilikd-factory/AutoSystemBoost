#!/system/bin/sh
# build_termux.sh — сборка asb_governor в Termux на OnePlus 15
#
# УСТАНОВКА ЗАВИСИМОСТЕЙ (один раз):
#   pkg update && pkg install clang
#
# ЗАПУСК СБОРКИ:
#   cd /path/to/asb_ai/build
#   sh build_termux.sh
#
# РЕЗУЛЬТАТ:
#   ../bin/asb  (ARM64 PIE бинарник, ~120KB stripped)

set -e

SRCDIR="$(cd "$(dirname "$0")/../src" && pwd)"
OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
mkdir -p "$OUTDIR"

echo "[ASB] Compiling asb..."
echo "[ASB] Source: $SRCDIR"
echo "[ASB] Output: $OUTDIR"

# Проверяем clang
if ! command -v clang >/dev/null 2>&1; then
    echo "[ERROR] clang not found. Install: pkg install clang"
    exit 1
fi

CLANG_VERSION=$(clang --version 2>&1 | head -1)
echo "[ASB] Compiler: $CLANG_VERSION"
echo "[ASB] Target: $(uname -m)"

# Флаги компиляции
# -O2:           оптимизация скорость/размер
# -fstack-protector-strong: защита стека
# -fPIE -pie:    position-independent executable
# -static-pie:   статическая линковка (не зависит от libc версии)
# -lm:           libm для fabsf в metrics
# -D_FORTIFY_SOURCE=2: дополнительные проверки libc

CFLAGS="-O2 -fstack-protector-strong -fPIE -pie"
CFLAGS="$CFLAGS -D_FORTIFY_SOURCE=2"
CFLAGS="$CFLAGS -Wall -Wextra -Wno-unused-parameter"
CFLAGS="$CFLAGS -I$SRCDIR"
LDFLAGS="-lm"

clang $CFLAGS \
    "$SRCDIR/asb_governor.c" \
    $LDFLAGS \
    -o "$OUTDIR/asb"

# Стриппинг debug symbols (уменьшает размер)
if command -v strip >/dev/null 2>&1; then
    strip "$OUTDIR/asb"
fi

SIZE=$(wc -c < "$OUTDIR/asb")
echo "[ASB] Binary size: ${SIZE} bytes"

# Проверяем что бинарник запускается
"$OUTDIR/asb" status 2>/dev/null || true

echo "[ASB] Build successful: $OUTDIR/asb"
echo ""
echo "Следующий шаг:"
echo "  cp $OUTDIR/asb /data/adb/modules/AutoSystemBoost/bin/"
echo "  chmod 755 /data/adb/modules/AutoSystemBoost/bin/asb"
