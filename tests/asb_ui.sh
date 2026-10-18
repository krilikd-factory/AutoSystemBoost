#!/usr/bin/env bash
# ASB host tests: WebUI, log kit, asbdiag and capture comparison.
#
# Each test is a function t_<name> whose body runs in its own subshell, exactly as the
# standalone script it used to be; the C fixtures it builds are the functions _c_<name>.
#   bash tests/asb_ui.sh                 run every test in this file
#   bash tests/asb_ui.sh NAME [NAME...]  run the named tests
#   bash tests/asb_ui.sh --list          list the tests
#   bash tests/asb_ui.sh --source NAME   print an embedded C fixture
# tools/asb_full_regression.sh runs every test of every tests/asb_*.sh in parallel.

t_asbdiag_report_host_runtime() (
# Runtime (fix151): asbdiag says which janky frames are its own output scrolling.
#
# A CPH2691 report run from Termux: "com.termux 663 of 676 frames (20.72/s)" and "steady:
# com.termux missed 663 of the 676 frames ... while you only waited for this report". An
# outside audit read that as "over 90% UI lag in Termux, up to 20 a second" and proposed CPU
# boosts and big-core whitelists for it. Termux was drawing the report. The REAL functions
# run on a fake /proc and cpuset: the app in front at the start is found from the top-app
# group (uid >= 10000, oom_score_adj 0), and its line says it is the report's own window.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL asbdiag report host: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^# asb_gfx_pkg_begin$/,/^# asb_gfx_pkg_end$/p' "$D" > "$T/f.sh"
grep -q '^asb_report_host() {' "$T/f.sh" || fail "no host lookup in the testable block"
mkdir -p "$T/cpuset/top-app"
mk() {   # pid uid oom cmdline
  mkdir -p "$T/proc/$1"
  printf 'Name:\tx\nUid:\t%s\t%s\t%s\t%s\n' "$2" "$2" "$2" "$2" > "$T/proc/$1/status"
  echo "$3" > "$T/proc/$1/oom_score_adj"
  printf '%s\000' "$4" > "$T/proc/$1/cmdline"
}
mk 100 1000 0 system_server
mk 200 10123 200 com.google.android.inputmethod.latin
mk 300 10234 0 /data/data/com.termux/files/usr/bin/bash
mk 400 10234 0 com.termux
printf '100\n200\n300\n400\n' > "$T/cpuset/top-app/cgroup.procs"
h="$(ASB_PROC_ROOT="$T/proc" ASB_CPUSET_ROOT="$T/cpuset" sh -c '. "$1"; asb_report_host' x "$T/f.sh")"
[ "$h" = com.termux ] || fail "host: '$h', want com.termux"
printf 'com.termux 1000 10\ncom.android.systemui 2000 20\n' > "$T/a"
printf 'com.termux 1676 673\ncom.android.systemui 3144 44\n' > "$T/b"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 com.termux' x "$T/f.sh" "$T/a" "$T/b")"
printf '%s\n' "$d" | grep -q 'com.termux 663 of 676 frames (20.72/s, the window this report is printed in)' || fail "per-app line: $d"
printf '%s\n' "$d" | grep -q '^host: com.termux missed 663 of the 676 frames it drew - the report scrolling in it, not a lag$' || fail "host line: $d"
printf '%s\n' "$d" | grep -q '^steady:' && fail "the report's own window called a steady redraw: $d"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 com.rifsxd.ksunext' x "$T/f.sh" "$T/a" "$T/b")"
printf '%s\n' "$d" | grep -q '^steady: com.termux missed 663' || fail "another app in front still gets the steady verdict: $d"
grep -q 'asb_gfx_run_delta "$_gfx_run0" "$_gfx_run1" "$(( $(date +%s) - ${_gfx_run0_t:-0} ))" "$_gfx_host"' "$D" || fail "7c does not pass the host"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS asbdiag report host: the window the report prints into is named, not read as lag"
)

t_asbdiag_settings_summary_runtime() (
# Runtime (fix159): asbdiag ends with "your settings vs what is live" - what the user changed
# in the WebUI (name, default -> value), what the device really has (one line per live check,
# the system settings Android refused, what waits for a reboot) and a verdict that reads FAIL,
# not PASS.
#
# Field reports compared "30 PASS" on one phone with "11 PASS" on another and read the second
# as a broken install; the difference was how many tweaks were switched on. The section is cut
# out of the REAL tools/asb_diag.sh (and the REAL V()) and run against the REAL WebUI, shipped
# config and key ownership registry, with a config, a boot-time copy and an apply ledger made
# up here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL asbdiag settings summary: $*" >&2; fail=1; }
cmp -s "$D" "$ROOT/system/bin/asbdiag" || f "system/bin/asbdiag is not a copy of tools/asb_diag.sh"
awk '/^SEC "11. YOUR SETTINGS/ { on = 1 } /^P "  PASS=\$PASS/ { exit } on' "$D" > "$T/sec.sh"
grep -q 'WHAT YOU CHOSE' "$T/sec.sh" || { echo "FAIL asbdiag settings summary: section 11 not found" >&2; exit 1; }
awk '/^V\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$D" > "$T/v.sh"
grep -q 'CHK_LIST=' "$T/v.sh" || f "V() does not record its checks"

mkdir -p "$T/mod/config" "$T/mod/webroot" "$T/state"
cp "$ROOT/config/governor.conf.shipped" "$ROOT/config/key_ownership.tsv" "$T/mod/config/"
cp "$ROOT/webroot/index.html" "$T/mod/webroot/"
S="$T/mod/config/governor.conf.shipped"
sed -e 's/^dsp_loudness=.*/dsp_loudness=25/' -e 's/^CAMERA_LEVEL=.*/CAMERA_LEVEL=10/' \
    -e 's/^media_vol_steps=.*/media_vol_steps=30/' -e 's/^heavy_gpu_enter=.*/heavy_gpu_enter=99/' "$S" > "$T/conf"
grep -q '^dsp_loudness=25$' "$T/conf" && grep -q '^media_vol_steps=30$' "$T/conf" && grep -q '^heavy_gpu_enter=99$' "$T/conf" \
  || { echo "FAIL asbdiag settings summary: shipped config lacks the keys this test edits" >&2; exit 1; }
cp "$T/conf" "$T/boot_same"
cp "$S" "$T/boot_old"
cat > "$T/state/apply_ledger" <<'L'
1|settings|ntp_server|time.example|time.example|time.example|already_set||
2|settings|network_recommendations_enabled|0|1|1|not_writable|write rejected|
3|settings|ram_expand_switch_state|0|1|0|applied||
4|reconcile|uclamp.max|100|0|100|applied||
L
run() {
  cat > "$T/run.sh" <<EOF
P() { printf '%s\n' "\$1"; }
SEC() { P "== \$1"; }
NOTE() { P "  (i) \$1"; }
MODDIR="$T/mod"; CONF="$1"; ASB_CONFIG_STATE="$T/state"; ASB_DIAG_BOOT_CONF="$2"
PASS=0; FAIL=0; NA=0; OFFN=0; OFF_LIST=""; CHK_LIST=""
. "$T/v.sh"
V "DSP gain applied (persist.asb.dsp.gain_mb)" 2500 2500 eq
V "camera grade live" 10 "$3" eq
. "$T/sec.sh"
EOF
  sh "$T/run.sh" 2>&1
}

o="$(run "$T/conf" "$T/boot_old" 3)"
printf '%s\n' "$o" | grep -q '^  A. WHAT YOU CHOSE' || f "part A missing"
printf '%s\n' "$o" | awk '/^     Audio$/ { a = 1; next } /^     [A-Z]/ { a = 0 } a && /DSP Loudness/ && /0 -> 25/ && /\[dsp_loudness\]/ { ok = 1 } END { exit !ok }' \
  || f "DSP Loudness not listed under Audio as 0 -> 25 with its key: $o"
printf '%s\n' "$o" | grep -q 'Camera Grade .*0 -> 10 .*\[CAMERA_LEVEL\]' || f "camera grade change not listed"
printf '%s\n' "$o" | grep -q 'heavy_gpu_enter' && f "an internal engine key listed as a user choice"
printf '%s\n' "$o" | grep -Eq '^     3 of [0-9]+ WebUI settings changed' || f "changed-count line wrong: $o"
printf '%s\n' "$o" | grep -q 'Media Volume Steps .*stock -> 30  (waits for a reboot)' || f "reboot-scoped change not flagged"
printf '%s\n' "$o" | grep -q '^     waiting for a reboot (changed after this boot, read only at boot):$' || f "waiting-for-reboot heading missing"
printf '%s\n' "$o" | grep -q '^       Media Volume Steps: stock -> 30   \[media_vol_steps\]$' || f "waiting key not named"
printf '%s\n' "$o" | grep -q '^       Camera Grade: 0 -> 10   \[CAMERA_LEVEL\]$' || f "reboot-scoped camera grade not listed as waiting"
printf '%s\n' "$o" | grep -q 'DSP Loudness:' && f "a setting applied live listed as waiting for a reboot"
printf '%s\n' "$o" | grep -q '^     \[PASS\] DSP gain applied (persist.asb.dsp.gain_mb)  ->  2500$' || f "PASS check not echoed in part B"
printf '%s\n' "$o" | grep -q '^     \[FAIL\] camera grade live  ->  3$' || f "FAIL check not echoed in part B"
printf '%s\n' "$o" | grep -q 'applied 1 · already set 1 · refused by Android 1' || f "ledger totals wrong (reconcile rows must not count): $o"
printf '%s\n' "$o" | grep -q 'refused, not in effect: settings/network_recommendations_enabled (wanted 0, device keeps 1)' || f "refused key not named"
printf '%s\n' "$o" | grep -q '^     FAIL=1 - these did not take effect' || f "verdict does not name the failure count"
printf '%s\n' "$o" | grep -q '^       camera grade live: want 10, live 3$' || f "failing check not listed in the verdict"
printf '%s\n' "$o" | grep -q 'Read FAIL, not PASS' || f "PASS-count explanation missing"

o="$(run "$T/conf" "$T/boot_same" 10)"
printf '%s\n' "$o" | grep -q '^     waiting for a reboot: nothing' || f "nothing pending not said when the boot copy matches"
printf '%s\n' "$o" | grep -q '(waits for a reboot)' && f "a change already booted with flagged as waiting"
printf '%s\n' "$o" | grep -q '^     FAIL=0 - everything this report can check for your settings is in effect.$' || f "clean verdict missing"

o="$(run "$S" "$T/missing" 10)"
printf '%s\n' "$o" | grep -q '^     nothing - every setting is at its shipped default$' || f "all-default config not described: $o"
printf '%s\n' "$o" | grep -q '^     waiting for a reboot: unknown' || f "missing boot copy not reported as unknown"
printf '%s\n' "$o" | grep -q 'not an install error' || f "default-is-not-an-error line missing"

grep -q 'cp -f "$MODDIR/config/governor.conf" /dev/.asb_profile_state/governor.boot.conf' "$ROOT/post-fs-data.sh" \
  || f "post-fs-data does not keep the config this boot used"
[ "$fail" = 0 ] && echo "PASS asbdiag settings summary: your choices, what is live, refused writes, pending reboots and a FAIL-based verdict"
exit "$fail"
)

