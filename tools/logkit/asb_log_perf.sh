#!/system/bin/sh
# asb_log_perf.sh — ASB V38 RC5 log collection for long heavy gaming sessions
#
# Scenario: phone on performance profile, COD Mobile 144fps for 45-90 min.
# Goal: verify V38 RC5 cooling works end-to-end:
#   - service.sh no longer overrides profile CPU_CAP_BIG with 3648000
#   - governor stays below ~72C peak (was 78-92C)
#   - SUSTAINED% drops to <50% (was 53-77%)
#   - exit=55 hysteresis lets device leave SUSTAINED during brief cool-offs
#   - thermal_cpu_fallback behavior is correct (no silent re-bind)
#
# Design (the critical decisions):
#   - 3s poll interval — fine enough to catch state transitions that were
#     previously compressed into 5s buckets
#   - 1s perf_trace row — the tight telemetry stream that asb_analyze.py
#     chews through for temperature histograms and cap_gap series
#   - Snapshot every 10 minutes — state + dumpsys thermalservice
#   - Cap verification written every 30 tick (~1.5 min) to catch shell desyncs
#     in real-time rather than only at start/end
#   - SUSTAINED entry/exit are copied inline into state_transitions.txt
#     with surrounding 10 ticks of context (via lk_finalize post-process)
#   - Runs up to 2h by default
#
# Usage:  sh asb_log_perf.sh [minutes=60]
# Output: /sdcard/asb_perf_<timestamp>.zip

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

LK_SCENARIO="perf"
LK_OUT_DIR="${TMPDIR:-/data/local/tmp}/asb_log_${LK_SCENARIO}_$$"
LK_POLL_S=3
LK_SNAPSHOT_S=600
LK_CAP_CHECK_EVERY_N=30     # ~1.5 min
LK_MINUTES="${1:-60}"
LK_MAX_SEC=$(( LK_MINUTES * 60 ))

trap 'lk_finalize; exit 0' INT TERM HUP EXIT

lk_init
lk_check_profile_matches "performance" || exit 1
lk_perf_trace_header

echo "[$(date '+%H:%M:%S')] performance capture running for up to ${LK_MINUTES}min."
echo "                     Start your game now. Ctrl-C to stop when session ends."

_last_snapshot=$(date +%s)
_prev_state=""
_prev_used_fb=""

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  # Status + perf_trace row
  _j="$(lk_status_json)"
  {
    lk_status_watch_header
    echo "$_j"
  } >> "$LK_OUT_DIR/status_watch.txt"
  lk_capture_perf_trace_row
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

  # Emit explicit state-change event lines while we're live — much better
  # than post-processing status_watch because we can include the live
  # governor.log tail context right at the transition moment.
  _st=$(echo "$_j" | awk -F'"state":"' '{print $2}' | awk -F'"' '{print $1}')
  _tp=$(echo "$_j" | awk -F'"temp":' '{print $2}' | awk -F, '{print $1}')
  _rs=$(echo "$_j" | awk -F'"last_sustained_reason":"' '{print $2}' | awk -F'"' '{print $1}')
  _hv=$(echo "$_j" | awk -F'"headroom_valid":' '{print $2}' | awk -F, '{print $1}')
  _fb=$(echo "$_j" | awk -F'"thermal_cpu_fallback_type":"' '{print $2}' | awk -F'"' '{print $1}')
  _ufb=$(echo "$_j" | awk -F'"used_fallback":' '{print $2}' | awk -F, '{print $1}')
  if [ -n "$_st" ] && [ "$_st" != "$_prev_state" ]; then
    {
      echo "--- STATE CHANGE $(date '+%H:%M:%S') elapsed=${_elapsed}s ---"
      echo "  $_prev_state -> $_st  temp=${_tp}C  reason=${_rs}  hr_valid=${_hv}  fb=${_fb}"
      echo "  governor.log context (last 5 lines):"
      tail -5 "$LK_GOV_LOG" 2>/dev/null | sed 's/^/    /'
      echo ""
    } >> "$LK_OUT_DIR/live_transitions.txt"
    _prev_state="$_st"
  fi

  # Thermal source flip detection — V38 RC added used_fallback to status JSON
  if [ -n "$_ufb" ] && [ "$_ufb" != "$_prev_used_fb" ]; then
    echo "$(date '+%H:%M:%S') used_fallback ${_prev_used_fb:-init}->${_ufb}  fb_type=${_fb}  cpu_temp=${_tp}C" >> "$LK_OUT_DIR/thermal_source_flips.txt"
    _prev_used_fb="$_ufb"
  fi

  # Periodic cap verify — the reason this run exists
  if [ $(( LK_TICK_COUNT % LK_CAP_CHECK_EVERY_N )) -eq 0 ]; then
    lk_verify_caps
  fi

  # Periodic big snapshot
  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    _last_snapshot=$_now
  fi

  sleep "$LK_POLL_S"
done
