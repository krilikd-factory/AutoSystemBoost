#!/system/bin/sh
#
# ASB V47 Smart Mode — DAILY USE capture
#
# Usage:
#   su
#   export MODDIR=/data/adb/modules/AutoSystemBoost
#   sh $MODDIR/tools/logkit/asb_log_smart_daily.sh [HOURS]
#
# Default: 6 hours. Recommended 4-12h covering a normal weekday daytime.
# What it captures:
#   - Smart Mode runtime state every 60s (bucket, confidence, alpha, overrides)
#   - Session history entries that arrive during the window
#   - Daypart transitions and smoothing behaviour
#   - CPU temp & battery alongside Smart state for correlation
#   - Snapshot of buckets.bin before and after for learning diff
#
# Best run on a normal weekday from morning to evening to capture multiple
# dayparts (wake/morn/day/eve) and daypart transitions where smoothing fires.

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

LK_SCENARIO="smart_daily"
LK_OUT_DIR="${TMPDIR:-/data/local/tmp}/asb_log_${LK_SCENARIO}_$$"
LK_POLL_S=60
LK_SNAPSHOT_S=1800
LK_HOURS="${1:-6}"
LK_MAX_SEC=$(( LK_HOURS * 3600 ))

trap 'lk_finalize_smart; exit 0' INT TERM HUP EXIT

lk_finalize_smart() {
  lk_capture_smart_sessions_window
  lk_snapshot_smart_store "after"
  lk_emit_smart_summary
  lk_finalize
}

lk_init
lk_check_smart_mode_active || exit 1
lk_smart_trace_header
lk_snapshot_smart_store "before"

echo "[$(date '+%H:%M:%S')] Smart Mode daily capture running for up to ${LK_HOURS}h."
echo "                     Use the phone normally. Press Ctrl-C to stop early."

_last_snapshot=$(date +%s)
_last_daypart=""
_daypart_transitions=0

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  # Per-tick capture
  {
    lk_status_watch_header
    lk_status_json
  } >> "$LK_OUT_DIR/status_watch.txt"
  lk_capture_battery_trace_row
  lk_capture_smart_trace_row
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

  # Detect daypart transitions
  _cur_dp=$(lk_state_kv smart_daypart)
  if [ -n "$_cur_dp" ] && [ -n "$_last_daypart" ] && [ "$_cur_dp" != "$_last_daypart" ]; then
    _daypart_transitions=$((_daypart_transitions + 1))
    {
      echo "$(date '+%Y-%m-%d %H:%M:%S') daypart $_last_daypart -> $_cur_dp  (transition #$_daypart_transitions, elapsed=${_elapsed}s)"
      echo "  Smart state at transition:"
      grep '^smart_' /dev/.asb/state 2>/dev/null | sed 's/^/    /'
    } >> "$LK_OUT_DIR/daypart_transitions.txt"
  fi
  [ -n "$_cur_dp" ] && _last_daypart="$_cur_dp"

  # Periodic full snapshot
  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    lk_verify_caps
    lk_snapshot_smart_store "mid_${_now}"
    _last_snapshot=$_now
  fi

  sleep "$LK_POLL_S"
done