t_capture_compare_runtime() (
# Runtime (fix152): the host comparison of field logs, build against build.
#
# Asked for: "after the tests I will send a new archive of logs from different users - compare
# how much better it got". The REAL tool reads full-day captures and asbdiag reports from
# folders and zips (a zip inside a zip too), counts a capture sent twice once, saves the
# figures (--json) and compares a new set with them per phone model (--baseline): lower drain
# and fewer janky frames read "better", a figure the report marks '~' is not compared.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOL="$ROOT/tools/asb_capture_compare.py"
fail() { echo "FAIL capture compare: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP capture compare: no python3"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cap() {   # dir model start night_pct night_awake idle_pct janky_s li_s cpu_ms wifi_med
  mkdir -p "$1"
  printf 'model:           %s\nmodule_version:  V65-debug%s\noem_build:       X\n' "$2" "$3" > "$1/env.txt"
  printf '# phase timeline\n%s|2026-10-20 08:00:00|active|capture_start\n' "$3" > "$1/phase_timeline.txt"
  printf 'governor_cpu_ms=%s\ngovernor_uptime_s=36000\n' "$9" > "$1/snapshot_1.txt"
  cat > "$1/_full_day_report.txt" <<R
 capture: 24h target, 1200 min elapsed
===== UI SMOOTHNESS (screen-on, HWUI frames of every app) =====
all screen-on intervals: 400  frames 900000  janky 4.0%  deadline missed 4.0%  slow UI thread 2.0%
janky frames per second on screen: $7
ASB state        intervals    frames    janky  janky/s
MODERATE               278    756613     3.0%     1.70
LIGHT_IDLE              65     44071    28.1%     $8

steady floor: 1.11 janky frames a second while almost nothing was drawn (under 5 frames/s),
1.73 a second in the busy intervals (20 frames/s and more). Something misses a deadline about
screen-on samples 472: prime cores working in 14%, main cores in 81%
===== WI-FI LEAVE (the leave-bad-Wi-Fi watcher, this capture) =====
releases: 3 (out of range 2, no internet 1) - Wi-Fi given back after the window: 3, could not disable: 0
first failing reading to the release: median ${10} s, longest 12 s (3 release(s))
===== PER-PHASE SUMMARY =====

phase            dur_min   d_pct    pct/h     mA  rmnetMiB     cpuT    surfT     p6MHz    gpu%  throttle   awake%
active             142.2      26   10.97     297    1420.4       39       35       917       7        39     98.1
idle               126.3       4    $6     182     106.1       34       36       806       5         0     23.5
sleep              553.9       6    0.65     155     113.2       36       38       768       4         0      5.1
night(longest)     538.2       5     $4    154         -       37       39       768       -         -      $5

Legend: x
R
}
cap "$T/old/a" CPH2745 1000 0.56 4.0 1.90 2.08 3.92 18000 20
cap "$T/old/b" CPH2691 2000 0.90 9.0 5.50 1.94 2.50 18000 20
cap "$T/new/a" CPH2745 3000 0.44 3.0 1.95 1.80 2.00 14400 6
cap "$T/new/b" CPH2691 4000 0.95 9.5 3.36~ 1.94 2.50 18000 6
( cd "$T/new" && mkdir -p z && cp -r a z/dup && cd z && python3 -c "
import zipfile,os
with zipfile.ZipFile('inner.zip','w') as z:
    for r,_,fs in os.walk('dup'):
        for f in fs: z.write(os.path.join(r,f))
with zipfile.ZipFile('../outer.zip','w') as z: z.write('inner.zip')
" && cd .. && rm -rf z )
cat > "$T/new/diag.txt" <<'D'
################################################################
#         AutoSystemBoost — GLOBAL SYSTEM DIAGNOSTIC            #
################################################################
 date    : Mon Oct 20 10:00:00 CEST 2026
 device  : OnePlus CPH2745  (OP611FL1)
 version : V65-debug9  (650)
  ASB overhead          : event_wakeups=1 timer_wakeups=2 cpu_ms=14201 over 8 h 36 min = 1.6 s of CPU per hour
    mSafeMediaVolumeState=SAFE_MEDIA_VOLUME_INACTIVE
  (i) net_txqueue=short - live: rmnet_data0=1000 wlan0=256
  (i) doze_trim_whitelist = 1 · trimmed by ASB: 7 · kept (WebUI list): 3 · made exempt by ASB: 1
    audio_remove_volume_limit=1
D
python3 "$TOOL" "$T/old" --json "$T/base.json" --label base > "$T/o1" || fail "baseline run failed"
grep -q '^FULL-DAY CAPTURES (2)$' "$T/o1" || fail "baseline captures: $(head -3 "$T/o1")"
python3 "$TOOL" "$T/new" "$T/new/outer.zip" --baseline "$T/base.json" > "$T/o2" || fail "compare run failed"
grep -q '^FULL-DAY CAPTURES (2)$' "$T/o2" || fail "a capture sent twice (a zip inside a zip) counted twice: $(grep -c CPH2745 "$T/o2")"
grep -q '^night %/h *0.56 *0.44 .*better' "$T/o2" || fail "night not better: $(grep 'night %/h' "$T/o2")"
grep -q '^LIGHT_IDLE janky/s *3.92 *2.00 .*better' "$T/o2" || fail "LIGHT_IDLE jank: $(grep LIGHT "$T/o2")"
grep -q '^Wi-Fi leave median s *20 *6 .*better' "$T/o2" || fail "Wi-Fi leave: $(grep 'Wi-Fi leave' "$T/o2")"
grep -q '^ASB CPU s/h *1.80 *1.44 .*better' "$T/o2" || fail "ASB CPU: $(grep 'ASB CPU s/h' "$T/o2")"
grep -q '^night %/h *0.90 *0.95 .*same' "$T/o2" || fail "a 5% change called a verdict: $(grep 'night %/h' "$T/o2")"
grep -q '^idle %/h *5.50 *- ' "$T/o2" || fail "a '~' figure was compared: $(grep 'idle %/h' "$T/o2")"
grep -q 'wlan0=256' "$T/o2" || fail "the Wi-Fi queue from asbdiag is not shown"
grep -q 'doze trim 7/kept 3/granted 1' "$T/o2" || fail "the doze trim figures from asbdiag are not shown"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['label']=='base' and len(d['captures'])==2" "$T/base.json" || fail "saved figures unreadable"
python3 "$TOOL" "$ROOT/docs/field_baseline" --baseline "$ROOT/docs/field_baseline/fix150.json" >/dev/null || fail "the stored fix150 baseline does not load"
echo "PASS capture compare: field logs read from folders and nested zips, one capture once, build against build per model"
)

t_capture_compare_warm_runtime() (
# Runtime (fix156): the comparison reads how the clusters were used while the phone was warm.
#
# fix156 keeps the main cores level with the prime under Smart's comfort trim and in HEAVY and
# SUSTAINED. What should change in the next round of logs: fewer warm screen-on samples with the
# main ceiling under the prime's, the prime working less, a lower sampled current. The REAL
# tool computes those from the raw traces of a capture (so captures made before the report
# printed them compare too): screen-on samples only, surface 40 C and above, capacities from the
# governor state, hardware maxima from the throttle trace; and the --baseline table names them.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOL="$ROOT/tools/asb_capture_compare.py"
fail() { echo "FAIL capture compare warm: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP capture compare warm: no python3"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cap() {
  d="$T/$1"; mkdir -p "$d"
  printf 'model:           CPH2745\nmodule_version:  V65-debug%s\n' "$2" > "$d/env.txt"
  printf '%s|2026-10-20 08:00:00|active|capture_start\n' "$3" > "$d/phase_timeline.txt"
  printf ' capture: 24h target, 600 min elapsed\n' > "$d/_full_day_report.txt"
  printf 'main_parity_capacity="762,1024"\n' > "$d/snapshot_1.txt"
  printf '# throttle trace\n%s|active|p0_max=1555200/3628800|p6_max=1862400/4608000|cpu_temp=50\n' "$3" > "$d/throttle_trace.txt"
  echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$d/display_trace.txt"
  echo "epoch|datetime|x|x|x|x|x|x|x|x|x|x|p0_cur|p0_max|p6_cur|p6_max|x|x|x|x|x|bat_mA|x|x|x|x|x|x|x|x|x|x|x|x|x|surface_c" > "$d/perf_trace.txt"
}
row() {   # dir epoch screen p0_max p6_cur p6_max mA surface
  echo "$2|d|active|$3|1|1|1|90|1||" >> "$T/$1/display_trace.txt"
  echo "$2|d|||||||||||1|$4|$5|$6||||||$7||||||||||||||$8" >> "$T/$1/perf_trace.txt"
}
cap old 8 1000
e=1000
for i in 1 2 3 4; do row old $e 1 1555200 1862400 1862400 480 44; e=$((e + 20)); done
for i in 1 2; do row old $e 1 1996800 768000 1862400 340 43; e=$((e + 20)); done
row old $e 1 1555200 1862400 1862400 900 33; e=$((e + 20))
row old $e 0 1555200 1862400 1862400 900 45; e=$((e + 20))
cap new 10 5000
e=5000
for i in 1 2 3 4 5; do row new $e 1 1996800 768000 1862400 330 44; e=$((e + 20)); done
row new $e 1 1996800 1862400 1862400 410 42
python3 "$TOOL" "$T/old" --json "$T/base.json" --label old > "$T/o1" 2>&1 || { cat "$T/o1" >&2; fail "tool failed"; }
python3 - "$T/base.json" <<'P' || fail "warm figures of the old capture"
import json, sys
c = json.load(open(sys.argv[1]))["captures"][0]
want = {"warm_on_n": 6, "warm_below_pct": 66.7, "warm_prime_pct": 66.7, "warm_on_ma": 433}
bad = {k: (c.get(k), v) for k, v in want.items() if c.get(k) != v}
if bad:
    print(bad); sys.exit(1)
P
python3 "$TOOL" "$T/new" --baseline "$T/base.json" > "$T/o2" 2>&1 || { cat "$T/o2" >&2; fail "comparison failed"; }
grep -qE '^warm: main under prime % +66\.70 +0\.00 +-66\.70 \(-100%\) +better' "$T/o2" || fail "main-under-prime row: $(cat "$T/o2")"
grep -qE '^warm: prime working % +66\.70 +16\.70 .* better' "$T/o2" || fail "prime row: $(cat "$T/o2")"
grep -qE '^warm screen-on mA +433 +343 .* better' "$T/o2" || fail "current row: $(cat "$T/o2")"
cap cool 9 9000
e=9000
for i in 1 2 3 4 5 6; do row cool $e 1 1555200 1862400 1862400 480 35; e=$((e + 20)); done
python3 "$TOOL" "$T/cool" --json "$T/cool.json" > "$T/o3" 2>&1 || fail "cool capture"
python3 -c "import json,sys; c=json.load(open(sys.argv[1]))['captures'][0]; sys.exit(0 if c['warm_on_n'] is None and c['warm_on_ma'] is None else 1)" "$T/cool.json" || fail "a capture that never got warm produced warm figures"
echo "PASS capture compare warm: warm screen-on samples, main under the prime, prime work and current, from the raw traces"
)

t_cluster_roles_runtime() (
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
)

t_debug_support_contract() (
# Contract: debug WebUI support actions stay debug-gated, bounded and non-overlapping.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
TIMELINE="$ROOT/runtime/asb_boot_timeline.sh"
DIAG="$ROOT/tools/asb_diag.sh"
INSTALLED_DIAG="$ROOT/system/bin/asbdiag"
UI="$ROOT/webroot/index.html"
TMP="$(mktemp -d)"
trap 'if [ -n "${REC_PID:-}" ]; then kill "$REC_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" || { echo "FAIL debug support: missing [$2]" >&2; exit 1; }; }
count_exact() {
  _actual="$(grep -Foc -- "$2" "$1" 2>/dev/null || true)"
  [ "$_actual" -eq "$3" ] || { echo "FAIL debug support: expected $3 [$2], found $_actual" >&2; exit 1; }
}
[ -f "$HELPER" ] || { echo "FAIL debug support: helper missing" >&2; exit 1; }
[ -f "$TIMELINE" ] || { echo "FAIL debug support: boot timeline helper missing" >&2; exit 1; }
[ -f "$DIAG" ] && [ -f "$INSTALLED_DIAG" ] || { echo "FAIL debug support: asbdiag copy missing" >&2; exit 1; }
sh -n "$HELPER"
sh -n "$TIMELINE"
cmp -s "$DIAG" "$INSTALLED_DIAG" || { echo "FAIL debug support: asbdiag copies diverged" >&2; exit 1; }
need "$DIAG" 'BOOT TIMELINE'
need "$DIAG" 'boot_timeline.tsv'

# Execute the actual asbdiag version gate fragment. A prior shell glob used
# [1-9][0-9]*, which requires two digits and therefore hid timeline evidence on
# V64-debug4 even though the recorder had correctly created it.
awk '
  /^_boot_debug=0$/ { capture=1 }
  capture && /^if \[ "\$_boot_debug" = "1" \]; then$/ { exit }
  capture { print }
' "$DIAG" > "$TMP/asbdiag_boot_gate.sh"
[ -s "$TMP/asbdiag_boot_gate.sh" ] || { echo 'FAIL debug support: cannot extract asbdiag boot gate' >&2; exit 1; }
diag_boot_gate() (
  _boot_version="$1"
  . "$TMP/asbdiag_boot_gate.sh"
  printf '%s' "$_boot_debug"
)
for _gate_case in \
  'V64-debug1:1' \
  'V64-debug4:1' \
  'V64-debug10:1' \
  'V64-debug42:1' \
  'V64-debug999999999:1' \
  'V64:0' \
  'V64-debug:0' \
  'V64-debug0:0' \
  'V64-debug4x:0'; do
  _gate_version="${_gate_case%:*}"; _gate_want="${_gate_case##*:}"
  _gate_live="$(diag_boot_gate "$_gate_version")"
  [ "$_gate_live" = "$_gate_want" ] || {
    echo "FAIL debug support: asbdiag boot gate version=$_gate_version want=$_gate_want live=$_gate_live" >&2; exit 1
  }
done

# A release module must refuse both mutations even if someone manufactures a DOM click.
REL="$TMP/release"; mkdir -p "$REL"
printf 'id=AutoSystemBoost\nversion=V65\n' > "$REL/module.prop"
REL_OUT="$(ASB_DEBUG_SUPPORT_MODDIR="$REL" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" sh "$HELPER" full-day || true)"
printf '%s\n' "$REL_OUT" | grep -Fq 'error=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse recorder' >&2; exit 1
}
REL_TL="$(ASB_BOOT_TIMELINE_MODDIR="$REL" ASB_BOOT_TIMELINE_STATE_DIR="$TMP/timeline-release" sh "$TIMELINE" begin postfs_begin || true)"
printf '%s\n' "$REL_TL" | grep -Fq 'status=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse boot timeline' >&2; exit 1
}
[ ! -e "$TMP/timeline-release/boot_timeline.tsv" ] || { echo 'FAIL debug support: release timeline wrote state' >&2; exit 1; }

# A debug module gets a mocked diagnostic and recorder. The recorder reproduces the real
# ownership protocol: it claims the tokenized directory with ITS OWN PID and only removes
# a guard that still names that PID. This catches launcher-PID and cleanup races on host.
DBG="$TMP/debug"; mkdir -p "$DBG/system/bin" "$DBG/tools/logkit" "$TMP/out"
printf 'id=AutoSystemBoost\nversion=V65-debug10\n' > "$DBG/module.prop"
TL_STATE="$TMP/timeline-debug"
ASB_BOOT_TIMELINE_MODDIR="$DBG" ASB_BOOT_TIMELINE_STATE_DIR="$TL_STATE" sh "$TIMELINE" begin postfs_begin >/dev/null
ASB_BOOT_TIMELINE_MODDIR="$DBG" ASB_BOOT_TIMELINE_STATE_DIR="$TL_STATE" sh "$TIMELINE" mark service_enter >/dev/null
grep -Fq $'\tpostfs_begin\t' "$TL_STATE/boot_timeline.tsv" || { echo 'FAIL debug support: postfs boot marker missing' >&2; exit 1; }
grep -Fq $'\tservice_enter\t' "$TL_STATE/boot_timeline.tsv" || { echo 'FAIL debug support: service boot marker missing' >&2; exit 1; }
printf '#!/bin/sh\n[ "${ASB_DEBUG_SUPPORT_TEST_DIAG_DELAY:-0}" = 1 ] && sleep 1\nif [ "${ASB_DEBUG_SUPPORT_TEST_DIAG_FAIL:-0}" = 1 ]; then echo diagnostic-failed; exit 9; fi\necho diagnostic-ok\n' > "$DBG/system/bin/asbdiag"; chmod 0755 "$DBG/system/bin/asbdiag"
cat > "$DBG/tools/logkit/asb_log_full_day.sh" <<'EOF_RECORDER'
#!/bin/sh
set -u
_lock="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"
_token="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
[ -n "$_lock" ] && [ -d "$_lock" ] || exit 91
[ "$(cat "$_lock/token" 2>/dev/null || true)" = "$_token" ] || exit 92
printf '%s\n' "$$" > "$_lock/pid.tmp.$$" || exit 93
mv -f "$_lock/pid.tmp.$$" "$_lock/pid" || exit 94
_out="$_lock/capture_output"; mkdir -p "$_out" || exit 95
printf '%s\n' "$_out" > "$_lock/output_dir" || exit 96
cleanup() {
  _pid="$(tr -dc '0-9' < "$_lock/pid" 2>/dev/null || true)"
  [ "$_pid" = "$$" ] && rm -rf "$_lock" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT HUP
sleep 30
cleanup
EOF_RECORDER
chmod 0755 "$DBG/tools/logkit/asb_log_full_day.sh"
ENV=(ASB_DEBUG_SUPPORT_MODDIR="$DBG" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" ASB_DEBUG_SUPPORT_RUNLOG="$TMP/full_day.out" ASB_DEBUG_SUPPORT_DIAG_OUTDIR="$TMP/out")
# Capture the output AND the status separately.
#
# Under `set -e` a non-zero exit from the helper aborts the test at this line, before any
# assertion runs - so the whole regression reported "exit code 8" with no failing check
# named, and the real problem was invisible. The helper legitimately returns non-zero for
# conditions this test is meant to observe, so its status is data here, not an error.
DIAG_OUT="$(env "${ENV[@]}" sh "$HELPER" diag || true)"
echo "$DIAG_OUT" | grep -Fq 'status=saved'
DIAG_PATH="$(printf '%s\n' "$DIAG_OUT" | sed -n 's/^path=//p')"
[ -f "$DIAG_PATH" ] && grep -Fq 'diagnostic-ok' "$DIAG_PATH" || { echo 'FAIL debug support: diag export' >&2; exit 1; }

# WebUI cannot paint while a KSU bridge waits for a synchronous diagnostic export.
# The async action must acknowledge a delayed worker immediately, remain observable via
# fixed status command, and publish a complete saved record after the worker exits.
ASYNC_DIAG="$(ASB_DEBUG_SUPPORT_TEST_DIAG_DELAY=1 env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$ASYNC_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: async diag did not return started' >&2; exit 1; }
ASYNC_PID="$(printf '%s\n' "$ASYNC_DIAG" | sed -n 's/^pid=//p')"
[ -n "$ASYNC_PID" ] && kill -0 "$ASYNC_PID" 2>/dev/null || { echo 'FAIL debug support: async diag worker missing' >&2; exit 1; }
ASYNC_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
printf '%s\n' "$ASYNC_STATUS" | grep -Eq '^status=(starting|running)$' || { echo 'FAIL debug support: async diag status not live' >&2; exit 1; }
for _diag_try in $(seq 1 30); do
  sleep 0.1
  ASYNC_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
  printf '%s\n' "$ASYNC_STATUS" | grep -Fqx 'status=saved' && break
done
printf '%s\n' "$ASYNC_STATUS" | grep -Fqx 'status=saved' || { echo 'FAIL debug support: async diag never reached saved' >&2; exit 1; }
ASYNC_PATH="$(printf '%s\n' "$ASYNC_STATUS" | sed -n 's/^path=//p')"
[ -f "$ASYNC_PATH" ] && grep -Fq 'diagnostic-ok' "$ASYNC_PATH" || { echo 'FAIL debug support: async diag saved output missing' >&2; exit 1; }

# A dead diagnostic worker must not leave a permanent `already_running` lock, and a nonzero
# asbdiag exit must become an explicit failed status rather than a misleading saved toast.
mkdir -p "$TMP/state/asbdiag_webui.lock"
printf '999999\n' > "$TMP/state/asbdiag_webui.lock/pid"
STALE_DIAG="$(env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$STALE_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: known-dead diag lock not reclaimed' >&2; exit 1; }
for _diag_try in $(seq 1 30); do sleep 0.1; env "${ENV[@]}" sh "$HELPER" diag-status | grep -Fqx 'status=saved' && break; done
FAIL_DIAG="$(ASB_DEBUG_SUPPORT_TEST_DIAG_FAIL=1 env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$FAIL_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: failing diag did not launch' >&2; exit 1; }
for _diag_try in $(seq 1 30); do
  sleep 0.1
  FAIL_DIAG_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
  printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'status=failed' && break
done
printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'status=failed' || { echo 'FAIL debug support: nonzero diag did not reach failed state' >&2; exit 1; }
printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'error=asbdiag_exit_9' || { echo 'FAIL debug support: nonzero diag exit was not surfaced' >&2; exit 1; }
START1="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$START1" | grep -Fq 'status=started'
REC_PID="$(printf '%s\n' "$START1" | sed -n 's/^pid=//p')"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: recorder did not stay alive' >&2; exit 1; }
START2="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$START2" | grep -Fq 'status=already_running'
echo "$START2" | grep -Fq "pid=$REC_PID"

# Deleting the exact directory published by the live recorder is an explicit cancellation.
# The helper may stop ONLY that recorder, clear its lock and launch a new single capture.
# Simulate a common Android toybox limitation: both ps formats expose only a shortened command
# line. The recovery still needs the script basename, but remains gated by a live lock PID and
# an explicitly removed recorder-owned output directory.
mkdir -p "$TMP/ps-truncated"
cat > "$TMP/ps-truncated/ps" <<'EOF_PS'
#!/bin/sh
printf '%s\n' 'sh asb_log_full_day.sh 24'
EOF_PS
chmod 0755 "$TMP/ps-truncated/ps"
ORPHAN_OUT="$(cat "$TMP/state/full_day_webui.lock/output_dir")"
[ -d "$ORPHAN_OUT" ] || { echo 'FAIL debug support: recorder did not publish output dir' >&2; exit 1; }
rm -rf "$ORPHAN_OUT"
RECOVERED="$(PATH="$TMP/ps-truncated:$PATH" env "${ENV[@]}" sh "$HELPER" full-day || true)"
printf '%s\n' "$RECOVERED" | grep -Fq 'status=started' || {
  echo 'FAIL debug support: removed output dir did not recover capture slot' >&2
  # What the helper answered and why (fix146: a CI run failed here with nothing to read).
  printf '  helper: %s\n' "$RECOVERED" >&2
  sed 's/^/  recovery log: /' "$TMP/state/full_day_webui.recovery.log" >&2 2>/dev/null || true
  _rp="$(printf '%s\n' "$START1" | sed -n 's/^pid=//p')"
  [ -n "$_rp" ] && { printf '  recorder %s: ' "$_rp"; cat "/proc/$_rp/stat" 2>/dev/null || echo gone; } >&2
  exit 1
}
grep -Fq 'recovered=output_removed' "$TMP/state/full_day_webui.recovery.log" || { echo 'FAIL debug support: orphan recovery evidence missing' >&2; exit 1; }
REC_PID="$(printf '%s\n' "$RECOVERED" | sed -n 's/^pid=//p')"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: recovered recorder missing' >&2; exit 1; }

# Repeat simultaneous starts from a clean state. One and only one recorder may be created in
# every round; the losing request must publish the winner PID rather than relying on a
# short-lived helper process or a removable empty PID file.
for round in $(seq 1 12); do
  kill -KILL "$REC_PID" 2>/dev/null || true
  wait "$REC_PID" 2>/dev/null || true
  REC_PID=""
  rm -rf "$TMP/state/full_day_webui.lock"
  rm -f "$TMP/state/full_day_webui.pid"
  env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_${round}_a.out" & C1=$!
  env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_${round}_b.out" & C2=$!
  # wait propagates the child status, and under set -e that aborts the test before the
  # assertion that is meant to inspect it. The helper legitimately returns non-zero for
  # the losing side of this race - that is the behaviour being measured.
  wait "$C1" || true; wait "$C2" || true
  CONCURRENT="$(cat "$TMP/concurrent_${round}_a.out" "$TMP/concurrent_${round}_b.out")"
  [ "$(printf '%s\n' "$CONCURRENT" | grep -c '^status=started$')" -eq 1 ] || { echo "FAIL debug support: concurrent start count round=$round" >&2; exit 1; }
  printf '%s\n' "$CONCURRENT" | grep -Fq 'status=already_running' || { echo "FAIL debug support: concurrent guard did not report running round=$round" >&2; exit 1; }
  REC_PID="$(printf '%s\n' "$CONCURRENT" | sed -n 's/^pid=//p' | grep -E '^[0-9]+$' | head -n 1)"
  [ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo "FAIL debug support: concurrent recorder missing round=$round" >&2; exit 1; }
  printf '%s\n' "$CONCURRENT" | grep -Fq "pid=$REC_PID" || { echo "FAIL debug support: loser did not observe winner PID round=$round" >&2; exit 1; }
done

# A killed recorder leaves a known-dead PID. The next action may reclaim only that stale lock.
kill -KILL "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
# The recorder is not this shell's child, so `wait` returns at once; SIGKILL lands
# asynchronously. Give it up to 5 s to be gone or a zombie before asking (fix136 - the
# full regression failed here once in a while on a loaded host, never on a device).
_dk=0
while [ "$_dk" -lt 50 ]; do
  kill -0 "$REC_PID" 2>/dev/null || break
  case "$(cat "/proc/$REC_PID/stat" 2>/dev/null)" in *') Z '*) break ;; esac
  sleep 0.1; _dk=$((_dk + 1))
done
STALE="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$STALE" | grep -Fq 'status=started' || { echo 'FAIL debug support: known-dead lock not reclaimed' >&2; exit 1; }
REC_PID="$(printf '%s\n' "$STALE" | sed -n 's/^pid=//p')"

# The helper accepts a fixed enum only; it has no eval/source/untrusted command interpolation.
need "$HELPER" "case \"\${1:-status}\" in"
need "$HELPER" 'mkdir "$LOCKDIR"'
need "$HELPER" 'lock_known_dead()'
need "$HELPER" 'full_day_output_missing()'
need "$HELPER" 'full_day_cancel_orphan()'
need "$HELPER" 'full_day_pid_matches_recorder()'
need "$HELPER" 'asb_log_full_day.sh*) return 0'
need "$HELPER" 'full_day_recovery_note()'
need "$HELPER" 'RECOVERY_LOG='
need "$HELPER" 'PROC_ROOT='
need "$HELPER" 'diag_lock_known_dead()'
need "$HELPER" 'asbdiag_exit_${_rc}'
need "$HELPER" 'lock_wait_live_pid()'
need "$HELPER" 'ASB_DEBUG_SUPPORT_LOCKDIR="$LOCKDIR"'
need "$HELPER" 'diag-start) diag_start'
need "$HELPER" 'diag-status) diag_status'
need "$HELPER" 'full-day-start) start_full_day 1'
need "$HELPER" 'DIAG_LOCKDIR="$STATE_DIR/asbdiag_webui.lock"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'LK_WEBUI_LOCKDIR="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim()'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim || { echo '\''[debug-webui] guard claim failed'\''; exit 2; }'
need "$ROOT/tools/logkit/asb_log_full_day.sh" "trap 'lk_finalize; lk_webui_guard_release; exit 0' TERM INT HUP"
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_release'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_publish_output()'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'LK_WEBUI_OUTPUTFILE'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'FULL-DAY capture complete. Output: $LK_OUT_DIR'
# Debug capture must expose a resolvable AudioMix owner and the evidence that made
# a media-like workload game-like, without putting any package-manager polling in
# the native governor. The logkit helpers are passive and use one capture-start map.
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
need "$COMMON" 'lk_audio_wakelock_attribution_init()'
need "$COMMON" 'audio_wakelock_attribution.tsv'
need "$COMMON" 'lk_fsm_media_trace_header()'
need "$COMMON" 'fsm_media_trace.tsv'
# Android 16 emits a chained WorkSource for AudioMix. Test both that real form and
# the compact legacy form; raw UID attribution is useless if the recorder prints '-'.
sed -n '/^lk_audio_wakelock_live_row() {/,/^}/p' "$COMMON" > "$TMP/audio_wakelock_fn.sh"
[ -s "$TMP/audio_wakelock_fn.sh" ] || { echo 'FAIL debug support: cannot extract AudioMix attribution helper' >&2; exit 1; }
lk_audio_wakelock_package_for_uid() { printf 'pkg.uid.%s\n' "$1"; }
LK_OUT_DIR="$TMP/audio_attr"; mkdir -p "$LK_OUT_DIR"
. "$TMP/audio_wakelock_fn.sh"
lk_audio_wakelock_live_row "PARTIAL_WAKE_LOCK 'AudioMix' (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}})" 123
lk_audio_wakelock_live_row "PARTIAL_WAKE_LOCK 'AudioMix' WorkSource{10652}" 124
grep -Fq '123|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: chained AudioMix row absent' >&2; exit 1; }
grep -Fq '|10658|pkg.uid.10658|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: chained WorkSource UID unresolved' >&2; exit 1; }
grep -Fq '|10652|pkg.uid.10652|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: compact WorkSource UID unresolved' >&2; exit 1; }
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_audio_wakelock_attribution_init'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_capture_fsm_media_trace_row "$_phase"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'rmnetMiB'
need "$ROOT/src/asb_governor.c" 'asb_smart_media_guard_observe'
need "$ROOT/src/asb_governor.c" 'no_fresh_known_media_pkg'
need "$ROOT/src/asb_governor.c" 'ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT = 70'
need "$ROOT/src/asb_smart.h" 'asb_smart_pkg_is_media_candidate'
if grep -nE '\beval\b|\bsource\b|/system/bin/sh -c|sh -c' "$HELPER" >/dev/null; then
  echo 'FAIL debug support: helper accepts unsafe shell execution' >&2; exit 1
