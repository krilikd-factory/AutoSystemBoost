#!/bin/sh
# Runtime (fix143): a steady source of janky frames is told apart from lag.
#
# Capture 26147: about 1.5 janky frames a second in every ASB state and at every frame rate,
# so LIGHT_IDLE - few frames drawn - read "42.0% janky" at 1.44 janky/s while MODERATE read
# 3.0% at 1.64/s. The report now prints janky/s, the frame-rate bands and the floor, records
# which app drew the janky frames (jank_trace column 17), and asbdiag measures the same per
# app while it runs. The REAL functions run here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL jank floor: $*" >&2; fail=1; }

# --- 1. report: a floor of 1.5 janky/s from SystemUI, under quiet and busy intervals ---------
mkdir -p "$T/a"
J="$T/a/jank_trace.tsv"
echo "# epoch|iso_time|phase|fsm_state|interval_s|main_at_cap|prime_at_cap|touches|frames|janky|deadline_missed|slow_ui|high_input|main_cap_pct|prime_cap_pct|fg_pkg|jank_pkgs" > "$J"
i=0
row() {   # state frames janky pkgs
  i=$((i + 1))
  printf '%s|t|active|%s|48|0|0|0|%s|%s|%s|50|5|1|0|com.instagram.android|%s\n' "$i" "$1" "$2" "$3" "$3" "$4" >> "$J"
}
for k in 1 2 3 4 5 6; do row LIGHT_IDLE 120 72 "com.android.systemui:70:72,com.instagram.android:2:48"; done
for k in 1 2 3 4 5 6 7 8; do row MODERATE 4000 76 "com.android.systemui:71:73,com.instagram.android:5:3900"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out" | grep -qE '^LIGHT_IDLE +6 +720 +60\.0% +1\.50$' || f "state row without janky/s: $out"
printf '%s\n' "$out" | grep -qE '^MODERATE +8 +32000 +1\.9% +1\.58$' || f "MODERATE row: $out"
printf '%s\n' "$out" | grep -qE '^  under 5 +6 +1\.50 +60\.0%$' || f "quiet band: $out"
printf '%s\n' "$out" | grep -qE '^  60 and over +8 +1\.58 +1\.9%$' || f "busy band: $out"
printf '%s\n' "$out" | grep -q '^steady floor: 1.50 janky frames a second while almost nothing was drawn' || f "no floor verdict: $out"
printf '%s\n' "$out" | grep -q '^  high share, ordinary rate: LIGHT_IDLE 60.0% janky at 1.50/s$' || f "LIGHT_IDLE not named as share-only: $out"
printf '%s\n' "$out" | grep -q 'high share, ordinary rate:.*MODERATE' && f "MODERATE named as share-only: $out"
printf '%s\n' "$out" | grep -qE '^  com\.android\.systemui +988 +1016 +1\.47   14 of 14$' || f "per-app source row: $out"
printf '%s\n' "$out" | grep -q '^the floor: com.android.systemui drew 97.2% of the janky frames in the quiet intervals.$' || f "floor source not named: $out"
printf '%s\n' "$out" | grep -q '^com.android.systemui missed deadlines in 14 of 14 screen-on intervals, whatever app was in front' || f "steady redraw line missing: $out"
printf '%s\n' "$out" | grep -q '^(the app in front is credited with every app' || f "front-app caveat missing: $out"
printf '%s\n' "$out" | grep -qE 'main cores at the ASB ceiling \(end of interval\): yes - of 0 frames \(-/s\), no 3\.2% of 32720 frames \(1\.55/s\)' || f "ceiling line without janky/s: $out"

# --- 2. no floor: janky frames only where much is drawn ---------------------------------------
mkdir -p "$T/b"; J="$T/b/jank_trace.tsv"; i=0
echo "# header" > "$J"
for k in 1 2 3 4 5 6; do row LIGHT_IDLE 120 1 "-"; done
for k in 1 2 3 4 5 6 7 8; do row MODERATE 4000 150 "-"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/b" 2>&1)"
printf '%s\n' "$out" | grep -q 'steady floor' && f "floor claimed where the quiet intervals are clean: $out"
printf '%s\n' "$out" | grep -q 'janky frames by the app that drew them' && f "per-app table printed with no column 17: $out"
printf '%s\n' "$out" | grep -q '^  under 5 ' || f "bands missing: $out"

