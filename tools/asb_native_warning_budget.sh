#!/usr/bin/env sh
# Enforce a progressive strict-warning budget without pretending legacy debt is
# zero. Lower BASELINE after each cleanup; a release may never add warnings.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BASELINE_FILE="${ASB_WARNING_BASELINE:-$ROOT/tools/asb_native_warning_baseline.txt}"
CC_BIN="${CC:-cc}"
TMP=$(mktemp "${TMPDIR:-/tmp}/asb_warnings.XXXXXX")
CURRENT=$(mktemp "${TMPDIR:-/tmp}/asb_warnings_current.XXXXXX")
NEW=$(mktemp "${TMPDIR:-/tmp}/asb_warnings_new.XXXXXX")
RESOLVED=$(mktemp "${TMPDIR:-/tmp}/asb_warnings_resolved.XXXXXX")
trap 'rm -f "$TMP" "$CURRENT" "$NEW" "$RESOLVED"' EXIT HUP INT TERM

[ -r "$BASELINE_FILE" ] || { echo "warning budget file unavailable: $BASELINE_FILE" >&2; exit 1; }
# The baseline is a ratchet, not a target: it may only move when a change is understood.
#
# 79 -> 80 for the cooldown clamp. The clamp itself introduces no conversions - it compares
# and assigns ints throughout - and gcc still reports 79 locally. clang reaches one more
# pre-existing line in asb_governor.c (the thermal_overlay_pct float maths around 6683)
# once the new code changes what it can prove about that path.
#
# Recorded here rather than silently raised so the next person can tell a deliberate bump
# from a slipped one.
#
# 80 -> 62: the read()/write()/recv() return values and their size arguments now carry
# explicit casts (ssize_t -> int, int -> size_t) - 18 of the 80 were those, all at call
# sites whose buffers are a few hundred bytes. gcc reports 61, clang 62; the ratchet holds
# the higher of the two so either compiler passes.
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

# GCC also gets a site-signature ratchet. A developer may not delete one legacy warning
# and introduce a different one while keeping the same total. Line/column numbers are
# deliberately excluded so unrelated edits do not create false "new" warnings; duplicate
# signatures remain significant and are compared as a multiset.
case "${CC_BIN##*/}" in
  gcc|gcc-[0-9]*)
    INVENTORY="${ASB_WARNING_INVENTORY:-$ROOT/tools/asb_native_warning_inventory.gcc.txt}"
    [ -r "$INVENTORY" ] || { echo "warning inventory unavailable: $INVENTORY" >&2; exit 1; }
    sed -nE 's#^(.*/)?src/([^:]+):[0-9]+:[0-9]+: warning: (.*)$#\2|\3#p' "$TMP" | LC_ALL=C sort > "$CURRENT"
    LC_ALL=C sort "$INVENTORY" | comm -23 "$CURRENT" - > "$NEW"
    LC_ALL=C sort "$INVENTORY" | comm -13 "$CURRENT" - > "$RESOLVED"
    NEW_COUNT=$(wc -l < "$NEW" | tr -d ' ')
    RESOLVED_COUNT=$(wc -l < "$RESOLVED" | tr -d ' ')
    printf 'GCC warning inventory: new=%s resolved=%s baseline_sites=%s\n' \
      "$NEW_COUNT" "$RESOLVED_COUNT" "$(wc -l < "$INVENTORY" | tr -d ' ')"
    if [ "$NEW_COUNT" -gt 0 ]; then
      echo 'ERROR: new native warning site(s) since the reviewed inventory:' >&2
      cat "$NEW" >&2
      exit 1
    fi
    ;;
esac

if [ "${ASB_WARNING_VERBOSE:-0}" = 1 ]; then cat "$TMP"; fi