fi
# Every one of Profile, Monitor and Settings gets one support wrapper. A debug build
# swaps its single release Telegram link for exactly one no-wrap, three-control rail.
count_exact "$UI" '<div class="footer-support-row" data-debug-support-row hidden>' 3
count_exact "$UI" '<a class="tg-link" data-release-telegram' 3
count_exact "$UI" '<a class="tg-link" data-debug-telegram' 3
count_exact "$UI" "asbDebugAction('diag')" 3
count_exact "$UI" "asbDebugAction('full-day')" 3
count_exact "$UI" '<span class="tg-link-ico" data-tech-icon="telegram"></span>' 6
need "$UI" '.tg-link-ico .tech-icon { width: 18px; height: 18px; }'
need "$UI" '.footer-support-row .tg-link-ico { width: 16px; height: 16px; flex-basis: 16px; }'
need "$UI" 'background: linear-gradient(135deg, rgba(0,240,180,0.08), rgba(0,212,255,0.05));'
need "$UI" 'height: 40px;'
need "$UI" 'flex-wrap: nowrap;'
need "$UI" '[data-release-telegram][hidden] { display: none !important; }'
need "$UI" 'runtime/asb_debug_support.sh'
need "$UI" 'loadDebugSupport()'
need "$UI" '/-debug[1-9][0-9]*$/i'
# asbdiag can spend seconds writing its export. A persistent modal must open before
# the root bridge await, stay while the pulse is active, and close only in finally.
need "$UI" 'id="debugActionWait"'
need "$UI" 'debug-action-wait-sheet'
need "$UI" 'background:#000;'
need "$UI" 'stockRestoreToastOpen();'
need "$UI" 'stockRestoreToastClose();'
need "$UI" 'toast.stock-restoring'
need "$UI" 'stockRestoreToastPulse'
need "$UI" 'debugDiagPulse .38s'
need "$UI" 'debugActionWaitOpen(action);'
need "$UI" 'debugActionWaitClose();'
need "$UI" 'await debugFrame();'
need "$UI" "'diag-start' : 'full-day-start'"
need "$UI" 'runtime/asb_debug_support.sh diag-status'
need "$UI" 'async function debugDiagPoll()'
need "$UI" 'async function debugFullDayPoll()'
need "$UI" 'runtime/asb_debug_support.sh status'
awk '
  /async function asbDebugAction\(action\)/ { in_fn=1 }
  in_fn && /debugActionWaitOpen\(action\)/ { opened=NR }
  in_fn && /await run\(/ && !awaited { awaited=NR }
  in_fn && /finally \{/ { in_final=1 }
  in_final && /debugActionWaitClose\(\)/ { closed=1 }
  in_fn && /^}/ { if (opened && awaited && opened < awaited && closed) ok=1; in_fn=0 }
  END { if (!ok) { print "FAIL debug support: wait modal lifecycle is not open-before-await / close-in-finally" > "/dev/stderr"; exit 1 } }
' "$UI"
awk '
  /<div class="footer-support-row" data-debug-support-row hidden>/ { inrow=1; seq=""; next }
  inrow && /asbDebugAction\('\''diag'\''\)/ { seq=seq "D" }
  inrow && /data-debug-telegram/ { seq=seq "T" }
  inrow && /asbDebugAction\('\''full-day'\''\)/ { seq=seq "L" }
  inrow && /<\/div>/ { if (seq != "DTL") { printf "FAIL debug support: expected DTL rail order, got %s\\n", seq > "/dev/stderr"; exit 1 }; rails++; inrow=0 }
  END { if (rails != 3) { printf "FAIL debug support: checked %d central rails\\n", rails > "/dev/stderr"; exit 1 } }
' "$UI"
for locale in "$ROOT"/webroot/i18n/*.json; do
  # Check the VALUE, not the byte sequence.
  #
  # These matched '"key": "value"' with the space that json.dump's indent mode happens to
  # emit. Compacting the locale files to save 43 KB changed no data at all and broke both
  # lines, because a grep for punctuation is not a test of content.
  #
  # Matching the key and value with optional whitespace between them holds for either
  # formatting, and still fails if the string is actually missing or renamed - which is
  # what the contract is about.
  grep -Eq '"dbg_diag_btn"[[:space:]]*:[[:space:]]*"asbdiag"' "$locale" \
    || fail "missing dbg_diag_btn=asbdiag in $locale"
  grep -Eq '"dbg_log_btn"[[:space:]]*:[[:space:]]*"24h log"' "$locale" \
    || fail "missing dbg_log_btn=24h log in $locale"
  need "$locale" '"dbg_log_failed"'
done

echo 'PASS debug support WebUI/helper contract'
)

t_debug_support_stale_lock() (
# Regression: the WebUI must be able to start a daily log again after a previous one ended or
# its folder was deleted. Three cases:
#   1. stale lock whose PID now belongs to an UNRELATED live process (PID reuse within a boot)
#      -> the lock is not ours: start must succeed, the unrelated process must be left alive;
#   2. our recorder alive, folder present -> still "already running" (no second recorder);
#   3. our recorder alive, folder deleted -> recorder AND its sampler child stopped, new start.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
TMP="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; pkill -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL debug stale-lock: $*" >&2; exit 1; }
# Alive and not a zombie: a killed process stays visible to kill -0 until it is reaped.
alive() { [ -r "/proc/$1/stat" ] || return 1; case "$(sed 's/^.*) //' "/proc/$1/stat" | cut -c1)" in Z|X) return 1 ;; esac; return 0; }
DBG="$TMP/mod"; mkdir -p "$DBG/tools/logkit" "$DBG/runtime"
printf 'id=AutoSystemBoost\nversion=V65-debug10\nversionCode=650\n' > "$DBG/module.prop"
cat > "$DBG/tools/logkit/asb_log_full_day.sh" << 'EOF_REC'
set -u
_lock="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"; _token="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
[ -d "$_lock" ] && [ "$(cat "$_lock/token")" = "$_token" ] || exit 91
printf '%s\n' "$$" > "$_lock/pid"
_out="$_lock/../capture_$$"; mkdir -p "$_out"; printf '%s\n' "$_out" > "$_lock/output_dir"
( while :; do sleep 1; done ) &          # a sampler child, as the real recorder has
echo $! > "$_lock/../child_$$"
sleep 60
EOF_REC
ENV=(ASB_DEBUG_SUPPORT_MODDIR="$DBG" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" ASB_DEBUG_SUPPORT_RUNLOG="$TMP/run.out")
H() { env "${ENV[@]}" sh "$HELPER" "$@" 2>/dev/null || true; }
LOCK="$TMP/state/full_day_webui.lock"
boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo boot)"

# ---- case 1: stale lock, PID reused by an unrelated live process
mkdir -p "$LOCK"; sleep 300 & OTHER=$!
printf '%s\n' "$boot" > "$LOCK/boot_id"; printf 'tok\n' > "$LOCK/token"
printf '%s\n' "$OTHER" > "$LOCK/pid"; printf '%s\n' "$OTHER" > "$LOCK/launcher"
printf '%s\n' "$TMP/deleted_capture" > "$LOCK/output_dir"
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'status=started' || fail "case 1: stale lock blocked the start: $OUT"
kill -0 "$OTHER" 2>/dev/null || fail "case 1: an unrelated process was killed"
sleep 0.6
P1="$(tr -dc 0-9 < "$LOCK/pid" 2>/dev/null)"; [ -n "$P1" ] && kill -0 "$P1" || fail "case 1: recorder not running"

# ---- case 2: our recorder alive, folder present -> already running
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'status=already_running' || fail "case 2: a second recorder was allowed: $OUT"

# ---- case 3: folder deleted -> recorder and child stopped, new recorder started
CHILD="$(cat "$TMP/state/child_$P1" 2>/dev/null)"
rm -rf "$(cat "$LOCK/output_dir")"
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'orphan_recovered=output_dir_removed' || fail "case 3: orphan not recovered: $OUT"
echo "$OUT" | grep -q 'status=started' || fail "case 3: no new start: $OUT"
sleep 0.4
alive "$P1" && fail "case 3: old recorder still alive"
[ -n "$CHILD" ] && alive "$CHILD" && fail "case 3: old sampler child still alive"
kill "$OTHER" 2>/dev/null
echo "PASS debug support stale-lock and deleted-folder recovery"
)

t_jank_app_state_runtime() (
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
)

t_jank_floor_runtime() (
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
)

t_jank_trace_runtime() (
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
  # Screen off keeps the last screen-on baseline (fix150); this wake went backwards against
  # it (a pruned day), so the first screen-on poll after it writes no row.
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

# fix150: the wake itself. The last screen-on baseline survives the screen-off stretch and the
# first screen-on poll after it writes one row marked "wake" (column 18); the report keeps
# those rows apart - their seconds are mostly screen-off.
mkdir -p "$T/outw"
outw="$(LK_OUT_DIR="$T/outw" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  lk_jank_trace_header
  ASB_LK_STATE_FILE="$T/state1" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row idle 0
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row idle 0
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g3" lk_capture_jank_row post_wake 1
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g3" lk_capture_jank_row post_wake 1
  echo "--- trace"; grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
  echo "--- report"; lk_emit_jank_summary
' "$C" "$T" 2>&1)"
rw="$(printf '%s\n' "$outw" | grep '|wake$')"
[ "$(printf '%s\n' "$rw" | grep -c .)" = 1 ] || f "expected one wake row: $outw"
[ "$(printf '%s' "$rw" | cut -d'|' -f3-4)" = "post_wake|MODERATE" ] || f "wake row phase/state: $rw"
[ "$(printf '%s' "$rw" | cut -d'|' -f6-10)" = "-|-|0|200|2" ] || f "wake row deltas (against the last screen-on poll): $rw"
case "$(printf '%s' "$rw" | cut -d'|' -f17)" in
  "com.android.systemui:1:100,com.google.android.youtube:1:100"|"com.google.android.youtube:1:100,com.android.systemui:1:100") : ;;
  *) f "wake row apps: $rw" ;;
esac
[ "$(printf '%s\n' "$outw" | sed -n '/^--- trace/,/^--- report/p' | grep -c '|')" = 3 ] || f "wake must not replace the ordinary rows: $outw"
printf '%s\n' "$outw" | grep -q 'all screen-on intervals: 2  frames 2000  janky 5.3%' || f "a wake row leaked into the ordinary figures: $outw"
printf '%s\n' "$outw" | grep -q 'the wake itself: 1 wake(s), last screen-on poll before each to the first after it - frames 200, janky 1.0% (ordinary screen-on intervals: 5.3%)' \
  || f "wake summary missing: $outw"
printf '%s\n' "$outw" | grep -q '  at the wakes, by app: com.android.systemui 1 of 100 janky (1.0%), com.google.android.youtube 1 of 100 janky (1.0%)' \
  || printf '%s\n' "$outw" | grep -q '  at the wakes, by app: com.google.android.youtube 1 of 100 janky (1.0%), com.android.systemui 1 of 100 janky (1.0%)' \
  || f "wake apps missing: $outw"

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
)

t_logkit_bstats_no_reset_runtime() (
# Runtime: the capture no longer resets batterystats by default, and the per-app wakelock
# section shows the capture's own window as a difference against the start.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit batterystats: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/out"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$2" = "--reset" ] && { echo reset >> "$RESETS"; exit 0; }
cat "$BS"
S
chmod +x "$T/bin/dumpsys"
cat > "$T/bs1" <<'B'
  Wake lock u0a493 PedometerLib:tag: 4m 4s 955ms (3 times) max=1 realtime
  Wake lock u0a700 SyncLoop: 10s 1ms (4 times) realtime
B
cat > "$T/bs2" <<'B'
  Wake lock u0a493 PedometerLib:tag: 9m 4s 955ms (9 times) max=1 realtime
  Wake lock u0a700 SyncLoop: 12s 1ms (5 times) realtime
  Wake lock u0a800 NewOne: 1m 0s 1ms (1 times) realtime
B
printf '10493|com.sec.android.app.shealth\n10800|com.example.new\n' > "$T/out/.uid_package_map.tsv"
out="$(PATH="$T/bin:$PATH" RESETS="$T/resets" LK_OUT_DIR="$T/out" BS="$T/bs1" sh -c '
  . "$0" >/dev/null 2>&1
  lk_have() { command -v "$1" >/dev/null 2>&1 || type "$1" >/dev/null 2>&1; }
  lk_dumpsys() { dumpsys "$@"; }
  LK_WAKELOCK_NAME=asb_logkit_self
  lk_wakelock_batterystats_reset
  BS="'"$T"'/bs2" lk_wakelock_batterystats_reset
  BS="'"$T"'/bs2" lk_wakelock_emit_report "'"$T"'/bs2"
  sed -n "/TOP APPS/,/^$/p" "$LK_OUT_DIR/_wakelock_report.txt"
' "$C" 2>&1)"
[ -f "$T/resets" ] && f "batterystats was reset without ASB_LK_BSTATS_RESET=1"
printf '%s\n' "$out" | grep -q 'during this capture' || f "section not labelled as the capture window: $out"
printf '%s\n' "$out" | grep -q '5m 00s  com.sec.android.app.shealth' || f "pedometer delta should be 5m 00s: $out"
printf '%s\n' "$out" | grep -q '1m 00s  com.example.new' || f "new holder missing: $out"
printf '%s\n' "$out" | grep -q 'uid 10700' && f "2 s delta must stay under the 5 s floor"
[ "$fail" = 0 ] && echo "PASS logkit batterystats no-reset runtime"
exit "$fail"
)

t_logkit_bstats_stall_runtime() (
# Runtime (fix140): a capture says so when batterystats did not update, instead of "no app
# held a partial wakelock".
#
# Capture 2830 (OP15, 9.5 h): "TOP APPS BY HELD WAKELOCK TIME ... (no app held a partial
# wakelock for 5 s or more in this window)" while the live power-manager samples saw
# YouTube's AudioMix held for 20 minutes at a stretch. Every uid's batterystats total was the
# one recorded at the start (AudioMix 1m 52s at 22:45 and at 08:03), the kernel wakelock
# totals too: Android's accounting did not move. The REAL report functions run on fixtures
# with a fake dumpsys.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
fail() { echo "FAIL logkit batterystats stall: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
O="$T/out"; B="$T/bin"; mkdir -p "$O" "$B"
cat > "$B/dumpsys" <<'S'
#!/bin/sh
[ "$1" = batterystats ] || exit 0
cat "$BS_FILE"
S
chmod +x "$B/dumpsys"
cat > "$T/bs_frozen.txt" <<'X'
  All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: 4m 24s 17ms (4 times) max=79609 actual=339376 realtime
  Wake lock u0a658 AudioMix: 1m 52s 686ms (0 times) max=139335 actual=148655 realtime

X
printf '10493 264 PedometerLib:tag\n10658 112 AudioMix\n' > "$O/.wl_uid_base"
echo $(( $(date +%s) - 3 * 3600 - 60 )) > "$O/.bstats_base_epoch"
echo "epoch|datetime|status" > "$O/charge_trace.txt"
printf '10658|com.google.android.youtube\n10493|com.sec.android.app.shealth\n' > "$O/.uid_package_map.tsv"
# On battery: 52 % -> 35 % over the night (the OP15's status node reads "Unknown" throughout).
printf 'epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA\n1|d|MODERATE|smart|1|52|1124\n2|d|DEEP_IDLE|smart|0|35|83\n' > "$O/battery_trace.txt"

run_dump() {
  BS_FILE="$1" PATH="$B:$PATH" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_wakelock_batterystats_dump' "$C" "$O" >/dev/null 2>&1
}

# The screen was off for most of it (fix142: batterystats charges partial wakelocks only with
# the screen off, so the stall claim needs real screen-off time). Rows 30 min apart at night.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 2600 4400 6200 8000; do echo "$e|d|sleep|0|0|4094|0||-60||" >> "$O/display_trace.txt"; done
cp "$O/display_trace.txt" "$T/dt.night"

# 0. Screen on the whole time and nothing moved: batterystats had nothing to charge - no claim.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 2600 4400 6200 8000; do echo "$e|d|active|1|900|4094|22|120|-400||2" >> "$O/display_trace.txt"; done
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed for a capture with the screen on throughout"
cp "$T/dt.night" "$O/display_trace.txt"

# 1. Nothing moved in 3 h, no charging: the stall is named, "no app" is not printed.
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved in 3 h of capture" "$O/_wakelock_report.txt" || fail "stall not named: $(sed -n '/TOP APPS/,/^$/p' "$O/_wakelock_report.txt")"
grep -q 'no app held a partial wakelock' "$O/_wakelock_report.txt" && fail "still says no app held one"
grep -qx '10658 0' "$O/.wl_uid_delta" || fail "per-uid deltas not kept for the report"

# 2. The live samples saw AudioMix (YouTube's worksource) held 20 min at a stretch.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
# Screen off since 800: the 20-minute hold sampled at 2020 lies entirely in the dark.
for e in 800 2000 2020 2040; do echo "$e|d|audio_bt|0|0|4094|0||-120||" >> "$O/display_trace.txt"; done
cat > "$O/wake_live.txt" <<'X'
2000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-5m1s2ms LONG (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}});
2020|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-20m3s9ms LONG (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}});
2040|kactive=0|ktop=|plocks=
X
printf '10658 com.google.android.youtube\n' > "$O/uid_map.txt"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q '^batterystats disagrees with these samples:$' || fail "no disagreement line: $live"
printf '%s\n' "$live" | grep -q 'com.google.android.youtube (AudioMix): held 20 min at a stretch with the screen off here, batterystats added 0 s' \
  || fail "holder not compared: $live"

# 2b. fix142: the same 20-minute hold, but the screen went off 20 s before the sample - the
# hold ran with the screen on, which batterystats does not charge. No disagreement.
cp "$O/display_trace.txt" "$T/dt.keep"
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 1950; do echo "$e|d|active|1|900|4094|22|120|-400||2" >> "$O/display_trace.txt"; done
for e in 2000 2020 2040; do echo "$e|d|audio_bt|0|0|4094|0||-120||" >> "$O/display_trace.txt"; done
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "a hold that ran with the screen on compared against batterystats: $live"
cp "$T/dt.keep" "$O/display_trace.txt"

# 3. On the charger batterystats counts nothing by design: no stall claim, no disagreement.
echo "1|d|Charging" >> "$O/charge_trace.txt"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed during a charging capture"
grep -q 'no app held a partial wakelock for 5 s' "$O/_wakelock_report.txt" || fail "charging capture lost the plain line"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "disagreement printed while charging: $live"
echo "epoch|datetime|status" > "$O/charge_trace.txt"

# 3b. No charge row but the level held (a phone kept at a charge limit): no claim either.
cp "$O/battery_trace.txt" "$T/bt.keep"
printf 'epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA\n1|d|MODERATE|smart|1|80|-5\n2|d|DEEP_IDLE|smart|0|80|3\n' > "$O/battery_trace.txt"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed with the level held"
cp "$T/bt.keep" "$O/battery_trace.txt"

# 4. Accounting that moves: the ranking as before, and no disagreement once it covers the hold.
sed 's/AudioMix: 1m 52s 686ms/AudioMix: 26m 2s 1ms/' "$T/bs_frozen.txt" > "$T/bs_live.txt"
run_dump "$T/bs_live.txt"
grep -q 'com.google.android.youtube' "$O/_wakelock_report.txt" || fail "moving totals not ranked"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed with moving totals"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "disagreement with totals that cover the hold: $live"

# 5. A short capture with nothing moved is just a quiet window.
echo $(( $(date +%s) - 1800 )) > "$O/.bstats_base_epoch"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed after 30 minutes"
echo "PASS logkit batterystats stall: a stalled batterystats is named and checked against the live samples"
)

t_logkit_capture_quality_contract() (
# Contract: full-day telemetry improvements must remain observer-only and phase-stable.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOGKIT="$ROOT/tools/logkit/asb_log_full_day.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" >/dev/null || { echo "FAIL logkit capture-quality: missing [$2]" >&2; exit 1; }; }

[ -f "$LOGKIT" ] || { echo "FAIL logkit capture-quality: missing full-day logkit" >&2; exit 1; }
sh -n "$LOGKIT"

# Extract the standalone debounce function: this avoids sourcing a device-only recorder.
sed -n '/^lk_stabilize_charging_phase() {/,/^}/p' "$LOGKIT" > "$TMP/debounce.sh"
[ -s "$TMP/debounce.sh" ] || { echo "FAIL logkit capture-quality: cannot extract debounce helper" >&2; exit 1; }
. "$TMP/debounce.sh"

LK_CHG_PHASE_STABLE=""
LK_CHG_IDLE_CANDIDATE_SINCE=0
LK_CHG_IDLE_DEBOUNCE_S=45
LK_CHG_IDLE_COALESCED=0
# Charging-idle telemetry is intentionally less frequent than visible charging/gaming so an
# opt-in diagnostic capture does not itself keep a plugged, screen-off device busy.
need "$LOGKIT" 'LK_POLL_CHARGING_IDLE=60'
need "$LOGKIT" 'charging_idle)          echo "$LK_POLL_CHARGING_IDLE" ;'
sed -n '/^lk_poll_for_phase() {/,/^}/p' "$LOGKIT" > "$TMP/cadence.sh"
[ -s "$TMP/cadence.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract cadence helper' >&2; exit 1; }
LK_POLL_FAST=15 LK_POLL_NORMAL=45 LK_POLL_SLOW=90 LK_POLL_CHARGING_IDLE=60
. "$TMP/cadence.sh"
[ "$(lk_poll_for_phase charging_idle)" = 60 ] || { echo 'FAIL logkit capture-quality: charging-idle cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase charging_active)" = 15 ] || { echo 'FAIL logkit capture-quality: visible charging cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase gaming)" = 15 ] || { echo 'FAIL logkit capture-quality: gaming cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase sleep)" = 90 ] || { echo 'FAIL logkit capture-quality: sleep cadence' >&2; exit 1; }
lk_stabilize_charging_phase charging_active 100
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: first active sample" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 115
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: short idle must stay active" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 145
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: debounce must remain bounded" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 160
[ "$LK_CHG_PHASE_OUT" = charging_idle ] || { echo "FAIL logkit capture-quality: sustained idle must commit" >&2; exit 1; }
lk_stabilize_charging_phase charging_active 161
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: visible screen use must be immediate" >&2; exit 1; }
[ "$LK_CHG_IDLE_COALESCED" -ge 2 ] || { echo "FAIL logkit capture-quality: coalesced counter" >&2; exit 1; }

need "$LOGKIT" 'LK_SCREENOFF_LONGEST_S=0'
need "$LOGKIT" '----- CAPTURE VALIDITY -----'
need "$LOGKIT" 'night verdict: unavailable'
need "$LOGKIT" '----- CAP OWNERSHIP VERDICT -----'
need "$LOGKIT" 'Native vendor holddown/detente'
need "$LOGKIT" 'throttle samples logged: $_tc (poll observations, not independent clamp incidents)'
need "$LOGKIT" 'continuous clamp periods (new period after >180s gap or owner change):'
need "$LOGKIT" 'owner=%-8s duration=%4d min samples=%d'
need "$LOGKIT" "_tc=\$(awk -F'|' 'NR>1 && NF>=6 {n++} END{print n+0}'"
if grep -Fq '%s..%s\\\\n", own' "$LOGKIT"; then
  echo 'FAIL logkit capture-quality: grouping would print literal \\n' >&2
  exit 1
fi
cat > "$TMP/throttle_trace.txt" <<'EOF_TRACE'
# throttle trace — epoch | phase | p0 | p6 | temps | cap_owner
100|active|p0_max=1/2|p6_max=1/2|cpu_temp=45|surface=40|cap_owner=vendor
160|active|p0_max=1/2|p6_max=1/2|cpu_temp=46|surface=41|cap_owner=vendor
400|idle|p0_max=1/2|p6_max=1/2|cpu_temp=44|surface=39|cap_owner=asb
EOF_TRACE
_count="$(awk -F'|' 'NR>1 && NF>=6 {n++} END{print n+0}' "$TMP/throttle_trace.txt")"
[ "$_count" = 3 ] || { echo "FAIL logkit capture-quality: expected 3 data rows, got $_count" >&2; exit 1; }
_grouped="$(awk -F'|' '
  function emit(){ if(n>0) printf "owner=%s samples=%d epoch=%s..%s\n", own, n, start, last }
  NR==1 {next}; NF<6 {next}
  { split($0,a,"cap_owner="); own_now=a[2]; sub(/\|.*/,"",own_now); now=$1+0
    if(n==0){start=now;last=now;own=own_now;n=1;next}
    if((now-last)>180 || own_now!=own){emit();start=now;own=own_now;n=1}else n++
    last=now }
  END{emit()}
