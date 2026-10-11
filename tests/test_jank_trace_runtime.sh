#!/bin/sh
# Runtime (fix121): the full-day capture measures UI smoothness - HWUI frame deltas from
# dumpsys graphicsstats between screen-on polls, tagged with the ASB state and whether the
# clusters sat at ASB's ceiling - and the report puts janky% next to each.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL jank trace: $*" >&2; fail=1; }
mkdir -p "$T/out" "$T/cpufreq/policy0" "$T/cpufreq/policy6"

# Two packages; the second also has a block from an older day (counted in the totals too).
gfx() {   # $1 file  $2 sysui frames  $3 sysui janky  $4 app frames  $5 app janky  $6 app deadline
  cat > "$1" <<EOF

Package: com.android.systemui
Version: 36
Stats since: 1000ns
Stats end: 2000ns
Total frames rendered: $2
Janky frames: $3 (1.00%)
Janky frames (legacy): 999 (9.99%)
50th percentile: 5ms
Number Missed Vsync: 0
Number High input latency: 1
Number Slow UI thread: 2
Number Slow bitmap uploads: 0
Number Slow issue draw commands: 0
Number Frame deadline missed: $3
HISTOGRAM: 5ms=10 6ms=2
Package: com.google.android.youtube
Version: 1
Stats since: 1000ns
Stats end: 2000ns
Total frames rendered: $4
Janky frames: $5 (2.00%)
Janky frames (legacy): 888 (9.99%)
Number Missed Vsync: 0
Number High input latency: 0
Number Slow UI thread: 3
Number Slow bitmap uploads: 0
Number Slow issue draw commands: 0
Number Frame deadline missed: $6
Package: com.google.android.youtube
Version: 1
Stats since: 500ns
Stats end: 900ns
Total frames rendered: 7000
Janky frames: 70 (1.00%)
Number Frame deadline missed: 70
Number Slow UI thread: 5
Number High input latency: 1
EOF
}
gfx "$T/g1" 1000 10 5000 50 60
gfx "$T/g2" 1600 16 6400 150 180     # +600/+6 and +1400/+100 -> 2000 frames, 106 janky
gfx "$T/g3" 1700 17 6500 151 181     # +100/+1 and +100/+1 -> 200 frames, 2 janky
gfx "$T/g4"  100  1 6500 151 181     # sysui went backwards: pruned day, no row

printf 'state=MODERATE\ntouch_starts=10\n' > "$T/state1"
printf 'state=MODERATE\ntouch_starts=14\n' > "$T/state2"
printf 'state=LIGHT_IDLE\ntouch_starts=14\n' > "$T/state3"
echo 1555200 > "$T/cpufreq/policy0/scaling_max_freq"; echo 1555200 > "$T/cpufreq/policy0/scaling_cur_freq"
echo 1862400 > "$T/cpufreq/policy6/scaling_max_freq"; echo  768000 > "$T/cpufreq/policy6/scaling_cur_freq"

out="$(LK_OUT_DIR="$T/out" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  lk_jank_trace_header
  ASB_LK_STATE_FILE="$T/state1" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g3" lk_capture_jank_row audio_bt_scr 1
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g4" lk_capture_jank_row audio_bt_scr 1
  # Screen off resets the baseline: the next screen-on poll writes no row.
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g4" lk_capture_jank_row idle 0
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  echo "--- trace"; cat "$LK_OUT_DIR/jank_trace.tsv"
  echo "--- report"; lk_emit_jank_summary
' "$C" "$T" 2>&1)"

rows="$(printf '%s\n' "$out" | sed -n '/^--- trace/,/^--- report/p' | grep -v '^#' | grep -c '|')"
[ "$rows" = 2 ] || f "expected 2 interval rows (pruned day and screen-off must not write one), got $rows: $out"
r1="$(printf '%s\n' "$out" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r1" | cut -d'|' -f4)" = MODERATE ] || f "same state at both ends must be named: $r1"
[ "$(printf '%s' "$r1" | cut -d'|' -f6-13)" = "1|0|4|2000|106|126|0|0" ] || f "deltas or tags wrong: $r1"
r2="$(printf '%s\n' "$out" | grep '|audio_bt_scr|' | head -1)"
[ "$(printf '%s' "$r2" | cut -d'|' -f4)" = mixed ] || f "a state change inside the interval must read mixed: $r2"
[ "$(printf '%s' "$r2" | cut -d'|' -f9-10)" = "200|2" ] || f "second interval deltas wrong: $r2"
printf '%s\n' "$out" | grep -q 'all screen-on intervals: 2  frames 2200  janky 4.9%' || f "overall janky share wrong: $out"
printf '%s\n' "$out" | grep -qE '^MODERATE +1 +2000 +5.3%' || f "per-state line wrong: $out"
printf '%s\n' "$out" | grep -q 'main cores at the ASB ceiling (end of interval): yes 4.9% of 2200 frames' || f "ceiling correlation missing: $out"

