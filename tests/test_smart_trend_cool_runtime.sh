#!/bin/sh
# Runtime (fix160): Smart no longer cuts the ceilings by a third on a fast thermal trend while the
# body is cool, and a ceiling ASB asked for itself is no longer counted as a vendor raise.
#
# Owner's OP15, capture 31599: every thermal-trend trim in the captured log tails came at a skin
# of 28-31 C with the HAL headroom at 83-100% - "trim=34 stage=3 reason=thermal_trend_fast
# skin=28 trend=20" - and read "cool" 30-60 s later. The trend sums rises of the hottest CPU
# sensor, which follows load: an app launch or camera start is enough. The trend now needs the
# skin within 8 C of thermal_skin_c (the band the light headroom stage already uses).
# The same day's action screen said the ROM raised the CPU ceiling above ASB's in 100 checks and
# the clock ran above it in 59; both log lines behind it carried "req 3648000" - the 80% unlock
# lift ASB itself had written. The REAL helpers are cut out of asb_governor.c and run on those
# numbers.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL smart trend cool: $*" >&2; exit 1; }
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP smart trend cool: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^static int asb_trend_body_cool(/,/^}/p' "$G" > "$T/h.c"
sed -n '/^enum { ASB_CEIL_OVER_NONE/,/^}/p' "$G" >> "$T/h.c"
grep -q 'asb_trend_body_cool' "$T/h.c" && grep -q 'asb_ceiling_over_kind' "$T/h.c" || fail "helpers not found"
_gate="$(grep -n 'asb_trend_body_cool(m->therm.temp_valid, m->therm.skin_temp_c, g_asb_cfg.thermal_skin_c)' "$G" | cut -d: -f1)"
_fast="$(grep -n '"thermal_trend_fast");' "$G" | cut -d: -f1)"
_mark="$(grep -n 'int _trend_warm = (!m->therm.temp_valid) || m->therm.cpu_max_c >= _trend_mark;' "$G" | cut -d: -f1)"
[ -n "$_gate" ] && [ -n "$_fast" ] && [ -n "$_mark" ] || fail "trend gate not wired"
[ "$_mark" -lt "$_gate" ] && [ "$_gate" -lt "$_fast" ] || fail "the cool-body gate is not between the warm mark and the trend trims"
grep -q 'int leak0 = (k0 == ASB_CEIL_OVER_VENDOR);' "$G" || fail "vendor leak still counts ASB's own requests"
grep -q 'asb_ceiling_over_kind(actual_p1, want_p1, g_write_health\[ASB_WRITE_CPU_MAX0 + 1\].requested)' "$G" || fail "prime classification does not read the writer's request"
grep -q 'own_ceiling_ticks=%lu' "$G" || fail "own lifts not published"
grep -q 'trend_trim_held_cool=%lu' "$G" || fail "held trend trims not published"
grep -q 'own_ceiling_ticks' "$ROOT/tools/asb_diag.sh" && grep -q 'trend_trim_held_cool' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show them"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include "h.c"
static int bad;
static void chk(int c, const char *m) { if (!c) { printf("FAIL %s\n", m); bad++; } }
int main(void) {
    chk(asb_trend_body_cool(1, 28, 47) == 1, "skin 28 C with a 47 C limit is cool (17:48:52 trim)");
    chk(asb_trend_body_cool(1, 31, 47) == 1, "skin 31 C is cool (16:58:44 and 19:04:25 trims)");
    chk(asb_trend_body_cool(1, 38, 47) == 1, "skin 38 C is still under the pre-lean band");
    chk(asb_trend_body_cool(1, 39, 47) == 0, "skin 39 C is in the band - the trend counts");
    chk(asb_trend_body_cool(1, 44, 47) == 0, "a warm body keeps the trend trim");
    chk(asb_trend_body_cool(0, 28, 47) == 0, "no valid reading keeps the old trend-only behaviour");
    chk(asb_trend_body_cool(1, 0, 47) == 0, "no skin sensor keeps the old behaviour");
    chk(asb_trend_body_cool(1, 85, 47) == 0, "an implausible skin reading is not taken as cool");
    chk(asb_trend_body_cool(1, 28, 0) == 0, "no limit configured keeps the old behaviour");
    chk(asb_ceiling_over_kind(3648000, 1862400, 3648000) == ASB_CEIL_OVER_OWN, "unlock-lift rail ASB wrote is its own (18:45:27)");
    chk(asb_ceiling_over_kind(2496000, 1996800, 2841600) == ASB_CEIL_OVER_OWN, "a vendor-held value under ASB's own lift is the lift");
    chk(asb_ceiling_over_kind(3648000, 1862400, 1862400) == ASB_CEIL_OVER_VENDOR, "a raise above what ASB asked is the vendor's");
    chk(asb_ceiling_over_kind(1900000, 1862400, 0) == ASB_CEIL_OVER_NONE, "within 100 MHz is no raise");
    chk(asb_ceiling_over_kind(3648000, 1862400, 0) == ASB_CEIL_OVER_VENDOR, "no request on record reads as the vendor");
    chk(asb_ceiling_over_kind(0, 1862400, 3648000) == ASB_CEIL_OVER_NONE, "an unreadable node is not a raise");
    return bad ? 1 : 0;
}
X
"$CC" -O2 -Wall -Wextra -I"$T" "$T/t.c" -o "$T/t" 2> "$T/cc.log" || { cat "$T/cc.log" >&2; fail "harness does not compile"; }
out="$("$T/t")" || fail "$out"
echo "PASS smart trend cool: trend trims need a body within 8 C of the skin limit; ASB's own lifts are not counted as vendor raises"