' "$TMP/throttle_trace.txt")"
printf '%s\n' "$_grouped" | grep -Fqx 'owner=vendor samples=2 epoch=100..160' || { echo 'FAIL logkit capture-quality: vendor period grouping' >&2; exit 1; }
printf '%s\n' "$_grouped" | grep -Fqx 'owner=asb samples=1 epoch=400..400' || { echo 'FAIL logkit capture-quality: ASB period grouping' >&2; exit 1; }
case "$_grouped" in *'\\n'*) echo 'FAIL logkit capture-quality: literal \\n in fixture output' >&2; exit 1 ;; esac
need "$LOGKIT" '----- CHARGING-IDLE AWAKE VERDICT -----'
need "$LOGKIT" 'ASB does not alter charge current or kill apps automatically.'
need "$LOGKIT" 'lk_charge_idle_observe "$_phase"'
# The source-class report is a passive observed-context diagnostic. It must never claim a
# causal battery percentage by class, and may only cover adjacent same-class samples.
need "$LOGKIT" '===== SCREEN-OFF CLASS OBSERVATIONS ====='
need "$LOGKIT" 'screenoff_class_trace.tsv'
need "$LOGKIT" 'lk_capture_screenoff_class_row "$_phase"'
need "$LOGKIT" 'intervals <=180s'
need "$LOGKIT" 'not a percentage or causal energy allocation'
sed -n '/^lk_emit_screenoff_class_summary() {/,/^}/p' "$LOGKIT" > "$TMP/screenoff_summary.sh"
[ -s "$TMP/screenoff_summary.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract screen-off summary' >&2; exit 1; }
cat > "$TMP/screenoff_class_trace.tsv" <<'EOF_CLASS'
# epoch|phase|class|awake_pct|window_min|bat_mA|reason
100|sleep|quiet|2|55|80|low awake / no media or network
160|sleep|quiet|4|56|100|low awake / no media or network
230|idle|network|28|58|240|active mobile transfer
700|idle|network|31|60|280|active mobile transfer
EOF_CLASS
LK_OUT_DIR="$TMP"
. "$TMP/screenoff_summary.sh"
_class_summary="$(lk_emit_screenoff_class_summary)"
printf '%s\n' "$_class_summary" | grep -Eq '^quiet[[:space:]]+2[[:space:]]+1\.0' || { echo 'FAIL logkit capture-quality: quiet observed coverage' >&2; exit 1; }
printf '%s\n' "$_class_summary" | grep -Eq '^network[[:space:]]+2[[:space:]]+0\.0' || { echo 'FAIL logkit capture-quality: gap must not be attributed to network class' >&2; exit 1; }
printf '%s\n' "$_class_summary" | grep -Fq 'not a percentage or causal energy allocation' || { echo 'FAIL logkit capture-quality: causal allocation disclaimer missing' >&2; exit 1; }

# Current and capacity-percent rates are complementary measurements, not source attribution.
# A synthetic ledger verifies both the aligned path and the explicit >30% quality warning.
need "$LOGKIT" '===== CURRENT / SOC CONSISTENCY (MEASUREMENT QUALITY) ====='
need "$LOGKIT" 'A CHECK result is a measurement-consistency warning, not causal energy attribution.'
sed -n '/^lk_emit_current_soc_consistency() {/,/^}/p' "$LOGKIT" > "$TMP/current_soc_summary.sh"
[ -s "$TMP/current_soc_summary.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract current/SOC helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
sleep	0	3600	90	88	40	35	1000000	0	0	0	2	100	0	0
idle	3600	7200	88	86	42	36	1000000	0	0	0	5	400	0	0
EOF_LEDGER
LK_OUT_DIR="$TMP" LK_BATTERY_CAPACITY_MAH=5000
. "$TMP/current_soc_summary.sh"
_consistency="$(lk_emit_current_soc_consistency)"
printf '%s\n' "$_consistency" | grep -Eq '^sleep[[:space:]]+60\.0[[:space:]]+2\.00[[:space:]]+2\.00[[:space:]]+0\.0%[[:space:]]+aligned$' || { echo 'FAIL logkit capture-quality: aligned current/SOC verdict' >&2; exit 1; }
printf '%s\n' "$_consistency" | grep -Eq '^idle[[:space:]]+60\.0[[:space:]]+2\.00[[:space:]]+8\.00[[:space:]]+75\.0%[[:space:]]+CHECK high \(>30%\)$' || { echo 'FAIL logkit capture-quality: current/SOC check verdict' >&2; exit 1; }
printf '%s\n' "$_consistency" | grep -Fq 'not causal energy attribution' || { echo 'FAIL logkit capture-quality: current/SOC causal disclaimer missing' >&2; exit 1; }

# Per-phase distribution must use raw battery samples mapped to each concrete ledger interval,
# not a median of phase averages. The outlier makes this distinction visible: mean=250 but
# median=100 for the two disjoint active intervals. The endpoint rule must not double-count
# the transition sample at epoch 200, while epoch 400 belongs once to the final interval.
need "$LOGKIT" '===== SAMPLED CURRENT DISTRIBUTION ====='
need "$LOGKIT" 'raw positive discharge samples'
need "$LOGKIT" 'not physical whole-phase averages'
need "$LOGKIT" 'Suspend and intervals between recorder wake-ups are under-sampled'
sed -n '/^lk_emit_sampled_current_distribution() {/,/^}/p' "$LOGKIT" > "$TMP/sampled_current_distribution.sh"
[ -s "$TMP/sampled_current_distribution.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract sampled-current helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_SAMPLE_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
active	100	200	90	90	40	35	1000000	0	0	0	0	0	0	0
idle	200	300	90	90	40	35	1000000	0	0	0	0	0	0	0
active	300	400	90	90	40	35	1000000	0	0	0	0	0	0	0
EOF_SAMPLE_LEDGER
cat > "$TMP/battery_trace.txt" <<'EOF_SAMPLE_TRACE'
epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA
100|x|x|x|1|90|100000
150|x|x|x|1|90|100000
199|x|x|x|1|90|1000000
200|x|x|x|0|90|900000
250|x|x|x|0|90|-100000
300|x|x|x|1|90|100000
350|x|x|x|1|90|100000
400|x|x|x|1|90|100000
EOF_SAMPLE_TRACE
LK_OUT_DIR="$TMP"
. "$TMP/sampled_current_distribution.sh"
_sampled_current="$(lk_emit_sampled_current_distribution "$TMP/phase_ledger.tsv")"
printf '%s\n' "$_sampled_current" | grep -Eq '^active[[:space:]]+3\.3[[:space:]]+6[[:space:]]+250\.0[[:space:]]+100\.0$' || { echo 'FAIL logkit capture-quality: mapped active raw-sample mean/median' >&2; exit 1; }
printf '%s\n' "$_sampled_current" | grep -Eq '^idle[[:space:]]+1\.7[[:space:]]+1[[:space:]]+900\.0[[:space:]]+900\.0$' || { echo 'FAIL logkit capture-quality: endpoint belongs to next interval once' >&2; exit 1; }
printf '%s\n' "$_sampled_current" | grep -Fq 'not causal attribution' || { echo 'FAIL logkit capture-quality: sampled-current disclaimer missing' >&2; exit 1; }

# Mobile traffic is a qualified phase context only. Aggregate two active blocks across the
# 32 MiB report-only threshold and keep a 31 MiB idle block out of the listing.
need "$LOGKIT" '===== MOBILE TRAFFIC CONTEXT ====='
need "$LOGKIT" 'LK_MOBILE_TRAFFIC_CONTEXT_MIN_MIB=32'
need "$LOGKIT" 'does not prove cause or assign battery percentage'
sed -n '/^lk_emit_mobile_traffic_context() {/,/^}/p' "$LOGKIT" > "$TMP/mobile_traffic_context.sh"
[ -s "$TMP/mobile_traffic_context.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract mobile-traffic helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_TRAFFIC_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
active	100	200	90	90	40	35	1000000	0	0	0	0	0	20971520	0
idle	200	300	90	90	40	35	1000000	0	0	0	0	0	32505856	0
active	300	400	90	90	40	35	1000000	0	0	0	0	0	13631488	0
EOF_TRAFFIC_LEDGER
LK_OUT_DIR="$TMP" LK_MOBILE_TRAFFIC_CONTEXT_MIN_MIB=32
. "$TMP/mobile_traffic_context.sh"
_traffic_context="$(lk_emit_mobile_traffic_context "$TMP/phase_ledger.tsv")"
printf '%s\n' "$_traffic_context" | grep -Eq '^active[[:space:]]+3\.3[[:space:]]+33\.0[[:space:]]+screen-on$' || { echo 'FAIL logkit capture-quality: aggregated traffic context' >&2; exit 1; }
if printf '%s\n' "$_traffic_context" | grep -Eq '^idle[[:space:]]'; then
  echo 'FAIL logkit capture-quality: below-threshold mobile traffic was listed' >&2
  exit 1
fi
printf '%s\n' "$_traffic_context" | grep -Fq 'does not prove cause or assign battery percentage' || { echo 'FAIL logkit capture-quality: mobile-traffic disclaimer missing' >&2; exit 1; }

# New verdict code must remain read-only: no global runtime-policy writes are allowed here.
if grep -nE 'setprop|settings[[:space:]]+put|sysctl[[:space:]]+-w|swapoff|svc[[:space:]]+power|reboot' "$LOGKIT" >/dev/null 2>&1; then
  echo "FAIL logkit capture-quality: full-day telemetry gained a policy write" >&2
  exit 1
fi

echo 'PASS logkit capture-quality telemetry contract'
)

t_logkit_cluster_wakelock_runtime() (
# Runtime (fix130): the full-day report says which cluster carried the screen-on work and
# who held a wakelock while the phone charged.
#
# An OP15 capture on V65-debug5: the prime above a quarter of its top clock in 90% of the
# screen-on samples, the main cores in 32%, and the split followed the ceilings. The same
# capture's "anomaly: charging idle stayed awake" pointed at a batterystats ranking that was
# empty - batterystats counts nothing on the charger - while the live power-manager samples
# showed a proxy app holding a partial wakelock in every one of them. The REAL report
# functions run on fixtures and a fake two-cluster sysfs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
fail() { echo "FAIL logkit cluster/wakelock: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="$T/sys"; O="$T/out"
mkdir -p "$F/cpufreq/policy0" "$F/cpufreq/policy6" "$F/cpu0" "$F/cpu6" "$O"
echo 762 > "$F/cpu0/cpu_capacity"; echo 1024 > "$F/cpu6/cpu_capacity"
echo 3628800 > "$F/cpufreq/policy0/cpuinfo_max_freq"; echo 4608000 > "$F/cpufreq/policy6/cpuinfo_max_freq"
echo "6 7" > "$F/cpufreq/policy6/related_cpus"

echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
echo "epoch|x|x|x|x|x|x|x|x|x|x|x|p0_cur|p0_max|p6_cur|p6_max" > "$O/perf_trace.txt"
i=0
while [ $i -lt 14 ]; do
  e=$((1000 + i * 20))
  echo "$e|d|active|1|1000|4094|25|120|300||" >> "$O/display_trace.txt"
  # 8 samples main 1555200 / prime 1862400 with the prime working; 4 level (1996800) with it idle;
  # 2 within 10% (1900800 = capacity 399 of the prime's 414, fix132) with it idle.
  # fix156: discharge current in column 22, surface temperature in column 36; the first five
  # below-the-prime samples and two level ones are warm.
  sf=33; [ $i -lt 5 ] && sf=41; [ $i -eq 8 ] || [ $i -eq 9 ] && sf=42
  if [ $i -lt 8 ]; then row="883200|1555200|1862400|1862400"; ma=480
  elif [ $i -lt 12 ]; then row="1996800|1996800|768000|1862400"; ma=320
  else row="1900800|1900800|768000|1862400"; ma=400; fi
  echo "$e|d|||||||||||$row||||||$ma||||||||||||||$sf" >> "$O/perf_trace.txt"
  i=$((i + 1))
done
for e in 2000 2020 2040 2060; do
  echo "$e|d|charging_idle|0|0|4094|0||-120||" >> "$O/display_trace.txt"
done
cat > "$O/wake_live.txt" <<'X'
1000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'ScreenOnOnly' ACQ=-50m0s1ms LONG (uid=10999 pid=1);
2000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-9m7s229ms LONG (uid=10383 pid=16659);PARTIAL_WAKE_LOCK                 '*sync*/com.android.contacts/com.whatsapp' ACQ=-47s696ms (uid=1000 pid=4813 ws=WorkSource{10384});
2020|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-23m57s318ms LONG (uid=10383 pid=16659);PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-3s916ms (uid=1041 ws=WorkSource{ chains=WorkChain{(10382), (1041)}});
2040|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-1h2m4s5ms LONG (uid=10383 pid=16659);
2060|kactive=0|ktop=|plocks=
X
printf '10383 com.amurcanov.tgwsproxy\n10384 com.whatsapp\n1000 com.oplus.atlas\n10382 org.telegram.messenger\n' > "$O/uid_map.txt"

out="$(LK_CPU_SYSFS="$F" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_cluster_work_summary; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$out" | grep -q '^screen-on samples 14: prime cores working in 57%, main cores in 42%$' || fail "cluster split: $out"
printf '%s\n' "$out" | grep -qE 'level with the prime .*: +4 samples, prime working in 0%' || fail "level bucket: $out"
printf '%s\n' "$out" | grep -qE "more than 10% below the prime's: +8 samples, prime working in 100%" || fail "below bucket: $out"
printf '%s\n' "$out" | grep -qE "within 10% of the prime's: +2 samples, prime working in 0%, mean 400 mA$" || fail "near bucket: $out"
printf '%s\n' "$out" | grep -qE "more than 10% below the prime's: +8 samples, prime working in 100%, mean 480 mA$" || fail "below bucket current: $out"
printf '%s\n' "$out" | grep -q '^  warm (surface 40 C and above), 7 samples:$' || fail "warm split: $out"
printf '%s\n' "$out" | grep -qE '^    main level with the prime: +2 samples, prime working in 0%, mean 320 mA$' || fail "warm level row: $out"
printf '%s\n' "$out" | grep -qE '^    main more than 10% below it: +5 samples, prime working in 100%, mean 480 mA$' || fail "warm below row: $out"
printf '%s\n' "$out" | grep -q 'main within 10% of the prime.s:   ' && fail "a warm row printed with no warm samples: $out"
printf '%s\n' "$out" | grep -q '^screen-off samples: 4$' || fail "screen-off samples: $out"
printf '%s\n' "$out" | grep -qE '^  held in  75% of samples, longest hold   62 min  TgWsProxy::ServiceWakeLock  \(com.amurcanov.tgwsproxy\)$' || fail "proxy not ranked first with its longest hold: $out"
printf '%s\n' "$out" | grep -q 'com.android.contacts/com.whatsapp  (com.whatsapp)' || fail "compact WorkSource uid not resolved: $out"
printf '%s\n' "$out" | grep -q 'ScreenOnOnly' && fail "a screen-on sample counted: $out"
# Not shown on a three-cluster phone.
mkdir -p "$F/cpufreq/policy2"
out2="$(LK_CPU_SYSFS="$F" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_cluster_work_summary' "$C" "$O" 2>&1)"
[ -z "$out2" ] || fail "cluster summary printed on a 3-cluster layout: $out2"
grep -q '^    lk_emit_cluster_work_summary$' "$FD" || fail "report does not include the cluster summary"
grep -q '^  lk_emit_live_wakelock_holders$' "$FD" || fail "report does not include the live wakelock holders"
grep -q 'LIVE WAKELOCK HOLDERS below names who held the CPU' "$FD" || fail "charging verdict still points at the empty ranking"
echo "PASS logkit cluster/wakelock: screen-on work by cluster, wakelock holders while charging"
)

t_logkit_detach_sysui_sco_runtime() (
# Runtime + contract: fix67 field reports.
#  1. A capture started from the manager app escapes the app's cgroup (frozen/killed with
#     the app on KernelSU: a "24 h" capture held ten minutes of samples).
#  2. bt_sco is classified as the call link - in the logkit (was route=none) and in the DSP
#     route publishers (was "bt", so a Bluetooth boost processed a VoIP call).
#  3. A SystemUI restart during a capture is recorded with the crash/ANR evidence.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit detach/sysui/sco: $*" >&2; fail=1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"

run_fn() {   # source the common file in a subshell and run one function
  ( set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1; "$@" )
}

# --- 1. cgroup escape -------------------------------------------------------------------
printf '0::/uid_10853/pid_4242\n' > "$T/cg"
true > "$T/root1"; true > "$T/root2"
out="$(ASB_LK_CG_FILE="$T/cg" ASB_LK_CG_ROOTS="$T/root1 $T/root2 $T/absent" run_fn lk_escape_app_cgroup 777)"
[ "$(cat "$T/root1")" = 777 ] && [ "$(cat "$T/root2")" = 777 ] || f "pid not written to the root groups"
# The fake cgroup file still says uid_ (nothing moved it for real) -> must report failed,
# never claim success it cannot see.
[ "$out" = failed ] || f "escape claimed '$out' while the process is still in uid_"
printf '0::/\n' > "$T/cg2"
out="$(ASB_LK_CG_FILE="$T/cg2" ASB_LK_CG_ROOTS="$T/root1" run_fn lk_escape_app_cgroup 778)"
[ "$out" = not_needed ] || f "a process outside any app group should not be moved ($out)"
grep -Fq 'LK_CGROUP_ESCAPE="$(lk_escape_app_cgroup $$)"' "$C" || f "lk_init does not escape the app cgroup"
grep -q '_recorder_cgroup.txt' "$C" || f "capture does not record its cgroup"

# --- 2. bt_sco classification ---------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/dumpsys" <<'X'
#!/bin/sh
cat <<'D'
Audio mode:
- mode (internal) = MODE_IN_COMMUNICATION
- mode (external) = MODE_IN_COMMUNICATION
mode owner: pid: 5555 uid: 10499
  AudioPlaybackConfiguration piid:1 deviceIds:[3] type:android.media.AudioTrack u/pid:10499/5555 state:started attr:x
- STREAM_MUSIC:
   Muted: false
   Devices: bt_sco
- STREAM_ALARM:
   Devices: speaker
D
X
chmod +x "$T/bin/dumpsys"
res="$(PATH="$T/bin:$PATH" run_fn sh -c 'true' ; ( set +u; PATH="$T/bin:$PATH"; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1; lk_dumpsys() { dumpsys "$@"; }; lk_sample_audio; echo "$LK_AUDIO_ROUTE|$LK_AUDIO_MODE|$LK_AUDIO_MODE_OWNER" ))"
case "$res" in
  "bt_sco|MODE_IN_COMMUNICATION|mode owner: pid: 5555 uid: 10499"*) : ;;
  *) f "bt_sco/mode not classified: '$res'" ;;
esac
grep -q 'bt|bt_le|bt_sco) _apn="audio_bt"' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "bt_sco not mapped to a Bluetooth audio phase"
grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _now="call"' "$ROOT/service.sh" || f "live DSP route watcher still calls SCO bt"
grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _asb_route="call"' "$ROOT/runtime/asb_audio_apply.sh" || f "audio apply still calls SCO bt"
grep -q 'call:\*) _dsp_ra=0' "$ROOT/runtime/asb_audio_apply.sh" || f "call route not excluded from processing"

# --- 3. SystemUI restart recorder -------------------------------------------------------
cat > "$T/bin/pidof" <<'X'
#!/bin/sh
cat "$SYSUI_PIDF"
X
cat > "$T/bin/logcat" <<'X'
#!/bin/sh
echo "10-08 19:54:30 E AndroidRuntime: FATAL EXCEPTION: main Process: com.android.systemui"
X
chmod +x "$T/bin/"*
mkdir -p "$T/out"
echo 1000 > "$T/pid"
( set +u; PATH="$T/bin:$PATH"; SYSUI_PIDF="$T/pid"; export SYSUI_PIDF
  LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1
  lk_dumpsys() { echo "dropbox $*"; }
  LK_OUT_DIR="$T/out"
  lk_sysui_watch_row; lk_sysui_watch_row
  echo 2000 > "$T/pid"; lk_sysui_watch_row; lk_sysui_watch_row
  echo "$LK_SYSUI_RESTARTS" > "$T/count" )
[ "$(cat "$T/count")" = 1 ] || f "restart count $(cat "$T/count") (want 1)"
grep -q 'SYSTEMUI RESTART .* pid 1000 -> 2000' "$T/out/sysui_restarts.txt" || f "restart not recorded"
grep -q 'FATAL EXCEPTION' "$T/out/sysui_restarts.txt" || f "crash evidence not captured"
grep -q 'dropbox --print system_app_anr' "$T/out/sysui_restarts.txt" || f "ANR dropbox not captured"
grep -q 'lk_sysui_watch_row' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "full-day capture does not watch SystemUI"
grep -q 'SYSTEMUI RESTARTS' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "report has no SystemUI section"

[ "$fail" = 0 ] && echo "PASS logkit detach/sysui/sco runtime"
exit "$fail"
)

t_logkit_stale_temp_runtime() (
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
)

t_logkit_sysui_redraw_runtime() (
# Runtime (fix159): when SystemUI misses frames in every interval, the report names the
# status-bar settings that redraw every second.
#
# The owner's OP15 shows SystemUI at about one janky frame a second in every screen-on interval
# of four captures, at 60, 90 and 120 Hz alike - against 0.05-0.2 a second on two other OP15s
# and an OP15R. The report already says "a steady redraw, turn off what updates every second",
# but not what is switched on. The REAL capture function records the status-bar settings once
# (fake `settings` here), and the REAL report prints them under the steady-redraw line - only
# when SystemUI is the steady source, and nothing when the phone has none of those settings.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL sysui redraw: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/a" "$T/b"
cat > "$T/bin/settings" <<'S'
#!/bin/sh
[ "$1" = list ] || exit 0
case "$2" in
  system) printf '%s\n' 'peak_refresh_rate=165.0' 'show_network_speed=1' 'status_bar_show_battery_percent=1' 'screen_off_timeout=30000' \
            'oplus.radio.smart5g_apk_cfg=ver_num=9;filetrans=org.zwanoo.android.speedtest,com.Wifi.lte5g.Internetspeed;others=com.antutu.ABenchMark' ;;
  secure) printf '%s\n' 'clock_seconds=1' 'doze_always_on=0' 'icon_blacklist=rotate,ime,show_network_speed,vpn' ;;
  global) printf '%s\n' 'wifi_on=1' ;;
