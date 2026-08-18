#!/usr/bin/env sh
# Enforce a progressive strict-warning budget without pretending legacy debt is
# zero. Lower BASELINE after each cleanup; a release may never add warnings.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BASELINE_FILE="${ASB_WARNING_BASELINE:-$ROOT/.ci/native_warning_budget.txt}"
CC_BIN="${CC:-cc}"
TMP=$(mktemp "${TMPDIR:-/tmp}/asb_warnings.XXXXXX")
trap 'rm -f "$TMP"' EXIT HUP INT TERM

[ -r "$BASELINE_FILE" ] || { echo "warning budget file unavailable: $BASELINE_FILE" >&2; exit 1; }
BASELINE=$(tr -d ' \r\n' < "$BASELINE_FILE")
case "$BASELINE" in ''|*[!0-9]*) echo "invalid warning baseline: $BASELINE" >&2; exit 1 ;; esac

# The production build keeps its current ABI flags. The strict pass is syntax
# only: it reveals narrowing/sign changes while remaining device-independent.
if ! "$CC_BIN" -fsyntax-only -I"$ROOT/src" -Wall -Wextra -Wconversion -Wsign-conversion \
  -Wno-unused-parameter -Wno-sign-compare "$ROOT/src/asb_governor.c" >"$TMP" 2>&1; then
  cat "$TMP" >&2
  exit 1
fi
COUNT=$(grep -cE 'warning:' "$TMP" 2>/dev/null || true)
printf 'native strict warnings: %s (budget: %s)\n' "$COUNT" "$BASELINE"
if [ "$COUNT" -gt "$BASELINE" ]; then
  echo 'ERROR: native strict-warning budget exceeded; fix the new conversion/type warning or deliberately lower the baseline in a dedicated cleanup change.' >&2
  cat "$TMP" >&2
  exit 1
fi
