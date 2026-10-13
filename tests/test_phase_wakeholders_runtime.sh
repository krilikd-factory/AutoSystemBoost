#!/bin/sh
# Runtime (fix143): phase_wakeholders.txt names what held each screen-off phase awake INSIDE
# that phase, not batterystats' running totals.
#
# Capture 26147 printed "PowerManagerService.WakeLocks: 15m 2s" under a two-minute gap, with a
# header saying the figures were not the phase's own - and idle phases at 47-64% awake had no
# culprit. Apps: the step of batterystats' per-app partial wakelock timers (screen-off only)
# since the previous screen-off close. Kernel: /sys/class/wakeup at open and at close. The
# interim report's snapshot of the open phase no longer writes a block or dumps batterystats.
# The REAL ledger functions run here, with dumpsys and the wakeup class faked.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL phase wakeholders: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/out" "$T/wk/wakeup0" "$T/wk/wakeup1" "$T/wk/wakeup2"
: > "$T/dumpsys_calls"

cat > "$T/bin/dumpsys" <<'EOF'
#!/bin/sh
echo x >> "$FAKE_DIR/dumpsys_calls"
[ "$1" = batterystats ] && cat "$FAKE_DIR/bs"
exit 0
EOF
chmod +x "$T/bin/dumpsys"

# Helpers the scenario steps call: the fake batterystats and the fake wakeup class.
cat > "$T/defs.sh" <<'EOF'
bs() {   # pedometer time, system *alarm* time
  cat > "$T/bs" <<EOB
All kernel wake locks:
  Kernel Wake lock PowerManagerService.WakeLocks: 15m 2s 250ms (4 times) realtime
All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: $1 (5 times) max=79609 actual=425546 realtime
  Wake lock u0a691 *job*e/@androidx.work.systemjobscheduler@com.anthropic.claude/androidx.work.impl.background.systemjob.SystemJobService: 3m 27s 118ms (1 times) max=246955 actual=246955 realtime
  Wake lock 1000 *alarm*: $2 (29 times) realtime

  u0a493:
    Wake lock PedometerLib:tag: $1 partial (5 times) max=79609 realtime
EOB
}
wk() {   # pms_ms uart_ms own_ms
  echo PowerManagerService.WakeLocks > "$T/wk/wakeup0/name"; echo "$1" > "$T/wk/wakeup0/total_time_ms"
  echo 1994000.qcom,qup_uart > "$T/wk/wakeup1/name"; echo "$2" > "$T/wk/wakeup1/total_time_ms"
  echo asb_logkit_123 > "$T/wk/wakeup2/name"; echo "$3" > "$T/wk/wakeup2/total_time_ms"
}
ph() { echo "$2" > "$T/up"; echo "$3" > "$T/mono"; lk_phase_ledger_open "$1"; }
cl() { echo "$1" > "$T/up"; echo "$2" > "$T/mono"; lk_phase_ledger_flush; }
EOF

# The ledger functions, as the full-day recorder defines them.
awk '/^[a-z_][a-z0-9_]*\(\) *\{/ { f = 1 } f { print } f && /^}/ { f = 0 }' "$FD" > "$T/fns.sh"

