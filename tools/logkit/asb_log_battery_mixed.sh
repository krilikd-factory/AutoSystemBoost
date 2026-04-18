#!/system/bin/sh
# asb_log_battery_mixed.sh — ASB V38 RC5 log collection for daytime mixed use
#
# Scenario: phone on battery profile during normal daytime use — screen on/off
# transitions, light app use, background sync, some radio activity.
# Goal: see whether V38 RC5's relaxed TRUST_PARTIAL gate actually catches
# typical daytime sessions (iq=14-15, wph=8-11, wake=16-23) and produces
# trust=1 (PARTIAL) instead of trust=0 (DIRTY) as in pre-RC builds.
#
# Design:
#   - 20s poll interval — tighter than sleep, loose enough to not interfere
#   - Snapshot every 10 minutes
#   - Screen-transition timeline + radio activity log
#   - Hourly TRUST evaluation dump from governor.log
#   - Runs up to 8h by default
#
# Usage:  sh asb_log_battery_mixed.sh [hours=4]
# Output: /sdcard/asb_battery_mixed_<timestamp>.zip

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

LK_SCENARIO="battery_mixed"
LK_OUT_DIR="${TMPDIR:-/data/local/tmp}/asb_log_${LK_SCENARIO}_$$"
LK_POLL_S=20
LK_SNAPSHOT_S=600
LK_HOURS="${1:-4}"
LK_MAX_SEC=$(( LK_HOURS * 3600 ))

trap 'lk_finalize; exit 0' INT TERM HUP EXIT

lk_init
lk_check_profile_matches "battery" || exit 1
lk_battery_trace_header

echo "[$(date '+%H:%M:%S')] battery mixed-day capture running for up to ${LK_HOURS}h."
echo "                     Use phone normally. Ctrl-C to stop."

# Record initial governor.log tail position so we can diff "new lines since start"
_gov_start_lines=$(wc -l < "$LK_GOV_LOG" 2>/dev/null)
_gov_start_lines="${_gov_start_lines:-0}"

_last_snapshot=$(date +%s)
_last_trust_dump=$(date +%s)
_trust_dump_interval=3600   # every hour
_last_screen=""

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

  # Screen on/off timeline — a big signal for mixed-day behavior
  _screen=$(dumpsys power 2>/dev/null | grep -m1 "mWakefulness=" | sed 's/.*mWakefulness=//;s/ .*//')
  if [ -n "$_screen" ] && [ "$_screen" != "$_last_screen" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') wakefulness=$_screen (elapsed=${_elapsed}s)" >> "$LK_OUT_DIR/screen_timeline.txt"
    _last_screen="$_screen"
  fi

  # Periodic big snapshot
  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    lk_verify_caps
    _last_snapshot=$_now
  fi

  # Hourly TRUST dump — tracks gate evaluations over time
  if [ $(( _now - _last_trust_dump )) -ge "$_trust_dump_interval" ]; then
    {
      echo "--- TRUST snapshot at $(date) (elapsed=${_elapsed}s) ---"
      grep -E "pstats: battery trust=|BAT_TRUST_PARTIAL|BAT_TRUST_CLEAN|BAT_TRUST_DIRTY" "$LK_GOV_LOG" 2>/dev/null | tail -20
    } >> "$LK_OUT_DIR/trust_timeline.txt"
    _last_trust_dump=$_now
  fi

  sleep "$LK_POLL_S"
done
