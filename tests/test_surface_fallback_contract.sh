#!/bin/sh
# Contract: a phone without sys-therm/board zones still has a surface temperature.
#
# OnePlus 12 (SM8650) exposes only shell_* body sensors. surface_hotspot stayed 0 there,
# so every surface-driven heat trim was silently off on that model.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL surface fallback: $*" >&2; fail=1; }
grep -q 'g_thermal_surface_zone < 0 && g_thermal_board_zone < 0' "$M" || f "no fallback when both zones are missing"
grep -q 't->surface_hotspot_c = t->skin_temp_c;' "$M" || f "fallback does not use the shell sensor"
grep -q '!g_surface_from_skin &&' "$M" || f "borrowed surface counted twice in consensus"
grep -q 'surface_source=%s' "$G" || f "surface provenance not published"
grep -q 'surface_source' "$ROOT/tools/asb_diag.sh" || f "diag does not report the surface source"
grep -q 'policy6}/scaling_cur_freq' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "logkit phase prime read is not policy-agnostic"
grep -q 'LK_PRIME_POL:-' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "logkit phase prime read ignores LK_PRIME_POL"
[ "$fail" = 0 ] && echo "PASS surface fallback contract"
exit "$fail"
