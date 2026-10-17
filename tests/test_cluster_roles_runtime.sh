#!/bin/sh
# Runtime (fix146): the capture judges the cores the governor calls main, and says which.
#
# 1. The jank trace took the lowest and the highest policy for "main" and "prime". On a
#    1+3+2+1 part (CPH2691, SM8650: policies 0/2/5/7) "main" was the A520 pair, which runs
#    no UI - every "main cores at the ASB ceiling" line of those captures described the
#    wrong cores. Main and prime now come from the governor's slot_policy_ids.
# 2. The report names them where it is not the obvious pair, and the throttle split calls
#    slot 0 "little" there instead of "main".
# 3. The per-app table went to the app with the most frames only; on PLQ110 capture 28616
#    that was the app store while "LIGHT_IDLE 25.6% janky" was YouTube playing untouched.
#    The app in front with the most janky frames gets its own table.
# 4. asbdiag called policy0 of a 6+2 part "little".
# The REAL functions run here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL cluster roles: $*" >&2; fail=1; }

# --- 1. roles from the governor's map --------------------------------------------------------
roles() { printf 'slot_policy_ids=%s\n' "$1" > "$T/st"; ASB_LK_STATE_FILE="$T/st" sh -c '. "$0" >/dev/null 2>&1; lk_cluster_roles' "$C"; }
[ "$(roles 0,2,7)" = "2 7 0" ] || f "1+3+2+1 map: '$(roles 0,2,7)' (want main 2, prime 7, little 0)"
[ "$(roles 0,6,-1)" = "0 6 -" ] || f "6+2 map: '$(roles 0,6,-1)' (want main 0, prime 6)"
: > "$T/st"
[ -z "$(ASB_LK_STATE_FILE="$T/st" sh -c '. "$0" >/dev/null 2>&1; lk_cluster_roles' "$C")" ] || f "roles invented with no map"

# --- 2. the recorder measures policy2, not policy0, on a 4-cluster part ----------------------
for p in 0 2 5 7; do mkdir -p "$T/cpufreq/policy$p/stats"; done
# policy0 (little) idles far below its ceiling; policy2 (main) sits at it the whole interval.
echo 1017600 > "$T/cpufreq/policy0/scaling_max_freq"; echo 364800 > "$T/cpufreq/policy0/scaling_cur_freq"
echo 1497600 > "$T/cpufreq/policy2/scaling_max_freq"; echo 1497600 > "$T/cpufreq/policy2/scaling_cur_freq"
echo 1497600 > "$T/cpufreq/policy5/scaling_max_freq"; echo 1497600 > "$T/cpufreq/policy5/scaling_cur_freq"
echo 1593600 > "$T/cpufreq/policy7/scaling_max_freq"; echo 480000  > "$T/cpufreq/policy7/scaling_cur_freq"
printf '364800 1000\n1017600 0\n' > "$T/cpufreq/policy0/stats/time_in_state"
printf '499200 0\n1497600 1000\n' > "$T/cpufreq/policy2/stats/time_in_state"
printf '480000 1000\n1593600 0\n' > "$T/cpufreq/policy7/stats/time_in_state"
printf 'state=MODERATE\ntouch_starts=1\nslot_policy_ids=0,2,7\n' > "$T/st4"
gfx() { printf 'Package: com.x\nStats since: 1000ns\nTotal frames rendered: %s\nJanky frames: %s (1.00%%)\nNumber Frame deadline missed: %s\nNumber Slow UI thread: 0\nNumber High input latency: 0\n' "$2" "$3" "$3" > "$1"; }
gfx "$T/g1" 1000 10; gfx "$T/g2" 3000 50
mkdir -p "$T/c"
rec="$(LK_OUT_DIR="$T/c" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" ASB_LK_STATE_FILE="$T/st4" T="$T" sh -c '
  . "$0" >/dev/null 2>&1
  lk_jank_trace_header
  ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  printf "499200 0\n1497600 2000\n" > "$T/cpufreq/policy2/stats/time_in_state"
  printf "364800 2000\n1017600 0\n" > "$T/cpufreq/policy0/stats/time_in_state"
  printf "480000 2000\n1593600 0\n" > "$T/cpufreq/policy7/stats/time_in_state"
  ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
' "$C" 2>&1)"
r="$(printf '%s\n' "$rec" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r" | cut -d'|' -f6)" = 1 ] || f "main_at_cap not from policy2 (at its ceiling): $r"
[ "$(printf '%s' "$r" | cut -d'|' -f14)" = 100 ] || f "main_cap_pct not from policy2 (100% at the ceiling): $r"
[ "$(printf '%s' "$r" | cut -d'|' -f7)" = 0 ] || f "prime_at_cap not from policy7: $r"
L="$T/c/cluster_layout.txt"
[ -s "$L" ] || f "no cluster_layout.txt"
grep -qx 'policies=0 2 5 7' "$L" || f "layout policies: $(cat "$L" 2>/dev/null)"
grep -qx 'main=policy2' "$L" && grep -qx 'prime=policy7' "$L" && grep -qx 'little=policy0' "$L" || f "layout roles: $(cat "$L" 2>/dev/null)"
# A 6+2 part: no little line, policy0 is main.
mkdir -p "$T/c2" "$T/cf2/policy0" "$T/cf2/policy6"
printf 'slot_policy_ids=0,6,-1\n' > "$T/st2"
LK_OUT_DIR="$T/c2" ASB_LK_CPUFREQ_ROOT="$T/cf2" ASB_LK_STATE_FILE="$T/st2" sh -c '. "$0" >/dev/null 2>&1; lk_jank_trace_header' "$C"
grep -qx 'main=policy0' "$T/c2/cluster_layout.txt" && ! grep -q '^little=' "$T/c2/cluster_layout.txt" || f "6+2 layout: $(cat "$T/c2/cluster_layout.txt" 2>/dev/null)"