esac
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = wallpaper ] || exit 0
printf '%s\n' 'System wallpaper state:' ' User 0: id=12 mWidth=1440' '  mWallpaperComponent=ComponentInfo{com.example.live/com.example.live.Waves}'
S
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_display_config_capture' "$C" "$T/a"
D="$T/a/display_config.txt"
grep -qx '## status bar redraw settings' "$D" || f "no status-bar section in display_config"
grep -qx 'system: show_network_speed=1' "$D" || f "network speed meter not recorded"
grep -qx 'secure: clock_seconds=1' "$D" || f "seconds on the clock not recorded"
grep -q 'screen_off_timeout\|doze_always_on\|wifi_on' "$D" && f "unrelated settings recorded"
# fix168: the owner's capture listed oplus.radio.smart5g_apk_cfg - two kilobytes of 5G app
# lists - because its VALUE holds "Internetspeed". Keys are matched, not values.
grep -q 'smart5g_apk_cfg' "$D" && f "a setting matched on its value"
grep -qx 'secure: icon_blacklist=rotate,ime,show_network_speed,vpn' "$D" || f "hidden status-bar icons not recorded"
grep -qx 'wallpaper: ComponentInfo{com.example.live/com.example.live.Waves} - a wallpaper service; a live one redraws whenever it is visible' "$D" || f "wallpaper not recorded"
J="$T/a/jank_trace.tsv"
echo "# epoch|iso_time|phase|fsm_state|interval_s|main_at_cap|prime_at_cap|touches|frames|janky|deadline_missed|slow_ui|high_input|main_cap_pct|prime_cap_pct|fg_pkg|jank_pkgs" > "$J"
i=0
while [ $i -lt 10 ]; do
  i=$((i + 1))
  printf '%s|t|active|MODERATE|48|0|0|1|4000|60|60|10|5|1|0|com.twitter.android|com.android.systemui:48:200,com.twitter.android:12:3800\n' "$i" >> "$J"
done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out" | grep -q '^com.android.systemui missed deadlines in 10 of 10 screen-on intervals' || f "steady redraw line missing: $out"
printf '%s\n' "$out" | grep -q '^status-bar settings read on this phone at the start of the capture:$' || f "settings heading missing: $out"
printf '%s\n' "$out" | grep -qx '  system: show_network_speed=1' || f "network speed not listed: $out"
printf '%s\n' "$out" | grep -qx '  secure: clock_seconds=1' || f "clock seconds not listed: $out"
printf '%s\n' "$out" | grep -q '^  wallpaper: ComponentInfo{com.example.live' || f "wallpaper not listed: $out"
cp "$J" "$T/b/jank_trace.tsv"
out2="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/b" 2>&1)"
printf '%s\n' "$out2" | grep -q 'missed deadlines in 10 of 10' || f "steady redraw line missing without a config file"
printf '%s\n' "$out2" | grep -q 'status-bar settings read' && f "a settings heading printed with nothing recorded: $out2"
sed 's/com.android.systemui:48:200,com.twitter.android:12:3800/com.twitter.android:60:4000/' "$J" > "$T/a/j2" && mv "$T/a/j2" "$J"
out3="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out3" | grep -q 'status-bar settings read' && f "status-bar settings printed for an app that is not SystemUI: $out3"
[ "$fail" = 0 ] && echo "PASS sysui redraw: the status-bar settings that redraw every second are recorded and named under a steady SystemUI redraw"
exit "$fail"
)

t_logkit_sysui_verdict_runtime() (
# Runtime (fix133): a SystemUI restart in the full-day capture carries one line saying why.
#
# The restart block showed "dropbox system_app_crash (latest)" - the latest crash of ANY
# system app. An OP15 capture had a Contacts crash there for both SystemUI restarts, while
# the crash buffer held the real cause: SIGSEGV in libart.so (ProfileSaver) inside
# com.android.systemui. The REAL verdict function runs on fixtures cut from that capture.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
fail() { echo "FAIL logkit sysui verdict: $*" >&2; exit 1; }
v() { sh -c '. "$0" >/dev/null 2>&1; lk_sysui_verdict' "$C"; }

# A native crash of SystemUI, after an unrelated process's tombstone.
out="$(v <<'T'
10-12 11:20:00.000   700   700 F DEBUG   : pid: 9001, tid: 9001, name: something  >>> com.android.contacts <<<
10-12 11:20:00.000   700   700 F DEBUG   : signal 7 (SIGBUS), code 2 (BUS_ADRERR), fault addr 0x1
10-12 11:20:00.000   700   700 F DEBUG   :       #00 pc 000000000007126c  /system/lib64/libft2.so (tt_face_load_strike_metrics+96) (BuildId: d9)
10-12 11:25:10.110   759   759 F DEBUG   : pid: 8142, tid: 8230, name: Profile Saver  >>> com.android.systemui <<<
10-12 11:25:10.110   759   759 F DEBUG   : signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x00000000c2e15038
10-12 11:25:10.111   759   759 F DEBUG   :       #00 pc 00000000004feeb8  /apex/com.android.art/lib64/libart.so (void art::ProfileSaver::GetClassesAndMethodsHelper::CollectInternal<false>(art::Handle<art::mirror::ClassLoader>)+176) (BuildId: a4)
T
)"
case "$out" in "native crash SIGSEGV in libart.so (art::ProfileSaver::"*"not a kill") : ;; *) fail "native: $out" ;; esac
# A Java crash.
out="$(v <<'T'
10-12 11:25:10.000  8142  8142 E AndroidRuntime: FATAL EXCEPTION: main
10-12 11:25:10.000  8142  8142 E AndroidRuntime: Process: com.android.systemui, PID: 8142
10-12 11:25:10.000  8142  8142 E AndroidRuntime: java.lang.IllegalStateException: View not attached
T
)"
[ "$out" = "Java crash: java.lang.IllegalStateException: View not attached" ] || fail "java: $out"
# Another process crashed; SystemUI did not.
out="$(v <<'T'
10-12 11:20:00.000   700   700 F DEBUG   : pid: 9001, tid: 9001, name: x  >>> com.android.contacts <<<
10-12 11:20:00.000   700   700 F DEBUG   : signal 7 (SIGBUS), code 2 (BUS_ADRERR), fault addr 0x1
10-12 11:20:00.000   700   700 F DEBUG   :       #00 pc 000000000007126c  /system/lib64/libft2.so (tt+96)
10-11 22:08:35.415   654   654 E lowmemorykiller: device has enough memory 4998492Kib, disable killing
T
)"
case "$out" in "no SystemUI crash in the crash buffer"*) : ;; *) fail "other process taken for SystemUI: $out" ;; esac
# A low-memory kill of SystemUI.
out="$(v <<'T'
10-12 11:25:10.000   654   654 I lowmemorykiller: Kill 'com.android.systemui' (8142), uid 10283, oom_score_adj -800
T
)"
[ "$out" = "killed by lowmemorykiller" ] || fail "lmk: $out"
grep -q 'echo "verdict: $(printf' "$C" || fail "restart block does not record the verdict"
grep -q '/^verdict: / { print "      " $0 }' "$FD" || fail "report does not print the verdict"
echo "PASS logkit sysui verdict: native, Java, other-process and low-memory cases"
)

t_logkit_traffic_edge_runtime() (
# Runtime (fix137): the screen-off traffic line and the phase table add up.
#
# Capture 2830: "sleep ... rmnetMiB 168.7" in the phase table, "measured screen-off mobile
# traffic 45.7 MiB" below it. Both were right - the 122.9 MiB moved in the interval in which
# the morning screen came on, which the table counts and the measured line silently dropped.
# The REAL awk from asb_log_full_day.sh runs against a battery_trace fixture.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/tools/logkit/asb_log_full_day.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL logkit traffic edge: $*" >&2; exit 1; }
# The program between the quotes of  _meas="$(awk -F'|' -v A=.. -v Z=.. '<program>' file)".
awk '/_meas="\$\(awk -F.\|. -v A="\$_a" -v Z="\$_z" .\$1/ { on = 1 }
     on { print }
     on && /END \{ printf "%d %d %d", m \+ 0, e \+ 0, wf \+ 0 \}/ { exit }' "$SRC" \
  | sed -e "1s/^.*-v Z=\"\$_z\" '//" -e "\$s/' \"\$LK_OUT_DIR.*\$//" > "$TMP/meas.awk"
grep -q 'else if (ps != \$5) e += b - pb' "$TMP/meas.awk" || fail "edge accounting not found"
# epoch|...|screen(5)|...|wifi_rx(24)|wifi_tx(25)|rmnet_rx(26)|rmnet_tx(27): only the columns
# the program reads matter. fix148: Wi-Fi with the screen off is the third figure; a Wi-Fi
# counter that went backwards (interface restarted) adds nothing.
row() { printf '%s|x|x|x|%s|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|%s|0|%s|%s\n' "$1" "$2" "$5" "$3" "$4"; }
{ row 1000 1 100 0 0          # screen on before the phase
  row 1100 0 200 0 1000       # phase starts (screen off)
  row 1200 0 1048776 0 2098152  # +1 MiB mobile, +2 MiB Wi-Fi with the screen off
  row 1250 0 2097352 0 500    # +1 MiB mobile; Wi-Fi counter reset
  row 1300 0 3145928 0 1049076  # +1 MiB mobile, +1 MiB Wi-Fi
  row 1302 1 9437384 0 9999999; } > "$TMP/bt.txt"   # the morning: +6 MiB across the screen-on edge
out="$(awk -F'|' -v A=1100 -v Z=1301 -f "$TMP/meas.awk" "$TMP/bt.txt")"
[ "$out" = "3145728 6291456 3145728" ] || fail "measured/edge/Wi-Fi split wrong: $out"
grep -q 'in the interval the screen changed state' "$SRC" || fail "edge traffic not printed"
grep -q 'measured screen-off mobile traffic %.1f MiB, Wi-Fi %.1f MiB' "$SRC" || fail "Wi-Fi not printed beside mobile"
echo "PASS logkit traffic edge: screen-off measured and screen-change edge reported apart, adding up to the table, Wi-Fi beside mobile"
)

t_logkit_wifi_leave_runtime() (
# Runtime (fix152): the full-day capture keeps the Wi-Fi leave watcher's events and says how
# long leaving took.
#
# Testers: "it leaves Wi-Fi about 10 s sooner, but still holds a dead access point for about
# 10 s". The watcher's own log keeps 80 lines and no capture copied it, so neither that nor
# the fix151 change could be measured. The REAL collector copies new lines each poll -
# nothing from before the capture, nothing twice, also after the watcher trims its log - and
# the REAL report section counts releases by reason and the time from the first failing
# reading to the release.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit wifi leave: $*" >&2; fail=1; }
mkdir -p "$T/out" "$T/mod/config"
{ sed -n '/^lk_wifi_leave_collect() {$/,/^}$/p' "$S"; sed -n '/^lk_emit_wifi_leave_summary() {$/,/^}$/p' "$S"; } > "$T/f.sh"
grep -q '^lk_emit_wifi_leave_summary() {$' "$T/f.sh" || f "summary function not found"
grep -q '^  lk_wifi_leave_collect$' "$S" || f "the poll loop does not collect"
grep -q '^    lk_emit_wifi_leave_summary$' "$S" || f "the report has no Wi-Fi leave section"
printf 'net_wifi_leave=aggressive\nnet_wifi_leave_dbm=-80\n' > "$T/mod/config/governor.conf"
L="$T/wifi_fallback.log"
w() { printf '%s wifi_fallback: %s\n' "$1" "$2" >> "$L"; }
w '2026-10-20 08:00:00' 'out of range (rssi=-88) pass 1/3'
w '2026-10-20 08:00:03' 'out of range (rssi=-88) pass 2/3'
w '2026-10-20 08:00:06' 'out of range (rssi=-88) - releasing Wi-Fi default route for 30s'
run() { LK_OUT_DIR="$T/out" LK_MODDIR="$T/mod" LK_WIFI_FALLBACK_LOG="$L" LK_WIFI_SINCE='2026-10-20 09:00:00' sh -c '. "$1"; '"$1" x "$T/f.sh"; }
run lk_wifi_leave_collect
[ -s "$T/out/wifi_leave_events.log" ] && f "events from before the capture were copied"
w '2026-10-20 09:10:00' 'out of range (rssi=-86) pass 1/3'
w '2026-10-20 09:10:03' 'out of range (rssi=-86) pass 2/3'
w '2026-10-20 09:10:06' 'out of range (rssi=-86) - releasing Wi-Fi default route for 30s'
run lk_wifi_leave_collect
run lk_wifi_leave_collect
[ "$(grep -c . "$T/out/wifi_leave_events.log")" = 3 ] || f "first copy wrong: $(cat "$T/out/wifi_leave_events.log")"
w '2026-10-20 09:10:36' 'Wi-Fi re-enabled after ASB fallback window'
w '2026-10-20 09:10:36' 'cooldown started (300s)'
w '2026-10-20 09:30:00' 'out of range (rssi=-84) pass 1/3'
w '2026-10-20 09:40:00' 'unvalidated Wi-Fi pass 1/3 (rssi=-50) - waiting'
w '2026-10-20 09:40:03' 'unvalidated Wi-Fi pass 2/3 (rssi=-50) - waiting'
w '2026-10-20 09:40:09' 'released unvalidated Wi-Fi default route for 60s'
tail -n 4 "$L" > "$L.t"; mv "$L.t" "$L"
w '2026-10-20 10:00:00' 'could not disable Wi-Fi; no route action taken'
run lk_wifi_leave_collect
[ "$(grep -c 'released unvalidated' "$T/out/wifi_leave_events.log")" = 1 ] || f "line after a trimmed log lost or doubled"
[ "$(grep -c 'pass 1/3' "$T/out/wifi_leave_events.log")" -ge 2 ] || f "streak starts lost"
run lk_emit_wifi_leave_summary > "$T/rep"
grep -qx 'rung now: aggressive, threshold -80 dBm' "$T/rep" || f "rung line: $(cat "$T/rep")"
grep -q '^releases: 2 (out of range 1, no internet 1) - Wi-Fi given back after the window: 0, could not disable: 1$' "$T/rep" || f "counts: $(cat "$T/rep")"
grep -qx 'first failing reading to the release: median 7 s, longest 9 s (2 release(s))' "$T/rep" || f "timing: $(cat "$T/rep")"
grep -qx 'failing streaks that recovered before a release: 1' "$T/rep" || f "recovered: $(cat "$T/rep")"
rm -f "$T/out/wifi_leave_events.log"
run lk_emit_wifi_leave_summary > "$T/rep"
grep -qx 'no watcher events in this capture' "$T/rep" || f "empty capture: $(cat "$T/rep")"
[ "$fail" = 0 ] && echo "PASS logkit wifi leave: watcher events kept for the whole capture, releases timed from the first failing reading"
exit "$fail"
)

t_webui_back_nav_runtime() (
# Runtime (fix159): the back gesture steps back inside the WebUI and leaves it only from Home;
# the Monitor's Smart card shows the drain with the screen on and off and opens a sheet with
# what each figure is based on.
#
# Asked for: from a category, a popup or any page but Home, back should go back inside the
# WebUI (as other modules do); only back on Home leaves. A root manager's WebView goes back
# through the page's history before it closes, so the page keeps one history entry per open
# level. The REAL navigation code runs in node against a history that behaves like a WebView's
# (pushState, go(-n) answered by an asynchronous popstate, nothing left = the manager closes the
# page), and the REAL drain sheet painter is run with the Smart card's figures.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui back nav: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui back nav: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ "$(grep -c "addEventListener('popstate'" "$H")" = 1 ] || fail "more than one popstate handler - two would both act on one back"
grep -q 'if (typeof navSyncSoon === .function.) navSyncSoon();' "$H" || fail "category changes do not resync the history"
for id in bnDrainStrip bnDrainOff bnSlotTemp bnDrain; do grep -q "id=\"$id\"" "$H" || fail "Smart card lacks #$id"; done
grep -q 'onclick="liveDrainOpen()"' "$H" || fail "the drain strip does not open the sheet"
for l in en ru uk de es fr it pt tr id ar hy zh; do
  J="$ROOT/webroot/i18n/$l.json"
  for k in lv_slot_heat lv_heat_cool lv_heat_norm lv_heat_warm lv_heat_tip lv_drain_on_meter lv_drain_cmp lv_scr_on lv_scr_off lv_drain_title lv_drain_on_now lv_drain_on_recent lv_drain_on_slot lv_drain_on_wait lv_drain_off_measured lv_drain_off_wait lv_drain_left lv_drain_note; do
    grep -q "\"$k\"" "$J" || fail "$l.json lacks $k"
  done
  for k in lv_drain_on_now lv_drain_off_measured lv_drain_left; do
    grep -q "\"$k\": \"[^\"]*%s" "$J" || fail "$l.json $k has no place for its number"
  done
done
{
  sed -n '/^const NAV_OVERLAYS = \[/,/^})();$/p' "$H"
  cat <<'EOF'
;
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
async function tick() { for (let i = 0; i < 6; i++) await new Promise(function (r) { setImmediate(r); }); }
async function back() { if (!hist.canGoBack()) { exited++; return; } hist.go(-1); await tick(); }
(async function () {
  chk(_nav.depth === 0 && hist.idx === 0, 'start: ' + _nav.depth + '/' + hist.idx);
  _liveOpen = true; navSync();
  chk(hist.idx === 1, 'Monitor opened: one history entry, have ' + hist.idx);
  _el('liveDrainSheet').hidden = false; navSync();
  chk(hist.idx === 2, 'drain sheet opened: two entries, have ' + hist.idx);
  await back();
  chk(_el('liveDrainSheet').hidden === true && _liveOpen === true, 'back closed the sheet and kept Monitor');
  await back();
  chk(_liveOpen === false && hist.idx === 0 && exited === 0, 'back from Monitor went Home, not out: live=' + _liveOpen + ' idx=' + hist.idx);
  await back();
  chk(exited === 1, 'back on Home leaves the WebUI');

  exited = 0;
  _cfgOpen = true; navSync(); _cfgGroup = 'battery'; navSync(); _el('dozeKeepModal').hidden = false; navSync();
  chk(hist.idx === 3, 'Settings > Battery > picker: three entries, have ' + hist.idx);
  await back();
  chk(_el('dozeKeepModal').hidden && _cfgGroup === 'battery' && _cfgOpen, 'back closed the picker only');
  await back();
  chk(_cfgGroup === null && _cfgOpen, 'back left the category for the Settings hub');
  await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'back from the hub went Home');

  _cfgOpen = true; _cfgGroup = 'audio'; navSync();
  chk(hist.idx === 2, 'category opened: two entries, have ' + hist.idx);
  _cfgGroup = null; navSync(); await tick();
  chk(hist.idx === 1 && _cfgOpen && !_nav.pending, 'category closed by a tap: history stepped back once without acting, idx=' + hist.idx);
  await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'next back went Home after a tap-close');

  _liveOpen = true; navSync(); _liveOpen = false; _cfgOpen = true; navSync(); await tick();
  chk(hist.idx === 1, 'switching tabs Monitor -> Settings keeps one entry, have ' + hist.idx);
  _el('logMenu').hidden = false; _el('cfgFm').hidden = false; navSync();
  chk(hist.idx === 3, 'two overlays over Settings: three entries, have ' + hist.idx);
  await back();
  chk(_el('logMenu').hidden && !_el('cfgFm').hidden, 'back closes one overlay at a time');
  await back(); await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'everything closed, Home reached, nothing left the WebUI');
  await back();
  chk(exited === 1, 'and only now does back leave');

  _lvDrain.on = 'recent'; _lvDrain.off = 'measured'; _lvDrain.offN = 3; _lvDrain.winS = 0;
  _el('bnDrain').textContent = '~8.5%/h'; _el('bnDrainOff').textContent = '0.52%/h';
  _el('liveEtaOn').textContent = '8h 56m'; _el('liveEtaOff').textContent = '> 72h';
  liveDrainPaint();
  const blocks = _el('liveDrainBody').children;
  chk(blocks.length === 3, 'sheet: two figures and a note, have ' + blocks.length);
  const txt = function (b) { return b.children[1].children.map(function (c) { return c.className + '=' + c.textContent; }).join(' | '); };
  const on = txt(blocks[0]), off = txt(blocks[1]);
  chk(/live-drain-val=~8\.5%\/h/.test(on) && /lv_drain_on_recent/.test(on) && /to 0%: 8h 56m/.test(on), 'screen-on block: ' + on);
  chk(/live-drain-val=0\.52%\/h/.test(off) && /stretch\(es\)/.test(off) && / 3 /.test(off) && /to 0%: > 72h/.test(off), 'screen-off block: ' + off);
  _lvDrain.on = 'charging'; _lvDrain.off = 'wait'; liveDrainPaint();
  const on2 = txt(_el('liveDrainBody').children[0]), off2 = txt(_el('liveDrainBody').children[1]);
  chk(!/to 0%/.test(on2), 'no time-to-empty while charging: ' + on2);
  chk(/lv_drain_off_wait/.test(off2), 'screen-off waits for an hour of screen off: ' + off2);
  if (bad) process.exit(1);
  console.log('ok');
})();
EOF
} > "$T/body.js"
cat > "$T/run.js" <<'EOF'
const fs = require('fs');
const els = {};
function mk(tag) {
  const e = { tagName: tag, id: '', hidden: true, className: '', innerHTML: '', children: [], attrs: {}, _t: '',
    setAttribute: function (k, v) { this.attrs[k] = v; }, addEventListener: function () {},
    appendChild: function (c) { this.children.push(c); if (c.id) els[c.id] = c; return c; } };
  Object.defineProperty(e, 'textContent', { get: function () { return this._t; }, set: function (v) { this._t = String(v); this.children = []; } });
  return e;
}
['logMenu', 'liveDrainSheet', 'cfgFm', 'dozeKeepModal', 'cfgResetModal', 'cfgProfileModal', 'bnDrain', 'bnDrainOff', 'liveEtaOn', 'liveEtaOff',
 'liveDrainBody', 'liveDrainTitle', 'liveDrainDone'].forEach(function (id) { const e = mk('div'); e.id = id; els[id] = e; });
