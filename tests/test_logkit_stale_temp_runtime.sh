#!/bin/sh
# Runtime (fix141): the per-phase cpuT/surfT do not carry a governor reading hours old.
#
# Capture 2830: the governor's deep-idle economy skips the thermal zones, its status kept
# temp 43 / surface 37 from 01:03 to 08:02, and the sleep row read "cpuT 41 surfT 36" while
# the capture's own zone reads sat at 26-35 C.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL logkit stale temp: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tz/thermal_zone26" "$T/tz/thermal_zone15" "$T/tz/thermal_zone79" "$T/tz/thermal_zone84"
echo 29400 > "$T/tz/thermal_zone26/temp"; echo 31200 > "$T/tz/thermal_zone15/temp"
echo 27100 > "$T/tz/thermal_zone79/temp"; echo 28000 > "$T/tz/thermal_zone84/temp"
r="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
       LK_THERMAL_BASE="$T/tz" TZ_CPU_PRIME=26 TZ_CPU_PERF=15 TZ_SYSTHERM6=79 TZ_BOARD=84 lk_direct_temps) )"
[ "$r" = "31|28" ] || fail "direct reads: $r"
r="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
       LK_THERMAL_BASE="$T/tz" TZ_CPU_PRIME= TZ_CPU_PERF= TZ_SYSTHERM6=79 TZ_BOARD= lk_direct_temps) )"
[ "$r" = "|27" ] || fail "missing CPU zones must leave the field empty, not shift the surface into it: $r"
F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '"temp_read_epoch":' "$F" || fail "phase accumulation ignores the reading's age"
grep -q "IFS='|' read -r _temp _surf" "$F" || fail "stale reading not replaced by the zones"
grep -q 'temp_read_epoch' "$ROOT/src/asb_governor.c" || fail "governor no longer publishes the read time"
echo "PASS logkit stale temp: a governor reading over two minutes old is replaced by the capture's own zone reads"
