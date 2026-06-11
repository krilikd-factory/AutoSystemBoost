#!/system/bin/sh
#
# ASB  Smart Mode — NIGHT SLEEP capture
#
# Usage (SAFE for overnight — survives Termux closure):
#   su
#   export MODDIR=/data/adb/modules/AutoSystemBoost
#   nohup sh $MODDIR/tools/logkit/asb_log_smart_sleep.sh [HOURS] >/data/local/tmp/smart_sleep.out 2>&1 &
#   # then you can close Termux and go to bed
#
# Default: 9 hours. Recommended 7-10h overnight.
# What it captures:
#   - Smart Mode state every 90s (idle is slow-changing)
#   - night_safe_override firing (MUST be 1 most of the night between 00-06h)
#   - Wakefulness events (notifications, alarms — note their effect on alpha)
#   - Battery drain trajectory for idle quality calculation
#   - Whether alpha stays high (battery-lean) consistently during sleep
#
# What to verify:
#   1. night_safe_override == 1 for most of 00:00-06:00 window
#   2. alpha_battery ≥ 900 during night_safe periods
#   3. interactive_bonus == 0 (no daytime-style perf headroom)
#   4. Drain rate (mAh/h) should be lower than baseline without smart
#
# Setup:
#   1. Plug in to charge briefly so battery is ≥60% but unplug before sleep
#   2. Verify Smart Mode is on: sh tools/asb_smart_mode.sh status
#   3. Run the nohup command above BEFORE bed
#   4. Close Termux — capture continues in background
#   5. In morning: collect the output dir from /data/local/tmp/

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

# Auto-detach so overnight capture survives Termux closure / phone sleep
if [ -t 0 ]; then
  if command -v setsid >/dev/null 2>&1; then
    if [ -z "${ASB_LOGKIT_DETACHED:-}" ]; then
      export ASB_LOGKIT_DETACHED=1
      echo "[autodetach] Re-launching detached for overnight capture"
      exec setsid sh "$0" "$@" </dev/null
    fi
  fi
fi

LK_SCENARIO="smart_sleep"
LK_OUT_DIR="${TMPDIR:-/data/local/tmp}/asb_log_${LK_SCENARIO}_$$"
LK_POLL_S=90
LK_SNAPSHOT_S=3600
LK_HOURS="${1:-9}"
LK_MAX_SEC=$(( LK_HOURS * 3600 ))

# Acquire kernel partial wakelock so the CPU stays awake during deep sleep.
# Without this, Android Doze mode pauses /bin/sh in long sleep() calls — capture
# gets only a handful of ticks over 2+ hours instead of one every LK_POLL_S sec.
# We write a unique name into /sys/power/wake_lock; the kernel keeps CPU awake
# while that name is registered. Released in lk_finalize_smart_sleep.
LK_WAKELOCK_NAME="asb_logkit_$$"
LK_HAVE_WAKELOCK=0
if [ -w /sys/power/wake_lock ]; then
  echo "$LK_WAKELOCK_NAME" > /sys/power/wake_lock 2>/dev/null && LK_HAVE_WAKELOCK=1
  if [ "$LK_HAVE_WAKELOCK" = "1" ]; then
    echo "[wakelock] acquired '$LK_WAKELOCK_NAME' — CPU will stay awake during capture"
  fi
fi
if [ "$LK_HAVE_WAKELOCK" = "0" ]; then
  echo "[wakelock] WARNING: /sys/power/wake_lock not writable — Doze may freeze the capture"
  echo "           (try: chmod 666 /sys/power/wake_lock as root, or run script as root)"
fi

trap 'lk_finalize_smart_sleep; exit 0' INT TERM HUP EXIT

lk_finalize_smart_sleep() {
  # Release kernel wakelock first so device can return to deep sleep
  if [ "$LK_HAVE_WAKELOCK" = "1" ]; then
    echo "$LK_WAKELOCK_NAME" > /sys/power/wake_unlock 2>/dev/null
  fi
  lk_capture_smart_sessions_window
  lk_snapshot_smart_store "after"
  lk_emit_smart_summary
  lk_emit_sleep_night_report
  lk_finalize
}