# --- 3. report: names the clusters on a 4-cluster part only --------------------------------
J="$T/c/jank_trace.tsv"
i=0
row() {   # state touches frames janky front pkgs
  i=$((i + 1))
  printf '%s|t|active|%s|48|1|0|%s|%s|%s|%s|5|1|70|0|%s|%s\n' "$i" "$1" "$2" "$3" "$4" "$4" "$5" "$6" >> "$J"
}
for k in 1 2 3 4 5 6; do row MODERATE 2 9000 30 com.heytap.market "com.heytap.market:28:8800"; done
for k in 1 2; do row MODERATE 0 3000 0 com.heytap.market "-"; done
for k in 1 2 3; do row MODERATE 0 600 130 com.google.android.youtube "com.google.android.youtube:128:590"; done
for k in 1 2 3 4; do row LIGHT_IDLE 0 500 135 com.google.android.youtube "com.google.android.youtube:134:495"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/c" 2>&1)"
printf '%s\n' "$out" | grep -q '^main cores below = policy2 and policy5 (the middle clusters, under one ceiling), prime = policy7; the little cluster (policy0) runs no UI and is not in these lines.$' \
  || f "4-cluster layout line: $out"
printf '%s\n' "$out" | grep -q '^within com.heytap.market (most frames), by ASB state and touch:$' || f "most-frames table: $out"
printf '%s\n' "$out" | grep -q '^within com.google.android.youtube (most janky frames), by ASB state and touch:$' || f "no table for the app with the most janky frames: $out"
printf '%s\n' "$out" | awk '/^within com.google.android.youtube/ { f = 1; next } /^within |^  Compare/ { f = 0 } f' > "$T/yt"
grep -qE '^  MODERATE +no +3 +1800 +21\.7% +2\.71$' "$T/yt" || f "YouTube MODERATE row: $(cat "$T/yt")"
grep -qE '^  LIGHT_IDLE +no +4 +2000 +27\.0% +2\.81$' "$T/yt" || f "YouTube LIGHT_IDLE row: $(cat "$T/yt")"
[ "$(printf '%s\n' "$out" | grep -c '^  Compare states inside one app')" = 1 ] || f "the caveat is printed once: $out"
printf '%s\n' "$out" | grep -q '^  touch = a touch began after 3 s without one; steady typing or scrolling can read no.$' || f "touch column not explained: $out"
# Same app most frames and most janky: one table. 6+2 layout: no cluster line.
mkdir -p "$T/d"; J="$T/d/jank_trace.tsv"; i=0; echo "# h" > "$J"
cp "$T/c2/cluster_layout.txt" "$T/d/"
for k in 1 2 3; do row MODERATE 1 4000 40 com.a "com.a:40:4000"; done
for k in 1 2; do row LIGHT_IDLE 0 300 20 com.a "com.a:20:300"; done
for k in 1 2; do row MODERATE 1 200 5 com.b "com.b:5:200"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/d" 2>&1)"
[ "$(printf '%s\n' "$out" | grep -c '^within ')" = 1 ] || f "two tables for one app: $out"
printf '%s\n' "$out" | grep -q '^main cores below' && f "cluster line on a 6+2 part: $out"

# --- 4. throttle split: slot 0 is the little pair there --------------------------------------
printf '1|active|p0_max=1/2|p6_max=1/2|cpu_temp=40|surface=33|cap_owner=asb|main_by=asb_trim|prime_by=vendor\n' > "$T/thr"
out="$(LK_OUT_DIR="$T/c" sh -c '. "$0" >/dev/null 2>&1; lk_emit_cap_cause_split "$1"' "$C" "$T/thr")"
printf '%s\n' "$out" | grep -qE '^  little: asb_trim 1$' || f "4-cluster split still says main: $out"
printf '%s\n' "$out" | grep -q 'little = policy0, the efficiency cores' || f "little note: $out"
out="$(LK_OUT_DIR="$T/d" sh -c '. "$0" >/dev/null 2>&1; lk_emit_cap_cause_split "$1"' "$C" "$T/thr")"
printf '%s\n' "$out" | grep -qE '^  main: +asb_trim 1$' || f "6+2 split: $out"
grep -q 'the LPM feature or the cellular power policy (radio_policy_enable, off by default) is off' "$ROOT/tools/logkit/asb_log_full_day.sh" \
  || f "an empty modem LPM line still prints nothing"

# --- 5. asbdiag: policy0 of a 6+2 part is "main" ---------------------------------------------
D="$ROOT/tools/asb_diag.sh"
grep -q '_tier="little"; \[ "$_npol" -eq 2 \] && _tier="main"' "$D" || f "asbdiag policy list calls the six main cores little"
grep -q '\[ "$_ncl" -eq 2 \] && _role=main' "$D" || f "asbdiag slot map calls the six main cores little"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

[ "$fail" = 0 ] && echo "PASS cluster roles: main/prime from the governor's map, named in the report, a table for the jankiest app, asbdiag labels"
exit "$fail"