out="$(PATH="$T/bin:$PATH" FAKE_DIR="$T" LK_OUT_DIR="$T/out" LK_WAKEUP_CLASS="$T/wk" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  . "$T/fns.sh"; . "$T/defs.sh"
  lk_uptime_s() { cat "$T/up"; }
  lk_mono_s() { cat "$T/mono"; }
  lk_phase_rmnet_bytes() { echo "0 0"; }
  LK_WAKELOCK_NAME=asb_logkit_123
  # 1. the first screen-off close of the capture: running totals, said so
  bs "4m 59s 837ms" "10s 0ms"; wk 900000 300000 5000
  ph gap 1000 1000
  bs "5m 41s 533ms" "12s 500ms"; wk 930000 301000 9000
  cl 1060 1040
  # 2. a screen-on phase: no batterystats read at its close
  ph active 1060 1040; cl 2000 1980
  echo "calls after active: $(wc -l < "$T/dumpsys_calls")"
  # 3. a screen-off stretch that turns out longer than a gap
  wk 2000000 400000 20000
  ph gap 2000 1980
  echo 2030 > "$T/up"; echo 2010 > "$T/mono"
  lk_phase_ledger_snapshot_open      # the interim report: no block, no dumpsys
  echo "calls after snapshot: $(wc -l < "$T/dumpsys_calls")"
  LK_PH_START=$(( $(date +%s) - 200 ))
  bs "7m 46s 533ms" "13s 0ms"; wk 2130000 440000 90000
  cl 2200 2100
  # 4. screen-off audio keeps the baseline current without printing
  ph audio_bt 2200 2100
  bs "8m 46s 533ms" "1m 13s 0ms"
  cl 2500 2490
  ph idle 2500 2490
  bs "8m 50s 533ms" "1m 13s 300ms"; wk 2200000 445000 99000
  cl 2700 2600
  echo "--- holders"; cat "$LK_OUT_DIR/phase_wakeholders.txt"
  echo "--- files"; ls -a "$LK_OUT_DIR"
' "$C" "$T" 2>&1)"

h="$(printf '%s\n' "$out" | sed -n '/^--- holders$/,/^--- files$/p')"
printf '%s\n' "$out" | grep -q '^calls after active: 1$' || f "a screen-on close read batterystats, or the first screen-off close did not: $out"
printf '%s\n' "$out" | grep -q '^calls after snapshot: 1$' || f "the interim snapshot read batterystats: $out"
[ "$(printf '%s\n' "$h" | grep -c '^phase=')" = 3 ] || f "expected three blocks (gap, idle-relabelled gap, idle; none for audio_bt or the snapshot): $h"
printf '%s\n' "$h" | grep -q 'dur=2s\|dur=30s' && f "a block for the phase still open: $h"
# 1: running totals, labelled.
printf '%s\n' "$h" | grep -q "^  app:    5m 41s  PedometerLib:tag  (u0a493)  since Android's last unplug - no earlier reading in this capture$" \
  || f "first close not labelled as running totals: $h"
printf '%s\n' "$h" | grep -q '^  kernel: +0m 30s  PowerManagerService.WakeLocks$' || f "kernel step of the first gap: $h"
printf '%s\n' "$h" | grep -q 'asb_logkit' && f "the capture's own lock listed: $h"
# 3: the 200-second "gap" is an idle, and its steps are its own.
blk="$(printf '%s\n' "$h" | awk '/^phase=/{n++} n==2')"
printf '%s\n' "$blk" | head -1 | grep -q '^phase=idle awake=60% dur=200s  (time gained inside this phase)$' || f "relabel or header: $blk"
printf '%s\n' "$blk" | grep -q '^  app:    +2m 05s  PedometerLib:tag  (u0a493)$' || f "app step in the idle stretch: $blk"
printf '%s\n' "$blk" | grep -q 'SystemJobService' && f "an app with no step listed: $blk"
printf '%s\n' "$blk" | grep -q '^  kernel: +2m 10s  PowerManagerService.WakeLocks$' || f "kernel step (open->close): $blk"
printf '%s\n' "$blk" | grep -q '^  kernel: +0m 40s  1994000.qcom,qup_uart$' || f "second kernel step: $blk"
# 4: after the audio phase the idle shows only its own 4 s, not the minute the audio phase added.
blk="$(printf '%s\n' "$h" | awk '/^phase=/{n++} n==3')"
printf '%s\n' "$blk" | grep -q '^  app:    +0m 04s  PedometerLib:tag  (u0a493)$' || f "baseline not carried through the audio phase: $blk"
printf '%s\n' "$blk" | grep -q '\*alarm\*' && f "a sub-second step listed: $blk"
printf '%s\n' "$out" | sed -n '/^--- files$/,$p' | grep -q '^\.wh_a_prev$' || f "baseline not kept: $out"
printf '%s\n' "$out" | sed -n '/^--- files$/,$p' | grep -qE '^\.wh_(a|k)_now$' && f "scratch files left: $out"

[ "$fail" = 0 ] && echo "PASS phase wakeholders: app and kernel time gained inside each screen-off phase, no blocks from interim snapshots"
exit "$fail"
