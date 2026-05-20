#!/system/bin/sh

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

LK_SCENARIO="battery_sleep"
LK_OUT_DIR="${TMPDIR:-/data/local/tmp}/asb_log_${LK_SCENARIO}_$$"
LK_POLL_S=60
LK_SNAPSHOT_S=1800
LK_HOURS="${1:-8}"
LK_MAX_SEC=$(( LK_HOURS * 3600 ))

trap 'lk_finalize; exit 0' INT TERM HUP EXIT

lk_init
lk_check_profile_matches "battery" || exit 1
lk_battery_trace_header

echo "[$(date '+%H:%M:%S')] battery sleep capture running for up to ${LK_HOURS}h."
echo "                     Screen OFF recommended. Press Ctrl-C to stop early."

_last_snapshot=$(date +%s)
_last_wake_state=""
_wake_events=0

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  {
    lk_status_watch_header
    lk_status_json
  } >> "$LK_OUT_DIR/status_watch.txt"
  lk_capture_battery_trace_row
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

  _screen=$(getprop init.svc.servicemanager >/dev/null 2>&1; dumpsys power 2>/dev/null | grep -m1 "mWakefulness=" | sed 's/.*mWakefulness=//;s/ .*//')
  if [ -n "$_screen" ] && [ "$_screen" != "$_last_wake_state" ]; then
    _wake_events=$((_wake_events + 1))
    {
      echo "$(date '+%Y-%m-%d %H:%M:%S') $_last_wake_state -> $_screen  (event #$_wake_events, elapsed=${_elapsed}s)"
    } >> "$LK_OUT_DIR/wakefulness_timeline.txt"
    _last_wake_state="$_screen"
  fi

  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    lk_verify_caps  # detects if anyone is silently overriding caps during sleep
    _last_snapshot=$_now
  fi

  sleep "$LK_POLL_S"
done

