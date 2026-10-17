#!/bin/sh
# Native build gate: the governor must compile cleanly with -O2 -Wall -Wextra -Werror.
#
# Without -Werror the build always passed, so warnings could accumulate unnoticed; an
# external audit found 16 (unused parameters, devfreq path truncation, strncpy). They are
# fixed, and this gate keeps them from coming back. Skipped when no C compiler is present.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC_BIN="${CC:-}"
[ -n "$CC_BIN" ] || for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
if [ -z "$CC_BIN" ]; then echo "SKIP native -Werror gate (no C compiler)"; exit 0; fi
TMP="$(mktemp)"; trap 'rm -f "$TMP" "$TMP.o"' EXIT
if ! "$CC_BIN" -O2 -Wall -Wextra -Werror -I"$ROOT/src" -c "$ROOT/src/asb_governor.c" -o "$TMP.o" >"$TMP" 2>&1; then
  echo "FAIL native -Werror gate:"; head -20 "$TMP"; exit 1
fi
echo "PASS native -Werror gate ($CC_BIN -O2 -Wall -Wextra -Werror)"