['bnDrain', 'bnDrainOff', 'liveEtaOn', 'liveEtaOff', 'liveDrainBody', 'liveDrainTitle', 'liveDrainDone'].forEach(function (id) { els[id].hidden = false; });
const listeners = {};
const hist = { stack: [{ state: null }], idx: 0,
  pushState: function (s) { this.stack = this.stack.slice(0, this.idx + 1); this.stack.push({ state: s }); this.idx++; },
  canGoBack: function () { return this.idx > 0; },
  go: function (n) { const self = this; setImmediate(function () { self.idx = Math.max(0, self.idx + n); (listeners.popstate || []).forEach(function (f) { f({ state: self.stack[self.idx].state }); }); }); } };
global.hist = hist; global.exited = 0;
global.window = { history: hist, addEventListener: function (t, f) { (listeners[t] = listeners[t] || []).push(f); } };
global.history = hist;
global.document = { body: mk('body'), createElement: mk, addEventListener: function () {} };
global.MutationObserver = function () { this.observe = function () {}; };
global._el = function (id) { return els[id] || null; };
global.T = function (k, d) { return d; };
global.techIcon = function (k) { return '<svg data-k="' + k + '"></svg>'; };
global.uiSound = function () {};
global._liveOpen = false; global._cfgOpen = false; global._cfgGroup = null;
global.closeLivePage = function () { _liveOpen = false; };
global.closeConfigPage = function () { _cfgOpen = false; _cfgGroup = null; };
global.cfgBack = function () { _cfgGroup = null; };
global.asbCloseLogMenu = function () { els.logMenu.hidden = true; };
global.cfgFmClose = function () { els.cfgFm.hidden = true; };
global.dozeKeepClose = function () { els.dozeKeepModal.hidden = true; };
global.cfgResetDialogClose = function () { els.cfgResetModal.hidden = true; };
global.cfgProfileClose = function () { els.cfgProfileModal.hidden = true; };
const src = fs.readFileSync(process.argv[2], 'utf8')
  .replace('const _nav =', 'var _nav =').replace('const _lvDrain =', 'var _lvDrain =')
  .replace(/T\('lv_drain_on_recent', '[^']*'\)/, "'lv_drain_on_recent'").replace(/T\('lv_drain_off_wait', '[^']*'\)/, "'lv_drain_off_wait'");
(0, eval)(src);
EOF
out="$(node "$T/run.js" "$T/body.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui back nav: back closes the top popup, then the category, then the page; only Home lets the WebUI close; the drain sheet shows both figures with their basis"
)

t_webui_doze_keep_picker_runtime() (
# Runtime (fix152): the WebUI picker for apps the Doze trim must leave alone.
#
# Testers asked to choose these apps in the WebUI, easily, with a search. The REAL page
# functions run in node on the REAL applier's `list` output (fake pm / deviceidle):
#   - every user app is offered, not only the ones Android still exempts, and an app ASB
#     already trimmed is there to tick, marked as trimmed;
#   - names come from the root manager when it gives them, and the search finds an app by
#     its name or by its package;
#   - ticked apps come first, then what ASB trimmed, then the exempt ones, then the rest;
#   - the saved file holds exactly the ticked packages, one per line, and nothing else.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui doze keep picker: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui doze keep picker: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q "eb.onclick = (e) => { e.stopPropagation(); uiSound('option'); dozeOpenEditor(); };" "$H" || fail "the card button does not open the picker"
grep -q "run('sh ' + shQuote(MD + '/runtime/asb_doze_apply.sh') + ' list 2>/dev/null')" "$H" || fail "the picker does not read the applier's list"
grep -q "try { await run('sh ' + shQuote(MD + '/runtime/asb_doze_apply.sh') + ' >/dev/null 2>&1'); } catch (e) {}" "$H" || fail "closing the picker does not apply"
grep -q 'id="dozeKeepSearch" type="search"' "$H" || fail "no search field"
for l in en ru uk; do
  for k in doze_keep_title doze_keep_search doze_keep_copy doze_tag_trimmed doze_chip_trimmed doze_keep_saved; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
done
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' com.example.zeta org.telegram.messenger com.example.vpn com.example.game com.azure.authenticator com.whatsapp com.example.alpha
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] && [ "$2" = whitelist ] && [ -z "${3:-}" ] || exit 0
printf '%s\n' 'system-excidle,com.android.phone,1001' 'user,com.example.vpn,10100' 'user,com.azure.authenticator,10101'
S
chmod +x "$T/bin/"*
printf 'doze_level=night\ndoze_trim_whitelist=1\n' > "$T/mod/config/governor.conf"
printf '%s\n' com.example.game > "$T/st/doze_whitelist_removed"
printf '%s\n' com.example.zeta > "$T/st/doze_whitelist_keep"
PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" sh "$ROOT/runtime/asb_doze_apply.sh" list > "$T/list" 2>/dev/null
{
  echo "const DOZE_KEEP_PATH = process.env.KEEP;"
  sed -n '/^const DOZE_MESSENGERS = \[/,/^\];/p' "$H"
  sed -n '/^const _dozeKeep = {/,/};$/p' "$H"
  grep '^function dozePkgOk(p) { return /^\[A-Za-z0-9_.\]+\$/.test(p); }$' "$H"
  for fn in shQuote dozeIsMessenger dozeKeepParse dozeKeepLabels dozeKeepRank dozeKeepMatch dozeKeepWrite; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  cat <<'EOF'
const fs = require('fs'); const cp = require('child_process');
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const d = dozeKeepParse(fs.readFileSync(process.env.LIST, 'utf8'));
chk(d.trim === true, 'night doze with trim on not read as working');
chk(d.apps.length === 7, 'not every user app offered: ' + d.apps.length);
chk(!d.E['com.android.phone'] && !d.apps.some(a => a.pkg === 'com.android.phone'), 'a system entry offered');
chk(d.R['com.example.game'] === 1, 'the app ASB trimmed is not marked');
chk(d.apps.some(a => a.pkg === 'com.example.game'), 'the app ASB trimmed is not offered');
chk(d.apps.find(a => a.pkg === 'com.azure.authenticator').prot === true, 'rule protection lost');
global.ksu = { getPackagesInfo: function (j) {
  const want = JSON.parse(j);
  const names = { 'org.telegram.messenger': 'Telegram', 'com.whatsapp': 'WhatsApp', 'com.example.alpha': 'Альфа Банк', 'com.example.zeta': 'com.example.zeta' };
  return JSON.stringify(want.map(p => ({ packageName: p, appLabel: names[p] || '' })));
} };
const labels = dozeKeepLabels(d.apps.map(a => a.pkg));
chk(labels['org.telegram.messenger'] === 'Telegram', 'name from the root manager not used');
chk(!('com.example.zeta' in labels), 'a label equal to the package treated as a name');
delete global.ksu;
chk(Object.keys(dozeKeepLabels(['com.whatsapp'])).length === 0, 'no root-manager API must give no names, not an error');
global.ksu = { getPackagesInfo: function () { throw new Error('x'); } };
chk(Object.keys(dozeKeepLabels(['com.whatsapp'])).length === 0, 'a failing API must give no names');
delete global.ksu;
const apps = d.apps.map(function (a) {
  const name = labels[a.pkg] || '';
  return { pkg: a.pkg, name: name, prot: a.prot, e: !!d.E[a.pkg], r: !!d.R[a.pkg], g: !!d.G[a.pkg],
    msg: dozeIsMessenger(a.pkg), kept0: !!d.K[a.pkg], q: (name + ' ' + a.pkg).toLowerCase() };
});
apps.sort(function (x, y) { const a = dozeKeepRank(x), b = dozeKeepRank(y); return a !== b ? a - b : (x.name || x.pkg).toLowerCase().localeCompare((y.name || y.pkg).toLowerCase()); });
const order = apps.map(a => a.pkg).join(' ');
chk(order === 'com.example.zeta com.example.game com.example.vpn org.telegram.messenger com.whatsapp com.example.alpha com.azure.authenticator', 'order: ' + order);
_dozeKeep.apps = apps; _dozeKeep.keep = { 'com.example.zeta': 1 };
function hits(q, f) { _dozeKeep.q = q.toLowerCase(); _dozeKeep.filter = f || 'all'; return apps.filter(dozeKeepMatch).map(a => a.pkg).join(' '); }
chk(hits('tele') === 'org.telegram.messenger', 'search by name: ' + hits('tele'));
chk(hits('WHATS') === 'com.whatsapp', 'search is case-sensitive');
chk(hits('альфа') === 'com.example.alpha', 'search by a Cyrillic name: ' + hits('альфа'));
chk(hits('messenger') === 'org.telegram.messenger', 'search by package: ' + hits('messenger'));
chk(hits('', 'trimmed') === 'com.example.game', 'trimmed filter: ' + hits('', 'trimmed'));
chk(hits('', 'kept') === 'com.example.zeta', 'ticked filter: ' + hits('', 'kept'));
chk(hits('zzz') === '', 'a search with no match still shows apps');
let cmd = '';
global.run = function (c) { cmd = c; return Promise.resolve({ errno: cp.spawnSync('sh', ['-c', c]).status }); };
_dozeKeep.keep = { 'org.telegram.messenger': 1, 'com.whatsapp': 1, "x';touch /tmp/asb_pwn;'": 1 };
dozeKeepWrite().then(function () {
  chk(fs.readFileSync(process.env.KEEP, 'utf8') === 'com.whatsapp\norg.telegram.messenger\n', 'file: ' + JSON.stringify(fs.readFileSync(process.env.KEEP, 'utf8')));
  chk(!fs.existsSync('/tmp/asb_pwn') && cmd.indexOf('pwn') < 0, 'an invalid name reached the shell');
  chk(_dozeKeep.failed === false, 'a good write reported as failed');
  _dozeKeep.keep = {};
  return dozeKeepWrite();
}).then(function () {
  chk(fs.readFileSync(process.env.KEEP, 'utf8') === '', 'unticking everything left names in the file');
  process.exit(bad ? 1 : 0);
});
EOF
} > "$T/t.js"
LIST="$T/list" KEEP="$T/keep" node "$T/t.js" || fail "see above"
echo "PASS webui doze keep picker: all user apps, trimmed ones marked, search by name or package, exact keep file"
)

t_webui_doze_keep_tags_runtime() (
# Runtime (fix158): the picker's labels say what will happen, and the night window is named.
#
# Asked: what is the difference between "exempt" and "exempt via ASB", between Ticked and
# Trimmed, and does Trimmed work. The labels were fixed when the list opened, so ticking an
# app ASB had trimmed still read "trimmed by ASB" until the window was closed and opened
# again, and Deep Sleep on night by day showed an empty Trimmed with no reason. The REAL page
# functions run in node:
#   - the applier's window/night lines are read;
#   - each label follows the tick: trimmed -> returns on Done, ASB's exemption -> removed on
#     Done, a new tick -> exempt on Done, an exempt app just unticked -> trimmed on Done (only
#     while the trim is live), and back to the plain label when the tick is undone;
#   - protected apps keep their own label whatever the tick;
#   - every new string exists in every language, and the legend names every label.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui doze keep tags: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui doze keep tags: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q '<details class="doze-keep-legend" id="dozeKeepLegend">' "$H" || fail "no legend in the picker"
grep -q "_dozeKeep.live = d.trim && d.window !== false;" "$H" || fail "the live state ignores the night window"
grep -q "} else if (d.window === false) {" "$H" || fail "no note for the closed night window"
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in doze_tag_back doze_tag_drop doze_tag_willtrim doze_tag_give doze_keep_day doze_keep_legend_title doze_keep_legend; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
  grep -q '"doze_keep_day": "[^"]*%s' "$ROOT/webroot/i18n/$l.json" || fail "$l.json doze_keep_day has no place for the window"
done
python3 - "$ROOT/webroot/i18n" <<'P' || fail "a legend does not name every label"
import json, sys
for l in ("en", "ru", "uk", "de", "es", "fr", "it", "pt", "tr", "id", "ar", "hy", "zh"):
    d = json.load(open("%s/%s.json" % (sys.argv[1], l), encoding="utf-8"))
    leg = d["doze_keep_legend"].lower()
    for k in ("doze_tag_exempt", "doze_tag_granted", "doze_tag_trimmed", "doze_tag_always", "doze_chip_kept", "doze_chip_trimmed"):
        if d[k].lower() not in leg:
            print(l, k, d[k]); sys.exit(1)
P
{
  echo "function T(k, d) { return k; }"
  sed -n '/^const _dozeKeep = {/,/};$/p' "$H"
  for fn in dozeKeepParse dozeKeepTag; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const out = ['trim=1', 'level=night', 'window=0', 'night=23:15-06:40', 'A com.a -', 'A com.b -', 'A com.c -',
  'A com.d -', 'A com.auth p', 'E com.b', 'E com.d', 'E com.auth', 'R com.a', 'G com.b', 'K com.b', 'K com.d'].join('\n');
const d = dozeKeepParse(out);
chk(d.trim === true && d.window === false && d.night === '23:15-06:40', 'window lines: ' + JSON.stringify([d.trim, d.window, d.night]));
chk(dozeKeepParse('trim=1\nlevel=aggressive').window === null, 'no window line must read as no window');
chk(dozeKeepParse('window=1').window === true, 'open window');
function app(p) { return { pkg: p, prot: p === 'com.auth', e: !!d.E[p], r: !!d.R[p], g: !!d.G[p], kept0: !!d.K[p] }; }
const A = app('com.a'), B = app('com.b'), C = app('com.c'), D = app('com.d'), P = app('com.auth');
function tag(a) { const t = dozeKeepTag(a); return t ? t[0] : '-'; }
_dozeKeep.trim = true; _dozeKeep.live = true; _dozeKeep.keep = { 'com.b': 1, 'com.d': 1 };
chk(tag(A) === 'trimmed', 'trimmed app: ' + tag(A));
chk(tag(B) === 'granted', 'ASB grant: ' + tag(B));
chk(tag(C) === '-', 'plain app: ' + tag(C));
chk(tag(D) === 'exempt', 'kept exempt app: ' + tag(D));
chk(tag(P) === 'always', 'protected app: ' + tag(P));
_dozeKeep.keep = { 'com.a': 1, 'com.c': 1, 'com.auth': 1 };
chk(tag(A) === 'back', 'ticking a trimmed app: ' + tag(A));
chk(tag(B) === 'drop', 'unticking an ASB grant: ' + tag(B));
chk(tag(C) === 'give', 'ticking an app with no exemption: ' + tag(C));
chk(tag(D) === 'drop' && dozeKeepTag(D)[1] === 'doze_tag_willtrim', 'unticking an exempt app while the trim is live: ' + tag(D));
chk(tag(P) === 'always', 'protected app ticked: ' + tag(P));
_dozeKeep.live = false;
chk(tag(D) === 'exempt', 'unticking an exempt app by day must not promise a trim: ' + tag(D));
chk(tag(C) === 'give', 'by day a tick still gets an exemption: ' + tag(C));
_dozeKeep.trim = false;
chk(tag(C) === '-' && tag(A) === 'trimmed' && tag(B) === 'granted', 'trim off: no promise of a change');
process.exit(bad ? 1 : 0);
EOF
} > "$T/t.js"
node "$T/t.js" || fail "see above"
echo "PASS webui doze keep tags: labels follow the tick, the night window is named, every language explains every label"
)

