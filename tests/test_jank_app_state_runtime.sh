#!/bin/sh
# Runtime (fix140): the smoothness report compares ASB states inside the app with the most
# frames, touched and untouched apart.
#
# Capture 2830 read "LIGHT_IDLE 34.8% janky, MODERATE 4.1%" - and YouTube playing untouched
# made up most of LIGHT_IDLE. Inside YouTube untouched: 43.8% in LIGHT_IDLE, 42.3% in mixed.
# The per-state table on its own pointed at the state. The REAL report function runs here.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
fail() { echo "FAIL jank app/state: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
J="$T/jank_trace.tsv"
echo "# epoch|iso_time|phase|fsm_state|interval_s|main_at_cap|prime_at_cap|touches|frames|janky|deadline_missed|slow_ui|high_input|main_cap_pct|prime_cap_pct|fg_pkg" > "$J"
row() { printf '%s|t|audio_bt_scr|%s|48|0|0|%s|%s|%s|%s|50|5|1|0|%s\n' "$1" "$2" "$3" "$4" "$5" "$5" "$6" >> "$J"; }
row 1 LIGHT_IDLE 0 600 264 com.google.android.youtube
row 2 LIGHT_IDLE 0 600 262 com.google.android.youtube
row 3 mixed      0 600 254 com.google.android.youtube
row 4 MODERATE   3 1300 110 com.google.android.youtube
row 5 MODERATE   2 900 40 com.rifsxd.ksunext
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T" 2>&1)"
printf '%s\n' "$out" | grep -q '^within com.google.android.youtube (most frames), by ASB state and touch:$' || fail "no per-app table: $out"
printf '%s\n' "$out" | grep -qE '^  MODERATE +yes +1 +1300 +8\.5% +2\.29$' || fail "touched MODERATE row: $out"
printf '%s\n' "$out" | grep -qE '^  LIGHT_IDLE +no +2 +1200 +43\.8% +5\.48$' || fail "untouched LIGHT_IDLE row: $out"
printf '%s\n' "$out" | grep -qE '^  mixed +no +1 +600 +42\.3% +5\.29$' || fail "untouched mixed row: $out"
printf '%s\n' "$out" | grep -q 'ksunext .*yes' && fail "another app's rows in the table: $out"
# MODERATE before LIGHT_IDLE before mixed - a fixed order, not awk's hash order.
printf '%s\n' "$out" | awk '/^  MODERATE/ { m = NR } /^  LIGHT_IDLE/ { l = NR } /^  mixed/ { x = NR } END { exit !(m < l && l < x) }' \
  || fail "rows out of order: $out"
# One group only: nothing to compare, no table.
grep -v '|mixed|\||MODERATE|' "$J" > "$T/j2"; mkdir -p "$T/o2"; mv "$T/j2" "$T/o2/jank_trace.tsv"
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/o2" 2>&1)"
printf '%s\n' "$out" | grep -q '^within ' && fail "table printed for a single group: $out"
echo "PASS jank app/state: states compared inside the top app, touched and untouched apart"
