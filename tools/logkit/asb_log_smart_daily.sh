#!/system/bin/sh
#
# ASB  Smart Mode — DAILY USE capture
#
# Usage (the SAFE way — survives terminal closure):
#   su
#   export MODDIR=/data/adb/modules/AutoSystemBoost
#   nohup sh $MODDIR/tools/logkit/asb_log_smart_daily.sh [HOURS] >/data/local/tmp/smart_daily.out 2>&1 &
#   # then you can close Termux — capture keeps running in background
#   # to check progress: ls -la /data/local/tmp/asb_log_smart_daily_*/
#   # to stop early:     killall asb_log_smart_daily.sh
#
# Default: 6 hours. Recommended 4-12h covering a normal weekday daytime.
# What it captures:
#   - Smart Mode runtime state every 60s (bucket, confidence, alpha, overrides)
#   - Session history entries that arrive during the window
#   - Daypart transitions and smoothing behaviour
#   - CPU temp & battery alongside Smart state for correlation
#   - Snapshot of buckets.bin before and after for learning diff
#
# IMPORTANT: if you just run "sh asb_log_smart_daily.sh 6" without nohup,
# closing Termux or losing SSH will KILL the script. Always use the nohup
# pattern above for any capture longer than a few minutes.

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

# Detach from controlling terminal if we have one (survives Termux closure)
# This is best-effort — if setsid/nohup isn't available, we continue anyway
if [ -t 0 ]; then
  if command -v setsid >/dev/null 2>&1; then
    # If we haven't already been re-exec'd in a new session, do so now
    if [ -z "${ASB_LOGKIT_DETACHED:-}" ]; then
      export ASB_LOGKIT_DETACHED=1
      echo "[autodetach] Re-launching in new session so capture survives Termux closure"
      echo "[autodetach] PID: $$ -> new session via setsid"
      exec setsid sh "$0" "$@" </dev/null
    fi
  fi
fi

LK_SCENARIO="smart_daily"
LK_OUT_DIR="${TMPDIR:-/data/local/tmp}/asb_log_${LK_SCENARIO}_$$"
LK_POLL_S=60
LK_SNAPSHOT_S=1800
LK_HOURS="${1:-6}"
LK_MAX_SEC=$(( LK_HOURS * 3600 ))

# Acquire kernel partial wakelock to prevent Doze from freezing the script.
LK_WAKELOCK_NAME="asb_logkit_$$"
LK_HAVE_WAKELOCK=0
if [ -w /sys/power/wake_lock ]; then
  echo "$LK_WAKELOCK_NAME" > /sys/power/wake_lock 2>/dev/null && LK_HAVE_WAKELOCK=1
  if [ "$LK_HAVE_WAKELOCK" = "1" ]; then
    echo "[wakelock] acquired — CPU will stay awake during capture"
  fi
fi

trap 'lk_finalize_smart; exit 0' INT TERM HUP EXIT

lk_finalize_smart() {
  if [ "$LK_HAVE_WAKELOCK" = "1" ]; then
    echo "$LK_WAKELOCK_NAME" > /sys/power/wake_unlock 2>/dev/null
  fi
  lk_snapshot_smart_store "after" 2>/dev/null || true
  lk_emit_report_card 2>/dev/null || true
  lk_capture_smart_sessions_window 2>/dev/null || true
  lk_emit_smart_summary 2>/dev/null || true
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