lk_emit_sleep_night_report() {
  _trace="$LK_OUT_DIR/smart_trace.tsv"
  _out="$LK_OUT_DIR/_sleep_night_report.txt"
  [ -r "$_trace" ] || return 0
  {
    echo "===== Night-sleep Smart Mode verification ====="
    echo ""

    # Override firing measured inside the sleep core only (daypart sleep/late).
    # A long morning tail in the capture must not poison the night verdict.
    echo "── Night_safe_override firing rate (sleep core: daypart sleep+late) ──"
    awk '$1+0 >= 1000000000 && $10 != "-" {
      n++; if ($10+0 == 1) o++
      if ($4+0 == 0 || $4+0 == 5) { cn++; if ($10+0 == 1) co++ }
      else { tn++; if ($10+0 == 1) to++ }
    } END {
      if (cn > 0) {
        printf "  sleep-core ticks: %d\n", cn
        printf "  override active:  %d (%.1f%%)\n", co+0, (co+0)*100.0/cn
        if ((co+0)*100.0/cn >= 70) print "  ✓ Healthy: override fired for majority of sleep core"
        else if ((co+0)*100.0/cn >= 30) print "  ⚠️  Partial: override fired for some sleep-core ticks"
        else print "  ✗ POOR: override rarely fired in sleep core — check conditions (screen, charging, app)"
      } else {
        print "  (no sleep-core ticks captured — capture window missed the night?)"
      }
      if (tn > 0) {
        printf "  wake/day tail:    %d ticks, override %d (%.1f%%) — informational only\n", tn, to+0, (to+0)*100.0/tn
      }
      if (n > 0) {
        printf "  full capture:     %d ticks, override %d (%.1f%%)\n", n, o+0, (o+0)*100.0/n
      }
    }' "$_trace"
    echo ""

    # When override fires, verify alpha is actually high
    echo "── Alpha_battery during override windows ──"
    awk '$1+0 >= 1000000000 && $10+0 == 1 && $8 != "-" {
      n++; v=$8+0; sum+=v
      if (n==1 || v<min) min=v
      if (n==1 || v>max) max=v
    } END {
      if (n>0) {
        printf "  override ticks: %d\n", n
        printf "  alpha avg: %.0f, min: %d, max: %d\n", sum/n, min, max
        if (min >= 900) print "  ✓ Healthy: alpha stayed ≥900 during all override ticks"
        else print "  ⚠️  alpha dipped below 900 during some override ticks — investigate"
      }
    }' "$_trace"
    echo ""

    # Daypart accounting — should mostly be sleep+late
    echo "── Daypart distribution during capture ──"
    awk '$1+0 >= 1000000000 && $4 != "-" {
      n[$4]++; tot++
    } END {
      for (k=0; k<6; k++) {
        if (n[k] > 0) {
          name = "?"
          if (k == 0) name = "sleep"; else if (k == 1) name = "wake"
          else if (k == 2) name = "morn"; else if (k == 3) name = "day"
          else if (k == 4) name = "eve"; else if (k == 5) name = "late"
          printf "  %s : %d (%.1f%%)\n", name, n[k], n[k]*100.0/tot
        }
      }
    }' "$_trace"
    echo ""

    # Battery drain inside the sleep core
    echo "── Battery drain (sleep core only) ──"
    awk '$1+0 >= 1000000000 && ($4+0 == 0 || $4+0 == 5) && $15 != "-" && $1 != "-" {
      if (!seen) { f=$15; ft=$1; seen=1 }
      l=$15; lt=$1
    } END {
      if (seen && lt > ft) {
        d = f - l
        h = (lt - ft) / 3600.0
        printf "  core start: %d%%  core end: %d%%  drop: %d%%  over %.1fh", f, l, d, h
        if (h > 0.5) printf "  = %.2f%%/h", d/h
        printf "\n"
      } else {
        print "  (insufficient sleep-core battery samples)"
      }
    }' "$_trace"
    echo ""

    # Battery drain over capture
    echo "── Battery drain over capture (incl. wake tail) ──"
    _first=$(awk '$1+0 >= 1000000000 && $15 != "-" { print $15; exit }' "$_trace")
    _last=$(awk '$1+0 >= 1000000000 && $15 != "-" { v=$15 } END { print v }' "$_trace")
    if [ -n "$_first" ] && [ -n "$_last" ]; then
      _delta=$(( _first - _last ))
      _dur_h=$(awk -v s="$LK_START_EPOCH" 'BEGIN { print (systime()-s)/3600 }')
      _rate=$(awk -v d="$_delta" -v h="$_dur_h" 'BEGIN { if (h>0) printf "%.2f", d/h; else print "0" }')
      echo "  start: ${_first}%   end: ${_last}%   drop: ${_delta}%"
      echo "  duration: ${_dur_h}h   drain rate: ${_rate}%/h"
      if [ "$_delta" -le 8 ]; then
        echo "  ✓ Excellent: drain ≤8% (typical good idle)"
      elif [ "$_delta" -le 15 ]; then
        echo "  Acceptable: drain 9-15%"
      else
        echo "  ⚠️  High drain: investigate background processes / radio activity"
      fi
    fi
    echo ""

    # Show daypart-transition events
    if [ -r "$LK_OUT_DIR/daypart_transitions.txt" ]; then
      echo "── Daypart transitions during night ──"
      cat "$LK_OUT_DIR/daypart_transitions.txt"
      echo ""
    fi

    echo "── Final bucket store status ──"
    sh "$MODDIR/tools/asb_smart_mode.sh" status 2>/dev/null | head -25
  } > "$_out"
  cat "$_out"
}