# --- 3. recorder: column 17 from two dumps ------------------------------------------------------
gfx() {   # $1 file; then pairs "pkg frames janky"
  _o="$1"; shift; : > "$_o"
  while [ "$#" -ge 3 ]; do
    printf 'Package: %s\nStats since: 1000ns\nTotal frames rendered: %s\nJanky frames: %s (1.00%%)\nNumber Frame deadline missed: %s\nNumber Slow UI thread: 0\nNumber High input latency: 0\n' "$1" "$2" "$3" "$3" >> "$_o"
    shift 3
  done
}
gfx "$T/g1" com.android.systemui 1000 100 com.instagram.android 5000 10 com.old.app 900 90
gfx "$T/g2" com.android.systemui 1050 148 com.instagram.android 9000 14 com.old.app 900 90 com.new.app 30 6
gfx "$T/g3" com.android.systemui 1100 196 com.instagram.android 9000 14 com.old.app 100 1
mkdir -p "$T/c" "$T/cpufreq/policy0"
echo 100 > "$T/cpufreq/policy0/scaling_max_freq"; echo 50 > "$T/cpufreq/policy0/scaling_cur_freq"
printf 'state=MODERATE\ntouch_starts=1\n' > "$T/st"
rec="$(LK_OUT_DIR="$T/c" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" ASB_LK_STATE_FILE="$T/st" sh -c '
  . "$0" >/dev/null 2>&1
  lk_jank_trace_header
  ASB_LK_GFXSTATS_DUMP="$1/g1" lk_capture_jank_row active 1
  ASB_LK_GFXSTATS_DUMP="$1/g2" lk_capture_jank_row active 1
  ASB_LK_GFXSTATS_DUMP="$1/g3" lk_capture_jank_row active 1
  grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
  ls -a "$LK_OUT_DIR"
' "$C" "$T" 2>&1)"
r1="$(printf '%s\n' "$rec" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r1" | cut -d'|' -f17)" = "com.android.systemui:48:50,com.new.app:6:30,com.instagram.android:4:4000" ] \
  || f "column 17 wrong (worst first, a package new today counted from zero): $r1"
# g3: old.app went backwards (pruned) - the whole row is skipped like before, no column to check.
[ "$(printf '%s\n' "$rec" | grep -c '|active|')" = 1 ] || f "a pruned day must still skip the row: $rec"
printf '%s\n' "$rec" | grep -q '^\.jank_pkg_prev$' || f "per-package baseline not kept: $rec"
printf '%s\n' "$rec" | grep -q '^\.jank_pkg_now$' && f "per-package scratch file left behind: $rec"
# Screen off drops the baseline with the totals.
LK_OUT_DIR="$T/c" sh -c '. "$0" >/dev/null 2>&1; lk_capture_jank_row idle 0' "$C"
[ -e "$T/c/.jank_pkg_prev" ] && f "per-package baseline survived a screen-off"

# --- 4. asbdiag: per app while the report runs -------------------------------------------------
sed -n '/^# asb_gfx_pkg_begin$/,/^# asb_gfx_pkg_end$/p' "$ROOT/tools/asb_diag.sh" > "$T/gp.sh"
[ -s "$T/gp.sh" ] || f "asbdiag has no asb_gfx_pkg block"
a="$(sh -c '. "$1"; asb_gfx_pkg < "$2"' x "$T/gp.sh" "$T/g1" | sort)"
[ "$a" = "$(printf 'com.android.systemui 1000 100\ncom.instagram.android 5000 10\ncom.old.app 900 90')" ] || f "asb_gfx_pkg: $a"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(asb_gfx_pkg < "$2")" "$(asb_gfx_pkg < "$3")" 40' x "$T/gp.sh" "$T/g1" "$T/g2")"
printf '%s\n' "$d" | grep -q '^while this report ran (40 s), janky frames by app: com.android.systemui 48 of 50 frames (1.20/s)  ·  com.new.app 6 of 30 frames (0.15/s)  ·  com.instagram.android 4 of 4000 frames (0.10/s)$' \
  || f "asbdiag per-app line: $d"
printf '%s\n' "$d" | grep -q '^steady: com.android.systemui missed 48 of the 50 frames it drew - about 1.2 a second' || f "asbdiag steady line: $d"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(asb_gfx_pkg < "$2")" "$(asb_gfx_pkg < "$3")" 3' x "$T/gp.sh" "$T/g1" "$T/g2")"
[ -z "$d" ] || f "asbdiag printed a 3-second window: $d"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(asb_gfx_pkg < "$2")" "$(asb_gfx_pkg < "$2")" 40' x "$T/gp.sh" "$T/g1")"
[ -z "$d" ] || f "asbdiag printed a window with nothing drawn (screen off): $d"
grep -q '_gfx_run0="$(dumpsys graphicsstats 2>/dev/null | asb_gfx_pkg)"' "$ROOT/tools/asb_diag.sh" || f "asbdiag does not read the counters at its start"
grep -q 'asb_gfx_run_delta "$_gfx_run0" "$_gfx_run1"' "$ROOT/tools/asb_diag.sh" || f "asbdiag does not compare them in 7c"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

[ "$fail" = 0 ] && echo "PASS jank floor: janky/s and frame-rate bands, the floor and who draws it, asbdiag per app while it runs"
exit "$fail"