t_webui_monitor_card_head_runtime() (
# Runtime (fix162, reworked fix163): the Monitor card is symmetric, carries the time to empty
# beside each drain figure, and speaks the UI language.
#
# fix162 moved the "exact" chip off the card border into a title row; the owner found the card
# lopsided that way and the page half empty below the tiles, and asked for the screen-on and
# idle forecasts to sit with the two drain figures they belong to. fix163: a section title over
# the card (as on Home and Settings), two equal battery tiles - drain, then time to empty - and
# the eight Smart readings, the chip's meaning folded into a "Basis" reading; the live grid is
# three rows of three. The REAL page functions run in node.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor card: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor card: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'P' || fail "layout"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
top = s.index('id="liveTopSecLabel"')
sb = s[s.index('id="liveSmartBanner"'):s.index('id="liveStockRomBanner"')]
st = s[s.index('id="liveStockRomBanner"'):s.index('data-i18n="sec_live"')]
assert top < s.index('id="liveSmartBanner"'), "no section title over the card"
for part, name in ((sb, "Smart"), (st, "ROM")):
    assert "smart-banner-head" not in part and "smart-banner-tag" not in part and "tags" not in part, "%s card still carries a title row or chips" % name
strip = sb[sb.index('id="bnDrainStrip"'):sb.index('<div class="smart-banner-row">')]
halves = strip.split('class="smart-drain-half"')[1:]
assert len(halves) == 2, "want two drain tiles, have %d" % len(halves)
for h, val, eta in zip(halves, ("bnDrain", "bnDrainOff"), ("liveEtaOn", "liveEtaOff")):
    assert 'onclick="liveDrainOpen()"' in h, "a drain tile does not open the sheet"
    assert h.index('id="%s"' % val) < h.index('id="%s"' % eta), "%s is not under %s" % (eta, val)
for k in ("lv_bucket", "lv_conf", "lv_alpha", "lv_app", "lv_basis", "lv_slot_heat", "lv_trend", "lv_lpm"):
    assert ('data-i18n="%s"' % k) in sb, "Smart reading %s missing or untranslated" % k
assert 'id="bnSes"' not in sb and 'id="bnBasis"' in sb, "Basis did not take the sessions slot"
g = s[s.index('<div class="live-metrics">'):s.index('<section class="stock-telemetry"')]
rows = g.count('<div class="live-row">')
cells = len(re.findall(r'<div class="live-cell"(?: data-lvi="[a-z]+")?>', g))
assert rows == 3 and cells == 9 and "live-cell-wide" not in g, "live grid is %d rows / %d cells, want 3 x 3" % (rows, cells)
assert "fbTag" not in s and "T('lv_fb_' + fb," in s, "the slot source is still a chip"
assert "T('lv_mode_guard'," in s and "T('lv_mode_night'," in s, "night and thermal guard are not shown in Basis"
assert "T('lv_dp_' + dp, dpNames[dp])" in s and "T('lv_app_' + appH," in s, "day part or load class still English"
assert "+ '% bat'" not in s and "T('unit_d', 'd')" in s, "English units left"
assert "_el('liveLearner').textContent = sm.total + ' ' + _ses;" in s, "Learner repeats the confidence instead of the session count"
P
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in lv_card_smart lv_card_rom lv_bucket lv_conf lv_alpha lv_basis lv_we_short lv_wd_short lv_fb_tip lv_eta_meter_tip \
           lv_mode_night lv_mode_guard unit_d lv_dp_0 lv_dp_1 lv_dp_2 lv_dp_3 lv_dp_4 lv_dp_5 \
           lv_app_0 lv_app_1 lv_app_2 lv_app_3 lv_app_4 lv_fb_0 lv_fb_1 lv_fb_2 lv_fb_3 lv_fb_4; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
done
python3 - "$ROOT/webroot/i18n/ru.json" <<'P' || fail "ru strings"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for k, v in (("lv_bucket", "Слот"), ("lv_basis", "Основа"), ("lv_fb_0", "свой слот"), ("lv_app_2", "средняя"), ("lv_dp_0", "сон"), ("lv_card_smart", "Батарея и Smart"), ("lv_card_rom", "Батарея и система")):
    assert d[k] == v, (k, d[k])
P
{
  cat <<'EOF'
const _nodes = {};
function _el(id) { return _nodes[id] || null; }
function T(k, d) { return d; }
let _selectedProfile = 'smart';
const _lvMeter = { at: 0, cur: '', p: {} };
function liveDrainIsOpen() { return false; }
function liveDrainPaint() {}
EOF
  for fn in lvEtaFmt lvEtaPaint lvTopSec lvTopSecSync lvDrainHome lvMeterPaint lvPct; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  sed -n "/^const _lvEta = /p; /^const _lvDrain = /p" "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
function el(id) { const e = { id: id, textContent: '', title: '', style: { display: '' }, parentElement: null }; _nodes[id] = e; return e; }
const on = el('liveEtaOn'), off = el('liveEtaOff'); el('bnDrain'); el('bnDrainOff');
_lvEta.gov = { on: 536, onTip: 'gov on', off: 5000, offTip: 'gov off' };
_lvEta.cap = 88;
lvEtaPaint();
chk(on.textContent === '8h 56m' && off.textContent === '> 72h', 'Smart shows the governor forecast: ' + on.textContent + ' / ' + off.textContent);
_lvEta.chg = true; lvEtaPaint();
chk(on.textContent === '—' && off.textContent === '—', 'no time to empty while charging');
_lvEta.chg = false;
_selectedProfile = 'stock'; lvEtaPaint();
chk(on.textContent === '—' && off.textContent === '—', 'Stock without a measurement borrows nothing from the governor');
_lvMeter.p.stock = { on: 75, off: 50, offN: 1, onMin: 40 };
lvMeterPaint('stock');
chk(on.textContent === '11h 44m' && on.title.indexOf('measured') >= 0, 'Stock: level over its own measured drain: ' + on.textContent);
chk(off.textContent === '> 72h', 'Stock idle past three days shows the ceiling: ' + off.textContent);
_selectedProfile = 'battery'; lvMeterPaint('battery');
chk(on.textContent === '8h 56m' && off.textContent === '> 72h', 'Battery without a measurement falls back to the governor: ' + on.textContent);
_lvMeter.p.battery = { on: 120, off: 0, offN: 0, onMin: 30 };
lvMeterPaint('battery');
chk(on.textContent === '7h 20m' && off.textContent === '> 72h', 'Battery: measured screen-on, governor idle: ' + on.textContent + ' / ' + off.textContent);
const sec = { style: { display: 'none' } };
_nodes.liveTopSecLabel = { textContent: '', parentElement: sec };
const smart = el('liveSmartBanner'), rom = el('liveStockRomBanner');
smart.style.display = 'none'; rom.style.display = 'none';
lvTopSec(true);
chk(sec.style.display === 'none', 'section title hidden while no card is shown');
smart.style.display = ''; lvTopSec(true);
chk(sec.style.display === '' && _nodes.liveTopSecLabel.textContent === 'Battery & Smart', 'Smart card titled');
smart.style.display = 'none'; rom.style.display = ''; lvTopSec(false);
chk(_nodes.liveTopSecLabel.textContent === 'Battery & system', 'ROM card titled');
function card() {
  const c = { kids: [{ k: 'grid' }], style: { display: '' } };
  c.kids.forEach(function (k) { k.parentElement = c; });
  c.firstChild = c.kids[0];
  c.insertBefore = function (n, ref) {
    if (n.parentElement && n.parentElement !== c) { const p = n.parentElement; p.kids = p.kids.filter(function (k) { return k !== n; }); p.firstChild = p.kids[0] || null; }
    c.kids = c.kids.filter(function (k) { return k !== n; });
    const i = ref ? c.kids.indexOf(ref) : c.kids.length; c.kids.splice(i < 0 ? c.kids.length : i, 0, n); n.parentElement = c; c.firstChild = c.kids[0];
  };
  return c;
}
const a = card(), b = card(), strip = { k: 'strip', parentElement: null };
_nodes.bnDrainStrip = strip;
lvDrainHome(a); chk(a.kids[0] === strip, 'drain tiles open the Smart card');
lvDrainHome(b); chk(b.kids[0] === strip && a.kids.indexOf(strip) < 0, 'drain tiles move to the ROM card');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor card: section title, two drain tiles with their time to empty on every profile, Basis instead of chips, three by three live grid, all in the UI language"
)

t_webui_monitor_compact_runtime() (
# Runtime (fix161): the Monitor fits with room to spare, its heat tile no longer scares, every
# profile shows both drains, and the Settings restarts are one row of small tiles.
#
# Owner's screenshot: the last row of Monitor tiles touched the tab bar after the screen-on /
# screen-off pair went into the Smart card, and "usual peak 51.8 C" read as a hot phone - it is
# the hottest core at its busiest moment, and this phone's own norm is 41-49 C. Asked too: the
# drain pair on every profile (Stock included) and lighter restart buttons. The REAL page
# functions run in node; the markup is checked for the new layout.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor compact: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor compact: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'P' || fail "layout"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
b = s[s.index('id="liveSmartBanner"'):s.index('id="liveStockRomBanner"')]
assert b.index('id="bnDrainStrip"') < b.index('id="bnBucket"'), "drain pair is not the first row of the Smart card"
assert 'data-i18n="lv_slot_heat"' in b and 'lv_slot_temp' not in b, "the usual-peak tile is still a bare temperature"
st = s[s.index('id="liveStockRomBanner"'):s.index('<div class="live-metrics">')]
assert 'id="bnStockDrain"' in st, "stock card lost its battery current"
g = s[s.index('<div class="live-metrics">'):s.index('<section class="stock-telemetry"')]
for i in ("liveCpu", "liveSkin", "liveSurface", "liveState", "liveGpu", "liveHeadroom", "liveCapSrc", "liveClamp", "liveLearner"):
    assert ('id="%s"' % i) in g, "metric %s lost" % i
for i in ("liveEtaOn", "liveEtaOff"):
    assert ('id="%s"' % i) in b, "time to empty %s is not beside the drain figures" % i
r = s[s.index('<div id="cfgRebootWrap" class="cfg-reboot-row">'):]
r = r[:r.index('</div>')]
assert r.count('class="cfg-reboot-tile') == 3, "restarts are not three tiles"
assert "#cfgRebootWrap.cfg-reboot-row { display: grid; grid-template-columns: repeat(3, 1fr);" in s, "restart tiles not in one row"
assert re.search(r"if \(stockBanner\) \{ lvDrainHome\(stockBanner\);[^}]*lvMeterPaint\(_selectedProfile\); \}", s), "other profiles do not get the drain pair"
P
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in lv_slot_heat lv_heat_cool lv_heat_norm lv_heat_warm lv_heat_tip lv_drain_on_meter lv_drain_cmp cfg_reboot_tile cfg_soft_tile cfg_sysui_tile; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
  grep -q '"lv_heat_tip": "[^"]*%s[^"]*%s' "$ROOT/webroot/i18n/$l.json" || fail "$l.json lv_heat_tip needs two places"
done
{
  echo "var T = function (k, d) { return d; };"
  for fn in lvSlotHeat lvMeterParse; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
let h = lvSlotHeat(518, 414, 494);
chk(h.text === 'above normal' && h.warm === true, 'slot above the norm: ' + JSON.stringify(h));
chk(h.tip.indexOf('51.8') >= 0 && h.tip.indexOf('41') >= 0 && h.tip.indexOf('49') >= 0, 'number kept in the tooltip: ' + h.tip);
h = lvSlotHeat(487, 414, 494); chk(h.text === 'normal' && !h.warm, 'slot inside the norm: ' + h.text);
h = lvSlotHeat(400, 414, 494); chk(h.text === 'below normal' && !h.warm, 'slot under the norm: ' + h.text);
h = lvSlotHeat(0, 414, 494); chk(h.text === '—', 'nothing learned shows a dash');
h = lvSlotHeat(530, 0, 0); chk(h.text === 'normal' && !h.warm, 'no norm known: never "above"');
const m = lvMeterParse('smart 1170 300 7230 100 1\nbattery 300 100 0 0 0\nstock 2400 500 7200 100 1\njunk\ncurrent stock\n');
chk(m.cur === 'stock', 'current profile');
chk(m.p.smart.on === 92 && m.p.smart.off === 50, 'smart rates: ' + JSON.stringify(m.p.smart));
chk(m.p.battery.on === 0, 'under 10 min of screen time is not a rate');
chk(m.p.stock.on === 75 && m.p.stock.offN === 1, 'stock rates: ' + JSON.stringify(m.p.stock));
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor compact: drain pair first in the card on every profile, heat against the phone's own norm, restarts as one row of tiles"
)

t_webui_quiet_ui_runtime() (
# Runtime (fix145): the WebUI keeps still and quiet where it should.
#
# 1. Interface sounds: a switch, and no cue while another app plays. A CPH2691 user heard his
#    Bluetooth music dip in loudness and bass for about a second on opening the Audio
#    category - the length of the WebView stream each cue opens. The REAL sound block runs
#    on a fake AudioContext, a fake clock and a fake run(): dumpsys says another player has
#    started -> no cue; switched off -> no cue; the look is never taken while this page's
#    own stream could be the player counted.
# 2. Settings entrance: "the six category cards twitch every time I open Settings". The hub
#    was painted, slid in, and painted again with the loaded values - with the entrance
#    animation both times. Pinned: the entrance runs on a change of screen only, the slide-in
#    paint does not run it, and a same-screen repaint during an entrance waits for it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/webroot/index.html"
fail() { echo "FAIL webui quiet ui: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui quiet ui: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_s="$(grep -n '^let _uiAudioCtx = null;$' "$W" | head -1 | cut -d: -f1)"
_e="$(grep -n '^  } catch (e) { /\* no WebAudio: stay silent \*/ }' "$W" | head -1 | cut -d: -f1)"
[ -n "$_s" ] && [ -n "$_e" ] || fail "sound block not found"
{ sed -n "${_s},${_e}p" "$W"; echo "}"; } > "$T/s.js"
sed -n '/^const UI_SONIC = {/,/^};/p' "$W" > "$T/u.js"
cat > "$T/run.js" <<'X'
const fs = require('fs');
let now = 0; const timers = [];
global.setTimeout = (fn, ms) => { const t = { at: now + ms / 1000, fn, live: true }; timers.push(t); return t; };
global.clearTimeout = (t) => { if (t) t.live = false; };
function advance(s) {
  const end = now + s;
  for (;;) {
    const due = timers.filter(t => t.live && t.at <= end).sort((a, b) => a.at - b.at)[0];
    if (!due) break;
    now = due.at; due.live = false; due.fn();
  }
  now = end;
}
global.performance = { now: () => now * 1000 };
const store = {};
global.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
global.document = { hidden: false, addEventListener: () => {} };
let oscs = 0;
class FakeCtx {
  constructor() { this.state = 'running'; this.destination = {}; }
  get currentTime() { return now; }
  suspend() { this.state = 'suspended'; }
  resume() { this.state = 'running'; }
  createOscillator() { oscs++; return { frequency: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {}, start() {}, stop() {} }; }
  createGain() { return { gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {} }; }
}
global.window = { AudioContext: FakeCtx };
let playing = '0', looks = [];
global.run = (cmd) => { looks.push(cmd); return Promise.resolve({ stdout: playing + '\n' }); };
global._el = () => null; global.T = (k, d) => d; global.toast = () => {};
eval(fs.readFileSync(process.argv[2], 'utf8') + fs.readFileSync(process.argv[3], 'utf8') + `
(async () => {
  const flush = () => new Promise(r => setImmediate(r));
  const out = [];
  advance(2); await flush();                                    // the look taken at page open completes
  advance(18);
  uiSound('nav'); await flush();
  out.push('first=' + oscs + '/' + looks.length);           // looked at open (nothing playing) and again at the cue 15 s+ later
  advance(30);                                                  // own context suspended, cue long ago
  playing = '1';
  uiSound('nav'); await flush();
  const afterLook = oscs;
  out.push('lookedWhilePlaying=' + looks.length);
  uiSound('nav');
  out.push('mutedWhilePlaying=' + (oscs === afterLook));
  advance(20); playing = '0';
  uiSound('nav'); await flush();
  uiSound('nav');
  out.push('backAfterStop=' + (oscs > afterLook));
  // Never look while this page's own stream is the likely player.
  const n = looks.length; _uiOtherAudioAt = -1e9; uiSound('nav');
  out.push('noLookRightAfterOwnCue=' + (looks.length === n));
  // Switched off: nothing plays, the choice is stored.
  advance(30); _uiOtherAudio = false; const o = oscs;
  uiSoundToggle(); uiSound('nav');
  out.push('off=' + (oscs === o) + '/' + store.asb_ui_sound);
  uiSoundToggle();
  out.push('on=' + (oscs > o) + '/' + store.asb_ui_sound);
  out.push('cmd=' + /dumpsys audio .*state:started .*USAGE_\\(MEDIA\\|GAME/.test(looks[0]) );
  console.log(out.join(' '));
})();
`);
X
r="$(node "$T/run.js" "$T/u.js" "$T/s.js")"
printf '%s\n' "$r" | grep -q 'first=4/2' || fail "first cue: $r"
printf '%s\n' "$r" | grep -q 'lookedWhilePlaying=3' || fail "no second look after 15 s: $r"
printf '%s\n' "$r" | grep -q 'mutedWhilePlaying=true' || fail "a cue played over another app's audio: $r"
printf '%s\n' "$r" | grep -q 'backAfterStop=true' || fail "cues did not come back once playback stopped: $r"
printf '%s\n' "$r" | grep -q 'noLookRightAfterOwnCue=true' || fail "looked while its own stream could be counted: $r"
printf '%s\n' "$r" | grep -q 'off=true/0' || fail "switch off did not silence or was not stored: $r"
printf '%s\n' "$r" | grep -q 'on=true/1' || fail "switch on: $r"
grep -q 'id="cfgSoundBtn" onclick="uiSoundToggle()"' "$W" || fail "no sound switch in the settings tools row"
for f in "$ROOT"/webroot/i18n/*.json; do
  for k in ui_sound_aria ui_sound_on ui_sound_off; do grep -q "\"$k\":" "$f" || fail "$k missing in ${f##*/}"; done
done

# 2. Entrance motion only on a change of screen.
grep -q "if (_screen !== _cfgShownScreen) {" "$W" || fail "entrance not tied to a change of screen"
grep -q "^  _cfgShownScreen = 'hub';" "$W" || fail "the slide-in paint runs the entrance as well"
grep -q "(_cfgGroup || 'hub') === _cfgShownScreen && performance.now() < _cfgEnterUntil" "$W" \
  || fail "a repaint during the entrance restarts it"
_n="$(grep -c "list.classList.add('cfg-stagger');" "$W")"
[ "$_n" = 1 ] || fail "cfg-stagger added in $_n places (want exactly the screen-change one)"
echo "PASS webui quiet ui: cues switchable and quiet over other audio, entrance only on a change of screen"
)

t_webui_stock_monitor_runtime() (
# Runtime (fix168): on Stock the Monitor shows nine real ROM readings, never a trip point.
#
# Owner's screenshots after switching Smart -> Stock: CPU 95 C on a phone at 43 C, cells left
# as placeholders, and on a second visit almost nothing at all. The OP15 publishes
# cpu-hw-trip-0/1 as thermal zones reading a constant 95000 and the CPU filter took them; the
# page cleared its cells on open and then skipped the read as too recent. The REAL
# paintStockLive runs in node against a ROM sample shaped like the owner's phone.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui stock monitor: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui stock monitor: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -Fq "if (Object.keys(_stockTelemetryKv).length) paintStockLive(_stockTelemetryKv);" "$H" || fail "a throttled read still leaves the cells empty"
grep -Fq "    if (_selectedProfile === 'stock') pollStockTelemetry(true, true);" "$H" || fail "opening Monitor on Stock does not read a fresh sample"
grep -Fq "    paintStockLive(_stockTelemetryKv);" "$H" || fail "opening Monitor does not paint the last ROM sample"
grep -Fq "const ownGrid = _selectedProfile === 'stock';" "$H" || fail "the ROM sample still repaints the governor's grid on other profiles"
{
  cat <<'EOF'
const _nodes = {};
function _el(id) { if (!_nodes[id]) _nodes[id] = { id: id, textContent: '', title: '', className: '', style: { display: '' }, classList: { remove() {} } }; return _nodes[id]; }
function T(k, d) { return d; }
let _selectedProfile = 'stock';
let _stockRomHistory = { ts: 0, cpuT: 0 };
const _stockLiveInfo = { ceil: [] };
const _lvEta = { cap: 0, chg: false, gov: null };
function lvTopSecSync() {} function lvDrainHome() {} function lvTopSec() {} function lvMeterPaint() {}
EOF
  for fn in fmtTempC setLiveLabel fmtStockLoad paintStockLive; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const kv = {
  ts: '1760000000', uptime: '5400.2', loadavg: '6.12 5.80 5.10',
  'battery.capacity': '88', 'battery.current_now': '412000', 'battery.voltage_now': '4210000',
  'battery.temp': '331', 'battery.status': 'Discharging', 'battery.charge_full': '5300000',
  MemAvailable: '5242880 kB', SwapTotal: '8388604 kB', SwapFree: '5420000 kB',
  'cpu.policy0.scaling_cur_freq': '1785600', 'cpu.policy0.scaling_max_freq': '3628800', 'cpu.policy0.cpuinfo_max_freq': '3628800',
  'cpu.policy6.scaling_cur_freq': '1132800', 'cpu.policy6.scaling_max_freq': '1632000', 'cpu.policy6.cpuinfo_max_freq': '4608000',
  'gpu.gpuclk': '220000000', 'gpu.gpu_busy_percentage': '12 %',
  'thermal.cpu-1-1-0': '43000', 'thermal.cpu-1-1-1': '44500',
  'thermal.cpu-hw-trip-0': '95000', 'thermal.cpu-hw-trip-1': '95000', 'thermal.pmh0101-bcl-lvl0': '96000',
  'thermal.shell_frame': '29600', 'thermal.shell_back': '29700', 'thermal.board_temp': '41800',
  'thermal.gpuss-0': '43200', 'thermal.ddr': '44000'
};
paintStockLive(kv);
const v = (id) => _nodes[id] ? _nodes[id].textContent : '';
chk(v('liveCpu') === '45°C', 'CPU from the core zones, not the 95 C trip point: ' + v('liveCpu'));
chk(v('liveSkin') === '30°C', 'shell: ' + v('liveSkin'));
chk(v('liveSurface') === '42°C' && v('liveSurfaceLabel') === 'Board', 'board sensor: ' + v('liveSurface') + ' / ' + v('liveSurfaceLabel'));
chk(v('liveState') === '35%' && /cap-raised/.test(_nodes.liveState.className) && v('liveStateLabel') === 'CPU ceiling', 'CPU ceiling on the most limited cluster: ' + v('liveState'));
chk(_stockLiveInfo.ceil.length === 2 && _stockLiveInfo.ceil[1] === 'policy6: 1.63 / 4.61 GHz', 'ceiling lines for the sheet: ' + JSON.stringify(_stockLiveInfo.ceil));
chk(v('liveGpu') === '12%' && v('liveHeadroom') === '220 MHz', 'GPU load and clock: ' + v('liveGpu') + ' / ' + v('liveHeadroom'));
chk(v('liveCapSrc') === '33°C' && v('liveCapSrcLabel') === 'Battery', 'battery temperature: ' + v('liveCapSrc'));
chk(v('liveClamp') === '2.8 GB' && v('liveClampLabel') === 'zRAM used', 'zRAM in use: ' + v('liveClamp'));
chk(v('liveLearner') === 'paused' && v('liveLearnerLabel') === 'Smart learning', 'learner: ' + v('liveLearner'));
chk(v('bnStockLoad') === '6.12', 'system load is a number, not "1 min 6.12": ' + v('bnStockLoad'));
const tripOnly = { 'thermal.cpu-hw-trip-0': '95000', 'thermal.cpu-hw-trip-1': '95000', 'thermal.socd': '8' };
paintStockLive(tripOnly);
chk(v('liveCpu') === '—' && v('liveSurface') === '—', 'trip zones and the socd level are not temperatures: ' + v('liveCpu') + ' / ' + v('liveSurface'));
_selectedProfile = 'battery';
_nodes.liveCpu.textContent = '39°C'; _nodes.liveStateLabel.textContent = 'FSM';
paintStockLive(kv);
chk(v('liveCpu') === '39°C' && v('liveStateLabel') === 'FSM', 'on Battery the governor keeps its own grid');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui stock monitor: nine ROM readings on Stock, trip points and alarm zones never read as a temperature, last sample painted on every visit"
)

t_webui_live_info_runtime() (
# Runtime (fix168): every live tile opens an explanation in the UI language.
#
# Owner's request: a tap on any of the nine Monitor readings shows what it is and how to read
# it, in every language. Stock swaps five tiles for ROM readings, so it has its own five texts.
# fix172 extended the same sheet to the eight Smart-banner readings (slot, confidence, lean,
# load, basis, heat, trend, LPM); fix174 stops the weekday pill from gluing itself onto the
# slot value. The REAL liveInfoOpen runs in node against stub cells.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui live info: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui live info: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$ROOT" <<'P' || fail "texts"
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
s = (root / 'webroot' / 'index.html').read_text(encoding='utf-8')
lvi = s[s.index('const LVI_TEXT = {'):s.index('const LVI_STOCK')]
pairs = dict(re.findall(r"^  (\w+): \['(lvi_\w+)', ", lvi, re.M))
stock = dict(re.findall(r"(\w+): '(\w+)'", s[s.index('const LVI_STOCK = {'):].split('\n', 1)[0]))
cells = re.findall(r'<div class="live-cell" data-lvi="([a-z]+)">', s)
assert len(cells) == 9 and len(set(cells)) == 9, cells
for c in cells:
    assert c in pairs, "tile %s has no explanation" % c
banner = re.findall(r'<div class="smart-banner-item" data-lvi="([a-z]+)">', s)
assert len(banner) == 8 and len(set(banner)) == 8, banner
for b in banner:
    assert b in pairs, "banner reading %s has no explanation" % b
for pos, key in stock.items():
    assert pos in cells and key in pairs, "Stock tile %s -> %s has no explanation" % (pos, key)
assert len(stock) == 5, stock
en = json.loads((root / 'webroot' / 'i18n' / 'en.json').read_text(encoding='utf-8'))
for name, key in pairs.items():
    fb = re.search(r"%s: \['%s', '((?:[^'\\]|\\.)*)'\]" % (name, key), lvi).group(1)
    fb = re.sub(r'\\u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), fb)
    assert en.get(key) == fb, "en.json %s differs from the page fallback" % key
files = sorted((root / 'webroot' / 'i18n').glob('*.json'))
assert len(files) == 13
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for key in list(pairs.values()) + ['lvi_now', 'lvi_source', 'lvi_dwell']:
        assert isinstance(d.get(key), str) and d[key].strip(), "%s lacks %s" % (p.name, key)
    assert '%s' in d['lvi_dwell'], "%s: lvi_dwell lost its %%s" % p.name
    if p.name != 'en.json':
        same = [k for k in pairs.values() if d[k] == en[k]]
        assert not same, "%s: untranslated %s" % (p.name, same)
P
{
  cat <<'EOF'
const _nodes = {};
function mk(id) { const e = { id: id, textContent: '', className: '', hidden: true, title: '', attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {}, querySelector() { return null; } }; _nodes[id] = e; return e; }
function _el(id) { return _nodes[id] || null; }
function T(k, d) { return d; }
function uiSound() {} function navSyncSoon() {}
let _selectedProfile = 'smart';
const _stockLiveInfo = { ceil: ['policy6: 1.63 / 4.61 GHz'] };
const _lvLast = { st: { thermal_cpu_type: 'cpu-1-1-1' }, kv: { dwell_sec: '210', cpu_max_live: '3628800,1862400' } };
function liveInfoEnsure() { if (_nodes.liveInfoSheet) return _nodes.liveInfoSheet; ['liveInfoTitle', 'liveInfoNowLbl', 'liveInfoVal', 'liveInfoText', 'liveInfoSrc', 'liveInfoDone'].forEach(mk); return mk('liveInfoSheet'); }
function cell(pos, label, value, cls, title) {
  const l = { textContent: label }, v = { textContent: value, className: 'live-cell-value' + (cls ? ' ' + cls : ''), title: title || '' };
  return { getAttribute() { return pos; }, querySelector(q) { return q === '.live-cell-label' ? l : v; } };
}
function bcell(pos, label, value, cls, title, pill) {
  /* With a pill badge the real span reads "value"+"pill" through textContent, exactly
   * like the DOM the banner builder produces. */
  const l = { textContent: label }, v = { textContent: value + (pill || ''), className: 'smart-banner-value' + (cls ? ' ' + cls : ''), title: title || '' };
  if (pill) v.childNodes = [ { nodeType: 3, textContent: value }, { nodeType: 1, textContent: pill } ];
  return { getAttribute() { return pos; }, querySelector(q) {
    if (q === '.smart-banner-label') return l;
    if (q === '.smart-banner-value') return v;
    return null;
  } };
}
EOF
  sed -n "/^const LVI_TEXT = {/,/^};/p; /^const LVI_STOCK = /p" "$H"
  for fn in liveInfoSource liveInfoValText liveInfoOpen liveInfoClose; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
liveInfoOpen(cell('cpu', 'CPU', '41°C'));
chk(_nodes.liveInfoTitle.textContent === 'CPU' && _nodes.liveInfoVal.textContent === '41°C', 'title and value from the tile');
chk(_nodes.liveInfoText.textContent.indexOf('CPU cores') >= 0, 'CPU explanation');
chk(_nodes.liveInfoSrc.textContent === 'Source: cpu-1-1-1' && !_nodes.liveInfoSrc.hidden, 'CPU source zone: ' + _nodes.liveInfoSrc.textContent);
chk(!_nodes.liveInfoSheet.hidden, 'sheet opens');
liveInfoClose();
chk(_nodes.liveInfoSheet.hidden, 'sheet closes');
liveInfoOpen(cell('fsm', 'FSM', 'MODERATE'));
chk(_nodes.liveInfoSrc.textContent === 'in this state for 210 s', 'FSM dwell: ' + _nodes.liveInfoSrc.textContent);
liveInfoOpen(cell('headroom', 'Headroom', '40%'));
chk(_nodes.liveInfoSrc.textContent === '3.63 · 1.86 GHz', 'live ceilings: ' + _nodes.liveInfoSrc.textContent);
liveInfoOpen(cell('capsrc', 'Cap Src', 'ASB', 'cap-asb', 'owner=asb\nASB holds the ceiling'));
chk(_nodes.liveInfoVal.className === 'live-info-val cap-asb', 'value keeps the tile colour: ' + _nodes.liveInfoVal.className);
chk(_nodes.liveInfoSrc.textContent === 'ASB holds the ceiling', 'tile tooltip without raw key=value lines: ' + _nodes.liveInfoSrc.textContent);
_selectedProfile = 'stock';
liveInfoOpen(cell('fsm', 'CPU ceiling', '35%', 'cap-raised'));
chk(_nodes.liveInfoText.textContent.indexOf('In Stock ASB sets no ceilings') >= 0, 'Stock explains the ROM ceiling, not the FSM');
chk(_nodes.liveInfoSrc.textContent === 'policy6: 1.63 / 4.61 GHz', 'Stock ceiling per cluster: ' + _nodes.liveInfoSrc.textContent);
liveInfoOpen(cell('cpu', 'CPU', '45°C'));
chk(_nodes.liveInfoSrc.hidden, 'Stock shows no governor sensor name');
liveInfoOpen(cell('learner', 'Smart learning', 'paused'));
chk(_nodes.liveInfoText.textContent.indexOf('neither learns nor decides') >= 0, 'Stock learner text');
_selectedProfile = 'smart';
/* The eight Smart-banner readings open the same sheet: label and value come from the
 * banner's own span classes, and the value keeps its colour. */
liveInfoOpen(bcell('lpm', 'Modem LPM', 'save', 'cap-raised'));
chk(_nodes.liveInfoTitle.textContent === 'Modem LPM', 'banner item title: ' + _nodes.liveInfoTitle.textContent);
chk(_nodes.liveInfoVal.textContent === 'save', 'banner item value: ' + _nodes.liveInfoVal.textContent);
chk(_nodes.liveInfoVal.className === 'live-info-val cap-raised', 'banner value keeps its colour: ' + _nodes.liveInfoVal.className);
chk(_nodes.liveInfoText.textContent.indexOf('power mode') >= 0, 'LPM explanation: ' + _nodes.liveInfoText.textContent);
chk(!_nodes.liveInfoSheet.hidden, 'sheet opens from a banner item');
/* The slot value carries the weekday/weekend pill as a child element; the sheet must
 * show the slot name alone (the fix174 "вечервых" report). */
liveInfoOpen(bcell('slot', 'Слот', 'вечер', '', '#9 · вечер · вых', 'вых'));
chk(_nodes.liveInfoVal.textContent === 'вечер', 'pill badge is not glued onto the value: ' + _nodes.liveInfoVal.textContent);
chk(_nodes.liveInfoText.textContent.indexOf('twelve two-hour slots') >= 0, 'slot explanation: ' + _nodes.liveInfoText.textContent);
liveInfoOpen(bcell('slot', 'Slot', 'morning'));
chk(_nodes.liveInfoVal.textContent === 'morning', 'slot without a pill still reads whole: ' + _nodes.liveInfoVal.textContent);
liveInfoOpen(bcell('trend', 'Trend', '↑ warming', 'cap-clamp'));
chk(_nodes.liveInfoText.textContent.indexOf('warming') >= 0, 'trend explanation');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
grep -Fq "e.target.closest('.live-cell[data-lvi], .smart-banner-item[data-lvi]');" "$H" || fail "tiles and banner readings are not tappable"
grep -Fq "html[dir=\"rtl\"] .live-page .smart-banner-item[data-lvi]::after { content: '\\2039'; }" "$H" || fail "the banner chevron does not mirror in Arabic"
grep -Fq "html[dir=\"rtl\"] .live-page .live-cell[data-lvi]::after { content: '\\2039'; }" "$H" || fail "the tile chevron does not mirror in Arabic"
grep -Fq 'function liveInfoValText(val)' "$H" || fail "the sheet has no pill-safe value reader"
echo "PASS webui live info: all nine tiles and the eight Smart-banner readings explain themselves, the pill never glues onto the value, Stock has its own five, every language translated"
)

t_webui_fill_pages_runtime() (
# Runtime (fix168): Home and Settings fill the screen the way Monitor does, at any density.
#
# Owner's request: Home and Settings looked empty next to Monitor; bigger, richer profile cards
# and category tiles that look right on screens of different DPI. The free height is measured
# and shared out within limits, so a short screen scrolls and a tall one stops before the
# cards look stretched. The REAL asbFitPages runs in node against measured boxes.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui fill pages: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui fill pages: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$ROOT" <<'P' || fail "markup"
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
s = (root / 'webroot' / 'index.html').read_text(encoding='utf-8')
assert re.findall(r'<div class="pmeta" data-meter="(\w+)" hidden></div>', s) == ['smart', 'performance', 'balanced', 'battery', 'stock'], "a profile card lacks its measured drain"
for k in ('prof_performance_desc', 'prof_balanced_desc', 'prof_battery_desc'):
    assert ('class="pdesc" data-i18n="%s"' % k) in s, "%s card has no description" % k
assert re.search(r'\.pbtn \{[^}]*min-height: var\(--pbtn-h', s) and re.search(r'\.cfg-tile \{[^}]*min-height: var\(--cfg-tile-h', s), "cards do not take the fitted height"
# fix174: the six hub categories carry a quiet tint of their own hue so they lift off the
# neutral restart row, and the nine Monitor tiles are filled a notch stronger.
assert re.search(r'\.cfg-tile \{[^}]*color-mix\(in srgb, var\(--tech-icon, var\(--accent\)\) 11%', s), "hub tiles lost their category tint"
assert 'color-mix(in srgb, var(--tech-icon) 9%, #ffffff)' in s, "light hub tiles lost their category tint"
assert 'background: linear-gradient(135deg, rgba(255,255,255,0.065), rgba(255,255,255,0.024));' in s, "Monitor tiles lost their stronger fill"
assert "'cfg-tile-desc'" in s and "'cfg-tile-bar'" in s, "category tiles lack their description and fill bar"
assert "sub.className = 'smart-banner-pill' + (we ? ' we' : '');" in s, "weekday/weekend is still glued to the slot name"
assert "html[data-asb-font=\"device\"] { --sans: 'ASB Device', sans-serif; --mono: 'ASB Device', sans-serif; }" in s, "no device-font switch"
assert "'px @ '" not in s and "document.documentElement.dataset.asbUi = w + 'px@' + scale;" in s, "the scale reading is still glued to the device line"
files = sorted((root / 'webroot' / 'i18n').glob('*.json'))
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for k in ('prof_performance_desc', 'prof_balanced_desc', 'prof_battery_desc') + tuple('grp_%s_desc' % g for g in ('audio', 'camera', 'iface', 'net', 'battery', 'ui')):
        assert isinstance(d.get(k), str) and d[k].strip(), "%s lacks %s" % (p.name, k)
P
{
  cat <<'EOF'
let _cfgGroup = null;
const props = {};
const root = { style: { setProperty(k, v) { props[k] = v; } } };
const box = (top, h) => ({ getBoundingClientRect() { return { top: top, height: h }; } });
let barTop = 1700, profTop = 600, hubTop = 760, live = false, cfgOpen = false;
const pb = new Array(5).fill(0), tiles = new Array(6).fill(0);
const prof = { getBoundingClientRect() { return { top: profTop }; }, querySelectorAll() { return pb; } };
const hub = { getBoundingClientRect() { return { top: hubTop }; }, querySelectorAll() { return tiles; } };
const page = { scrollTop: 0, getAttribute() { return cfgOpen ? 'false' : 'true'; } };
const reb = box(0, 84);
global.window = { _asbUiScale: 1, innerHeight: 1900, scrollY: 0 };
global.document = {
  documentElement: root,
  body: { classList: { contains(c) { return (c === 'live-active' && live) || (c === 'config-active' && cfgOpen); } } },
  querySelector(q) { if (q === '.asb-tabbar') return box(barTop, 60); if (q.indexOf('.profiles') >= 0) return prof; if (q.indexOf('.cfg-hub') >= 0) return hub; return null; }
};
global.getComputedStyle = () => ({ rowGap: '10px', gap: '10px', marginTop: '10px' });
function _el(id) { return id === 'configPage' ? page : id === 'cfgRebootWrap' ? reb : null; }
EOF
  sed -n "/^function asbFitPages(/,/^}/p" "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
asbFitPages();
chk(props['--pbtn-h'] === '104px', 'a tall screen stops at the upper limit: ' + props['--pbtn-h']);
barTop = 1100; asbFitPages();
chk(props['--pbtn-h'] === '88px', 'shared out to the five cards: ' + props['--pbtn-h']);
barTop = 800; asbFitPages();
chk(props['--pbtn-h'] === '68px', 'a short screen keeps the floor and scrolls: ' + props['--pbtn-h']);
chk(props['--cfg-tile-h'] === undefined, 'Settings closed: tiles untouched');
cfgOpen = true; barTop = 1200; delete props['--pbtn-h']; asbFitPages();
chk(props['--pbtn-h'] === undefined, 'Home cards are not refitted while Settings covers them');
chk(props['--cfg-tile-h'] === '158px', 'two rows of tiles share the height left over the restart row: ' + props['--cfg-tile-h']);
_cfgGroup = 'audio'; props['--cfg-tile-h'] = 'x'; asbFitPages();
chk(props['--cfg-tile-h'] === 'x', 'an open category leaves the hub alone');
_cfgGroup = null; barTop = 2600; asbFitPages();
chk(props['--cfg-tile-h'] === '176px', 'upper limit on Settings: ' + props['--cfg-tile-h']);
barTop = 900; asbFitPages();
chk(props['--cfg-tile-h'] === '104px', 'floor on a short screen: ' + props['--cfg-tile-h']);
window._asbUiScale = 0.82; barTop = 1120; asbFitPages();
chk(props['--cfg-tile-h'] === '148px', 'a scaled UI shares out unscaled pixels: ' + props['--cfg-tile-h']);
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
grep -Fq "window.addEventListener('resize', function () { requestAnimationFrame(asbFitPages); });" "$H" || fail "the fit is not redone on resize"
echo "PASS webui fill pages: profile cards and category tiles take the free height within limits on any screen, with descriptions, measured drain and fill bars"
)

t_webui_device_font_runtime() (
# Runtime (fix168): the device-font test variant draws with the font the system UI uses.
#
# Owner's request: a variant with the WebUI text in the phone's font. A WebView only knows the
# families in fonts.xml, so a font applied through the font settings or a font app never reaches
# it; the variant takes the files the system UI process has mapped, prefers one applied from
# /data, falls back to the OnePlus system family, copies them next to the page and registers
# them under one name. The REAL discovery command runs against a fixture maps file and the REAL
# loader runs in node; the normal build never runs either.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui device font: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui device font: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q '^<html lang="en">$' "$H" || fail "the normal build must not carry the device-font switch"
grep -Fq "html[data-asb-font=\"device\"] { --sans: 'ASB Device', sans-serif; --mono: 'ASB Device', sans-serif; }" "$H" || fail "the variant does not draw with the found font"
mkdir -p "$T/mod/webroot" "$T/data/fonts" "$T/system/fonts"
printf 'R' > "$T/data/fonts/Custom-Regular.ttf"; printf 'B' > "$T/data/fonts/Custom-Bold.ttf"
printf 'E' > "$T/data/fonts/NotoColorEmoji.ttf"; printf 'S' > "$T/system/fonts/SysSans-En-Regular.ttf"
printf 'H' > "$T/system/fonts/SysSans-Hans-Regular.ttf"
for f in system/fonts/SysSans-En-Regular.ttf system/fonts/SysSans-Hans-Regular.ttf data/fonts/Custom-Regular.ttf data/fonts/Custom-Bold.ttf data/fonts/NotoColorEmoji.ttf; do
  printf '7000-8000 r--s 00000000 fd:00 1 %s\n' "$T/$f"
done > "$T/maps"
printf '7000-8000 r-xp 00000000 fd:00 1 /system/lib64/libc.so\n' >> "$T/maps"
cat > "$T/cmd.js" <<'EOF'
const fs = require('fs');
const [, , html, T] = process.argv;
const src = fs.readFileSync(html, 'utf8');
const m = src.match(/const ASB_DEVICE_FONT_CMD = ([\s\S]*?);\nfunction asbDeviceFontWeight/);
if (!m) { console.log('no command'); process.exit(1); }
const MD = T + '/mod';
let cmd = eval(m[1]);
for (const w of ['settings put', 'resetprop', 'setprop', 'rm ', 'mv ', '/sys/', 'echo ']) if (cmd.indexOf(w) >= 0) { console.log('writes outside its folder: ' + w); process.exit(1); }
cmd = cmd.replace('$(pidof com.android.systemui)', '1').replace('/proc/$p/maps', T + '/maps').replace('grep "^/data/"', 'grep "^' + T + '/data/"');
fs.writeFileSync(T + '/cmd.sh', cmd.replace(/^sh -c '/, '').replace(/'$/, '') + '\n');
EOF
node "$T/cmd.js" "$H" "$T" || fail "command"
out="$(sh "$T/cmd.sh")"
[ "$(printf '%s\n' "$out" | cut -d'|' -f1,2 | tr '\n' ' ')" = "f0.ttf|$T/data/fonts/Custom-Bold.ttf f1.ttf|$T/data/fonts/Custom-Regular.ttf " ] || fail "applied font not preferred: $out"
cmp -s "$T/mod/webroot/devfont/f1.ttf" "$T/data/fonts/Custom-Regular.ttf" || fail "font not copied next to the page"
grep -v '/data/fonts/' "$T/maps" > "$T/maps2"; mv "$T/maps2" "$T/maps"
out="$(sh "$T/cmd.sh")"
[ "$(printf '%s\n' "$out" | cut -d'|' -f1,2)" = "f0.ttf|$T/system/fonts/SysSans-En-Regular.ttf" ] || fail "no OnePlus family fallback, or a CJK face taken: $out"
{
  cat <<'EOF'
const faces = [];
global.FontFace = function (fam, src, d) { this.fam = fam; this.src = src; this.d = d; faces.push(this); this.load = () => Promise.resolve(this); };
const root = { dataset: {} };
global.document = { documentElement: root, fonts: { add() {}, delete() {} } };
let ran = 0;
function run() { ran++; return Promise.resolve({ stdout: 'f0.ttf|/data/x/Custom-Bold.ttf|11\nf1.ttf|/data/x/Custom-Regular.ttf|12\nf2.ttf|/data/x/OPlusSans3.0-VF.ttf|13\nf3.ttf|/data/x/Custom-LightItalic.ttf|14\njunk|/etc/passwd|1\n' }); }
const MD = '/m';
EOF
  sed -n "/^const ASB_DEVICE_FONT_CMD = /,/^function asbDeviceFontWeight/p" "$H" | sed '$d'
  for fn in asbDeviceFontWeight asbDeviceFont; do sed -n "/^\(async \)\{0,1\}function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
(async () => {
  let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
  chk(await asbDeviceFont() === 0 && ran === 0, 'the normal build runs nothing');
  root.dataset.asbFont = 'device';
  chk(await asbDeviceFont() === 4, 'four faces registered, the junk line ignored');
  chk(faces.every(f => f.fam === 'ASB Device'), 'one family name');
  chk(faces.map(f => f.d.weight).join(',') === '700,400,100 900,300', 'weights from the file names: ' + faces.map(f => f.d.weight).join(','));
  chk(faces[3].d.style === 'italic' && faces[0].d.style === 'normal', 'italic face');
  chk(faces[1].src === "url('devfont/f1.ttf?v=12')", 'served next to the page, refreshed when the copy changes: ' + faces[1].src);
  chk(root.dataset.asbFontSrc.indexOf('/data/x/Custom-Regular.ttf') >= 0, 'source recorded');
  if (bad) process.exit(1);
  console.log('ok');
})();
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui device font: the variant takes the system UI's own font, an applied one first, and the normal build runs nothing"
)

t_webui_option_labels_runtime() (
# Runtime (fix169): option buttons and value badges speak the UI language.
#
# Owner's Settings > Network in Russian: Wi-Fi power save offered "выкл / screen_off / always"
# under a badge reading "OFF", Leave Bad Wi-Fi listed "weak" and "unusable", Act on Wakelocks
# and Trim Background GPS showed bare "0" / "1", and the Wi-Fi scan slider read "1" where the
# action screen said "every 10 min". The REAL Topt, cfgScanLabel and cfgStatus run in node with
# the shipped en.json and ru.json; every language is checked for the labels.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui option labels: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui option labels: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$ROOT/webroot/i18n" <<'P' || fail "locales"
import json, sys, pathlib
need = {'bt_link_stability': ['stable'], 'net_wifi_leave': ['weak', 'unusable'],
        'wifi_powersave': ['screen_off', 'always'], 'wakelock_action': ['0', '1'],
        'gnss_trim': ['0', '1'], 'mglru_hold': ['hold']}
files = sorted(pathlib.Path(sys.argv[1]).glob('*.json'))
assert len(files) == 13
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for k, opts in need.items():
        for o in opts:
            v = d.get('optFor', {}).get(k, {}).get(o) or d.get('opt', {}).get(o)
            assert v and not (v == o and o.isdigit()), '%s: %s=%s has no label' % (p.name, k, o)
    assert d.get('wst_every', '').count('%s') == 1 and d.get('wst_free'), p.name + ': scan labels'
P
{
  printf 'const I18N = { en: %s, ru: %s };\n' "$(cat "$ROOT/webroot/i18n/en.json")" "$(cat "$ROOT/webroot/i18n/ru.json")"
  cat <<'EOF'
let ASB_LANG = 'ru';
function T(k, d) { const L = I18N[ASB_LANG]; return (L && typeof L[k] === 'string') ? L[k] : d; }
function ledgerBadge() { return null; } function trialHoursLeft() { return 0; } function trialExpired() { return false; }
const _netResult = {}; const _cfgVals = {};
EOF
  for fn in Topt cfgScanLabel cfgStatus; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
const seg = (key, stock) => ({ key: key, type: 'seg', stock: stock });
chk(Topt('screen_off', 'wifi_powersave') === 'экран выкл', 'power-save option: ' + Topt('screen_off', 'wifi_powersave'));
chk(cfgStatus(seg('wifi_powersave', 'off'), 'off').text === 'ВЫКЛ', 'badge over "выкл" reads OFF: ' + cfgStatus(seg('wifi_powersave', 'off'), 'off').text);
chk(cfgStatus(seg('wifi_powersave', 'off'), 'always').text === 'ВСЕГДА', 'badge: ' + cfgStatus(seg('wifi_powersave', 'off'), 'always').text);
chk(cfgStatus(seg('wakelock_action', '0'), '1').text === 'ДЕЙСТВОВАТЬ', 'wakelock badge: ' + cfgStatus(seg('wakelock_action', '0'), '1').text);
chk(cfgStatus(seg('net_congestion_wifi', 'auto'), 'cubic').text === 'CUBIC', 'technical names unchanged');
chk(cfgStatus({ key: 'wifi_scan_throttle', type: 'range' }, '1').text === 'раз в 10 мин', 'scan badge: ' + cfgStatus({ key: 'wifi_scan_throttle', type: 'range' }, '1').text);
chk(cfgScanLabel(0) === 'выкл' && cfgScanLabel(3) === 'раз в 2 мин' && cfgScanLabel(4) === 'без ограничений', 'scan labels');
chk(cfgStatus({ key: 'dsp_bass', type: 'range' }, '0').text === 'выкл', 'a range at zero says off in the UI language');
ASB_LANG = 'en';
chk(cfgScanLabel(2) === 'every 5 min', 'English scan label');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
grep -Fq "if (it.key === 'wifi_scan_throttle') return cfgScanLabel(v);" "$H" || fail "the slider value is still a bare number"
grep -Fq '.cfg-row-top > .cfg-range input[type="range"] { flex: 1 1 auto; width: auto; min-width: 0; }' "$H" || fail "a slider on its own row keeps its short track"
echo "PASS webui option labels: option buttons and value badges are labelled in the UI language, the Wi-Fi scan rate in minutes, sliders use their row"
)

_asb_tests() { declare -F | awk '$3 ~ /^t_/ { print substr($3, 3) }'; }
case "${1:-}" in
  --list) _asb_tests ;;
  --source) "_c_${2:?fixture name}" ;;
  *)
    _asb_failed=0
    for _asb_t in ${*:-$(_asb_tests)}; do
      "t_$_asb_t"
      [ $? -eq 0 ] || { printf 'FAILED: %s\n' "$_asb_t" >&2; _asb_failed=$((_asb_failed + 1)); }
    done
    [ "$_asb_failed" -eq 0 ]
    ;;
esac