# fix125: time at the ceiling from time_in_state, and the app in front from the top-app cgroup.
mkdir -p "$T/cpufreq/policy0/stats" "$T/cpufreq/policy6/stats" "$T/proc/2001" "$T/proc/1000" "$T/out2"
printf '384000 1000\n1555200 500\n' > "$T/cpufreq/policy0/stats/time_in_state"
printf '768000 900\n1862400 100\n' > "$T/cpufreq/policy6/stats/time_in_state"
printf 'Name:\tx\nUid:\t10234\t10234\t10234\t10234\n' > "$T/proc/2001/status"; echo 0 > "$T/proc/2001/oom_score_adj"
printf 'com.instagram.android\0' > "$T/proc/2001/cmdline"
printf 'Name:\tx\nUid:\t1000\t1000\t1000\t1000\n' > "$T/proc/1000/status"; echo -900 > "$T/proc/1000/oom_score_adj"
printf 'system_server\0' > "$T/proc/1000/cmdline"
printf '1000\n2001\n' > "$T/topapp"
out2="$(LK_OUT_DIR="$T/out2" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" ASB_LK_TOPAPP_PROCS="$T/topapp" ASB_LK_PROC_ROOT="$T/proc" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  lk_jank_trace_header
  ASB_LK_STATE_FILE="$T/state1" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  # 4 s more at 1555200 (the ceiling), 1 s at 384000 on the main cores; prime idle.
  printf "384000 1100\n1555200 900\n" > "$T/cpufreq/policy0/stats/time_in_state"
  printf "768000 1400\n1862400 100\n" > "$T/cpufreq/policy6/stats/time_in_state"
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
  echo "--- report"; lk_emit_jank_summary
' "$C" "$T" 2>&1)"
r3="$(printf '%s\n' "$out2" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r3" | cut -d'|' -f14-16)" = "80|0|com.instagram.android" ] || f "time-at-ceiling or app columns wrong: $r3"
printf '%s\n' "$out2" | grep -q 'main cores, share of the interval AT the ceiling ->  >=60%: 5.3% of 2000' || f "time-at-ceiling split missing: $out2"
printf '%s\n' "$out2" | grep -qE '^com.instagram.android +2000 +5.3%' || f "per-app line missing: $out2"
printf '%s\n' "$out2" | grep -q 'high-input-latency events:' || f "input latency not shown as a count"
printf '%s\n' "$out2" | grep -q 'high input latency [0-9.]*%' && f "input latency still shown as a share of frames"

# asbdiag: today's blocks only (the newest "Stats since"), totals and the most janky apps.
sed -n '/^# asb_gfx_today_begin$/,/^# asb_gfx_today_end$/p' "$ROOT/tools/asb_diag.sh" > "$T/gfx_today.sh"
[ -s "$T/gfx_today.sh" ] || f "asbdiag has no asb_gfx_today block"
# Field shape (fix125): each process's block starts when it first drew - different starts on
# the same UTC day must all count; yesterday's block must not.
cat > "$T/gd" <<'EOF'
Package: com.old.app
Stats since: 1791590400000000000ns
Total frames rendered: 90000
Janky frames: 9000 (10.00%)
Number Slow UI thread: 10
Number High input latency: 0
Package: com.android.systemui
Stats since: 1791712801000000000ns
Total frames rendered: 8000
Janky frames: 80 (1.00%)
Number Slow UI thread: 40
Number High input latency: 8
Package: com.instagram.android
Stats since: 1791716455000000000ns
Total frames rendered: 2000
Janky frames: 120 (6.00%)
Number Slow UI thread: 60
Number High input latency: 2
Package: com.tiny.app
Stats since: 1791714000000000000ns
Total frames rendered: 100
Janky frames: 50 (50.00%)
Number Slow UI thread: 0
Number High input latency: 0
EOF
gd="$(sh -c '. "$1"; asb_gfx_today < "$2"' x "$T/gfx_today.sh" "$T/gd" 2>&1)"
printf '%s\n' "$gd" | grep -q '^frames 10100  ·  janky 2.5%  ·  slow UI thread 1.0%  ·  high-input-latency events 10$' || f "asbdiag totals wrong (older day must be left out, latency is a count): $gd"
printf '%s\n' "$gd" | grep -q '^most janky frames: com.instagram.android 120 (6.0% of 2000)  ·  com.android.systemui 80 (1.0% of 8000)$' || f "asbdiag ranking wrong (under 300 frames must be left out): $gd"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

# The full-day recorder calls it and prints the section.
grep -q '^lk_jank_trace_header$' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "trace header not created by the full-day capture"
grep -q 'lk_capture_jank_row "$_phase" "${_dscr:-0}"' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "rows not captured per poll"
grep -q '^    lk_emit_jank_summary$' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "report does not print the section"

[ "$fail" = 0 ] && echo "PASS jank trace: frame deltas per screen-on interval, state and ceiling tags, report"
exit "$fail"
