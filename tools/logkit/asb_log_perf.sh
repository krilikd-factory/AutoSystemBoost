#!/system/bin/sh

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

echo "[$(date '+%H:%M:%S')] waiting for clean performance state (up to 60s)..."
_gate_start=$(date +%s)
_gate_ready=0
while [ $(( $(date +%s) - _gate_start )) -lt 60 ]; do
  _j="$(lk_status_json)"
  _pr=$(echo "$_j"   | awk -F'"profile":"'               '{print $2}' | awk -F'"' '{print $1}')
  _tv=$(echo "$_j"   | awk -F'"temp_valid":'             '{print $2}' | awk -F, '{print $1}')
  _tp=$(echo "$_j"   | awk -F'"temp":'                   '{print $2}' | awk -F, '{print $1}')
  _ct=$(echo "$_j"   | awk -F'"thermal_cpu_type":"'      '{print $2}' | awk -F'"' '{print $1}')
  if [ "$_pr" = "performance" ] && [ "$_tv" = "1" ] && \
     { [ "${_tp:-0}" -gt 20 ] 2>/dev/null || [ "$_ct" != "socd" ] ; }; then
    _gate_ready=1
    echo "[$(date '+%H:%M:%S')] clean state reached: profile=$_pr temp=$_tp cpu_type=$_ct"
    break
  fi
  sleep 2
done
if [ "$_gate_ready" = "0" ]; then
  echo "[$(date '+%H:%M:%S')] WARNING: clean state not reached after 60s; logging anyway. Check thermal binding in before.txt." >&2
  echo "clean_start_gate: FAILED profile=$_pr temp=$_tp temp_valid=$_tv cpu_type=$_ct" > "$LK_OUT_DIR/clean_start_gate.txt"
else
  echo "clean_start_gate: OK profile=$_pr temp=$_tp temp_valid=$_tv cpu_type=$_ct" > "$LK_OUT_DIR/clean_start_gate.txt"
fi

echo "[$(date '+%H:%M:%S')] performance capture running for up to ${LK_MINUTES}min."
echo "                     Start your game now. Ctrl-C to stop when session ends."

_last_snapshot=$(date +%s)
_prev_state=""
_prev_used_fb=""

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  _j="$(lk_status_json)"
  {
    lk_status_watch_header
    echo "$_j"
  } >> "$LK_OUT_DIR/status_watch.txt"
  lk_capture_perf_trace_row
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

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

  if [ -n "$_ufb" ] && [ "$_ufb" != "$_prev_used_fb" ]; then
    echo "$(date '+%H:%M:%S') used_fallback ${_prev_used_fb:-init}->${_ufb}  fb_type=${_fb}  cpu_temp=${_tp}C" >> "$LK_OUT_DIR/thermal_source_flips.txt"
    _prev_used_fb="$_ufb"
  fi

  if [ $(( LK_TICK_COUNT % LK_CAP_CHECK_EVERY_N )) -eq 0 ]; then
    lk_verify_caps
  fi

  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    _last_snapshot=$_now
  fi

  sleep "$LK_POLL_S"
done
