#!/bin/sh
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