lk_init
lk_check_smart_mode_active || exit 1
lk_smart_trace_header
lk_snapshot_smart_store "before"

echo "[$(date '+%H:%M:%S')] Smart Mode NIGHT SLEEP capture running for up to ${LK_HOURS}h."
echo "                     Screen OFF + unplugged recommended. Don't touch the phone overnight."

_last_snapshot=$(date +%s)
_last_wake_state=""
_wake_events=0
_last_daypart=""
_daypart_transitions=0

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  {
    lk_status_watch_header
    lk_status_json
  } >> "$LK_OUT_DIR/status_watch.txt"
  lk_capture_battery_trace_row
  lk_capture_smart_trace_row
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

  # Wakefulness transitions
  _screen=$(dumpsys power 2>/dev/null | grep -m1 "mWakefulness=" | sed 's/.*mWakefulness=//;s/ .*//')
  if [ -n "$_screen" ] && [ "$_screen" != "$_last_wake_state" ]; then
    _wake_events=$((_wake_events + 1))
    _alpha=$(lk_state_kv smart_alpha_battery)
    _ov=$(lk_state_kv smart_sleep_override)
    {
      echo "$(date '+%Y-%m-%d %H:%M:%S') wake $_last_wake_state -> $_screen  (event #$_wake_events, alpha=${_alpha} override=${_ov})"
    } >> "$LK_OUT_DIR/wakefulness_timeline.txt"
    _last_wake_state="$_screen"
  fi

  # Daypart transitions (e.g. late→sleep at 00:00, sleep→wake at 06:00)
  _cur_dp=$(lk_state_kv smart_daypart)
  if [ -n "$_cur_dp" ] && [ -n "$_last_daypart" ] && [ "$_cur_dp" != "$_last_daypart" ]; then
    _daypart_transitions=$((_daypart_transitions + 1))
    {
      echo "$(date '+%Y-%m-%d %H:%M:%S') daypart $_last_daypart -> $_cur_dp  (transition #$_daypart_transitions)"
      grep '^smart_' /dev/.asb/state 2>/dev/null | sed 's/^/    /'
    } >> "$LK_OUT_DIR/daypart_transitions.txt"
  fi
  [ -n "$_cur_dp" ] && _last_daypart="$_cur_dp"

  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    lk_verify_caps
    _last_snapshot=$_now
  fi

  sleep "$LK_POLL_S"
done
